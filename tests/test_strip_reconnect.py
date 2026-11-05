"""A SMART strip whose outlet python-kasa gave up on is reconnected in place.

python-kasa disables an outlet's energy module after 10 errors and never re-enables it
on that client. The strip is connected afresh while it keeps being polled on the old
client, the new client is swapped in, and the old one is closed once no fetch holds it.
Driven through the real python-kasa client over KLAP v2 against harness/fake_smart.py.
"""

import asyncio

import pytest
from kasa import Device, Module

import tests.test_smart_strip_edges as edges
from tests.test_smart_strip_edges import (
    _connect,
    _drop_outlet,
    _expected,
    _outlet_energy_fails,
    _outlet_power_by_plug_id,
    _poller,
)

pytestmark = pytest.mark.unit
fake = edges.fake  # the fixture
IP = "127.0.0.1"


class _Registry:
    """The DeviceManager's registry contract, holding one strip."""

    def __init__(self, strip, connect):
        from app.collector.device_manager import DeviceManager

        self.manager = object.__new__(DeviceManager)
        self.manager.devices = {IP: strip}
        self.manager.emeter_devices = {IP: strip}
        self.manager.polling_devices = {IP: strip}
        self.connect = connect
        self.connects = 0

    def is_current(self, key, device):
        return self.manager.is_current(key, device)

    async def connect_fresh(self, key):
        self.connects += 1
        return await self.connect()

    def swap_client(self, key, old, new):
        return self.manager.swap_client(key, old, new)

    @property
    def current(self) -> Device:
        return self.manager.devices[IP]


async def _disable_outlet_3(fake, monkeypatch, strip):
    await strip.update()
    real, failing = _outlet_energy_fails(fake, 3)
    monkeypatch.setattr(fake, "outlet_methods", failing)
    energy = strip.children[2].modules[Module.Energy]
    for _ in range(10):
        energy._last_update_time = 1.0  # the backoff has elapsed
        await strip.update()
    assert energy.disabled
    monkeypatch.setattr(fake, "outlet_methods", real)  # the outlet recovers


def _session(strip):
    return strip.protocol._transport._http_client._client_session


async def _setup(fake, monkeypatch):
    server, strip = await _connect(fake)
    clients = []

    async def connect():
        _, new = await _connect_on(fake, server)
        await new.update()
        clients.append(new)
        return new

    poller = _poller(monkeypatch)
    poller.on_reachable = None
    registry = _Registry(strip, connect)
    poller.registry = registry
    return server, strip, poller, registry, clients


async def _connect_on(fake, server):
    from kasa import Credentials, DeviceConfig, DeviceConnectionParameters
    from kasa.deviceconfig import DeviceEncryptionType, DeviceFamily

    port = server.sockets[0].getsockname()[1]
    config = DeviceConfig(
        host=IP,
        credentials=Credentials(edges.USERNAME, edges.PASSWORD),
        connection_type=DeviceConnectionParameters(
            DeviceFamily.SmartTapoPlug,
            DeviceEncryptionType.Klap,
            login_version=2,
            http_port=port,
        ),
    )
    return server, await Device.connect(config=config)


async def _cycle(poller, registry, *fetches):
    """One cycle over the live registry, as the poll loops run it."""
    outcome = {"ok": 0, "failed": 0, "write_failed": 0}
    async with asyncio.TaskGroup() as tg:
        for fetch, interval in fetches:
            for ip, device in list(registry.manager.emeter_devices.items()):
                tg.create_task(
                    poller._fetch_counted(fetch, ip, device, outcome, "f", interval)
                )
    return outcome


async def _settle(poller):
    tasks = list(poller._clients().tasks.values())
    if tasks:
        await asyncio.gather(*tasks)


async def test_a_disabled_outlet_reconnects_the_strip_in_place(fake, monkeypatch):
    server, strip, poller, registry, clients = await _setup(fake, monkeypatch)
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        poller.storage.captured.clear()

        await _cycle(poller, registry, (poller.process_smart_strip_data, 15))
        # The cycle that saw the disabled outlet still wrote every other outlet.
        assert sorted(_outlet_power_by_plug_id(poller.storage.captured)) == [
            "1",
            "2",
            "4",
            "5",
            "6",
        ]
        await _settle(poller)

        assert registry.current is clients[0]
        assert registry.manager.emeter_devices[IP] is clients[0]
        assert _session(strip) is None  # the old client is closed

        poller.storage.captured.clear()
        await clients[0].update()
        await _cycle(poller, registry, (poller.process_smart_strip_data, 15))
        assert _outlet_power_by_plug_id(poller.storage.captured) == {
            str(n): _expected(n) for n in range(1, 7)
        }
    finally:
        for client in clients:
            await client.disconnect()
        server.close()


