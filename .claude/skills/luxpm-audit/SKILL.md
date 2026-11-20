---
name: luxpm-audit
description: Audit this repo's whole LuxPM project, not just the issues the current work touched — verify every open issue against the code and close, park, merge or comment on it with evidence, backfill a close summary on every closed issue that lacks one, recover work a closed summary deferred without tracking it, then re-issue the sync receipt. Use when the receipt shows untriaged or unexplained issues, when repo.luxpm_backlog_triaged is red, or when asked to review/clean up/audit LuxPM.
---

<!-- luxarch:luxpm-audit-skill asset v12 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit luxpm-audit-skill`. -->

# Audit the LuxPM backlog

Emitted from luxarch (`luxarch --emit luxpm-audit-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` ("LuxPM: required practices") and `luxarch --playbook luxpm-currency`.

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

`/wrap-up` closes the issues ONE piece of work touched. This is the other half: the whole project. A tracker nobody audits fills with issues that shipped months ago, issues nobody will do, and closes nobody can explain. Each looks like open work to the next agent and the owner.

**The goal is an accurate tracker, not a small number.** Closing a live issue to move a count is a false attestation; so is a summary that says nothing. An issue you cannot yet verify either way is settled by running what decides it, never left open with a comment.

## 0. Scope and baseline

- This repo's project only: the `project:` line of `.luxpm-receipt` (re-issue it first with `luxpm_issue_sync_receipt` if it is stale). Never edit another project's issues.
- Record the receipt's counts as the baseline: `open`, `open_untriaged` (open with no state change or comment for `stale_days`; a parked issue counts after 4 x `stale_days`), `closed_without_summary`. What resets an issue's clock is a state change or a comment/activity, never a label, priority or description edit or a commit link; that is why only real triage moves the count.
- List every open issue: `luxpm_list_issues` for this project, paging until exhausted, every non-terminal state (`backlog`, `todo`, `in_progress`, `on_hold`). Do not filter by label or age — the audit is the whole list.
- **More than ~25 open issues: work in batches of 25** and report after each batch (counts per outcome). Continue until done; a backlog of 300 is 12 batches, not a reason to sample.
- **Read lean.** The listing is keys, titles and states; do not quote it back. `luxpm_get_context` one issue at a time, when you judge it.
- **Subagents, if you use them, name the tier** (`--doc FLEET-AGENT-CONDUCT-STANDARD`, "Subagent model tiering"): listing, paging and `git log` lookups on **Sonnet**; the verify-and-decide judgment in step 1 on the main session's model. A close or cancel is acted on without re-checking, so it is judgment work.

## 1. Each open issue: verify, then decide

Read it fully (`luxpm_get_context`: description, comments, linked commits). Then check the claim **against the code**, not the issue text: `git log --grep <KEY>`, `git log -S <symbol>`, read the file it names, run the test or command it describes. Exactly one outcome:

| Finding                                                                                | Action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Shipped** — the code does what the issue asked, and you verified it                  | `state: done` with a `close_summary`: what shipped, the commit SHA(s), and how you verified it (test name, command output, file:line). Link the commits (`luxpm_link_commits`), each with its `committed_at` (`git log -1 --format=%cI <sha>`): an old commit linked as evidence without it becomes the sync receipt's anchor.                                                                                                                                                                                                                |
| **Partly shipped**                                                                     | Do the remainder now, with its test, then close it as shipped. When the remainder is a scope call (it may lie outside the scope the owner set), ask the owner one question, set `on_hold` with `waiting_on: "owner: <the question?>"` and comment what is done (with SHAs) and what remains.                                                                                                                                                                                                                                                  |
| **Superseded / duplicate**                                                             | Search (`luxpm_semantic_search`, two phrasings) for the survivor **in this project** (a match in another project is a relationship to note in a comment here, never an edit there). Comment on the survivor if this one held evidence it lacks, and `luxpm_add_relationship` (duplicates/superseded by). A cancel is the owner's call: ask the owner one question ("cancel <KEY> as superseded by <SURVIVOR>?") and set `on_hold` with `waiting_on: "owner: <the question?>"`; the emitted `no-self-park` hook denies an agent's `cancelled`. |
| **No longer wanted / obsolete** (the feature was removed, the premise no longer holds) | Comment with the evidence (the commit that removed it, the file that no longer exists). A cancel is the owner's call: ask the owner one question and set `on_hold` with `waiting_on: "owner: <the question?>"`. Never `cancelled` by an agent.                                                                                                                                                                                                                                                                                                |
| **Live, blocked on a person or an external event**                                     | Blocked on the owner: `state: on_hold` with `waiting_on: "owner: <the question?>"`, the only park an agent sets. Blocked on another repo's agent, a guard maintainer or an upstream release: it keeps its open state (`todo`) with a comment saying what unblocks it; it is never set `on_hold` or `backlog` by an agent, and its `waiting_on` names no one but the owner (an escalation's is set as below). When the work cannot go on without that party, ask the owner one question naming it.                                             |
| **Live and actionable**                                                                | It is this repo's work: it keeps its state (`backlog`/`todo`) and is worked in `/fleet-start` order, never parked. Comment with what you checked and the next concrete step (file, function, test). A bare "still relevant" is not triage.                                                                                                                                                                                                                                                                                                    |
| **Cannot verify either way**                                                           | Settle it: run the test or command that decides it, then take the matching row. Only when the owner alone can settle it, ask one question and set `on_hold` with `waiting_on: "owner: <the question?>"`, commenting what you checked.                                                                                                                                                                                                                                                                                                         |

**An escalation is read by its `waiting_on`.** An issue labelled `fleet-escalation` / `escalation`, or titled `[<guard> ESCALATION]`, waits on whoever its `waiting_on` names. In a repo's own project, one it filed against another guard waits on that guard: it stays open (`todo`) with `waiting_on: "<guard> maintainer: <what it waits for>"`, never set `on_hold` or `backlog`. In a guard's own project (LUXARCH, LUXLINT, LUXAUDIT, LUXIOS) an escalation relayed there (`[<KEY>] …`, `escalation-from-<project>`) is that maintainer's own work, worked in the work order, never parked: its `waiting_on` says where it is queued (`<guard> maintainer: <work-order key and section>`), as `/escalation-triage` sets it. If it names this repo's step, the maintainer has answered: do that step as `/pin-bump` step 5 says, and close the escalation once the step verifies on the version it names. Its red stays lit while it is open.

**Never** delete an issue (deleting is the owner's call — ask), use `administrative_close`, close in bulk without reading each one, bulk-edit fields to reset issues' clocks (a label or priority touched on every issue is not triage, it is gaming the count), or write a summary you did not verify.

## 2. Closed issues: no summary, or deferred work nobody tracks

For each `done`/`cancelled` issue in this project with a blank `close_summary` (list closed issues and read the field): reconstruct what happened from its linked commits, comments and activities, and `git log --grep <KEY>`. Write a `close_summary` (`luxpm_update_issue` with only `close_summary` — the state stays) that says what was done, or why it was cancelled (the owner's ruling, in the owner's words: a summary written onto an issue the owner cancelled records that ruling, and the close hook does not read it for slots), and where the evidence is. If nothing can be found, say so honestly: "Closed before summaries were required; no linked commit, comment or code reference found (checked: …)". That is an explanation; an empty field is not.

**Then read every closed summary for deferred work.** A closed issue is in no open list, so "Not built: X" or "Stated limit: Y" written only into its summary is tracked by nothing. Collect each closed issue's full summary (`luxpm_list_issues` with `state` `done`, then `cancelled`, `verbose: true`, paging until exhausted) into a JSON object `{"<KEY>": "<close summary>", …}` in your scratch directory, and run the emitted hook's checker over it:

```sh
python3 .claude/hooks/luxpm-close-tracks-deferrals.py --scan <scratch>/closed.json
```

It prints each sentence of prose that reads like an untracked deferral, as `<KEY>: <sentence>`. This is the prose backstop: the close hook itself holds only labelled slots (`Not built:`, `Deferred:`, `Follow-up:` and the rest), so a deferral written as prose reaches you here. Each hit is for you to judge one by one, never an automatic denial: many are sentences that defer nothing. For each one:

- **Read it in context.** A sentence about the ticket itself ("left open for two weeks") defers nothing: note it and move on.
- **Check the code.** Work done since (`git log -S <symbol>`, the file it names) needs no issue.
- **Search LuxPM** (`luxpm_semantic_search`, two phrasings). Work an open issue already covers gets a comment there naming the closed key.
- **Work the rest now** (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Work what you find; never defer it"): build what it deferred, with its test, in the change of the issue you are working (an agent neither reopens a closed issue nor files a new one; the emitted `no-new-follow-ups` hook denies both), and log an activity on the closed issue naming the commit that built it. When the deferred work is a scope call, ask the owner one question, and park the issue you are working `on_hold` with `waiting_on: "owner: <the question?>"` until the answer.

A summary that ends mid-word, usually at 1000 characters and often on `...`, was stored cut off, and its original tail is gone. For each one:

- **Now: read the issue's activity log, its commits and the changelog** for a follow-up the lost tail may have named. Work what nothing tracks, as above.
- **Rebuild the tail** from the activity log and commits (`luxpm_update_issue` with only `close_summary`, the state unchanged).
- **A rebuilt tail is marked as such:** end the stored text, then `Reconstructed <date> from the activity log and commits; the original tail was lost.`, then what you rebuilt. It is a reconstruction, never a recovery. A deferral you find in it is worked like any other. A stored slot whose work has since shipped keeps its words and gains the commit at its end, `(built in <sha>)` (the hook passes it when the sha is a commit of the checkout); one whose work has not shipped is worked first.
- **Never reword a true sentence to get past the hook, and never leave a deferral out because the hook would object.** A denial you believe is wrong goes to `/escalate`, and that summary stays as stored.

## 3. Checklists and activities

For each issue you closed: tick its checklist items that are actually done (one `luxpm_update_checklist(sequence_id, items=[{item: <number or title>, done: true}, …])` per issue), and complete its open activities/todos (`luxpm_list_activities`). An open checklist on a closed issue reads as unfinished work.

## 4. Re-issue the receipt and report

- `luxpm_issue_sync_receipt` for this project, written VERBATIM to `.luxpm-receipt`, committed (push only as this repo's CLAUDE.md and `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` allow). Editing any byte invalidates it.
- Report, with numbers: baseline vs new receipt counts; per outcome (closed-shipped, on_hold on an owner question, commented-live, escalations left open); summaries backfilled; the issue keys of anything you asked the owner to decide (a cancel, a deletion, a scope question).

**Evidence to report:** before/after receipt counts, a per-outcome count with issue keys, and the receipt commit SHA.
