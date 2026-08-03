# Kasa Collector Requirements

This document details the dependencies and requirements for the Kasa Collector application.

## Python Version

- **Minimum**: Python 3.14 (`python = "^3.14"` in `pyproject.toml`)
- **Recommended**: Python 3.14+ (for enhanced features)
- **Container**: Uses `python:3.14-slim` base image (multi-stage build)

## Dependency Management

Dependencies are managed with **Poetry** — `pyproject.toml` declares them and `poetry.lock` pins the full resolved graph (runtime *and* dev tooling). There is no `requirements.txt`. The Docker build installs from the lockfile inside a builder stage, so runtime and tooling versions are pinned and reproducible (never an ad-hoc `pip install`).

Lockfile operations run in a throwaway container (no host Poetry required):

```bash
make poetry-lock       # regenerate poetry.lock from pyproject.toml
make poetry-update     # update deps to latest allowed + relock
make poetry-install    # verify deps resolve + install cleanly
```

## Core Dependencies

### Production Requirements

```toml
[tool.poetry.dependencies]
python = "^3.14"
aiofiles = "^24.1.0"
influxdb-client = "^1.46.0"
python-kasa = "^0.10.2"
```

#### Dependency Details

1. **aiofiles** (^24.1.0)

   - Asynchronous file operations
   - Used for non-blocking JSON file writes
   - Required when `KASA_COLLECTOR_WRITE_TO_FILE=True`

1. **influxdb-client** (^1.46.0)

   - Official InfluxDB 2.x Python client
   - Handles time-series data storage
   - Supports batch writes and async operations

1. **python-kasa** (^0.10.2)

   - TP-Link Kasa device communication library
   - Supports both legacy and modern Kasa protocols
   - Required version for EP25 hardware 2.6+ authentication

### Development Requirements

```toml
[tool.poetry.group.dev.dependencies]
ruff = "^0.12.7"          # lint + format (replaces black + flake8)
mypy = "^1.20.0"          # static type checking
pytest = "^8.4.1"         # test runner
pytest-asyncio = "^1.1.0" # async test support
types-aiofiles = "^24.1.0"
```

Quality gates run in containers built from the current source:

```bash
make lint   # ruff check + ruff format --check + mypy
make test   # pytest (tests/ suite)
make check  # both
```

## Runtime Image

The multi-stage `Dockerfile` produces a lean `python:3.14-slim` runtime that also installs **`tzdata` and `tzdata-legacy`**. python-kasa resolves each device's timezone via `zoneinfo.ZoneInfo`, which needs the system tz database (absent from the slim image). TP-Link's timezone index uses legacy POSIX zone names (e.g. `PST8PDT`, `EST5EDT`, `CST6CDT`, `MST7MDT`) that Debian bookworm split into `tzdata-legacy` — without it, `device.update()` raises `ZoneInfoNotFoundError` on most US devices.

## System Requirements

### Container Resources

#### Minimum

- CPU: 100m (0.1 core)
- Memory: 128MB
- Storage: 50MB (without file output)

#### Recommended

- CPU: 500m (0.5 core)
- Memory: 256MB
- Storage: 1GB (with file output)

### Network Requirements

1. **Host Networking**: Required for UDP broadcast device discovery
1. **Ports**:
   - UDP 9999 (Kasa device discovery)
   - TCP 80/443 (InfluxDB connection)
1. **Firewall**: Allow outbound HTTP/HTTPS to InfluxDB

## External Service Requirements

### InfluxDB

- **Version**: 2.0 or higher
- **Requirements**:
  - Organization created
  - Bucket created
  - API token with write permissions
  - Accessible URL from container

### TP-Link Kasa Account (Optional)

- Required for newer devices (EP25 hardware 2.6+)
- Valid email and password
- Devices must be linked to account

## Operating System Support

### Container Host

- Linux (amd64, arm64)
- Docker 20.10+
- Docker Compose 1.29+ (optional)

### Development Environment

- Linux, macOS, Windows with WSL2
- Docker (all build, lint, and test targets run in containers)
- Python 3.14+ only needed for running the app directly outside Docker
- Poetry manages dependencies (no host Poetry required — Makefile runs it in Docker)

## Feature Dependencies

### DNS Caching

- No additional requirements
- Uses standard library `socket` module
- Configurable TTL via environment variable

### Health Check

- No additional requirements
- Uses Python standard library only
- File-based or process-based checks

### Modern Python Features

The codebase uses Python 3.14 features:

- `asyncio.TaskGroup` (Python 3.11+)
- `ExceptionGroup` (Python 3.11+)
- Enhanced type annotations
- Modern `type` statement syntax

For older Python versions, fallbacks are implemented.

## Security Considerations

### Credentials

- Environment variables for sensitive data
- No hardcoded credentials
- Support for Docker secrets (compose/swarm)

### Network

- Runs with host networking (required)
- No inbound ports exposed
- Outbound HTTPS for InfluxDB

### Container

- Non-root user recommended
- Read-only filesystem possible (except output dir)
- No privileged mode required

## Version Compatibility Matrix

| Component   | Minimum | Recommended | Notes                          |
| ----------- | ------- | ----------- | ------------------------------ |
| Python      | 3.14    | 3.14        | Image runs on python:3.14-slim |
| Docker      | 20.10   | 24.0+       | BuildKit support               |
| InfluxDB    | 2.0     | 2.7+        | Latest features                |
| python-kasa | 0.10.2  | 0.10.2      | Required for auth support      |

## Upgrade Considerations

### From Pre-2025.7.0

- Update all environment variables
- Add new timeout configurations
- Review health check settings
- Update Docker image tag

### Python Version

- 3.14 is the minimum supported version (`python = "^3.14"` in `pyproject.toml`)
- Container handles version automatically (runs on python:3.14-slim)

## Testing

A pytest suite lives under `tests/` and runs fully in containers (`make test`), with a hardware-free end-to-end harness (`make test-e2e`) that stands up fake Kasa device emulators (`harness/fake_kasa.py`) → collector → InfluxDB. See `docs/TESTING.md`.

______________________________________________________________________

*Last updated: 2026-07-11*
