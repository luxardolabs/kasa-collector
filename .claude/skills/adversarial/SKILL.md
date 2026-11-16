---
name: adversarial
description: Attack a change before calling it done — an independent agent that did not write the change tries to make it wrong (security, tenant isolation, data integrity, money, the real stack), reproduces each break as a failing test or a probe, and the author fixes every confirmed break and commits the test. Run it from /wrap-up for any change touching auth, tenancy, data writes or migrations, money, secrets or personal data, deploys, or a guard-red fix.
---

<!-- luxarch:adversarial-skill asset v8 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit adversarial-skill`. -->

# Adversarial pass

Emitted from luxarch (`luxarch --emit adversarial-skill`); re-emit, never hand-edit. The standard is `luxarch --doc FLEET-ADVERSARIAL-TESTING-STANDARD`; this is the procedure. The fleet's guard maintainer runs this same pass on every rule before a release, and it finds a real defect almost every time. The author of a change is the person least able to see how it fails, which is why the attacker must be someone else.

**Which agent are you?** In a repo that hosts a luxios app (a nested `apps/ios/` with its own `CLAUDE.md`, beside the backend), there are two agents. If this machine has no Docker (`command -v docker` prints nothing), you are that app's agent: read its `CLAUDE.md` first, follow the iOS reading below, and leave the root guard gates (`make check`, the luxarch, luxlint and luxaudit images) to the backend agent. Never look for a Docker binary to install.

**In an iOS repo, or as the iOS agent of a repo that hosts one** (luxios: native, no Docker), luxios installs this file unchanged (`bash $LUXIOS/scripts/install.sh`). Read every `luxarch --doc X` here as the file `$LUXIOS/docs/fleet/X.md`, and every `luxarch --playbook X` as `$LUXIOS/docs/fleet/playbooks/X.md`. The guard there is luxios: its version is `cat $LUXIOS/VERSION`, and its changelog is `$LUXIOS/CHANGELOG.md`.

## 0. Who the attacker is

The attacker has none of the operator's access: a visitor or signed-in user of the app, another tenant, a caller of its API, a malformed or legacy row, the real stack's own behaviour, or the operator's honest mistake. Out of scope is anyone who already controls the machine the operator runs the change on: its shell environment, git config, home directory, installed tools or typed arguments. Such a person needs no flaw in the change.

A build, release or deploy recipe runs on the operator's machine with the operator's credentials, so it is attacked for **accidents only**:

- publishing a commit the gate did not pass;
- an artifact that differs from the one tested;
- a personal identity or a secret reaching a tag, a log or a terminal;
- a run that half-completes on an ordinary machine.

A finding must also be **real**: an input that a real user, repo or environment produces, not a shape built only to break the code. A finding outside this section is listed under NOT IN SCOPE, and is neither fixed nor filed.

## 1. Scope the change

`git diff --stat <base>..HEAD` (the base is where this work started). List each changed **behaviour** in one line: what it now does, for whom, with what input. That list is the attack surface.

## 2. Spawn the attacker

Use the Agent tool with a **general-purpose** agent, on the strongest model (the session's own; never a cheaper tier for this). **Launch it with the session inside the attacked issue's worktree, and do not leave that worktree until it reports.** A subagent runs in the session's current worktree, not the one its brief names: once the session enters another worktree, Claude Code refuses every command the attacker runs against its own, and the round comes back with nothing run. Run it in the background only if your other work is in that same worktree. For a change to authentication, authorization, tenant isolation or money, spawn **two** attackers in parallel that share nothing; act on the union of their findings, and record how many each found and how many they shared. The prompt, filled in:

```
You are attacking a change in <repo> that you did not write. Your job is to make it WRONG.

THE CHANGE: <base>..HEAD (`git diff <base>..HEAD`). Changed behaviours:
<the list from step 1>

For each behaviour, ask how a realistic input, state or environment makes it do the wrong thing, and
REPRODUCE it. The attacker you play has none of the operator's access: a user, another tenant, an API
caller, a dirty row, the real stack, or the operator's honest mistake. Someone who already controls the
operator's machine (shell environment, git config, home directory, installed tools, typed arguments)
is out of scope; so is a build, release or deploy recipe attacked for anything but an accident (an
untested commit published, an artifact that differs from the tested one, an identity or secret
reaching a tag, log or terminal, a half-completed run). Only inputs a real user, repo or environment
produces count. Attack in this order:
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

TARGET: your requests reach only this work's throwaway stack, never a real host. Address it by
container name or 127.0.0.1, and send the real host name only as a header (`curl -H 'Host: <name>'`,
playwright `extra_http_headers`). A script that needs the real name in its URL (a cookie domain, TLS)
runs in a container on a `docker network create --internal` network holding only that stack, with its
dependencies installed before it joins: a remap the script sets for itself, or a hosts entry it relies
on, fails open, and a missed one sends its login to production. Outside that network, never use
`curl -k` or any other certificate bypass.

