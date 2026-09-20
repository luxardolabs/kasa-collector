---
name: release
description: Cut an app release the same way every time — reconcile the tracker, write both release documents, tag vX.Y.Z, run the release function, create the GitHub Release (+ LuxPM mirror). Follow it end to end; never skip a step.
---

# App release ritual

The one runnable checklist for cutting a release of THIS app. Emitted from luxarch (`luxarch --emit release-skill`) so every repo has the identical one — do not hand-edit it; re-emit to update. The *rationale* for each step lives in `luxarch --doc FLEET-RELEASE-PROCESS`; this is the runnable steps. Do them in order. A skipped step is the whole point of failure this exists to prevent (a release that tagged but never built, or shipped with a stale changelog).

> Shipping a **guard** (luxarch/luxlint/luxaudit) uses that repo's own `release` skill, not this one.

## Non-negotiables (get these wrong and you leak or break provenance)

- **Commit + tag as the fleet identity** (global git config: name `luxardolabs`, the GitHub noreply email). Just `git commit` / `git tag`; **never** `-c user.email=…`. **No AI attribution** in any message (no "Co-Authored-By", no "Generated with").
- **The git tag is `vX.Y.Z`** (leading `v`) — the git-ecosystem convention. Everything else is **bare**: the `VERSION` file, the docker `:X.Y.Z` tag, the LuxPM release version. (The `v` marks a *git tag*; it is not part of the version number.)
- **`VERSION` file at repo root is the version source of truth.** Bump it; everything derives from it.
- **Build once, deploy that artifact.** `make release` (or the repo's `dev-build-push` / `prod-deploy`) pushes the image; every node pulls it. Never deploy from local source.
- **Everything runs in Docker** — `make check`/`lint`/`test` are `docker run`; no host `.venv`.

## Steps — do every one, in order

1. **Preconditions.** Clean working tree, on the release branch. The release gate is met at step 8 — `make check` green, or every red escalated + owner-approved + recorded (a red is fixed or escalated, never released *around*).
1. **Decide the version.** Bump `VERSION` — apps are **CalVer `YYYY.0M.MICRO`** (zero-padded month; first release of a month is `.0`). Record the previous tag; you diff against it next.
1. **Gather the window (git).** `git fetch --tags`, then `git log --no-merges <last-tag>..HEAD --pretty=format:'%h %s'` and `git diff --stat <last-tag>..HEAD`. Note the issue IDs referenced, migrations added (destructive vs additive), infra/ops changes, and which surfaces changed.
1. **Reconcile the tracker (LuxPM) — audit open → closed.** `luxpm_list_issues` for open issues; for each, decide if it shipped in this window (cross-ref the step-3 commits). Close the shipped ones (`luxpm_update_issue state=done` + a `close_summary`); leave the rest open; reverse-check that every commit's issue ID resolves to a closed issue. The **closed-this-window** set is your "Issues Closed".
1. **Write the technical change log — now, from the complete window** (not earlier in the cycle, and not as an afterthought *after* you ship). `<app>/change_logs/{VERSION}.md`, per `luxarch --emit changelog-guide`. A changelog written early goes stale and still passes `repo.release_docs_current` (which only checks the file *exists*). Sections: Issues Closed, Features, Refactors, Schema/Migrations, Infra/Ops, Fixes, Notes (pre/post-deploy steps at the top).
1. **Write the user-facing release notes — now, same window.** `<app>/release_notes/{VERSION}.md`, per `luxarch --emit release-notes-guide`. Walk the changelog through "would a user notice this?" → NEW/IMPROVED/FIXED, written to the user, no jargon, surface badges. (Headless repo? plain-text operator labels, no badge registry — see the guide.)
1. **Cross-check the two** (FLEET-RELEASE-PROCESS §6): nothing user-visible dropped; no jargon leaked; badges are registered surfaces; both files named exactly `{VERSION}.md`; root `CHANGELOG.md` + `RELEASE_NOTES.md` pointers exist.
1. **Meet the release gate** — `make check` **green**, OR every remaining red is examined + escalated (an open tracked issue) + **owner-approved** to ship while red + recorded under `## Known reds` in `change_logs/{VERSION}.md` (name each red, its issue, why it isn't fixable locally now). Do NOT hard- stop a correctly-escalated repo: a repo tracking the guards is red-by-design between pin drops, and the fleet does not gate on red. What still blocks: an **unexamined** red, or one **deferred to green** (`[rules.deferred]`/allowlist) instead of escalated. `repo.release_docs_current` / `repo.release_docs_present` must be genuinely green (they're this release's own deliverable, never a known red). See `luxarch --doc FLEET-RELEASE-PROCESS` §0.
1. **Commit** the `VERSION` bump + both documents together: `git add -A && git commit`.
1. **Tag `vX.Y.Z`** and push it: `git tag v$(cat VERSION) && git push && git push --tags`. This is the anchor the release object hangs off — do not skip it, and do not tag without the rest of this list.
1. **Run the release function — DO NOT SKIP.** `make release` (build + push `:$(VERSION)` + `:latest`), then deploy per `luxarch --doc FLEET-BUILD-DEPLOY-STANDARD` (dev/prod), migrate the DB per `luxarch --playbook alembic`. Tagging *instead of* running this is the exact miss this checklist prevents — a tag with no shipped artifact is not a release.
1. **Publish the GitHub Release — EVERY repo, do NOT stop at the pushed image.** A git tag is NOT a Release, and `make release`/`release-public` ships the *image*, not the notes. Create the Release so this version's notes land on `github.com/luxardolabs/<repo>/releases`: `gh release create v{VERSION} --title "{VERSION}" --notes-file <app>/release_notes/{VERSION}.md`. This is the repo's release record — **public OR private** (a private GitHub repo has a `/releases` page too; visibility just follows the repo). Skipping it leaves `/releases` empty while the notes you wrote in step 6 sit unused (verified by `repo.github_release_wired`). Public/private only decided the *image* registry (a public repo also ran `make release-public` → GHCR); it does NOT change this step.
1. **Mirror to LuxPM (the fleet index).** `luxpm_create_release(project_id=<this app's>, version="{VERSION}", status="released", release_date=<today>, changelog_md=<the change_logs/{VERSION}.md body>)`. This is the cross-project index + semantic-search layer, generated FROM the repo — a mirror of the GitHub Release above, not a substitute for it.

## Done when

Every step above is done: `VERSION` bumped; both `{VERSION}.md` documents written from the full window and cross-checked; every issue that shipped is closed in LuxPM (none falsely); the **release gate** met (`make check` green, or every red examined + escalated + owner-approved + listed under `## Known reds`); the `vX.Y.Z` tag pushed; the image built + pushed + **deployed**; the **GitHub Release created** (with the notes) on this repo's `/releases` — **every** repo, public or private — and **mirrored to LuxPM** (the fleet index). If the tag exists but the artifact was never built/deployed, the GitHub Release was never created (a tag is not a Release — `/releases` is empty), a red is unexamined or merely deferred, or either document is missing or stale, the release is **not** done.
