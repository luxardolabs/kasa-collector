# Deploying Kasa Collector

You can deploy Kasa Collector using Docker. It runs as one of four stacks — all build the collector image locally and tear up/down. Pick the path that fits.

The image is published to GitHub Container Registry as `ghcr.io/luxardolabs/kasa-collector` (public).

## Demo — collector + InfluxDB + Grafana, no hardware

The quickest way to get running. This bundles the collector with its own InfluxDB and a pre-provisioned Grafana (datasource plus all dashboards), driven by **fake** emulated Kasa devices so the dashboards populate with no hardware:

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up
```

Then open **http://localhost:3000** (admin / admin). Stop with `make demo-down`, or `make demo-clean` to also drop the data volumes. If ports 3000 / 8086 are taken, set `GRAFANA_PORT` / `INFLUX_PORT` in `.env.demo`. This path uses `compose.demo.yml`.

## Dev — the same bundled stack against your real devices

To run that same bundled InfluxDB + Grafana against **your real** Kasa devices (host networking + broadcast discovery) instead of fakes, use `make dev-up` (uses `compose.dev.yml`). Open **http://localhost:3000** (admin / admin); stop with `make dev-down` or `make dev-clean`.

## Collector-only — bring your own InfluxDB / Grafana

If you already run InfluxDB 2.x and Grafana, run just the collector and point it at your InfluxDB via the `KASA_COLLECTOR_INFLUXDB_*` variables. Edit `.env.dev` and run `make up` (uses `compose.yml`), or roll your own Compose / `docker run` using the options below.

## Docker Compose

Create a `compose.yml` file:

```yaml
services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:latest
    container_name: kasa-collector
    network_mode: host
    restart: unless-stopped
    environment:
      # Required - InfluxDB Configuration
      KASA_COLLECTOR_INFLUXDB_URL: http://influxdb:8086
      KASA_COLLECTOR_INFLUXDB_TOKEN: your-token-here
      KASA_COLLECTOR_INFLUXDB_ORG: your-org
      KASA_COLLECTOR_INFLUXDB_BUCKET: kasa
      
      # Optional - For newer devices requiring authentication
      # KASA_COLLECTOR_TPLINK_USERNAME: your-email@example.com
      # KASA_COLLECTOR_TPLINK_PASSWORD: your-password
      
      # Optional - Manual device configuration (disables auto-discovery)
      # KASA_COLLECTOR_DEVICE_HOSTS: "192.168.1.100,192.168.1.101"
      # KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY: "false"
      
      # Optional - Timezone
      TZ: America/Chicago
```

Then deploy with:

```bash
docker compose up -d
```

## Docker Run

Alternatively, you can use this `docker run` command:

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  -e KASA_COLLECTOR_INFLUXDB_URL=http://influxdb:8086 \
  -e KASA_COLLECTOR_INFLUXDB_TOKEN=your-token-here \
  -e KASA_COLLECTOR_INFLUXDB_ORG=your-org \
  -e KASA_COLLECTOR_INFLUXDB_BUCKET=kasa \
  -e TZ=America/Chicago \
  ghcr.io/luxardolabs/kasa-collector:latest
```
