# Troubleshooting & FAQ

Solutions to the problems people actually hit, followed by a general FAQ. If something here isn't enough, enable debug logging (below) and open a [GitHub issue](https://github.com/luxardolabs/kasa-collector/issues).

See also: [configuration.md](configuration.md) for every environment variable, [grafana-dashboards.md](grafana-dashboards.md) for the dashboards, and [deployment.md](deployment.md) for stacks and deployment.

## Discovery problems

Kasa Collector finds devices two ways: **broadcast auto-discovery** and an explicit **manual host list**. Most "no devices" reports come down to how discovery interacts with your network.

### No devices discovered

If auto-discovery finds zero devices, check in order:

1. **Host networking.** Broadcast discovery only works with host networking, because the collector sends UDP broadcasts to `255.255.255.255` on ports 9999 (IOT), 20002 and 20004 (SMART/KLAP) and listens for replies. In Compose:

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

1. **Manual hosts (recommended for segmented networks).** Set `KASA_COLLECTOR_DEVICE_HOSTS` to the device IPs and turn auto-discovery off. Manual hosts use `discover_single()`, a unicast UDP query to that host that detects the device's protocol (IOT vs SMART), falling back to a direct connection. No broadcast is required, so it works across subnets as long as the device's unicast reply is routed back to the collector.
1. **A narrow firewall exception** allowing return UDP 9999, 20002 and 20004 traffic from the IoT VLAN back to the collector's IP.
1. **Run the collector on the IoT VLAN** with the devices.

Manual hosts are also never pruned when a discovery sweep doesn't see them, so a cross-subnet device won't be dropped just because it's invisible to broadcast. Each discovery round retries a manual host that has not connected yet and re-resolves a hostname.

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

- **UDP 9999** — broadcast discovery of IOT devices.
- **UDP 20002, 20004** — broadcast discovery of SMART/KLAP devices.
- **TCP 9999** — IOT device communication (legacy plugs/strips).
- **TCP 80/443** — SMART device communication (newer protocol devices).

## Authentication

### "Device response did not match our challenge"

The device requires TP-Link cloud credentials (SMART/KLAP protocol), and the collector logs `Device <ip> requires TP-Link cloud credentials. Please set KASA_COLLECTOR_TPLINK_USERNAME and KASA_COLLECTOR_TPLINK_PASSWORD.` Newer hardware — roughly 2021 firmware onward, e.g. KP125M, EP25, some HS103 units, and an HS300 on firmware 1.1.2 — needs them; older IOT devices don't. Set:

```bash
KASA_COLLECTOR_TPLINK_USERNAME=your-email@example.com
KASA_COLLECTOR_TPLINK_PASSWORD=your-password
```

The credentials are never sent in the discovery broadcast; they are used only on the direct connect to each device. If a device still won't authenticate after credentials are set, the collector logs a warning and, as a last resort, tries connecting without auth — so an occasional warning for a device that genuinely needs no credentials is harmless.

### "Discovered device … needs TP-Link credentials but is not trusted"

With `KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES=False`, a SMART/KLAP device found by broadcast gets no credentials unless it is listed in `KASA_COLLECTOR_DEVICE_HOSTS`, and the collector logs this once per device. Add the device's address or hostname to `KASA_COLLECTOR_DEVICE_HOSTS` to collect from it. Under either setting, an unlisted device that asks for an AES login is never given credentials; list it if it is yours (see [configuration.md](configuration.md#authentication-tp-link)).

### "InfluxDB Connection Failed" at startup

At startup the collector waits up to 60 seconds for InfluxDB to answer, logging `InfluxDB at <url> is not answering yet (…); retrying in Ns` between attempts. The delay doubles from 1 s, capped by `KASA_COLLECTOR_MAX_RETRY_DELAY`. That covers an InfluxDB started at the same moment, as the bundled stacks do. If it is still unreachable after that, the collector logs `InfluxDB Connection Failed` with the URL and exits, so the container restarts and tries again. Check that `KASA_COLLECTOR_INFLUXDB_URL` names a host and port this container can reach: the real-device collector runs on the host's network, so a compose service name does not resolve, and the dev stack's InfluxDB is at its fixed address.

### InfluxDB authentication failed

The collector prints an actionable error and keeps retrying each cycle:

