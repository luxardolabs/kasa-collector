# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- luxarch:claude-pointer asset v7 - DO NOT edit this marker line; it is how repo.claude_pointer_present knows your copy is current. Re-emit with `luxarch --emit claude-pointer`. -->

## How to work here (fleet conduct — read the standard, not just this block)

**`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` — read it in full before your first change.** It is the one home for *how* agents work in this fleet. This block is a pointer plus the handful of rules that get broken most; it is not a summary and does not replace reading it.

**Run `/fleet-start` at the start of every session and after every compact.** It rehydrates from LuxPM and restates the session rules.

**Report the result, not the mountain.** No "heavy", "multi-hour", "the big one", no narrating difficulty. Done + next in one line, with numbers.

**Decide; do not hand back a menu.** Whether to ask the owner is decided by the **class of action**, never by how confident you feel:

- **Ask** — deleting anything; changing scope; a deferral/allowlist/exemption; publishing outward (pushing another repo, a force-push, a history rewrite); a genuine product fork where the choice is taste, not correctness.
- **Do it** — aligning code to a ratified standard or a guard red; anything you have evidence for that is reversible in one commit. The standard already decided; say what you did.

**Work the guard reds in `luxarch --plan` order. Never ask which family or sweep is next.** The order is decided. An escalation covers ONE site: its family keeps going.

**An owner hold is exactly as wide as the owner said.** "Hold off on X" excludes X and nothing else. It is not permission to pause, ask, or check in about anything outside X. Skip the held family, say so in one line, and keep burning down the rest.

**End every turn that worked guard reds with `reds: N (was M)`**, plus the held families by name. A turn that ends on a question while N > 0, outside an ask-class, is the failure this block exists to stop.

When you do ask: **one decision per message**, the evidence that makes it answerable, your recommendation stated as one, and a question answerable in one word. **A recommendation that ends in a menu is not a recommendation** — if you rejected the alternatives, re-offering them asks the owner to redo your analysis.

**Use the fleet skills; don't improvise the procedure.** `/fleet-start` to open a session. `/wrap-up` before you call anything done (tests you saw fail before the fix, every red in touched files, docs, gate, LuxPM closed out, all with evidence). `/adversarial` to have an independent agent attack a change touching auth, tenancy, data, money, secrets or deploys. `/pin-bump` to upgrade the guards. `/escalate` when a guard is wrong. `/release` to cut a release.

**You touched it, you own it.** Edit a file for any reason and it has a mypy, ruff or luxarch red: fix every one in that file, not just yours. Never spend time proving a red predates you; fix it. Test what you changed first. **Before fixing any mypy red, read `luxlint --playbook mypy-sweep` in full.**

**Align or escalate; never route around.** A guard red is fixed by changing the code, or escalated to the guard maintainer as genuinely wrong. Never by an exemption, a `# noqa`, a deferral, or a local config. Verification is not authorization: proving something is unreferenced does not license deleting it.

**Escalations go in THIS repo's LuxPM project** — label `fleet-escalation`, title `[<guard> ESCALATION] …`, self-contained enough to forward whole. **Search LuxPM for an existing issue first** (and comment on it if found); filing a new one is pre-authorized. **Never a GitHub issue** — there is no fallback. The maintainer sweeps the label across every project and picks it up where you filed it.

**A red stays RED while its escalation is open.** The fleet does not gate CI on red. A lit red is honest; a silenced one is a lie you will inherit.

**Commit as `luxardolabs`** using the global git config, and never `git -c user.email=…`. No AI attribution in commit messages.

## Project Overview

Kasa Collector is a Python-based data collection service for TP-Link Kasa smart plugs and power strips. It discovers devices on the network, collects energy consumption metrics, stores data in InfluxDB, and provides Grafana dashboards for visualization.

**Version**: see `VERSION` (CalVer `YYYY.0M.MICRO`; the VERSION file is the one version literal) **Python**: 3.14+ with modern Python features **Architecture**: Asynchronous event-driven with comprehensive resource management

## Common Development Commands

