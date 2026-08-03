# Troubleshooting & FAQ

Solutions to the problems people actually hit, followed by a general FAQ. If something here isn't enough, enable debug logging (below) and open a [GitHub issue](https://github.com/luxardolabs/kasa-collector/issues).

See also: [configuration.md](configuration.md) for every environment variable, [grafana-dashboards.md](grafana-dashboards.md) for the dashboards, and [deployment.md](deployment.md) for stacks and deployment.

## Discovery problems

Kasa Collector finds devices two ways: **broadcast auto-discovery** and an explicit **manual host list**. Most "no devices" reports come down to how discovery interacts with your network.

### No devices discovered

If auto-discovery finds zero devices, check in order:

1. **Host networking.** Broadcast discovery only works with host networking, because the collector sends a UDP broadcast to `255.255.255.255:9999` and listens for replies. In Compose:

   ```yaml
   network_mode: host   # required for broadcast discovery
   ```

1. **Discovery is enabled.**

   ```bash
   KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=true
   ```

1. **Same subnet.** Broadcast discovery only reaches devices on the collector's own subnet. Devices on another VLAN/subnet won't answer the broadcast — use manual hosts instead (below).

1. **Fall back to manual hosts.** List device IPs explicitly:

   ```bash
   KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false
   KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100,192.168.1.101
   ```

### VLANs and cross-subnet devices

Auto-discovery relies on bidirectional UDP: the collector broadcasts, and each device unicasts a reply back. Asymmetric firewall rules silently break this:

- ✅ Server VLAN → IoT VLAN — the broadcast gets through.
- ❌ IoT VLAN → Server VLAN — the devices' replies are dropped, so discovery finds nothing.

This is TP-Link's proprietary protocol, **not mDNS**, so mDNS reflectors won't help. Options, best first:

1. **Manual hosts (recommended for segmented networks).** Set `KASA_COLLECTOR_DEVICE_HOSTS` to the device IPs and turn auto-discovery off. Manual hosts use `discover_single()`, which connects directly over TCP and detects the device's protocol (IOT vs SMART) even across subnets — no broadcast required, so only Server → IoT reachability is needed.
1. **A narrow firewall exception** allowing return UDP 9999 traffic from the IoT VLAN back to the collector's IP.
1. **Run the collector on the IoT VLAN** with the devices.

Manual hosts are also never pruned when a discovery sweep doesn't see them, so a cross-subnet device won't be dropped just because it's invisible to broadcast.

### Discovered but not connectable

A device answers UDP discovery but the TCP connection fails ("Connection reset by peer", "Connect call failed", "appears to be discovered but not connectable"). Usual causes:

- Device on a different VLAN, or a firewall between collector and device.
- Firewall blocking **TCP 9999** (IOT) or **TCP 80/443** (SMART).
- Device in a bad state.

Try:

- Power-cycle the device, and confirm it works in the Kasa app.
- Verify no firewall rule blocks the relevant TCP port.
- Pin the device with `KASA_COLLECTOR_DEVICE_HOSTS` so it connects directly instead of via broadcast.

### Ports used

- **UDP 9999** — broadcast discovery.
- **TCP 9999** — IOT device communication (legacy plugs/strips).
- **TCP 80/443** — SMART device communication (newer protocol devices).

## Authentication

### "Server response doesn't match our challenge"

The device requires TP-Link cloud credentials (SMART/KLAP protocol). Newer hardware — roughly 2021 firmware onward, e.g. KP125M, EP25, some HS103 units — needs them; older IOT devices don't. Set:

```bash
KASA_COLLECTOR_TPLINK_USERNAME=your-email@example.com
KASA_COLLECTOR_TPLINK_PASSWORD=your-password
```

The credentials are used both in discovery packets and on direct connects. If a device still won't authenticate after credentials are set, the collector logs a warning and, as a last resort, tries connecting without auth — so an occasional warning for a device that genuinely needs no credentials is harmless.

### InfluxDB authentication failed

The collector prints an actionable error and keeps retrying each cycle:

```
InfluxDB rejected the write (401 Unauthorized)
```

Verify these and that the token has **write** access to the bucket:

