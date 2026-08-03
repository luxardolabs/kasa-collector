"""Fake Kasa (IOT-protocol) device emulator for the e2e test harness.

Speaks the legacy TP-Link IOT protocol (XOR "autokey" cipher over UDP + TCP 9999)
well enough that python-kasa's `Discover.discover_single()` + `Device.update()`
build a real device and read live energy-meter data — so the collector can be
tested end-to-end against device types you don't physically own, no hardware.

One image emulates any device; configure via environment:
    KASA_FAKE_KIND   plug | plug_noemeter | strip   (default plug)
    KASA_FAKE_MODEL  device model         (default depends on kind)
    KASA_FAKE_ALIAS  friendly name        (default "Fake <MODEL>")
    KASA_FAKE_ID     deviceId             (default derived from alias)
    KASA_FAKE_MAC    MAC address          (default 50:C7:BF:00:00:01)
    KASA_FAKE_BASE_W base power in watts   (default 42.0)
    KASA_FAKE_OUTLETS strip outlet count   (default 6; strip only)

Device kinds:
    plug           — smart plug WITH energy monitoring (e.g. HS110, KP115)
    plug_noemeter  — smart plug WITHOUT energy monitoring (e.g. HS103)
    strip          — multi-outlet power strip, per-outlet emeter (e.g. HS300)

Pure stdlib — no dependencies. Not part of the app package; test tooling only.
"""

import asyncio
import json
import math
import os
import random
import struct
import time

KEY0 = 0xAB
PORT = 9999


def encrypt(s: str) -> bytes:
    key = KEY0
    out = bytearray()
    for c in s.encode():
        key ^= c
        out.append(key)
    return bytes(out)


def decrypt(data: bytes) -> str:
    key = KEY0
    out = bytearray()
    for c in data:
        out.append(key ^ c)
        key = c
    return out.decode(errors="replace")


KIND = os.getenv("KASA_FAKE_KIND", "plug")
_DEFAULT_MODEL = {"plug": "HS110(US)", "plug_noemeter": "HS103(US)", "strip": "HS300(US)"}
MODEL = os.getenv("KASA_FAKE_MODEL", _DEFAULT_MODEL.get(KIND, "HS110(US)"))
ALIAS = os.getenv("KASA_FAKE_ALIAS", f"Fake {MODEL}")
DEVICE_ID = os.getenv("KASA_FAKE_ID", "8006" + "".join(f"{ord(c):02X}" for c in ALIAS)[:20])
MAC = os.getenv("KASA_FAKE_MAC", "50:C7:BF:00:00:01")
BASE_W = float(os.getenv("KASA_FAKE_BASE_W", "42.0"))
OUTLETS = int(os.getenv("KASA_FAKE_OUTLETS", "6"))

HAS_EMETER = KIND in ("plug", "strip")
IS_STRIP = KIND == "strip"

# Per-emeter live state (keyed by child id, or "" for the top-level device).
_start = time.time()
_totals: dict[str, float] = {}


def _emeter_realtime(key: str, base_w: float) -> dict:
    t = time.time() - _start
    # Deterministic-ish base + slow sway + jitter; unique phase per key.
    phase = (hash(key) % 100) / 100.0 * math.tau
    power_w = max(0.5, base_w + base_w * 0.25 * math.sin(t / 30.0 + phase) + random.uniform(-2, 2))
    voltage_v = 120.0 + random.uniform(-0.8, 0.8)
    current_a = power_w / voltage_v
    _totals[key] = _totals.get(key, 1000.0) + power_w / 3600.0
    return {
        "voltage_mv": int(voltage_v * 1000),
        "current_ma": int(current_a * 1000),
        "power_mw": int(power_w * 1000),
        "total_wh": int(_totals[key]),
        "err_code": 0,
    }


def _children() -> list:
    out = []
    for i in range(OUTLETS):
        out.append({
            "id": f"{DEVICE_ID}{i:02d}",
            "state": 1,
            "alias": f"{ALIAS} Outlet {i + 1}",
            "on_time": 3600 + i * 60,
            "next_action": {"type": -1},
        })
    return out


