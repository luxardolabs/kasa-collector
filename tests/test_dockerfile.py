"""The production image runs as appuser, which may write its output and never its own code.

A collector process that can rewrite `/app/app` can be made to persist: a hostile device response
that reaches a parser bug could change the code the container re-runs on its next restart. So the
code is copied root-owned with its modes set in the image (a checkout made under umask 077 would
otherwise leave appuser unable to import it), and the one directory appuser owns is `/app/output`,
where the exports and the device roster are written.
"""

import re
from pathlib import Path

DOCKERFILE = Path(__file__).resolve().parent.parent / "Dockerfile"


def _production_stage() -> list[str]:
    """The production stage's instructions, with backslash continuations joined."""
    text = DOCKERFILE.read_text().replace("\\\n", " ")
    lines, inside = [], False
    for raw in text.splitlines():
        line = raw.strip()
        if line.upper().startswith("FROM "):
            inside = bool(re.search(r"\bAS\s+production\b", line, re.IGNORECASE))
            continue
        if inside and line and not line.startswith("#"):
            lines.append(line)
    assert lines, "Dockerfile has no production stage"
    return lines


def test_nothing_is_copied_owned_by_the_runtime_user() -> None:
    stage = _production_stage()
    assert any(re.match(r"COPY\b.*\s/app/app\s*$", ln) for ln in stage), (
        "production stage must COPY the app package to /app/app"
    )
    chowned = [ln for ln in stage if ln.startswith("COPY") and "--chown" in ln]
    assert not chowned, chowned


def test_app_code_modes_are_set_readable_and_not_writable() -> None:
    stage = _production_stage()
    copy_at = next(
        i for i, ln in enumerate(stage) if re.match(r"COPY\b.*\s/app/app\s*$", ln)
    )
    chmods = [
        ln
        for ln in stage[copy_at:]
        if re.search(r"chmod\s+-R\s+a\+rX,go-w\s+/app/app", ln)
    ]
    assert chmods, (
        "after copying /app/app, set its modes with chmod -R a+rX,go-w /app/app"
    )


def test_the_runtime_user_owns_only_the_output_directory() -> None:
    chowns = [
        m.group(0)
        for ln in _production_stage()
        for m in re.finditer(r"chown\s+(?:-\S+\s+)*\S+\s+\S+", ln)
    ]
    assert chowns, "production stage must give appuser /app/output"
    assert all(
        re.fullmatch(r"chown\s+appuser:appuser\s+/app/output", c) for c in chowns
    ), chowns
    installs = [
        ln for ln in _production_stage() if re.search(r"\binstall\b.*\s-o\s", ln)
    ]
    assert not installs, installs


# The built image is the authority: scripts/e2e-test.sh fails if anything under /app or
# /opt/venv other than /app/output is owned by appuser or writable by group/other.
