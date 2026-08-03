# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kasa Collector is a Python-based data collection service for TP-Link Kasa smart plugs and power strips. It discovers devices on the network, collects energy consumption metrics, stores data in InfluxDB, and provides Grafana dashboards for visualization.

**Version**: 2025.7.0 (Latest)
**Python**: 3.14+ with modern Python features
**Architecture**: Asynchronous event-driven with comprehensive resource management

## Common Development Commands

### Building and Running

The build/deploy flow follows the Luxardo Labs fleet standard. `VERSION` (repo root)
is the source of truth; the `Makefile` drives everything and compose never builds.
Run `make help` for the grouped command list.

```bash
# Build + push the :dev image (tooling stage: dev deps + tests baked) to the registry
make dev-build-push

# Bring the dev stack up (pulls :dev, uses .env.dev) — host networking
make dev-up          # make dev-logs / make dev-ps / make dev-down

# Release: multi-arch :VERSION + :latest to the private registry (prod pulls :latest)
make release
# Promote the released image to GHCR (ghcr.io/luxardolabs/kasa-collector) — run `make release` first
make release-public

# Remote prod deploy (set the collector host explicitly — no fleet default)
make prod-deploy PROD_NODE=<host>
```

### The four stacks (all build locally — no registry needed)

```bash
# collector-only → YOUR external InfluxDB/Grafana (edit .env.dev). The plug-in.
make up                # make down / logs / ps / shell

# dev: your REAL devices + bundled InfluxDB + Grafana (daily local driver)
make dev-up            # open http://localhost:3000 (admin/admin) — make dev-down

# demo: FAKE devices + bundled InfluxDB + Grafana (watch it work, no hardware)
make demo-up           # http://localhost:3000 — make demo-down / demo-clean
# Standard ports 3000/8086 for dev+demo (override GRAFANA_PORT/INFLUX_PORT in .env.demo).

# test: hardware-free end-to-end (all fake device kinds -> collector -> InfluxDB)
make test-e2e          # builds from source, pass/fail, self-tears-down

# Unit tests + lint. Both are decoupled from :dev (FLEET-BUILD-DEPLOY-STANDARD): ruff is
# mount-only luxlint, mypy is python:3.14-slim + fresh pip, pytest runs in a lean image
# built from poetry.lock (Dockerfile.test), rebuilt only when the lock changes.
make test              # pytest        make lint   # luxlint (ruff) + mypy tail
```

### Development Workflow

Everything runs in containers — there is no host Python/Poetry requirement.

```bash
make lint            # luxlint (canonical ruff, mount-only) + mypy tail (one recipe)
make format          # auto-fix + format with the canonical luxlint ruff config
make test            # pytest suite (self-contained; no external services)
make poetry-lock     # regenerate poetry.lock (poetry-in-docker)
make gitleaks-staged # secret scan of staged changes (run before git commit)
make hooks           # one-time: install the pre-commit secret-scan hook (core.hooksPath)

docker logs kasa-collector          # view logs
make dev-shell                      # shell into the running container
```

## Architecture Overview

The application uses an asynchronous event-driven architecture with these key components:

1. **Main Orchestrator** (`app/main.py`) - Manages all components and the main event loop
2. **Device Manager** (`app/collector/device_manager.py`) - Handles device discovery and tracking
3. **Kasa API** (`app/collector/kasa_api.py`) - Wrapper for communicating with Kasa devices
4. **Poller** (`app/collector/poller.py`) - Periodic data collection with two intervals:
   - Energy meter data (15 seconds)
   - System information (60 seconds)
5. **InfluxDB Storage** (`app/storage/influxdb.py`) - Persists time-series data
6. **Configuration** (`app/core/config.py`) - Environment-based configuration management
7. **Health Check** (`app/health/check.py`) - Docker healthcheck entrypoint (`python -m app.health.check`)

## Key Configuration

All configuration is done through environment variables. Key settings include:

- **InfluxDB**: `KASA_COLLECTOR_INFLUXDB_URL`, `KASA_COLLECTOR_INFLUXDB_TOKEN`, `KASA_COLLECTOR_INFLUXDB_ORG`, `KASA_COLLECTOR_INFLUXDB_BUCKET`
- **Discovery**: `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY`, `KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL`
- **Data Collection**: `KASA_COLLECTOR_DATA_FETCH_INTERVAL`, `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL`
- **Authentication**: `KASA_COLLECTOR_TPLINK_USERNAME`, `KASA_COLLECTOR_TPLINK_PASSWORD`
- **Operational Timeouts**: `KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT`, `KASA_COLLECTOR_SHUTDOWN_TIMEOUT`, `KASA_COLLECTOR_DNS_CACHE_TTL`, `KASA_COLLECTOR_MAX_RETRY_DELAY`
- **Health Check**: `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`

## Important Notes

- The application requires host networking for device discovery
- Data is stored both in InfluxDB and optionally as `.jsonl` files in `/app/output` (bind-mounted)
- Docker health check included for container orchestration (no web server required)
- Tests: pytest suite under `tests/`; `make test` runs it in a lean image built from
  `poetry.lock` (`Dockerfile.test`) with the source over-mounted — never `FROM :dev`
- Multi-platform builds support amd64 and arm64 architectures (`make release`)
- Grafana dashboards are pre-configured in the `/grafana` directory
- Comprehensive resource cleanup and timeout management for long-running deployments
- The runtime image installs `tzdata` + `tzdata-legacy` — python-kasa resolves each
  device's timezone via `zoneinfo`, and TP-Link's timezone index uses legacy POSIX
  names (e.g. `PST8PDT`, `CST6CDT`) that would otherwise crash `update()`

