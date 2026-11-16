"""The dev stack runs on the dev host, publishes no port, and still reaches its InfluxDB.

FLEET-BUILD-DEPLOY-STANDARD, "The dev host": the dev stack runs where the committed DEV_HOST
says and publishes no host port; its Grafana is served by name through the dev host's edge.
The collector is on the host's network (discovery is a LAN broadcast), where no compose service
name resolves, so it reaches the dev InfluxDB at a fixed address on a pinned subnet. These read
the committed files compose and `make` read, so a regression fails here, not at the next deploy.
"""

import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
COMPOSE = (REPO / "compose.yml").read_text()
MAKEFILE = (REPO / "Makefile").read_text()
DEV_GRAFANA_ENTRYPOINT = REPO / "ops" / "grafana" / "dev-entrypoint.sh"


def _service(name: str) -> str:
    """One service's block: from its `  <name>:` line to the next top-level key or service."""
    match = re.search(
        rf"^  {re.escape(name)}:\n((?:(?:    .*)?\n)+?)(?=^  \S|^\S|\Z)", COMPOSE, re.M
    )
    assert match, f"compose.yml has no service {name}"
    return match.group(1)


def _make_setting(name: str) -> list[str]:
    match = re.search(rf"^{name}\s*:=\s*(.+)$", MAKEFILE, re.M)
    assert match, f"{name} is not set with := in the Makefile"
    return match.group(1).split()


def test_the_dev_stack_runs_on_the_declared_dev_host() -> None:
    """dev-pin and smoke reach the dev host's docker; the repo's own dev-* targets must too,
    or they start, stop or read a stack on whichever machine runs make."""
    assert _make_setting("DEV_HOST") == ["devhost"]
    assert re.search(
        r"^DEV_DC\s+= DOCKER_HOST=ssh://\$\(DEV_HOST\) docker compose --env-file \.env\.dev$",
        MAKEFILE,
        re.M,
    )


@pytest.mark.parametrize("name", ["kasa_influxdb", "kasa_grafana"])
def test_the_dev_pair_publishes_no_host_port(name: str) -> None:
    service = _service(name)
    assert "ports:" not in service, name
    assert "profiles: [bundled]" in service, name


def test_the_dev_grafana_is_served_by_name_on_the_edge() -> None:
    """The edge hands the dev name to http://kasa_grafana:3000 on `dev-edge` ([dev_host] in
    .luxarch.toml); a Grafana off that network cannot be reached at all."""
    service = _service("kasa_grafana")
    assert "container_name: kasa_grafana" in service
    assert "networks: [kasa_dev, dev-edge]" in service
    assert re.search(r"^  dev-edge:\n    external: true$", COMPOSE, re.M)
    toml = (REPO / ".luxarch.toml").read_text()
    assert re.search(
        r'^\[dev_host\]\nfront = "app"\nservice = "kasa_grafana"$', toml, re.M
    )


def test_the_host_networked_collector_can_reach_the_dev_influxdb() -> None:
    """With no published port, the address the env template tells the collector to write to
    must be the dev InfluxDB's fixed address, inside the subnet its network is pinned to."""
    assert "network_mode: host" in _service("kasa-collector")
    influx = _service("kasa_influxdb")
    address = re.search(r"ipv4_address: \$\{KASA_DEV_INFLUX_ADDR:-([\d.]+)\}", influx)
    assert address, "the dev InfluxDB has no fixed address"
    subnet = re.search(r"- subnet: \$\{KASA_DEV_SUBNET:-([\d.]+)\.0/24\}", COMPOSE)
    assert subnet, "the kasa_dev network's subnet is not pinned"
    assert address[1].startswith(subnet[1] + "."), (address[1], subnet[1])
    assert "kasa_dev:" in influx
    template = (REPO / ".env.example").read_text()
    assert f"http://{address[1]}:8086" in template


def test_each_grafana_reaches_its_own_stacks_influxdb() -> None:
    datasource = (
        REPO / "grafana" / "provisioning" / "datasources" / "influxdb.yml"
    ).read_text()
    assert "url: http://${INFLUX_HOST}:8086" in datasource
    for grafana, influx, profiles in (
        ("kasa_grafana", "kasa_influxdb", "[bundled]"),
        ("kasa_local_grafana", "kasa_local_influxdb", "[local, demo]"),
    ):
        assert f"INFLUX_HOST: {influx}" in _service(grafana), grafana
        assert f"profiles: {profiles}" in _service(grafana), grafana
        assert f"profiles: {profiles}" in _service(influx), influx


