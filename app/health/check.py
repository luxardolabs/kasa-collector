#!/usr/bin/env python3
"""Docker health check script for Kasa Collector.

This standalone script is the container's HEALTHCHECK (`python -m app.health.check`). It is
healthy only when THIS run of the collector is storing data: the poller writes a heartbeat
(`app.health.heartbeat`) after every emeter cycle that stored data, and the check requires
that heartbeat to be fresh and written by the current PID 1.

It used to check something weaker. With file output off it reported healthy unconditionally,
and with it on it trusted the newest `.jsonl` in the output directory, which is a persistent
bind mount, so a file the previous build wrote made a new build "healthy" before it collected
anything. `make smoke` passed a container that collected nothing that way.

Exit codes:
    0 - Healthy: this process stored data within KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE
    1 - Unhealthy: no heartbeat, a stale one, or one left by a previous run

Configuration:
    KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE: Maximum heartbeat age in seconds (default: 120)
    KASA_COLLECTOR_HEARTBEAT_FILE: Heartbeat path (default: /tmp/kasa-collector.heartbeat)
"""

import json
import os
import sys
import time

from app.health import heartbeat

MAX_AGE_SECONDS = int(os.getenv("KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE", "120"))
# A beat's recorded start may trail PID 1's by the import time; it may never precede it by
# more than the clock-tick rounding of /proc. Anything earlier is a previous run's file.
_START_TOLERANCE_SECONDS = 1.0


def check_heartbeat() -> tuple[bool, str]:
    """Return (is_healthy, status_message) for the collector's heartbeat."""
    path = heartbeat.HEARTBEAT_FILE
    try:
        age = time.time() - os.stat(path).st_mtime
        with open(path, encoding="utf-8") as f:
            started_at = float(json.load(f)["started_at"])
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

    pid1_start = heartbeat.pid1_started_at()
    if pid1_start is not None and started_at < pid1_start - _START_TOLERANCE_SECONDS:
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
