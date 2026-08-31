# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kasa Collector is a Python-based data collection service for TP-Link Kasa smart plugs and power strips. It discovers devices on the network, collects energy consumption metrics, stores data in InfluxDB, and provides Grafana dashboards for visualization.

**Version**: 2026.08.0 (CalVer `YYYY.0M.MICRO`; the VERSION file is the one version literal) **Python**: 3.14+ with modern Python features **Architecture**: Asynchronous event-driven with comprehensive resource management

## Common Development Commands

### Building and Running

The build/deploy flow follows the Luxardo Labs fleet standard. `VERSION` (repo root) is the source of truth; the `Makefile` drives everything and compose never builds. Run `make help` for the grouped command list.

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

# Unit tests + lint. All decoupled from :dev (FLEET-BUILD-DEPLOY-STANDARD): ruff AND mypy
# are mount-only luxlint (the repo installs nothing), pytest runs in a lean image built
# from poetry.lock (Dockerfile.test), rebuilt only when the lock changes.
make test              # pytest    make lint   # ruff    make mypy   # types
```

### Development Workflow

Everything runs in containers — there is no host Python/Poetry requirement.

```bash
make lint            # luxlint — ruff/format/docs/secret checks (canonical config, mount-only)
make mypy            # luxlint --mypy — types, mount-only (fleet typed deps baked in the image)
make format          # THE canonical fixer (`luxlint --format`) — autofix + formatter + Markdown,
                     # all from the image, with the same config the checker reads. Never
                     # hand-roll it: an unpinned host formatter drifts from the pinned checker
                     # and applies its default width to a repo that carries no local config.
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
1. **Device Manager** (`app/collector/device_manager.py`) - Handles device discovery and tracking
1. **Kasa API** (`app/collector/kasa_api.py`) - Wrapper for communicating with Kasa devices
1. **Poller** (`app/collector/poller.py`) - Periodic data collection with two intervals:
   - Energy meter data (15 seconds)
   - System information (60 seconds)
1. **InfluxDB Storage** (`app/storage/influxdb.py`) - Persists time-series data
1. **Configuration** (`app/core/config.py`) - Environment-based configuration management
1. **Health Check** (`app/health/check.py`) - Docker healthcheck entrypoint (`python -m app.health.check`)

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
- Tests: pytest suite under `tests/`; `make test` runs it in a lean image built from `poetry.lock` (`Dockerfile.test`) with the source over-mounted — never `FROM :dev`
- Multi-platform builds support amd64 and arm64 architectures (`make release`), on the ONE shared fleet buildx builder (`luxardo-builder`, GC-capped) — never a per-project builder, which holds an un-deduplicated cache plus an idle buildkit daemon
- Build backend is **hatchling**, versioned dynamically from `VERSION`; Poetry stays the dependency manager in non-package mode (`poetry install --no-root` in both Dockerfiles, so the backend is never exercised at image-build time)
- Grafana dashboards are pre-configured in the `/grafana` directory
- Comprehensive resource cleanup and timeout management for long-running deployments
- The runtime image installs `tzdata` + `tzdata-legacy` — python-kasa resolves each device's timezone via `zoneinfo`, and TP-Link's timezone index uses legacy POSIX names (e.g. `PST8PDT`, `CST6CDT`) that would otherwise crash `update()`

### Four stacks (all `.yml`, short-form volumes), by device source + observability

- **collector-only** — `compose.yml` (+ `compose.prod.yml`): just the collector → YOUR external InfluxDB/Grafana. The production plug-in. `make up`/`down`, `make prod-*`.
- **dev** — `compose.dev.yml`: your REAL devices (host networking, broadcast discovery)
  - bundled InfluxDB + Grafana. The daily local driver. `make dev-up`/`dev-down`.
- **demo** — `compose.demo.yml`: FAKE devices (the harness emulators) + bundled InfluxDB
  - Grafana. Watch it work with no hardware. `make demo-up`/`demo-down`.
- **test** — `compose.e2e.yml`: all fake device kinds + ephemeral InfluxDB, bridge network, no published ports. `make test-e2e` (pass/fail). See `docs/testing.md`.

