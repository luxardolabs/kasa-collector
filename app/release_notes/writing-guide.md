<!-- luxarch:release-notes-guide asset v2 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit release-notes-guide`. -->

# Release Notes Writing Guide

Canonical fleet guide — emitted by `luxarch --emit release-notes-guide`. Drop it in at `<app>/release_notes/writing-guide.md`. This is the **user-facing** release notes — the people who actually use the app. NOT the dev team. For the internal, technical change log see `<app>/change_logs/` (`luxarch --emit changelog-guide`).

The full release PROCESS that produces this file is `luxarch --doc FLEET-RELEASE-PROCESS`; this guide is only the FORMAT of the user-facing half.

## Audience

The people who use this app every day. For a staff/admin app **they ARE the "users"** (the admin *is* the product), so a redesign of the admin UI belongs here. For a customer-facing app it's the customer. What does NOT belong: pure plumbing they'd never see.

## The test

For every line item, ask: **"Would a user notice this in the app?"**

- If it changes what they see, click, or the data they rely on — include it.
- If it's reliability/performance/accuracy they'd feel — include it, generalized.
- If only a developer would ever know (a refactor, a rename, a test) — leave it out.

## Format

```markdown
# {version} — {date}

One-line summary of the release theme.

## NEW
- **Feature name** `Surface` — What you can now do that you couldn't before.

## IMPROVED
- **What got better** `Surface` — How the experience changed, not what code changed.

## FIXED
- **What was broken** `Surface` — What you saw wrong, and that it's fixed now.
```

## Rules

### Write to the user — use "you/your"

- YES: "Your whole admin has a cleaner, faster layout."
- NO: "Migrated all admin pages from Bootstrap to Tailwind."

### Describe outcomes, not implementations

- YES: "Invoices you create or void now save correctly."
- NO: "Fixed create_manual_invoice → create_invoice(InvoiceCreate(...))."

### Leave out pure plumbing

Refactors, file renames, layering rules, schema-naming, import cleanups, the build/deploy pipeline, test suites — none of that is a line item. If backend work made things more reliable, roll it into one line: **Reliability** `Surface` — Lots of behind-the-scenes stability and speed work.

### The "would they file a bug?" test

Before a FIX, ask: would a user have noticed it was broken? If yes, include it (described as what they saw wrong). If no, skip it or roll it into "Reliability."

### No jargon

No framework/tooling names (HTMX, Tailwind, Starlette, mypy, CRUD, alembic, registry, …). Describe what the user sees instead.

### Keep it short

One sentence per item, two max. No sub-bullets.

### Categories

- **NEW** — Something you couldn't do before.
- **IMPROVED** — Something you had, now better.
- **FIXED** — Something was broken, now it isn't.

### Product surface badges

Every line gets a badge after the bold title naming the **surface** it ships on. A change that ships on more than one surface wears **both** badges — never a merged one. In an app that renders these notes on a releases page, **badges are a closed set wired in code** — a bare `` `Whatever` `` you invent renders unstyled. A badge is styled only if it's registered in **two** places:

1. `app/core/templates.py` → the `render_markdown` surface-badge transform (maps `` `Name` `` → `<code class="badge-name">`).
1. `app/templates/web/pages/releases/index.html` → a `.badge-<name>` CSS rule (colour + the `::before/::after { content: "" }` reset that strips the code-span backticks).

To add a surface, update BOTH places — not just this note.

### Apps with no releases page (headless, or a web app that has not added one yet)

The two-place wiring above exists because a releases page *renders* these notes and needs the badge styled. An app with no releases page has **no badge registry to register against** — a headless collector/poller (no `templates.py` at all), or a web app that has not built its releases page yet — and that is fine. Its `release_notes/{version}.md` is a plain Markdown file nobody renders through that transform, so:

- Use plain-text **surface** labels for the surfaces a user or operator actually experiences — e.g. `` `Collector` ``, `` `Dashboards` ``, `` `Site` ``, `` `Docs` `` — and say in the file that these are the repo's surfaces. There is **no** code registration to do; do not invent a `templates.py`/CSS entry for a page that does not exist.
- **Do not back-tick a non-surface token.** A backticked word (`` `GRAFANA_PORT` ``, a config var, a metric name) reads as a badge to the web transform — on a repo that later adds a releases page, or to a human skimming, it becomes a bogus badge. Leave config values, ports, and identifiers un-backticked (or in prose), and reserve backticks for the surface labels.
- When the app adds a releases page, register exactly the labels its notes already use, in both places above.

(Such an app still writes both documents per FLEET-RELEASE-PROCESS — the change log and these notes; the badge registry is the only part that needs a releases page, and this is how it degrades without one.)

## Per-repo parameters

- `{Surface}` set — your app's registered surfaces (e.g. `Web`, `Mobile`, `Portal`). Keep the two-place wiring above as the source of truth; never fold two distinct apps under one badge.
- `{version}` / `{date}` — the `VERSION` file's value and the cut date.

One file per version: `<app>/release_notes/{version}.md` (named to match `VERSION` exactly).

## This repo's own rules (the region at the end of this file)

The region that closes this file belongs to the repo, and no guard compares it. `repo.emitted_assets_current` reads everything above it line for line, and `luxarch --emit release-notes-guide --update <file>` carries it across a new version. Write the repo's rules **below** its comment line, never above it. The region may hold only two things:

- **Audience, narrowed** — who this repo's users are, and the surfaces that are NOT user surfaces here (for example, an admin only staff see behind a public site).
- **Per-repo parameters** — this repo's products and surface labels, a jargon list tuned to its stack, and worked YES/NO examples in its own words.

Everything above the region is the fleet's: the test, the format, the categories and the rules. Where the region disagrees with it, the fleet text wins. A fleet rule this repo needs changed is an escalation to the guard maintainer, not a region edit.

<!-- --- EDIT THIS: this repo's own writing rules -->