### Building and Running

The build/deploy flow follows the Luxardo Labs fleet standard. `VERSION` (repo root) is the source of truth; the `Makefile` drives everything and compose never builds. Run `make help` for the grouped command list.

```bash
# Commit first (both refuse a dirty tree). Build + push THIS commit as :sha-<commit>, pin
# .env.dev to it, restart the dev stack, then `make smoke`: the kasa-collector container must run
# this commit and reach healthy by its own HEALTHCHECK, and app.main / app.health.check must import
# in the production image (no HTTP surface, so SMOKE_URL stays empty). A FAIL fails the deploy.
# `make dev-pin TAG=sha-…` rolls back to a published tag.
make dev-deploy

# Bring the dev stack up at whatever .env.dev pins — host networking
make dev-up          # make dev-logs / make dev-ps / make dev-down

# Release: refuses an already-released VERSION, pushes the multi-arch build ONCE as an unpinned
# :candidate-<commit>, pulls + scans it ONCE PER PLATFORM (luxaudit --image-archive refuses on any
# fixable HIGH/CRITICAL), then `imagetools create`s :VERSION (+ :latest alias, + :sha-<commit>
# unless dev-deploy already published it) FROM it — the tags name exactly the scanned bits. prod
# pins TAG=<VERSION> in .env.prod. dev-deploy scans before it pushes too; dev-pin refuses a
# candidate-* tag (it may have failed its scan).
# `make audit`'s image leg is a MONITOR of what the registry already holds — it clears by releasing.
make release
# Promote the released image to GHCR (ghcr.io/luxardolabs/kasa-collector) — run `make release` first
make release-public

# Remote prod deploy (set the collector host explicitly — no fleet default)
make prod-deploy PROD_NODE=<host>
```

### The stacks — ONE `compose.yml`, four PROFILES

