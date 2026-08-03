"""Unit tests for the environment-driven config parsing helpers."""

import pytest

from app.core import config


@pytest.mark.unit
class TestBoolConfig:
    def test_defaults_to_given_default(self, monkeypatch):
        monkeypatch.delenv("KASA_TEST_BOOL", raising=False)
        assert config._get_bool_config("KASA_TEST_BOOL", default=True) is True
        assert config._get_bool_config("KASA_TEST_BOOL", default=False) is False

    @pytest.mark.parametrize("value", ["true", "True", "YES", "1", "on"])
    def test_truthy_values(self, monkeypatch, value):
        monkeypatch.setenv("KASA_TEST_BOOL", value)
        assert config._get_bool_config("KASA_TEST_BOOL") is True

    @pytest.mark.parametrize("value", ["false", "no", "0", "off", "nonsense", ""])
    def test_falsey_values(self, monkeypatch, value):
        monkeypatch.setenv("KASA_TEST_BOOL", value)
        assert config._get_bool_config("KASA_TEST_BOOL") is False


@pytest.mark.unit
class TestIntConfig:
    def test_default_when_unset(self, monkeypatch):
        monkeypatch.delenv("KASA_TEST_INT", raising=False)
        assert config._get_int_config("KASA_TEST_INT", default=15) == 15

    def test_parses_env_value(self, monkeypatch):
        monkeypatch.setenv("KASA_TEST_INT", "42")
        assert config._get_int_config("KASA_TEST_INT", default=15) == 42

    def test_invalid_int_falls_back_to_default(self, monkeypatch):
        # ConfigValidator clamps-and-warns rather than crashing the collector.
        monkeypatch.setenv("KASA_TEST_INT", "not-a-number")
        assert config._get_int_config("KASA_TEST_INT", default=15) == 15

    def test_below_minimum_falls_back_to_default(self, monkeypatch):
        monkeypatch.setenv("KASA_TEST_INT", "0")
        assert config._get_int_config("KASA_TEST_INT", default=15, min_value=1) == 15


@pytest.mark.unit
class TestConfigValidator:
    def test_int_out_of_range_without_default_raises(self):
        # No default → a genuine error surfaces (main enforces required vars separately).
        with pytest.raises(ValueError):
            config.ConfigValidator.validate_int("0", min_val=1)

    def test_bool_invalid_falls_back_to_default(self):
        assert config.ConfigValidator.validate_bool("nonsense", default=True) is True

    def test_log_level_invalid_falls_back_to_default(self):
        assert config.ConfigValidator.validate_log_level("LOUD", default="INFO") == "INFO"

    def test_log_level_normalizes_case(self):
        assert config.ConfigValidator.validate_log_level("debug") == "DEBUG"
