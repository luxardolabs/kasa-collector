"""Heartbeat: the collector's proof, to the container HEALTHCHECK, that it is collecting.

The poller calls `beat()` after every emeter cycle that stored data. The health check
(`app.health.check`) is healthy only on a FRESH heartbeat written by the CURRENT process:

- fresh: younger than KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE;
- current: written during this boot, by a process that started no earlier than PID 1, so
  a heartbeat a previous run left behind (a restarted container keeps its filesystem) does
  not count.

"Current" is judged by the kernel's own start times, in clock ticks since boot, and the
boot id. Neither moves when the wall clock is stepped (NTP on a Pi with no clock battery,
a resumed VM), so a step never makes a collecting run read as a previous one.

It lives in the container's own /tmp, never on the persistent output mount: a data file the
previous build wrote there used to make a new build "healthy" before it collected anything.

Standard library only: the health check imports this.
"""

import json
import logging
import os

logger = logging.getLogger(__name__)

HEARTBEAT_FILE = os.getenv(
    "KASA_COLLECTOR_HEARTBEAT_FILE", "/tmp/kasa-collector.heartbeat"
)
PROC_ROOT = "/proc"


def start_ticks(pid: str) -> int | None:
    """When process ``pid`` (a number, or ``self``) started, in clock ticks since boot.

    Field 22 of /proc/<pid>/stat; None without /proc.
    """
    try:
        with open(f"{PROC_ROOT}/{pid}/stat", encoding="utf-8") as f:
            stat = f.read()
        # The command name (field 2) may contain spaces; fields resume after its ')'.
        return int(stat[stat.rindex(")") + 2 :].split()[19])
    except OSError, ValueError, IndexError:
        return None


def boot_id() -> str | None:
    """This boot's id, which start ticks count from; None without /proc."""
    try:
        with open(f"{PROC_ROOT}/sys/kernel/random/boot_id", encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def beat() -> None:
    """Record that a collection cycle stored data. Never raises: a full disk or a read-only
    /tmp must not stop collection, so a failure is logged and the health check reports it."""
    tmp = f"{HEARTBEAT_FILE}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "boot_id": boot_id(),
                    "start_ticks": start_ticks("self"),
                    "pid": os.getpid(),
                },
                f,
            )
        # Atomic: the health check never reads a half-written file.
        os.replace(tmp, HEARTBEAT_FILE)
    except OSError as e:
        logger.warning("Could not write the health heartbeat %s: %s", HEARTBEAT_FILE, e)


def written_by_a_previous_run(beat_record: dict[str, object]) -> bool:
    """Whether ``beat_record`` was written before this container's PID 1 started.

    A beat from another boot, or from a process that started before PID 1, is a previous
    run's. Without /proc there is nothing to compare, and the beat is taken as current.
    """
    current_boot, pid1_ticks = boot_id(), start_ticks("1")
    if current_boot is None or pid1_ticks is None:
        return False
    writer_ticks = beat_record.get("start_ticks")
    return (
        beat_record.get("boot_id") != current_boot
        or not isinstance(writer_ticks, int)
        or writer_ticks < pid1_ticks
    )