Bundled InfluxDB uses a v1 DBRP mapping (`ops/influxdb/init-dbrp.sh`) because the dashboards are InfluxQL; the Grafana datasource (uid `uDxwFcOGz`) uses token-header auth. `.env.demo` holds the bundled-stack values (used by dev + demo). `make build-local` builds the runtime image from source; `up`/`dev-up`/`demo-up` build locally (no registry needed). The emulator (`harness/fake_kasa.py`) does IOT plugs (emeter + non-emeter) and HS300-style strips (per-outlet emeter) via `KASA_FAKE_KIND`.

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

- Python package: `app/` at the repo root (fleet layout standard — deployed apps use `app/`, not `src/`). Subpackages: `app/core`, `app/collector`, `app/storage`, `app/health`.
- Import statements are `app.`-prefixed: `from app.collector.kasa_api import KasaAPI`
- Entrypoint: `python -m app.main`; healthcheck: `python -m app.health.check`
- Container working directory: `/app`
- Volume mount targets: `/app/output`
- Environment variable prefixes: `KASA_COLLECTOR_*`

### Why This Split?

- **Hyphens** are standard for Docker, Kubernetes, URLs, and external systems
- **Underscores** are required for Python imports and module names
- This follows Python PEP8 and industry best practices

## Recent Changes (2025.7.0 baseline)

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

- `make lint`), not kept in this repo — a local `[tool.ruff]`/`[tool.mypy]` is exactly the drift luxlint's `no_local_ruff_config` / `no_local_mypy_config` checks flag. Emit the canonical config for your editor with `--emit-config ruff > .ruff.local.toml` (gitignored):

```bash
make lint    # luxlint — ruff/format/docs/secret checks (canonical config, mount-only)
make mypy    # luxlint --mypy — mount-only; the fleet's typed dependency union is BAKED into
             # the image, so py.typed libs resolve. The old in-repo tail ran without the app's
             # deps, degrading every typed symbol to Any — a hollow-green type checker.
make arch    # architecture conformance via luxarch (pinned container, reads .luxarch.toml)
make plan    # the full arch red board: every red at once, phase-ordered + file-clustered
make test    # pytest
make check   # THE fleet gate: guard-version-check lint mypy test arch audit gitleaks
make status  # regenerate the committed guard-status files (.lux*-status.json), then COMMIT them.
             # The fleet reads these instead of re-running every guard on every repo
             # (`luxarch/scripts/fleet-status.py`). A lockfile, not a cache: guard-generated,
             # stamped with the commit it was computed at, freshness-verified on read — the
             # reader marks a row STALE when HEAD moves past that SHA, so a committed green
             # that no longer reflects the code can't pass as current. Regenerate and commit
             # AFTER the change it describes, or the row lands STALE immediately.
make onboard-check  # the MACHINE GATE for "is this repo onboarded" — wiring + honesty,
             # deliberately distinct from findings red/green. Checks all three guards run,
             # luxarch --assert-scans (no rule family inspected ZERO files — a hollow green),
             # luxlint --preflight (the mypy run is honest), luxaudit actually scans, secret
             # hooks committed, no public CI, and gitleaks over FULL history (the pre-commit
             # hook only sees staged diffs, so an old untouched leak passes every commit).
```

`make check` is byte-identical across every fleet app repo (`repo.makefile_canonical`) — a gate that quietly drops mypy, arch, or the secret scan reads exactly as green as one that runs them. It is a **gate, not a report**: Make stops at the first failing step, so use `make plan` to work a list down. `guard-version-check` is **fatal** — a guard pin behind the published `:latest` fails the gate, so no one works off a stale guard; `make guard-upgrade` bumps every pin and prints what newly bites.

Secret scanning is fleet-owned too: there is no local `.gitleaks.toml` (luxlint's `secret.no_local_gitleaks_config` flags one). `make gitleaks` emits the canonical config (gitleaks defaults + the org denylist) from the luxlint image at scan time and runs it over full history; `make gitleaks-staged` scans staged changes. The committed `hooks/` (pre-commit → `gitleaks-staged`, pre-push → `gitleaks`) fire the scan on every commit/push once wired with `make hooks` (`core.hooksPath hooks`) — enforced by luxlint's `secret.githooks_wired`. There is deliberately **no** public CI: `make check` is the sole gate (luxarch's `repo.no_public_ci` — a public GitHub Actions workflow would expose its YAML + logs).

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
