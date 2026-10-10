---
name: luxpm-audit
description: Audit this repo's whole LuxPM project, not just the issues the current work touched — verify every open issue against the code and close, park, merge or comment on it with evidence, backfill a close summary on every closed issue that lacks one, then re-issue the sync receipt. Use when the receipt shows untriaged or unexplained issues, when repo.luxpm_backlog_triaged is red, or when asked to review/clean up/audit LuxPM.
---

<!-- luxarch:luxpm-audit-skill asset v6 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit luxpm-audit-skill`. -->

# Audit the LuxPM backlog

Emitted from luxarch (`luxarch --emit luxpm-audit-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` ("LuxPM: required practices") and `luxarch --playbook luxpm-currency`.

**In an iOS repo** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

`/wrap-up` closes the issues ONE piece of work touched. This is the other half: the whole project. A tracker nobody audits fills with issues that shipped months ago, issues nobody will do, and closes nobody can explain. Each looks like open work to the next agent and the owner.

**The goal is an accurate tracker, not a small number.** Closing a live issue to move a count is a false attestation; so is a summary that says nothing. If you cannot verify an issue either way, it stays open with a comment saying what you checked.

## 0. Scope and baseline

- This repo's project only: the `project:` line of `.luxpm-receipt` (re-issue it first with `luxpm_issue_sync_receipt` if it is stale). Never edit another project's issues.
- Record the receipt's counts as the baseline: `open`, `open_untriaged` (open with no state change or comment for `stale_days`; a parked issue counts after 4 x `stale_days`), `closed_without_summary`. What resets an issue's clock is a state change or a comment/activity, never a label, priority or description edit or a commit link; that is why only real triage moves the count.
- List every open issue: `luxpm_list_issues` for this project, paging until exhausted, every non-terminal state (`backlog`, `todo`, `in_progress`, `on_hold`). Do not filter by label or age — the audit is the whole list.
- **More than ~25 open issues: work in batches of 25** and report after each batch (counts per outcome). Continue until done; a backlog of 300 is 12 batches, not a reason to sample.
- **Read lean.** The listing is keys, titles and states; do not quote it back. `luxpm_get_context` one issue at a time, when you judge it.
- **Subagents, if you use them, name the tier** (`--doc FLEET-AGENT-CONDUCT-STANDARD`, "Subagent model tiering"): listing, paging and `git log` lookups on **Sonnet**; the verify-and-decide judgment in step 1 on the main session's model. A close or cancel is acted on without re-checking, so it is judgment work.

## 1. Each open issue: verify, then decide

Read it fully (`luxpm_get_context`: description, comments, linked commits). Then check the claim **against the code**, not the issue text: `git log --grep <KEY>`, `git log -S <symbol>`, read the file it names, run the test or command it describes. Exactly one outcome:

| Finding                                                                                | Action                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Shipped** — the code does what the issue asked, and you verified it                  | `state: done` with a `close_summary`: what shipped, the commit SHA(s), and how you verified it (test name, command output, file:line). Link the commits (`luxpm_link_commits`), each with its `committed_at` (`git log -1 --format=%cI <sha>`): an old commit linked as evidence without it becomes the sync receipt's anchor.                                              |
| **Partly shipped**                                                                     | Leave open. Comment: what is done (with SHAs), what remains, the next concrete step. Update `progress_percentage`.                                                                                                                                                                                                                                                          |
| **Superseded / duplicate**                                                             | Search (`luxpm_semantic_search`, two phrasings) for the survivor **in this project** (a match in another project is a relationship to note in a comment here, never an edit there). `state: cancelled`, `close_summary` naming the survivor's key and why; `luxpm_add_relationship` (duplicates/superseded by); comment on the survivor if this one held evidence it lacks. |
| **No longer wanted / obsolete** (the feature was removed, the premise no longer holds) | `state: cancelled`, `close_summary` with the evidence (the commit that removed it, the file that no longer exists). Not "no longer relevant" alone.                                                                                                                                                                                                                         |
| **Live, blocked on a person or an external event**                                     | `state: on_hold` with `waiting_on: <who/what>`, plus a comment saying what unblocks it.                                                                                                                                                                                                                                                                                     |
| **Live and actionable**                                                                | Leave it in `backlog`/`todo`. Comment with what you checked and the next concrete step (file, function, test). A bare "still relevant" is not triage.                                                                                                                                                                                                                       |
| **Cannot verify either way**                                                           | Leave open. Comment: what you checked and what would settle it.                                                                                                                                                                                                                                                                                                             |

**Escalations are not yours to close.** An issue labelled `fleet-escalation` / `escalation`, or titled `[<guard> ESCALATION]`, is waiting on the guard maintainer; it closes when the maintainer's fix ships. Park it: `state: on_hold`, `waiting_on: <guard> maintainer`. If your pinned guard version already contains the fix (`luxarch --changelog --since <version>`), also comment that with the evidence, so the maintainer can close it. Its red stays lit while it is open.

**Never** delete an issue (deleting is the owner's call — ask), use `administrative_close`, close in bulk without reading each one, bulk-edit fields to reset issues' clocks (a label or priority touched on every issue is not triage, it is gaming the count), or write a summary you did not verify.

## 2. Closed issues with no summary

For each `done`/`cancelled` issue in this project with a blank `close_summary` (list closed issues and read the field): reconstruct what happened from its linked commits, comments and activities, and `git log --grep <KEY>`. Write a `close_summary` (`luxpm_update_issue` with only `close_summary` — the state stays) that says what was done or why it was dropped, and where the evidence is. If nothing can be found, say so honestly: "Closed before summaries were required; no linked commit, comment or code reference found (checked: …)". That is an explanation; an empty field is not.

## 3. Checklists and activities

For each issue you closed: tick its checklist items that are actually done (one `luxpm_update_checklist(sequence_id, items=[{item: <number or title>, done: true}, …])` per issue), and complete its open activities/todos (`luxpm_list_activities`). An open checklist on a closed issue reads as unfinished work.

## 4. Re-issue the receipt and report

- `luxpm_issue_sync_receipt` for this project, written VERBATIM to `.luxpm-receipt`, committed (push only as this repo's CLAUDE.md and `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` allow). Editing any byte invalidates it.
- Report, with numbers: baseline vs new receipt counts; per outcome (closed-shipped, cancelled, on_hold, commented-live, unverifiable, escalations left open); summaries backfilled; the issue keys of anything you want the owner to decide (a deletion, a scope question).

**Evidence to report:** before/after receipt counts, a per-outcome count with issue keys, and the receipt commit SHA.