def test_a_clone_can_still_run_its_real_devices_with_a_bundled_stack_here() -> None:
    """The dev stack moved to the fleet's dev host; anyone else running the collector from a
    clone keeps a stack on their own machine: the collector plus the published local pair,
    profiles named on the command line so .env.example's dev profiles never start the dev pair."""
    assert re.search(
        r"^LOCAL_DC := docker compose --env-file \.env\.local --profile collector"
        r" --profile local$",
        MAKEFILE,
        re.M,
    )
    for target in ("local-up", "local-down", "local-logs", "local-ps"):
        assert re.search(rf"^{target}:.*\n\t\$\(LOCAL_DC\) ", MAKEFILE, re.M), target
    for name in ("kasa_local_influxdb", "kasa_local_grafana"):
        assert "ports:" in _service(name), name


def test_the_demo_collector_writes_to_the_demos_influxdb() -> None:
    demo = _service("kasa-collector-demo")
    assert "KASA_COLLECTOR_INFLUXDB_URL: http://kasa_local_influxdb:8086" in demo
    assert "kasa_local_influxdb:\n        condition: service_healthy" in demo


def test_the_dev_grafana_starts_through_the_password_guard() -> None:
    service = _service("kasa_grafana")
    # sh exits 0, silently, when its script is a directory: the shape docker gives a missing
    # bind source. Grafana must then fail loudly instead of restarting in silence.
    assert 'entrypoint: ["/bin/sh", "-c", "test -f /ops/dev-entrypoint.sh' in service
    assert "exit 1; }; exec /bin/sh /ops/dev-entrypoint.sh" in service
    assert "- ./ops/grafana/dev-entrypoint.sh:/ops/dev-entrypoint.sh:ro" in service


def _guard(tmp_path: Path, password: str, cli_exit: int = 0):
    """Run the dev Grafana entrypoint with a stand-in `grafana` that records its arguments
    (one call per line) and what it read on stdin (in `<tmp>/stdin`)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls"
    cli = bin_dir / "grafana"
    cli.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$*" >> {calls}\ncat > {tmp_path / "stdin"}\n'
        f"exit {cli_exit}\n"
    )
    cli.chmod(0o755)
    run = subprocess.run(
        ["/bin/sh", str(DEV_GRAFANA_ENTRYPOINT)],
        env={
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "GF_SECURITY_ADMIN_PASSWORD": password,
        },
        capture_output=True,
        text=True,
        check=False,
    )
    return run, (calls.read_text().splitlines() if calls.exists() else [])


@pytest.mark.parametrize(
    "password",
    [
        "",
        "admin",
        "ADMIN",
        "choose-a-password",
        "   ",
        # the CLI reads stdin's first line only: `admin\n…` would set `admin`
        "admin\nZq7-unrelated-suffix",
        "S3cret-pw\r",
    ],
)
def test_the_dev_grafana_refuses_a_default_or_published_password(
    tmp_path: Path, password: str
) -> None:
    """Served by name, the dev Grafana never takes a password anyone can guess: none,
    Grafana's default, or the placeholder this public repo's env template shows."""
    run, calls = _guard(tmp_path, password)
    assert run.returncode == 1
    assert "REFUSING" in run.stderr
    assert calls == []


@pytest.mark.parametrize("password", ["S3cret pw with spaces*", "-Rk9vT2qLm8w"])
def test_the_dev_grafana_sets_its_admin_password_on_every_start(
    tmp_path: Path, password: str
) -> None:
    """Grafana applies GF_SECURITY_ADMIN_PASSWORD only when it creates its database, so a
    volume first started with admin/admin keeps it unless the entrypoint sets it each start.
    It goes on stdin, never as an argument: no `ps` shows it, and a leading `-` is no flag."""
    run, calls = _guard(tmp_path, password)
    assert calls == [
        "cli --homepath /usr/share/grafana admin reset-admin-password"
        " --password-from-stdin"
    ]
    assert (tmp_path / "stdin").read_text() == password
    assert password not in run.stdout + run.stderr


def test_the_dev_grafana_does_not_start_when_its_password_cannot_be_set(
    tmp_path: Path,
) -> None:
    run, calls = _guard(tmp_path, "S3cret-pw", cli_exit=1)
    assert run.returncode == 1
    assert "REFUSING" in run.stderr
    assert len(calls) == 1
