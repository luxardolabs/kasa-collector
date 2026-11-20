---
name: fleet-start
description: Start (or resume after a compact) a working session the fleet way — read this repo's CLAUDE.md and the conduct standard, rehydrate from LuxPM leanly (focus + this repo's open issues, keys and titles only), and restate the seven session rules, then confirm readiness (name, owner order, next step) and wait for the go-ahead unless the owner gave a note. Run at the start of every session and after every compact.
---

<!-- luxarch:fleet-start-skill asset v17 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit fleet-start-skill`. -->

# Fleet start

The start-of-session routine for this repo. Emitted from luxarch (`luxarch --emit fleet-start-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`. This skill points at it and restates nothing but the seven rules below.

**`luxarch …` is a Docker image, not a host command.** Run `luxarch --doc X` as `docker run --rm -v <checkout>:/repo -w /repo <image> --doc X`, where `<checkout>` is the absolute path of the checkout you are in, written out (your issue's worktree when you are in one: inside a worktree Claude Code refuses a mount computed at run time, such as `"$PWD"`), and `<image>` is the Makefile's pinned `LUXARCH` image (set from `LUXARCH_VERSION`). There is no host install. `luxlint …` and `luxaudit …` are the same, with `LUXLINT` and `LUXAUDIT`.

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

LuxPM is the state. The conversation is not a second copy of it: rehydrate from LuxPM, and persist decisions back to it as they are made, so a compact at any moment loses nothing.

## 1. Read the instructions

- This repo's `CLAUDE.md` (or `AGENTS.md`), in full.
- `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, in full on the first session in this repo. After a compact, re-read its "LuxPM: working habits", "Compaction" and "Subagent model tiering" sections.

## 2. Rehydrate from LuxPM, lean

