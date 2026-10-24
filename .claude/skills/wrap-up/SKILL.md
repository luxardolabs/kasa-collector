---
name: wrap-up
description: Close out a piece of work the fleet way before calling it done — tests written and run for what changed, every red in touched files fixed, docs updated (stale advice removed), make check green, committed in the issue's worktree, LuxPM fully closed out (issues, checklists, activities, commit links, sync receipt), then landed on the base branch, the worktree removed, and pushed as the repo declares. Every step reports evidence, not a tick.
---

<!-- luxarch:wrap-up-skill asset v17 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit wrap-up-skill`. -->

# Wrap up

The runnable close-out for any piece of work in this repo. Emitted from luxarch (`luxarch --emit wrap-up-skill`) so every repo runs the same one; do not hand-edit it, re-emit to update. The standard behind each step is `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` (the honesty gate, "End of session"); this is the steps.

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read it with these substitutions:

- **The gate.** It is `make ios-check` wherever this says `make check` or `make test`.
- **Seeing a test fail.** Run `swift test --filter <name>` for a package, or `xcodebuild test -only-testing:<target>/<class>/<method>` for an app.
- **What the suite cannot see** (step 2). That is the live backend, a device, push notifications or background tasks, not the deployed stack. `/adversarial` also covers the Keychain, in-app purchase and the backend contract.
- **The reds** (step 3). They are SwiftLint, swift-format, luxios's arch-check and Swift concurrency warnings. `make ios-format` fixes layout. The mypy playbook does not apply. A genuine waiver is a `swiftlint:disable` with its `// <why>` on the line directly above, never a bare one.
- **References.** Every `luxarch --doc X` is `$LUXIOS/docs/fleet/X.md`.
- **Pushing** (step 7). Push as the repo declares (`[agents] push` in `.luxarch.toml`, where it has one). Where nothing is declared, stop at the commit and say it is ready.

**Every step ends with its evidence**: a count, a command's output line, a commit SHA, an issue key. "Done" without the evidence is not done. If a step cannot be completed, say which and why; never skip it silently.

## 1. What changed

`git status` and `git diff --stat` against where the work started. List the files and behaviours you changed. Everything below is checked against this list.

## 2. Tests: written, seen to fail, attacked, run

A green suite is evidence only for what it can see. Four bugs in one repo passed a green `make check` and failed in the real stack (an outage among them), because nothing made anyone prove a test could fail or attack the change. So:

