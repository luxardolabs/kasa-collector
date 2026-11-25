"""InfluxDB's startup connect waits out an InfluxDB that is still starting.

A deploy that recreates InfluxDB beside the collector starts both at once, and InfluxDB takes
seconds to answer. The collector retries its first ping with a growing delay, within a bounded
window, and fails with the connection banner only when InfluxDB is still unreachable at the
end of it, so a wrong URL still stops the container clearly.
"""

import asyncio

import pytest

from app.storage import influxdb as influx_module
from app.storage.influxdb import CONNECT_WINDOW_SECONDS, InfluxDBStorage


class _FakeClient:
    """Stands in for InfluxDBClientAsync: each ping takes the next outcome from `pings`
    (an exception to raise, or the bool ping returns); the last outcome repeats."""

    instances: list[_FakeClient] = []

    def __init__(self, pings, **_kwargs):
        self.pings = list(pings)
        self.ping_calls = 0
        self.closed = False
        _FakeClient.instances.append(self)

    async def ping(self):
        outcome = self.pings[min(self.ping_calls, len(self.pings) - 1)]
        self.ping_calls += 1
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    async def version(self):
        return "2.7.12"

    def write_api(self):
        return object()

    async def close(self):
        self.closed = True


@pytest.fixture
def connect_with(monkeypatch):
    """Run InfluxDBStorage.connect() against a fake client and a recorded sleep."""
    sleeps: list[float] = []

    async def fake_sleep(delay):
        sleeps.append(delay)

    monkeypatch.setattr(asyncio, "sleep", fake_sleep)
    _FakeClient.instances = []

    def run(pings):
        monkeypatch.setattr(
            influx_module,
            "InfluxDBClientAsync",
            lambda **kw: _FakeClient(pings, **kw),
        )
        storage = InfluxDBStorage()
        asyncio.run(storage.connect())
        return storage

    return run, sleeps


@pytest.mark.unit
def test_an_influxdb_still_starting_is_waited_for(connect_with):
    run, sleeps = connect_with
    refused = ConnectionRefusedError(111, "Connection refused")
    storage = run([refused, refused, True])
    assert storage.write_api is not None
    assert _FakeClient.instances[0].ping_calls == 3
    assert sleeps == [1, 2]


@pytest.mark.unit
def test_an_unhealthy_answer_is_retried_like_an_unreachable_one(connect_with):
    run, sleeps = connect_with
    storage = run([False, True])
    assert storage.write_api is not None
    assert sleeps == [1]


@pytest.mark.unit
def test_an_influxdb_unreachable_for_the_whole_window_still_stops_the_collector(
    connect_with, caplog
):
    run, sleeps = connect_with
    with pytest.raises(SystemExit) as exit_info:
        run([ConnectionRefusedError(111, "Connection refused")])
    assert exit_info.value.code == 1
    assert sum(sleeps) == CONNECT_WINDOW_SECONDS
    assert all(
        delay <= influx_module.Config.KASA_COLLECTOR_MAX_RETRY_DELAY for delay in sleeps
    )
    assert _FakeClient.instances[0].closed
    assert "InfluxDB Connection Failed" in caplog.text