- **Your owner order, first.** The owner names each agent for its job, `[<repo> <role>]` (`[shop mypy]`). When `/fleet-start` runs, and after every compact, the emitted `fleet-start-after-compact` hook names you, your role and the exact query: `luxpm_list_issues` with `project` set to this repo's project code and `labels` `owner-order` plus `agent:<role>`, then `labels` `owner-order` alone (orders for every agent here). An owner order is the owner's own: an issue the OWNER labelled `owner-order`, or a `/fleet-start <note>` the owner typed, which the hook prints back verbatim at each `/fleet-start` and after each compact. An open owner order is your work. It comes before the open issues, the guard reds and every queue below: only work that blocks other agents right now interrupts it, and you say so when it does. You never add or remove the `owner-order` label, and you park nothing: an agent sets `todo`, `in_progress`, `done`, or, blocked on the owner's call, `on_hold` with `waiting_on: "owner: <the question?>"`.
- **Then the work another agent of this repo handed you.** In a repo whose `.luxarch.toml` declares `[agents] roles`, `luxpm_list_issues` with `project` set to this repo's project and `labels` `agent:<your role>`, every open one, backlog included (skip `done` and `cancelled`, and skip one that also carries `owner-order`: that is an owner order, listed above, whose labels are the owner's): a request, or a reply you owe. Each comes before your own queue: do the step, then hand it back (`agent:<asker's role>` in place of yours, `waiting_on: "<asker's role> agent: …"`) or close it with `waiting_on` cleared and your label dropped. A close hands nothing off. To hand work to another agent: an issue in this repo's project labelled `agent:<their role>`, `state: todo`, `waiting_on: "<their role> agent: <the step>"` (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Handing work to another agent of this repo").
- **A note on `/fleet-start` is an owner order.** When the owner ran `/fleet-start <note>` (the whole message is the command and its note), record the note verbatim as an activity (`luxpm_log_activity`) on the issue you work it in, before any other work. When the note names work no open issue covers, file that issue yourself: search first (`luxpm_list_issues` with `search` set to the note's words), then `luxpm_create_issue` with `project` set to this repo's project, `state: in_progress`, no `waiting_on`, and the note quoted in its description (the emitted `no-new-follow-ups` hook allows exactly that create), then enter its worktree and start. Never ask the owner to file an issue, and never add the `owner-order` label: it is the owner's. The same goes for any work you start now that no open issue covers, a pin bump `guard-version-check` reports among them. A tag pasted inside a longer message is no command.
- `luxpm_get_focus`.
- This repo's open issues: `luxpm_list_issues` with `project` set to this repo's project code and `state` (`in_progress` first, then `todo`), a small `limit`. Keep **keys and titles** in mind; do not quote the payload back.
- This repo's open guard escalations: `luxpm_list_issues` with `project` set to this repo's project code and `labels` `fleet-escalation`, with no state and no date filter (skip `done` and `cancelled`). Read each one's `waiting_on`. One that names no guard maintainer (`luxarch maintainer`, `luxlint maintainer`, `luxaudit maintainer`, `luxios maintainer`) is waiting on you: the maintainer answered and named your step. Work those first, as `/pin-bump` step 5 says, and set `waiting_on` when you reply (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "LuxPM: required practices").
- `luxpm_get_context` **only** for the issue you are about to work. Nothing else until it is needed.

**Evidence:** one line: your owner order (key, or "none open"), what is in progress, the escalations waiting on you (keys, or "none"), and what you are picking up.

## 3. Worktrees: inventory, prune, enter yours

Every agent works in its issue's worktree; the main checkout is the owner's (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Concurrent agents: one worktree per issue").

- From the main checkout: `python3 .claude/hooks/worktree.py list`, and once the owner has said go (step 7), `python3 .claude/hooks/worktree.py list --prune`. `--prune` removes each worktree that is clean, fully merged and has no live session, and lists the rest with each one's session: `LIVE` or `locked by a live session` (a `claude` works there, or the lock's pid and start time are a running claude), or `gone` (the machine rebooted under it, or it exited).
- **An `ADOPT` line is yours, first after the go-ahead.** A session that died (a reboot, a lost connection) left that worktree's work mid-issue, and you are its successor: the owner starts every session in the main checkout and never goes looking for the old one. Run the line's steps in order: `python3 .claude/hooks/worktree.py adopt <ISSUE-KEY>` (it claims the worktree's lock for you; two sessions never adopt the same one), `EnterWorktree` with `name` = the issue key the line names (never `path=`: outside `.claude/worktrees/` it stalls for minutes, while `name=` re-enters the same worktree at once), then rehydrate from the issue's last LuxPM note, the end of the dead session's transcript, and its scratchpad, all named on the line. Then carry on where it stopped. Never start that issue afresh beside it, and never hand the owner the `claude --resume` fallback instead of adopting. With several ADOPT lines, adopt the first; the owner's other sessions take the rest.
- A worktree with a live session is that agent's: name it to the owner in one line (issue, branch, state). Removing any worktree holding work is a delete, the owner's call.
- Before your first write (and after the go-ahead, step 7): `EnterWorktree` with `name` = the issue key. The worktree hook creates it beside the repository, at `<repo parent>/.worktrees/<repo>/<ISSUE-KEY>`, never inside it (a worktree inside the checkout puts its copy of every skill in the session's skill list). For one you adopted, the same: `EnterWorktree` with `name` = its issue key. A worktree still under `.claude/worktrees/` was made before the move: work it there and land it as usual.
- After a compact you have forgotten what you started: `python3 .claude/hooks/background-shells.py --own` lists this session's background shells. Stop any whose work is done.
- The machine is shared with every other agent: per-unit scratch, docker names carrying the issue key, no fixed host ports, no writes outside your worktree and scratch, at most three heavy jobs at once, deploys from the main checkout (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Shared machine").
- Know who pushes: `[agents] push` in `.luxarch.toml` (`"agent"`: you push when the issue lands; `"owner"`: you stop at the landed commit).

**Evidence:** the `list --prune` summary line (`N pruned, M kept, K holding unmerged or uncommitted work, A with no live session to adopt`), the `adopt` result when there was one, and the worktree you entered.

## 4. The seven session rules

1. **Ask or do, by the class of action**, never by how confident you feel. Ask: deleting, changing scope, a deferral/allowlist/exemption, publishing outward, a genuine product fork. Do: aligning to a ratified standard or a guard red, anything evidenced and reversible in one commit.
1. **One decision per question, with your recommendation stated as one.** No menu after a recommendation.
1. **Hold the recommendation.** A "why?" is a question, not an objection: answer it with the evidence, and change your answer only on new evidence.
1. **Report the result, not the effort.** Done + next, in one line, with numbers.
1. **Evidence over memory.** Cite the file and line, the command output, the issue. "Done" is a check you ran this turn.
1. **Reds stay red.** Align the code or escalate the guard (`/escalate`). Never an exemption, a suppression comment, a deferral or a local config.
1. **Work what you find.** A finding in the work at hand is fixed in that change, with its test: never a follow-up issue, `dropped`, a stated limit or a self-parked `on_hold`. The only other routes are `/escalate` for a defect in another repo's guard or emitted asset, and one question to the owner (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Work what you find; never defer it").

## 5. Compaction

Agents never prompt for a compact. The owner runs `/compact`, and Claude Code also compacts on its own when the context fills. Nothing can run before a compact, so your part is to keep decisions persisted to LuxPM as they are made. The standard focus text, for the owner to copy:

> Keep: current task and where we are, open hypotheses, decisions not yet in LuxPM, files in play, unresolved failures. Drop: raw tool/LuxPM output, resolved errors, file contents and anything retrievable from LuxPM or the repo.

After a compact, run `/fleet-start` again. The emitted `fleet-start-after-compact` hook (`luxarch --emit hooks`) says so in the context the compact leaves.

## 6. The other fleet skills

`/wrap-up` before calling anything done. `/adversarial` to attack a risky change before that. `/pin-bump` to upgrade the guards. `/escalate` when a guard is wrong. `/luxpm-audit` to triage the whole backlog. `/release` to cut a release.

## 7. Ready: wait for the go-ahead, unless the owner left a note

This step is for a `/fleet-start` the owner typed. After an automatic compact (the hook's context says the session was just compacted, and you ran `/fleet-start` yourself) you already had the go-ahead: state the three lines below and carry on with your owner order without waiting.

Every time the owner types `/fleet-start` with no note (a new session, after a manual compact, at any point), end the turn with these three lines and wait for the owner:

- **Agent:** your name and role, or "unnamed: name this session, or give me a note".
- **Owner order:** its key and title, or "none open".
- **Next step:** the one thing you will do first, with its key.

Until the owner's next message, only read: adopt no worktree, enter none, change nothing, run no gate and ask no AskUserQuestion (the three lines are the question). The emitted `fleet-start-gate` hook allows only reading until then (Read, Grep, Glob, the LuxPM reads, `git status`/`log`/`diff`/`show`, `worktree.py list`, `command -v`, and a guard's docs as `docker run --rm -v <checkout>:/repo -w /repo <image> --doc X` with `<image>` the Makefile's pinned `LUXARCH`, `LUXLINT` or `LUXAUDIT`, from the fleet registry or, on an airgapped machine, `luxarch:<version>` as the tarball loaded it), and the owner's next message, whatever it says, ends the wait, a slash command they type among them; a task notification or a system reminder is not one. An `ADOPT` line (step 3) is your next step: name it on the **Next step** line, and adopt it, enter its worktree and rehydrate after that message. With a note, the note is the go-ahead: record it (step 2), state the same three lines, and start.
