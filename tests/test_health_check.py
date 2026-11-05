"""The container HEALTHCHECK must mean "this process is collecting", nothing weaker.

Run exactly as Docker runs it (`python -m app.health.check`, exit code is the verdict). An
adversarial pass showed `make smoke` passing on a container that collected nothing: with file
output off the check was healthy unconditionally, and with it on, a data file the PREVIOUS build
left in the persistent output directory passed for the new one.
"""

import json
import logging
import os
import subprocess
import sys
import time

import pytest

from app.health import heartbeat


def _run_check(tmp_path, **env):
    full_env = {
        **os.environ,
        "KASA_COLLECTOR_HEARTBEAT_FILE": str(tmp_path / "heartbeat"),
        "KASA_COLLECTOR_OUTPUT_DIR": str(tmp_path / "output"),
        **env,
    }
    return subprocess.run(
        [sys.executable, "-m", "app.health.check"],
        env=full_env,
        capture_output=True,
        text=True,
        check=False,
    )


def _write_heartbeat(tmp_path, start_ticks=None, boot=None, age_seconds=0.0):
    """A heartbeat as this test process would write it, unless told otherwise."""
    path = tmp_path / "heartbeat"
    record = {
        "boot_id": boot or heartbeat.boot_id(),
        "start_ticks": heartbeat.start_ticks("self")
        if start_ticks is None
        else start_ticks,
    }
    path.write_text(json.dumps(record))
    then = time.time() - age_seconds
    os.utime(path, (then, then))


@pytest.mark.unit
class TestHealthCheckVerdict:
    def test_unhealthy_when_nothing_ever_collected_and_file_output_off(self, tmp_path):
        result = _run_check(tmp_path, KASA_COLLECTOR_WRITE_TO_FILE="False")
        assert result.returncode == 1, result.stdout

    def test_previous_builds_data_file_does_not_make_a_new_one_healthy(self, tmp_path):
        out = tmp_path / "output"
        out.mkdir()
        (out / "emeter_plug.jsonl").write_text(
            '{"10.0.0.5": {}}\n'
        )  # fresh, left behind
        result = _run_check(tmp_path, KASA_COLLECTOR_WRITE_TO_FILE="True")
        assert result.returncode == 1, result.stdout

    def test_healthy_on_a_fresh_heartbeat_from_the_running_process(self, tmp_path):
        _write_heartbeat(tmp_path)
        result = _run_check(tmp_path, KASA_COLLECTOR_WRITE_TO_FILE="False")
        assert result.returncode == 0, result.stdout

    def test_unhealthy_on_a_stale_heartbeat(self, tmp_path):
        _write_heartbeat(tmp_path, age_seconds=300)
        result = _run_check(tmp_path, KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE="120")
        assert result.returncode == 1, result.stdout

    def test_unhealthy_on_a_heartbeat_left_by_a_process_that_is_gone(self, tmp_path):
        # Fresh mtime, but written by a process that started before the current PID 1:
        # a restarted container must not inherit its predecessor's verdict. The suite runs
        # in the Linux test image, where /proc/1 always exists.
        pid1 = heartbeat.start_ticks("1")
        assert pid1 is not None
        _write_heartbeat(tmp_path, start_ticks=pid1 - 1)
        result = _run_check(tmp_path)
        assert result.returncode == 1, result.stdout

    def test_unhealthy_on_a_heartbeat_from_another_boot(self, tmp_path):
        _write_heartbeat(tmp_path, boot="00000000-0000-0000-0000-000000000000")
        result = _run_check(tmp_path)
        assert result.returncode == 1, result.stdout

    def test_a_max_age_the_collector_accepts_never_crashes_the_check(self, tmp_path):
        # The collector warns on "2m" and uses its default; the check must too.
        _write_heartbeat(tmp_path)
        result = _run_check(tmp_path, KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE="2m")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "Traceback" not in result.stderr

    def test_a_long_fetch_interval_raises_the_max_age(self, tmp_path):
        # Stored 200s ago with a 300s fetch interval: due, not stale.
        _write_heartbeat(tmp_path, age_seconds=200)
        result = _run_check(
            tmp_path,
            KASA_COLLECTOR_DATA_FETCH_INTERVAL="300",
            KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE="120",
        )
        assert result.returncode == 0, result.stdout


