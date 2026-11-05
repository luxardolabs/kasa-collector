"""The per-device deadline bounds the device read, never the InfluxDB writes."""

import asyncio
import logging
from types import SimpleNamespace

import pytest
from kasa.emeterstatus import EmeterStatus
from kasa.exceptions import TimeoutError as KasaTimeoutError

from app.collector.poller import Poller

pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _no_dns(monkeypatch):
    async def hostname(ip):
        return "strip.lan"

    monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)


def _strip(outlets):
    reading = EmeterStatus(
        {"current_ma": 10, "voltage_mv": 230000, "power_mw": 500, "total_wh": 7}
    )

    async def update():
        return None

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
        await asyncio.sleep(write_seconds)  # a slow InfluxDB write
        written.extend(data.values())
        return True

    p = object.__new__(Poller)
    p.logger = logging.getLogger("test")
    p.storage = SimpleNamespace(process_emeter_data=store)
    p.on_reachable = reached.append
    return p


async def test_a_slow_write_finishes_the_whole_strip_and_counts_it_reachable():
    # A 1 s interval gives the read 0.8 s; the four writes take 1.2 s. The strip
    # answered in full, so every point lands and it is reachable and stored.
    written, reached = [], []
    p = _poller(written, reached, 0.3)
    outcome = {"ok": 0, "failed": 0, "write_failed": 0}

    await p._fetch_counted(
        p.process_smart_strip_data, "10.0.0.9", _strip(3), outcome, "emeter fetch", 1
    )

    assert len(written) == 4
    assert reached == ["10.0.0.9"]
    assert outcome == {"ok": 1, "failed": 0, "write_failed": 0}


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