- `KASA_COLLECTOR_INFLUXDB_TOKEN`
- `KASA_COLLECTOR_INFLUXDB_ORG`
- `KASA_COLLECTOR_INFLUXDB_URL`
- `KASA_COLLECTOR_INFLUXDB_BUCKET`

## No data in InfluxDB / Grafana

Work from the collector outward.

1. **Is the collector writing?** `docker logs kasa-collector` should show discovery/authentication and periodic fetch cycles. Auth or connection errors here mean no data is being produced — fix those first (see above).

1. **Datasource shape (your own InfluxDB 2.x).** The bundled dashboards are written in **InfluxQL**, so an InfluxDB 2.x server needs a **v1 DBRP mapping** plus a Grafana datasource configured in **InfluxQL mode** (token-header auth). The bundled dev/demo stacks do this for you automatically (`ops/influxdb/init-dbrp.sh`, Grafana datasource uid `uDxwFcOGz`). If you point the collector at **your own** InfluxDB 2.x, you must create the DBRP mapping and configure the datasource yourself, or the dashboards will render empty even though data is landing. See [grafana-dashboards.md](grafana-dashboards.md).

1. **Query the right measurements.** Data is split across:

   - `emeter` — energy metrics (power, current, voltage, totals).
   - `sysinfo` — per-device system information.
   - `sysinfo_child` — per-plug system information for power strips.
   - `collector_stats` — the collector's own per-cycle health (devices attempted/succeeded/failed, duration), tagged by `cycle` (`emeter`/`sysinfo`).

### Per-outlet power strip data is missing

For strips like the HS300, each outlet is written to the `emeter` measurement as its own point:

- The **parent strip** aggregate is tagged `equipment_type=device`.
- Each **child outlet** is tagged `equipment_type=plug`, plus `plug_alias` and a numeric `plug_id`.

If per-outlet points are missing but the parent is present, make sure the **sysinfo** cycle has run at least once — child `plug_id`/`plug_alias` enrichment is resolved from cached sysinfo, so per-outlet detail fills in after the first sysinfo poll (default 60s).

## Performance and tuning

### InfluxDB growing fast

At defaults, each emeter device produces roughly 4 points every 15s (~240/min) plus ~1 sysinfo point/min — about 241 points/min/device, so ~3.5M points/day for 10 devices. To slow growth:

- Raise the intervals: `KASA_COLLECTOR_DATA_FETCH_INTERVAL`, `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL`.
- Add an InfluxDB retention policy and/or downsampling task.

### Fetch cycle warnings / slow collection

The poller warns when a cycle exceeds 80% of its interval and again if it overruns the interval entirely. If you see these, either raise the interval or reduce load (fewer devices per collector, or spread discovery out).

### Slow discovery

```bash
KASA_COLLECTOR_DISCOVERY_TIMEOUT=10   # wait longer for replies
KASA_COLLECTOR_DISCOVERY_PACKETS=1    # send fewer discovery packets
```

### High log volume

The collector logs device detail at INFO on the first discovery, then drops to DEBUG. To quiet it further:

```bash
KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=WARNING
KASA_COLLECTOR_LOG_LEVEL_KASA_API=WARNING
```

### DNS lookups

Hostname resolution is cached to keep frequent polling cheap. Tune or disable it:

```bash
KASA_COLLECTOR_DNS_CACHE_TTL=600   # default 300 seconds
KASA_COLLECTOR_DNS_CACHE_TTL=0     # disable caching (test only)
```

If hostnames appear wrong or stale, drop the TTL or disable caching temporarily to confirm DNS itself is healthy.

## Docker and health

### Container shows unhealthy

The health check (`python -m app.health.check`) reports healthy when data is flowing. Its behavior depends on file output:

- **`KASA_COLLECTOR_WRITE_TO_FILE=true`** — it checks that the newest `emeter_*.jsonl` in the output dir is non-empty and fresher than `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` (default 120s). This is the reliable signal.
- **File output disabled** — it falls back to a process-liveness check.

Inspect and tune:

```bash
docker inspect kasa-collector | jq '.[0].State.Health'
KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE=180   # default 120 seconds
```

If it's unhealthy with file output on, the collector isn't producing data — check the log for discovery/auth/InfluxDB errors.

