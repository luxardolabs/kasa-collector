"""SMART-protocol fake device over KLAP v2, for the hardware-free e2e stack.

A Tapo/Kasa SMART power strip (default: P316M, six outlets with per-outlet energy
monitoring) as python-kasa 0.11 talks to it:

- discovery on UDP 20002: a 16-byte header and the device's JSON discovery result,
  advertising KLAP with login version 2;
- KLAP v2 on HTTP: ``/app/handshake1``, ``/app/handshake2`` and ``/app/request?seq=N``,
  each request and response AES-128-CBC encrypted and signed with the session's keys;
- the SMART JSON methods the collector's poll reaches (``component_nego``,
  ``get_device_info``, ``get_child_device_list``, the energy methods), single or inside
  ``multipleRequest``, and ``control_child`` for the outlets.

Every outlet draws its own power, so an e2e run can tell their series apart.

Standard library only, like ``fake_kasa``: AES is implemented here. It is a test
fixture, never a cipher to protect anything.

Environment:
    KASA_FAKE_ALIAS     strip name               (default "Fake P316M")
    KASA_FAKE_MODEL     model                    (default "P316M(US)")
    KASA_FAKE_OUTLETS   outlet count             (default 6)
    KASA_FAKE_BASE_W    first outlet's watts     (default 20.0; each next one +5 W)
    KASA_FAKE_USERNAME  TP-Link account the device accepts
    KASA_FAKE_PASSWORD  its password
    KASA_FAKE_HTTP_PORT HTTP port                (default 80)
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import time
from typing import Any

# --------------------------------------------------------------------- AES-128-CBC

_SBOX = bytearray(256)
_INV_SBOX = bytearray(256)


def _build_sboxes() -> None:
    p = q = 1
    while True:
        # p: multiply by 3 in GF(2^8); q: divide by 3.
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4)
        _SBOX[p] = x ^ 0x63
        if p == 1:
            break
    _SBOX[0] = 0x63
    for i, v in enumerate(_SBOX):
        _INV_SBOX[v] = i


def _rotl8(x: int, shift: int) -> int:
    return ((x << shift) | (x >> (8 - shift))) & 0xFF


def _xtime(a: int) -> int:
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a: int, b: int) -> int:
    out = 0
    while b:
        if b & 1:
            out ^= a
        a = _xtime(a)
        b >>= 1
    return out


_build_sboxes()


def _expand_key(key: bytes) -> list[list[int]]:
    words = [list(key[i : i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        word = list(words[i - 1])
        if i % 4 == 0:
            word = word[1:] + word[:1]
            word = [_SBOX[b] for b in word]
            word[0] ^= rcon
            rcon = _xtime(rcon)
        words.append([a ^ b for a, b in zip(words[i - 4], word, strict=True)])
    return [sum(words[r * 4 : r * 4 + 4], []) for r in range(11)]


def _add(state: list[int], round_key: list[int]) -> list[int]:
    return [a ^ b for a, b in zip(state, round_key, strict=True)]


def _shift_rows(s: list[int], inverse: bool = False) -> list[int]:
    out = [0] * 16
    for col in range(4):
        for row in range(4):
            src = (col + row) % 4 if not inverse else (col - row) % 4
            out[col * 4 + row] = s[src * 4 + row]
    return out


def _mix(s: list[int], m: tuple[int, int, int, int]) -> list[int]:
    out = []
    for col in range(4):
        c = s[col * 4 : col * 4 + 4]
        for row in range(4):
            out.append(
                _mul(c[0], m[(0 - row) % 4])
                ^ _mul(c[1], m[(1 - row) % 4])
                ^ _mul(c[2], m[(2 - row) % 4])
                ^ _mul(c[3], m[(3 - row) % 4])
            )
    return out


def _encrypt_block(block: bytes, keys: list[list[int]]) -> bytes:
    s = _add(list(block), keys[0])
    for r in range(1, 10):
        s = _mix(_shift_rows([_SBOX[b] for b in s]), (2, 3, 1, 1))
        s = _add(s, keys[r])
    s = _add(_shift_rows([_SBOX[b] for b in s]), keys[10])
    return bytes(s)


def _decrypt_block(block: bytes, keys: list[list[int]]) -> bytes:
    s = _add(list(block), keys[10])
    for r in range(9, 0, -1):
        s = [_INV_SBOX[b] for b in _shift_rows(s, inverse=True)]
        s = _mix(_add(s, keys[r]), (14, 11, 13, 9))
    s = [_INV_SBOX[b] for b in _shift_rows(s, inverse=True)]
    return bytes(_add(s, keys[0]))


def aes_cbc_encrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    keys = _expand_key(key)
    pad = 16 - len(data) % 16
    data += bytes([pad]) * pad
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        prev = _encrypt_block(
            bytes(a ^ b for a, b in zip(data[i : i + 16], prev)), keys
        )
        out += prev
    return bytes(out)


def aes_cbc_decrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    keys = _expand_key(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        block = data[i : i + 16]
        out += bytes(a ^ b for a, b in zip(_decrypt_block(block, keys), prev))
        prev = block
    return bytes(out[: -out[-1]])


# --------------------------------------------------------------------- KLAP v2


def _sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def auth_hash(username: str, password: str) -> bytes:
    """KLAP v2's account hash: sha256(sha1(username) + sha1(password))."""
    # SHA-1 is the protocol's choice, not a security decision.
    user = hashlib.sha1(username.encode(), usedforsecurity=False).digest()
    secret = hashlib.sha1(password.encode(), usedforsecurity=False).digest()
    return _sha256(user + secret)


