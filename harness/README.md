# Fake Kasa device harness

A tiny, dependency-free emulator that lets you test Kasa Collector against device models you don't physically own — no hardware required.

`fake_kasa.py` speaks the legacy TP-Link **IOT protocol** (the XOR "autokey" cipher over UDP + TCP on port 9999) faithfully enough that [python-kasa](https://github.com/python-kasa/python-kasa)'s `Discover.discover_single()` and `Device.update()` build a real `IotPlug` and read live energy-meter data from it. The collector then treats it exactly like a physical plug.

## How it's used

The e2e stack (the `e2e` profile of `compose.yml`, driven by `make test-e2e`) runs seven of these, and one SMART strip (`fake_smart.py`, below), on a bridge network, and the collector finds them by broadcast discovery (a Docker bridge floods broadcast); the demo stack names its four via `KASA_COLLECTOR_DEVICE_HOSTS`. Emeter values sway over time so dashboards actually move.

## Configuration (environment)

One image emulates any device; pick the **kind** and model per container:

| Variable                 | Default              | Meaning                                                       |
| ------------------------ | -------------------- | ------------------------------------------------------------- |
| `KASA_FAKE_KIND`         | `plug`               | `plug` (with emeter), `plug_noemeter`, or `strip`             |
| `KASA_FAKE_MODEL`        | per kind             | Reported device model (e.g. HS110(US), HS103(US), HS300(US))  |
| `KASA_FAKE_ALIAS`        | `Fake <MODEL>`       | Friendly device name                                          |
| `KASA_FAKE_MAC`          | `50:C7:BF:00:00:01`  | MAC address                                                   |
| `KASA_FAKE_ID`           | derived from alias   | `deviceId`                                                    |
| `KASA_FAKE_BASE_W`       | `42.0`               | Base power draw (watts); readings sway around this            |
| `KASA_FAKE_OUTLETS`      | `6`                  | Outlet count (strip only); each gets its own emeter           |
| `KASA_FAKE_OUTLET_ALIAS` | `<ALIAS> Outlet <n>` | One name for every outlet (strip only), as a user leaves them |
| `KASA_FAKE_LEGACY_UNITS` | `false`              | `true`: emeter in A / V / W / kWh floats (HS110 hardware v1)  |
| `KASA_FAKE_UNICAST_ONLY` | `false`              | `true`: deaf to broadcast discovery, answers direct queries   |
| `KASA_FAKE_DEAF_AFTER`   | `0`                  | Seconds after which it goes deaf to broadcast (0: never)      |

### Device kinds

- **`plug`** — smart plug WITH energy monitoring (HS110, KP115, KP125, EP10, …). Builds an `IotPlug` with emeter.
- **`plug_noemeter`** — smart plug WITHOUT energy monitoring (HS103, HS105, …). Exercises the collector's "no emeter" path.
- **`strip`** — multi-outlet power strip (HS300) with **per-outlet** energy meters. Builds an `IotStrip` whose children each report independent emeter data via the child-context protocol.

## Run one by hand

```bash
docker build -t fake-kasa ./harness
docker run --rm -e KASA_FAKE_MODEL="KP115(US)" -e KASA_FAKE_ALIAS="Bench Plug" \
  -e KASA_FAKE_BASE_W=88 --network some-bridge fake-kasa
```

## Scope / limitations

- **IOT protocol devices:** emeter plugs, non-emeter plugs, and multi-outlet strips (per-outlet emeter). Enough to exercise discovery, `update()`, and both single-device and child-device emeter collection.
- **SMART protocol:** a SMART power strip over KLAP v2 (`fake_smart.py`): UDP 20002 discovery, the KLAP handshake and its AES-encrypted requests, `multipleRequest`, and `control_child` for six outlets that each measure their own energy. Its AES is implemented in the file, stdlib only, and checked against `cryptography` by `tests/test_smart_strip.py`.
- **Not yet emulated:** SMART devices over the AES transport, and bulbs/dimmers with lighting modules.

## The SMART strip (`fake_smart.py`)

Run with `python3 /fake_smart.py` (the e2e `kasa_fake_p316m` service). It accepts the TP-Link account given by `KASA_FAKE_USERNAME` / `KASA_FAKE_PASSWORD` and refuses any other. `KASA_FAKE_ALIAS`, `KASA_FAKE_MODEL` (default `P316M(US)`), `KASA_FAKE_OUTLETS` (default 6), `KASA_FAKE_BASE_W` (the first outlet's watts, default 20; each next one draws 5 W more) and `KASA_FAKE_HTTP_PORT` (default 80) configure it.
