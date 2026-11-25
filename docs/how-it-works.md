# How It Works

Kasa Collector is an asynchronous data-collection service (Python 3.14) that discovers TP-Link Kasa smart plugs and power strips on your network, polls them for energy and system data, and writes time-series points to InfluxDB for Grafana to visualize. This page explains the pieces and how a reading gets from a device into your dashboard.

For configuration and deployment specifics, see [configuration.md](configuration.md) and [deployment.md](deployment.md); for dashboards, see [grafana-dashboards.md](grafana-dashboards.md).

## Component architecture

The application is a small set of cooperating components, each with a single job. They live under the `app/` package and are wired together by the orchestrator.

- **Main orchestrator** (`app/main.py`) — the entry point (`python -m app.main`). It validates configuration and prints an effective-config dump (secrets masked) on startup, opens the storage connection (waiting up to 60 s for an InfluxDB that is still starting), acquires device clients, launches the long-running tasks, and owns graceful shutdown.
- **Device manager** (`app/collector/device_manager.py`) — the device registry. It initializes manual devices, runs discovery, authenticates devices, and tracks which ones have an energy meter and therefore need polling. It maintains separate registries for all devices, emeter-capable devices, and polling devices.
- **Kasa API** (`app/collector/kasa_api.py`) — a thin wrapper over the `python-kasa` library. It handles broadcast discovery, direct/cross-subnet connections, protocol differences between IOT and SMART device families, fetching emeter and sysinfo data, and clean disconnection.
- **Poller** (`app/collector/poller.py`) — the data-collection engine. It runs two independent loops (energy and system info) at different cadences, collecting from all devices concurrently and handing points to storage.
- **InfluxDB storage** (`app/storage/influxdb.py`) — the persistence layer. It shapes device readings into InfluxDB points with the right measurements and tags and writes them asynchronously.
- **DNS cache** (`app/collector/dns_cache.py`) — a shared, TTL-based cache for reverse hostname lookups, so frequent polling doesn't repeatedly resolve the same IPs.
- **Health check** (`app/health/check.py`) — a standalone script (`python -m app.health.check`) used as the Docker `HEALTHCHECK`; it is healthy only on a fresh heartbeat that this run writes after each energy-poll cycle that stored data, so it reflects collection, not just a live process.

## Device discovery

There are two ways devices enter the registry, and they can be used together.

### Broadcast auto-discovery

