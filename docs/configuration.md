# Configuration

Kasa Collector is configured entirely through environment variables. Every application setting uses the `KASA_COLLECTOR_*` prefix; the sole exception is `TZ`, the standard container timezone variable (see [Timezone](#timezone)).

Configuration is read once at startup. There is no config file to edit — set the variables in your `docker run` command, Compose `environment:` block, or an `.env` file. See [Getting Started](getting-started.md) to stand up the stack, and [Troubleshooting](troubleshooting.md) if the collector will not start or finds no devices.

## How values are validated

There are two classes of settings, and they fail very differently:

- **Required settings** — the four InfluxDB variables. If any is missing, the collector logs the missing names and exits immediately at startup. There are no defaults; the collector cannot run without a place to write data.
- **Everything else** — optional. Each optional value is parsed and bounds-checked. If a value is missing, unparseable, or out of range, the collector **logs a warning and falls back to the documented default** rather than crashing. A single misconfigured knob will never take the whole collector down.

Booleans accept `true/false`, `1/0`, `yes/no`, and `on/off` (case-insensitive). Integer settings are clamped to a minimum where noted; there are no maximum clamps.

## InfluxDB (required)

The collector exits at startup if any of these are unset.

| Variable                         | Default      | Description                                                |
| -------------------------------- | ------------ | ---------------------------------------------------------- |
| `KASA_COLLECTOR_INFLUXDB_URL`    | _(required)_ | URL of the InfluxDB instance, e.g. `http://influxdb:8086`. |
| `KASA_COLLECTOR_INFLUXDB_TOKEN`  | _(required)_ | InfluxDB API token with write access to the bucket.        |
| `KASA_COLLECTOR_INFLUXDB_ORG`    | _(required)_ | InfluxDB organization name.                                |
| `KASA_COLLECTOR_INFLUXDB_BUCKET` | _(required)_ | Target bucket for time-series data, e.g. `kasa`.           |

Writes are batched per poll cycle by the asyncio-native client — each cycle's points go out in a single awaited request — so there is no batch-size or flush-interval setting to tune.

## Discovery

| Variable                                   | Default   | Description                                                                                                                                                 |
| ------------------------------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY`     | `True`    | Broadcast-discover devices on the local network. When `False`, only devices listed in `KASA_COLLECTOR_DEVICE_HOSTS` are monitored.                          |
| `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL` | `300`     | Seconds between discovery scans (minimum `1`).                                                                                                              |
| `KASA_COLLECTOR_DISCOVERY_TIMEOUT`         | `5`       | Seconds to wait for device responses during a scan (minimum `1`).                                                                                           |
| `KASA_COLLECTOR_DISCOVERY_PACKETS`         | `3`       | Discovery packets sent per scan; more packets improve reliability on lossy networks (minimum `1`).                                                          |
| `KASA_COLLECTOR_KEEP_MISSING_DEVICES`      | `True`    | Keep known devices in memory when they stop responding to discovery. When `False`, unreachable devices are dropped.                                         |
| `KASA_COLLECTOR_DEVICE_HOSTS`              | _(unset)_ | Comma-separated IPs or hostnames for manual/cross-subnet devices, e.g. `192.168.1.100,kasa-plug.local`. Used in addition to (or instead of) auto-discovery. |

Broadcast discovery only reaches the local subnet, so devices on other VLANs/subnets must be listed explicitly in `KASA_COLLECTOR_DEVICE_HOSTS`. Host networking is required for broadcast discovery to work.

## Data collection and polling

| Variable                                | Default | Description                                                                                  |
| --------------------------------------- | ------- | -------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_DATA_FETCH_INTERVAL`    | `15`    | Seconds between energy-meter (power/voltage/current) reads (minimum `1`).                    |
| `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL` | `60`    | Seconds between system-information reads (minimum `1`).                                      |
| `KASA_COLLECTOR_FETCH_MAX_RETRIES`      | `5`     | Retry attempts for a failed data fetch before giving up for the cycle (minimum `1`).         |
| `KASA_COLLECTOR_FETCH_RETRY_DELAY`      | `1`     | Initial delay in seconds between fetch retries; grows via exponential backoff (minimum `1`). |
| `KASA_COLLECTOR_MAX_RETRY_DELAY`        | `60`    | Ceiling in seconds on the exponential backoff delay (minimum `1`).                           |

## Authentication (TP-Link)

IOT-protocol devices (most legacy plugs and strips) need no credentials. Newer SMART/KLAP devices require your TP-Link cloud account. See [Supported Devices](supported-devices.md) for which family your hardware belongs to.

| Variable                          | Default   | Description                                                  |
| --------------------------------- | --------- | ------------------------------------------------------------ |
| `KASA_COLLECTOR_TPLINK_USERNAME`  | _(unset)_ | TP-Link account email, required for SMART/KLAP devices.      |
| `KASA_COLLECTOR_TPLINK_PASSWORD`  | _(unset)_ | TP-Link account password, required for SMART/KLAP devices.   |
| `KASA_COLLECTOR_AUTH_MAX_RETRIES` | `3`       | Retry attempts for device authentication (minimum `1`).      |
| `KASA_COLLECTOR_AUTH_TIMEOUT`     | `10`      | Seconds to wait for an authentication attempt (minimum `1`). |

Credentials are masked in the startup configuration log.

## Operational timeouts

| Variable                                   | Default | Description                                                                                           |
| ------------------------------------------ | ------- | ----------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT` | `5`     | Seconds allowed to tear down a device's network transport, preventing connection leaks (minimum `1`). |
| `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`          | `10`    | Seconds to wait for in-flight tasks to finish during graceful shutdown (minimum `1`).                 |
| `KASA_COLLECTOR_DNS_CACHE_TTL`             | `300`   | Seconds to cache hostname lookups; set `0` to disable caching (minimum `0`).                          |

## Logging

| Variable                                    | Default | Description                                                                              |
| ------------------------------------------- | ------- | ---------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR`   | `INFO`  | Level for the main orchestrator. One of `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`. |
| `KASA_COLLECTOR_LOG_LEVEL_KASA_API`         | `INFO`  | Level for device communication. Set `DEBUG` to trace per-device protocol activity.       |
| `KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE` | `INFO`  | Level for InfluxDB writes. Set `DEBUG` to trace storage operations.                      |
| `KASA_COLLECTOR_STRUCTURED_LOGS`            | `False` | Emit logs as structured JSON for log aggregators instead of colored console output.      |

## Output

| Variable                       | Default  | Description                                                                                                         |
| ------------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------- |
| `KASA_COLLECTOR_WRITE_TO_FILE` | `False`  | Also write each poll's data to newline-delimited JSON (`.jsonl`) files. Primarily for debugging.                    |
| `KASA_COLLECTOR_OUTPUT_DIR`    | `output` | Directory for `.jsonl` files when file output is enabled (container path, typically bind-mounted to `/app/output`). |

## Health check

| Variable                              | Default | Description                                                                                                  |
| ------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` | `120`   | Seconds since the last successful collection before the Docker health check reports unhealthy (minimum `1`). |

The health check runs as `python -m app.health.check` and needs no web server.

## Timezone

| Variable | Default                    | Description                                                                  |
| -------- | -------------------------- | ---------------------------------------------------------------------------- |
| `TZ`     | _(container default, UTC)_ | Standard container timezone, e.g. `America/Chicago`. Affects log timestamps. |

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
