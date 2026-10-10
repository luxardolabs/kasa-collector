"""The collector's entrypoint installs the fleet logging module with its per-component levels."""

import json
import logging

import pytest

from app import main
from app.core.config import Config


@pytest.fixture
def restore_logging():
    root = logging.getLogger()
    saved = (root.level, list(root.handlers))
    names = ("KasaCollector", "KasaAPI", "KasaCompat", "InfluxDBStorage", "kasa")
    levels = {n: logging.getLogger(n).level for n in names}
    yield
    root.handlers[:] = saved[1]
    root.setLevel(saved[0])
    for n, lvl in levels.items():
        logging.getLogger(n).setLevel(lvl)


@pytest.mark.unit
def test_component_levels_come_from_config(monkeypatch, restore_logging):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_LOG_LEVEL_KASA_API", "DEBUG")
    monkeypatch.setattr(Config, "KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE", "ERROR")
    main.configure_app_logging()
    assert logging.getLogger("KasaAPI").level == logging.DEBUG
    assert logging.getLogger("KasaCompat").level == logging.DEBUG
    assert logging.getLogger("InfluxDBStorage").level == logging.ERROR
    assert logging.getLogger("kasa").level == logging.WARNING


@pytest.mark.unit
def test_lines_are_fleet_json_with_fields_under_attributes(
    monkeypatch, capsys, restore_logging
):
    monkeypatch.setenv("KASA_COLLECTOR_VERSION", "2026.10.0")
    monkeypatch.delenv("LOG_FORMAT", raising=False)
    main.configure_app_logging()
    # `name` collides with a LogRecord attribute: stock logging raises KeyError here.
    logging.getLogger("KasaCollector").info("device up", extra={"name": "Fridge"})
    line = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert line["service"] == "kasa-collector"
    assert line["version"] == "2026.10.0"
    assert line["logger"] == "KasaCollector"
    assert line["message"] == "device up"
    assert line["attributes"] == {"name": "Fridge"}
