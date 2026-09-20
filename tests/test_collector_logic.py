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
        threshold = config.Config.KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD
        for _ in range(threshold):
            await dm.remove_missing_devices({})  # discovery returned nothing
        assert "manual-host" in dm.devices  # manual device protected
        assert "10.0.0.9" not in dm.devices  # discovered-and-now-missing pruned
        assert "10.0.0.9" not in dm.emeter_devices

    async def test_single_missed_round_does_not_prune(self, monkeypatch):
        """Discovery is a lossy UDP broadcast — one miss is not absence.

        Observed live: a device reachable on both ports, with zero errors logged,
        dropped out of collection because it missed a single broadcast round.
        """
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)

        await dm.remove_missing_devices({})
        assert "10.0.0.9" in dm.devices  # still collecting after one miss
        assert dm.discovery_misses["10.0.0.9"] == 1

        await dm.remove_missing_devices({})
        assert "10.0.0.9" in dm.devices  # and after two
        assert dm.discovery_misses["10.0.0.9"] == 2

        await dm.remove_missing_devices({})
        assert "10.0.0.9" not in dm.devices  # pruned on the third
        assert "10.0.0.9" not in dm.emeter_devices

    async def test_reappearing_device_resets_the_miss_count(self, monkeypatch):
        # Two misses then a sighting must not leave the device one miss from
        # eviction -- otherwise intermittent loss still evicts a healthy host.
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        dm = self._dm(monkeypatch)
        device = SimpleNamespace(alias="Fridge", host="10.0.0.9")
        dm.devices = {"10.0.0.9": device}

        await dm.remove_missing_devices({})
        await dm.remove_missing_devices({})
        assert dm.discovery_misses["10.0.0.9"] == 2

        await dm.remove_missing_devices({"10.0.0.9": device})  # seen again
        assert dm.discovery_misses.get("10.0.0.9", 0) == 0

        # A fresh run of misses must start from zero, not from two.
        await dm.remove_missing_devices({})
        await dm.remove_missing_devices({})
        assert "10.0.0.9" in dm.devices


@pytest.mark.unit
class TestPollEvidenceOutranksDiscovery:
    """A device we are still polling must never be pruned as missing.

    Live incident (KASACOLLEC-70): five devices stopped answering broadcast discovery
    entirely -- captured on the wire, they emitted nothing while eleven siblings on the
    same segment replied -- while continuing to serve every poll. The collector deleted
    them anyway. One lost its last reading THREE SECONDS before being removed:

        10.10.7.68  last successful data point  04:59:10Z
        10.10.7.68  deleted as "missing"        04:59:13Z

    Discovery absence is an inference; a successful poll is direct evidence. The
    threshold work in KASACOLLEC-65 could not help -- it only sets how many rounds to
    keep trusting the wrong signal.
    """

    def _dm(self, monkeypatch):
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_polling_device_survives_never_being_discovered(self, monkeypatch):
        """The regression. Fails on pre-fix code: the device is pruned on round 3."""
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)

        # Far more rounds than the threshold, and discovery NEVER sees it -- exactly the
        # live shape, where broadcast silence was permanent rather than transient.
        for _ in range(10):
            dm.mark_reachable("10.0.0.9")  # ...but every poll succeeds
            await dm.remove_missing_devices({})

        assert "10.0.0.9" in dm.devices
        assert "10.0.0.9" in dm.emeter_devices
        # Never accrues misses: a poll is as good as a sighting.
        assert dm.discovery_misses.get("10.0.0.9", 0) == 0

    async def test_device_that_stops_answering_polls_is_still_pruned(self, monkeypatch):
        """The control. Without it the fix could simply disable pruning."""
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)

        dm.mark_reachable("10.0.0.9")
        # Age the evidence past the grace window, then stop answering.
        from app.core import config

        dm.last_poll_ok["10.0.0.9"] = (
            dm.last_poll_ok["10.0.0.9"]
            - config.Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL
            - 1
        )
        for _ in range(3):
            await dm.remove_missing_devices({})

        assert "10.0.0.9" not in dm.devices
        assert "10.0.0.9" not in dm.emeter_devices
        assert "10.0.0.9" not in dm.last_poll_ok  # evidence cleaned up with the device

    async def test_poll_evidence_does_not_rescue_a_device_that_never_polled(
        self, monkeypatch
    ):
        """A device with no successful poll on record prunes as before."""
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        for _ in range(3):
            await dm.remove_missing_devices({})
        assert "10.0.0.9" not in dm.devices


