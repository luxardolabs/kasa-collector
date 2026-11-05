"""A camera or doorbell family advertising KLAP still gets the camera (SSL-AES) login
from python-kasa, so an unlisted one is refused by the transport, not the advert."""

import pytest
from kasa import DeviceConfig
from kasa.discover import Discover
from kasa.transports.sslaestransport import SslAesTransport

from app.collector import kasa_api

pytestmark = pytest.mark.unit

HOST = "10.0.0.9"


def _camera_reply(device_type: str, encrypt_type: str, https: bool = True) -> dict:
    return {
        "error_code": 0,
        "result": {
            "device_type": device_type,
            "device_model": "C100",
            "device_id": "00",
            "ip": HOST,
            "mac": "F0-A7-31-00-00-00",
            "mgt_encrypt_schm": {
                "is_support_https": https,
                "encrypt_type": encrypt_type,
                "http_port": 443,
            },
        },
    }


@pytest.fixture
def handshakes(monkeypatch):
    seen: list[tuple] = []

    async def fake_handshake1(self):
        seen.append((type(self).__name__, self._username, self._pwd_to_hash()))
        raise RuntimeError("stop after recording the login")

    monkeypatch.setattr(SslAesTransport, "perform_handshake1", fake_handshake1)

    async def no_connect(*a, **k):
        raise OSError("no network in test")

    monkeypatch.setattr(kasa_api.Device, "connect", no_connect)
    return seen


def _patch_discover(monkeypatch, device_type, encrypt_type, https=True):
    async def fake_discover_single(host, *, credentials=None, **kw):
        config = DeviceConfig(host=host, credentials=credentials)
        return Discover._get_device_instance(
            _camera_reply(device_type, encrypt_type, https), config
        )

    monkeypatch.setattr(kasa_api.Discover, "discover_single", fake_discover_single)


@pytest.mark.parametrize("https", [True, False])
@pytest.mark.parametrize("device_type", ["SMART.IPCAMERA", "SMART.TAPODOORBELL"])
async def test_klap_advertised_camera_is_refused(
    monkeypatch, handshakes, device_type, https
):
    _patch_discover(monkeypatch, device_type, "KLAP", https)
    with pytest.raises(kasa_api.InsecureLoginRefused):
        await kasa_api.KasaAPI.get_device(
            HOST, "owner@x", "s3cret", refuse_aes_login=True
        )
    # The camera SSL-AES login never runs with the owner's password.
    assert handshakes == [], f"AES camera login attempted: {handshakes}"


async def test_control_aes_advertised_camera_is_refused(monkeypatch, handshakes):
    _patch_discover(monkeypatch, "SMART.IPCAMERA", "AES")
    with pytest.raises(kasa_api.InsecureLoginRefused):
        await kasa_api.KasaAPI.get_device(
            HOST, "owner@x", "s3cret", refuse_aes_login=True
        )
    assert handshakes == []


@pytest.mark.parametrize(
    ("encrypt_type", "https"), [("KLAP", True), ("KLAP", False), ("AES", True)]
)
async def test_discovered_unlisted_camera_via_device_manager(
    monkeypatch, tmp_path, handshakes, encrypt_type, https
):
    """Full discovered-device path under the trust default: broadcast object, then retry."""
    from tests.test_collector_logic import TestCredentialsGatedByTrust

    dm = TestCredentialsGatedByTrust()._dm(monkeypatch, tmp_path, trust=True)
    dm.max_retries = 1
    _patch_discover(monkeypatch, "SMART.IPCAMERA", encrypt_type, https)
    # What broadcast discovery hands the manager: built WITHOUT credentials.
    discovered = Discover._get_device_instance(
        _camera_reply("SMART.IPCAMERA", encrypt_type, https),
        DeviceConfig(host=HOST),
    )
    await dm._authenticate_device_with_retry(
        HOST, discovered, allow_credentials=dm._may_use_credentials(HOST)
    )
    with_owner = [h for h in handshakes if h[1] == "owner@x"]
    # Neither advert leads to a camera SSL-AES login with the owner's password.
    assert with_owner == [], f"owner credentials used in AES login: {with_owner}"