async def test_the_old_client_is_closed_only_after_every_fetch_lets_go(
    fake, monkeypatch
):
    # The emeter and sysinfo loops both hold the strip; the reconnect finishes while
    # the sysinfo fetch is still in flight. The old client must not be closed under
    # it, and must not be left open once it is done.
    server, strip, poller, registry, clients = await _setup(fake, monkeypatch)
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        await _cycle(
            poller,
            registry,
            (poller.process_smart_strip_data, 15),
            (poller.fetch_and_store_sysinfo, 60),
        )
        await _settle(poller)
        await asyncio.sleep(0)

        assert registry.current is clients[0]
        assert _session(strip) is None
        assert poller._clients().in_flight == {}
        assert poller._clients().retiring == {}
    finally:
        for client in clients:
            await client.disconnect()
        server.close()


async def test_a_replaced_client_is_never_fetched_again(fake, monkeypatch):
    server, strip, poller, registry, clients = await _setup(fake, monkeypatch)
    try:
        replacement = object()
        registry.manager.devices[IP] = replacement
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        await poller._fetch_counted(
            poller.fetch_and_store_sysinfo, IP, strip, outcome, "s", 60
        )

        assert outcome == {"ok": 0, "failed": 0, "write_failed": 0}
        assert poller.storage.captured == []
    finally:
        await strip.disconnect()
        server.close()


async def test_reconnects_of_one_strip_back_off(fake, monkeypatch):
    server, strip, poller, registry, clients = await _setup(fake, monkeypatch)

    async def failing():
        raise ConnectionError("strip unreachable")

    registry.connect = failing
    try:
        await _disable_outlet_3(fake, monkeypatch, strip)
        for _ in range(3):
            await _cycle(poller, registry, (poller.process_smart_strip_data, 15))
            await _settle(poller)

        assert registry.connects == 1  # within the first back-off gap
        assert registry.current is strip  # still polled on the old client
    finally:
        await strip.disconnect()
        server.close()


async def test_a_reorder_then_a_missing_position_keeps_every_series(fake, monkeypatch):
    # Outlet 2 misses one child list (python-kasa re-creates it at the end of the
    # children); later outlet 5 reports no position. Each outlet keeps its series.
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)

    async def poll():
        poller.storage.captured.clear()
        await strip.update()
        assert await poller.process_smart_strip_data(IP, strip)
        return _outlet_power_by_plug_id(poller.storage.captured)

    try:
        await poll()
        real, dropped = _drop_outlet(fake, 2)
        monkeypatch.setattr(fake, "parent_methods", dropped)
        await poll()
        monkeypatch.setattr(fake, "parent_methods", real)
        assert await poll() == {str(n): _expected(n) for n in range(1, 7)}

        def no_position_for_5():
            m = real()
            for child in m["get_child_device_list"]["child_device_list"]:
                if child.get("position") == 5:
                    child.pop("position")
            return m

        monkeypatch.setattr(fake, "parent_methods", no_position_for_5)
        assert await poll() == {str(n): _expected(n) for n in range(1, 7)}
    finally:
        await strip.disconnect()
        server.close()


@pytest.mark.parametrize(
    ("positions", "expected"),
    [
        ([0, 1, 2, 3, 4, 5], ["1", "2", "3", "4", "5", "6"]),
        ([1, 2, None, 4, 5, 6], ["1", "2", "3", "4", "5", "6"]),
        ([1, 1, 2, 3, 4, 5], ["1", "2", "3", "4", "5"]),
    ],
    ids=["zero-based", "one-missing", "duplicate"],
)
async def test_two_outlets_never_share_a_plug_id(
    fake, monkeypatch, positions, expected
):
    def bend(info, n):
        if positions[n - 1] is None:
            info.pop("position", None)
        else:
            info["position"] = positions[n - 1]

    real_parent, real_outlet = fake.parent_methods, fake.outlet_methods

    def parent_methods():
        m = real_parent()
        for n, child in enumerate(m["get_child_device_list"]["child_device_list"], 1):
            bend(child, n)
        return m

    def outlet_methods(n):
        m = real_outlet(n)
        bend(m["get_device_info"], n)
        return m

    monkeypatch.setattr(fake, "parent_methods", parent_methods)
    monkeypatch.setattr(fake, "outlet_methods", outlet_methods)
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await strip.update()
        assert await poller.process_smart_strip_data(IP, strip)
        plug_ids = [
            dict(p._tags)["plug_id"]
            for p in poller.storage.captured
            if dict(p._tags).get("equipment_type") == "plug" and "power_mw" in p._fields
        ]
        assert sorted(plug_ids) == expected  # a duplicate is left out, not merged
    finally:
        await strip.disconnect()
        server.close()


def test_the_device_manager_swaps_only_the_client_it_still_holds():
    from app.collector.device_manager import DeviceManager

    manager = object.__new__(DeviceManager)
    old, new, other = object(), object(), object()
    manager.devices = {IP: old}
    manager.emeter_devices = {IP: old}
    manager.polling_devices = {IP: old}

    assert manager.is_current(IP, old)
    assert manager.swap_client(IP, old, new)
    assert manager.devices[IP] is new
    assert manager.emeter_devices[IP] is new
    assert manager.polling_devices[IP] is new
    assert not manager.swap_client(IP, old, other)  # already replaced
    assert manager.devices[IP] is new
