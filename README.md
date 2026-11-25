# Kasa Collector

![Kasa Collector](docs/images/kasa_collector_header.png)

Kasa Collector is an async Python service that discovers TP-Link Kasa smart plugs and power strips on your network, polls their energy and system data, and writes it to InfluxDB for visualization in Grafana. It runs as a single Docker container, finds devices automatically, and ships with ready-made dashboards.

See it in action: a live set of dashboards powered by this collector is [available to explore here](https://www.luxardolabs.com/).

License: AGPL-3.0-only.

## Quick Start

Want to see it working first, with no hardware? Clone the repo and run the demo stack — it bundles a pre-provisioned InfluxDB and Grafana driven by fake Kasa devices, so the dashboards populate immediately:

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up          # then open http://localhost:3000 (admin/admin)
```

Ready to plug into your own InfluxDB and Grafana? Point a single container at your existing stack. Host networking is required for broadcast discovery of devices on your LAN.

```yaml
services:
  kasa-collector:
    # Pin a release (see the Releases page) so you know which bits you run.
    image: ghcr.io/luxardolabs/kasa-collector:2026.11.1
    container_name: kasa-collector
    network_mode: host
    restart: unless-stopped
    environment:
      # Required — InfluxDB 2.x
      KASA_COLLECTOR_INFLUXDB_URL: http://influxdb:8086
      KASA_COLLECTOR_INFLUXDB_TOKEN: your-token-here
      KASA_COLLECTOR_INFLUXDB_ORG: your-org
      KASA_COLLECTOR_INFLUXDB_BUCKET: kasa

      # Optional — required only for newer SMART/KLAP devices
      # KASA_COLLECTOR_TPLINK_USERNAME: your-email@example.com
      # KASA_COLLECTOR_TPLINK_PASSWORD: your-password
    volumes:
      # The roster of devices found (known_devices.json), kept across container recreates
      - kasa_collector_output:/app/output

volumes:
  kasa_collector_output:
```

See [Getting Started](docs/getting-started.md) for the full walkthrough and [Configuration](docs/configuration.md) for every setting.

## The four stacks

Everything is driven by `make`. There is one `compose.yml`; the stack is a compose **profile** and the environment is the `.env.<env>` file. **Compose never builds**: the stacks run the published collector image by a pinned tag. The demo builds only its fake-device emulator locally, and `make test-e2e` builds the collector from source, so none of them needs a registry of your own.

| Stack              | Command         | What it does                                                                    |
| ------------------ | --------------- | ------------------------------------------------------------------------------- |
| **demo**           | `make demo-up`  | Fake emulated devices + bundled InfluxDB + Grafana — watch it work, no hardware |
| **local**          | `make local-up` | Your real devices (host networking) + bundled InfluxDB + Grafana                |
| **collector-only** | `make up`       | Just the collector, pointed at your own external InfluxDB + Grafana             |
| **test**           | `make test-e2e` | Hardware-free end-to-end test — fakes → collector → ephemeral InfluxDB          |

The demo and local stacks serve Grafana at http://localhost:3000 (`admin`, with `admin` for the demo or your `GRAFANA_PASSWORD` for the local stack) — set `GRAFANA_PORT`/`INFLUX_PORT` in `.env.demo` / `.env.local` if another service already owns those ports. The maintainers' own dev stack (`make dev-up`) runs on their dev host and is reached by name, not a port. See [Deployment](docs/deployment.md) for production.

## Features

- **Automatic discovery** — finds Kasa devices via network broadcast; manual/cross-subnet hosts supported too
- **Per-outlet monitoring** — individual emeter data for each outlet on HS300-style IOT strips and SMART strips such as the P316M
- **Energy + system metrics** — power, current, voltage, and cumulative consumption every 15s; system info every 60s
- **Async InfluxDB writes** — one awaited write per device (a strip's points together) each poll cycle, over aiohttp
- **Authentication** — works with newer SMART/KLAP devices requiring TP-Link account credentials
- **Grafana dashboards** — pre-built and auto-provisioned in the demo, local and dev stacks
- **Docker healthcheck** — `python -m app.health.check`, no web server required
- **Graceful shutdown** — comprehensive resource and transport cleanup for long-running deployments
- **Multi-arch** — published for amd64 and arm64

## Documentation

- **[Getting Started](docs/getting-started.md)** — the three ways to run it, from zero to dashboards
- **[Configuration](docs/configuration.md)** — every environment variable and default
- **[Supported Devices](docs/supported-devices.md)** — compatible plugs, strips, and protocols
- **[Grafana Dashboards](docs/grafana-dashboards.md)** — what ships and how to import it
- **[How It Works](docs/how-it-works.md)** — architecture, polling model, and data flow
- **[Deployment](docs/deployment.md)** — production Docker Compose, Kubernetes, and remote deploys
- **[Troubleshooting](docs/troubleshooting.md)** — discovery, auth, InfluxDB, and timezone fixes
- **[Testing](docs/testing.md)** — unit tests, lint, and the hardware-free e2e harness

## Contributing

Issues and pull requests are welcome. The full local check runs in Docker (no host Python required):

```bash
make check    # guard pin check, then lint + mypy + test + arch + audit + gitleaks secret scan
make hooks    # install the git hooks that run the secret scan on commit/push
```

`make check`'s guard legs (the pin check, lint, mypy, arch and audit) pull the maintainers' private guard images, which a `Makefile.local` points at (see `Makefile.local.example`). Without one, lint and mypy are skipped and the pin check fails, so an outside contributor's check is `make test` and `make test-e2e`.

See [Testing](docs/testing.md) for the individual targets.

## License

Licensed under the AGPL-3.0-only license. See [LICENSE](LICENSE).

## Support

Questions or bugs? Please [open an issue](https://github.com/luxardolabs/kasa-collector/issues).

______________________________________________________________________

This project is not affiliated with TP-Link or Kasa. It is an independent tool for monitoring the energy consumption of Kasa smart devices.