```bash
# collector-only → YOUR external InfluxDB/Grafana (edit .env.prod). The plug-in.
make up                # make down / logs / ps / shell

# dev: your REAL devices + bundled InfluxDB + Grafana (daily local driver).
# Same compose.yml — .env.dev sets COMPOSE_PROFILES=collector,bundled.
make dev-up            # make dev-down

# demo: FAKE devices + bundled InfluxDB + Grafana (watch it work, no hardware)
make demo-up           # http://localhost:3000 — make demo-down / demo-clean

# test: hardware-free end-to-end (all fake device kinds -> collector -> InfluxDB)
make test-e2e          # builds the images, runs by tag, pass/fail, self-tears-down

# Ports default to 3000/8086. They are DEPLOYMENT facts, not repo defaults: set
# GRAFANA_PORT/INFLUX_PORT in your gitignored .env.dev when a sibling app owns one.
# Compose never builds — `make` builds each image and compose runs it by pinned tag.

# Unit tests + lint. All decoupled from :dev (FLEET-BUILD-DEPLOY-STANDARD): ruff AND mypy
# are mount-only luxlint (the repo installs nothing). `make test` is luxarch's emitted test
# block: the Dockerfile's `test` stage (production `base` + dev group) built from source, a
# REAL InfluxDB in an isolated per-run compose project (profile `test`), branch coverage
# ratcheted against [test].coverage_min in .luxlint.toml.
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
- Tests: pytest suite under `tests/`; `make test` (luxarch's test block) runs it in the Dockerfile's `test` stage — production's `base` plus the dev group, rebuilt from source every run, never `FROM :dev` — with the source mounted read-only, against a real throwaway InfluxDB (`kasa_test_influxdb`, compose profile `test`) started in its own per-run compose project and torn down pass or fail. Branch coverage is ratcheted against `[test].coverage_min` in `.luxlint.toml`
- Multi-platform builds support amd64 and arm64 architectures (`make release`), on the ONE shared fleet buildx builder (`luxardo-builder`, GC-capped) — never a per-project builder, which holds an un-deduplicated cache plus an idle buildkit daemon
- Build backend is **hatchling**, versioned dynamically from `VERSION`; Poetry stays the dependency manager in non-package mode (`poetry install --no-root` in both Dockerfiles, so the backend is never exercised at image-build time)
- Grafana dashboards are pre-configured in the `/grafana` directory
- Comprehensive resource cleanup and timeout management for long-running deployments
- The runtime image installs `tzdata` + `tzdata-legacy` — python-kasa resolves each device's timezone via `zoneinfo`, and TP-Link's timezone index uses legacy POSIX names (e.g. `PST8PDT`, `CST6CDT`) that would otherwise crash `update()`

### ONE `compose.yml` + `.env.<env>` — four profiles

The fleet standard is one compose file per repo: the STACK is a compose **profile** and the ENVIRONMENT is the `--env-file`, never an overlay file (`luxarch --doc FLEET-BUILD-DEPLOY-STANDARD`, `--playbook compose-hygiene`, `repo.compose_conventions`). **Compose never builds** — every image is built outside it and referenced by a PINNED tag, so the app image never floats (no `:latest`, no `${TAG:-latest}`).

| profile     | services                                            | selected by             |
| ----------- | --------------------------------------------------- | ----------------------- |
| `collector` | `kasa-collector` — HOST network, real devices       | `.env.prod`, `.env.dev` |
| `bundled`   | `kasa_influxdb` + `kasa_grafana`                    | `.env.dev`              |
| `demo`      | that bundled pair + 4 fakes + `kasa-collector-demo` | `.env.demo`             |
| `e2e`       | throwaway InfluxDB + 4 fakes + `kasa-collector-e2e` | `make test-e2e`         |

Each env file names its stack in `COMPOSE_PROFILES`: `.env.prod` → `collector`, `.env.dev` → `collector,bundled`, `.env.demo` → `demo`. Set `GRAFANA_PORT`/`INFLUX_PORT` per host — sibling apps share the box, so 3000 is often taken.

**Why three collector SERVICES rather than one.** `network_mode` is a property of a service and cannot vary by profile. The real collector needs HOST networking because Kasa discovery is a UDP broadcast that cannot cross a bridge; the fake-device stacks need BRIDGE networking so the collector resolves the emulators by service name, which host networking cannot do. Those are three different services, not one service in three moods. (This supersedes the previous note claiming demo/e2e had to be separate FILES — they had to be separate services, which profiles express fine.)

**Variables interpolate file-wide, regardless of profile.** `${ENV_FILE:?}` on the `collector` service is resolved even for an `--profile e2e` run, which is why `scripts/e2e-test.sh` exports `ENV_FILE` although nothing in the e2e profile reads it.

Images: the NAME declares provenance (`repo.image_name_declares_provenance`) and stacks pin only IMMUTABLE tags (`repo.deploy_tag_is_immutable`). `make dev-deploy` pushes `:sha-<commit>` (moving the `:dev` alias onto it) and `make release` pushes `:VERSION` + `:sha-<commit>`; both build the `base` stage. The hardware-free stacks run BARE local images that are never pushed: `make harness-build` → `kasa-collector-fake:test`, `make test-e2e` → `kasa-collector:test`. The runtime image ships only the app's venv — no Poetry, no pip (luxaudit's image leg scans it). Bundled InfluxDB uses a v1 DBRP mapping (`ops/influxdb/init-dbrp.sh`) because the dashboards are InfluxQL; the Grafana datasource (uid `uDxwFcOGz`) uses token-header auth. The emulator (`harness/fake_kasa.py`) does IOT plugs (emeter + non-emeter) and HS300-style strips (per-outlet emeter) via `KASA_FAKE_KIND`.

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
- `app/core/logging_config.py` - the fleet's one logging setup (`luxarch --emit logging`, never hand-edited): JSON lines on stdout, `LOG_FORMAT=text` for local runs; `app/main.py`'s `configure_app_logging()` installs it with the per-component `KASA_COLLECTOR_LOG_LEVEL_*` levels
- `app/health/check.py` - Docker health check script
- `Makefile` / `VERSION` / `pyproject.toml` - Fleet build, versioning, deps + tooling