class KlapSession:
    """One KLAP session's keys, as both ends derive them after handshake2."""

    def __init__(self, local_seed: bytes, remote_seed: bytes, user_hash: bytes) -> None:
        seeds = local_seed + remote_seed + user_hash
        self.key = _sha256(b"lsk" + seeds)[:16]
        full_iv = _sha256(b"iv" + seeds)
        self.iv = full_iv[:12]
        self.sig = _sha256(b"ldk" + seeds)[:28]

    def _iv_for(self, seq: int) -> bytes:
        return self.iv + struct.pack(">i", seq)

    def decrypt(self, payload: bytes, seq: int) -> bytes:
        return aes_cbc_decrypt(self.key, self._iv_for(seq), payload[32:])

    def encrypt(self, message: bytes, seq: int) -> bytes:
        ciphertext = aes_cbc_encrypt(self.key, self._iv_for(seq), message)
        signature = _sha256(self.sig + struct.pack(">i", seq) + ciphertext)
        return signature + ciphertext


# --------------------------------------------------------------------- the device

ALIAS = os.getenv("KASA_FAKE_ALIAS", "Fake P316M")
MODEL = os.getenv("KASA_FAKE_MODEL", "P316M(US)")
OUTLETS = int(os.getenv("KASA_FAKE_OUTLETS", "6"))
BASE_W = float(os.getenv("KASA_FAKE_BASE_W", "20.0"))
USERNAME = os.getenv("KASA_FAKE_USERNAME", "")
PASSWORD = os.getenv("KASA_FAKE_PASSWORD", "")
HTTP_PORT = int(os.getenv("KASA_FAKE_HTTP_PORT", "80"))
# An id, not a digest anyone relies on.
DEVICE_ID = hashlib.sha256(ALIAS.encode()).hexdigest()[:40].upper()
MAC = "A8-29-48-" + "-".join(DEVICE_ID[i : i + 2] for i in (0, 2, 4))
STARTED = time.monotonic()
_UNKNOWN_METHOD = -40106


def _components(*names: str) -> list[dict[str, Any]]:
    return [{"id": name, "ver_code": 2} for name in names]


PARENT_COMPONENTS = _components(
    "device", "child_device", "control_child", "energy_monitoring"
)
OUTLET_COMPONENTS = _components("device", "energy_monitoring")


def _b64(text: str) -> str:
    return base64.b64encode(text.encode()).decode()


def outlet_id(n: int) -> str:
    return f"{DEVICE_ID}{n:02d}"


def outlet_watts(n: int) -> float:
    return BASE_W + 5.0 * (n - 1)


def _emeter(watts: float) -> dict[str, int]:
    hours = (time.monotonic() - STARTED) / 3600
    return {
        "power_mw": round(watts * 1000),
        "voltage_mv": 120_500,
        "current_ma": round(watts / 120.5 * 1000),
        "energy_wh": round(watts * hours),
    }


