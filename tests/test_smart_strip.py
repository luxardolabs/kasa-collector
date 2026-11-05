"""A SMART power strip (P316M) is collected per outlet, through the real python-kasa.

The device is harness/fake_smart.py, the e2e stack's KLAP v2 strip, run in-process: the
real python-kasa client logs in to it, and the collector's own poll path writes it.
"""

import importlib.util
import logging
import os
import secrets
from pathlib import Path

import pytest
from kasa import Credentials, Device, DeviceConfig, DeviceConnectionParameters
from kasa.deviceconfig import DeviceEncryptionType, DeviceFamily

from app.collector.poller import Poller
from app.collector.utils import has_outlet_energy, measures_energy
from tests.fakes import emeter_storage

pytestmark = pytest.mark.unit

FAKE = Path(__file__).resolve().parent.parent / "harness" / "fake_smart.py"
USERNAME = "owner@example.invalid"
PASSWORD = "".join(["fake-", "strip-", "login"])


@pytest.fixture
def fake(monkeypatch):
    monkeypatch.setenv("KASA_FAKE_USERNAME", USERNAME)
    monkeypatch.setenv("KASA_FAKE_PASSWORD", PASSWORD)
    monkeypatch.setenv("KASA_FAKE_ALIAS", "Bench Strip")
    spec = importlib.util.spec_from_file_location("fake_smart", FAKE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
async def strip(fake):
    server = await fake.start_http("127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    config = DeviceConfig(
        host="127.0.0.1",
        credentials=Credentials(USERNAME, PASSWORD),
        connection_type=DeviceConnectionParameters(
            DeviceFamily.SmartTapoPlug,
            DeviceEncryptionType.Klap,
            login_version=2,
            http_port=port,
        ),
    )
    device = await Device.connect(config=config)
    yield device
    await device.disconnect()
    server.close()


def test_the_fakes_aes_matches_a_real_implementation(fake):
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key, iv = secrets.token_bytes(16), secrets.token_bytes(16)
    for size in (0, 1, 15, 16, 17, 100):
        message = os.urandom(size)
        padder = padding.PKCS7(128).padder()
        padded = padder.update(message) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        expected = encryptor.update(padded) + encryptor.finalize()

        assert fake.aes_cbc_encrypt(key, iv, message) == expected
        assert fake.aes_cbc_decrypt(key, iv, expected) == message


async def test_a_smart_strip_is_read_as_one_with_outlet_energy(strip):
    assert len(strip.children) == 6
    assert has_outlet_energy(strip)
    assert measures_energy(strip)


async def test_a_smart_strip_writes_one_point_per_outlet(strip, monkeypatch):
    async def hostname(ip):
        return "strip.lan"

    monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)
    written: list[dict] = []

    async def store(data):
        written.extend(data.values())
        return True

    poller = object.__new__(Poller)
    poller.logger = logging.getLogger("test")
    poller.storage = emeter_storage(store)

    assert await poller.process_smart_strip_data("127.0.0.1", strip)

    # Like a real P316M, the strip itself measures nothing: only its outlets.
    outlets = written
    assert [o["plug_id"] for o in outlets] == ["1", "2", "3", "4", "5", "6"]
    assert [o["emeter"]["power_mw"] for o in outlets] == [
        20_000 + 5_000 * n for n in range(6)
    ]
    assert {o["equipment_type"] for o in outlets} == {"plug"}
    assert len({o["device_id"] for o in outlets}) == 1
    assert None not in {o["device_id"] for o in outlets}
    assert outlets[0]["plug_alias"] == "Bench Strip Outlet 1"


async def test_the_fake_refuses_a_wrong_login(fake):
    server = await fake.start_http("127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    config = DeviceConfig(
        host="127.0.0.1",
        credentials=Credentials(USERNAME, "not-the-password"),
        connection_type=DeviceConnectionParameters(
            DeviceFamily.SmartTapoPlug,
            DeviceEncryptionType.Klap,
            login_version=2,
            http_port=port,
        ),
    )
    try:
        with pytest.raises(Exception, match="(?i)did not match our challenge"):
            await Device.connect(config=config)
    finally:
        server.close()


async def test_an_hs300_behind_klap_is_collected_as_a_strip(monkeypatch):
    # The firmware-1.1.2 HS300: IOT.SMARTPLUGSWITCH over KLAP v2. python-kasa's
    # discovery builds an IotPlug for it; the collector's re-class must hand back an
    # IotStrip with every outlet, or its outlets are never collected.
    import asyncio

    from kasa import Discover

    from app.collector.kasa_api import KasaAPI

    for name, value in {
        "KASA_FAKE_USERNAME": USERNAME,
        "KASA_FAKE_PASSWORD": PASSWORD,
        "KASA_FAKE_PROTOCOL": "iot",
        "KASA_FAKE_KIND": "strip",
        "KASA_FAKE_ALIAS": "KLAP Strip",
        "KASA_FAKE_HTTP_PORT": "18080",
    }.items():
        monkeypatch.setenv(name, value)
    spec = importlib.util.spec_from_file_location("fake_smart_iot", FAKE)
    assert spec is not None and spec.loader is not None
    fake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake)

    server = asyncio.create_task(fake.serve())
    try:
        await asyncio.sleep(0.2)
        found = await Discover.discover_single(
            "127.0.0.1", credentials=Credentials(USERNAME, PASSWORD), timeout=5
        )
        assert type(found).__name__ == "IotPlug"  # the discovery path's class

        ready = await KasaAPI.authenticate_discovered_device(found, USERNAME, PASSWORD)

        assert type(ready).__name__ == "IotStrip"
        assert len(ready.children) == 6
        await ready.disconnect()

        # The credentialed connection the device manager falls back to, which is how a
        # discovered KLAP strip is actually reached: discovery enumerates without the
        # account, so the probe of the discovered object cannot log in.
        connected = await KasaAPI.get_device("127.0.0.1", USERNAME, PASSWORD)
        assert type(connected).__name__ == "IotStrip"
        assert len(connected.children) == 6
        await connected.disconnect()
    finally:
        server.cancel()