- **Every changed behaviour has a test, and you SAW it fail.** For each fix, in your worktree: reverse the fix alone as a patch (`git diff -- <the source files you changed> > <scratch>/fix.patch && git apply -R <scratch>/fix.patch`, keeping the test), run the new or changed test, and paste its failing line; restore (`git apply <scratch>/fix.patch`), run it again, and paste the pass. Never `git stash`: the stash is shared by every worktree of the repository. A test you never saw fail is not evidence (`luxarch --doc FLEET-VERIFICATION-STANDARD`). New behaviour: run the test before the code exists, or against the parent commit.
- **Attack it (`/adversarial`)** when the change touches authentication or authorization, tenant isolation, data writes or migrations, money, secrets or personal data, deploy or release, or fixes a guard red. An independent agent that did not write the change tries to make it wrong. Every break it reproduces is fixed and committed as a test. A change outside that list may still be attacked; it may not skip this step when inside it.
- **Say what the suite cannot see.** `make test` runs the app in-process against its test stack. If the change lives where that stack does not reach (a cache or queue the test stack lacks, nginx or the server's config, an entry point other than `app.main`, the production image), probe the deployed dev stack (`make smoke` where the repo has it) and paste the result.
- Run the tests that cover what changed first, then the whole suite (`make test`).
- **Evidence:** per test, its failing line before the fix and its pass after. The `/adversarial` report's CONFIRMED and UNREPRODUCED counts (or which category put the change outside it). Any stack probe's output. The suite's pass line.

## 3. Every red in a file you touched, and none moved

You touched it, you own it (conduct standard #11): fix every mypy, ruff and luxarch red in each changed file, not only yours, and never spend time proving one predates you. Check a file's luxarch reds with a targeted run, `luxarch --rule <id> --path <file>` (or `--path <file>` alone over the rules that fire there), never a full scan filtered through `grep`. For mypy, read `luxlint --playbook mypy-sweep` in full first. Fix by aligning the code; never `type: ignore`, `cast`, `Any`, `noqa` or an exemption.

A red can also be moved instead of fixed: the code goes to another layer, helper or consumer module, and a rule stops seeing it or another rule starts. Counting only the files you touched cannot see that. So compare the WHOLE repo. Take the base's committed status (`git show <base>:.luxarch-status.json`, and `.luxlint-status.json` the same way), run `make status` on your tree, and compare each rule's `violations` count in the two. A rule whose count rose anywhere is a red you moved: fix it in this change, or escalate it. A site that cleared because its code moved rather than changed is the same thing. A site you skipped because it is held (conduct standard, "Before you change code to clear a red") is named here with its issue key.

**Evidence:** per touched file, the red count before and after; the whole-repo per-rule delta (`<rule>: <before> → <after>` for every rule that changed); each held site you skipped, with its key.

## 4. Docs

- Update the doc that is the ONE home for what you changed (a `--doc`/`--playbook`, the repo's own docs, the changelog if the repo keeps one). Point, don't restate.
- **Search for advice your change made wrong, and delete it.** Stale instructions are how agents keep doing the old thing: grep the docs for the old command, flag, file or name.
- **Current state only.** Reread every comment, docstring, test name and doc line the diff adds (`git diff <base> -U0 | grep '^+'`). Each states what the code does now and why. Rewrite any that tells history ("used to", "no longer", "instead of", "the old…", "was green", a version that introduced it, an incident, an issue key): that goes in the commit message, the LuxPM issue and the change log (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, first principles).

**Evidence:** the doc lines changed, the grep you ran for the old advice, and the added lines you rewrote to current state (or "none tell history").

## 5. The gate, committed in the issue's worktree

- You are in the issue's worktree (`.claude/worktrees/<ISSUE-KEY>`; `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Concurrent agents: one worktree per issue"). If the work was done in the main checkout, that is the failure the standard exists to stop: say so in the report.
- `make check` green, run in the worktree. A red you could not fix stays red with an open escalation (`/escalate`), never deferred or silenced.
- Commit as `luxardolabs` via the global git config (never `git -c user.email=…`), no AI attribution.

**Evidence:** the `make check` result line, the commit SHA, `git status -s` empty in the worktree.

## 6. LuxPM, closed out

- Every issue this work touched: **closed** (`luxpm_update_issue` with a `close_summary` saying what shipped), or left open on purpose with a comment saying what remains. A comment is not a close. **Close when the code is done** (committed, pushed, gate green), never later: not "after the deploy", not "once I've checked prod". Deploying is the owner's step; a check of the deployed stack is its own step or its own issue.
- **Checklist items** done: one `luxpm_update_checklist(sequence_id, items=[{item: <number or title>, done: true}, …])` per issue, ticking every finished item. **Activities and todos** for this work completed (`luxpm_list_activities`).
- **Work logged with its commits**, one call per issue: `luxpm_log_activity(sequence_id, kind="code_change", content=<the evidence>, commits=[{sha, committed_at}, …])` records the entry AND links the commits (use `luxpm_link_commits` only for commits that belong to no issue), every commit with its `committed_at` (`git log -1 --format=%cI <sha>`): without it LuxPM cannot know the commit's age, and an old sha linked as evidence becomes the sync receipt's anchor. Link this repo's commits to this repo's issues only.
- **Every finding this session raised, filed or dropped.** Go back through the session, not just the diff: each bug, red, limit or follow-up you named in a reply ("not filed yet", "to file", "follow-up", "out of scope"), each `/adversarial` UNREPRODUCED or deferred item, each red you noticed in a file outside the change, and each owner aside. For each one: **search first** (`luxpm_semantic_search`, `luxpm_list_issues` with `search`), comment on the match, or create one; or name it dropped with the reason. One that lives only in the conversation is lost at the next compact.
- **A close summary is not a tracker.** Work you did not do — not built, deferred, a follow-up, a stated limit with a fix, an UNREPRODUCED finding — is filed as its own open issue BEFORE the close, and the close summary names that key beside it ("Not built: X (<ticket>)"), or says `dropped: <why>`. Written into a closed issue's summary or comment, it is tracked by nothing and nobody picks it up. The emitted `luxpm-close-tracks-deferrals` hook denies a close whose summary defers work without naming another issue or `dropped`.
- New follow-up work from the close-out itself: the same, search first, comment on an existing issue if found, create only if none.
- **Close on the commit and the green gate**: step 7 lands and pushes it next. If landing then fails, set the issue back to `in_progress` with the reason.
- Re-issue the **sync receipt** (`luxpm_issue_sync_receipt`), write it verbatim to `.luxpm-receipt` in the worktree, and commit it there: it lands with the work.
- **Read the receipt you just issued.** If `open_untriaged` or `closed_without_summary` is above zero (`repo.luxpm_backlog_triaged` reds it), the backlog beyond this work needs triage: say so in your report with the counts and run `/luxpm-audit` (it works in batches; a large backlog is not a reason to skip it). This step covers only what THIS work touched.

**Evidence:** each issue key with its new state; each finding the session raised with its issue key, or "dropped: <why>"; and the receipt's `issued_at`.

## 7. Land, remove the worktree, push

- In the worktree: `python3 .claude/hooks/worktree.py land`. If it rebased onto new commits (this machine's, or under `"agent"` another machine's, fetched from origin), it stops: re-run the touched tests and `make check` on the rebased code, then `land` again. A conflict stops it with nothing changed: resolve it in the worktree, re-run the gate, land.
- Pushing follows `.luxarch.toml`. `[agents] push = "agent"`: `land` pushes the tested HEAD to origin as it lands. If origin rejected it, origin moved: run `land` again, never `git pull --rebase` on the base. `push = "owner"`: `land` stays local; say the work is landed and ready. A repo with no declaration reds `repo.agent_push_declared`: ask the owner which it is, once, and write the answer there.
- `ExitWorktree` with `action: "keep"`, then from the main checkout `python3 .claude/hooks/worktree.py list --prune`: it prunes the worktree and its branch now that they are landed, clean, and locked by no one else. Not `ExitWorktree` `remove`: it judges the branch against the commit the worktree was made from, so it refuses every landed branch as unmerged work, and `discard_changes: true` is never the answer to that refusal.
- `python3 .claude/hooks/worktree.py list`: no worktree left for this issue.

**Evidence:** `land`'s `Landed and pushed N commit(s) on <base> at <sha>` line (`Landed N commit(s)` under `"owner"`), the `list` output, and `git status -sb` (nothing ahead under `"agent"`; the commits ahead named under `"owner"`).

## 8. Report

One short report: what shipped (with the evidence above), what is still open and why. No effort narration.
