"""An unlisted responder never gets an AES-family login, whatever it advertises.

The discover_single reply is built by python-kasa's REAL Discover._get_device_instance
(the same function datagram_received calls, with the same credentialed DeviceConfig),
so the transport chosen is python-kasa's own choice. The rogue's HTTPS side is the
transport's HttpClient.post, recorded.
"""

import contextlib
import hashlib

import pytest
from kasa import DeviceConfig, Discover
from kasa.httpclient import HttpClient

from app.collector import kasa_api

pytestmark = pytest.mark.unit

IP = "10.0.0.9"
USER = "owner@example.com"
PWD = "s3cret-Passw0rd"
MD5 = hashlib.md5(PWD.encode(), usedforsecurity=False).hexdigest().upper()


def _reply(device_type: str, mgt: dict, extra: dict | None = None) -> dict:
    result = {
        "device_id": "00000000000000000000000000000000",
        "device_model": "C100",
        "device_type": device_type,
        "factory_default": False,
        "ip": IP,
        "is_support_iot_cloud": True,
        "mac": "F0-A7-31-00-00-00",
        "mgt_encrypt_schm": mgt,
        "protocol_version": 1,
        "hw_ver": "4.0",
        "owner": "",
    }
    result.update(extra or {})
    return {"error_code": 0, "result": result}


def _install_rogue(monkeypatch, info: dict) -> list[dict]:
    sent: list[dict] = []

    async def fake_discover_single(host, *, credentials=None, **kw):
        # Exactly what _DiscoverProtocol.datagram_received does for a 20002 reply.
        config = DeviceConfig(host=host)
        if credentials:
            config.credentials = credentials
        return Discover._get_device_instance(info, config)

    async def fake_post(
        self,
        url,
        *,
        params=None,
        data=None,
        json=None,
        headers=None,
        cookies_dict=None,
        ssl=False,
    ):
        sent.append({"url": str(url), "json": json, "data": data})
        params_ = (json or {}).get("params", {})
        if (json or {}).get("method") == "login" and "password" not in params_:
            # handshake1: ask for the "less secure" camera login.
            return 200, {
                "error_code": -40401,
                "result": {"data": {"encrypt_type": ["2"]}},
            }
        if (json or {}).get("method") == "login":
            return 200, {"error_code": 0, "result": {"stok": "rogue-stok"}}
        return 200, {"error_code": -1}

    async def no_connect(*a, **kw):
        raise ConnectionError("no network in test")

    monkeypatch.setattr(kasa_api.Discover, "discover_single", fake_discover_single)
    monkeypatch.setattr(HttpClient, "post", fake_post)
    monkeypatch.setattr(kasa_api.Device, "connect", no_connect)
    return sent


async def _run(monkeypatch, info) -> tuple[list[dict], BaseException | None]:
    sent = _install_rogue(monkeypatch, info)
    err: BaseException | None = None
    try:
        await kasa_api.KasaAPI.get_device(IP, USER, PWD, refuse_aes_login=True)
    except Exception as e:
        err = e
    return sent, err


def _leaked(sent: list[dict]) -> list[dict]:
    return [s for s in sent if MD5 in repr(s) or PWD in repr(s) or USER in repr(s)]


# --- CONTROL: the AES camera advert the change targets is refused, nothing sent -------
async def test_control_camera_advertising_aes_is_refused(monkeypatch):
    info = _reply("SMART.IPCAMERA", {"is_support_https": True, "encrypt_type": "AES"})
    sent, err = await _run(monkeypatch, info)
    assert isinstance(err, kasa_api.InsecureLoginRefused)
    assert sent == []


# --- ATTACK: same camera family, advertising KLAP -> python-kasa still uses SslAes ------
@pytest.mark.parametrize("device_type", ["SMART.IPCAMERA", "SMART.TAPODOORBELL"])
@pytest.mark.parametrize("https", [True, False])
async def test_camera_family_advertising_klap_gets_no_credentials(
    monkeypatch, device_type, https
):
    info = _reply(device_type, {"is_support_https": https, "encrypt_type": "KLAP"})
    sent, err = await _run(monkeypatch, info)
    leaked = _leaked(sent)
    assert leaked == [], f"credential-equivalent sent to unlisted responder: {leaked}"


# --- probes -----------------------------------------------------------------------
async def test_sym_schm_only_aes_is_refused(monkeypatch):
    info = _reply(
        "SMART.TAPOPLUG",
        {"is_support_https": False},
        {"encrypt_info": {"sym_schm": "AES", "key": "", "data": ""}},
    )
    sent, err = await _run(monkeypatch, info)
    assert isinstance(err, kasa_api.InsecureLoginRefused)
    assert _leaked(sent) == []


async def test_camera_lv3_without_encrypt_type_is_refused(monkeypatch):
    info = _reply("SMART.IPCAMERA", {"is_support_https": True}, {"encrypt_type": ["3"]})
    sent, err = await _run(monkeypatch, info)
    assert isinstance(err, kasa_api.InsecureLoginRefused)
    assert _leaked(sent) == []


async def test_robovac_aes_is_refused(monkeypatch):
    info = _reply(
        "SMART.TAPOROBOVAC", {"is_support_https": True, "encrypt_type": "AES"}
    )
    sent, err = await _run(monkeypatch, info)
    assert isinstance(err, kasa_api.InsecureLoginRefused)
    assert _leaked(sent) == []


async def test_hub_https_klap_does_not_use_aes(monkeypatch):
    info = _reply("SMART.TAPOHUB", {"is_support_https": True, "encrypt_type": "KLAP"})
    sent, err = await _run(monkeypatch, info)
    assert not isinstance(err, kasa_api.InsecureLoginRefused)
    assert _leaked(sent) == []


async def test_listed_aes_camera_still_logs_in(monkeypatch):
    """Regression control: refuse_aes_login=False lets the AES login run."""
    info = _reply("SMART.IPCAMERA", {"is_support_https": True, "encrypt_type": "AES"})
    sent = _install_rogue(monkeypatch, info)
    # The rogue's replies end the listed login in an error; what matters is what it sent.
    with contextlib.suppress(Exception):
        await kasa_api.KasaAPI.get_device(IP, USER, PWD, refuse_aes_login=False)
    assert any(MD5 in repr(s) for s in sent)
