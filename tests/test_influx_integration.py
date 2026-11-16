"""InfluxDB storage against a REAL InfluxDB (`make test` starts one: compose profile `test`).

The shaping tests stub the write; these prove the points the collector builds are accepted by
the server and land with the tags and fields the dashboards query, through the same async
client, write API and auth the deployed collector uses.
"""

import csv
from uuid import uuid4

import pytest

from app.core.config import Config
from app.storage.influxdb import InfluxDBStorage


async def _query(storage: InfluxDBStorage, flux: str) -> list[dict[str, str]]:
    # query_raw, parsed here: the parsed query() needs aiocsv, an extra the collector does not
    # ship (it only writes). Annotation lines start with '#'; each table repeats the header.
    assert storage.client is not None
    raw = await storage.client.query_api().query_raw(flux, org=storage.org)
    lines = [line for line in raw.splitlines() if line and not line.startswith("#")]
    return [row for row in csv.DictReader(lines) if row["_field"] != "_field"]


@pytest.mark.integration
async def test_an_iot_plugs_sysinfo_lands_in_a_bucket_holding_lnk_on_as_text():
    """A bucket the typed shaping filled before lnk_on had a rule holds it as text, and one
    filled as each device sent it holds it as integer: no single type fits both, so lnk_on
    is not written, and an IOT plug's whole sysinfo point lands in either."""
    from influxdb_client.client.write.point import Point

    storage = InfluxDBStorage()
    await storage.connect()
    try:
        run = uuid4().hex[:12]
        sysinfo = {"deviceId": f"P{run}", "rssi": -40, "relay_state": 1, "lnk_on": 1}
        # The bucket already holds lnk_on as text for this measurement's current shard.
        held = (
            Point("sysinfo")
            .tag("device_alias", f"itest-txt-{run}")
            .field("lnk_on", "1")
        )
        assert await storage.send_to_influxdb([held])

        assert await storage.process_sysinfo_data(
            {"10.9.8.7": {"sysinfo": sysinfo, "alias": f"itest-now-{run}"}}
        ), "the sysinfo point was refused by a bucket holding lnk_on as text"
    finally:
        await storage.close()


@pytest.mark.integration
async def test_emeter_point_lands_with_its_tags_and_fields():
    storage = InfluxDBStorage()
    await storage.connect()
    try:
        alias = f"itest-{uuid4().hex[:12]}"
        ok = await storage.process_emeter_data(
            {
                "10.9.8.7": {
                    "emeter": {"power_mw": 42000, "voltage_mv": 120500},
                    "alias": alias,
                }
            }
        )
        assert ok is True

        rows = await _query(
            storage,
            f'from(bucket: "{storage.bucket}") |> range(start: -5m)'
            f' |> filter(fn: (r) => r.device_alias == "{alias}")',
        )
        fields = {row["_field"]: int(row["_value"]) for row in rows}
        assert fields, f"no point for alias {alias} reached InfluxDB"
        assert {row["_measurement"] for row in rows} == {"emeter"}
        assert fields["power_mw"] == 42000
        assert fields["voltage_mv"] == 120500
    finally:
        await storage.close()


@pytest.mark.integration
async def test_a_rejected_write_is_reported_not_swallowed(monkeypatch):
    # A wrong token is the real server's 401, not a stub: the batch must come back False
    # so the cycle counts it (KASACOLLEC-63), and the collector must keep running.
    monkeypatch.setattr(Config, "KASA_COLLECTOR_INFLUXDB_TOKEN", "not-the-token")
    storage = InfluxDBStorage()
    await storage.connect()
    try:
        ok = await storage.process_emeter_data(
            {"10.9.8.7": {"emeter": {"power_mw": 1000}, "alias": "itest-unauthorized"}}
        )
        assert ok is False
    finally:
        await storage.close()


@pytest.mark.integration
async def test_a_device_reporting_another_type_cannot_cost_another_its_sysinfo():
    # The rogue writes first, so without one type per key InfluxDB would fix rssi as
    # text and reject the legitimate device's whole sysinfo point.
    storage = InfluxDBStorage()
    await storage.connect()
    try:
        run = uuid4().hex[:12]
        rogue, legit = f"itest-rogue-{run}", f"itest-legit-{run}"
        assert await storage.process_sysinfo_data(
            {"10.9.8.66": {"sysinfo": {"deviceId": "R", "rssi": "x"}, "alias": rogue}}
        )
        assert await storage.process_sysinfo_data(
            {
                "10.9.8.7": {
                    "sysinfo": {"deviceId": "L", "rssi": -40, "relay_state": 1},
                    "alias": legit,
                }
            }
        )

        rows = await _query(
            storage,
            f'from(bucket: "{storage.bucket}") |> range(start: -5m)'
            f' |> filter(fn: (r) => r._measurement == "sysinfo")'
            f' |> filter(fn: (r) => r.device_alias == "{legit}")',
        )
        fields = {row["_field"]: row["_value"] for row in rows}
        assert fields.get("rssi") == "-40"
        assert fields.get("relay_state") == "1"
    finally:
        await storage.close()
