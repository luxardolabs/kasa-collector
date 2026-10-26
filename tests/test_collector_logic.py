"""Unit tests for retry policy and the missing-device pruning logic."""

import json
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

    async def test_returns_on_success(self, tmp_path):
        @async_retry(max_retries=3, base_delay=0, operation_name="test")
        async def ok():
            return 42

        assert await ok() == 42


@pytest.mark.unit
class TestRemoveMissingDevices:
    def _dm(self, monkeypatch, tmp_path):
        # Avoid real reverse-DNS during pruning.
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        # Isolate the persisted roster: the manager reads AND writes it at
        # construction, so a shared dir leaks devices between tests.
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_keeps_missing_when_configured(self, monkeypatch, tmp_path):
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", True)
        dm = self._dm(monkeypatch, tmp_path)
        dm.devices = {"10.0.0.1": SimpleNamespace(alias="A", host="10.0.0.1")}
        await dm.remove_missing_devices({})  # nothing discovered
        assert "10.0.0.1" in dm.devices  # kept

    async def test_prunes_discovered_but_protects_manual(self, monkeypatch, tmp_path):
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        dm = self._dm(monkeypatch, tmp_path)
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

    async def test_single_missed_round_does_not_prune(self, monkeypatch, tmp_path):
        """Discovery is a lossy UDP broadcast — one miss is not absence.

        Observed live: a device reachable on both ports, with zero errors logged,
        dropped out of collection because it missed a single broadcast round.
        """
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        dm = self._dm(monkeypatch, tmp_path)
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

    async def test_reappearing_device_resets_the_miss_count(
        self, monkeypatch, tmp_path
    ):
        # Two misses then a sighting must not leave the device one miss from
        # eviction -- otherwise intermittent loss still evicts a healthy host.
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        dm = self._dm(monkeypatch, tmp_path)
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

        192.0.2.68  last successful data point  04:59:10Z
        192.0.2.68  deleted as "missing"        04:59:13Z

    Discovery absence is an inference; a successful poll is direct evidence. The
    threshold work in KASACOLLEC-65 could not help -- it only sets how many rounds to
    keep trusting the wrong signal.
    """

    def _dm(self, monkeypatch, tmp_path):
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 3)
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_polling_device_survives_never_being_discovered(
        self, monkeypatch, tmp_path
    ):
        """The regression. Fails on pre-fix code: the device is pruned on round 3."""
        dm = self._dm(monkeypatch, tmp_path)
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

    async def test_device_that_stops_answering_polls_is_still_pruned(
        self, monkeypatch, tmp_path
    ):
        """The control. Without it the fix could simply disable pruning."""
        dm = self._dm(monkeypatch, tmp_path)
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
        self, monkeypatch, tmp_path
    ):
        """A device with no successful poll on record prunes as before."""
        dm = self._dm(monkeypatch, tmp_path)
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

    def _dm(self, monkeypatch, tmp_path):
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 1)
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_pruned_device_is_remembered_not_erased(self, monkeypatch, tmp_path):
        dm = self._dm(monkeypatch, tmp_path)
        dm.devices = {"10.0.0.9": SimpleNamespace(alias="Fridge", host="10.0.0.9")}
        dm.emeter_devices = dict(dm.devices)

        await dm.remove_missing_devices({})

        assert "10.0.0.9" not in dm.devices  # stopped polling it
        assert "10.0.0.9" in dm.retired  # but did not forget it

    async def test_retired_device_that_answers_unicast_is_reclaimed(
        self, monkeypatch, tmp_path
    ):
        """The regression. Fails pre-fix: nothing ever re-probes a pruned address."""
        dm = self._dm(monkeypatch, tmp_path)
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

    async def test_still_unreachable_device_stays_retired(self, monkeypatch, tmp_path):
        """The control: a genuinely departed device must not be resurrected,
        and its failure must not abort the pass for its siblings."""
        dm = self._dm(monkeypatch, tmp_path)
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
        self, monkeypatch, tmp_path
    ):
        """No double-registration: if broadcast found it, reclaim keeps its hands off."""
        dm = self._dm(monkeypatch, tmp_path)
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
class TestKnownDevicesSurviveRestart:
    """A device found by discovery ONCE must stay collected across restarts.

    Discovery is the product: a user is never expected to know their plug's IP
    address. Holding the roster only in memory meant a restart forgot every device
    broadcast could not see at that moment, and the sole recovery was hand-listing
    addresses in DEVICE_HOSTS -- precisely what discovery exists to spare them.

    Live, four devices were invisible to broadcast for a whole day while answering a
    direct connection instantly. Without persistence they are lost on every restart,
    forever, with no action the user could reasonably be expected to take.
    """

    def _dm(self, monkeypatch, tmp_path):
        async def fake_hostname(ip):
            return ip

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    def test_registering_a_device_persists_it(self, monkeypatch, tmp_path):
        dm = self._dm(monkeypatch, tmp_path)
        dm._check_and_add_emeter_device(
            "10.0.0.9", SimpleNamespace(alias="Fridge", has_emeter=True)
        )
        saved = json.loads((tmp_path / "known_devices.json").read_text())
        assert saved["addresses"] == ["10.0.0.9"]

    def test_a_fresh_manager_reloads_the_roster(self, monkeypatch, tmp_path):
        """The regression. Fails pre-fix: nothing survives the process."""
        dm = self._dm(monkeypatch, tmp_path)
        dm._check_and_add_emeter_device(
            "10.0.0.9", SimpleNamespace(alias="Fridge", has_emeter=True)
        )
        restarted = self._dm(monkeypatch, tmp_path)  # new process
        assert restarted.known_addresses == {"10.0.0.9"}
        assert restarted.devices == {}  # not registered yet -- it must be re-probed

    async def test_a_remembered_device_is_probed_after_restart(
        self, monkeypatch, tmp_path
    ):
        """The whole point: recovered WITHOUT discovery ever seeing it, and without
        the user knowing any address."""
        dm = self._dm(monkeypatch, tmp_path)
        dm._check_and_add_emeter_device(
            "10.0.0.9", SimpleNamespace(alias="Fridge", has_emeter=True)
        )
        restarted = self._dm(monkeypatch, tmp_path)

        recovered = SimpleNamespace(alias="Fridge", host="10.0.0.9", has_emeter=True)

        async def fake_get_device(ip, user, pw):
            return recovered

        monkeypatch.setattr(
            "app.collector.device_manager.KasaAPI.get_device", fake_get_device
        )
        await restarted.reclaim_retired_devices({})  # discovery returns NOTHING

        assert restarted.devices["10.0.0.9"] is recovered

    def test_a_corrupt_roster_never_stops_startup(self, monkeypatch, tmp_path):
        """Degrades to discovery-only rather than refusing to start."""
        (tmp_path / "known_devices.json").write_text("{ this is not json")
        dm = self._dm(monkeypatch, tmp_path)
        assert dm.known_addresses == set()

    def test_an_unwritable_output_dir_never_stops_registration(
        self, monkeypatch, tmp_path
    ):
        """Persisting is an optimisation over discovery, not a precondition for it."""
        dm = self._dm(monkeypatch, tmp_path)
        monkeypatch.setattr(
            dm, "_known_file", tmp_path / "no" / "such" / "dir" / "x.json"
        )
        monkeypatch.setattr(
            type(dm._known_file), "write_text", _raise_oserror, raising=False
        )
        dm._check_and_add_emeter_device(
            "10.0.0.9", SimpleNamespace(alias="Fridge", has_emeter=True)
        )
        assert "10.0.0.9" in dm.known_addresses  # in-memory roster still correct


def _raise_oserror(*a, **k):
    raise OSError("read-only file system")


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

    async def test_unreachable_device_still_counts_as_failed(self, tmp_path):
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
class TestBadReadingsAreNotStorageFailures:
    """A reading the collector cannot turn into points is the device's fault.

    It counts as `failed`, never as `write_failed` (an InfluxDB problem), and the log
    says the reading was bad. The device answered, so it still counts as reachable.
    """

    @staticmethod
    def _poller(reached):
        async def store(data):
            return True

        p = object.__new__(Poller)
        p.logger = logging.getLogger("test")
        p.storage = SimpleNamespace(process_emeter_data=store)
        p.on_reachable = reached.append
        return p

    @pytest.fixture(autouse=True)
    def _no_dns(self, monkeypatch):
        async def hostname(ip):
            return "plug.lan"

        monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)

    async def test_unparseable_reading_counts_as_failed_not_write_failed(self, caplog):
        reached: list[str] = []
        p = self._poller(reached)
        plug = SimpleNamespace(
            alias="Kettle", host="10.0.0.5", emeter_realtime={"power_mw": "garbage"}
        )
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        async def fetch(ip, device):
            return await p.process_device_data(ip, device)

        await p._fetch_counted(fetch, "10.0.0.5", plug, outcome, "emeter fetch")
        assert outcome == {"ok": 0, "failed": 1, "write_failed": 0}
        assert reached == ["10.0.0.5"]
        assert "InfluxDB" not in caplog.text

    @pytest.mark.parametrize("kind", ["builtin", "kasa"])
    async def test_an_outlet_that_does_not_answer_writes_nothing_once(
        self, monkeypatch, kind
    ):
        # The strip answered, one outlet did not: a device failure, counted once.
        # Nothing of the strip is written (no partial strip), the fetch is not re-run
        # (which would re-write the strip's points), and the strip stays reachable.
        from kasa.exceptions import _ConnectionError

        import app.collector.poller as poller_mod
        import app.collector.utils as utils_mod

        error: Exception = (
            ConnectionError("outlet did not answer")
            if kind == "builtin"
            else _ConnectionError("Unable to connect to the device")
        )

        async def hostname(ip):
            return "strip.lan"

        async def no_sleep(seconds):
            return None

        updates: list[str] = []

        class Outlet:
            alias = "Lamp"
            emeter_realtime = {"power_mw": 5}

            async def update(self):
                updates.append(self.alias)
                raise error

        class Strip:
            alias = "Desk Strip"
            host = "10.0.0.9"
            sys_info = {"deviceId": "STRIP1"}
            emeter_realtime = {"power_mw": 2}
            children = [Outlet()]

            async def update(self):
                return None

        monkeypatch.setattr(poller_mod, "IotStrip", Strip)
        monkeypatch.setattr(utils_mod, "get_hostname_cached", hostname)
        monkeypatch.setattr(utils_mod.asyncio, "sleep", no_sleep)
        written: list[dict] = []

        async def capture(data):
            written.extend(data.values())
            return True

        reached: list[str] = []
        p = self._poller(reached)
        p.storage = SimpleNamespace(process_emeter_data=capture)
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        await p._fetch_counted(
            p.fetch_and_store_emeter_data, "10.0.0.9", Strip(), outcome, "emeter fetch"
        )
        assert outcome == {"ok": 0, "failed": 1, "write_failed": 0}
        assert written == [] and updates == ["Lamp"] and reached == ["10.0.0.9"]

    async def test_a_reading_with_no_storable_field_is_not_ok(self):
        # Every field NaN: nothing would be written, which must not count as a
        # success (a success drives the healthcheck heartbeat).
        p = self._poller([])
        plug = SimpleNamespace(
            alias="Kettle", host="10.0.0.5", emeter_realtime={"power_mw": float("nan")}
        )
        outcome = {"ok": 0, "failed": 0, "write_failed": 0}

        async def fetch(ip, device):
            return await p.process_device_data(ip, device)

        await p._fetch_counted(fetch, "10.0.0.5", plug, outcome, "emeter fetch")
        assert outcome == {"ok": 0, "failed": 1, "write_failed": 0}

    @pytest.mark.parametrize("legacy_units", [False, True])
    def test_an_integer_outside_int64_drops_only_its_field(self, legacy_units):
        # InfluxDB rejects the whole batch for one out-of-range integer field.
        from app.collector.poller import emeter_fields

        reading = {"power_mw": 5, "total_wh": 2**63}
        assert emeter_fields(reading, legacy_units=legacy_units) == {"power_mw": 5}

    @pytest.mark.parametrize("bad", [float("nan"), float("inf"), float("-inf")])
    def test_a_non_finite_value_drops_only_its_field(self, bad):
        from app.collector.poller import emeter_fields

        reading = {"power_mw": bad, "voltage_mv": 120000}
        assert emeter_fields(reading, legacy_units=False) == {"voltage_mv": 120000}
        assert emeter_fields(reading, legacy_units=True) == {"voltage_mv": 120000}


@pytest.mark.unit
class TestManualHostsAreIntent:
    """A host in KASA_COLLECTOR_DEVICE_HOSTS must converge to collected.

    Listing a host in the env var is an explicit operator statement, so it cannot
    depend on a lossy broadcast OR on the one moment the process started. The old
    code called initialize_manual_devices() exactly once at startup: a manual host
    unreachable at that instant was absent for the life of the process.
    """

    def _dm(self, monkeypatch, tmp_path):
        async def fake_hostname(ip):
            return f"host-{ip}"

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        # Isolate the persisted device roster (read+written at construction).
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_missing_manual_host_is_retried_on_a_later_pass(
        self, monkeypatch, tmp_path
    ):
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
        dm = self._dm(monkeypatch, tmp_path)
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

    async def test_already_registered_manual_host_is_not_reconnected(
        self, monkeypatch, tmp_path
    ):
        # Re-connecting a working device every cycle would churn its session for
        # nothing -- reconcile must only attempt hosts that are actually absent.
        from app.collector import device_manager as dm_mod

        attempts: list[str] = []

        async def fake_get_device(ip, user, pw):
            attempts.append(ip)
            return SimpleNamespace(alias="X", host=ip, has_emeter=False)

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch, tmp_path)
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

    def _dm(self, monkeypatch, tmp_path):
        async def fake_hostname(ip):
            return f"host-{ip}"

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        # Isolate the persisted device roster (read+written at construction).
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    async def test_registry_key_is_the_resolved_ip_not_the_configured_name(
        self, monkeypatch, tmp_path
    ):
        from app.collector import device_manager as dm_mod

        async def fake_get_device(entry, user, pw):
            # get_device resolves the name up front and connects on the address,
            # so device.host is the resolved IPv4 on every path.
            return SimpleNamespace(
                alias="Fridge", host="198.51.100.100", has_emeter=False
            )

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]

        await dm.reconcile_manual_devices()
        assert "198.51.100.100" in dm.devices  # keyed by address
        assert "kasa-backroom-fridge.example.com" not in dm.devices
        assert (
            dm.manual_addresses["kasa-backroom-fridge.example.com"] == "198.51.100.100"
        )

    async def test_resolved_manual_host_is_not_reattempted(self, monkeypatch, tmp_path):
        # reconcile must recognise the host as registered via the mapping, or it
        # would reconnect (and re-handshake) a working device every cycle.
        from app.collector import device_manager as dm_mod

        attempts: list[str] = []

        async def fake_get_device(entry, user, pw):
            attempts.append(entry)
            return SimpleNamespace(
                alias="Fridge", host="198.51.100.100", has_emeter=False
            )

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]

        await dm.reconcile_manual_devices()
        await dm.reconcile_manual_devices()
        assert attempts == ["kasa-backroom-fridge.example.com"]  # attempted once

    async def test_resolved_manual_host_is_still_protected_from_pruning(
        self, monkeypatch, tmp_path
    ):
        # The prune guard matched the registry key against device_hosts. Once the key
        # is an address that no longer matches, so the mapping has to be consulted --
        # otherwise every Boutique device would be pruned on the first discovery pass.
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_KEEP_MISSING_DEVICES", False)
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_DISCOVERY_MISS_THRESHOLD", 1)
        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["kasa-backroom-fridge.example.com"]
        dm.manual_addresses = {"kasa-backroom-fridge.example.com": "198.51.100.100"}
        dm.devices = {
            "198.51.100.100": SimpleNamespace(alias="F", host="198.51.100.100")
        }

        await dm.remove_missing_devices({})  # never appears in a broadcast
        assert "198.51.100.100" in dm.devices  # protected


@pytest.mark.unit
class TestStripOutletIdentity:
    """Each outlet's point carries the outlet's own position and the strip's id.

    Outlet identity comes from the strip as polled, not from a lookup by alias in the
    sysinfo cache: two outlets may share a user-set alias, and the emeter loop can run
    before the strip's first sysinfo poll.
    """

    @pytest.mark.parametrize("key", ["deviceId", "device_id"])
    async def test_a_plug_point_carries_its_device_id_before_any_sysinfo(
        self, monkeypatch, key
    ):
        # Read off the device as polled, so the first points (before the sysinfo
        # cache holds this plug) are not a separate series without device_id.
        async def hostname(ip):
            return "plug.lan"

        monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)
        written: list[dict] = []

        async def capture(data):
            written.extend(data.values())
            return True

        p = object.__new__(Poller)
        p.logger = logging.getLogger("test")
        p.storage = SimpleNamespace(process_emeter_data=capture)
        plug = SimpleNamespace(
            alias="Kettle",
            host="10.0.0.5",
            sys_info={key: "DEV1"},
            emeter_realtime={"power_mw": 1},
        )
        assert await p.process_device_data("10.0.0.5", plug)
        assert written[0]["device_id"] == "DEV1"

    async def test_each_outlet_carries_its_position_and_the_strip_id(self, monkeypatch):
        async def hostname(ip):
            return "strip.lan"

        monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)

        class Outlet:
            def __init__(self, alias):
                self.alias = alias
                self.emeter_realtime = {"power_mw": 1000}

            async def update(self):
                return None

        written: list[dict] = []

        async def capture(data):
            written.extend(data.values())
            return True

        p = object.__new__(Poller)
        p.logger = logging.getLogger("test")
        p.storage = SimpleNamespace(process_emeter_data=capture)
        strip = SimpleNamespace(
            alias="Desk Strip",
            sys_info={"deviceId": "STRIP1"},
            emeter_realtime={"power_mw": 2000},
            children=[Outlet("Plug"), Outlet("Plug"), Outlet("TV")],
        )

        assert await p.process_smart_strip_data("10.0.0.9", strip) is True
        outlets = [d for d in written if d["equipment_type"] == "plug"]
        assert [(d["plug_id"], d["plug_alias"]) for d in outlets] == [
            ("1", "Plug"),
            ("2", "Plug"),
            ("3", "TV"),
        ]
        assert all(d["device_id"] == "STRIP1" for d in outlets)


@pytest.mark.unit
class TestEmeterUnits:
    """Readings are written in the dashboards' units, whatever units the firmware uses.

    Legacy firmware (HS110 hardware v1) reports A / V / W / kWh as floats under
    `current` / `voltage` / `power` / `total`; python-kasa's EmeterStatus converts them
    when a `*_ma` / `*_mv` / `*_mw` / `*_wh` key is read.
    """

    LEGACY = {"current": 0.123, "voltage": 230.5, "power": 12.7, "total": 1.876}
    NORMALIZED = {
        "current_ma": 123,
        "voltage_mv": 230500,
        "power_mw": 12700,
        "total_wh": 1876,
    }

    @staticmethod
    def _poller(written):
        async def capture(data):
            written.extend(data.values())
            return True

        p = object.__new__(Poller)
        p.logger = logging.getLogger("test")
        p.storage = SimpleNamespace(process_emeter_data=capture)
        return p

    @pytest.fixture(autouse=True)
    def _no_dns(self, monkeypatch):
        async def hostname(ip):
            return "plug.lan"

        monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)

    @staticmethod
    def _iot_plug(realtime):
        """An IOT plug (the device class whose firmware may use legacy units)."""
        from kasa.iot import IotPlug

        class Plug(IotPlug):
            alias = "Kettle"
            host = "10.0.0.5"
            emeter_realtime = realtime

        return object.__new__(Plug)

    async def test_legacy_plug_reading_is_written_in_milli_units(self):
        from kasa.emeterstatus import EmeterStatus

        written: list[dict] = []
        plug = self._iot_plug(EmeterStatus({**self.LEGACY, "err_code": 0}))
        assert await self._poller(written).process_device_data("10.0.0.5", plug)
        assert written[0]["emeter"] == {**self.NORMALIZED, "err_code": 0}

    async def test_modern_plug_reading_is_written_unchanged(self):
        from kasa.emeterstatus import EmeterStatus

        written: list[dict] = []
        plug = self._iot_plug(EmeterStatus(dict(self.NORMALIZED)))
        assert await self._poller(written).process_device_data("10.0.0.5", plug)
        assert written[0]["emeter"] == self.NORMALIZED

    async def test_smart_device_reading_is_not_converted(self):
        # A SMART energy-v1 device reports `total` as TODAY's kWh: it must never be
        # written as `total_wh`, which the dashboards read as a lifetime counter.
        from kasa.emeterstatus import EmeterStatus

        written: list[dict] = []
        plug = SimpleNamespace(
            alias="Kettle",
            host="10.0.0.5",
            emeter_realtime=EmeterStatus({"power_mw": 95000, "total": 2.9}),
        )
        assert await self._poller(written).process_device_data("10.0.0.5", plug)
        assert written[0]["emeter"] == {"power_mw": 95000, "total": 2}

    async def test_smart_device_writes_today_and_month_energy_in_wh(self):
        # The SMART Energy module reports today's and this month's energy in Wh
        # (get_energy_usage); they are written whole, never as a lifetime total_wh.
        from kasa import Module
        from kasa.smart import SmartDevice
        from kasa.smart.modules.energy import Energy

        # python-kasa's own SmartDevice and Energy module, after its update hook.
        device = SmartDevice("10.0.0.5")
        device._last_update = {
            "get_energy_usage": {
                "today_energy": 2900,
                "month_energy": 41250,
                "current_power": 95000,
            }
        }
        device._components = {"energy_monitoring": 1}
        energy = Energy(device, "Energy")
        await energy._post_update_hook()

        written: list[dict] = []
        plug = SimpleNamespace(
            alias="Kettle",
            host="10.0.0.5",
            emeter_realtime=energy.status,
            modules={Module.Energy: energy},
        )
        assert await self._poller(written).process_device_data("10.0.0.5", plug)
        assert written[0]["emeter"] == {
            "power_mw": 95000,
            "total": 2,
            "today_wh": 2900,
            "month_wh": 41250,
        }

    @pytest.mark.parametrize(
        "modules",
        [property(lambda self: (_ for _ in ()).throw(RuntimeError("boom"))), [1]],
        ids=["modules-raises", "modules-not-a-mapping"],
    )
    async def test_the_energy_extras_never_cost_the_reading(self, modules):
        # today_wh/month_wh are extras: a device whose modules cannot be read still
        # stores its realtime reading.
        written: list[dict] = []

        class Plug:
            alias = "Kettle"
            host = "10.0.0.5"
            emeter_realtime = {"power_mw": 95000}

        Plug.modules = modules
        assert await self._poller(written).process_device_data("10.0.0.5", Plug())
        assert written[0]["emeter"] == {"power_mw": 95000}

    def test_energy_counters_are_whole_non_negative_numbers(self):
        from app.collector.poller import smart_energy_fields

        def fields(energy):
            return smart_energy_fields(
                SimpleNamespace(modules={"Energy": SimpleNamespace(energy=energy)})
            )

        assert fields({"today_energy": True, "month_energy": -5}) == {}
        assert fields({"today_energy": 2899.6, "month_energy": 41250}) == {
            "today_wh": 2900,
            "month_wh": 41250,
        }

    def test_a_null_legacy_field_drops_only_itself(self):
        from kasa.emeterstatus import EmeterStatus

        from app.collector.poller import emeter_fields

        reading = EmeterStatus({**self.LEGACY, "power": None})
        expected = {k: v for k, v in self.NORMALIZED.items() if k != "power_mw"}
        assert emeter_fields(reading, legacy_units=True) == expected

    def test_a_plain_mapping_is_converted_like_an_emeter_status(self):
        from app.collector.poller import emeter_fields

        assert emeter_fields(dict(self.LEGACY), legacy_units=True) == self.NORMALIZED

    async def test_legacy_strip_and_outlet_readings_are_written_in_milli_units(self):
        from kasa.emeterstatus import EmeterStatus

        class Outlet:
            alias = "Lamp"
            emeter_realtime = EmeterStatus(dict(TestEmeterUnits.LEGACY))

            async def update(self):
                return None

        written: list[dict] = []
        strip = SimpleNamespace(
            alias="Desk Strip",
            sys_info={"deviceId": "STRIP1"},
            emeter_realtime=EmeterStatus(dict(self.LEGACY)),
            children=[Outlet()],
        )
        assert await self._poller(written).process_smart_strip_data("10.0.0.9", strip)
        assert [d["emeter"] for d in written] == [self.NORMALIZED, self.NORMALIZED]


@pytest.mark.unit
class TestCredentialsGatedByTrust:
    """The TP-Link credentials reach only listed or already-seen devices.

    Broadcast discovery hands credentials to whatever answers it, so a rogue device on
    the LAN could be given the account's credentials. They now go only to a device the
    operator listed, one collected from before, or every device when the operator opts
    in with KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES (KASACOLLEC-99).
    """

    def _dm(self, monkeypatch, tmp_path, *, trust=False):
        async def fake_hostname(ip):
            return f"host-{ip}"

        monkeypatch.setattr(
            "app.collector.device_manager.get_hostname_cached", fake_hostname
        )
        from app.core import config

        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_OUTPUT_DIR", str(tmp_path))
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_TPLINK_USERNAME", "owner@x")
        monkeypatch.setattr(config.Config, "KASA_COLLECTOR_TPLINK_PASSWORD", "s3cret")
        monkeypatch.setattr(
            config.Config, "KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES", trust
        )
        from app.collector.device_manager import DeviceManager

        return DeviceManager(logging.getLogger("test"))

    def test_predicate_allows_listed_seen_and_trusted_only(self, monkeypatch, tmp_path):
        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["10.0.0.1"]
        dm.manual_addresses = {"plug.lan": "10.0.0.2"}
        dm.known_addresses = {"10.0.0.3"}
        assert dm._may_use_credentials("10.0.0.1")  # listed
        assert dm._may_use_credentials("10.0.0.2")  # resolved manual
        # collected-from-before alone does NOT authorise credentials: a cred-less
        # responder can put itself in known_addresses (KASACOLLEC-99).
        assert not dm._may_use_credentials("10.0.0.3")
        assert not dm._may_use_credentials("10.0.0.9")  # a stranger

        trusting = self._dm(monkeypatch, tmp_path, trust=True)
        assert trusting._may_use_credentials("10.0.0.9")  # opted in

    async def test_broadcast_enumeration_sends_no_credentials(self, monkeypatch):
        from app.collector import kasa_api

        captured: dict = {}

        async def fake_discover(**kwargs):
            captured.update(kwargs)
            return {}

        monkeypatch.setattr(kasa_api.Discover, "discover", fake_discover)
        monkeypatch.setattr(
            kasa_api.Config, "KASA_COLLECTOR_TPLINK_USERNAME", "owner@x"
        )
        monkeypatch.setattr(kasa_api.Config, "KASA_COLLECTOR_TPLINK_PASSWORD", "s3cret")

        await kasa_api.KasaAPI.discover_devices()

        assert captured.get("username") is None
        assert captured.get("password") is None

    async def test_unlisted_device_is_never_handed_credentials(
        self, monkeypatch, tmp_path
    ):
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path)  # nothing listed, nothing known
        seen_creds: list[tuple] = []

        async def fake_get_device(ip, username=None, password=None):
            seen_creds.append((username, password))
            raise Exception("handshake challenge failed")

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        warnings: list[str] = []
        monkeypatch.setattr(
            dm.logger, "warning", lambda msg, *a: warnings.append(msg % a)
        )

        await dm._authenticate_device_with_retry(
            "10.0.0.9", None, allow_credentials=False
        )
        await dm._authenticate_device_with_retry(
            "10.0.0.9", None, allow_credentials=False
        )

        assert seen_creds and all(c == (None, None) for c in seen_creds)
        assert "10.0.0.9" not in dm.devices
        assert sum("not trusted" in w for w in warnings) == 1

    async def test_listed_device_is_authenticated_with_credentials(
        self, monkeypatch, tmp_path
    ):
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["10.0.0.3"]  # operator-listed
        seen_creds: list[tuple] = []

        async def fake_get_device(ip, username=None, password=None):
            seen_creds.append((username, password))
            return SimpleNamespace(
                host=ip, alias="Kettle", has_emeter=True, model="HS110"
            )

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)

        await dm._authenticate_device_with_retry(
            "10.0.0.3", None, allow_credentials=dm._may_use_credentials("10.0.0.3")
        )

        assert ("owner@x", "s3cret") in seen_creds
        assert "10.0.0.3" in dm.devices

    async def test_reclaim_withholds_credentials_from_a_self_promoted_stranger(
        self, monkeypatch, tmp_path
    ):
        # A rogue IOT responder answers discovery once (cred-less), landing in
        # known_addresses; it must never be handed the account credentials on a later
        # reclaim pass (KASACOLLEC-99).
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path)  # nothing listed, trust off
        dm.known_addresses = {"10.0.0.9"}  # self-promoted via a cred-less register
        dm.retired = {"10.0.0.9": 0.0}
        seen_creds: list[tuple] = []

        async def fake_get_device(ip, username=None, password=None):
            seen_creds.append((username, password))
            return SimpleNamespace(
                host=ip, alias="Rogue", has_emeter=True, model="HS110"
            )

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)

        await dm.reclaim_retired_devices({})  # nothing seen by discovery this round

        assert seen_creds and all(c == (None, None) for c in seen_creds), seen_creds

    async def test_reclaim_after_restart_gives_creds_only_to_listed_addresses(
        self, monkeypatch, tmp_path
    ):
        # After a restart the roster is reloaded and self.devices is empty, so reclaim
        # probes every remembered address. The listed one gets credentials; a remembered
        # stranger (e.g. a departed device's reused IP) does not.
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path)
        dm.device_hosts = ["10.0.0.1"]  # operator-listed survives a restart
        dm.known_addresses = {"10.0.0.1", "10.0.0.9"}
        creds_by_ip: dict[str, tuple] = {}

        async def fake_get_device(ip, username=None, password=None):
            creds_by_ip[ip] = (username, password)
            return SimpleNamespace(host=ip, alias="Dev", has_emeter=True, model="HS110")

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)

        await dm.reclaim_retired_devices({})

        assert creds_by_ip["10.0.0.1"] == ("owner@x", "s3cret")  # listed
        assert creds_by_ip["10.0.0.9"] == (None, None)  # remembered stranger

    async def test_trusted_smart_device_falls_through_to_credentialed_connection(
        self, monkeypatch, tmp_path
    ):
        # A discovered SMART/KLAP device reports no state without credentials, and the
        # discovery object never carries them (KASACOLLEC-99). When the operator has opted
        # in (trust on, or listed), the failed discovered-object probe must fall through to
        # a fresh credentialed get_device(), not dead-end -- otherwise the trust knob is a
        # no-op for exactly the devices it exists to serve (KASACOLLEC-107).
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path, trust=True)  # operator opted in

        class SmartDevice:  # the class name is what the SMART branch checks
            host = "10.0.0.9"

        async def fake_auth_discovered(device, username=None, password=None):
            return (
                None  # cred-less discovery object cannot complete the SMART handshake
            )

        monkeypatch.setattr(
            dm_mod.KasaAPI, "authenticate_discovered_device", fake_auth_discovered
        )
        seen_creds: list[tuple] = []

        async def fake_get_device(ip, username=None, password=None):
            seen_creds.append((username, password))
            return SimpleNamespace(
                host=ip, alias="Outside Front", has_emeter=True, model="KP125M"
            )

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)

        await dm._authenticate_device_with_retry(
            "10.0.0.9", SmartDevice(), allow_credentials=True
        )

        assert ("owner@x", "s3cret") in seen_creds  # the knob actually logs in
        assert "10.0.0.9" in dm.devices

    async def test_unlisted_smart_device_is_withheld_not_retried(
        self, monkeypatch, tmp_path
    ):
        # An unlisted, untrusted SMART device still gets no credentials, is not hammered
        # with a connection it may not make, and is reported with the actionable "not
        # trusted" line (once), not the old misleading "newer protocol support" message.
        from app.collector import device_manager as dm_mod

        dm = self._dm(monkeypatch, tmp_path)  # unlisted, trust off

        class SmartDevice:
            host = "10.0.0.9"

        async def fake_auth_discovered(device, username=None, password=None):
            return None

        monkeypatch.setattr(
            dm_mod.KasaAPI, "authenticate_discovered_device", fake_auth_discovered
        )
        attempted: list[str] = []

        async def fake_get_device(ip, username=None, password=None):
            attempted.append(ip)
            return SimpleNamespace(host=ip, alias="x", has_emeter=True, model="KP125M")

        monkeypatch.setattr(dm_mod.KasaAPI, "get_device", fake_get_device)
        warnings: list[str] = []
        monkeypatch.setattr(
            dm.logger, "warning", lambda msg, *a: warnings.append(msg % a)
        )

        await dm._authenticate_device_with_retry(
            "10.0.0.9", SmartDevice(), allow_credentials=False
        )
        await dm._authenticate_device_with_retry(
            "10.0.0.9", SmartDevice(), allow_credentials=False
        )

        assert attempted == []  # withheld: never opened a connection
        assert "10.0.0.9" not in dm.devices
        assert sum("not trusted" in w for w in warnings) == 1
        assert not any("newer protocol support" in w for w in warnings)

    async def test_failed_smart_probe_closes_its_session(self, monkeypatch):
        # A discovered SMART probe that fails must close the device's aiohttp session;
        # otherwise the event loop logs "Unclosed client session" on GC (KASACOLLEC-107).
        from app.collector import kasa_api

        closed: list[bool] = []

        class SmartDevice:
            host = "10.0.0.9"

            async def update(self):
                raise Exception("needs credentials")

            async def disconnect(self):
                closed.append(True)

        result = await kasa_api.KasaAPI.authenticate_discovered_device(SmartDevice())

        assert result is None
        assert closed == [True]

    async def test_get_device_closes_a_discovered_device_it_falls_back_from(
        self, monkeypatch
    ):
        # get_device tries discover_single first. When that returns a device whose update()
        # fails, the fallback connects a new one; the first, its HTTP session already open,
        # must be closed rather than dropped, or the event loop logs "Unclosed client
        # session" for every device that takes the fallback (KASACOLLEC-109).
        from app.collector import kasa_api

        closed: list[str] = []

        class Probed:
            host = "10.0.0.5"

            async def update(self):
                raise Exception("handshake failed")

            async def disconnect(self):
                closed.append("discovered")

        class Connected:
            host = "10.0.0.5"
            alias = "Office Desk West Power Strip"
            model = "HS300"
            has_emeter = True
            sys_info: dict = {}

            async def update(self):
                return None

            async def disconnect(self):
                closed.append("connected")

        async def fake_discover_single(host, credentials=None):
            return Probed()

        async def fake_connect(*, host=None, config=None):
            return Connected()

        monkeypatch.setattr(kasa_api.Discover, "discover_single", fake_discover_single)
        monkeypatch.setattr(kasa_api.Device, "connect", fake_connect)

        device = await kasa_api.KasaAPI.get_device("10.0.0.5", "owner@x", "s3cret")

        assert isinstance(device, Connected)
        assert closed == [
            "discovered"
        ]  # the dropped one closed; the kept one left open