```
InfluxDB rejected the write (401 Unauthorized) — check that KASA_COLLECTOR_INFLUXDB_TOKEN has write access to bucket '<bucket>' in org '<org>'.
InfluxDB write failed (404 Not Found) — bucket '<bucket>' or org '<org>' does not exist.
```

Verify these and that the token has **write** access to the bucket:

- `KASA_COLLECTOR_INFLUXDB_TOKEN`
- `KASA_COLLECTOR_INFLUXDB_ORG`
- `KASA_COLLECTOR_INFLUXDB_URL`
- `KASA_COLLECTOR_INFLUXDB_BUCKET`

## No data in InfluxDB / Grafana

Work from the collector outward.

1. **Is the collector writing?** `docker logs kasa-collector` should show discovery/authentication and periodic fetch cycles. Auth or connection errors here mean no data is being produced — fix those first (see above).

1. **Datasource shape (your own InfluxDB 2.x).** The bundled dashboards are written in **InfluxQL**, so an InfluxDB 2.x server needs a **v1 DBRP mapping** plus a Grafana datasource configured in **InfluxQL mode**, signing in with a read-only v1 user. The bundled dev, local and demo stacks do this for you automatically (`ops/influxdb/init-dbrp.sh`, Grafana datasource uid `uDxwFcOGz`). If you point the collector at **your own** InfluxDB 2.x, you must create the DBRP mapping and configure the datasource yourself, or the dashboards will render empty even though data is landing. See [grafana-dashboards.md](grafana-dashboards.md).

1. **Query the right measurements.** Data is split across:

   - `emeter` — energy metrics (power, current, voltage, totals).
   - `sysinfo` — per-device system information.
   - `sysinfo_child` — per-plug system information for power strips.
   - `collector_stats` — the collector's own per-cycle health (`devices`, `succeeded`, `failed`, `write_failed`, `duration_seconds`), tagged by `cycle` (`emeter`/`sysinfo`).

### Per-outlet power strip data is missing

For strips like the HS300 (IOT) and the P316M (SMART), each outlet is written to the `emeter` measurement as its own point:

- The **parent strip** aggregate is tagged `equipment_type=device`.
- Each **child outlet** is tagged `equipment_type=plug`, plus `plug_alias` and a numeric `plug_id`.

Each outlet's `plug_id` is its position on the strip, read off the strip as it is polled. If outlet points are missing, check the collector log for the strip's emeter fetch. On an IOT strip (HS300), an outlet that does not answer leaves the whole strip unwritten for that cycle, so it is never written in part. On a SMART strip (P316M), only that outlet is left out and the other outlets are written.

## Performance and tuning

### InfluxDB growing fast

At defaults an IOT emeter plug writes 4 points every 15 s (16/min) plus 1 sysinfo point a minute, about 17 points/min/device, or roughly 245,000 points a day for 10 devices. SMART devices add their today/month counters, and each strip outlet is its own set of points. To slow growth:

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

### Dashboards are empty after upgrading a bundled stack

The bundled Grafana signs in to InfluxDB as a read-only user `grafana`, never with the InfluxDB operator token. InfluxDB creates that user on its first start, from `GRAFANA_INFLUX_PASSWORD`, so a stack whose InfluxDB was first started by an earlier release does not have it. Grafana then starts, but every panel is empty. Collection is unaffected. Once per stack:

1. Add `GRAFANA_INFLUX_PASSWORD=` to its env file (`.env.local`, or `.env.dev`), with a password of 8 to 72 characters.

1. Restart the stack (`make local-up`, `make demo-up` or `make dev-up`), so InfluxDB and Grafana both get the password.

1. Create the user on that stack's InfluxDB (`kasa_local_influxdb` for local and demo, `kasa_influxdb` for dev). The password is read from the container's environment, so nothing is typed in:

   ```sh
   docker exec kasa_local_influxdb sh -c 'influx v1 auth create --org "$DOCKER_INFLUXDB_INIT_ORG" --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" --username grafana --password="$GRAFANA_INFLUX_PASSWORD" --read-bucket "$(influx bucket list --org "$DOCKER_INFLUXDB_INIT_ORG" --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" --name "$DOCKER_INFLUXDB_INIT_BUCKET" --hide-headers | cut -f1)"'
   ```

