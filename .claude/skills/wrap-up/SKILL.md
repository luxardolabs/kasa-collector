---
name: wrap-up
description: Close out a piece of work the fleet way before calling it done — tests written and run for what changed, every red in touched files fixed, docs updated (stale advice removed), make check green, committed in the issue's worktree, LuxPM fully closed out (issues, checklists, activities, commit links, sync receipt), then landed on the base branch, the worktree removed, and pushed as the repo declares. Every step reports evidence, not a tick.
---

<!-- luxarch:wrap-up-skill asset v28 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit wrap-up-skill`. -->

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

**Every step ends with its evidence**: a count, a command's output line, a commit SHA, an issue key. "Done" without the evidence is not done. A step is completed, never skipped: one that cannot be completed in this change waits on an open escalation (`/escalate`, for a defect in another repo's guard or emitted asset) or on the owner's answer to one question, and the report names it with that key.

## 1. What changed

`git status` and `git diff --stat` against where the work started. List the files and behaviours you changed. Everything below is checked against this list.

## 2. Tests: written, seen to fail, attacked, run

A green suite is evidence only for what it can see. Four bugs in one repo passed a green `make check` and failed in the real stack (an outage among them), because nothing made anyone prove a test could fail or attack the change. So:

- **Every changed behaviour has a test, and you SAW it fail.** For each fix, in your worktree: reverse the fix alone as a patch (`git diff -- <the source files you changed> > <scratch>/fix.patch && git apply -R <scratch>/fix.patch`, keeping the test), run the new or changed test, and paste its failing line; restore (`git apply <scratch>/fix.patch`), run it again, and paste the pass. Never `git stash`: the stash is shared by every worktree of the repository. A test you never saw fail is not evidence (`luxarch --doc FLEET-VERIFICATION-STANDARD`). New behaviour: run the test before the code exists, or against the parent commit.
- **Attack it (`/adversarial`)** when the change touches authentication or authorization, tenant isolation, data writes or migrations, money, secrets or personal data, deploy or release, or fixes a guard red. An independent agent that did not write the change tries to make it wrong. Every break it reproduces is fixed and committed as a test. A change outside that list may still be attacked; it may not skip this step when inside it.
- **Say what the suite cannot see.** `make test` runs the app in-process against its test stack. If the change lives where that stack does not reach (a cache or queue the test stack lacks, nginx or the server's config, an entry point other than `app.main`, the production image), probe the deployed dev stack (`make smoke` where the repo has it) and paste the result.
- Run the tests that cover what changed first, then the whole suite (`make test`).
- **Evidence:** per test, its failing line before the fix and its pass after. The `/adversarial` report's CONFIRMED and UNREPRODUCED counts (or which category put the change outside it), with every CONFIRMED finding fixed and each UNREPRODUCED one re-probed until it was confirmed and fixed or shown not a defect. Any stack probe's output. The suite's pass line.

## 3. Every red in a file you touched, and none moved

You touched it, you own it (conduct standard #11): fix every mypy, ruff and luxarch red in each changed file, not only yours, and never spend time proving one predates you. Check a file's luxarch reds with a targeted run, `luxarch --path <file>` for the per-file rules and `luxarch --rule <id> --path <file>` for each whole-tree rule that fires in the repo, never a full scan filtered through `grep`. For mypy, read `luxlint --playbook mypy-sweep` in full first. Fix by aligning the code; never `type: ignore`, `cast`, `Any`, `noqa` or an exemption.

A red can also be moved instead of fixed: the code goes to another layer, helper or consumer module, and a rule stops seeing it or another rule starts. Counting only the files you touched cannot see that. So compare the WHOLE repo. Take the base's committed status (`git show <base>:.luxarch-status.json`, and `.luxlint-status.json` the same way), run `make status` on your tree, and compare each rule's `violations` count in the two. A rule whose count rose anywhere is a red you moved: fix it in this change, or escalate it. A site that cleared because its code moved rather than changed is the same thing. A site you skipped because it is held (conduct standard, "Before you change code to clear a red") is named here with its issue key.

**Evidence:** per touched file, the red count before and after; the whole-repo per-rule delta (`<rule>: <before> → <after>` for every rule that changed); each held site you skipped, with its key.

## 4. Docs

- Update the doc that is the ONE home for what you changed (a `--doc`/`--playbook`, the repo's own docs, the changelog if the repo keeps one). Point, don't restate.
- **Search for advice your change made wrong, and delete it.** Stale instructions are how agents keep doing the old thing: grep the docs for the old command, flag, file or name.
- **Current state only.** Reread every comment, docstring, test name and doc line the diff adds (`git diff <base> -U0 | grep '^+'`). Each states what the code does now and why. Rewrite any that tells history ("used to", "no longer", "instead of", "the old…", "was green", a version that introduced it, an incident, an issue key): that goes in the commit message, the LuxPM issue and the change log (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, first principles).

**Evidence:** the doc lines changed, the grep you ran for the old advice, and the added lines you rewrote to current state (or "none tell history").

## 5. The gate, committed in the issue's worktree

- You are in the issue's worktree (`<repo parent>/.worktrees/<repo>/<ISSUE-KEY>`, or `.claude/worktrees/<ISSUE-KEY>` for one made before worktrees moved beside the repository; `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Concurrent agents: one worktree per issue"). If the work was done in the main checkout, that is the failure the standard exists to stop: say so in the report.
- `make check` green, run in the worktree. A red you could not fix stays red with an open escalation (`/escalate`), never deferred or silenced.
- **In a repo whose `.luxarch.toml` declares `[agents] land = "queue"`**, the land queue runs the full gate once for every ready branch together, on the tree that lands, so you do not run `make check` or `make status`. Run the checks for what you changed instead: one `luxarch --path <file> --path <file> …` naming every file you touched (the per-file rules, in seconds; its exit 0 clears those rules only, and the whole-tree rules it names are judged by the queue's gate), `luxarch --rule <id> --path <file>` naming those files for each whole-tree rule whose count in `.luxarch-status.json` is above 0, and the touched tests (`make test-fast PYTEST_ARGS='<files>'`).
- Commit as `luxardolabs` via the global git config (never `git -c user.email=…`), no AI attribution.

**Evidence:** the `make check` result line, the commit SHA, `git status -s` empty in the worktree.

## 6. LuxPM, closed out

- Every issue this work touched: **closed** (`luxpm_update_issue` with a `close_summary` saying what shipped), or open only while it waits on an open escalation (with every step that works already landed: an escalation holds back one site), on the owner's answer to one question, or on another declared agent of the repo it was handed to (`agent:<their role>`), with a comment naming that key, question or step. A comment is not a close. **Close when the code is done** (committed, pushed, gate green), never later: not "after the deploy", not "once I've checked prod". Deploying is the owner's step, and a check of the deployed stack follows it.
- **Checklist items** done: one `luxpm_update_checklist(sequence_id, items=[{item: <number or title>, done: true}, …])` per issue, ticking every finished item. **Activities and todos** for this work completed (`luxpm_list_activities`).
- **Work logged with its commits**, one call per issue: `luxpm_log_activity(sequence_id, kind="code_change", content=<the evidence>, commits=[{sha, committed_at}, …])` records the entry AND links the commits (use `luxpm_link_commits` only for commits that belong to no issue), every commit with its `committed_at` (`git log -1 --format=%cI <sha>`) and `files`, as `worktree.py land` prints each landed commit's JSON: without it LuxPM cannot know the commit's age, and an old sha linked as evidence becomes the sync receipt's anchor. Link this repo's commits to this repo's issues only.
- **Every finding this session raised, fixed.** Go back through the session, not just the diff: each bug, red, limit or follow-up you named in a reply ("to file", "follow-up", "out of scope", "later"), each `/adversarial` finding, each red you noticed in a file outside the change, and each owner aside. Each one takes exactly one of three routes (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Work what you find; never defer it"): **fixed in this change**, with its test seen failing then passing; **escalated** (`/escalate`) when the defect is in another repo's guard or emitted asset; or **asked of the owner**, one question, when it is genuinely the owner's call (scope, money, a delete). Never a new issue in any project, never `dropped`, never a stated limit.
- **Record each issue's release action as it closes.** Ask of every issue you close: does its work need a step or a heads-up when it is released (a secret or setting to change, a one-off script to run, a correction to the last release's notes, a breaking change for consumers to hear about)? When it does: write the step in `release-actions/<KEY>.md` at the repo's root and commit it in the worktree with the work (step 5's commit, or one after it, before the close), and close with the label `release-action` (spelled exactly so) and a line `Release: <the step>` in the close summary, one line per step. When it does not, it carries none of them. The file lands with the work, and the release that holds the work consumes it into its change log (`luxarch --doc FLEET-RELEASE-PROCESS` §3a), so nobody has to remember it. The emitted `release-action-close` hook denies a close where the file, the label and the line disagree.
- **A close summary names no unbuilt work.** It says what shipped. Work found during the close-out itself is done before the close, in this change. The emitted `no-new-follow-ups` hook denies every new issue but an escalation, a handoff to another declared agent of the repo, or work started now (`in_progress`, with a title, in this repo's project), in any project, and reopening a closed one.
- **Close on the commit and the green gate**: step 7 lands and pushes it next. If landing then fails, log an activity on the issue with the reason, fix it and land before you end the session: an agent does not reopen a closed issue.
- Re-issue the **sync receipt** (`luxpm_issue_sync_receipt`), write it verbatim to `.luxpm-receipt` in the worktree, and commit it there: it lands with the work.
- **Read the receipt you just issued.** If `open_untriaged` or `closed_without_summary` is above zero (`repo.luxpm_backlog_triaged` reds it), the backlog beyond this work needs triage: say so in your report with the counts and run `/luxpm-audit` (it works in batches; a large backlog is not a reason to skip it). This step covers only what THIS work touched.

**Evidence:** each issue key with its new state and its release action (the `Release:` step, or none); each finding the session raised with its fixing commit, or the escalation or owner question it waits on, by key; and the receipt's `issued_at`.

## 7. Land, remove the worktree, push

- **In a repo that declares `[agents] land = "queue"`:** in the worktree, `python3 .claude/hooks/worktree.py ready`, not `land`. It rebases the branch and records it as ready. The queue (`python3 .claude/hooks/worktree.py queue`, run from the main checkout by the owner or the repo's lander session) gates the batch and lands it. `python3 .claude/hooks/worktree.py queue --status` shows your branch's outcome. `landed` carries the landed commits' JSON for step 6's commit links: close the issue then. `handed-back` carries the reason and the log: fix it in this worktree and run `ready` again. `stale` means you committed after `ready`: run `ready` again. Removing the worktree, below, follows `landed`.
- In the worktree: `python3 .claude/hooks/worktree.py land`. If it rebased onto new commits (this machine's, or under `"agent"` another machine's, fetched from origin), it stops: re-run the touched tests and `make check` on the rebased code, then `land` again. A conflict stops it with nothing changed: resolve it in the worktree, re-run the gate, land.
- Pushing follows `.luxarch.toml`. `[agents] push = "agent"`: `land` pushes the tested HEAD to origin as it lands. If origin rejected it, origin moved: run `land` again, never `git pull --rebase` on the base. `push = "owner"`: `land` stays local; say the work is landed and ready. A repo with no declaration reds `repo.agent_push_declared`: ask the owner which it is, once, and write the answer there.
- `ExitWorktree` with `action: "keep"`, then from the main checkout `python3 .claude/hooks/worktree.py list --prune`: it prunes the worktree and its branch now that they are landed, clean, and locked by no one else. Not `ExitWorktree` `remove`: it judges the branch against the commit the worktree was made from, so it refuses every landed branch as unmerged work, and `discard_changes: true` is never the answer to that refusal.
- `python3 .claude/hooks/worktree.py list`: no worktree left for this issue.
- Nothing of this unit is left on the shared machine (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Shared machine"): its background shells stopped (`python3 .claude/hooks/background-shells.py --own`, read before clearing scratch, since one may be waiting on a file there), its scratch subdirectory removed, every container, image tag, compose project and volume it created removed by its exact name, nothing written outside the worktree and scratch. A claim that nothing is running comes from that command, not from memory.

**Evidence:** `land`'s `Landed and pushed N commit(s) on <base> at <sha>` line (`Landed N commit(s)` under `"owner"`), the `list` output, and `git status -sb` (nothing ahead under `"agent"`; the commits ahead named under `"owner"`), and `docker ps -a` and `docker image ls` filtered by the issue key listing nothing.

## 8. Report

Three parts, in this order:

1. **What this session worked on**, in a short paragraph or a few bullets of plain sentences for someone who was not watching:

   - what it set out to do, and why;
   - what it did and found along the way, including the decisions and owner rulings, anything that changed the plan, and dead ends worth knowing;
   - where things stand;
   - what comes next.

   Name issues by key. This is a summary of the work, not of the effort: no narrating how hard it was.

1. **The evidence:** what shipped (with the evidence above), and what waits on the owner or an escalation, by key.

1. **The compact line**, last, for the owner to paste if they choose to compact. It is an offer, never a prompt: agents never ask for a compact (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Compaction"). One line, built from this session's real state:

   ```
   /compact Keep: next <key> (<what>) in <work order key>'s order, then <keys>; owner decisions open: <keys>; running: <agents or background jobs, or none>; main at <sha> <clean|dirty>, <release state>; unresolved: <failures, by key, or none>. Drop: raw tool/LuxPM output, landed-fix details, resolved errors, file contents and anything retrievable from LuxPM or the repo.
   ```

   Every Keep entry is a pointer to something already persisted: an issue key, a commit sha or a file path. A decision, finding or failure that you cannot name that way lives only in the conversation, and the compact loses it: fix it, or log it on the issue you are working first (step 6), then name that key. The line must start with `/compact` at the very start of the prompt, or Claude Code sends it as a message instead of running it.
