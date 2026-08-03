# Kasa Collector

![Kasa Collector](docs/images/kasa_collector_header.png)

**Kasa Collector** is a Python-based application deployed with Docker that discovers and monitors TP-Link Kasa smart plugs and power strips on your network. It continuously collects energy consumption data and stores it in InfluxDB for visualization with Grafana dashboards.

A live set of dashboards using this Collector [are available here](https://www.luxardolabs.com/) for you to explore.

## Quick Start

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
```

Want to see it working first, with no hardware? `make demo-up` runs the collector with a bundled, pre-provisioned InfluxDB + Grafana driven by fake devices. The collector ships as four run stacks — **demo** (fake devices), **dev** (your real devices + bundled InfluxDB/Grafana), **collector-only** (plug into your own InfluxDB/Grafana), and **test** (hardware-free end-to-end) — all built locally with `make`. See [Getting Started](docs/wiki/Getting-Started.md).

## Documentation

Full documentation is available in the [docs/wiki](docs/wiki) directory:

- **[Getting Started](docs/wiki/Getting-Started.md)** - Initial setup guide
- **[Configuration](docs/wiki/Environmental-Flags.md)** - All environment variables
- **[Supported Devices](docs/wiki/Supported-Devices.md)** - Compatible Kasa devices
- **[Grafana Dashboards](docs/wiki/Grafana-Dashboards.md)** - Visualization setup
- **[Troubleshooting](docs/wiki/Troubleshooting.md)** - Common issues and solutions
- **[FAQ](docs/wiki/FAQ.md)** - Frequently asked questions
- **[How It Works](docs/wiki/How-It-Works.md)** - Technical details
- **[Testing](docs/TESTING.md)** - Unit tests, lint, and the hardware-free e2e harness

## Features

- Automatic device discovery
- Energy monitoring (power, current, voltage, consumption)
- Smart power strip support with individual outlet monitoring
- Docker health checks
- Grafana dashboards included
- Production-ready with graceful shutdown

## License

This project is licensed under the AGPL-3.0-only license - see the [LICENSE](LICENSE) file for details.

## Support

Questions or issues? Please [open an issue](https://github.com/luxardolabs/kasa-collector/issues) on the [project repository](https://github.com/luxardolabs/kasa-collector).

---

**Note**: This project is not affiliated with TP-Link or Kasa. It's an independent tool for monitoring energy consumption of Kasa smart devices.
