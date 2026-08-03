# How It Works

Kasa Collector is designed to automate data collection from Kasa Smart Plugs. It offers two modes of device configuration:

## Automatic Device Discovery

Kasa Collector automatically discovers compatible Kasa devices on your network. By default, it sends discovery packets regularly and identifies devices that support energy monitoring.

Control automatic discovery using the `KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY` environment variable:
- **Enable Auto-Discovery:** Set to `true`
- **Disable Auto-Discovery:** Set to `false`

## Manual Device Configuration

For devices not automatically discovered, manually specify device IPs or hostnames using `KASA_COLLECTOR_DEVICE_HOSTS`. This variable accepts a comma-separated list of device IPs/hostnames.

**Example:** `KASA_COLLECTOR_DEVICE_HOSTS="10.50.0.101,10.50.0.102"`

## TP-Link Account Configuration

For Kasa devices requiring TP-Link account authentication, provide credentials using:
- `KASA_COLLECTOR_TPLINK_USERNAME`
- `KASA_COLLECTOR_TPLINK_PASSWORD`

These credentials enable control of TP-Link cloud-authenticated devices.

## Data Storage and Networking

Collected energy metrics are written to **InfluxDB 2.x**, which Grafana then
visualizes. Because Kasa auto-discovery relies on UDP broadcast, the collector
container runs with host networking. If host networking is not an option, or your
devices live on a different subnet, use `KASA_COLLECTOR_DEVICE_HOSTS` to point the
collector at devices explicitly instead of relying on discovery.

## Application Architecture

The Python code is organized as an `app/` package:

- `app/core` - configuration and shared infrastructure
- `app/collector` - device discovery, communication, and polling
- `app/storage` - InfluxDB persistence
- `app/health` - the Docker health check

The container entrypoint is `python -m app.main`, the working directory is `/app`,
and optional JSON output is written to `/app/output`.

## Testing Without Hardware

You can exercise the full pipeline without any physical Kasa devices using the
hardware-free end-to-end harness (`make test-e2e`), which runs fake Kasa device
emulators (`harness/fake_kasa.py`, IOT protocol) against the collector and an
ephemeral InfluxDB. See [docs/TESTING.md](../TESTING.md) for details.

For a complete list of environment variables, refer to the [Environmental Flags](Environmental-Flags.md) page.