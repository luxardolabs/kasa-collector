# =============================================================================
# kasa-collector — multi-stage image (fleet standard)
#   --target base : the runtime — every deploy tag is built from it (:sha-<commit> by
#                   `make dev-deploy`, :VERSION by `make release`, kasa-collector:test by
#                   `make test-e2e`). pytest runs in Dockerfile.test, built from the lock.
# Runtime dependency versions come from poetry.lock. The runtime carries ONLY the app's
# venv: no Poetry, no pip, no build tools (luxaudit's image leg scans what ships).
# =============================================================================

# ---- Stage 1: builder — resolve + install runtime deps with Poetry ----------
FROM python:3.14-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POETRY_VERSION=2.4.1 \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_NO_INTERACTION=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry with pip (pinned + wheel-hash-verified) rather than the piped
# remote installer — no unpinned `curl … | python3 -` execution at build time.
# Poetry goes into the builder's SYSTEM Python; the app's deps go into /opt/venv (the active
# VIRTUAL_ENV, which Poetry installs into with virtualenvs.create=false). Only the venv is
# copied to the runtime, so Poetry and its dependency tree never ship.
RUN /usr/local/bin/python -m pip install --no-cache-dir "poetry==$POETRY_VERSION" \
    && /usr/local/bin/python -m venv /opt/venv

WORKDIR /app
COPY pyproject.toml poetry.lock* ./
RUN /usr/local/bin/poetry install --no-root --only main \
    && /opt/venv/bin/python -m pip uninstall -y pip

# ---- Stage 2: base — lean runtime image (prod) ------------------------------
FROM python:3.14-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

# tzdata (+ tzdata-legacy): python-kasa resolves each device's timezone via
# zoneinfo.ZoneInfo, which needs the system tz database (absent from python:*-slim).
# TP-Link's timezone index uses legacy POSIX zone names (e.g. index 6 = PST8PDT,
# plus EST5EDT/CST6CDT/MST7MDT) which Debian bookworm split into tzdata-legacy —
# without it, update() raises ZoneInfoNotFoundError on most US devices.
# `apt-get upgrade`: the base image lags Debian's security fixes (openssl, pcre2, …), and
# only a rebuild from an upgraded layer clears them. The base image's own pip goes too:
# nothing runs it, and it vendors urllib3/msgpack/setuptools that no upgrade reaches.
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends tzdata tzdata-legacy \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip

# The app's venv (main deps only) — the one thing the runtime takes from the builder.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app

# Non-root runtime user
RUN useradd -m -u 1000 appuser

# Application code (only the package — tests/docs stay out of the runtime image)
COPY --chown=appuser:appuser app /app/app

# Own the whole workdir by appuser: the output dir must exist for a clean-clone
# build (bind-mounted at runtime, but the writer + healthcheck reference ./output
# relative to WORKDIR when unmounted), and pytest's cache needs it writable.
RUN mkdir -p /app/output && chown -R appuser:appuser /app

USER appuser

# Build metadata LAST so ARG churn doesn't bust the dependency layers above.
ARG BUILD_VERSION=unknown
ARG BUILD_TIMESTAMP=unknown
ARG BUILD_COMMIT=unknown
ENV KASA_COLLECTOR_VERSION=${BUILD_VERSION} \
    KASA_COLLECTOR_BUILD_TIMESTAMP=${BUILD_TIMESTAMP} \
    BUILD_VERSION=${BUILD_VERSION} \
    BUILD_TIMESTAMP=${BUILD_TIMESTAMP} \
    BUILD_COMMIT=${BUILD_COMMIT}
LABEL org.opencontainers.image.title="Kasa Collector" \
      org.opencontainers.image.description="Kasa Collector — TP-Link Kasa energy metrics to InfluxDB" \
      org.opencontainers.image.source="https://github.com/luxardolabs/kasa-collector" \
      org.opencontainers.image.url="https://www.luxardolabs.com" \
      org.opencontainers.image.vendor="Luxardo Labs" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIMESTAMP}"

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["python3", "-m", "app.health.check"]

CMD ["python3", "-m", "app.main"]