def _energy_usage(watts: float) -> dict[str, Any]:
    wh = _emeter(watts)["energy_wh"]
    return {
        "today_energy": wh,
        "month_energy": wh,
        "today_runtime": 1,
        "month_runtime": 1,
        "local_time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "electricity_charge": [0, 0, 0],
    }


def _device_info(**extra: Any) -> dict[str, Any]:
    return {
        "device_id": DEVICE_ID,
        "model": MODEL.split("(")[0],
        "type": "SMART.TAPOPLUG",
        "fw_ver": "1.0.5 Build 250710 Rel.120000",
        "hw_ver": "1.6",
        "mac": MAC,
        "nickname": _b64(ALIAS),
        "device_on": True,
        "on_time": int(time.monotonic() - STARTED),
        "rssi": -48,
        "signal_level": 3,
        "ssid": _b64("fake-lan"),
        "region": "America/New_York",
        "time_diff": -300,
        "lang": "en_US",
        "latitude": 0,
        "longitude": 0,
        "has_set_location_info": False,
        "hw_id": "0" * 32,
        "oem_id": "0" * 32,
        "fw_id": "0" * 32,
        "overheated": False,
        "overcurrent_status": "normal",
        "power_protection_status": "normal",
        "specs": "",
        **extra,
    }


def _outlet_info(n: int) -> dict[str, Any]:
    return _device_info(
        device_id=outlet_id(n),
        nickname=_b64(f"{ALIAS} Outlet {n}"),
        category="plug.powerstrip.sub-plug",
        position=n,
        slot_number=OUTLETS,
        original_device_id=DEVICE_ID,
        parent_device_id=DEVICE_ID,
    )


def _energy_methods(watts: float) -> dict[str, Any]:
    return {
        "get_emeter_data": _emeter(watts),
        "get_energy_usage": _energy_usage(watts),
        "get_current_power": {"current_power": round(watts)},
        "get_emeter_vgain_igain": {"igain": 11652, "vgain": 120000},
    }


def parent_methods() -> dict[str, Any]:
    outlets = range(1, OUTLETS + 1)
    return {
        "component_nego": {"component_list": PARENT_COMPONENTS},
        "get_device_info": _device_info(),
        "get_child_device_list": {
            "child_device_list": [_outlet_info(n) for n in outlets],
            "start_index": 0,
            "sum": OUTLETS,
        },
        "get_child_device_component_list": {
            "child_component_list": [
                {"device_id": outlet_id(n), "component_list": OUTLET_COMPONENTS}
                for n in outlets
            ],
            "start_index": 0,
            "sum": OUTLETS,
        },
        **_energy_methods(sum(outlet_watts(n) for n in outlets)),
    }


def outlet_methods(n: int) -> dict[str, Any]:
    return {
        "component_nego": {"component_list": OUTLET_COMPONENTS},
        "get_device_info": _outlet_info(n),
        **_energy_methods(outlet_watts(n)),
    }


def answer(request: dict[str, Any], methods: dict[str, Any]) -> dict[str, Any]:
    """The SMART reply to one request, against the given method table."""
    method = request.get("method")
    if method == "multipleRequest":
        responses = []
        for sub in request.get("params", {}).get("requests", []):
            reply = answer(sub, methods)
            reply["method"] = sub.get("method")
            responses.append(reply)
        return {"error_code": 0, "result": {"responses": responses}}
    if method == "control_child":
        params = request.get("params", {})
        outlets = {outlet_id(n): n for n in range(1, OUTLETS + 1)}
        n = outlets.get(params.get("device_id"))
        if n is None:
            return {"error_code": -1}
        inner = answer(params.get("requestData", {}), outlet_methods(n))
        return {"error_code": 0, "result": {"responseData": inner}}
    if method in methods:
        return {"error_code": 0, "result": methods[method]}
    if isinstance(method, str) and method.startswith("set_"):
        return {"error_code": 0}
    return {"error_code": _UNKNOWN_METHOD}


def discovery_reply(ip: str) -> bytes:
    """The UDP 20002 discovery answer: a 16-byte header, then the JSON result."""
    result = {
        "device_id": DEVICE_ID,
        "device_model": MODEL,
        "device_type": "SMART.TAPOPLUG",
        "factory_default": False,
        "ip": ip,
        "is_support_iot_cloud": True,
        "mac": MAC,
        "mgt_encrypt_schm": {
            "encrypt_type": "KLAP",
            "http_port": HTTP_PORT,
            "is_support_https": False,
            "lv": 2,
        },
        "obd_src": "tplink",
        "owner": "",
        "protocol_version": 1,
    }
    body = json.dumps({"error_code": 0, "result": result}).encode()
    return b"\x02\x00\x00\x01" + b"\x00" * 12 + body


