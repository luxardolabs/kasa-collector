# Testing

Everything runs in containers — no host Python, Poetry, or dependencies required.

## Unit tests + lint

Lint and test are decoupled from the `:dev` deploy image (per the fleet Build & Deploy Standard — a check built `FROM :dev` inherits a stale artifact and goes quietly false). Each ingredient stays fresh on its own: ruff and mypy run mount-only in the pinned luxlint image (which bakes the fleet's typed dependencies), and pytest in a lean image built from `poetry.lock` (`Dockerfile.test`, rebuilt only when the lock changes) with the working tree over-mounted — so tests always run against current source, never a bake.

```bash
make test    # pytest (lock-keyed image, source over-mounted)
make lint    # luxlint ruff/format (mount-only)
make mypy    # luxlint --mypy (mount-only)
make check   # the fleet gate: pins, lint, mypy, test, arch, audit, secret scan
```

## End-to-end harness (no hardware)

`make test-e2e` proves the whole pipeline — **fake Kasa devices → collector → InfluxDB** — with zero physical devices and zero published host ports (so it's safe in CI and on a busy host).

```bash
make test-e2e
```

What it does:

1. Builds the collector image from the current source as `kasa-collector:test`, and the emulator as `kasa-collector-fake:test` — bare local names, never pushed, so no registry is involved.
1. Brings up the `e2e` profile of `compose.yml` on a bridge network, under its own compose project so a teardown can never reach the dev or demo volumes: an ephemeral InfluxDB, a roster of fake Kasa devices (`harness/fake_kasa.py` speaking the real TP-Link IOT protocol) — two emeter plugs (HS110, KP115), a non-emeter plug (HS103), and a 6-outlet power strip (HS300) — and the collector pointed at them via `KASA_COLLECTOR_DEVICE_HOSTS` (auto-discovery off, since a bridge network can't broadcast).
1. Polls InfluxDB and asserts the emeter data for the plugs **and** the strip lands in the `emeter` measurement, and that the non-emeter plug is handled cleanly (no emeter data, collector stays healthy), then tears everything down.

To emulate other models or more devices, add services to `compose.yml` carrying `profiles: [demo, e2e]`, using the harness image and set `KASA_FAKE_KIND` (`plug` | `plug_noemeter` | `strip`), `KASA_FAKE_MODEL`, `KASA_FAKE_ALIAS`, `KASA_FAKE_BASE_W`, and (for strips) `KASA_FAKE_OUTLETS`. See [`harness/README.md`](../harness/README.md) and [supported-devices.md](supported-devices.md) for the device kinds the emulator covers.

## Try the full system interactively

Two self-contained stacks bring up the collector with a bundled, auto-provisioned InfluxDB + Grafana (open http://localhost:3000, admin / admin):

- `make demo-up` — driven by **fake** devices (the harness emulators), so the dashboards populate with no hardware.
- `make dev-up` — driven by **your real** Kasa devices on the network.

The demo runs the published GHCR release (`.env.demo`) plus the locally built emulator, so it needs no registry of your own; the dev stack runs whatever `.env.dev` pins. Stop them with `make demo-down` / `make dev-down` (add `-clean` to also drop the data volumes). The dashboards they provision are documented in [grafana-dashboards.md](grafana-dashboards.md).

## See also

- [deployment.md](deployment.md) — production deployment and release flow
- [supported-devices.md](supported-devices.md) — device compatibility and the emulator's device kinds
