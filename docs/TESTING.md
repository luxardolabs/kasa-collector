# Testing

Everything runs in containers — no host Python, Poetry, or dependencies required.

## Unit tests + lint

Lint and test are decoupled from the `:dev` deploy image (per the fleet Build & Deploy Standard — a check built `FROM :dev` inherits a stale artifact and goes quietly false). Each ingredient stays fresh on its own: ruff runs mount-only in the luxlint image, mypy on `python:3.14-slim` with a fresh `pip install`, and pytest in a lean image built from `poetry.lock` (`Dockerfile.test`, rebuilt only when the lock changes) with the working tree over-mounted — so tests always run against current source, never a bake.

```bash
make test    # pytest (lock-keyed image, source over-mounted)
make lint    # luxlint ruff (mount-only) + mypy tail
make check   # lint + arch + audit + test
```

## End-to-end harness (no hardware)

`make test-e2e` proves the whole pipeline — **fake Kasa devices → collector → InfluxDB** — with zero physical devices and zero published host ports (so it's safe in CI and on a busy host).

```bash
make test-e2e
```

What it does:

1. Builds the collector image from the current source.
1. Brings up `compose.e2e.yml` on a bridge network: an ephemeral InfluxDB, a roster of fake Kasa devices (`harness/fake_kasa.py` over the real IOT protocol) — two emeter plugs (HS110, KP115), a non-emeter plug (HS103), and a 6-outlet power strip (HS300) — and the collector pointed at them via `KASA_COLLECTOR_DEVICE_HOSTS` (auto-discovery off, since a bridge can't broadcast).
1. Polls InfluxDB and asserts the emeter data for the plugs **and** the strip lands in the `emeter` measurement, and that the non-emeter plug is handled cleanly (no emeter data, collector stays healthy), then tears everything down.

To emulate other models or more devices, add services to `compose.e2e.yml` using the harness image and set `KASA_FAKE_MODEL` / `KASA_FAKE_ALIAS` / `KASA_FAKE_BASE_W` (see [`harness/README.md`](../harness/README.md)).

## Try the full system interactively

Two self-contained stacks bring up the collector with a bundled, auto-provisioned InfluxDB + Grafana (open http://localhost:3000, admin / admin):

- `make demo-up` — driven by **fake** devices (the harness emulators), so the dashboards populate with no hardware.
- `make dev-up` — driven by **your real** Kasa devices on the network.

Both build the collector image locally (no registry needed) and stop with `make demo-down` / `make dev-down`.
