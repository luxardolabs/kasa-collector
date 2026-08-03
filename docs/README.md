# Kasa Collector

A Python-based data collection service for TP-Link Kasa smart plugs and power strips. Discovers devices on the network, collects energy consumption metrics, stores data in InfluxDB, and provides Grafana dashboards for visualization.

Maintained by **Luxardo Labs**. Source: [github.com/luxardolabs/kasa-collector](https://github.com/luxardolabs/kasa-collector).

## Features

- **Automatic Device Discovery**: Finds Kasa devices on your network
- **Manual Device Configuration**: Support for specific device IPs/hostnames (including cross-subnet)
- **Authentication Support**: Works with newer Kasa devices requiring TP-Link account credentials (KLAP)
- **Energy Monitoring**: Collects voltage, current, power, and total energy consumption
- **Time-Series Storage**: Stores data in InfluxDB 2.x for historical analysis
- **Visualization**: Pre-configured Grafana dashboards
- **File Output**: Optional newline-delimited JSON (`.jsonl`) file output for debugging/backup
- **Containerized**: Docker-based deployment, multi-architecture (amd64 + arm64)
- **Health Monitoring**: Built-in Docker health check for container orchestration
- **Resource Management**: Comprehensive cleanup for long-running deployments
- **Modern Python**: Uses Python 3.14 with asyncio and type hints

Everything runs in Docker. You do **not** need host Python, Poetry, or any dependencies installed to build, run, or test the project.

## Supported Devices

- TP-Link Kasa smart plugs and power strips with energy monitoring (emeter functionality)
- Newer devices requiring authentication (e.g. EP25 hardware 2.6+, KLAP protocol)
- Both legacy IOT and modern Kasa protocols supported

## Run Stacks

Kasa Collector runs as one of four stacks depending on what you want. All build the
collector image **locally** (no registry or push needed) and tear up/down:

| Stack | Command | What it runs |
|-------|---------|--------------|
| **demo** | `make demo-up` | FAKE emulated devices + bundled InfluxDB + Grafana — dashboards populate with zero hardware |
| **dev** | `make dev-up` | Your REAL Kasa devices (host networking) + bundled InfluxDB + Grafana |
| **collector-only** | `make up` | Just the collector against YOUR OWN external InfluxDB + Grafana |
| **test** | `make test-e2e` | Hardware-free end-to-end test (fake devices + ephemeral InfluxDB), self-tearing-down |

## Quick Start — Demo (no hardware)

The fastest way to see the collector working. This bundles the collector with its own
InfluxDB 2.x and a pre-provisioned Grafana (datasource + all dashboards), driven by
**fake** Kasa devices (emulated plugs + a power strip) so the dashboards populate with
no hardware at all.

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up          # or: docker compose -f compose.demo.yml --env-file .env.demo up -d
```

Then open **http://localhost:3000** (admin / admin) and watch the dashboards move. Stop
with `make demo-down`, or `make demo-clean` to also drop the data volumes. If ports
3000/8086 are already taken, set `GRAFANA_PORT` / `INFLUX_PORT` in `.env.demo`.

**Requirement:** InfluxDB 2.x (the demo stack bundles it; bring-your-own must also be 2.x).

## Run it for real — Dev (your devices + bundled InfluxDB/Grafana)

Same self-contained InfluxDB + Grafana, but the collector uses host networking and
broadcast discovery to find **your real** Kasa devices on the network:

```bash
make dev-up           # http://localhost:3000 (admin/admin) — make dev-down to stop
```

`make dev-clean` also drops the data volumes; `make dev-logs` follows the collector logs.

## Collector-only — Bring your own InfluxDB

If you already run InfluxDB 2.x + Grafana, run just the collector against them. Copy the
environment template and fill in your `KASA_COLLECTOR_INFLUXDB_*` values:

```bash
cp .env.example .env.dev   # edit with your InfluxDB URL/org/bucket/token
```

Then `make up` (builds locally, host networking, reads `.env.dev`), or roll your own
Compose service against the published image:

```yaml
# compose.local.yml
services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:latest
    container_name: kasa-collector
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env.dev
```

```bash
docker compose -f compose.local.yml up -d
```

Import the dashboards from `grafana/shared-local/` and point their datasource at your
InfluxDB. Multi-arch images (amd64 + arm64) are published to GitHub Container Registry as
`ghcr.io/luxardolabs/kasa-collector`.

## Configuration

All configuration is done through environment variables. In practice these live in a
gitignored `.env.dev` / `.env.prod` file (only `.env.example` is committed); see
[`.env.example`](../.env.example) for the full annotated template.

### Required Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `KASA_COLLECTOR_INFLUXDB_URL` | InfluxDB server URL | `http://influxdb.example.com:8086` |
| `KASA_COLLECTOR_INFLUXDB_TOKEN` | InfluxDB authentication token | `your-token-here` |
| `KASA_COLLECTOR_INFLUXDB_ORG` | InfluxDB organization | `your-org` |
| `KASA_COLLECTOR_INFLUXDB_BUCKET` | InfluxDB bucket name | `kasa` |

### Authentication (for newer devices)

| Variable | Description | Example |
|----------|-------------|---------|
| `KASA_COLLECTOR_TPLINK_USERNAME` | TP-Link account email | `user@example.com` |
| `KASA_COLLECTOR_TPLINK_PASSWORD` | TP-Link account password | `your-password` |

### Device Discovery

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY` | `True` | Enable automatic device discovery |
| `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL` | `300` | Discovery interval (seconds) |
| `KASA_COLLECTOR_DISCOVERY_TIMEOUT` | `5` | Discovery timeout (seconds) |
| `KASA_COLLECTOR_DISCOVERY_PACKETS` | `3` | Number of discovery packets |
| `KASA_COLLECTOR_DEVICE_HOSTS` | _(empty)_ | Comma-separated list of device IPs/hostnames (manual / cross-subnet) |

### Data Collection

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_DATA_FETCH_INTERVAL` | `15` | Energy data collection interval (seconds) |
| `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL` | `60` | System info collection interval (seconds) |
| `KASA_COLLECTOR_FETCH_MAX_RETRIES` | `3` | Max retries for failed requests |
| `KASA_COLLECTOR_FETCH_RETRY_DELAY` | `1` | Delay between retries (seconds) |

### File Output (Optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_WRITE_TO_FILE` | `False` | Enable newline-delimited JSON (`.jsonl`) file output |
| `KASA_COLLECTOR_OUTPUT_DIR` | `output` | Directory for `.jsonl` files (bind-mounted at `/app/output`) |

### Advanced Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_KEEP_MISSING_DEVICES` | `False` | Keep devices that disappear from discovery |
| `KASA_COLLECTOR_AUTH_MAX_RETRIES` | `3` | Authentication retry attempts |
| `KASA_COLLECTOR_AUTH_TIMEOUT` | `10` | Authentication timeout (seconds) |

### Operational Timeouts

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT` | `5` | Transport cleanup timeout (seconds) |
| `KASA_COLLECTOR_SHUTDOWN_TIMEOUT` | `10` | Graceful shutdown timeout (seconds) |
| `KASA_COLLECTOR_DNS_CACHE_TTL` | `300` | DNS cache TTL (seconds) |
| `KASA_COLLECTOR_MAX_RETRY_DELAY` | `60` | Maximum exponential backoff delay (seconds) |
| `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE` | `120` | Maximum data age for health check (seconds) |

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR` | `INFO` | Main application log level |
| `KASA_COLLECTOR_LOG_LEVEL_KASA_API` | `INFO` | Kasa API log level |
| `KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE` | `INFO` | InfluxDB storage log level |
| `KASA_COLLECTOR_STRUCTURED_LOGS` | `False` | Emit logs as structured JSON (for aggregation) instead of colored console |

## Architecture

The application uses an asynchronous event-driven architecture:

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│  Main Collector │    │  Device Manager  │    │   Kasa API      │
│                 │    │                  │    │                 │
│ • Orchestration │◄──►│ • Discovery      │◄──►│ • Device Comm   │
│ • Task Mgmt     │    │ • Authentication │    │ • Data Fetching │
│ • Scheduling    │    │ • Device Tracking│    │ • Error Handling│
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│     Poller      │    │  InfluxDB Store  │    │   File Output   │
│                 │    │                  │    │                 │
│ • Energy Data   │    │ • Time Series    │    │ • JSON Backup   │
│ • System Info   │    │ • Batch Writes   │    │ • Debug Data    │
│ • Retry Logic   │    │ • Error Recovery │    │ • Local Storage │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### Code Layout

The application is an `app/` Python package at the repo root:

| Path | Responsibility |
|------|----------------|
| `app/main.py` | Main orchestrator and async event loop (entrypoint: `python -m app.main`) |
| `app/core/config.py` | Environment-based configuration |
| `app/collector/device_manager.py` | Device discovery, authentication, and lifecycle |
| `app/collector/poller.py` | Periodic data collection with retry logic |
| `app/collector/kasa_api.py` | Low-level communication with Kasa devices |
| `app/collector/dns_cache.py` | Async DNS caching |
| `app/collector/utils.py` | Shared utilities (retry decorator, device helpers) |
| `app/storage/influxdb.py` | Time-series data persistence |
| `app/health/check.py` | Docker health check (`python -m app.health.check`) |

The container `WORKDIR` is `/app`, runs as the non-root `appuser`, and bind-mounts its
output directory at `/app/output`.

### Data Flow

1. **Discovery Phase**: Auto-discover devices on network + load manual devices
2. **Authentication**: Authenticate devices requiring credentials
3. **Polling Phase**:
   - Energy data every 15 seconds (configurable)
   - System info every 60 seconds (configurable)
4. **Storage**: Data written to InfluxDB and optionally to `.jsonl` files

## Grafana Dashboards

Pre-configured dashboards are included in the `grafana/` directory:

- `grafana/shared-local/` — dashboards for a local InfluxDB datasource (used by the demo and dev stacks)
- `grafana/shared-external/` — dashboards for an external/shared InfluxDB datasource
- `grafana/provisioning/` — datasource + dashboard provisioning used by the demo and dev stacks

Dashboards cover power consumption per device, voltage/current/power measurements,
time-based energy analysis, device details, and collector/device status. The demo and dev
stacks provision all of these automatically; for a collector-only / bring-your-own setup,
import them and point their datasource at your InfluxDB.

## Development

### Build & Release (Makefile-driven)

The build is driven by a `Makefile`, and the `VERSION` file at the repo root is the
source of truth for the version. Dependencies are managed with **Poetry**
(`pyproject.toml` + `poetry.lock`) — run entirely inside Docker, so no host Poetry is
needed. The local run stacks (`up` / `dev-up` / `demo-up`) build the collector image
**locally** from current source (no registry needed); the `release*` targets build and
push multi-arch images for remote/prod deploys.

```bash
make help                       # list all targets with descriptions

make demo-up                    # demo: fake devices + bundled InfluxDB + Grafana (no hardware)
make dev-up                     # dev: your real devices + bundled InfluxDB + Grafana
make up                         # collector-only against your external InfluxDB (edit .env.dev)

make dev-down                   # stop the dev stack   (dev-clean also drops data volumes)
make dev-logs                   # follow collector logs

make release                    # multi-arch :VERSION + :latest → private registry
make release-public             # multi-arch :VERSION + :latest → GHCR (public OSS)
```

Dependency management (Poetry-in-Docker):

```bash
make poetry-lock                # regenerate poetry.lock from pyproject.toml
make poetry-update              # update deps to latest allowed + rewrite the lock
```

### Code Quality & Tests

All checks run in Docker (no host Python required):

```bash
make lint       # ruff check + ruff format --check + mypy
make test       # pytest suite under tests/
make check      # lint + arch (standards guards) + test
make test-e2e   # hardware-free end-to-end: fake Kasa devices → collector → InfluxDB
```

Optional git hooks wrap these (see `.pre-commit-config.yaml`): `pip install pre-commit &&
pre-commit install` runs a staged secret scan on every commit, and `pre-commit install
--hook-type pre-push` adds lint + tests before a push.

The end-to-end harness (`harness/`) emulates real Kasa devices over the IOT protocol, so
the full pipeline can be exercised with no physical hardware. See
[TESTING.md](TESTING.md) for details.

## Runtime Image Notes

- Base image is `python:3.14-slim`, built multi-stage (builder → base runtime → dev tooling).
- Runs as the non-root `appuser`.
- The runtime image installs `tzdata` **and** `tzdata-legacy`. `python-kasa` resolves each
  device's timezone via `zoneinfo`, and TP-Link's timezone index uses legacy POSIX zone
  names (e.g. `PST8PDT`, `EST5EDT`) that Debian split into `tzdata-legacy`. Without it,
  `update()` raises `ZoneInfoNotFoundError` on most US devices.

## Troubleshooting

### "Server response doesn't match our challenge"

Authentication issue with newer Kasa devices:

1. Ensure you're using a current `python-kasa` (see `pyproject.toml`)
2. Set `KASA_COLLECTOR_TPLINK_USERNAME` and `KASA_COLLECTOR_TPLINK_PASSWORD`
3. Verify credentials work with the Kasa mobile app
4. Check device hardware version (e.g. EP25 2.6+ requires authentication)

### "Failed to discover or authenticate device"

1. Ensure devices are on the same network as the collector (host networking required)
2. Check if devices require authentication (newer firmware)
3. Verify network connectivity and firewall settings
4. Try manual device configuration with `KASA_COLLECTOR_DEVICE_HOSTS`

### `ZoneInfoNotFoundError` on device update

The runtime image ships `tzdata` + `tzdata-legacy` to avoid this. If you build a custom
image, ensure both packages are installed.

### InfluxDB connection issues

1. Verify the InfluxDB URL is correct and reachable
2. Confirm the token has write permissions to the bucket
3. Ensure the organization and bucket exist (InfluxDB 2.x)
4. Test connectivity with the InfluxDB CLI or web UI

### Debug Mode

```bash
# in your .env.dev / .env.prod
KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG
KASA_COLLECTOR_LOG_LEVEL_KASA_API=DEBUG
KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE=DEBUG
```

### File Output for Debugging

```bash
KASA_COLLECTOR_WRITE_TO_FILE=True
KASA_COLLECTOR_OUTPUT_DIR=output   # bind-mounted at /app/output
```

## Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed Docker, Docker Compose, and Kubernetes
deployment guidance, including the Makefile-driven remote production deploy
(`make prod-deploy PROD_NODE=<host>`).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes following the code style (`make lint`)
4. Add or update tests (`make test`)
5. Submit a pull request

## License

This project is licensed under the AGPL-3.0-only license — see the [LICENSE](../LICENSE) file for details.

## Support

- **Issues**: [github.com/luxardolabs/kasa-collector/issues](https://github.com/luxardolabs/kasa-collector/issues)
- **Maintainer**: Luxardo Labs
- **Live Demo**: [https://www.luxardolabs.com/kasa-collector/](https://www.luxardolabs.com/kasa-collector/)

This project is not affiliated with TP-Link or Kasa. It is an independent tool for
monitoring energy consumption of Kasa smart devices.
