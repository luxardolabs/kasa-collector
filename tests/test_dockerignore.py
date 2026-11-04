"""The image build contexts keep host junk, secrets and keys out at ANY depth.

A bare `.dockerignore` pattern (`__pycache__`, `.env`) matches only at the context root, while the
Dockerfile COPYs `app/` whole, so a host `app/**/__pycache__` or a gitignored `app/.env` reaches the
image unless the pattern is `**/`-anchored. The release's clean-tree gate never sees a gitignored
file, so the ignore file is the only barrier.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCKERIGNORE = ROOT / ".dockerignore"
HARNESS_DOCKERIGNORE = ROOT / "harness" / ".dockerignore"

SECRET_AND_BYTECODE_CLASSES = (
    "**/*.py[cod]",
    "**/.env",
    "**/.env.*",
    "**/*.env",
    "**/*credentials.json",
    "**/*.pem",
    "**/id_rsa*",
    "**/id_ecdsa*",
    "**/id_ed25519*",
    "**/.git",
)

MUST_EXCLUDE_AT_ANY_DEPTH = (
    *SECRET_AND_BYTECODE_CLASSES,
    "**/__pycache__",
    "**/output/",
    "**/.DS_Store",
)


def _patterns(path: Path = DOCKERIGNORE) -> set[str]:
    lines = path.read_text().splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def test_secrets_and_host_junk_are_excluded_at_any_depth() -> None:
    missing = [p for p in MUST_EXCLUDE_AT_ANY_DEPTH if p not in _patterns()]
    assert not missing, f".dockerignore must exclude these at any depth: {missing}"


def test_the_harness_context_excludes_secrets_and_bytecode_at_any_depth() -> None:
    wanted = (*SECRET_AND_BYTECODE_CLASSES, "**/__pycache__/")
    missing = [p for p in wanted if p not in _patterns(HARNESS_DOCKERIGNORE)]
    assert not missing, f"harness/.dockerignore must exclude these: {missing}"


def test_env_example_stays_includable() -> None:
    lines = [ln.strip() for ln in DOCKERIGNORE.read_text().splitlines()]
    assert "!.env.example" in lines
    # The last matching line wins: the re-include must follow every dotenv exclusion.
    last_exclusion = max(i for i, ln in enumerate(lines) if ln.startswith("**/.env"))
    assert lines.index("!.env.example") > last_exclusion
