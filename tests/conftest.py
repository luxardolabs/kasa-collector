"""Shared pytest fixtures / test environment for kasa-collector.

`app.core.config.Config` reads configuration from the environment at import time
and calls ``sys.exit`` on *invalid* values. The InfluxDB connection settings are
plain ``os.getenv`` (default ``None``), so importing is safe without them, but we
set harmless dummy values here so any test that reads Config sees a complete,
valid configuration and never triggers a validation exit.
"""

import os

_TEST_ENV = {
    "KASA_COLLECTOR_INFLUXDB_URL": "http://influxdb.test:8086",
    "KASA_COLLECTOR_INFLUXDB_TOKEN": "test-token",
    "KASA_COLLECTOR_INFLUXDB_ORG": "test-org",
    "KASA_COLLECTOR_INFLUXDB_BUCKET": "test-bucket",
}

for _key, _value in _TEST_ENV.items():
    os.environ.setdefault(_key, _value)
