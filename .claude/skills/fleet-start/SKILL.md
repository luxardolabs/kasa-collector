---
name: fleet-start
description: Start (or resume after a compact) a working session the fleet way — read this repo's CLAUDE.md and the conduct standard, rehydrate from LuxPM leanly (focus + this repo's open issues, keys and titles only), and restate the six session rules. Run at the start of every session and after every compact.
---

<!-- luxarch:fleet-start-skill asset v3 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit fleet-start-skill`. -->

# Fleet start

The start-of-session routine for this repo. Emitted from luxarch (`luxarch --emit fleet-start-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`. This skill points at it and restates nothing but the six rules below.

**In an iOS repo** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

LuxPM is the state. The conversation is not a second copy of it: rehydrate from LuxPM, and persist decisions back to it as they are made, so a compact at any moment loses nothing.

## 1. Read the instructions

- This repo's `CLAUDE.md` (or `AGENTS.md`), in full.
- `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, in full on the first session in this repo. After a compact, re-read its "LuxPM: working habits", "Compaction" and "Subagent model tiering" sections.

## 2. Rehydrate from LuxPM, lean

- `luxpm_get_focus`.
- This repo's open issues: `luxpm_list_issues` with this project's `project_id` and `state` (`in_progress` first, then `todo`), a small `limit`. Keep **keys and titles** in mind; do not quote the payload back.
- `luxpm_get_context` **only** for the issue you are about to work. Nothing else until it is needed.

**Evidence:** one line: what is in progress, and what you are picking up.

## 3. The six session rules

1. **Ask or do, by the class of action**, never by how confident you feel. Ask: deleting, changing scope, a deferral/allowlist/exemption, publishing outward, a genuine product fork. Do: aligning to a ratified standard or a guard red, anything evidenced and reversible in one commit.
1. **One decision per question, with your recommendation stated as one.** No menu after a recommendation.
1. **Hold the recommendation.** A "why?" is a question, not an objection: answer it with the evidence, and change your answer only on new evidence.
1. **Report the result, not the effort.** Done + next, in one line, with numbers.
1. **Evidence over memory.** Cite the file and line, the command output, the issue. "Done" is a check you ran this turn.
1. **Reds stay red.** Align the code or escalate the guard (`/escalate`). Never an exemption, a suppression comment, a deferral or a local config.

## 4. Compaction (the owner runs it)

The owner runs `/compact`; agents never prompt for it. Your part is to keep decisions persisted to LuxPM as they are made. The standard focus text, for the owner to copy:

> Keep: current task and where we are, open hypotheses, decisions not yet in LuxPM, files in play, unresolved failures. Drop: raw tool/LuxPM output, resolved errors, file contents and anything retrievable from LuxPM or the repo.

After a compact, run `/fleet-start` again.

## 5. The other fleet skills

`/wrap-up` before calling anything done. `/adversarial` to attack a risky change before that. `/pin-bump` to upgrade the guards. `/escalate` when a guard is wrong. `/luxpm-audit` to triage the whole backlog. `/release` to cut a release.