@pytest.mark.unit
class TestRetiredDevicesAreReclaimed:
    """Pruning must stop us POLLING a device, not erase that it ever existed.

    Before this, `self.devices.pop(ip)` was the whole mechanism and there was no other
    record — the three registries all mean "currently collecting". So the address went
    with it, and the only route back was the very broadcast that had already failed.
    A device quiet for 15 minutes was unrecoverable without a human editing
    DEVICE_HOSTS.

    Measured live: two devices went silent to broadcast for twelve hours and then began
    answering again on their own, nothing changed. Both answered a direct connection
    throughout. Broadcast silence drifts over HOURS; pruning judges it in minutes.
    """

    def _dm(self, monkeypatch):
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 1)
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_pruned_device_is_remembered_not_erased(self, monkeypatch):
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)

        await dm.remove_missing_devices({})

        assert "10.0.0.9" not in dm.devices  # stopped polling it
        assert "10.0.0.9" in dm.retired  # but did not forget it

    async def test_retired_device_that_answers_unicast_is_reclaimed(self, monkeypatch):
        """The regression. Fails pre-fix: nothing ever re-probes a pruned address."""
        dm = self._dm(monkeypatch)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)
        await dm.remove_missing_devices({})
        assert "10.0.0.9" in dm.retired

        # It is back on the network but STILL invisible to broadcast — the live shape.
        recovered = SimpleNamespace(alias="Fridge", host="10.0.0.9", modules={})

        async def fake_get_device(ip, user, pw):
            assert ip == "10.0.0.9"
            return recovered

        monkeypatch.setattr(
            "app.collector.device_manager.KasaAPI.get_device", fake_get_device
        )
        await dm.reclaim_retired_devices({})  # discovery STILL returns nothing

        assert dm.devices["10.0.0.9"] is recovered  # walked back in by itself
        assert "10.0.0.9" not in dm.retired
        assert "10.0.0.9" in dm.last_poll_ok  # and is protected from re-pruning

    async def test_still_unreachable_device_stays_retired(self, monkeypatch):
        """The control: a genuinely departed device must not be resurrected,
        and its failure must not abort the pass for its siblings."""
        dm = self._dm(monkeypatch)
        dm.retired = {"10.0.0.9": 0.0, "10.0.0.8": 0.0}

        async def fake_get_device(ip, user, pw):
            if ip == "10.0.0.8":
                return SimpleNamespace(alias="Back", host="10.0.0.8", modules={})
            raise ConnectionError("host unreachable")

        monkeypatch.setattr(
            "app.collector.device_manager.KasaAPI.get_device", fake_get_device
        )
        await dm.reclaim_retired_devices({})

        assert "10.0.0.9" not in dm.devices  # still gone
        assert "10.0.0.9" in dm.retired  # and still remembered for next round
        assert "10.0.0.8" in dm.devices  # sibling unaffected by the failure

    async def test_device_discovery_returns_is_left_to_the_normal_path(
        self, monkeypatch
    ):
        """No double-registration: if broadcast found it, reclaim keeps its hands off."""
        dm = self._dm(monkeypatch)
        dm.retired = {"10.0.0.9": 0.0}
        called = []

        async def fake_get_device(ip, user, pw):
            called.append(ip)
            raise AssertionError("must not probe a device discovery already returned")

        monkeypatch.setattr(
            "app.collector.device_manager.KasaAPI.get_device", fake_get_device
        )
        device = SimpleNamespace(alias="Fridge", host="10.0.0.9")
        await dm.reclaim_retired_devices({"10.0.0.9": device})

        assert called == []
        assert "10.0.0.9" not in dm.retired  # handed over to the auth path


@pytest.mark.unit
class TestPollerReportsReachability:
    """The wiring half: the poller must actually report what it observed.

    Tested separately from the pruning logic because the defect was the ABSENCE of a
    connection between the two -- `discovery_misses` was written and read in one
    function and nothing in the polling path ever reached it. A test that only
    exercised DeviceManager would pass with the poller still silent.
    """

    def _poller(self):
        from app.collector.poller import Poller

        poller = object.__new__(Poller)
        poller.logger = logging.getLogger("test")
        seen: list[str] = []
        poller.on_reachable = seen.append
        return poller, seen

    async def test_successful_poll_reports_reachable(self):
        poller, seen = self._poller()

        async def ok(ip, device):
            return True

        await poller._fetch_counted(ok, "10.0.0.1", None, {"ok": 0}, "emeter fetch")
        assert seen == ["10.0.0.1"]

    async def test_influx_write_failure_still_reports_reachable(self):
        """A rejected write is a STORAGE failure. The device answered."""
        poller, seen = self._poller()

        async def polled_but_write_failed(ip, device):
            return False

        await poller._fetch_counted(
            polled_but_write_failed,
            "10.0.0.1",
            None,
            {"ok": 0, "write_failed": 0},
            "emeter fetch",
        )
        assert seen == ["10.0.0.1"]

    async def test_failed_poll_reports_nothing(self):
        """No answer, no evidence -- the device must stay eligible for pruning."""
        poller, seen = self._poller()

        async def boom(ip, device):
            raise ConnectionError("device unreachable")

        await poller._fetch_counted(
            boom, "10.0.0.2", None, {"ok": 0, "failed": 0}, "emeter fetch"
        )
        assert seen == []


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