### Timezone crash on device update ("ZoneInfoNotFoundError")

python-kasa resolves each device's timezone via `zoneinfo`, and TP-Link's timezone index uses **legacy POSIX names** like `PST8PDT`, `CST6CDT`, `EST5EDT`. Without those names, `device.update()` can raise `ZoneInfoNotFoundError` and crash the collection cycle. The runtime image ships **both `tzdata` and `tzdata-legacy`**, so this is fixed out of the box. If you hit it, you're on an old or custom image that stripped `tzdata-legacy` — pull a current `ghcr.io/luxardolabs/kasa-collector`.

### Connection cleanup / transport leaks

Long-running deployments seeing transport churn can extend the cleanup windows:

```bash
KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT=10   # default 5 seconds
KASA_COLLECTOR_SHUTDOWN_TIMEOUT=15            # default 10 seconds
```

### "malformed JSON, retrying"

The device returned invalid data; the collector retries automatically. If it persists, power-cycle the device or update its firmware.

## Testing

### Run without any hardware

```bash
make test-e2e
```

This builds the image and brings up fake Kasa emulators (`harness/fake_kasa.py`, speaking the real IOT protocol) plus an ephemeral InfluxDB on a bridge network, then asserts emeter data lands in the `emeter` measurement before tearing everything down. No hardware and no published ports, so it's CI-safe. The harness covers emeter plugs (HS110/KP115), a non-emeter plug (HS103), and a 6-outlet strip (HS300). See [Testing](testing.md).

### See it work interactively

- `make demo-up` — fake emulated devices + bundled InfluxDB + Grafana (no hardware); dashboards populate immediately.
- `make dev-up` — the same bundled stack against **your real** devices.

Both serve Grafana at http://localhost:3000 (admin/admin). Stop with `make demo-down` / `make dev-down`. Run `make help` for the full command list.

For unit tests and linting: `make test`, `make lint`, `make check`.

## Debugging tips

- **Follow logs:** `docker logs -f kasa-collector`
- **Turn on debug:** `KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG`
- **Write raw data to disk:** `KASA_COLLECTOR_WRITE_TO_FILE=true` and `KASA_COLLECTOR_OUTPUT_DIR=/app/output` — inspect device detail in the `.jsonl` files.
- **Isolate one device:** `KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100` with `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false`.
- **Shell into the container:** `make dev-shell`

______________________________________________________________________

## FAQ

**Does the collector need to be on the same network/VLAN as my devices?** For **auto-discovery**, yes — it depends on UDP broadcast reaching devices and their replies coming back. For **manual hosts** (`KASA_COLLECTOR_DEVICE_HOSTS`), no: those connect directly over TCP via `discover_single()` and work across subnets with routing, no broadcast needed.

**Can I run without auto-discovery?** Yes, and it's often preferable on segmented networks. Set `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false` and list IPs in `KASA_COLLECTOR_DEVICE_HOSTS`. Since 2025.7.0, manual hosts use `discover_single()` for correct cross-subnet protocol detection.

**Why does the container need `network_mode: host`?** Only for UDP broadcast discovery. If you use manual hosts exclusively, bridge networking with the right routing can work.

**Which devices need credentials?** Newer SMART/KLAP devices (roughly 2021 firmware onward). Older IOT devices work without any. When in doubt, set `KASA_COLLECTOR_TPLINK_USERNAME`/`_PASSWORD` — they're ignored by devices that don't need them.

**How often does it poll?** Energy data every 15s (`KASA_COLLECTOR_DATA_FETCH_INTERVAL`), system info every 60s (`KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL`).

**Are all Kasa devices supported?** Most smart plugs and power strips, especially those with energy monitoring. Devices without an energy meter still report system info but naturally have no `emeter` data.

**How do I check the collector is healthy?**

```bash
docker inspect kasa-collector | jq '.[0].State.Health'
```

It reports unhealthy if data goes stale past `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` (default 120s) when file output is enabled.

## Getting help

If it still isn't working:

1. Search or open a [GitHub issue](https://github.com/luxardolabs/kasa-collector/issues).
1. Enable debug logging and capture the relevant lines.
1. Include your device models/firmware, network layout (VLANs, subnets), and configuration with secrets redacted.