def _fake_proc(root, *, pid1_ticks, self_ticks, boot, btime):
    for pid, ticks in (("1", pid1_ticks), ("self", self_ticks)):
        (root / pid).mkdir(parents=True, exist_ok=True)
        fields = ["S"] + ["0"] * 18 + [str(ticks), "0"]
        (root / pid / "stat").write_text(f"{pid} (python) " + " ".join(fields))
    (root / "sys" / "kernel" / "random").mkdir(parents=True, exist_ok=True)
    (root / "sys" / "kernel" / "random" / "boot_id").write_text(boot + "\n")
    (root / "stat").write_text(f"cpu 0 0 0\nbtime {btime}\n")


@pytest.mark.unit
class TestRunIdentity:
    """The run is told by kernel start ticks and the boot id, never the wall clock."""

    def test_a_wall_clock_step_keeps_a_collecting_run_healthy(
        self, tmp_path, monkeypatch
    ):
        from app.health import check

        proc = tmp_path / "proc"
        monkeypatch.setattr(heartbeat, "PROC_ROOT", str(proc))
        monkeypatch.setattr(heartbeat, "HEARTBEAT_FILE", str(tmp_path / "hb"))
        _fake_proc(proc, pid1_ticks=100, self_ticks=150, boot="b1", btime=1_700_000_000)
        heartbeat.beat()

        # NTP steps the clock forward: the kernel's btime moves with it.
        _fake_proc(proc, pid1_ticks=100, self_ticks=150, boot="b1", btime=1_700_000_030)

        assert check.check_heartbeat()[0]

    def test_a_beat_older_than_pid1_is_a_previous_runs(self, tmp_path, monkeypatch):
        from app.health import check

        proc = tmp_path / "proc"
        monkeypatch.setattr(heartbeat, "PROC_ROOT", str(proc))
        monkeypatch.setattr(heartbeat, "HEARTBEAT_FILE", str(tmp_path / "hb"))
        _fake_proc(proc, pid1_ticks=100, self_ticks=50, boot="b1", btime=0)
        heartbeat.beat()

        ok, message = check.check_heartbeat()
        assert not ok
        assert "previous run" in message


@pytest.mark.unit
class TestHeartbeatWriter:
    def test_beat_records_this_process_and_is_atomic(self, tmp_path, monkeypatch):
        path = tmp_path / "hb"
        monkeypatch.setattr(heartbeat, "HEARTBEAT_FILE", str(path))
        heartbeat.beat()
        record = json.loads(path.read_text())
        assert record["boot_id"] == heartbeat.boot_id()
        assert record["start_ticks"] == heartbeat.start_ticks("self")
        assert not list(tmp_path.glob("*.tmp"))

    def test_beat_survives_an_unwritable_location(self, tmp_path, monkeypatch, caplog):
        monkeypatch.setattr(
            heartbeat, "HEARTBEAT_FILE", str(tmp_path / "no" / "dir" / "hb")
        )
        heartbeat.beat()  # must not raise: a full disk must not stop collection
        assert "heartbeat" in caplog.text.lower()


class _StopLoop(Exception):
    pass


@pytest.mark.unit
class TestPollerBeats:
    """The poller writes the heartbeat exactly when a cycle stored data."""

    async def _one_cycle(self, monkeypatch, tmp_path, stored):
        from app.collector import poller as poller_mod

        hb = tmp_path / "hb"
        monkeypatch.setattr(heartbeat, "HEARTBEAT_FILE", str(hb))

        async def stop(_seconds):
            raise _StopLoop

        monkeypatch.setattr(poller_mod.asyncio, "sleep", stop)

        class _Storage:
            async def write_collector_metrics(self, **kwargs):
                pass

        p = object.__new__(poller_mod.Poller)
        p.logger = logging.getLogger("test")
        p.on_reachable = None
        p.storage = _Storage()

        async def fetch(ip, device):
            return stored

        monkeypatch.setattr(p, "fetch_and_store_emeter_data", fetch)
        with pytest.raises(_StopLoop):
            await p.periodic_emeter_fetch({"10.0.0.5": object()})
        return hb

    async def test_beats_after_a_cycle_that_stored_data(self, monkeypatch, tmp_path):
        hb = await self._one_cycle(monkeypatch, tmp_path, stored=True)
        assert hb.exists()

    async def test_no_beat_when_nothing_was_stored(self, monkeypatch, tmp_path):
        hb = await self._one_cycle(monkeypatch, tmp_path, stored=False)
        assert not hb.exists()