@pytest.mark.unit
class TestManualHostsAreIntent:
    """A host in KASA_COLLECTOR_DEVICE_HOSTS must converge to collected.

    Listing a host in the env var is an explicit operator statement, so it cannot
    depend on a lossy broadcast OR on the one moment the process started. The old
    code called initialize_manual_devices() exactly once at startup: a manual host
    unreachable at that instant was absent for the life of the process.
    """

    def _dm(self, monkeypatch):
        async def fake_hostname(ip):
            return f"host-{ip}"

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_missing_manual_host_is_retried_on_a_later_pass(self, monkeypatch):
        from app.collector import device_manager as dm_mod

        attempts: list[str] = []
        fail_first = {"on": True}

        async def fake_get_device(ip, user, pw):
            attempts.append(ip)
            if fail_first["on"]:
                raise ConnectionError("device rebooting")
            return SimpleNamespace(alias="Recovered", host=ip, has_emeter=False)

        async def no_devices_found():
            return {}

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        monkeypatch.setattr(dm_mod.KasaAPI, "discover_devices", no_devices_found)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]

        await dm.connect()  # startup: device is down
        assert dm.devices == {}  # not registered

        fail_first["on"] = False
        # The contract is that a DISCOVERY PASS reconciles configured hosts -- not that
        # someone remembers to call reconcile. Asserting the wiring is the point: the
        # old code called initialize_manual_devices() only from connect(), so a later
        # discovery pass did nothing for a manual host that had failed at startup.
        await dm.discover_devices()
        assert "kasa-backroom-fridge.example.com" in dm.devices  # recovered
        assert len(attempts) > 1  # re-attempted, not abandoned after startup

    async def test_already_registered_manual_host_is_not_reconnected(self, monkeypatch):
        # Re-connecting a working device every cycle would churn its session for
        # nothing -- reconcile must only attempt hosts that are actually absent.
        from app.collector import device_manager as dm_mod

        attempts: list[str] = []

        async def fake_get_device(ip, user, pw):
            attempts.append(ip)
            return SimpleNamespace(alias="X", host=ip, has_emeter=False)

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["a.example.com"]
        dm.devices = {"a.example.com": SimpleNamespace(alias="X", host="a.example.com")}

        await dm.reconcile_manual_devices()
        assert attempts == []  # nothing re-attempted


@pytest.mark.unit
class TestManualHostKeyedByResolvedAddress:
    """A manually configured host is registered by its RESOLVED address.

    The `ip` tag on every point comes from the registry key. Keying manual hosts on
    the raw DEVICE_HOSTS string meant a tag named `ip` held an IP for discovered
    devices and a DNS name for configured ones -- in the same measurement, so it
    could not be grouped or joined on (KASACOLLEC-64).
    """

    def _dm(self, monkeypatch):
        async def fake_hostname(ip):
            return f"host-{ip}"

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_registry_key_is_the_resolved_ip_not_the_configured_name(
        self, monkeypatch
    ):
        from app.collector import device_manager as dm_mod

        async def fake_get_device(entry, user, pw):
            # get_device resolves the name up front and connects on the address,
            # so device.host is the resolved IPv4 on every path.
            return SimpleNamespace(alias="Fridge", host="10.50.0.100", has_emeter=False)

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]

        await dm.reconcile_manual_devices()
        assert "10.50.0.100" in dm.devices  # keyed by address
        assert "kasa-backroom-fridge.example.com" not in dm.devices
        assert dm.manual_addresses["kasa-backroom-fridge.example.com"] == "10.50.0.100"

    async def test_resolved_manual_host_is_not_reattempted(self, monkeypatch):
        # reconcile must recognise the host as registered via the mapping, or it
        # would reconnect (and re-handshake) a working device every cycle.
        from app.collector import device_manager as dm_mod

        attempts: list[str] = []

        async def fake_get_device(entry, user, pw):
            attempts.append(entry)
            return SimpleNamespace(alias="Fridge", host="10.50.0.100", has_emeter=False)

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]

        await dm.reconcile_manual_devices()
        await dm.reconcile_manual_devices()
        assert attempts == ["kasa-backroom-fridge.example.com"]  # attempted once

    async def test_resolved_manual_host_is_still_protected_from_pruning(
        self, monkeypatch
    ):
        # The prune guard matched the registry key against device_hosts. Once the key
        # is an address that no longer matches, so the mapping has to be consulted --
        # otherwise every Boutique device would be pruned on the first discovery pass.
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 1)
        dm = self._dm(monkeypatch)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]
        dm.manual_addresses = {"kasa-backroom-fridge.example.com": "10.50.0.100"}
        dm.devices = {"10.50.0.100": SimpleNamespace(alias="F", host="10.50.0.100")}

        await dm.remove_missing_devices({})  # never appears in a broadcast
        assert "10.50.0.100" in dm.devices  # protected
