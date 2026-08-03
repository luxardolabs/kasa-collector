# How It Works

Kasa Collector is an asynchronous data-collection service (Python 3.14) that discovers TP-Link Kasa smart plugs and power strips on your network, polls them for energy and system data, and writes time-series points to InfluxDB for Grafana to visualize. This page explains the pieces and how a reading gets from a device into your dashboard.

For configuration and deployment specifics, see [configuration.md](configuration.md) and [deployment.md](deployment.md); for dashboards, see [grafana-dashboards.md](grafana-dashboards.md).

## Component architecture

The application is a small set of cooperating components, each with a single job. They live under the `app/` package and are wired together by the orchestrator.

- **Main orchestrator** (`app/main.py`) — the entry point (`python -m app.main`). It validates configuration and prints an effective-config dump (secrets masked) on startup, opens the storage connection, acquires device clients, launches the long-running tasks, and owns graceful shutdown.
- **Device manager** (`app/collector/device_manager.py`) — the device registry. It initializes manual devices, runs discovery, authenticates devices, and tracks which ones have an energy meter and therefore need polling. It maintains separate registries for all devices, emeter-capable devices, and polling devices.
- **Kasa API** (`app/collector/kasa_api.py`) — a thin wrapper over the `python-kasa` library. It handles broadcast discovery, direct/cross-subnet connections, protocol differences between IOT and SMART device families, fetching emeter and sysinfo data, and clean disconnection.
- **Poller** (`app/collector/poller.py`) — the data-collection engine. It runs two independent loops (energy and system info) at different cadences, collecting from all devices concurrently and handing points to storage.
- **InfluxDB storage** (`app/storage/influxdb.py`) — the persistence layer. It shapes device readings into InfluxDB points with the right measurements and tags and writes them asynchronously.
- **DNS cache** (`app/collector/dns_cache.py`) — a shared, TTL-based cache for reverse hostname lookups, so frequent polling doesn't repeatedly resolve the same IPs.
- **Health check** (`app/health/check.py`) — a standalone script (`python -m app.health.check`) used as the Docker `HEALTHCHECK`; it verifies data is actually flowing rather than merely that the process exists.

## Device discovery

There are two ways devices enter the registry, and they can be used together.

### Broadcast auto-discovery

When `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY` is enabled, the collector sends UDP broadcast packets on port 9999 and listens for device replies. This is TP-Link's proprietary discovery protocol (not mDNS) and requires bidirectional UDP, which is why the container runs with **host networking**. Discovery only reaches the collector's own subnet. Credentials, if configured, are included in the discovery packets so that devices requiring them can respond.

An initial discovery runs once at startup; a separate periodic task re-runs it on `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL` to pick up newly added devices. Newly seen devices are authenticated concurrently. Devices that disappear from a sweep can optionally be pruned (`KASA_COLLECTOR_KEEP_MISSING_DEVICES`), but manual hosts are never pruned — they legitimately won't appear in a broadcast result.

### Manual hosts and cross-subnet

For devices broadcast can't reach — different VLANs or subnets — list them explicitly in `KASA_COLLECTOR_DEVICE_HOSTS` (comma-separated IPs or hostnames). Manual devices are initialized in parallel at startup and connect directly. Rather than broadcasting, they use `discover_single()`, which reaches a single host over TCP and correctly detects its device type and protocol (IOT vs SMART) even on a different subnet. This makes manual configuration the reliable path for segmented networks, and it needs only one-way (collector → device) reachability.

## Authentication

Older **IOT** devices (IotPlug, IotStrip, and similar) need no credentials — once discovered they're ready after a state update. Newer **SMART/KLAP** devices require TP-Link cloud credentials, supplied via `KASA_COLLECTOR_TPLINK_USERNAME` and `KASA_COLLECTOR_TPLINK_PASSWORD`.

The device manager authenticates with layered fallbacks and retries. It first tries the object returned by discovery; if that fails it opens a fresh connection with credentials (with a timeout and bounded retries using exponential backoff); and as a last resort it tries connecting without credentials, since some devices need none. Credential-specific failures ("challenge", "authentication") short-circuit the retries and surface a clear message telling you to set the TP-Link variables. A device's emeter capability is determined right after it connects, which is what routes it into the polling set.

