# Roadmap

See the open issues on GitHub for a list of proposed features and known issues:

[GitHub Issues](https://github.com/luxardolabs/kasa-collector/issues)

## Testing

A hardware-free end-to-end test harness (`make test-e2e`) already exists. It uses
fake Kasa device emulators (`harness/fake_kasa.py`) so the full pipeline can be
tested without physical hardware. See [docs/TESTING.md](../TESTING.md).

The harness currently emulates IOT plugs (HS110/KP115/etc.). Extending it to cover
power strips (HS300) and SMART/KLAP devices is a possible future enhancement.