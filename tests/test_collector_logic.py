"""Unit tests for retry policy and the missing-device pruning logic."""

import logging
from types import SimpleNamespace

import pytest

from app.collector.poller import Poller
from app.collector.utils import async_retry


@pytest.mark.unit
class TestAsyncRetry:
    async def test_retries_network_errors_up_to_max(self):
        calls = 0

        @async_retry(max_retries=3, base_delay=0, operation_name="test")
        async def flaky():
            nonlocal calls
            calls += 1
            raise ConnectionError("transient")

        with pytest.raises(ConnectionError):
            await flaky()
        assert calls == 3  # retried the full budget

    async def test_does_not_retry_logic_errors(self):
        calls = 0

        @async_retry(max_retries=3, base_delay=0, operation_name="test")
        async def buggy():
            nonlocal calls
            calls += 1
            raise ValueError("a bug, not a network blip")

        with pytest.raises(ValueError):
            await buggy()
        assert calls == 1  # surfaced immediately, NOT retried

    async def test_returns_on_success(self):
        @async_retry(max_retries=3, base_delay=0, operation_name="test")
        async def ok():
            return 42

        assert await ok() == 42


@pytest.mark.unit
class TestRemoveMissingDevices:
    def _dm(self, monkeypatch):
        # Avoid real reverse-DNS during pruning.
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_keeps_missing_when_configured(self, monkeypatch):
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", True)
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.1": SimpleNamespace(alias="A", host="10.0.0.1")}
        await dm.remove_missing_devices({})  # nothing discovered
        assert "10.0.0.1" in dm.devices  # kept

    async def test_prunes_discovered_but_protects_manual(self, monkeypatch):
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["manual-host"]
        dm.devices = {
            "manual-host": SimpleNamespace(alias="Manual", host="manual-host"),
            "10.0.0.9": SimpleNamespace(alias="Discovered", host="10.0.0.9"),
        }
        dm.emeter_devices = dict(dm.devices)
        dm.polling_devices = dict(dm.devices)
        await dm.remove_missing_devices({})  # discovery returned nothing
        assert "manual-host" in dm.devices  # manual device protected
        assert "10.0.0.9" not in dm.devices  # discovered-and-now-missing pruned
        assert "10.0.0.9" not in dm.emeter_devices


@pytest.mark.unit
class TestFetchCounted:
    async def test_counts_success_and_failure_without_raising(self):
        from app.collector.poller import Poller

        poller = object.__new__(Poller)
        poller.logger = logging.getLogger("test")
        outcome = {"ok": 0, "failed": 0}

        async def ok(ip, device):
            return None

        async def boom(ip, device):
            raise ConnectionError("device unreachable")

        await poller._fetch_counted(ok, "10.0.0.1", None, outcome, "emeter fetch")
        # A failing device is counted, not re-raised — so siblings keep going.
        await poller._fetch_counted(boom, "10.0.0.2", None, outcome, "emeter fetch")

        assert outcome == {"ok": 1, "failed": 1}


@pytest.mark.unit
class TestFetchCountedWriteFailures:
    """A polled-but-unwritten device is counted separately, not as a success.

    The regression this locks (KASACOLLEC-63): send_to_influxdb swallowed write
    failures, so `_fetch_counted` saw a clean return and incremented `ok`. During an
    InfluxDB outage the per-cycle collector_stats point therefore reported every
    device as succeeded while nothing landed — the metric contradicted the logs.
    """

    def _poller(self):
        p = object.__new__(Poller)
        p.logger = logging.getLogger("test")
        return p

    async def test_failed_write_counts_as_write_failed_not_ok(self):
        p = self._poller()
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        async def fetch_that_stores_nothing(ip, device):
            return False  # polled fine, write rejected

        await p._fetch_counted(
            fetch_that_stores_nothing, "10.0.0.5", object(), outcome, "emeter fetch"
        )
        assert outcome == {"ok": 0, "failed": 0, "write_failed": 1}

    async def test_successful_write_counts_as_ok(self):
        p = self._poller()
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        async def fetch_that_stores(ip, device):
            return True

        await p._fetch_counted(
            fetch_that_stores, "10.0.0.5", object(), outcome, "emeter fetch"
        )
        assert outcome == {"ok": 1, "failed": 0, "write_failed": 0}

    async def test_unreachable_device_still_counts_as_failed(self):
        # The pre-existing outcome must not be disturbed by the new third state.
        p = self._poller()
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        async def fetch_that_raises(ip, device):
            raise ConnectionError("device unreachable")

        await p._fetch_counted(
            fetch_that_raises, "10.0.0.5", object(), outcome, "emeter fetch"
        )
        assert outcome == {"ok": 0, "failed": 1, "write_failed": 0}
