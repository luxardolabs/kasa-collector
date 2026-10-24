"""No part of the TP-Link account credentials or the InfluxDB token reaches the log."""

import hashlib
import io
import logging
from unittest.mock import AsyncMock

import pytest
from kasa import Credentials, DeviceConfig
from kasa.transports.ssltransport import SslTransport

from app.core.config import Config
from app.main import KasaCollector, _mask, configure_app_logging

SECRETS = [
    "x",
    "hunter2",
    "hunter2!9",
    "Summer2026",
    "Tr0ub4dor&3",
    "P@ssw0rd2026",
    "a-much-longer-influxdb-token-of-forty-ch",
    "None",
    "   ",
]

# Fake values whose 4-character windows appear nowhere else in the log, assembled here so
# the secret scan never sees a credential-shaped literal.
PASSWORD = "".join(["Qz7#", "Kp9!", "wXv"])
TOKEN = "".join(["Jq3v", "Tm8s", "Rw2y", "Lp5d"])
USERNAME = "".join(["zqx.wvb", "@qjzpkw"])
URL_PASSWORD = "".join(["FAKE", "urlPw9xQ"])


def _assert_no_window(text, secrets):
    for secret in secrets:
        for i in range(max(len(secret) - 3, 1)):
            assert secret[i : i + 4] not in text, f"{secret[i : i + 4]!r} logged"


@pytest.fixture
def credentials(monkeypatch):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", PASSWORD)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_USERNAME", USERNAME)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_INFLUXDB_TOKEN", TOKEN)
    monkeypatch.setattr(
        Config,
        "KASA_COLLECTOR_INFLUXDB_URL",
        f"http://admin:{URL_PASSWORD}@influx.invalid:8086",
    )


@pytest.fixture(params=["text", "json"])
def app_log(request, monkeypatch, credentials):
    """The process's real logging setup, as `python -m app.main` installs it, in each
    LOG_FORMAT, with the installed stdout handler pointed at a buffer the test reads."""
    monkeypatch.setenv("LOG_FORMAT", request.param)
    monkeypatch.setenv("LOG_MODULE_LEVELS", '{"kasa": "DEBUG"}')
    configure_app_logging()
    buffer = io.StringIO()
    (handler,) = logging.getLogger().handlers
    assert isinstance(handler, logging.StreamHandler)
    handler.setStream(buffer)
    yield buffer
    logging.getLogger("kasa").setLevel(logging.WARNING)


@pytest.mark.unit
class TestMask:
    @pytest.mark.parametrize("secret", SECRETS)
    def test_reveals_no_character_and_no_length(self, secret):
        shown = _mask(secret)
        assert shown == "****"
        assert shown == _mask("y" * 64)

    def test_unset_value_stays_visible_as_unset(self):
        assert _mask(None) == "None"
        assert _mask("") == ""


@pytest.mark.unit
def test_startup_dump_logs_no_part_of_any_secret(credentials, caplog):
    # Only the config dump is under test: skip __init__'s device manager and poller.
    collector = object.__new__(KasaCollector)
    collector.logger = logging.getLogger("test.startup-dump")

    with caplog.at_level(logging.INFO, logger="test.startup-dump"):
        collector.check_required_configs()

    for name in ("TPLINK_PASSWORD", "TPLINK_USERNAME", "INFLUXDB_TOKEN"):
        assert f"KASA_COLLECTOR_{name}: ****" in caplog.text
    assert "KASA_COLLECTOR_INFLUXDB_URL: http://****@influx.invalid:8086" in caplog.text
    _assert_no_window(caplog.text, (PASSWORD, TOKEN, USERNAME, URL_PASSWORD))


@pytest.mark.unit
def test_password_whose_value_is_the_word_none_is_masked(monkeypatch, caplog):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", "None")
    collector = object.__new__(KasaCollector)
    collector.logger = logging.getLogger("test.startup-dump")

    with caplog.at_level(logging.INFO, logger="test.startup-dump"):
        collector.check_required_configs()

    assert "KASA_COLLECTOR_TPLINK_PASSWORD: ****" in caplog.text


@pytest.mark.unit
def test_influxdb_url_password_never_reaches_a_log_line(app_log):
    logging.getLogger("InfluxDBStorage").error(
        "Could not reach InfluxDB at: %s", Config.KASA_COLLECTOR_INFLUXDB_URL
    )
    out = app_log.getvalue()
    assert "Could not reach InfluxDB at: http://admin:****@influx.invalid:8086" in out
    _assert_no_window(out, (URL_PASSWORD,))


@pytest.mark.unit
async def test_python_kasa_debug_login_logs_no_credential(app_log):
    transport = SslTransport(
        config=DeviceConfig(
            host="192.0.2.10", credentials=Credentials(USERNAME, PASSWORD)
        )
    )
    transport._http_client.post = AsyncMock(
        return_value=(200, {"error_code": 0, "result": {"token": "T"}})
    )

    await transport.try_login(transport._get_login_params(transport._credentials))

    out = app_log.getvalue()
    assert (
        "Sending" in out and "login" in out
    )  # the DEBUG line was written: the control
    md5 = hashlib.md5(PASSWORD.encode(), usedforsecurity=False).hexdigest()
    _assert_no_window(out, (USERNAME, PASSWORD, md5, md5.upper()))


@pytest.mark.unit
async def test_python_kasa_debug_klap_handshake_logs_no_crackable_hash(app_log):
    # KLAP's handshake1 DEBUG lines carry both seeds and the server hash
    # (sha256(local_seed + remote_seed + auth_hash), auth_hash from the TP-Link username
    # and password): together they allow an offline guess of the password.
    from kasa.transports.klaptransport import KlapTransport

    transport = KlapTransport(
        config=DeviceConfig(
            host="192.0.2.11", credentials=Credentials(USERNAME, PASSWORD)
        )
    )
    remote_seed = bytes(range(16))
    sent: list[bytes] = []

    async def post(url, *, data=None, **kwargs):
        sent.append(data)
        server_hash = transport.handshake1_seed_auth_hash(
            data, remote_seed, transport._local_auth_hash
        )
        return 200, remote_seed + server_hash

    transport._http_client.post = post

    await transport.perform_handshake1()

    out = app_log.getvalue()
    assert "Handshake1 success" in out  # the DEBUG lines were written: the control
    server_hash = transport.handshake1_seed_auth_hash(
        sent[0], remote_seed, transport._local_auth_hash
    )
    for secret in (sent[0].hex(), remote_seed.hex(), server_hash.hex()):
        assert secret not in out, f"{secret[:8]}… logged"
