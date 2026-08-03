# =============================================================================
# kasa-collector — multi-stage image (fleet standard)
#   --target base : runtime only (prod pulls :latest / :VERSION)
#   --target dev  : base + dev deps + baked tests (dev stack pulls :dev; lint/test
#                   images derive from it). See Makefile dev-build-push / release.
# All dependency versions (runtime AND dev tooling) come from poetry.lock, so the
# lint/type/test tooling is pinned and reproducible — never an ad-hoc pip install.
# =============================================================================

# ---- Stage 1: builder — resolve + install runtime deps with Poetry ----------
FROM python:3.14-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POETRY_VERSION=2.4.1 \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_NO_INTERACTION=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry with pip (pinned + wheel-hash-verified) rather than the piped
# remote installer — no unpinned `curl … | python3 -` execution at build time.
RUN pip install --no-cache-dir "poetry==$POETRY_VERSION"

WORKDIR /app
COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-root --only main

# ---- Stage 1b: builder-dev — add the dev group (ruff/mypy/pytest, pinned) ----
FROM builder AS builder-dev
RUN poetry install --no-root --with dev

# ---- Stage 2: base — lean runtime image (prod) ------------------------------
FROM python:3.14-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# tzdata (+ tzdata-legacy): python-kasa resolves each device's timezone via
# zoneinfo.ZoneInfo, which needs the system tz database (absent from python:*-slim).
# TP-Link's timezone index uses legacy POSIX zone names (e.g. index 6 = PST8PDT,
# plus EST5EDT/CST6CDT/MST7MDT) which Debian bookworm split into tzdata-legacy —
# without it, update() raises ZoneInfoNotFoundError on most US devices.
RUN apt-get update && apt-get install -y --no-install-recommends tzdata tzdata-legacy \
    && rm -rf /var/lib/apt/lists/*

# Copy installed packages + console scripts from the builder (main deps only)
COPY --from=builder /usr/local/lib/python3.14/site-packages/ /usr/local/lib/python3.14/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/

WORKDIR /app

# Non-root runtime user
RUN useradd -m -u 1000 appuser

# Application code (only the package — tests/docs stay out of the runtime image)
COPY --chown=appuser:appuser app /app/app

# Own the whole workdir by appuser: the output dir must exist for a clean-clone
# build (bind-mounted at runtime, but the writer + healthcheck reference ./output
# relative to WORKDIR when unmounted), and tool caches (ruff/mypy) need it writable.
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
LABEL version="${BUILD_VERSION}" \
      build_timestamp="${BUILD_TIMESTAMP}" \
      commit="${BUILD_COMMIT}" \
      description="Kasa Collector — TP-Link Kasa energy metrics to InfluxDB" \
      maintainer="Luxardo Labs"

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["python3", "-m", "app.health.check"]

CMD ["python3", "-m", "app.main"]

# ---- Stage 3: dev — base + dev tooling + baked tests (dev stack / lint / test)
FROM base AS dev

USER root
# Overlay the dev-group site-packages (ruff/mypy/pytest, pinned by poetry.lock)
# on top of the runtime deps. No ad-hoc pip install — versions match pyproject.
COPY --from=builder-dev /usr/local/lib/python3.14/site-packages/ /usr/local/lib/python3.14/site-packages/
COPY --from=builder-dev /usr/local/bin/ /usr/local/bin/

# Bake tests + current tool config so `make test` / `make lint` are self-contained.
COPY --chown=appuser:appuser tests /app/tests
COPY --chown=appuser:appuser pyproject.toml /app/pyproject.toml

USER appuser
