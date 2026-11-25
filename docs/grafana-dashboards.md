# Grafana Dashboards

Kasa Collector ships five prebuilt Grafana dashboards. They query InfluxDB using **InfluxQL** and are versioned in the repository under two directories:

- [`grafana/shared-local/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-local) — auto-provisioned by the bundled demo, local and dev stacks, and the set to import into your own Grafana.
- [`grafana/shared-external/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-external) — the same dashboards packaged with Grafana's `__inputs`/`__requires` import metadata for publishing to grafana.com and sharing outside this repo.

For most people the `shared-local` set is the one to use. Both sets carry a `data_source` template variable: `shared-external` asks for the datasource when you import it, and with `shared-local` you pick it from the dashboard's **Data Source** dropdown after importing.

## Getting the dashboards

### Bundled demo, local or dev stack (auto-provisioned)

If you start Kasa Collector with the demo stack (`make demo-up`, fake devices) or the local stack (`make local-up`, your real devices), Grafana comes up already provisioned with the datasource and all five dashboards — open **http://localhost:3000** (`admin`, with `admin` for the demo or your `GRAFANA_PASSWORD` for the local stack), nothing to import. Provisioning is wired up by [`grafana/provisioning/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/provisioning): the datasource is pinned to uid **`uDxwFcOGz`** in InfluxQL mode, signing in to InfluxDB 2.x's v1-compatibility API as the read-only v1 user `grafana` (password `GRAFANA_INFLUX_PASSWORD`, created by `ops/influxdb/init-dbrp.sh` on InfluxDB's first start), and the dashboards load from `grafana/shared-local`. Grafana never holds the InfluxDB operator token.

### Bring your own Grafana (import the JSON)

If you run your own Grafana, import the JSON files from [`grafana/shared-local/`](https://github.com/luxardolabs/kasa-collector/tree/main/grafana/shared-local):

1. In Grafana, go to **Dashboards → New → Import**.
1. Upload one of the `kasa_collector-*.json` files (or paste its contents).
1. Pick your **InfluxDB (InfluxQL)** datasource: Grafana prompts for it with a `shared-external` file; with a `shared-local` file, choose it in the dashboard's **Data Source** dropdown after import.
1. Repeat for each dashboard.

The dashboards only render if your datasource is an **InfluxDB datasource in InfluxQL mode**. On InfluxDB 2.x that also requires a **v1 DBRP mapping** so the InfluxQL query layer can resolve your bucket — the bundled stack does this automatically, but on your own server you create it once. See [Using your own external InfluxDB 2.x](deployment.md#using-your-own-external-influxdb-2x) in the deployment guide, and [troubleshooting.md](troubleshooting.md) if panels come up empty.

## Available dashboards

Each dashboard has a stable uid (`luxardolabs_kasa_01` through `luxardolabs_kasa_05`).

### Energy (By Device) — `luxardolabs_kasa_01`

Energy panels organized per device, with device/plug filters:

- Power, Watt-Hours, Current, Voltage
- Combined totals and voltage averages, at both the device and per-plug (outlet) level

### Energy (By Measurement) — `luxardolabs_kasa_02`

The same metrics grouped by measurement rather than by device — power, watt-hours, current, and voltage across devices and plugs, plus combined totals.

### Energy (By Time) — `luxardolabs_kasa_03`

Consumption and cost over time. The price per kWh is the dashboard's own `cost` variable (default `0.1181`), and `tz` sets the timezone the days are counted in:

- Watt-hours per device per day and per-plug energy usage
- Estimated daily device and plug costs
- Multi-day trend monitoring

Per-device panels read only each device's own point (`equipment_type = 'device'`), so a power strip counts once, at its aggregate, never blended with its outlets. Per-plug panels draw one line per outlet (grouped by the strip's `device_id` and the outlet's `plug_id`, labelled by its name), so two outlets that share a name are shown separately, never averaged together.

### Device Details — `luxardolabs_kasa_04`

An inventory-style overview of connected devices and plugs: state (on/off), software/firmware versions, model and device names, network connectivity, and real-time signal strength (RSSI). Its `tz` variable sets the displayed timezone.

### Status — `luxardolabs_kasa_05`

At-a-glance real-time monitoring — combined power, watt-hours, current, and voltage across everything the collector sees — plus a **Collector Health** row from the `collector_stats` measurement: Devices Polled, Succeeded, Poll Failed, Write Failed and Cycle Duration. A non-zero Poll Failed or Write Failed is where to start when a device's panels go quiet.

## See also

- [deployment.md](deployment.md) — running the collector and configuring your own InfluxDB 2.x for InfluxQL
- [configuration.md](configuration.md) — collector environment variables (the By Time dashboard's price per kWh is its own `cost` variable, not a collector setting)
- [troubleshooting.md](troubleshooting.md) — empty panels, datasource, and DBRP issues