## The poll cycle and what gets written

The poller runs two loops, each collecting from all emeter-capable devices concurrently with a `TaskGroup`. Each loop measures its own duration, warns when a cycle approaches or exceeds its interval, then sleeps for the remaining time so cadence stays steady. A single unreachable device can't abort a cycle: per-device failures are retried, then counted and swallowed so siblings still complete.

- **Energy loop** — every `KASA_COLLECTOR_DATA_FETCH_INTERVAL` (default 15s). Updates each device and reads its energy meter.
- **System-info loop** — every `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL` (default 60s). Reads model, firmware, state, wifi signal, and (for strips) child metadata.

Readings become InfluxDB points across these measurements:

- **`emeter`** — energy metrics (power, current, voltage, totals), one point per metric. Every point is tagged with `ip`, `dns_name`, `device_alias`, and `equipment_type`; `device_id` is added when known.
- **Per-outlet strip points** — for a power strip (e.g. HS300), the parent aggregate is written to `emeter` tagged `equipment_type=device`, and each child outlet is written to `emeter` as its own point tagged `equipment_type=plug` with `plug_alias` and a numeric `plug_id`. Child `plug_id`/`plug_alias` enrichment is resolved from cached sysinfo, so per-outlet detail fills in once the sysinfo loop has run.
- **`sysinfo`** and **`sysinfo_child`** — per-device and per-plug system information. Sysinfo is also cached in memory so the energy loop can cross-reference child plugs on strips.
- **`collector_stats`** — the collector's own per-cycle health, tagged by `cycle` (`emeter`/`sysinfo`), with fields for devices attempted, succeeded, failed, and cycle duration. This lets you watch the collector itself in Grafana alongside device data.

Optionally, with `KASA_COLLECTOR_WRITE_TO_FILE` enabled, each cycle is also appended to `.jsonl` files in `KASA_COLLECTOR_OUTPUT_DIR` — useful for debugging and the basis of the file-freshness health check.

## Async design

The whole collector is `asyncio`-native. Discovery, authentication, and both poll loops fan out over devices with `TaskGroup`, so many devices are contacted in parallel rather than serially, and exception groups keep one device's failure from taking down the rest. Reverse DNS lookups go through the shared TTL cache (`KASA_COLLECTOR_DNS_CACHE_TTL`) so repeated polling stays cheap. InfluxDB writes are asynchronous too: each poll cycle hands its batch of points to the async write API in a single awaited request, and write errors are logged with actionable guidance (for example auth/bucket problems) without stopping collection — the next cycle simply retries.

## Graceful shutdown

Signal handlers for **SIGTERM** (from `docker stop` or a Kubernetes termination) and **SIGINT** (Ctrl-C) trigger an orderly shutdown; without them, SIGTERM to PID 1 would be dropped and buffered writes would never flush. On shutdown the orchestrator cancels the running tasks (bounded by `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`), closes the InfluxDB connection, and disconnects from every device concurrently, clearing all registries. The result is that connections are released cleanly and in-flight data is flushed on exit.

## Storage and networking recap

Metrics land in **InfluxDB 2.x**, which Grafana reads. The bundled dev/demo stacks provision InfluxDB with a v1 DBRP mapping (`ops/influxdb/init-dbrp.sh`) and a Grafana datasource in InfluxQL mode, because the dashboards are written in InfluxQL. If you point the collector at your own InfluxDB 2.x, you'll need to set up the equivalent DBRP mapping and datasource yourself — see [grafana-dashboards.md](grafana-dashboards.md). Because auto-discovery needs UDP broadcast, the container uses host networking; if that isn't possible, drive everything through `KASA_COLLECTOR_DEVICE_HOSTS` instead.

## Testing without hardware

You can exercise the full pipeline with no physical devices using the end-to-end harness (`make test-e2e`), which runs fake Kasa emulators (`harness/fake_kasa.py`, IOT protocol) against the collector and an ephemeral InfluxDB. See [docs/testing.md](testing.md).
