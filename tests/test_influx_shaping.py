"""Unit tests for InfluxDB write-shaping (the highest-regression-risk logic).

InfluxDBStorage.__init__ opens a real connection, so these construct the object
via object.__new__ and stub send_to_influxdb / _append_to_file to capture the
Points the shaping logic produces, without any live InfluxDB.
"""

import logging

import pytest

from app.storage.influxdb import InfluxDBStorage


def _storage():
    s = object.__new__(InfluxDBStorage)
    s.logger = logging.getLogger("test")
    s.sysinfo_data = {}
    s.captured = []

    async def send(points):
        s.captured.extend(points)

    async def append(data):
        pass

    s.send_to_influxdb = send
    s._append_to_file = append
    return s


def _tags(point):
    return dict(point._tags)  # influxdb_client Point._tags is {key: value}


@pytest.mark.unit
class TestNormalizeSysinfo:
    def test_kp125m_field_renaming(self):
        s = _storage()
        out = s.normalize_sysinfo(
            {"model": "KP125M", "fw_ver": "1.2", "device_on": True, "mac": "AA"}
        )
        assert out["sw_ver"] == "1.2"  # fw_ver -> sw_ver
        assert out["relay_state"] == 1  # device_on(True) -> 1
        assert "fw_ver" not in out and "device_on" not in out
        assert out["mac"] == "AA"  # other fields pass through

    def test_kp125m_device_off(self):
        s = _storage()
        out = s.normalize_sysinfo({"model": "KP125M", "device_on": False})
        assert out["relay_state"] == 0

    def test_non_kp125m_passthrough(self):
        s = _storage()
        src = {"model": "HS110", "sw_ver": "1", "relay_state": 1}
        assert s.normalize_sysinfo(src) == src


@pytest.mark.unit
class TestPlugInfoLookup:
    def test_assigns_sequential_plug_id(self):
        s = _storage()
        sysinfo = {"children": [{"alias": "A"}, {"alias": "B"}, {"alias": "C"}]}
        assert s._get_plug_info_from_sysinfo_by_alias(sysinfo, "B")["plug_id"] == "2"
        assert s._get_plug_info_from_sysinfo_by_alias(sysinfo, "A")["plug_id"] == "1"

    def test_returns_none_when_not_found(self):
        s = _storage()
        sysinfo = {"children": [{"alias": "A"}]}
        assert s._get_plug_info_from_sysinfo_by_alias(sysinfo, "Z") is None


@pytest.mark.unit
class TestProcessEmeter:
    async def test_standalone_plug_has_no_plug_tags(self):
        s = _storage()
        s.sysinfo_data = {"10.0.0.1": {"sysinfo": {"deviceId": "DEV1", "children": []}}}
        await s.process_emeter_data(
            {
                "10.0.0.1": {
                    "emeter": {"power_mw": 42, "voltage_mv": 120000},
                    "alias": "Fridge",
                    "dns_name": "f.local",
                    "equipment_type": "device",
                }
            }
        )
        assert len(s.captured) == 2  # one point per metric
        tags = _tags(s.captured[0])
        assert tags["device_alias"] == "Fridge" and tags["device_id"] == "DEV1"
        assert "plug_id" not in tags and "plug_alias" not in tags

    async def test_strip_outlet_gets_plug_id_and_alias(self):
        s = _storage()
        s.sysinfo_data = {
            "10.0.0.2": {
                "sysinfo": {
                    "deviceId": "STRIP",
                    "children": [{"alias": "OutletA"}, {"alias": "OutletB"}],
                }
            }
        }
        await s.process_emeter_data(
            {
                "10.0.0.2": {
                    "emeter": {"power_mw": 10},
                    "alias": "Strip",
                    "dns_name": "s.local",
                    "equipment_type": "plug",
                    "plug_alias": "OutletB",
                }
            }
        )
        tags = _tags(s.captured[0])
        assert tags["plug_alias"] == "OutletB" and tags["plug_id"] == "2"

    async def test_malicious_alias_is_sanitized(self):
        s = _storage()
        s.sysinfo_data = {"10.0.0.3": {"sysinfo": {"deviceId": "D", "children": []}}}
        await s.process_emeter_data(
            {
                "10.0.0.3": {
                    "emeter": {"power_mw": 5},
                    "alias": "Evil\r\nFAKE",
                    "dns_name": "x",
                    "equipment_type": "device",
                }
            }
        )
        alias = _tags(s.captured[0])["device_alias"]
        assert "\n" not in alias and "\r" not in alias  # control chars stripped
        assert alias == "EvilFAKE"


@pytest.mark.unit
class TestCollectorMetrics:
    async def test_collector_stats_point_shape(self):
        s = _storage()
        await s.write_collector_metrics(
            cycle="emeter", devices=20, succeeded=18, failed=2, duration=3.5
        )
        assert len(s.captured) == 1
        point = s.captured[0]
        assert point._name == "collector_stats"
        assert _tags(point)["cycle"] == "emeter"
        fields = dict(point._fields)
        assert fields["devices"] == 20
        assert fields["succeeded"] == 18
        assert fields["failed"] == 2
        assert fields["duration_seconds"] == 3.5


@pytest.mark.unit
class TestProcessSysinfo:
    async def test_parent_and_child_points_with_sequential_ids(self):
        s = _storage()
        await s.process_sysinfo_data(
            {
                "10.0.0.2": {
                    "sysinfo": {
                        "device_id": "STRIP",
                        "model": "HS300",
                        "children": [
                            {"alias": "A", "id": "x00", "state": 1},
                            {"alias": "B", "id": "x01", "state": 0},
                        ],
                    },
                    "device_alias": "Strip",
                    "dns_name": "s.local",
                }
            }
        )
        measurements = [p._name for p in s.captured]
        assert measurements.count("sysinfo") == 1
        assert measurements.count("sysinfo_child") == 2
        child_tags = [_tags(p) for p in s.captured if p._name == "sysinfo_child"]
        assert {t["plug_id"] for t in child_tags} == {"1", "2"}  # sequential
        # the raw 'id' field is excluded from child points
        child_fields = [set(p._fields.keys()) for p in s.captured if p._name == "sysinfo_child"]
        assert all("id" not in fields for fields in child_fields)
