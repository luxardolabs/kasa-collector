"""A SMART power strip (P316M) is collected per outlet, through the real python-kasa.

The device is harness/fake_smart.py, the e2e stack's KLAP v2 strip, run in-process: the
real python-kasa client logs in to it, and the collector's own poll path writes it.
"""

import importlib.util
import logging
import os
import secrets
from pathlib import Path
from types import SimpleNamespace

import pytest
from kasa import Credentials, Device, DeviceConfig, DeviceConnectionParameters
from kasa.deviceconfig import DeviceEncryptionType, DeviceFamily

from app.collector.poller import Poller
from app.collector.utils import has_outlet_energy, measures_energy

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


async def test_a_smart_strip_writes_its_total_and_one_point_per_outlet(
    strip, monkeypatch
):
    async def hostname(ip):
        return "strip.lan"

    monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)
    written: list[dict] = []

    async def store(data):
        written.extend(data.values())
        return True

    poller = object.__new__(Poller)
    poller.logger = logging.getLogger("test")
    poller.storage = SimpleNamespace(process_emeter_data=store)

    assert await poller.process_smart_strip_data("127.0.0.1", strip)

    total, *outlets = written
    assert total["equipment_type"] == "device"
    assert total["emeter"]["power_mw"] == sum(20_000 + 5_000 * n for n in range(6))
    assert [o["plug_id"] for o in outlets] == ["1", "2", "3", "4", "5", "6"]
    assert [o["emeter"]["power_mw"] for o in outlets] == [
        20_000 + 5_000 * n for n in range(6)
    ]
    assert {o["equipment_type"] for o in outlets} == {"plug"}
    assert {o["device_id"] for o in written} == {total["device_id"]}
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
