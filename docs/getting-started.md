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

## Option 2 — Dev: your real devices + bundled InfluxDB / Grafana

Same self-contained InfluxDB and Grafana as the demo, but the collector uses host networking and broadcast discovery to find **your real** Kasa devices:

```bash
make dev-up
```

Open **http://localhost:3000** (admin / admin). Stop with `make dev-down` (or `make dev-clean` to also drop the data volumes); follow logs with `make dev-logs`.

To add real devices that require authentication or to pin manual device hosts, drop the relevant `KASA_COLLECTOR_*` values into a gitignored `.env.dev.local` (see `.env.dev.local.example`) — it layers on top of the bundled-stack config. Full variable reference in [Configuration](configuration.md).

## Option 3 — Collector-only: bring your own InfluxDB / Grafana

If you already run InfluxDB 2.x and Grafana, run just the collector and point it at them. Copy the environment template and fill in your `KASA_COLLECTOR_INFLUXDB_*` values:

```bash
cp .env.example .env.dev    # edit with your InfluxDB URL / org / bucket / token
make up                     # builds locally, host networking, reads .env.dev
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
