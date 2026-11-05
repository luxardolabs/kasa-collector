"""Each device fetch has a budget for its read, then a fresh one for its writes."""

import asyncio
import logging
import time
from types import SimpleNamespace

import pytest
from kasa.emeterstatus import EmeterStatus
from kasa.exceptions import TimeoutError as KasaTimeoutError

from app.collector.poller import Poller
from tests.fakes import emeter_storage

pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _no_dns(monkeypatch):
    async def hostname(ip):
        return "strip.lan"

    monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)


def _strip(outlets, read_seconds=0.0):
    reading = EmeterStatus(
        {"current_ma": 10, "voltage_mv": 230000, "power_mw": 500, "total_wh": 7}
    )

    async def update():
        await asyncio.sleep(read_seconds)

    from kasa.iot import IotStrip

    class Strip(IotStrip):
        sys_info = {"deviceId": "STRIP1"}
        emeter_realtime = reading
        alias = "Strip"
        children = [
            SimpleNamespace(alias=f"Outlet {i}", emeter_realtime=reading, update=update)
            for i in range(outlets)
        ]

    return object.__new__(Strip)


def _poller(written, reached, write_seconds):
    async def store(data):
        await asyncio.sleep(write_seconds)  # a slow InfluxDB write, or a hung mount
        written.extend(data.values())
        return True

    p = object.__new__(Poller)
    p.logger = logging.getLogger("test")
    p.storage = emeter_storage(store)
    p.on_reachable = reached.append
    return p


async def test_a_write_after_a_slow_read_gets_its_own_budget():
    # A 1 s interval: 0.8 s to read, then 0.8 s to write. The read takes 0.6 s and
    # the writes 0.6 s: together past 0.8 s, each within its own budget.
    written, reached = [], []
    p = _poller(written, reached, 0.15)
    outcome = {"ok": 0, "failed": 0, "write_failed": 0}

    await p._fetch_counted(
        p.process_smart_strip_data,
        "10.0.0.9",
        _strip(3, read_seconds=0.2),
        outcome,
        "emeter fetch",
        1,
    )

    assert len(written) == 4
    assert reached == ["10.0.0.9"]
    assert outcome == {"ok": 1, "failed": 0, "write_failed": 0}


async def test_a_write_that_never_finishes_is_bounded_and_counted_write_failed():
    # A dead InfluxDB or a hung file mount must not hold the cycle: the device
    # answered, so it is reachable, and its write failed.
    written, reached = [], []
    p = _poller(written, reached, 30)
    outcome = {"ok": 0, "failed": 0, "write_failed": 0}

    started = time.monotonic()
    await p._fetch_counted(
        p.process_smart_strip_data, "10.0.0.9", _strip(3), outcome, "emeter fetch", 1
    )

    assert time.monotonic() - started < 2
    assert reached == ["10.0.0.9"]
    assert outcome == {"ok": 0, "failed": 0, "write_failed": 1}


async def test_python_kasas_own_timeout_keeps_its_error_in_the_log(caplog):
    p = object.__new__(Poller)
    p.logger = logging.getLogger("test")
    p.on_reachable = None

    async def fetch(ip, device):
        raise KasaTimeoutError("Unable to query the device, timed out: 10.0.0.5: x")

    outcome = {"ok": 0, "failed": 0, "write_failed": 0}
    with caplog.at_level(logging.WARNING):
        await p._fetch_counted(fetch, "10.0.0.5", None, outcome, "emeter fetch", 15)

    assert outcome["failed"] == 1
    assert "Unable to query the device" in caplog.text
    assert "did not finish within" not in caplog.text
