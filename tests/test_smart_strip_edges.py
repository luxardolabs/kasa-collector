"""A SMART strip's edge cases, through the real python-kasa client over KLAP v2.

The device is harness/fake_smart.py in-process; each test bends what it sends the way a
real strip does (an outlet missing from one child list, an outlet's energy error, an
unnamed strip, a Wi-Fi name in its device info).
"""

import base64
import importlib.util
import logging
from pathlib import Path

import pytest
from kasa import Credentials, Device, DeviceConfig, DeviceConnectionParameters, Module
from kasa.deviceconfig import DeviceEncryptionType, DeviceFamily

from app.collector.poller import Poller
from app.storage.influxdb import InfluxDBStorage

FAKE = Path(__file__).resolve().parent.parent / "harness" / "fake_smart.py"
pytestmark = pytest.mark.unit
USERNAME = "owner@example.invalid"
PASSWORD = "".join(["fake-", "strip-", "login"])
SSID = "HomeNet-5G"


@pytest.fixture
def fake(monkeypatch):
    monkeypatch.setenv("KASA_FAKE_USERNAME", USERNAME)
    monkeypatch.setenv("KASA_FAKE_PASSWORD", PASSWORD)
    monkeypatch.setenv("KASA_FAKE_ALIAS", "Bench Strip")
    spec = importlib.util.spec_from_file_location("fake_smart_r3", FAKE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def _connect(fake):
    server = await fake.start_http("127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    config = DeviceConfig(
        host="127.0.0.1",
        credentials=Credentials(USERNAME, PASSWORD),
        connection_type=DeviceConnectionParameters(
            DeviceFamily.SmartTapoPlug,
            DeviceEncryptionType.Klap,
            login_version=2,
            http_port=port,
        ),
    )
    return server, await Device.connect(config=config)


def _storage():
    s = object.__new__(InfluxDBStorage)
    s.logger = logging.getLogger("test")
    s.sysinfo_data = {}
    s.captured = []

    async def send(points):
        s.captured.extend(points)
        return True

    async def append(data):
        pass

    s.send_to_influxdb = send
    s._append_to_file = append
    return s


def _poller(monkeypatch):
    async def hostname(ip):
        return "strip.lan"

    monkeypatch.setattr("app.collector.poller.get_hostname_cached", hostname)
    p = object.__new__(Poller)
    p.logger = logging.getLogger("test")
    p.storage = _storage()
    return p


def _outlet_power_by_plug_id(points):
    out = {}
    for pt in points:
        tags = dict(pt._tags)
        if tags.get("equipment_type") == "plug" and "power_mw" in pt._fields:
            out[tags["plug_id"]] = pt._fields["power_mw"]
    return out


def _expected(n):
    return 20_000 + 5_000 * (n - 1)  # fake_smart: outlet n draws 20 W + 5 W*(n-1)


# --------------------------------------------------------------- plug_id identity


def _drop_outlet(fake, gone):
    real = fake.parent_methods

    def parent_methods():
        m = real()
        lst = m["get_child_device_list"]
        lst["child_device_list"] = [
            c for c in lst["child_device_list"] if c["position"] != gone
        ]
        lst["sum"] = len(lst["child_device_list"])
        return m

    return real, parent_methods


async def _poll(poller, strip):
    poller.storage.captured.clear()
    await strip.update()
    assert await poller.process_smart_strip_data("127.0.0.1", strip)
    return _outlet_power_by_plug_id(poller.storage.captured)


async def test_control_plug_id_is_stable_when_the_outlet_list_is_stable(
    fake, monkeypatch
):
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        for _ in range(3):
            got = await _poll(poller, strip)
            assert got == {str(n): _expected(n) for n in range(1, 7)}
    finally:
        await strip.disconnect()
        server.close()


async def test_plug_id_follows_the_outlet_after_one_poll_missing_it(fake, monkeypatch):
    """One poll whose child list lacks outlet 2: python-kasa deletes that child and
    re-creates it at the END of strip.children on the next poll. plug_id is the
    index in strip.children, so from then on series '2'..'6' carry other outlets."""
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        assert await _poll(poller, strip) == {str(n): _expected(n) for n in range(1, 7)}
        real, dropped = _drop_outlet(fake, 2)
        monkeypatch.setattr(fake, "parent_methods", dropped)
        await _poll(poller, strip)  # outlet 2 absent this poll
        monkeypatch.setattr(fake, "parent_methods", real)
        got = await _poll(poller, strip)  # every outlet is back
        # Each plug_id must still carry its own outlet's power.
        assert got == {str(n): _expected(n) for n in range(1, 7)}
    finally:
        await strip.disconnect()
        server.close()


# --------------------------------------------------------------- SSID as the alias


def _no_nickname(fake):
    """The real P316M(US)_1.6_1.0.5 fixture: the strip's get_device_info has
    nickname "" (python-kasa then returns the decoded SSID as the alias)."""
    real_parent = fake.parent_methods
    b64 = base64.b64encode(SSID.encode()).decode()

    def parent_methods():
        m = real_parent()
        m["get_device_info"]["nickname"] = ""
        m["get_device_info"]["ssid"] = b64
        return m

    return parent_methods


def _all_text(points):
    return "\n".join(p.to_line_protocol() for p in points)


async def test_control_named_strip_writes_no_ssid(fake, monkeypatch):
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await strip.update()
        await poller.process_smart_strip_data("127.0.0.1", strip)
        assert SSID not in _all_text(poller.storage.captured)
    finally:
        await strip.disconnect()
        server.close()


async def test_an_unnamed_strip_writes_no_wifi_name_to_emeter(fake, monkeypatch):
    monkeypatch.setattr(fake, "parent_methods", _no_nickname(fake))
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await strip.update()
        await poller.process_smart_strip_data("127.0.0.1", strip)
        text = _all_text(poller.storage.captured)
        assert SSID not in text
    finally:
        await strip.disconnect()
        server.close()


async def test_a_strips_wifi_name_is_never_written_to_sysinfo(fake, monkeypatch):
    monkeypatch.setattr(fake, "parent_methods", _no_nickname(fake))
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await poller.fetch_and_store_sysinfo("127.0.0.1", strip)
        text = _all_text(poller.storage.captured)
        b64 = base64.b64encode(SSID.encode()).decode()
        leaks = [s for s in (SSID, b64) if s in text]
        assert leaks == [], text
    finally:
        await strip.disconnect()
        server.close()


# ------------------------------------------- one outlet's energy error, whole strip


def _outlet_energy_fails(fake, bad):
    real = fake.outlet_methods

    def outlet_methods(n):
        m = real(n)
        if n == bad:
            for k in (
                "get_emeter_data",
                "get_energy_usage",
                "get_current_power",
                "get_emeter_vgain_igain",
            ):
                m.pop(k, None)
        return m

    return real, outlet_methods


async def test_control_strip_is_stored_when_every_outlet_answers(fake, monkeypatch):
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        for _ in range(3):
            await strip.update()
            assert await poller.process_smart_strip_data("127.0.0.1", strip)
    finally:
        await strip.disconnect()
        server.close()


async def test_an_outlet_python_kasa_gave_up_on_costs_only_that_outlet(
    fake, monkeypatch
):
    """Outlet 3's energy read fails for python-kasa's 10 queried updates (its error
    backoff stepped over by ageing the module's last update time, i.e. ~22 minutes
    of a 15 s poll). python-kasa then disables the module, but leaves it in
    child.modules, so child.has_emeter stays True and status raises forever: the
    collector's strip read is UnstorableReading on EVERY later cycle, after the
    outlet has recovered, for all six outlets, and the device stays 'reachable'
    so it is never reconnected."""
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await strip.update()
        real, failing = _outlet_energy_fails(fake, 3)
        monkeypatch.setattr(fake, "outlet_methods", failing)
        energy = strip.children[2].modules[Module.Energy]
        for _ in range(10):
            energy._last_update_time = 1.0  # the backoff has elapsed
            await strip.update()
        assert energy.disabled
        monkeypatch.setattr(fake, "outlet_methods", real)  # outlet 3 recovered
        for _ in range(3):
            await strip.update()
        assert strip.children[2].has_emeter  # still "measures"
        # The five healthy outlets (and the recovered one) must be stored.
        poller.storage.captured.clear()
        try:
            await poller.process_smart_strip_data("127.0.0.1", strip)
        except Exception as e:  # UnstorableReading
            pytest.fail(f"whole strip unstorable after outlet recovered: {e!r}")
    finally:
        await strip.disconnect()
        server.close()


async def test_one_outlets_energy_error_costs_only_that_outlet(fake, monkeypatch):
    """One failed outlet read, then the outlet answers again: on the next 15 s cycle
    python-kasa's 30 s error backoff skips the outlet's energy query and its status
    still raises, so the WHOLE strip (all six outlets) is lost a second cycle."""
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await strip.update()
        real, failing = _outlet_energy_fails(fake, 3)
        monkeypatch.setattr(fake, "outlet_methods", failing)
        await strip.update()
        monkeypatch.setattr(fake, "outlet_methods", real)
        await strip.update()  # next cycle: outlet 3 is healthy again
        try:
            await poller.process_smart_strip_data("127.0.0.1", strip)
        except Exception as e:
            pytest.fail(f"strip lost on the cycle after outlet recovered: {e!r}")
    finally:
        await strip.disconnect()
        server.close()


# ---------------------------------------- harness fidelity: the real P316M parent


async def test_like_a_real_p316m_only_the_outlets_measure(fake, monkeypatch):
    # A real P316M's own device_info has no device_on, so python-kasa reads no energy
    # for the strip itself: the collector writes its outlets and no total.
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        assert "device_on" not in fake.parent_methods()["get_device_info"]
        assert not strip.has_emeter
        await strip.update()
        assert await poller.process_smart_strip_data("127.0.0.1", strip)
        kinds = {dict(p._tags)["equipment_type"] for p in poller.storage.captured}
        assert kinds == {"plug"}
    finally:
        await strip.disconnect()
        server.close()


# ------------------------------------------- an unnamed strip / outlet (real fixture)


def _unnamed(fake):
    real_parent, real_outlet = fake.parent_methods, fake.outlet_methods

    def parent_methods():
        m = real_parent()
        m["get_device_info"]["nickname"] = ""
        for c in m["get_child_device_list"]["child_device_list"]:
            c["nickname"] = ""
        return m

    def outlet_methods(n):
        m = real_outlet(n)
        m["get_device_info"]["nickname"] = ""
        return m

    return parent_methods, outlet_methods


def _alias_tags(points):
    aliases = {dict(p._tags)["device_alias"] for p in points}
    plugs = {dict(p._tags).get("plug_alias") for p in points} - {None}
    return aliases, plugs


async def test_control_named_strip_tags_match_sysinfo(fake, monkeypatch):
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await poller.fetch_and_store_sysinfo("127.0.0.1", strip)
        await strip.update()
        await poller.process_smart_strip_data("127.0.0.1", strip)
        aliases, plugs = _alias_tags(poller.storage.captured)
        assert len(aliases) == 1 and "None" not in plugs
    finally:
        await strip.disconnect()
        server.close()


async def test_an_unnamed_strip_is_tagged_as_its_sysinfo_is(fake, monkeypatch):
    """Real P316M parent nickname is "". sysinfo tags it device_alias=<host>
    (DeviceContext/get_device_name), emeter points device_alias=unknown
    (sanitize_tag(None)); unnamed outlets get plug_alias="None"."""
    p, o = _unnamed(fake)
    monkeypatch.setattr(fake, "parent_methods", p)
    monkeypatch.setattr(fake, "outlet_methods", o)
    server, strip = await _connect(fake)
    poller = _poller(monkeypatch)
    try:
        await poller.fetch_and_store_sysinfo("127.0.0.1", strip)
        await strip.update()
        await poller.process_smart_strip_data("127.0.0.1", strip)
        aliases, plugs = _alias_tags(poller.storage.captured)
        assert len(aliases) == 1 and "None" not in plugs, (aliases, plugs)
    finally:
        await strip.disconnect()
        server.close()