# --------------------------------------------------------------------- the servers


class KlapServer:
    """KLAP v2 over HTTP/1.1, one session per handshake, keep-alive aware."""

    def __init__(self, username: str, password: str) -> None:
        self.user_hash = auth_hash(username, password)
        self.pending: dict[str, tuple[bytes, bytes]] = {}
        self.sessions: dict[str, KlapSession] = {}

    def handle(
        self, path: str, query: dict[str, str], cookie: str | None, body: bytes
    ) -> tuple[int, bytes, dict[str, str]]:
        if path == "/app/handshake1":
            local_seed, remote_seed = body[:16], secrets.token_bytes(16)
            session_id = secrets.token_hex(16).upper()
            self.pending[session_id] = (local_seed, remote_seed)
            server_hash = _sha256(local_seed + remote_seed + self.user_hash)
            headers = {"Set-Cookie": f"TP_SESSIONID={session_id};TIMEOUT=86400"}
            return 200, remote_seed + server_hash, headers
        if path == "/app/handshake2":
            seeds = self.pending.pop(cookie or "", None)
            if seeds is None:
                return 403, b"", {}
            local_seed, remote_seed = seeds
            if body != _sha256(remote_seed + local_seed + self.user_hash):
                return 403, b"", {}
            self.sessions[cookie or ""] = KlapSession(
                local_seed, remote_seed, self.user_hash
            )
            return 200, b"", {}
        if path == "/app/request":
            session = self.sessions.get(cookie or "")
            if session is None:
                return 403, b"", {}
            seq = int(query.get("seq", "0"))
            request = json.loads(session.decrypt(body, seq))
            reply = json.dumps(answer(request, parent_methods())).encode()
            return 200, session.encrypt(reply, seq), {}
        return 404, b"", {}


async def _http(
    server: KlapServer, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    try:
        while True:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            _, target, _ = lines[0].split(" ", 2)
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    name, value = line.split(":", 1)
                    headers[name.strip().lower()] = value.strip()
            body = await reader.readexactly(int(headers.get("content-length", "0")))
            path, _, raw_query = target.partition("?")
            query = dict(p.split("=", 1) for p in raw_query.split("&") if "=" in p)
            cookie = None
            for part in headers.get("cookie", "").split(";"):
                name, _, value = part.strip().partition("=")
                if name == "TP_SESSIONID":
                    cookie = value
            status, payload, extra = server.handle(path, query, cookie, body)
            reason = {200: "OK", 403: "Forbidden", 404: "Not Found"}[status]
            out = [f"HTTP/1.1 {status} {reason}", f"Content-Length: {len(payload)}"]
            out += [f"{k}: {v}" for k, v in extra.items()]
            writer.write(("\r\n".join(out) + "\r\n\r\n").encode() + payload)
            await writer.drain()
    except asyncio.IncompleteReadError, ConnectionError, ValueError:
        pass
    finally:
        writer.close()


def _own_ip(peer: str) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((peer, 9))
        return str(s.getsockname()[0])


class _Discovery(asyncio.DatagramProtocol):
    transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        if isinstance(transport, asyncio.DatagramTransport):
            self.transport = transport

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        if self.transport is not None:
            self.transport.sendto(discovery_reply(_own_ip(addr[0])), addr)


async def start_http(host: str, port: int) -> asyncio.Server:
    """The KLAP HTTP endpoint alone, on ``port`` (0: any free one)."""
    klap = KlapServer(USERNAME, PASSWORD)
    return await asyncio.start_server(lambda r, w: _http(klap, r, w), host, port)


async def serve(http_port: int = HTTP_PORT, discovery_port: int = 20002) -> None:
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(
        _Discovery, local_addr=("0.0.0.0", discovery_port), allow_broadcast=True
    )
    http = await start_http("0.0.0.0", http_port)
    print(f"fake SMART strip {ALIAS!r} ({MODEL}, {OUTLETS} outlets) on :{http_port}")
    async with http:
        await http.serve_forever()


if __name__ == "__main__":
    asyncio.run(serve())
