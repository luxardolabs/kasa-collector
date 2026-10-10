"""The one local python-kasa fix left: a discovered KLAP strip is re-classed as IotStrip."""

import pytest
from kasa import Discover
from kasa.iot import IotPlug, IotStrip

from app.collector import kasa_compat


def _updated_plug(sys_info: dict) -> IotPlug:
    # An IotPlug as discovery hands it over after update(): sysinfo populated, no I/O here.
    plug = IotPlug("10.0.0.9")
    plug._last_update = {"system": {"get_sysinfo": sys_info}}
    plug._set_sys_info(sys_info)
    return plug


@pytest.mark.unit
class TestReclassStripIfNeeded:
    async def test_plug_reporting_children_is_rebuilt_as_strip(self, monkeypatch):
        updated = []

        async def fake_update(self, update_children=True):
            updated.append(self.host)

        monkeypatch.setattr(IotStrip, "update", fake_update)
        plug = _updated_plug({"children": [{"id": "00"}, {"id": "01"}]})

        dev = await kasa_compat.reclass_strip_if_needed(plug)

        assert isinstance(dev, IotStrip)
        assert dev.protocol is plug.protocol  # same session, no re-handshake
        assert updated == ["10.0.0.9"]

    async def test_plug_without_children_is_left_alone(self):
        plug = _updated_plug({"model": "KP115(US)"})
        assert await kasa_compat.reclass_strip_if_needed(plug) is plug

    async def test_strip_is_left_alone(self):
        strip = IotStrip("10.0.0.9")
        assert await kasa_compat.reclass_strip_if_needed(strip) is strip


@pytest.mark.unit
class TestVerifyStillNeeded:
    def test_installed_python_kasa_still_classes_discovery_by_family(self):
        # Pins the finding behind keeping this module on python-kasa 0.11.0.1: if a
        # python-kasa upgrade turns this red, the discovery fix shipped upstream —
        # re-probe the KLAP strips and delete the module, do not edit this test.
        assert kasa_compat.discovery_classes_from_family() is True
        assert kasa_compat.verify_still_needed() is True

    def test_announces_an_upstream_fix(self, monkeypatch, caplog):
        def fixed(info, config):
            # A discovery that classes from the device's own sys_info, as _connect does.
            return info

        monkeypatch.setattr(Discover, "_get_device_instance", staticmethod(fixed))
        assert kasa_compat.verify_still_needed() is False
        assert "#1748 looks FIXED upstream" in caplog.text
