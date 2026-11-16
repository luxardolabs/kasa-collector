<!-- luxarch:changelog-guide asset v4 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit changelog-guide`. -->

# Change Log Writing Guide (INTERNAL)

Canonical fleet guide — emitted by `luxarch --emit changelog-guide`. Drop it in at `<app>/change_logs/writing-guide.md`. This is the **internal, technical** change log. NOT for end users / staff — only the platform/dev team reads it. For the user-facing version see `<app>/release_notes/` (`luxarch --emit release-notes-guide`).

The full release PROCESS that produces this file (walk git, reconcile issues, write both docs, tag, deploy) is `luxarch --doc FLEET-RELEASE-PROCESS` — follow it every release; this guide is only the FORMAT of the technical half.

## Audience

You. Future-you. Whoever's debugging "what changed in `<version>`". Nothing here is filtered for friendliness.

## Format

```markdown
# {version} — {date}

One-line release theme (optional).

## Issues Closed
- {PREFIX}-NNN — Title — short note on what landed.

## Features
- What got built. Reference issue IDs.

## Refactors
- Architectural changes, renames, file moves, migrations to new patterns.

## Schema / Migrations
- Alembic migrations in this release. Note destructive vs additive.

## Infra / Ops
- Docker/registry/deploy/env-var changes. Anything ops needs to know.

## Fixes
- Bug fixes with enough context to find them in git later.

## Notes

### Deploy runbook ({version})
1. [where it runs] `make <target>` or the exact command — expect: what success prints. On failure: what to do. Rollback: how.
2. [node] `python -m scripts.ops.<name> --dry-run`, then the same without `--dry-run` — every one-off script this release ships.

- Known issues. Deferred follow-ups.

## Known reds
- {RULE} — {PREFIX}-NNN — why it isn't fixable locally now (escalated, owner-approved to ship red).
```

Omit **Known reds** when `make check` is green. Include it only when the release ships with a guard red that is examined, escalated (an open tracked issue), and owner-approved — the recorded exception the release gate requires (see `luxarch --doc FLEET-RELEASE-PROCESS` §0). A red that is unexamined, or deferred to green (`[rules.deferred]`/allowlist) rather than escalated, is **not** a Known red — it blocks the release. Mirror this section into the LuxPM release object too.

## Rules

- Reference `{PREFIX}-NNN` issue IDs liberally — this is the back-link to the tracker (LuxPM). Every issue the release closed appears under **Issues Closed** (the release process audits open→closed).
- Jargon is fine. Acronyms are fine. This is for engineers.
- No end-user impact framing — that belongs in `release_notes/`.
- Mention destructive operations (drops, force pushes, data backfills, prod cutovers) **prominently**.
- **Notes opens with the deploy runbook**, `### Deploy runbook ({version})`: every step of this release's deploy, in order, from the first command to the last check, so whoever deploys follows one list and no other document. It is the repo's standing procedure (`docs/deployment/prod-release.md`) filled in for this release, plus each one-off operator script the release ships (its row in `<component>/scripts/ops/README.md` names this version) and each owner step (a secret to set, a DNS change). Each step is a make target or an exact command, never a description, and says where it runs (a `[host]` tag), what success looks like, what to do if it fails, and how to roll it back where that differs from the standing procedure. `repo.ops_scripts_in_runbook` reds a one-off script this release ships that the runbook does not run. A release with nothing to deploy beyond the standing procedure still carries the heading, with the standing procedure's steps.
- One file per version: `<app>/change_logs/{version}.md` (named to match the repo `VERSION` file exactly — `repo.release_docs_current` reds a version bump with no matching file).

## Per-repo parameters

- `{PREFIX}` — your LuxPM project's issue prefix (e.g. `SHOP`, `APP`).
- `{version}` / `{date}` — the `VERSION` file's value (CalVer `YYYY.0M.MICRO` for apps) and the cut date.

## This repo's own rules (the region at the end of this file)

The region that closes this file belongs to the repo, and no guard compares it. `repo.emitted_assets_current` reads everything above it line for line, and `luxarch --emit changelog-guide --update <file>` carries it across a new version. Write the repo's rules **below** its comment line, never above it. The region may hold only two things:

- **Audience, narrowed** — who reads this repo's change log beyond its own developers, if anyone (for example, an operator who deploys it).
- **Per-repo parameters** — this repo's issue prefix, a jargon list tuned to its stack, and how it records work the format above has no section for (for example, guard upgrades as outcomes and counts, not a rule-by-rule replay).

Everything above the region is the fleet's: the test, the format, the categories and the rules. Where the region disagrees with it, the fleet text wins. A fleet rule this repo needs changed is an escalation to the guard maintainer, not a region edit.

<!-- --- EDIT THIS: this repo's own writing rules -->
