"""KasaAPI.get_device closes a client it built when the connection then fails or is
cancelled, so no caller (a reconnect, a manual add, a reclaim) leaks a session."""

import asyncio

import pytest

from app.collector import kasa_api

pytestmark = pytest.mark.unit


class _Client:
    def __init__(self, update_exc=None, gate=None):
        self.closed = False
        self.update_exc = update_exc
        self.gate = gate
        self.alias = "strip"
        self.model = "P316M"
        self.has_emeter = True
        self.host = "127.0.0.1"

    async def update(self):
        if self.gate is not None:
            await self.gate.wait()
        if self.update_exc is not None:
            raise self.update_exc

    async def disconnect(self):
        self.closed = True


@pytest.mark.parametrize("update_fails", [False, True], ids=["control-ok", "fails"])
async def test_a_failed_direct_connect_closes_its_client(monkeypatch, update_fails):
    async def no_discovery(*a, **k):
        raise OSError("no discovery reply")

    client = _Client(update_exc=TimeoutError("strip busy") if update_fails else None)

    async def connect(**k):
        return client

    async def same(d):
        return d

    monkeypatch.setattr(kasa_api.Discover, "discover_single", no_discovery)
    monkeypatch.setattr(kasa_api.Device, "connect", connect)
    monkeypatch.setattr(kasa_api, "reclass_strip_if_needed", same)
    if update_fails:
        with pytest.raises(TimeoutError):
            await kasa_api.KasaAPI.get_device("127.0.0.1")
        assert client.closed, "the client built for the failed attempt was left open"
    else:
        got = await kasa_api.KasaAPI.get_device("127.0.0.1")
        assert got is client and not client.closed


@pytest.mark.parametrize("cancel", [False, True], ids=["control-ok", "cancelled"])
async def test_a_cancelled_connect_closes_its_client(monkeypatch, cancel):
    gate = asyncio.Event()
    client = _Client(gate=gate)

    async def discovered(*a, **k):
        return client

    async def same(d):
        return d

    monkeypatch.setattr(kasa_api.Discover, "discover_single", discovered)
    monkeypatch.setattr(kasa_api, "reclass_strip_if_needed", same)
    task = asyncio.ensure_future(kasa_api.KasaAPI.get_device("127.0.0.1"))
    await asyncio.sleep(0.01)  # discover_single returned; update() in flight
    if cancel:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert client.closed, "the client built before the cancel was left open"
    else:
        gate.set()
        assert await task is client and not client.closed
