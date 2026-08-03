# Supported Devices

The Kasa Collector currently supports collecting data from the following Kasa devices:

- [KP115](https://www.kasasmart.com/us/products/smart-plugs/kasa-smart-plug-slim-energy-monitoring-kp115)
- [HS300](https://www.kasasmart.com/us/products/smart-plugs/kasa-smart-wi-fi-power-strip-hs300)
- [KP125M](https://www.tp-link.com/us/home-networking/smart-plug/kp125m/)

These devices have been tested personally, and others may be supported based on the "energy" tag found during device discovery.

For more information, refer to the [python-kasa project](https://github.com/python-kasa/python-kasa) for a list of supported devices.

## Testing Without Hardware

A hardware-free test harness (`make test-e2e`) uses fake Kasa device emulators (`harness/fake_kasa.py`) to exercise the collector without any physical devices. The harness currently emulates IOT plugs (HS110/KP115/etc.) over the real IOT protocol; power strips (HS300) and SMART/KLAP devices are a possible future extension. See [docs/TESTING.md](../TESTING.md) for details.
