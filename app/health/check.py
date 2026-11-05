#!/usr/bin/env python3
"""Docker health check script for Kasa Collector.

This standalone script is the container's HEALTHCHECK (`python -m app.health.check`). It is
healthy only when THIS run of the collector is storing data: the poller writes a heartbeat
(`app.health.heartbeat`) after every emeter cycle that stored data, and the check requires
that heartbeat to be fresh and written by a process no older than the current PID 1. A data
file in the persistent output directory is never evidence: a previous build may have left it.

Exit codes:
    0 - Healthy: this process stored data within KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE
    1 - Unhealthy: no heartbeat, a stale one, or one left by a previous run

Configuration:
    KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE: Maximum heartbeat age in seconds, read through
        Config (default 120, and never less than two KASA_COLLECTOR_DATA_FETCH_INTERVALs)
    KASA_COLLECTOR_HEARTBEAT_FILE: Heartbeat path (default: /tmp/kasa-collector.heartbeat)
"""

import json
import os
import sys
import time

from app.core.config import Config
from app.health import heartbeat

# Read the way the collector reads it, so a value the collector accepts never crashes the
# check, and with the same floor of two fetch intervals.
MAX_AGE_SECONDS = Config.KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE


def check_heartbeat() -> tuple[bool, str]:
    """Return (is_healthy, status_message) for the collector's heartbeat."""
    path = heartbeat.HEARTBEAT_FILE
    try:
        age = time.time() - os.stat(path).st_mtime
        with open(path, encoding="utf-8") as f:
            record = json.load(f)
        if not isinstance(record, dict):
            raise ValueError("not a heartbeat record")
    except FileNotFoundError:
        return (
            False,
            "no heartbeat yet: no collection cycle has stored data in this run",
        )
    except (OSError, ValueError, KeyError, TypeError) as e:
        return False, f"heartbeat {path} is unreadable: {e}"

    if age > MAX_AGE_SECONDS:
        return (
            False,
            f"last stored data {age:.0f}s ago (max allowed: {MAX_AGE_SECONDS}s)",
        )

    if heartbeat.written_by_a_previous_run(record):
        return False, "heartbeat was written by a previous run, not this process"

    return True, f"Healthy - last stored data {age:.0f}s ago"


def main() -> None:
    """Print the verdict with version information and exit 0 (healthy) or 1."""
    is_healthy, message = check_heartbeat()
    version = os.getenv("KASA_COLLECTOR_VERSION", "unknown")
    build_timestamp = os.getenv("KASA_COLLECTOR_BUILD_TIMESTAMP", "unknown")

    print(f"Health check: {'HEALTHY' if is_healthy else 'UNHEALTHY'}")
    print(f"Version: {version} (Built: {build_timestamp})")
    print(f"  - Collection: {message}")
    sys.exit(0 if is_healthy else 1)


if __name__ == "__main__":
    main()
