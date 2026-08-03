# Supported Devices

Kasa Collector reads energy and system data from TP-Link Kasa smart plugs and power strips through the [python-kasa](https://github.com/python-kasa/python-kasa) library. If python-kasa can talk to a device, Kasa Collector generally can too — python-kasa's compatibility list is the ultimate reference for what hardware works.

## Two device families

TP-Link ships two protocol families, and they differ in what setup they need:

- **IOT protocol** (legacy plugs and strips) — discovered and read with no account. Devices with energy monitoring (an "emeter") report power, voltage, current, and cumulative energy out of the box. These work with zero configuration beyond the InfluxDB settings.
- **SMART / KLAP protocol** (newer devices) — require your TP-Link cloud credentials. Set `KASA_COLLECTOR_TPLINK_USERNAME` and `KASA_COLLECTOR_TPLINK_PASSWORD` (see [Configuration](configuration.md#authentication-tp-link)). Without credentials these devices are discovered but cannot be authenticated or polled.

Devices without an energy meter (for example the HS103 plug) are handled cleanly: they are discovered and their system information is collected, but no energy metrics are recorded, and their absence of an emeter is not treated as an error.

## Per-outlet monitoring

Multi-outlet power strips such as the **HS300** expose a separate energy meter per outlet. Kasa Collector records each outlet as its own series, so you can see per-outlet power and energy — not just a strip-wide total — in the Grafana dashboards.

## Tested and known-good models

These have been verified directly:

| Model  | Type        | Energy monitoring | Notes                                                 |
| ------ | ----------- | ----------------- | ----------------------------------------------------- |
| HS110  | Smart plug  | Yes               | IOT protocol.                                         |
| KP115  | Smart plug  | Yes               | IOT protocol.                                         |
| HS300  | Power strip | Yes (per-outlet)  | IOT protocol; each outlet reported separately.        |
| KP125M | Smart plug  | Yes               | SMART/KLAP — requires TP-Link credentials.            |
| HS103  | Smart plug  | No                | IOT protocol; discovered and tracked, no emeter data. |

Other Kasa devices are commonly discovered automatically when they advertise the energy capability. If a device is supported by python-kasa but not listed here, it is worth trying.

## Testing without hardware

Kasa Collector ships a hardware-free end-to-end harness (`make test-e2e`) built on fake device emulators in `harness/fake_kasa.py`, which speak the real IOT protocol over UDP/TCP so python-kasa builds genuine device objects and reads live emeter data.

The emulator already covers every IOT device shape the collector handles, selectable via `KASA_FAKE_KIND`:

- `plug` — a smart plug **with** energy monitoring (e.g. HS110, KP115).
- `plug_noemeter` — a smart plug **without** energy monitoring (e.g. HS103), to exercise the no-emeter path.
- `strip` — an HS300-style multi-outlet strip with **per-outlet emeter** data.

Per-outlet strips are fully emulated today — they are not future work. See [Testing](testing.md) for how to run the harness.

## Compatibility reference

The underlying library is python-kasa `^0.10.2`. For the authoritative and continually updated list of supported models and protocols, consult the [python-kasa supported devices documentation](https://github.com/python-kasa/python-kasa).
