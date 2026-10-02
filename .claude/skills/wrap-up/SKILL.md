---
name: wrap-up
description: Close out a piece of work the fleet way before calling it done — tests written and run for what changed, every red in touched files fixed, docs updated (stale advice removed), make check green, committed and pushed, and LuxPM fully closed out (issues, checklists, activities, commit links, sync receipt). Every step reports evidence, not a tick.
---

<!-- luxarch:wrap-up-skill asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit wrap-up-skill`. -->

# Wrap up

The runnable close-out for any piece of work in this repo. Emitted from luxarch (`luxarch --emit wrap-up-skill`) so every repo runs the same one; do not hand-edit it, re-emit to update. The standard behind each step is `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` (the honesty gate, "End of session"); this is the steps.

**Every step ends with its evidence**: a count, a command's output line, a commit SHA, an issue key. "Done" without the evidence is not done. If a step cannot be completed, say which and why; never skip it silently.

## 1. What changed

`git status` and `git diff --stat` against where the work started. List the files and behaviours you changed. Everything below is checked against this list.

## 2. Tests: written, updated, run

- Every changed **behaviour** has a test that would fail without the change: new behaviour gets a new test, changed behaviour an updated one. A test that could not fail proves nothing (`luxarch --doc FLEET-VERIFICATION-STANDARD`).
- Run the tests that cover what changed first, then the full suite (`make test`).
- **Evidence:** the test names you added or changed, and the suite's pass line.

## 3. Every red in a file you touched

You touched it, you own it (conduct standard #11): fix every mypy, ruff and luxarch red in each changed file, not only yours, and never spend time proving one predates you. For mypy, read `luxlint --playbook mypy-sweep` in full first. Fix by aligning the code; never `type: ignore`, `cast`, `Any`, `noqa` or an exemption.

**Evidence:** per touched file, the red count before and after.

## 4. Docs

- Update the doc that is the ONE home for what you changed (a `--doc`/`--playbook`, the repo's own docs, the changelog if the repo keeps one). Point, don't restate.
- **Search for advice your change made wrong, and delete it.** Stale instructions are how agents keep doing the old thing: grep the docs for the old command, flag, file or name.

**Evidence:** the doc lines changed, and the grep you ran for the old advice.

## 5. The gate, committed and pushed

- `make check` green. A red you could not fix stays red with an open escalation (`/escalate`), never deferred or silenced.
- Commit as `luxardolabs` via the global git config (never `git -c user.email=…`), no AI attribution. Push.

**Evidence:** the `make check` result line, the commit SHA, `git status -sb` showing nothing ahead.

## 6. LuxPM, closed out

- Every issue this work touched: **closed** (`luxpm_update_issue` with a `close_summary` saying what shipped and anything deliberately not done), or left open on purpose with a comment saying what remains. A comment is not a close.
- **Checklist items** done (`luxpm_complete_checklist_item`), and **activities and todos** for this work completed (`luxpm_list_activities`).
- **Commits linked** to their issues (`luxpm_link_commits`). Link this repo's commits to this repo's issues only.
- New follow-up work: **search first** (`luxpm_semantic_search`, `luxpm_list_issues` with `search`), comment on an existing issue if found, create only if none.
- Re-issue the **sync receipt** (`luxpm_issue_sync_receipt`), write it verbatim to `.luxpm-receipt`, commit and push it.

**Evidence:** each issue key with its new state, and the receipt's `issued_at`.

## 7. Report

One short report: what shipped (with the evidence above), what is still open and why. No effort narration.
