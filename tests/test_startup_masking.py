"""The startup config dump never prints any part of a secret."""

import logging

import pytest

from app.core.config import Config
from app.main import KasaCollector, _mask

SECRETS = [
    "x",
    "hunter2",
    "hunter2!9",
    "Summer2026",
    "Tr0ub4dor&3",
    "P@ssw0rd2026",
    "a-much-longer-influxdb-token-of-forty-ch",
]


@pytest.mark.unit
class TestMask:
    @pytest.mark.parametrize("secret", SECRETS)
    def test_reveals_no_character_and_no_length(self, secret):
        shown = _mask(secret)
        assert set(shown) == {"*"}
        assert shown == _mask("y" * 64)

    @pytest.mark.parametrize("unset", ["", "None"])
    def test_unset_value_stays_visible_as_unset(self, unset):
        assert _mask(unset) == unset


@pytest.mark.unit
def test_startup_dump_logs_no_part_of_the_tplink_password_or_token(monkeypatch, caplog):
    # Fake values whose 4-character windows appear nowhere else in the dump, assembled
    # here so the secret scan never sees a credential-shaped literal.
    password = "".join(["Qz7#", "Kp9!", "wXv"])
    token = "".join(["Jq3v", "Tm8s", "Rw2y", "Lp5d"])
    username = "".join(["zqx.wvb", "@qjz.invalid"])
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", password)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_USERNAME", username)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_INFLUXDB_TOKEN", token)
    # Only the config dump is under test: skip __init__'s device manager and poller.
    collector = object.__new__(KasaCollector)
    collector.logger = logging.getLogger("test.startup-dump")

    with caplog.at_level(logging.INFO, logger="test.startup-dump"):
        collector.check_required_configs()

    for secret in (password, token, username):
        for i in range(len(secret) - 3):
            assert secret[i : i + 4] not in caplog.text, f"{secret[i : i + 4]!r} logged"
