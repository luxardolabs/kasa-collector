# Grafana Dashboards

Kasa Collector ships with five prebuilt Grafana dashboards. They query InfluxDB using **InfluxQL** and are versioned in the repository under:

- [`grafana/shared-local/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-local) — auto-provisioned by the demo and dev stacks, and for importing into your own Grafana.
- [`grafana/shared-external/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-external) — the same dashboards packaged for sharing/publishing.

The dashboards use the uids `luxardolabs_kasa_01` through `luxardolabs_kasa_05`.

## Getting the Dashboards

### Demo or dev stack (auto-provisioned)

If you started Kasa Collector with the demo stack (`make demo-up`, fake devices) or the dev stack (`make dev-up`, your real devices), Grafana is pre-provisioned with the datasource and all five dashboards. Just open **http://localhost:3000** (admin / admin) — nothing to import.

### Bring your own Grafana (import the JSON)

If you run your own Grafana, import the JSON files from [`grafana/shared-local/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-local):

1. In Grafana, go to **Dashboards → New → Import**.
2. Upload one of the `kasa_collector-*.json` files (or paste its contents).
3. Select your InfluxDB datasource when prompted.
4. Repeat for each dashboard.

## Available Dashboards

### Energy (By Device) — `luxardolabs_kasa_01`

Energy panels organized per device:
- Power
- Watt-Hours
- Current
- Voltage

Measurements include total combined information, voltage average, device- and plug-level details, and filtering options for devices and plugs.

### Energy (By Measurement) — `luxardolabs_kasa_02`

Detailed insights grouped by measurement:
- Power
- Watt-hours
- Current
- Voltage for devices and plugs
- Combined metrics
- Comparative charts
- RSSI signal strength tracking

### Energy (By Time) — `luxardolabs_kasa_03`

Summarizes energy consumption and costs over time:
- Watt-hours per device/day
- Plug-level energy usage
- Estimated daily device and plug costs
- Trend monitoring across multiple days

### Device Details — `luxardolabs_kasa_04`

An overview of connected smart devices and plugs, focusing on:
- Device state
- Software/firmware versions
- Network connectivity
- Device names and models
- On/off status
- Individual plug states
- Real-time signal strength tracking

### Status — `luxardolabs_kasa_05`

Real-time power consumption monitoring:
- Combined metrics for power, watt-hours, current, and voltage
