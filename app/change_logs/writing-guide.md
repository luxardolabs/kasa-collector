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
- Pre-/post-deploy steps. Known issues. Deferred follow-ups.

## Known reds
- {RULE} — {PREFIX}-NNN — why it isn't fixable locally now (escalated, owner-approved to ship red).
```

Omit **Known reds** when `make check` is green. Include it only when the release ships with a guard red that is examined, escalated (an open tracked issue), and owner-approved — the recorded exception the release gate requires (see `luxarch --doc FLEET-RELEASE-PROCESS` §0). A red that is unexamined, or deferred to green (`[rules.deferred]`/allowlist) rather than escalated, is **not** a Known red — it blocks the release. Mirror this section into the LuxPM release object too.

## Rules

- Reference `{PREFIX}-NNN` issue IDs liberally — this is the back-link to the tracker (LuxPM). Every issue the release closed appears under **Issues Closed** (the release process audits open→closed).
- Jargon is fine. Acronyms are fine. This is for engineers.
- No end-user impact framing — that belongs in `release_notes/`.
- Mention destructive operations (drops, force pushes, data backfills, prod cutovers) **prominently**.
- Pre-/post-deploy steps go at the **top** of the relevant section, not buried.
- One file per version: `<app>/change_logs/{version}.md` (named to match the repo `VERSION` file exactly — `repo.release_docs_current` reds a version bump with no matching file).

## Per-repo parameters

- `{PREFIX}` — your LuxPM project's issue prefix (e.g. `BOUTIQUE`, `LUXWX`).
- `{version}` / `{date}` — the `VERSION` file's value (CalVer `YYYY.0M.MICRO` for apps) and the cut date.
