"""A DEVICE_HOSTS name that moves to another address, over whole discovery passes.

After a DHCP move and a DNS update, the configured device is collected at its new
address only, and whatever takes the old address is neither polled nor credentialed.
"""

import logging
from types import SimpleNamespace

import pytest

pytestmark = pytest.mark.unit

PASSWORD = "".join(["hunter2", "-secret"])


class Plug(SimpleNamespace):
    async def disconnect(self):
        self.closed = True


def _manager(monkeypatch, tmp_path, dns, *, trust=True):
    """A DeviceManager whose forward DNS is ``dns`` (a name -> a list of A records, or
    a callable giving one) and whose broadcast discovery sees nothing."""
    from app.collector import device_manager as dm_mod
    from app.core import config

    async def hostname(ip):
        return f"host-{ip}"

    async def resolve(host):
        if host not in dns:
            raise OSError(f"{host} does not resolve")
        records = dns[host]
        return list(records() if callable(records) else records)

    async def no_broadcast():
        return {}  # cross-subnet: why the device was listed by name

    monkeypatch.setattr(dm_mod, "get_hostname_cached", hostname)
    monkeypatch.setattr(dm_mod, "resolve_ipv4s", resolve)
    monkeypatch.setattr(dm_mod.KasaAPI, "discover_devices", no_broadcast)
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES", trust)
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY", True)
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_TPLINK_USERNAME", "owner@x")
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_TPLINK_PASSWORD", PASSWORD)
    manager = dm_mod.DeviceManager(logging.getLogger("test"))
    manager.device_hosts = ["plug.lan"]
    return manager


def _connect_as(monkeypatch, address_for, calls):
    """get_device connects at ``address_for(entry)``; every call is recorded."""
    from app.collector import device_manager as dm_mod

    async def get_device(entry, user=None, pw=None, **kwargs):
        ip = address_for(entry)
        calls.append((entry, ip, pw))
        return Plug(alias=f"dev@{ip}", host=ip, has_emeter=True, closed=False)

    monkeypatch.setattr(dm_mod.KasaAPI, "get_device", get_device)


@pytest.mark.parametrize("trust", [True, False])
async def test_the_old_address_stays_dropped_over_a_whole_pass(
    monkeypatch, tmp_path, trust
):
    # The reclaim probe walks the remembered roster in the same pass: the moved name's
    # old address must not be in it.
    dns = {"plug.lan": ["10.0.0.50"]}
    manager = _manager(monkeypatch, tmp_path, dns, trust=trust)
    calls: list = []
    _connect_as(monkeypatch, lambda e: dns[e][0] if e in dns else e, calls)

    await manager.discover_devices()
    assert set(manager.devices) == {"10.0.0.50"}

    dns["plug.lan"] = ["10.0.0.77"]
    calls.clear()
    await manager.discover_devices()

    assert set(manager.devices) == {"10.0.0.77"}
    assert "10.0.0.50" not in manager.known_addresses
    assert all(ip != "10.0.0.50" for _, ip, _ in calls), calls


async def test_a_name_with_two_records_in_rotating_order_never_reconnects(
    monkeypatch, tmp_path
):
    turn = {"n": 0}

    def rotating():
        turn["n"] += 1
        return ["10.0.0.50", "10.0.0.77"][:: 1 if turn["n"] % 2 else -1]

    dns = {"plug.lan": rotating}
    manager = _manager(monkeypatch, tmp_path, dns)
    calls: list = []
    _connect_as(monkeypatch, lambda e: rotating()[0] if e == "plug.lan" else e, calls)

    for _ in range(5):
        await manager.reconcile_manual_devices()

    assert len(calls) == 1, calls


async def test_a_moved_name_is_added_at_the_address_its_pass_decided_on(
    monkeypatch, tmp_path
):
    dns = {"plug.lan": ["10.0.0.50"]}
    manager = _manager(monkeypatch, tmp_path, dns)
    calls: list = []
    second_lookup = {"plug.lan": "10.0.0.99"}  # what a second lookup would say
    _connect_as(
        monkeypatch,
        lambda e: second_lookup.get(e, e) if calls else dns[e][0],
        calls,
    )
    await manager.reconcile_manual_devices()

    dns["plug.lan"] = ["10.0.0.77"]
    await manager.reconcile_manual_devices()

    assert calls[-1][0] == "10.0.0.77"
    assert manager.manual_addresses == {"plug.lan": "10.0.0.77"}


async def test_a_re_add_onto_an_address_discovery_holds_closes_its_client(
    monkeypatch, tmp_path
):
    dns = {"plug.lan": ["10.0.0.50"]}
    manager = _manager(monkeypatch, tmp_path, dns)
    calls: list = []
    _connect_as(monkeypatch, lambda e: dns[e][0] if e in dns else e, calls)
    await manager.reconcile_manual_devices()

    discovered = Plug(alias="Kettle", host="10.0.0.77", has_emeter=True, closed=False)
    manager.devices["10.0.0.77"] = discovered
    manager.emeter_devices["10.0.0.77"] = discovered

    dns["plug.lan"] = ["10.0.0.77"]
    await manager.reconcile_manual_devices()

    assert manager.devices["10.0.0.77"] is not discovered
    assert discovered.closed


async def test_a_resolver_that_never_answers_is_bounded(monkeypatch):
    import asyncio

    from app.collector import device_manager as dm_mod

    async def hang(*args, **kwargs):
        await asyncio.sleep(30)

    monkeypatch.setattr(dm_mod, "_RESOLVE_TIMEOUT", 0.05)
    monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", hang)

    with pytest.raises(OSError):
        await dm_mod.resolve_ipv4s("plug.lan")


async def test_get_devices_own_lookup_is_bounded(monkeypatch):
    import asyncio

    from app.collector import kasa_api

    async def hang(*args, **kwargs):
        await asyncio.sleep(30)

    monkeypatch.setattr(kasa_api, "RESOLVE_TIMEOUT", 0.05)
    monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", hang)

    with pytest.raises(TimeoutError):
        await kasa_api.KasaAPI.get_device("plug.lan")
