"""Every client the device registry drops is closed, and never under a running fetch.

A pruned device, a moved manual host's old address and a client replaced by a re-add
all go through DeviceManager.release_client, which the poller makes wait for any
fetch still holding the client: closed under it, that fetch would reopen its session
and nothing would close it again.
"""

import asyncio
import logging
from types import SimpleNamespace

import pytest

from app.collector.poller import Poller
from tests.test_manual_host_moves import _connect_as, _manager

pytestmark = pytest.mark.unit


class Plug(SimpleNamespace):
    async def disconnect(self):
        self.closed = True


def _poller():
    poller = object.__new__(Poller)
    poller.logger = logging.getLogger("test")
    poller.on_reachable = None
    return poller


async def test_a_pruned_device_has_its_client_closed(monkeypatch, tmp_path):
    from app.core import config

    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
    monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 1)
    manager = _manager(monkeypatch, tmp_path, {})
    manager.device_hosts = []
    plug = Plug(alias="Kettle", host="10.0.0.9", has_emeter=True, closed=False)
    manager.devices["10.0.0.9"] = plug
    manager.emeter_devices["10.0.0.9"] = plug

    await manager.remove_missing_devices({})

    assert "10.0.0.9" not in manager.devices
    assert plug.closed


async def test_a_client_a_fetch_holds_is_closed_when_the_fetch_lets_go():
    poller = _poller()
    plug = Plug(closed=False)
    poller._clients().hold(plug)

    await poller.close_when_free(plug)
    assert not plug.closed  # a fetch still runs on it

    retired = poller._clients().release(plug)
    assert retired is plug  # _fetch_counted closes what release hands back


async def test_a_moved_hosts_old_client_is_closed_after_its_running_poll(
    monkeypatch, tmp_path
):
    # The poll of the old address is mid-update when the move is found: the close
    # waits for it, then happens.
    dns = {"plug.lan": ["10.0.0.50"]}
    manager = _manager(monkeypatch, tmp_path, dns)
    calls: list = []
    _connect_as(monkeypatch, lambda e: dns[e][0] if e in dns else e, calls)
    poller = _poller()
    poller.registry = manager
    manager.release_client = poller.close_when_free
    await manager.reconcile_manual_devices()
    old = manager.devices["10.0.0.50"]

    polling = asyncio.Event()
    finish = asyncio.Event()
    closed_during_poll: list[bool] = []

    async def slow_fetch(ip, device):
        polling.set()
        await finish.wait()
        closed_during_poll.append(device.closed)
        return True

    outcome = {"ok": 0, "failed": 0, "write_failed": 0}
    poll = asyncio.create_task(
        poller._fetch_counted(slow_fetch, "10.0.0.50", old, outcome, "e", 15)
    )
    await polling.wait()

    dns["plug.lan"] = ["10.0.0.77"]
    await manager.reconcile_manual_devices()
    assert not old.closed  # not under the running poll

    finish.set()
    await poll

    assert closed_during_poll == [False]
    assert old.closed
    assert "10.0.0.77" in manager.devices