def sysinfo() -> dict:
    info = {
        "sw_ver": "1.2.5 Build 171213 Rel.101523",
        "hw_ver": "1.0",
        "type": "IOT.SMARTPLUGSWITCH",
        "model": MODEL,
        "mac": MAC,
        "deviceId": DEVICE_ID,
        "hwId": "FAKE0000000000000000000000000001",
        "fwId": "FAKE0000000000000000000000000001",
        "oemId": "FAKE0000000000000000000000000001",
        "alias": ALIAS,
        "dev_name": "Wi-Fi Smart Device (Fake)",
        "icon_hash": "",
        "active_mode": "none",
        "feature": "TIM:ENE" if HAS_EMETER else "TIM",
        "updating": 0,
        "rssi": -45,
        "led_off": 0,
        "latitude": 0,
        "longitude": 0,
        "err_code": 0,
    }
    if IS_STRIP:
        info["children"] = _children()
        info["child_num"] = OUTLETS
    else:
        info["relay_state"] = 1
        info["on_time"] = 3600
    return info


def _child_base_w(child_id: str) -> float:
    # Vary base load per outlet so the dashboards show distinct series.
    try:
        idx = int(child_id[-2:])
    except ValueError:
        idx = 0
    return BASE_W * (0.5 + 0.3 * idx)


def handle(query: dict) -> dict:
    """Build a response mirroring the request's module/command structure."""
    child_ids = query.get("context", {}).get("child_ids") or []
    resp: dict = {}
    for mod, cmds in query.items():
        if mod == "context":
            continue
        resp[mod] = {}
        for cmd in cmds:
            if mod == "system" and cmd == "get_sysinfo":
                resp[mod][cmd] = sysinfo()
            elif mod == "emeter" and cmd == "get_realtime":
                if not HAS_EMETER:
                    resp[mod][cmd] = {"err_code": -1, "err_msg": "module not support"}
                elif child_ids:
                    cid = child_ids[0]
                    resp[mod][cmd] = _emeter_realtime(cid, _child_base_w(cid))
                else:
                    resp[mod][cmd] = _emeter_realtime("", BASE_W)
            elif mod == "emeter" and cmd == "get_daystat":
                resp[mod][cmd] = {"day_list": [], "err_code": 0}
            elif mod == "emeter" and cmd == "get_monthstat":
                resp[mod][cmd] = {"month_list": [], "err_code": 0}
            elif mod == "time" and cmd == "get_time":
                lt = time.localtime()
                resp[mod][cmd] = {
                    "year": lt.tm_year, "month": lt.tm_mon, "mday": lt.tm_mday,
                    "hour": lt.tm_hour, "min": lt.tm_min, "sec": lt.tm_sec,
                    "err_code": 0,
                }
            elif mod == "time" and cmd == "get_timezone":
                # index 13 -> America/Chicago in python-kasa's table (any resolvable ok)
                resp[mod][cmd] = {"index": 13, "err_code": 0}
            else:
                resp[mod][cmd] = {"err_code": -1, "err_msg": "module not support"}
    return resp


class UDPProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        try:
            query = json.loads(decrypt(data))
        except Exception:
            return
        self.transport.sendto(encrypt(json.dumps(handle(query))), addr)


async def tcp_handler(reader, writer):
    try:
        while True:
            header = await reader.readexactly(4)
            (length,) = struct.unpack(">I", header)
            body = await reader.readexactly(length)
            query = json.loads(decrypt(body))
            enc = encrypt(json.dumps(handle(query)))
            writer.write(struct.pack(">I", len(enc)) + enc)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(UDPProtocol, local_addr=("0.0.0.0", PORT))
    server = await asyncio.start_server(tcp_handler, "0.0.0.0", PORT)
    extra = f", {OUTLETS} outlets" if IS_STRIP else ""
    print(f"fake-kasa: {ALIAS} ({MODEL}, kind={KIND}{extra}) on UDP+TCP :{PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
