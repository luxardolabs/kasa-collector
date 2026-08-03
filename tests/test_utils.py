"""Unit tests for shared collector utilities."""

import asyncio
import logging
from types import SimpleNamespace

import pytest

from app.collector.utils import DeviceContext, format_duration, get_device_name, sanitize_tag


@pytest.mark.unit
class TestSanitizeTag:
    def test_strips_control_chars(self):
        assert sanitize_tag("Evil\r\nFAKE\tLOG") == "EvilFAKELOG"

    def test_keeps_normal_text_including_spaces(self):
        assert sanitize_tag("Back Room Fridge") == "Back Room Fridge"

    def test_caps_length(self):
        assert len(sanitize_tag("x" * 500, maxlen=64)) == 64

    def test_none_and_empty_become_unknown(self):
        assert sanitize_tag(None) == "unknown"
        assert sanitize_tag("\n\r") == "unknown"


@pytest.mark.unit
class TestDeviceContextExit:
    async def test_cancellation_is_not_logged_as_error(self, caplog):
        # A clean shutdown cancels in-flight ops; that must not log at ERROR.
        ctx = DeviceContext(SimpleNamespace(alias="Plug", host="10.0.0.5"), "10.0.0.5", "fetch")
        with caplog.at_level(logging.DEBUG):
            await ctx.__aexit__(asyncio.CancelledError, asyncio.CancelledError(), None)
        assert not any(r.levelno >= logging.ERROR for r in caplog.records)

    async def test_real_error_still_logs_as_error(self, caplog):
        ctx = DeviceContext(SimpleNamespace(alias="Plug", host="10.0.0.5"), "10.0.0.5", "fetch")
        with caplog.at_level(logging.ERROR):
            await ctx.__aexit__(ValueError, ValueError("boom"), None)
        assert any(r.levelno >= logging.ERROR for r in caplog.records)


@pytest.mark.unit
class TestGetDeviceName:
    def test_prefers_alias(self):
        device = SimpleNamespace(alias="Living Room Lamp", host="10.0.0.5", model="HS110")
        assert get_device_name(device) == "Living Room Lamp"

    def test_falls_back_to_host(self):
        device = SimpleNamespace(alias="", host="10.0.0.5", model="HS110")
        assert get_device_name(device) == "10.0.0.5"

    def test_falls_back_to_model(self):
        device = SimpleNamespace(alias=None, host=None, model="HS110")
        assert get_device_name(device) == "HS110"

    def test_final_fallback(self):
        device = SimpleNamespace(alias=None, host=None, model=None)
        assert get_device_name(device) == "Unknown Device"

    def test_never_raises(self):
        # An object whose attribute access explodes still yields a string.
        class Exploding:
            @property
            def alias(self):
                raise RuntimeError("boom")

        assert get_device_name(Exploding()) == "Unknown Device"


@pytest.mark.unit
class TestFormatDuration:
    def test_seconds(self):
        assert format_duration(2.5) == "2.50 seconds"

    def test_minutes(self):
        assert format_duration(225) == "3 minutes, 45.0 seconds"

    def test_hours(self):
        assert format_duration(5415) == "1 hours, 30 minutes, 15.0 seconds"