When `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY` is enabled, the collector sends UDP broadcasts on port 9999 (IOT devices) and ports 20002 and 20004 (SMART/KLAP devices) and listens for device replies. This is TP-Link's proprietary discovery protocol (not mDNS) and requires bidirectional UDP on the LAN the devices are on, which is why the container runs with **host networking**. Discovery only reaches the collector's own subnet. Credentials are never included in the broadcast; they are used only in the later per-device login, for devices allowed to receive them (see [configuration.md](configuration.md#authentication-tp-link)).

An initial discovery runs once at startup; the first re-discovery runs after `KASA_COLLECTOR_DISCOVERY_CATCH_UP_DELAY` (30 s), then every `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL`, to pick up newly added devices. Newly seen devices are authenticated concurrently. Every address the collector has collected from is remembered in `known_devices.json` in the output directory and probed directly on each round, so a device that stops answering broadcasts keeps being collected, across restarts. With `KASA_COLLECTOR_KEEP_MISSING_DEVICES=False`, a device that misses `KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD` rounds and has not answered a poll recently stops being polled; its address is still probed each round. Manual hosts are never pruned — they legitimately won't appear in a broadcast result.

### Manual hosts and cross-subnet

For devices broadcast can't reach — different VLANs or subnets — list them explicitly in `KASA_COLLECTOR_DEVICE_HOSTS` (comma-separated IPs or hostnames). Manual devices are initialized in parallel at startup. Rather than broadcasting, they use `discover_single()`, a unicast UDP query to that one host that detects its device type and protocol (IOT vs SMART), falling back to a direct `Device.connect()`. No broadcast is needed, so it works across subnets. Each discovery round retries a manual host that has not connected yet and re-resolves a hostname, following a device the router moves to a new address.

## Authentication

Older **IOT** devices (IotPlug, IotStrip, and similar) on the legacy XOR transport need no credentials — once discovered they're ready after a state update. **SMART** devices, and IOT devices on KLAP firmware (such as an HS300 on firmware 1.1.2), require TP-Link cloud credentials, supplied via `KASA_COLLECTOR_TPLINK_USERNAME` and `KASA_COLLECTOR_TPLINK_PASSWORD`.

The device manager authenticates with layered fallbacks and retries. It first tries the object returned by discovery; if that fails it opens a fresh connection with credentials (each attempt bounded by `KASA_COLLECTOR_AUTH_TIMEOUT`, up to `KASA_COLLECTOR_AUTH_MAX_RETRIES` attempts back to back); and as a last resort it tries connecting without credentials, since some devices need none. Credential-specific failures ("challenge", "authentication") short-circuit the retries and surface a clear message telling you to set the TP-Link variables. A device's emeter capability is determined right after it connects, which is what routes it into the polling set.

## The poll cycle and what gets written

The poller runs two loops, each collecting from all emeter-capable devices concurrently with a `TaskGroup`. Each loop measures its own duration, warns when a cycle approaches or exceeds its interval, then sleeps for the remaining time so cadence stays steady. A single unreachable device can't abort a cycle: each device's read, retries included, must finish within 80% of the interval, and its writes get a budget of the same size; a device that fails is counted and its siblings still complete.

- **Energy loop** — every `KASA_COLLECTOR_DATA_FETCH_INTERVAL` (default 15s). Updates each device and reads its energy meter.
- **System-info loop** — every `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL` (default 60s). Reads model, firmware, state, wifi signal, and (for strips) child metadata.

Readings become InfluxDB points across these measurements:

- **`emeter`** — energy metrics as integer fields, one point per metric: `power_mw`, `current_ma`, `voltage_mv` and `total_wh` (lifetime energy). Plugs on legacy firmware that report A / V / W / kWh (HS110 hardware v1) are converted to these units, never truncated. SMART devices write what their firmware reports: on energy monitoring v1, `power_mw` and `total` (today's energy in whole kWh); on v2, `power_mw`, `current_ma`, `voltage_mv` and `energy_wh` as reported. Both also write `today_wh` and `month_wh` from the device's energy counters. python-kasa reads no lifetime counter for SMART devices, so they write no `total_wh`. A value InfluxDB cannot hold (NaN, infinity, an integer outside int64) drops only its own field. Every point is tagged with `ip`, `dns_name`, `device_alias` and `equipment_type`; `device_id` is added when known.
- **Per-outlet strip points** — for a power strip (an IOT HS300, or a SMART P316M whose outlets measure their own energy), the parent aggregate is written to `emeter` tagged `equipment_type=device`, and each child outlet is written to `emeter` as its own point tagged `equipment_type=plug` with `plug_alias`, the strip's `device_id`, and a numeric `plug_id`: the outlet's position on the strip, the same numbering as `sysinfo_child`. Outlets that share a name still get separate series. An IOT strip is read in full before any of it is written, so an outlet that does not answer leaves the whole strip unwritten for that cycle. On a SMART strip, an outlet that does not answer is left out and the other outlets are written; an outlet whose energy python-kasa has stopped reading after repeated errors is left out, and the strip is connected afresh in the background (at most once a minute at first, backing off to once an hour) while it keeps being polled; the new connection replaces the old one once it works.
- **`sysinfo`** and **`sysinfo_child`** — per-device and per-plug system information. Each key is written as one InfluxDB field type whatever a device reports (`app/storage/sysinfo_fields.py`), so one device can never make another's point fail with a field type conflict; a value that does not fit its key's type is left out. A device's coordinates, Wi-Fi network name (`ssid`, `bssid`) and `lnk_on` are never written. Sysinfo is also cached in memory for the energy loop.
- **`collector_stats`** — the collector's own per-cycle health, tagged by `cycle` (`emeter`/`sysinfo`), with fields for devices attempted, succeeded, `failed` (the device could not be polled, or answered with a reading that could not be stored), `write_failed` (the device answered but InfluxDB rejected the write) and cycle duration. This lets you watch the collector itself in Grafana alongside device data.

Optionally, with `KASA_COLLECTOR_WRITE_TO_FILE` enabled, each cycle is also appended to `.jsonl` files in `KASA_COLLECTOR_OUTPUT_DIR` — useful for debugging. The health check does not use these files.

## Async design

The whole collector is `asyncio`-native. Discovery, authentication, and both poll loops fan out over devices with `TaskGroup`, so many devices are contacted in parallel rather than serially, and exception groups keep one device's failure from taking down the rest. Reverse DNS lookups go through the shared TTL cache (`KASA_COLLECTOR_DNS_CACHE_TTL`) so repeated polling stays cheap. InfluxDB writes are asynchronous too: each cycle awaits one write per device (a strip's points go together), plus one `collector_stats` point. Write errors are logged with actionable guidance (for example auth/bucket problems) without stopping collection; that cycle's points are counted as `write_failed` and not resent, and the next cycle writes fresh readings. Every log line is scrubbed of the configured secrets before it is written.

## Graceful shutdown

Signal handlers for **SIGTERM** (from `docker stop` or a Kubernetes termination) and **SIGINT** (Ctrl-C) trigger an orderly shutdown; without them, SIGTERM to PID 1 would be dropped and the container killed without closing its connections. On shutdown the orchestrator cancels the running tasks (bounded by `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`), closes the InfluxDB connection, and disconnects from every device concurrently (each disconnect bounded by `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT`), clearing all registries. Writes are awaited every cycle, so there is no buffer to flush.

## Storage and networking recap

Metrics land in **InfluxDB 2.x**, which Grafana reads. The bundled dev, local and demo stacks provision InfluxDB with a v1 DBRP mapping (`ops/influxdb/init-dbrp.sh`) and a Grafana datasource in InfluxQL mode, because the dashboards are written in InfluxQL. If you point the collector at your own InfluxDB 2.x, you'll need to set up the equivalent DBRP mapping and datasource yourself — see [grafana-dashboards.md](grafana-dashboards.md). Because auto-discovery needs UDP broadcast, the container uses host networking; if that isn't possible, drive everything through `KASA_COLLECTOR_DEVICE_HOSTS` instead.

## Testing without hardware

You can exercise the full pipeline with no physical devices using the end-to-end harness (`make test-e2e`), which runs fake Kasa emulators (`harness/fake_kasa.py` for IOT, `harness/fake_smart.py` for SMART/KLAP) against the collector and an ephemeral InfluxDB. See [docs/testing.md](testing.md).
