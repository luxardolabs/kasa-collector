# Fake Kasa device harness

A tiny, dependency-free emulator that lets you test Kasa Collector against device
models you don't physically own — no hardware required.

`fake_kasa.py` speaks the legacy TP-Link **IOT protocol** (the XOR "autokey" cipher over
UDP + TCP on port 9999) faithfully enough that [python-kasa](https://github.com/python-kasa/python-kasa)'s
`Discover.discover_single()` and `Device.update()` build a real `IotPlug` and read live
energy-meter data from it. The collector then treats it exactly like a physical plug.

## How it's used

The e2e stack (`compose.e2e.yml`, driven by `make test-e2e`) runs a couple of these on a
bridge network and points the collector at them via `KASA_COLLECTOR_DEVICE_HOSTS`. Emeter
values sway over time so dashboards actually move.

## Configuration (environment)

One image emulates any device; pick the **kind** and model per container:

| Variable | Default | Meaning |
|----------|---------|---------|
| `KASA_FAKE_KIND`    | `plug` | `plug` (with emeter), `plug_noemeter`, or `strip` |
| `KASA_FAKE_MODEL`   | per kind | Reported device model (e.g. HS110(US), HS103(US), HS300(US)) |
| `KASA_FAKE_ALIAS`   | `Fake <MODEL>` | Friendly device name |
| `KASA_FAKE_MAC`     | `50:C7:BF:00:00:01` | MAC address |
| `KASA_FAKE_ID`      | derived from alias | `deviceId` |
| `KASA_FAKE_BASE_W`  | `42.0` | Base power draw (watts); readings sway around this |
| `KASA_FAKE_OUTLETS` | `6` | Outlet count (strip only); each gets its own emeter |

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

- **IOT protocol devices:** emeter plugs, non-emeter plugs, and multi-outlet strips
  (per-outlet emeter). Enough to exercise discovery, `update()`, and both single-device
  and child-device emeter collection.
- **Not yet emulated:** the newer **SMART / KLAP** devices (AES handshake) and bulbs/
  dimmers with lighting modules. Possible future extensions.
