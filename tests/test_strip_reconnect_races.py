"""The in-place SMART strip reconnect under races: a missing zero-based outlet, shutdown,
a key pruned while connecting, a cancelled fetch, an outlet that stays broken."""

import asyncio
import logging

import pytest
from kasa import Module

import tests.test_smart_strip_edges as edges
from tests.test_smart_strip_edges import (
    _connect,
    _expected,
    _outlet_energy_fails,
    _outlet_power_by_plug_id,
    _poller,
)
from tests.test_strip_reconnect import _connect_on, _cycle, _disable_outlet_3, _session

pytestmark = pytest.mark.unit
fake = edges.fake
IP = "127.0.0.1"


# ----------------------------------------------------------- positions: zero-based


def _bent(fake, base):
    """Outlet n reports position n-1+base; outlet state['drop'] misses the child list."""
    real_parent, real_outlet = fake.parent_methods, fake.outlet_methods
    state = {"drop": None}

    def parent_methods():
        m = real_parent()
        lst = m["get_child_device_list"]
        kids = []
        for n, child in enumerate(lst["child_device_list"], 1):
            child["position"] = n - 1 + base
            if state["drop"] != n:
                kids.append(child)
        lst["child_device_list"] = kids
        lst["sum"] = len(kids)
        return m

    def outlet_methods(n):
        m = real_outlet(n)
        m["get_device_info"]["position"] = n - 1 + base
        return m

    return state, parent_methods, outlet_methods


async def _poll(poller, strip):
    poller.storage.captured.clear()
    await strip.update()
    assert await poller.process_smart_strip_data(IP, strip)
    return _outlet_power_by_plug_id(poller.storage.captured)


@pytest.mark.parametrize("base", [1, 0], ids=["control-one-based", "zero-based"])
async def test_an_outlet_missing_one_poll_never_moves_the_others(
    fake, monkeypatch, base
):
    state, parent, outlet = _bent(fake, base)
    monkeypatch.setattr(fake, "parent_methods", parent)
    monkeypatch.setattr(fake, "outlet_methods", outlet)
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        assert await _poll(poller, strip) == {str(n): _expected(n) for n in range(1, 7)}
        state["drop"] = 1  # the outlet at the first position misses one child list
        got = await _poll(poller, strip)
        # Every outlet that WAS written stays in its own series.
        wrong = {k: v for k, v in got.items() if v != _expected(int(k))}
        assert wrong == {}, got
    finally:
        await strip.disconnect()
        server.close()


# ------------------------------------------------- shutdown racing the reconnect


class _R:
    pass


async def _manager_setup(fake, monkeypatch):
    from app.collector.device_manager import DeviceManager

    server, strip = await _connect(fake)
    manager = object.__new__(DeviceManager)
    manager.logger = logging.getLogger("test")
    manager.devices = {IP: strip}
    manager.emeter_devices = {IP: strip}
    manager.polling_devices = {IP: strip}
    gate = asyncio.Event()
    clients = []

    async def connect_fresh(key):
        _, new = await _connect_on(fake, server)
        await new.update()
        clients.append(new)
        await gate.wait()  # the new client is connected; the reconnect is finishing
        return new

    manager.connect_fresh = connect_fresh
    poller = _poller(monkeypatch)
    poller.on_reachable = None
    poller.registry = manager
    reg = _R()
    reg.manager = manager
    return server, strip, manager, poller, reg, gate, clients


async def _until_connected(clients):
    for _ in range(300):
        if clients:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("fresh client never connected")


@pytest.mark.parametrize("finishes", ["control-after", "during"])
async def test_shutdown_leaves_no_client_open(fake, monkeypatch, finishes):
    from app.collector import device_manager as dm

    server, strip, manager, poller, reg, gate, clients = await _manager_setup(
        fake, monkeypatch
    )
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        await _cycle(poller, reg, (poller.process_smart_strip_data, 15))
        task = poller._clients().tasks[IP]
        await _until_connected(clients)

        real_disconnect = dm.KasaAPI.disconnect_device

        async def slow_disconnect(device):
            if finishes == "during":
                gate.set()  # the reconnect completes while shutdown's disconnect runs
                await asyncio.sleep(0.05)
            await real_disconnect(device)

        monkeypatch.setattr(dm.KasaAPI, "disconnect_device", slow_disconnect)
        await manager.disconnect_all_devices()  # KasaCollector.shutdown -> close()
        gate.set()
        await asyncio.wait_for(task, 5)

        assert manager.devices == {}
        assert _session(strip) is None
        assert [c for c in clients if _session(c) is not None] == []  # none leaked
    finally:
        for c in clients:
            await c.disconnect()
        server.close()


# ------------------------------------------- reconnect while discovery prunes it


async def test_a_key_pruned_while_connecting_is_not_re_added(fake, monkeypatch):
    server, strip, manager, poller, reg, gate, clients = await _manager_setup(
        fake, monkeypatch
    )
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        await _cycle(poller, reg, (poller.process_smart_strip_data, 15))
        task = poller._clients().tasks[IP]
        manager.devices.pop(IP)  # remove_missing_devices' pops
        manager.emeter_devices.pop(IP)
        manager.polling_devices.pop(IP)
        gate.set()
        await asyncio.wait_for(task, 5)
        assert manager.devices == {} and manager.emeter_devices == {}
        assert all(_session(c) is None for c in clients)
    finally:
        await strip.disconnect()
        for c in clients:
            await c.disconnect()
        server.close()


# ------------------------------------------------------ fetch cancelled mid-flight


async def test_a_cancelled_fetch_still_lets_the_old_client_close(fake, monkeypatch):
    server, strip, manager, poller, reg, gate, clients = await _manager_setup(
        fake, monkeypatch
    )
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        await _cycle(poller, reg, (poller.process_smart_strip_data, 15))
        task = poller._clients().tasks[IP]
        started = asyncio.Event()

        async def hang(ip, device):
            started.set()
            await asyncio.sleep(3600)

        outcome = {"ok": 0, "failed": 0, "write_failed": 0}
        fetch = asyncio.create_task(
            poller._fetch_counted(hang, IP, strip, outcome, "s", 60)
        )
        await started.wait()
        gate.set()
        await asyncio.wait_for(task, 5)
        assert manager.devices[IP] is clients[0]
        assert _session(strip) is not None  # still held: not closed under the fetch
        fetch.cancel()
        with pytest.raises(asyncio.CancelledError):
            await fetch
        assert _session(strip) is None
        assert poller._clients().in_flight == {}
        assert poller._clients().retiring == {}
    finally:
        for c in clients:
            await c.disconnect()
        server.close()


# ------------------------------------------------ an outlet that keeps failing


async def test_an_outlet_that_stays_broken_does_not_reconnect_in_a_loop(
    fake, monkeypatch
):
    server, strip, manager, poller, reg, gate, clients = await _manager_setup(
        fake, monkeypatch
    )
    gate.set()
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        _, failing = _outlet_energy_fails(fake, 3)
        monkeypatch.setattr(fake, "outlet_methods", failing)  # it never recovers
        for _ in range(30):
            cur = manager.devices[IP]
            e = cur.children[2].modules.get(Module.Energy) if cur.children else None
            if e is not None:
                e._last_update_time = 1.0
            await cur.update()
            await _cycle(poller, reg, (poller.process_smart_strip_data, 15))
            t = poller._clients().tasks.get(IP)
            if t:
                await t
        assert len(clients) == 1  # one reconnect within the first gap
    finally:
        for c in [strip, *clients]:
            await c.disconnect()
        server.close()
