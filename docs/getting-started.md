# Getting Started

Kasa Collector runs as a Docker container that discovers Kasa smart plugs and power strips on your network, polls their energy data, and writes it to InfluxDB for visualization in Grafana.

There are three ways to run it, plus a hardware-free test. All build the collector image locally with `make` (no registry needed) and tear cleanly up and down. If you're new, start with the demo.

## Prerequisites

- [Docker](https://docs.docker.com/install)
- [Docker Compose v2](https://docs.docker.com/compose/install) (the `docker compose` plugin)
- **Host networking** for broadcast discovery of devices on your LAN (Linux). Manual device hosts also work across subnets — see [Configuration](configuration.md).

For the collector-only path you additionally need an existing **InfluxDB 2.x** bucket + token and a **Grafana** instance. The demo and dev stacks bundle both for you, so there's nothing external to set up.

You do **not** need host Python or Poetry — everything runs in containers.

## Option 1 — Demo: no hardware (recommended first run)

The fastest way to see it working. This bundles the collector with its own InfluxDB and a pre-provisioned Grafana (datasource plus all dashboards), driven by **fake** emulated Kasa devices so the dashboards populate with no hardware at all.

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up
```

Then open **http://localhost:3000** (admin / admin) and watch the dashboards move — the fake devices (emulated plugs plus an HS300-style power strip) start reporting immediately.

- Stop the stack with `make demo-down` (keeps data).
- Stop and drop the data volumes with `make demo-clean`.
- Follow logs with `make demo-logs`.
- If ports 3000 / 8086 are already in use, set `GRAFANA_PORT` / `INFLUX_PORT` in `.env.demo`.
- The demo answers on this machine only (127.0.0.1). To open it from another machine (a Pi beside your plugs, say), set `GRAFANA_BIND=0.0.0.0` in `.env.demo`.

## Option 2 — Local: your real devices + bundled InfluxDB / Grafana

Same self-contained InfluxDB and Grafana as the demo, but the collector uses host networking and broadcast discovery to find **your real** Kasa devices. It runs the image `.env.local` pins — the published release is the simplest choice:

```bash
cp .env.example .env.local
# in .env.local: REGISTRY=ghcr.io, TAG=<a released version> (e.g. 2026.10.2), ENV_FILE=.env.local,
# KASA_COLLECTOR_INFLUXDB_URL=http://localhost:8086, and secrets of your own for
# INFLUX_PASSWORD, GRAFANA_PASSWORD, GRAFANA_INFLUX_PASSWORD (Grafana's read-only InfluxDB
# sign-in) and INFLUX_TOKEN (the InfluxDB operator token; put the same value in
# KASA_COLLECTOR_INFLUXDB_TOKEN). ORG and BUCKET must match the same way.
make local-up
```

Open **http://localhost:3000** and sign in as `admin` with the `GRAFANA_PASSWORD` from `.env.local`. Grafana and InfluxDB answer on this machine only (127.0.0.1); to reach them from your LAN, set `GRAFANA_BIND=0.0.0.0` / `INFLUX_BIND=0.0.0.0` in `.env.local`, after you have replaced the template's tokens and passwords. InfluxDB keeps the org, token and passwords it was first started with, so set them before the first `make local-up`. Stop with `make local-down` (or `make local-clean` to also drop the data volumes); follow logs with `make local-logs`. If ports 3000 / 8086 are taken, set `GRAFANA_PORT` / `INFLUX_PORT` in `.env.local` (and the InfluxDB URL's port with it).

To add real devices that require authentication or to pin manual device hosts, drop the relevant `KASA_COLLECTOR_*` values into a gitignored `.env.dev.local` (see `.env.dev.local.example`) — it layers on top of the env file. Full variable reference in [Configuration](configuration.md).

`make dev-up` is the maintainers' dev stack: the same services on their dev host (`DEV_HOST` in the Makefile), where Grafana is served by name instead of a port.

## Option 3 — Collector-only: bring your own InfluxDB / Grafana

If you already run InfluxDB 2.x and Grafana, run just the collector and point it at them. Copy the environment template and fill in your `KASA_COLLECTOR_INFLUXDB_*` values:

```bash
cp .env.example .env.prod   # REGISTRY=ghcr.io, TAG=<a released version>, plus your InfluxDB URL / org / bucket / token
make up                     # host networking, reads .env.prod
```

Or run the published image directly with the Compose snippet in the [README](../README.md#quick-start). Either way, import the bundled dashboards from `grafana/shared-local/` (or `grafana/shared-external/`) and point their datasource at your InfluxDB — see [Grafana Dashboards](grafana-dashboards.md).

## Testing without hardware

To exercise the whole pipeline as a pass/fail check with no hardware and no published ports:

```bash
make test-e2e
```

It spins up fake device emulators (emeter plugs, a non-emeter plug, and a 6-outlet strip) plus an ephemeral InfluxDB, asserts data lands, and tears itself down. See [Testing](testing.md).

## Next steps

- [Configuration](configuration.md) — every environment variable and its default
- [Grafana Dashboards](grafana-dashboards.md) — what ships and how to import it
- [Deployment](deployment.md) — production Docker Compose, Kubernetes, and remote deploys
- [How It Works](how-it-works.md) — architecture and the polling model
- [Troubleshooting](troubleshooting.md) — discovery, auth, and InfluxDB fixes
