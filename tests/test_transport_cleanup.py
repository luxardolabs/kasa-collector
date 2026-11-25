"""A device's disconnect is bounded by KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT.

A device that stops answering mid-close would otherwise hold shutdown (and a replaced
device's cleanup) for as long as its transport takes to give up.
"""

import asyncio

import pytest

from app.collector import kasa_api
from app.collector.kasa_api import KasaAPI


class _HangingDevice:
    host = "10.9.8.7"

    def __init__(self):
        self.disconnect_started = False

    async def disconnect(self):
        self.disconnect_started = True
        await asyncio.sleep(3600)


@pytest.fixture
def short_cleanup(monkeypatch):
    monkeypatch.setattr(
        kasa_api.Config, "KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT", 0.05
    )


async def _within(coro, seconds=2.0):
    # A guard of its own, so an unbounded disconnect fails the test instead of hanging it.
    return await asyncio.wait_for(coro, timeout=seconds)


@pytest.mark.unit
def test_a_hanging_disconnect_is_abandoned_after_the_cleanup_timeout(short_cleanup):
    device = _HangingDevice()
    asyncio.run(_within(KasaAPI.disconnect_device(device)))
    assert device.disconnect_started


@pytest.mark.unit
def test_a_hanging_close_of_a_discarded_probe_is_abandoned_too(short_cleanup):
    device = _HangingDevice()
    asyncio.run(_within(kasa_api._close_quietly(device)))
    assert device.disconnect_started
