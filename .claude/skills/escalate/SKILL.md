---
name: escalate
description: Escalate a fleet guard (luxarch, luxlint, luxaudit) the fleet way when a red is genuinely wrong or a guard conflicts with a standard — search LuxPM first, file a self-contained fleet-escalation in this repo's project with a repro and numbers, and leave the red lit while it is open.
---

<!-- luxarch:escalate-skill asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit escalate-skill`. -->

# Escalate a guard

Emitted from luxarch (`luxarch --emit escalate-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` ("Align or escalate", "LuxPM: required practices").

## 0. Is it an escalation?

Escalate when the guard is **wrong**: a false red on correct code, a false green on broken code, two guard requirements that cannot both be met, or a remedy that does not work as written. Read the rule's `--doc` / `--playbook` in full first; the inline fix text is a summary, not the authority. If the code is wrong, it is not an escalation: fix the code.

## 1. Search first

`luxpm_semantic_search` with two or three phrasings (the rule id, the symptom, the guard), and `luxpm_list_issues` with `search`. If it is already filed, **comment** on that issue with your repo's evidence and stop here.

## 2. Prove it

- The exact rule id and guard version (`luxarch --version`).
- A minimal repro: the file and line, or a few lines that trigger it.
- **Numbers**: how many sites, how many are wrong, and what you checked to know (`git show`, a grep, a run with and without the change).
- What you tried, and why the documented remedy does not work here.

## 3. File it in THIS repo's LuxPM project

- Title `[<guard> ESCALATION] <the defect in one line>`.
- Label **`fleet-escalation`**. An unlabelled escalation is missed by the maintainer's sweep.
- Self-contained: the maintainer reads it cold, so include the repro, numbers and evidence above, a suggested fix if you have one, and what this repo did meanwhile.
- **Never a GitHub issue.** There is no fallback.

## 4. Leave the red lit

The red stays red while the escalation is open: no `[rules.deferred]`, no allowlist, no `noqa`, no local config, no false attestation. A lit red is honest; a silenced one is a lie someone inherits. Say in the issue that you are holding it red.

**Evidence to report:** the issue key, and the red left lit.
