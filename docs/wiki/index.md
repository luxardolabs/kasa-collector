# Kasa Collector Wiki

This directory contains the documentation imported from the [Kasa Collector GitHub Wiki](https://github.com/luxardolabs/kasa-collector/wiki).

## Quick Start

The fastest way to try Kasa Collector is the all-in-one demo, which bundles the collector with its own InfluxDB and a pre-provisioned Grafana, driven by **fake** emulated devices so the dashboards populate with no hardware:

```bash
git clone https://github.com/luxardolabs/kasa-collector.git
cd kasa-collector
make demo-up
```

Then open **http://localhost:3000** (admin / admin). To run the same bundled stack against your real devices use `make dev-up`, or `make up` for collector-only against your own InfluxDB. See [Getting Started](Getting-Started.md) for details.

## Table of Contents

- [Getting Started](Getting-Started.md) - Prerequisites and quick start guide
- [Deploying Kasa Collector](Deploying-Kasa-Collector.md) - Docker deployment instructions
- [Environmental Flags](Environmental-Flags.md) - Configuration options and environment variables
- [How It Works](How-It-Works.md) - Technical explanation of the collector
- [Supported Devices](Supported-Devices.md) - List of tested Kasa devices
- [Grafana Dashboards](Grafana-Dashboards.md) - Available visualization dashboards
- [Troubleshooting](Troubleshooting.md) - Common issues and solutions
- [FAQ](FAQ.md) - Frequently asked questions
- [Roadmap](Roadmap.md) - Future development plans
- [Contact](Contact.md) - How to reach the maintainer

## Updating the Wiki

To update these docs:

1. Edit the markdown files directly
1. Commit changes to the repository
1. Optionally sync back to GitHub wiki if needed

## Contributing

Feel free to submit pull requests to improve the documentation!
