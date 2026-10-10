---
name: wrap-up
description: Close out a piece of work the fleet way before calling it done — tests written and run for what changed, every red in touched files fixed, docs updated (stale advice removed), make check green, committed and pushed, and LuxPM fully closed out (issues, checklists, activities, commit links, sync receipt). Every step reports evidence, not a tick.
---

<!-- luxarch:wrap-up-skill asset v7 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit wrap-up-skill`. -->

# Wrap up

The runnable close-out for any piece of work in this repo. Emitted from luxarch (`luxarch --emit wrap-up-skill`) so every repo runs the same one; do not hand-edit it, re-emit to update. The standard behind each step is `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` (the honesty gate, "End of session"); this is the steps.

**In an iOS repo** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read it with these substitutions:

- **The gate.** It is `make ios-check` wherever this says `make check` or `make test`.
- **Seeing a test fail.** Run `swift test --filter <name>` for a package, or `xcodebuild test -only-testing:<target>/<class>/<method>` for an app.
- **What the suite cannot see** (step 2). That is the live backend, a device, push notifications or background tasks, not the deployed stack. `/adversarial` also covers the Keychain, in-app purchase and the backend contract.
- **The reds** (step 3). They are SwiftLint, swift-format, luxios's arch-check and Swift concurrency warnings. `make ios-format` fixes layout. The mypy playbook does not apply. A genuine waiver is a `swiftlint:disable` with its `// <why>` on the line directly above, never a bare one.
- **References.** Every `luxarch --doc X` is `$LUXIOS/docs/fleet/X.md`.
- **Pushing** (step 5). Push only where the owner has said pushing this repo is yours to do. Otherwise stop at the commit and say it is ready.

**Every step ends with its evidence**: a count, a command's output line, a commit SHA, an issue key. "Done" without the evidence is not done. If a step cannot be completed, say which and why; never skip it silently.

## 1. What changed

`git status` and `git diff --stat` against where the work started. List the files and behaviours you changed. Everything below is checked against this list.

## 2. Tests: written, seen to fail, attacked, run

A green suite is evidence only for what it can see. Four bugs in one repo passed a green `make check` and failed in the real stack (an outage among them), because nothing made anyone prove a test could fail or attack the change. So:

- **Every changed behaviour has a test, and you SAW it fail.** For each fix: revert the fix alone (`git stash push -- <the source files you changed>`, keeping the test), run the new or changed test, and paste its failing line; restore (`git stash pop`), run it again, and paste the pass. A test you never saw fail is not evidence (`luxarch --doc FLEET-VERIFICATION-STANDARD`). New behaviour: run the test before the code exists, or against the parent commit.
- **Attack it (`/adversarial`)** when the change touches authentication or authorization, tenant isolation, data writes or migrations, money, secrets or personal data, deploy or release, or fixes a guard red. An independent agent that did not write the change tries to make it wrong. Every break it reproduces is fixed and committed as a test. A change outside that list may still be attacked; it may not skip this step when inside it.
- **Say what the suite cannot see.** `make test` runs the app in-process against its test stack. If the change lives where that stack does not reach (a cache or queue the test stack lacks, nginx or the server's config, an entry point other than `app.main`, the production image), probe the deployed dev stack (`make smoke` where the repo has it) and paste the result.
- Run the tests that cover what changed first, then the whole suite (`make test`).
- **Evidence:** per test, its failing line before the fix and its pass after. The `/adversarial` report's CONFIRMED and UNREPRODUCED counts (or which category put the change outside it). Any stack probe's output. The suite's pass line.

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
- **Checklist items** done: one `luxpm_update_checklist(sequence_id, items=[{item: <number or title>, done: true}, …])` per issue, ticking every finished item. **Activities and todos** for this work completed (`luxpm_list_activities`).
- **Work logged with its commits**, one call per issue: `luxpm_log_activity(sequence_id, kind="code_change", content=<the evidence>, commits=[{sha, committed_at}, …])` records the entry AND links the commits (use `luxpm_link_commits` only for commits that belong to no issue), every commit with its `committed_at` (`git log -1 --format=%cI <sha>`): without it LuxPM cannot know the commit's age, and an old sha linked as evidence becomes the sync receipt's anchor. Link this repo's commits to this repo's issues only.
- New follow-up work: **search first** (`luxpm_semantic_search`, `luxpm_list_issues` with `search`), comment on an existing issue if found, create only if none.
- Re-issue the **sync receipt** (`luxpm_issue_sync_receipt`), write it verbatim to `.luxpm-receipt`, commit and push it.
- **Read the receipt you just issued.** If `open_untriaged` or `closed_without_summary` is above zero (`repo.luxpm_backlog_triaged` reds it), the backlog beyond this work needs triage: say so in your report with the counts and run `/luxpm-audit` (it works in batches; a large backlog is not a reason to skip it). This step covers only what THIS work touched.

**Evidence:** each issue key with its new state, and the receipt's `issued_at`.

## 7. Report

One short report: what shipped (with the evidence above), what is still open and why. No effort narration.
