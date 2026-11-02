---
name: adversarial
description: Attack a change before calling it done — an independent agent that did not write the change tries to make it wrong (security, tenant isolation, data integrity, money, the real stack), reproduces each break as a failing test or a probe, and the author fixes every confirmed break and commits the test. Run it from /wrap-up for any change touching auth, tenancy, data writes or migrations, money, secrets or personal data, deploys, or a guard-red fix.
---

<!-- luxarch:adversarial-skill asset v4 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit adversarial-skill`. -->

# Adversarial pass

Emitted from luxarch (`luxarch --emit adversarial-skill`); re-emit, never hand-edit. The standard is `luxarch --doc FLEET-ADVERSARIAL-TESTING-STANDARD`; this is the procedure. The fleet's guard maintainer runs this same pass on every rule before a release, and it finds a real defect almost every time. The author of a change is the person least able to see how it fails, which is why the attacker must be someone else.

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

## 1. Scope the change

`git diff --stat <base>..HEAD` (the base is where this work started). List each changed **behaviour** in one line: what it now does, for whom, with what input. That list is the attack surface.

## 2. Spawn the attacker

Use the Agent tool with a **general-purpose** agent, on the strongest model (the session's own; never a cheaper tier for this). Run it in the background if you have other work. For a change to authentication, authorization, tenant isolation or money, spawn **two** attackers in parallel that share nothing; act on the union of their findings, and record how many each found and how many they shared. The prompt, filled in:

```
You are attacking a change in <repo> that you did not write. Your job is to make it WRONG.

THE CHANGE: <base>..HEAD (`git diff <base>..HEAD`). Changed behaviours:
<the list from step 1>

For each behaviour, ask how a realistic input, state or environment makes it do the wrong thing, and
REPRODUCE it. Attack in this order:
1. security: another user's or tenant's data, an unauthenticated path, a forged header or Host, an
   injection, a secret or personal data reaching a log or a response;
2. data integrity: a partial write, a missing transaction, a race, dirty or legacy rows the test DB
   does not have (nulls, orphans, soft-deleted parents, duplicates);
3. money and irreversible actions: a double charge, a retry, a webhook replayed or out of order;
4. the real stack: a service the test stack does not run (cache, queue, proxy), the production image,
   a standalone entry point that skips app.main's imports, a config default that differs in prod;
5. everything else in the behaviour list.

EVIDENCE BAR: a finding counts only when reproduced, as a failing test committed nowhere yet (write it
under <scratch dir>) or as a probe against the dev stack with its output. Show a control that passes,
so the failure is the change's, not the harness's. A suspicion you tried and could not reproduce is
UNREPRODUCED, with why. One you could not try (the run errored or timed out, a service or harness you
could not set up) is INCONCLUSIVE, with what stopped you: never report it as clean.

CONSTRAINTS: read-only on the repo except files under <scratch dir>; no commits, pushes or tracker
writes; never touch production.

REPORT: a table of CONFIRMED findings, most severe first: behaviour, what goes wrong, the reproducing
test or probe, the one-line fix. Then INCONCLUSIVE ones with what stopped you. Then UNREPRODUCED ones
with the reason. Then what you did not attack.
```

In a re-attack round (step 4), add to the prompt: `ALREADY FOUND AND FIXED (do not re-report these shapes): <one line per earlier finding>. Attack the fixes themselves and anything they made reachable.`

## 3. Act on the report

- **Merge duplicates first.** Two findings with the same reproduction and the same failing line are one finding, whatever their titles say: fix and test it once.
- **Every CONFIRMED finding is fixed in this work**, and its reproducing test is moved into the suite and committed. Run it against the code without the fix first and record its failing line (`/wrap-up` step 2).
- A finding whose fix needs the owner (scope, money, data semantics) gets an issue in LuxPM. The red stays red until it is decided.
- A finding in a fleet guard or emitted asset is a `/escalate`, not a local fix.
- **INCONCLUSIVE stays open.** Uncertainty never clears a finding: re-run that attack yourself, or file it in LuxPM as an open lead with what stopped the attacker. It never counts toward a clean pass.
- UNREPRODUCED findings get one line each in your report. Do not fix guesses.

## 4. Attack the fixes: a fresh attacker, at most three rounds

The fixes are new code, and nobody has attacked them. When round 1 confirmed anything, spawn a **new** attacker (a new agent, never the round-1 one continued) on the change as it now stands, with the earlier findings listed as already fixed (step 2). Act on its report as in step 3. Repeat while a round confirms something, **at most three rounds in all**. If round 3 still confirms findings, the design is not converging: stop patching. Split the change, rethink the approach, or take it to the owner with the round counts. A round that finds nothing ends the loop.

**A clean first round is a signal, not a pass.** When round 1 confirms nothing on a change to authentication, authorization, tenancy, money or a guard, run one more fresh attacker before believing it. An attacker that never finds anything is as likely lax as the change is clean.

**Escapes.** A defect found later in code that passed this pass (by a reviewer, a later attack, production) is filed with the label `adversarial-escape`, naming the change and the round that missed it. That count is how the fleet learns how good its attackers are.

## 5. Evidence

Per round: the CONFIRMED, INCONCLUSIVE and UNREPRODUCED counts (and, with two attackers, each one's count and the overlap). Each confirmed finding's test name with its fail-then-pass lines, how the loop ended (a clean round, or stopped at round 3 and why), and any issues or escalations filed. `/wrap-up` quotes this.
