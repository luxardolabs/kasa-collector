---
name: escalate
description: Escalate a fleet guard (luxarch, luxlint, luxaudit, luxios) the fleet way when a red is genuinely wrong or a guard conflicts with a standard — search LuxPM first, file a self-contained fleet-escalation in this repo's project with a repro and numbers, and leave the red lit while it is open.
---

<!-- luxarch:escalate-skill asset v7 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit escalate-skill`. -->

# Escalate a guard

Emitted from luxarch (`luxarch --emit escalate-skill`); re-emit, never hand-edit. Standard: `luxarch --doc FLEET-AGENT-CONDUCT-STANDARD` ("Align or escalate", "LuxPM: required practices").

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

## 0. Is it an escalation?

Escalate when the guard is **wrong**: a false red on correct code, a false green on broken code, two guard requirements that cannot both be met, or a remedy that does not work as written. Read the rule's `--doc` / `--playbook` in full first; the inline fix text is a summary, not the authority. If the code is wrong, it is not an escalation: fix the code.

**Escalate a SITE, never a family.** For each site you would include, write down why the rule's documented remedy cannot be applied *there*. If a remedy applies (rename a different concept, parse at the boundary, type the field, sweep the callers), it is work, and you do it, however many callers it touches. "Cascade-heavy", "risky" and "needs coordination" describe *how* to do the work carefully; they are never a reason to stop or to ask which family is next. One genuinely wrong site does not pause the rest of its family: escalate that site and keep burning the others down.

The test before filing: could the maintainer answer "apply the remedy in the fix text"? Then it is not an escalation. You answer that by **applying the remedy, not by reading it**: do the rule's documented steps in this issue's worktree and commit them. If the red clears, land it; there was nothing to escalate. A remedy that looks large, touches several services, or needs a piece of work from someone else is still the remedy: do your part.

**Work that belongs to someone else is a request to them, never an escalation.** A step the standard gives to infra (an edge map line, an upstream), to the owner (a data copy, a hold, a token), or to another repo's agent goes to them as the standard says, while you do the rest. A guard escalation says the guard is wrong; it is not how to hand off a step.

Every escalation declares its kind, on a `Kind:` line:

- `false-red`: correct code is red. `remedy-fails`: the documented remedy, applied, still reds or breaks the code. `conflict`: two guard requirements cannot both be met. Each of these says the remedy cannot work here, so you tried it: commit the attempt (in the issue's worktree, not landed) and name it on a `Remedy applied: <sha>` line.
- `false-green`: broken code the rule passes. `asset-defect`: an emitted asset, unedited, fails. `missing-rule`: a fleet concern no rule checks (FLEET-ONBOARDING-STANDARD, retiring a hand-rolled check). No remedy exists to apply, so no commit is named.

Keep the attempt until the escalation closes: `git branch escalation/<this issue's key> <sha>` before the worktree is landed or pruned, because pruning deletes the worktree's branch and the maintainer reads the commit (`git show <sha>`).

The emitted `escalation-remedy-tried` hook (`luxarch --emit hooks`) denies filing a guard escalation (a `[<guard> ESCALATION]` title, or `fleet-escalation` beside the guard's label), or rewriting its title, without its `Kind:` line, or with a remedy kind whose `Remedy applied:` commit is not in this repository, changes no file, or is already landed (on a `main` / `master` / `dev` / `develop` / `trunk` branch, local or pushed, the `init.defaultBranch`, a remote's default branch, or the main checkout's branch). Put the attempt's sha first on the `Remedy applied:` line, and write the fields in your own text (on their own lines, or inline after other fields): a field inside a code fence or a `>` quote is not read. Pushing the attempt's own branch so others can read it is fine.

## 1. Search first

`luxpm_semantic_search` with two or three phrasings (the rule id, the symptom, the guard), and `luxpm_list_issues` with `search`. If it is already filed, **comment** on that issue with your repo's evidence and stop here.

## 2. Prove it

- The exact rule id and guard version (`luxarch --version`).
- A minimal repro: the file and line, or a few lines that trigger it.
- **Numbers**: how many sites, how many are wrong, and what you checked to know (`git show`, a grep, a run with and without the change).
- `Kind:` and, for a remedy kind, `Remedy applied: <sha>` (section 0): the commit that applies the documented remedy, and what goes wrong on it.
- **Verify**: the exact command, run in this repo, that shows the defect (a targeted guard run such as `docker run … <guard image> --rule <id> --path <file>`, or the one test that fails); what it prints now (for a remedy kind, run on the `Remedy applied` commit, never on the code before the remedy); and what it will print once fixed. `/pin-bump` re-runs it on every new pin and closes the escalation when the output matches, so write it to be run as-is, with no reading between the lines.

## 3. File it in THIS repo's LuxPM project

- Title `[<guard> ESCALATION] <the defect in one line>`.
- Label **`fleet-escalation`**. An unlabelled escalation is missed by the maintainer's sweep.
- `waiting_on: <guard> maintainer`. The maintainer replaces it with your next step when they answer, and `/fleet-start` shows you every escalation whose `waiting_on` names you.
- Self-contained: the maintainer reads it cold, so include the repro, numbers, evidence and **Verify** block above, a suggested fix if you have one, and what this repo did meanwhile.
- **Never a GitHub issue.** There is no fallback.

## 4. Leave the red lit

The red stays red while the escalation is open: no `[rules.deferred]`, no allowlist, no `noqa`, no local config, no false attestation. A lit red is honest; a silenced one is a lie someone inherits. Say in the issue that you are holding it red.

**Evidence to report:** the issue key, and the red left lit.
