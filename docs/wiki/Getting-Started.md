# Getting Started

Kasa Collector runs as a Docker container that discovers Kasa smart plugs and power strips on your network, polls their energy data, and writes it to InfluxDB for visualization in Grafana.

There are three ways to run it (plus a hardware-free test). All build the collector image locally and tear up/down. If you're new, start with the all-in-one demo.

## Option 1 — Demo, no hardware (recommended for new users)

The fastest way to see it working. This bundles the collector with its own InfluxDB and a pre-provisioned Grafana (datasource plus all dashboards) — no external services to set up — and drives it with **fake** emulated Kasa devices so the dashboards populate with no hardware at all.

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up
```

Then open **http://localhost:3000** (admin / admin) and watch the dashboards move — the fake devices (emulated plugs plus a power strip) start reporting immediately.

- Stop the stack with `make demo-down` (keeps data).
- Stop and drop the data volumes with `make demo-clean`.
- If ports 3000 / 8086 are already in use, set `GRAFANA_PORT` / `INFLUX_PORT` in `.env.demo`.

The demo uses `compose.demo.yml`. Under the hood `make demo-up` runs `docker compose -f compose.demo.yml --env-file .env.demo up -d`.

## Option 2 — Dev: your real devices + bundled InfluxDB / Grafana

Same self-contained InfluxDB + Grafana as the demo, but the collector uses host networking and broadcast discovery to find **your real** Kasa devices on the network:

```bash
make dev-up
```

Open **http://localhost:3000** (admin / admin). Stop with `make dev-down` (or `make dev-clean` to also drop the data volumes); follow logs with `make dev-logs`. This uses `compose.dev.yml`.

## Option 3 — Collector-only: bring your own InfluxDB / Grafana

If you already run InfluxDB and Grafana, run just the collector container and point it at your InfluxDB via the `KASA_COLLECTOR_INFLUXDB_*` variables. Edit `.env.dev` and run `make up`, or see [Deploying Kasa Collector](Deploying-Kasa-Collector.md) for the full Docker Compose and `docker run` examples.

## Testing without hardware

To exercise the whole pipeline as a pass/fail check with no hardware and no published ports, run `make test-e2e` — it spins up fake device emulators (emeter plugs, a non-emeter plug, and a 6-outlet strip) plus an ephemeral InfluxDB, asserts data lands, and tears itself down. See [docs/TESTING.md](../TESTING.md).

## Prerequisites

You will need:

- [Docker](https://docs.docker.com/install)
- [Docker Compose](https://docs.docker.com/compose/install)

For the bring-your-own path you also need:

- [InfluxDB 2.x](https://docs.influxdata.com/influxdb/v2/)
- [Grafana](https://grafana.com/oss/grafana/)

(The all-in-one demo provides InfluxDB and Grafana for you.)

To proceed with a self-managed deployment, refer to the [Deploying Kasa Collector](Deploying-Kasa-Collector.md) page.