### Four stacks (all `.yml`, short-form volumes), by device source + observability
- **collector-only** — `compose.yml` (+ `compose.prod.yml`): just the collector →
  YOUR external InfluxDB/Grafana. The production plug-in. `make up`/`down`, `make prod-*`.
- **dev** — `compose.dev.yml`: your REAL devices (host networking, broadcast discovery)
  + bundled InfluxDB + Grafana. The daily local driver. `make dev-up`/`dev-down`.
- **demo** — `compose.demo.yml`: FAKE devices (the harness emulators) + bundled InfluxDB
  + Grafana. Watch it work with no hardware. `make demo-up`/`demo-down`.
- **test** — `compose.e2e.yml`: all fake device kinds + ephemeral InfluxDB, bridge
  network, no published ports. `make test-e2e` (pass/fail). See `docs/TESTING.md`.

Bundled InfluxDB uses a v1 DBRP mapping (`ops/influxdb/init-dbrp.sh`) because the
dashboards are InfluxQL; the Grafana datasource (uid `uDxwFcOGz`) uses token-header auth.
`.env.demo` holds the bundled-stack values (used by dev + demo). `make build-local` builds
the runtime image from source; `up`/`dev-up`/`demo-up` build locally (no registry needed).
The emulator (`harness/fake_kasa.py`) does IOT plugs (emeter + non-emeter) and HS300-style
strips (per-outlet emeter) via `KASA_FAKE_KIND`.

## Naming Convention

**IMPORTANT**: This project uses a split naming convention that follows industry standards:

### External/Infrastructure Names (use hyphens: `kasa-collector`)
- Docker image names: `ghcr.io/luxardolabs/kasa-collector` (public GHCR) and a private registry (host configured in the untracked `Makefile.local`)
- Container names: `kasa-collector`
- Git repository: `kasa-collector`
- Kubernetes resources
- Docker Compose project names
- InfluxDB bucket names

### Internal/Python Names (use underscores: `kasa_collector`)
- Python package: `app/` at the repo root (fleet layout standard — deployed apps use
  `app/`, not `src/`). Subpackages: `app/core`, `app/collector`, `app/storage`, `app/health`.
- Import statements are `app.`-prefixed: `from app.collector.kasa_api import KasaAPI`
- Entrypoint: `python -m app.main`; healthcheck: `python -m app.health.check`
- Container working directory: `/app`
- Volume mount targets: `/app/output`
- Environment variable prefixes: `KASA_COLLECTOR_*`

### Why This Split?
- **Hyphens** are standard for Docker, Kubernetes, URLs, and external systems
- **Underscores** are required for Python imports and module names
- This follows Python PEP8 and industry best practices

## Recent Changes (2025.7.0)

### Fixed Issues
- ✅ InfluxDB connection leaks - proper cleanup on shutdown
- ✅ Transport connection leaks - comprehensive cleanup with timeout
- ✅ Blocking DNS operations - replaced with async operations
- ✅ Task management - proper tracking and cancellation
- ✅ Broad exception handling - specific exception types
- ✅ Manual devices on different subnets - uses discover_single for cross-subnet support
- ✅ Type safety issues - all code passes mypy and pyright strict checking

### New Features
- 🚀 Docker health check without web server
- 🚀 DNS caching with configurable TTL
- 🚀 6 configurable operational timeouts
- 🚀 Modern Python 3.14 patterns (TaskGroup, exception groups)
- 🚀 Comprehensive retry logic with exponential backoff
- 🚀 Parallel device initialization for faster startup
- 🚀 asyncio-native InfluxDB writes (aiohttp `InfluxDBClientAsync`; one awaited batch per poll cycle)

## Code Quality Standards

The canonical ruff (lint + format) and mypy config is owned by **luxlint** (`.luxlint.toml`
+ `make lint`), not kept in this repo — a local `[tool.ruff]`/`[tool.mypy]` is exactly the
drift luxlint's `no_local_ruff_config` / `no_local_mypy_config` checks flag. Emit the canonical
config for your editor with `--emit-config ruff > .ruff.local.toml` (gitignored):
```bash
make lint    # luxlint (canonical ruff, mount-only) + mypy tail (one recipe)
make arch    # architecture conformance via luxarch (pinned container, reads .luxarch.toml)
make test    # pytest
make check   # lint + arch + audit + test + gitleaks
```

Secret scanning is fleet-owned too: there is no local `.gitleaks.toml` (luxlint's
`secret.no_local_gitleaks_config` flags one). `make gitleaks` emits the canonical config
(gitleaks defaults + the org denylist) from the luxlint image at scan time and runs it over
full history; `make gitleaks-staged` scans staged changes (the `make hooks` pre-commit hook).
A GitHub Action (`.github/workflows/gitleaks.yml`) runs the default ruleset server-side on
the public mirror as a backstop.

## Key Files to Know

- `app/main.py` - Main orchestrator with graceful shutdown
- `app/collector/device_manager.py` - Device lifecycle management
- `app/collector/poller.py` - Data collection with retry logic
- `app/collector/kasa_api.py` - Device communication with transport cleanup
- `app/collector/utils.py` - Shared utilities (retry decorator, device helpers)
- `app/collector/dns_cache.py` - DNS caching implementation
- `app/storage/influxdb.py` - InfluxDB time-series persistence
- `app/health/check.py` - Docker health check script
- `Makefile` / `VERSION` / `pyproject.toml` - Fleet build, versioning, deps + tooling