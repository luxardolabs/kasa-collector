"""Heartbeat: the collector's proof, to the container HEALTHCHECK, that it is collecting.

The poller calls `beat()` after every emeter cycle that stored data. The health check
(`app.health.check`) is healthy only on a FRESH heartbeat written by the CURRENT process:

- fresh: younger than KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE;
- current: the writer's start time is not earlier than PID 1's, so a heartbeat a previous
  run left behind (a restarted container keeps its filesystem) does not count.

It lives in the container's own /tmp, never on the persistent output mount: a data file the
previous build wrote there used to make a new build "healthy" before it collected anything.

Standard library only: the health check imports this, and it must not load the app's
settings (which validate the whole environment) just to answer Docker.
"""

import json
import logging
import os
import time

logger = logging.getLogger(__name__)

HEARTBEAT_FILE = os.getenv(
    "KASA_COLLECTOR_HEARTBEAT_FILE", "/tmp/kasa-collector.heartbeat"
)
# When this process started, as near as the import allows: written into every beat so the
# health check can tell this run's heartbeat from a predecessor's.
PROCESS_STARTED_AT = time.time()


def beat() -> None:
    """Record that a collection cycle stored data. Never raises: a full disk or a read-only
    /tmp must not stop collection, so a failure is logged and the health check reports it."""
    tmp = f"{HEARTBEAT_FILE}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"started_at": PROCESS_STARTED_AT, "pid": os.getpid()}, f)
        # Atomic: the health check never reads a half-written file.
        os.replace(tmp, HEARTBEAT_FILE)
    except OSError as e:
        logger.warning("Could not write the health heartbeat %s: %s", HEARTBEAT_FILE, e)


def pid1_started_at() -> float | None:
    """Wall-clock start time of PID 1 (the container's main process), or None without /proc.

    /proc/1/stat field 22 is the start time in clock ticks since boot; /proc/stat's btime is
    the boot time in seconds since the epoch.
    """
    try:
        with open("/proc/1/stat", encoding="utf-8") as f:
            stat = f.read()
        # The command name (field 2) may contain spaces; fields resume after its ')'.
        fields = stat[stat.rindex(")") + 2 :].split()
        start_ticks = int(fields[19])
        with open("/proc/stat", encoding="utf-8") as f:
            btime = next(int(line.split()[1]) for line in f if line.startswith("btime"))
    except OSError, ValueError, IndexError, StopIteration:
        return None
    return btime + start_ticks / os.sysconf("SC_CLK_TCK")
