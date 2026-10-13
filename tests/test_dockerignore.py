"""The image build context keeps host junk and secrets out at ANY depth.

A bare `.dockerignore` pattern (`__pycache__`, `.env`) matches only at the context root, while the
Dockerfile COPYs `app/` whole. So the host's `app/**/__pycache__` and `app/.DS_Store` shipped in
every image, and a gitignored `app/.env` would too: the release's clean-tree gate never sees a
gitignored file.
"""

from pathlib import Path

DOCKERIGNORE = Path(__file__).resolve().parent.parent / ".dockerignore"

MUST_EXCLUDE_AT_ANY_DEPTH = (
    "**/__pycache__",
    "**/*.py[cod]",
    "**/.env",
    "**/.env.*",
    "**/output/",
    "**/.DS_Store",
)


def _patterns() -> set[str]:
    lines = DOCKERIGNORE.read_text().splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def test_secrets_and_host_junk_are_excluded_at_any_depth() -> None:
    missing = [p for p in MUST_EXCLUDE_AT_ANY_DEPTH if p not in _patterns()]
    assert not missing, f".dockerignore must exclude these at any depth: {missing}"


def test_env_example_stays_includable() -> None:
    assert "!.env.example" in _patterns()