1. Open a dashboard: it shows data.

A stack started fresh creates the user itself; if InfluxDB's log shows `init-dbrp: ERROR: could not create read-only user 'grafana'`, the password was outside 8 to 72 characters: fix it and run step 3.

### `influx` CLI inside the bundled InfluxDB asks for an org or token

Since 2026.10.1 the bundled InfluxDB (`kasa_local_influxdb` in the local and demo stacks, `kasa_influxdb` in the dev stack) keeps `/etc/influxdb2` (the CLI's stored config) on its own named volume. On a stack that existed before, the first start mounts it empty: your data is untouched, but `docker exec kasa_local_influxdb influx …` no longer finds the token and org that setup stored. Pass them explicitly (`--org "$INFLUX_ORG" --token "$INFLUX_TOKEN"`), or recreate the CLI config once with `influx config create`.

### `make local-up`: "port is already allocated", or Grafana comes up empty

The stack for your machine is `make local-up`, with containers `kasa_local_influxdb` and `kasa_local_grafana` and volumes of their own; `make dev-up` drives the maintainers' dev host. If containers named `kasa_influxdb` and `kasa_grafana` run on your machine, they are a bundled stack started by `make dev-up` from an earlier checkout, and they hold ports 3000 and 8086. Stop it with plain compose, which keeps its data volumes:

```bash
docker compose --env-file .env.dev --profile collector --profile bundled down
```

To carry its history into the local stack, copy each volume once, before the first `make local-up`:

```bash
for v in influxdb_data influxdb_config grafana_data; do
  docker volume create --label com.docker.compose.project=kasa-collector \
    --label com.docker.compose.volume="kasa_local_$v" "kasa-collector_kasa_local_$v"
  docker run --rm -v "kasa-collector_kasa_$v:/from:ro" -v "kasa-collector_kasa_local_$v:/to" \
    alpine cp -a /from/. /to/
done
```

The volume names assume the default compose project, `kasa-collector`. If your env file sets `COMPOSE_PROJECT_NAME`, use that prefix instead (`docker volume ls | grep kasa` lists them).

The copied data keeps the credentials it was created with: InfluxDB and Grafana read `INFLUX_*` and `GRAFANA_PASSWORD` only when they create their database. So build `.env.local` from your old `.env.dev`, not from a fresh template: keep its `INFLUX_USER`, `INFLUX_PASSWORD`, `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_TOKEN`, `GRAFANA_PASSWORD`, `GRAFANA_INFLUX_PASSWORD` and `KASA_COLLECTOR_INFLUXDB_ORG` / `_BUCKET` / `_TOKEN`, set `ENV_FILE=.env.local` and `KASA_COLLECTOR_INFLUXDB_URL=http://localhost:8086`, and leave `COMPOSE_PROFILES` as it is (`make local-up` names its own).

### Container shows unhealthy

The health check (`python -m app.health.check`) reports healthy only while **this run** of the collector is storing data. After every energy-poll cycle that stores at least one device's reading, the collector writes a heartbeat inside the container (`/tmp/kasa-collector.heartbeat`). The check needs that heartbeat to be younger than `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` (default 120s, and never less than two fetch intervals) and written by the container's current process (judged by the kernel's process start times and boot id, so a wall-clock step does not affect it), so a restarted container can't inherit its predecessor's verdict. File output on or off makes no difference.

Inspect and tune:

```bash
docker inspect kasa-collector | jq '.[0].State.Health'
KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE=180   # default 120 seconds
```

If it's unhealthy, no device's reading has been stored for that long: check the log for discovery, authentication or InfluxDB errors. The health output says which case it is: no heartbeat yet, a stale one, or one left by a previous run.

### Timezone crash on device update ("ZoneInfoNotFoundError")

python-kasa resolves each device's timezone via `zoneinfo`, and TP-Link's timezone index uses **legacy POSIX names** like `PST8PDT`, `CST6CDT`, `EST5EDT`. Without those names, `device.update()` can raise `ZoneInfoNotFoundError` and crash the collection cycle. The runtime image ships **both `tzdata` and `tzdata-legacy`**, so this is fixed out of the box. If you hit it, you're on an old or custom image that stripped `tzdata-legacy` — pull a current `ghcr.io/luxardolabs/kasa-collector`.

### Connection cleanup / transport leaks

Each device's disconnect, at shutdown and when a device is replaced, gets `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT` seconds before it is abandoned; the whole shutdown gets `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`. A slow network can extend both:

```bash
KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT=10   # default 5 seconds
KASA_COLLECTOR_SHUTDOWN_TIMEOUT=15            # default 10 seconds
```

### A device returns readings that cannot be stored

A malformed reply is not retried within the cycle: the device counts as `failed` in `collector_stats` and is read again on the next cycle. Only network errors are retried. If it persists, power-cycle the device or update its firmware.

## Testing

### Run without any hardware

```bash
make test-e2e
```

This builds the image and brings up fake Kasa emulators (`harness/fake_kasa.py` for IOT, `harness/fake_smart.py` for SMART/KLAP) plus an ephemeral InfluxDB on a bridge network, then asserts emeter data lands in the `emeter` measurement before tearing everything down. No hardware and no published ports, so it's CI-safe. The harness covers HS110/KP115 emeter plugs, a non-emeter HS103, a 6-outlet HS300, a plug that goes deaf to discovery, a 2-outlet strip whose outlets share a name, a legacy-units plug, a SMART P316M strip and an HS300 behind KLAP. See [Testing](testing.md).

### See it work interactively

- `make demo-up` — fake emulated devices + bundled InfluxDB + Grafana (no hardware); dashboards populate immediately.
- `make local-up` — the same bundled stack against **your real** devices.

Both serve Grafana at http://localhost:3000 (`admin`, with `admin` for the demo or your `GRAFANA_PASSWORD` for the local stack). Stop with `make demo-down` / `make local-down`. Run `make help` for the full command list.

For unit tests and linting: `make test`, `make lint`, `make check`.

## Debugging tips

- **Follow logs:** `docker logs -f kasa-collector`
- **Turn on debug:** `KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG`, with `LOG_FORMAT=text` for readable lines instead of JSON
- **Write raw data to disk:** `KASA_COLLECTOR_WRITE_TO_FILE=true` and `KASA_COLLECTOR_OUTPUT_DIR=/app/output` — inspect device detail in the `.jsonl` files.
- **Isolate one device:** `KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100` with `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false`.
- **Shell into the container:** `make shell` (the collector-only stack) or `docker exec -it kasa-collector /bin/bash`

______________________________________________________________________

## FAQ

**Does the collector need to be on the same network/VLAN as my devices?** For **auto-discovery**, yes — it depends on UDP broadcast reaching devices and their replies coming back. For **manual hosts** (`KASA_COLLECTOR_DEVICE_HOSTS`), no: those are queried directly by `discover_single()` and work across subnets with routing, no broadcast needed.

**Can I run without auto-discovery?** Yes, and it's often preferable on segmented networks. Set `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false` and list IPs in `KASA_COLLECTOR_DEVICE_HOSTS`. Manual hosts use `discover_single()`, which detects each device's protocol across subnets.

**Why does the container need `network_mode: host`?** Only for UDP broadcast discovery. If you use manual hosts exclusively, bridge networking with the right routing can work.

**Which devices need credentials?** Newer SMART/KLAP devices (roughly 2021 firmware onward). Older IOT devices work without any. When in doubt, set `KASA_COLLECTOR_TPLINK_USERNAME`/`_PASSWORD` — they're ignored by devices that don't need them.

**How often does it poll?** Energy data every 15s (`KASA_COLLECTOR_DATA_FETCH_INTERVAL`), system info every 60s (`KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL`).

**Are all Kasa devices supported?** Most smart plugs and power strips, especially those with energy monitoring. Devices without an energy meter are discovered and registered, but nothing is collected from them.

**How do I check the collector is healthy?**

```bash
docker inspect kasa-collector | jq '.[0].State.Health'
```

It reports unhealthy if no data has been stored within `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` (default 120s, never less than two `KASA_COLLECTOR_DATA_FETCH_INTERVAL`s), whether file output is on or off.

## Getting help

If it still isn't working:

1. Search or open a [GitHub issue](https://github.com/luxardolabs/kasa-collector/issues).
1. Enable debug logging and capture the relevant lines.
1. Include your device models/firmware, network layout (VLANs, subnets), and configuration with secrets redacted.
