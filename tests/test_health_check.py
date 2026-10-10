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


def _write_heartbeat(tmp_path, started_at, age_seconds=0.0):
    path = tmp_path / "heartbeat"
    path.write_text(json.dumps({"started_at": started_at}))
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
        _write_heartbeat(tmp_path, started_at=time.time())
        result = _run_check(tmp_path, KASA_COLLECTOR_WRITE_TO_FILE="False")
        assert result.returncode == 0, result.stdout

    def test_unhealthy_on_a_stale_heartbeat(self, tmp_path):
        _write_heartbeat(tmp_path, started_at=time.time() - 600, age_seconds=300)
        result = _run_check(tmp_path, KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE="120")
        assert result.returncode == 1, result.stdout

    def test_unhealthy_on_a_heartbeat_left_by_a_process_that_is_gone(self, tmp_path):
        # Fresh mtime, but written by a process that started before the current PID 1:
        # a restarted container must not inherit its predecessor's verdict. The suite runs
        # in the Linux test image, where /proc/1 always exists.
        started = heartbeat.pid1_started_at()
        assert started is not None
        _write_heartbeat(tmp_path, started_at=started - 3600)
        result = _run_check(tmp_path)
        assert result.returncode == 1, result.stdout


@pytest.mark.unit
class TestHeartbeatWriter:
    def test_beat_records_this_process_and_is_atomic(self, tmp_path, monkeypatch):
        path = tmp_path / "hb"
        monkeypatch.setattr(heartbeat, "HEARTBEAT_FILE", str(path))
        heartbeat.beat()
        assert (
            json.loads(path.read_text())["started_at"] == heartbeat.PROCESS_STARTED_AT
        )
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
