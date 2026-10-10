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