WHERE ATTACK SCRIPTS RUN: on a machine other agents share, as a user that can write its system paths,
so a script's mistake lands on every session there. Every script you run:
- starts `set -eu` (a Python script fails on an unset name by itself), so an unset variable stops it
  before `"$ROOT/bin/gh"` becomes `/bin/gh`;
- runs only inside `docker run --rm --network none -v <scratch dir>:/s -v <worktree>:/w:ro -w /s
  <image> sh /s/<script>`, both paths written out, nothing else mounted: your scratch dir read-write,
  the code under attack read-only. The image already holds what the script needs (the repo's test
  image, or `python:3-slim` for a stdlib script); nothing is installed at run time. A stand-in tool
  (`gh`, `docker`, `git`) lives in /s/bin, on PATH inside that container only. Two runs leave it: the
  probe of the throwaway stack above, on its `--internal` network, and the repo's own `make test-one`
  for your one test file, which runs its own container;
- is a file you wrote with the file tool before the first `docker run` that mounts it (docker makes a
  missing mount source as an empty directory owned by root);
- is run by one plain `docker run` per step, naming that script: no `&&` chain, heredoc or pipe into a filter,
  and its whole output read (a cut tail is a lost result);
- has no `pytest.skip` and no bare `noqa`: a test that cannot run fails;
- holds a bare red and a bare green control, and the report shows both results.
A round in which nothing executed is INCONCLUSIVE, with what stopped it, never "no breaks".

CONSTRAINTS: read-only on the repo except files under <scratch dir>, and one test file of your own
in the repo's tests/ (`tests/test_adversarial_<topic>.py`) when a finding needs the repo's own test
harness (`make test-one`): name it in your report, and the author moves it into the suite or deletes
it. No commits, pushes or tracker writes. Run plain commands from the
worktree root: no `git -C <path>`, no `cd` elsewhere, no path computed at run time (`$PWD`,
`$(...)`); write files with the file tool. A command the session or a hook refuses is INCONCLUSIVE,
naming the refusal, never a pass.

REPORT: a table of CONFIRMED findings, most severe first: behaviour, what goes wrong, the reproducing
test or probe, the one-line fix. Then INCONCLUSIVE ones with what stopped you. Then UNREPRODUCED ones
with the reason. Then NOT IN SCOPE: findings outside the attacker above, one line each. Then what you did not attack. Then every host your scripts connected to, read from the scripts and their output.
```

In a re-attack round (step 4), add to the prompt: `ALREADY FOUND AND FIXED (do not re-report these shapes): <one line per earlier finding>. Attack the fixes themselves and anything they made reachable.`

## 3. Act on the report

- **Merge duplicates first.** Two findings with the same reproduction and the same failing line are one finding, whatever their titles say: fix and test it once.
- **Every CONFIRMED finding is fixed in this work**, and its reproducing test is moved into the suite and committed. Run it against the code without the fix first and record its failing line (`/wrap-up` step 2).
- A finding whose fix needs the owner (scope, money, data semantics) gets an issue in LuxPM. The red stays red until it is decided.
- A finding in a fleet guard or emitted asset is a `/escalate`, not a local fix.
- **INCONCLUSIVE stays open.** Uncertainty never clears a finding: re-run that attack yourself, or file it in LuxPM as an open lead with what stopped the attacker. It never counts toward a clean pass.
- UNREPRODUCED findings get one line each in your report. Do not fix guesses.
- NOT IN SCOPE findings (step 0) are neither fixed nor filed.

## 4. Attack the fixes: a fresh attacker, at most three rounds

The fixes are new code, and nobody has attacked them. When round 1 confirmed anything, spawn a **new** attacker (a new agent, never the round-1 one continued) on the change as it now stands, with the earlier findings listed as already fixed (step 2). Act on its report as in step 3. Repeat while a round confirms something, **at most three rounds in all**. If round 3 still confirms findings, the design is not converging: stop patching. Split the change, rethink the approach, or take it to the owner with the round counts. A round that finds nothing ends the loop.

**What is left is a stated limit, not new work.** A finding the loop leaves unfixed is one line in the change's stated limits (its changelog entry, docstring or close summary). It becomes an issue only when a real repo, user or incident already hits it.

**A clean first round is a signal, not a pass.** When round 1 confirms nothing on a change to authentication, authorization, tenancy, money or a guard, run one more fresh attacker before believing it. An attacker that never finds anything is as likely lax as the change is clean.

**Escapes.** A defect found later in code that passed this pass (by a reviewer, a later attack, production) is filed with the label `adversarial-escape`, naming the change and the round that missed it. That count is how the fleet learns how good its attackers are.

## 5. Evidence

Per round: the CONFIRMED, INCONCLUSIVE and UNREPRODUCED counts (and, with two attackers, each one's count and the overlap). Each confirmed finding's test name with its fail-then-pass lines, how the loop ended (a clean round, or stopped at round 3 and why), and any issues or escalations filed. `/wrap-up` quotes this.
