# Configuration

Kasa Collector is configured entirely through environment variables. Collector settings use the `KASA_COLLECTOR_*` prefix. The exceptions are `TZ`, the standard container timezone variable (see [Timezone](#timezone)), and the fleet logging variables `LOG_FORMAT`, `LOG_LEVEL` and `LOG_MODULE_LEVELS` (see [Logging](#logging)).

Configuration is read once at startup. There is no config file to edit — set the variables in your `docker run` command, Compose `environment:` block, or an `.env` file. See [Getting Started](getting-started.md) to stand up the stack, and [Troubleshooting](troubleshooting.md) if the collector will not start or finds no devices.

## How values are validated

There are two classes of settings, and they fail very differently:

- **Required settings** — the four InfluxDB variables. If any is missing, the collector logs the missing names and exits immediately at startup. There are no defaults; the collector cannot run without a place to write data.
- **Everything else** — optional. A missing value uses its default. A value that does not parse, or an integer below its documented minimum, **logs a warning and falls back to the documented default** rather than crashing, so a single misconfigured knob never takes the whole collector down. Path settings (`KASA_COLLECTOR_OUTPUT_DIR`, `KASA_COLLECTOR_HEARTBEAT_FILE`) are used as given.

Booleans accept `true/false`, `1/0`, `yes/no`, and `on/off` (case-insensitive). An integer below its minimum is replaced by the default, not by the minimum (so `KASA_COLLECTOR_DATA_FETCH_INTERVAL=0` runs at `15`). Two settings are adjusted against others: `KASA_COLLECTOR_DISCOVERY_CATCH_UP_DELAY` is capped at the discovery interval, and `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` is raised to twice the fetch interval.

## InfluxDB (required)

The collector exits at startup if any of these are unset.

| Variable                         | Default      | Description                                                |
| -------------------------------- | ------------ | ---------------------------------------------------------- |
| `KASA_COLLECTOR_INFLUXDB_URL`    | _(required)_ | URL of the InfluxDB instance, e.g. `http://influxdb:8086`. |
| `KASA_COLLECTOR_INFLUXDB_TOKEN`  | _(required)_ | InfluxDB API token with write access to the bucket.        |
| `KASA_COLLECTOR_INFLUXDB_ORG`    | _(required)_ | InfluxDB organization name.                                |
| `KASA_COLLECTOR_INFLUXDB_BUCKET` | _(required)_ | Target bucket for time-series data, e.g. `kasa`.           |

Each cycle writes one awaited request per device (a power strip's points go together, so a strip lands whole), plus one `collector_stats` point for the cycle. Nothing is buffered between cycles, so there is no batch-size or flush-interval setting to tune. A write the server refuses is logged and counted as `write_failed`; that cycle's points are not resent.

## Discovery

| Variable                                   | Default   | Description                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY`     | `True`    | Broadcast-discover devices on the local network. When `False`, only devices listed in `KASA_COLLECTOR_DEVICE_HOSTS` are monitored.                                                                                                                                                                                                  |
| `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL` | `300`     | Seconds between discovery scans (minimum `1`).                                                                                                                                                                                                                                                                                      |
| `KASA_COLLECTOR_DISCOVERY_TIMEOUT`         | `5`       | Seconds to wait for device responses during a scan (minimum `1`).                                                                                                                                                                                                                                                                   |
| `KASA_COLLECTOR_DISCOVERY_PACKETS`         | `3`       | Discovery packets sent per scan; more packets improve reliability on lossy networks (minimum `1`).                                                                                                                                                                                                                                  |
| `KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD`  | `3`       | Consecutive missed discovery rounds before a discovered device stops being polled (minimum `1`). Applies only with `KASA_COLLECTOR_KEEP_MISSING_DEVICES=False`, and never to a device that answered a poll within the last discovery interval. Discovery is a lossy UDP broadcast, so a healthy device can miss a round.            |
| `KASA_COLLECTOR_DISCOVERY_CATCH_UP_DELAY`  | `30`      | Seconds before the first re-discovery pass after startup (minimum `1`, capped at the discovery interval). A device that misses the single startup broadcast would otherwise wait a full interval to be collected.                                                                                                                   |
| `KASA_COLLECTOR_KEEP_MISSING_DEVICES`      | `True`    | Keep polling known devices when they stop answering discovery. When `False`, a device that misses `KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD` rounds and has not answered a poll within one discovery interval stops being polled; its address is still probed directly each discovery round, and collection resumes when it answers. |
| `KASA_COLLECTOR_DEVICE_HOSTS`              | _(unset)_ | Comma-separated IPs or hostnames for manual/cross-subnet devices, e.g. `192.168.1.100,kasa-plug.local`. Used in addition to (or instead of) auto-discovery. Each discovery round retries a host that has not connected yet and re-resolves a hostname, so a device the router moves is followed to its new address.                 |

Broadcast discovery (UDP 9999 for IOT devices, 20002 and 20004 for SMART/KLAP devices) only reaches the local subnet, so devices on other VLANs/subnets must be listed explicitly in `KASA_COLLECTOR_DEVICE_HOSTS`. Host networking is required for broadcast discovery to reach your LAN.

Every address the collector has collected from is kept in `known_devices.json` in the output directory, written whether or not file output is on, and probed directly on each discovery round, across restarts. A device that stops answering broadcasts keeps being collected.

## Data collection and polling

| Variable                                | Default | Description                                                                                                                                                           |
| --------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_DATA_FETCH_INTERVAL`    | `15`    | Seconds between energy-meter (power/voltage/current) reads (minimum `1`).                                                                                             |
| `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL` | `60`    | Seconds between system-information reads (minimum `1`).                                                                                                               |
| `KASA_COLLECTOR_FETCH_MAX_RETRIES`      | `5`     | Total attempts for a read that fails with a network error, before giving up for the cycle (minimum `1`). Other errors are not retried.                                |
| `KASA_COLLECTOR_FETCH_RETRY_DELAY`      | `1`     | Base delay in seconds: retry _n_ waits `FETCH_RETRY_DELAY × 2^n` seconds (2, 4, 8, …), capped at `KASA_COLLECTOR_MAX_RETRY_DELAY` (minimum `1`).                      |
| `KASA_COLLECTOR_MAX_RETRY_DELAY`        | `60`    | Ceiling in seconds on the exponential backoff delay (minimum `1`), including the delay between InfluxDB connection attempts at startup, which wait up to 60 s in all. |

Each device's read, retries included, must finish within 80% of its poll interval, and its writes get a budget of the same size, so one slow or unreachable device never stretches the other devices' sampling interval.

## Authentication (TP-Link)

IOT-protocol devices on the legacy XOR transport (most older plugs and strips) need no credentials. SMART devices, and IOT devices on KLAP firmware (an HS300 on firmware 1.1.2, for example), require your TP-Link cloud account. See [Supported Devices](supported-devices.md) for which family your hardware belongs to.

| Variable                                  | Default   | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_TPLINK_USERNAME`          | _(unset)_ | TP-Link account email, required for SMART/KLAP devices.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `KASA_COLLECTOR_TPLINK_PASSWORD`          | _(unset)_ | TP-Link account password, required for SMART/KLAP devices.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `KASA_COLLECTOR_AUTH_MAX_RETRIES`         | `3`       | Retry attempts for device authentication (minimum `1`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `KASA_COLLECTOR_AUTH_TIMEOUT`             | `10`      | Seconds to wait for an authentication attempt (minimum `1`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES` | `True`    | Hand the credentials to **any** device that answers broadcast discovery. Default `True`: if you enabled auto-discovery, discovered SMART/KLAP devices are authenticated and collected, the same as IOT devices. Set `False` to harden on a network you don't fully trust: credentials then go only to a device you listed in `KASA_COLLECTOR_DEVICE_HOSTS` (by IP or hostname), and a new, unlisted SMART/KLAP device is left unauthenticated with a one-time log line until you list it. Either way, an unlisted device whose discovery reply asks for an AES login gets no credentials: every AES login hands the device something it could log in with (the password itself, or an unsalted hash your own AES devices accept). |

Credentials are masked in every log line, the startup configuration dump included, and never sent in the discovery broadcast, regardless of the trust setting. By default discovered SMART/KLAP devices are authenticated with your TP-Link account, so auto-discovery collects them without a manual list. On a network you don't fully trust, set `KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES=False`: credentials are then withheld from any device not in `KASA_COLLECTOR_DEVICE_HOSTS`, so a rogue device impersonating Kasa cannot be handed your TP-Link account by answering discovery — at the cost of having to list each SMART/KLAP device yourself. IOT devices need no credentials and are collected on discovery either way. Even with the default `True`, an unlisted device is never logged in to over an AES login, which the device itself advertises: login version 1 sends your password, version 2 an unsalted hash of it that your own AES devices accept as the password, and SMART cameras an unsalted md5 of it. Such a device is logged once and left uncollected; list it in `KASA_COLLECTOR_DEVICE_HOSTS` if it is yours. KLAP devices, which get only a hash bound to random seeds, are collected under the default.

## Operational timeouts

| Variable                                   | Default | Description                                                                                                                                         |
| ------------------------------------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT` | `5`     | Seconds allowed for each device's disconnect, at shutdown and when a device is replaced; a disconnect that takes longer is abandoned (minimum `1`). |
| `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`          | `10`    | Seconds to wait for in-flight tasks to finish during graceful shutdown (minimum `1`).                                                               |
| `KASA_COLLECTOR_DNS_CACHE_TTL`             | `300`   | Seconds to cache hostname lookups; set `0` to disable caching (minimum `0`).                                                                        |

## Logging

| Variable                                    | Default | Description                                                                                                             |
| ------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR`   | `INFO`  | Level for the main orchestrator. One of `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`.                                |
| `KASA_COLLECTOR_LOG_LEVEL_KASA_API`         | `INFO`  | Level for device communication. Set `DEBUG` to trace per-device protocol activity.                                      |
| `KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE` | `INFO`  | Level for InfluxDB writes. Set `DEBUG` to trace storage operations.                                                     |
| `LOG_FORMAT`                                | `json`  | `json`: one JSON object per line on stdout (the fleet log contract). `text`: a readable line for local runs.            |
| `LOG_LEVEL`                                 | `INFO`  | Root level, for every logger the three settings above do not name (e.g. `python-kasa` stays at `WARNING`).              |
| `LOG_MODULE_LEVELS`                         | —       | JSON object of per-logger levels applied on top, e.g. `{"KasaAPI": "DEBUG"}`, to turn one logger up without a redeploy. |

Each JSON line carries `timestamp`, `level`, `logger`, `message`, `service` (`kasa-collector`), `version`, the code location, and any `extra=` fields under `attributes`. `KASA_COLLECTOR_STRUCTURED_LOGS` is gone: JSON is always on once the collector starts. A warning about an invalid setting is raised while settings load, before logging is configured, so it prints as a plain line.

The deployed and demo compose services cap each container's own log on the node: Docker's `json-file` driver, at most 5 files of 10 MB. Set `LOG_DRIVER` in the env file to keep a host's own logging driver (for example `loki`), and `LOG_MAX_SIZE` / `LOG_MAX_FILE` to change the caps.

## Output

| Variable                       | Default  | Description                                                                                                                                                                                                                                                                                     |
| ------------------------------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_WRITE_TO_FILE` | `False`  | Also write each poll's data to newline-delimited JSON (`.jsonl`) files. Primarily for debugging.                                                                                                                                                                                                |
| `KASA_COLLECTOR_OUTPUT_DIR`    | `output` | Directory, inside the container, for `known_devices.json` and the `.jsonl` files (`/app/output` from the working directory `/app`). The collector runs as uid 1000, which can write only `/app/output`, `/tmp` and its home directory, so a different path must be a mount that user can write. |

The compose stacks mount `/app/output` from a named volume, `kasa_collector_output`, by default. To keep the files on the host instead, set `OUTPUT_DIR` in the env file to a directory owned by uid 1000, created before the first start (`sudo install -d -o 1000 -g 1000 <path>`): a path Docker creates for you is owned by root, and the collector then cannot write to it.

## Health check

| Variable                              | Default                         | Description                                                                                                                                                                                                                                                   |
| ------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` | `120`                           | Seconds since the last successful collection before the Docker health check reports unhealthy. Never less than twice `KASA_COLLECTOR_DATA_FETCH_INTERVAL`: a lower value is raised to that, with a warning, and the default rises with a long fetch interval. |
| `KASA_COLLECTOR_HEARTBEAT_FILE`       | `/tmp/kasa-collector.heartbeat` | Where the collector records each cycle that stored data, for the health check. Keep it inside the container, never on the output mount, and under `/tmp`, which the collector's user can write.                                                               |

The health check runs as `python -m app.health.check` and needs no web server. It is healthy only on a fresh heartbeat written by the container's current process, whether or not file output is on.

## Timezone

| Variable | Default                    | Description                                                                                                                                                     |
| -------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TZ`     | _(container default, UTC)_ | Standard container timezone, e.g. `America/Chicago`. Affects `LOG_FORMAT=text` timestamps and the displayed next-run times; JSON log timestamps are always UTC. |

`TZ` is not a `KASA_COLLECTOR_*` setting — it is the conventional Docker timezone variable, and it is separate from device timezones. python-kasa resolves each device's own timezone via `zoneinfo`, and TP-Link's timezone index uses legacy POSIX names such as `PST8PDT` and `CST6CDT`. The runtime image therefore installs both `tzdata` and `tzdata-legacy`; without the legacy database those names are unresolvable and a device `update()` can crash.

## Example

```bash
# Required
KASA_COLLECTOR_INFLUXDB_URL=http://influxdb:8086
KASA_COLLECTOR_INFLUXDB_TOKEN=your-influxdb-token
KASA_COLLECTOR_INFLUXDB_ORG=your-org
KASA_COLLECTOR_INFLUXDB_BUCKET=kasa

# Only for newer SMART/KLAP devices
KASA_COLLECTOR_TPLINK_USERNAME=you@example.com
KASA_COLLECTOR_TPLINK_PASSWORD=your-tplink-password

# A few common overrides (defaults shown)
KASA_COLLECTOR_DATA_FETCH_INTERVAL=15
KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL=60
KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=INFO
TZ=America/Chicago
```

See [Getting Started](getting-started.md) for a full walkthrough and [Troubleshooting](troubleshooting.md) for common issues.
