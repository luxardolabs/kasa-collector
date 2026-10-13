---
name: adversarial-audit
description: Attack the WHOLE platform, not just a change — take the attack surface from `luxarch --sweep attack-surface`, rank it by this repo's committed audit profile, hand each slice to an independent attacker, verify every break with a second agent, and file each confirmed break in LuxPM with its failing test. Direct it in plain words ("what changed since the last release", "just payments, go deep", "quick"); re-runs attack only what changed. Use for a first full review of an app, on the owner's schedule, or when asked to audit or red-team the platform.
---

<!-- luxarch:adversarial-audit-skill asset v3 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit adversarial-audit-skill`. -->

# Adversarial audit: the whole platform

Emitted from luxarch (`luxarch --emit adversarial-audit-skill`); re-emit, never hand-edit. The standard is `luxarch --doc FLEET-ADVERSARIAL-TESTING-STANDARD`.

`/adversarial` attacks a change, so its surface is `git diff` and code that never changes is never attacked. This skill takes its surface from the guard's inventory of the platform instead. The guard decides what the platform is, and the repo's profile says what matters in it; the agents attack. One independent attacker per slice, a reproduced failure as the only evidence, and a second pass before anything is believed.

**Cost.** Measured on a 130-route app (2026-10-11): the default direction attacked 8 slices with 51 agents (8 attackers, 43 verifiers), about 3.7M tokens and 14 minutes, and found 42 real defects. So budget roughly **450k tokens per slice attacked** at the default depth; `quick` is about half that, `deep` more. Start it on purpose, never from a timer or a hook. If the person did not ask for an audit, offer it in one line instead of running it.

## 1. Inventory

```sh
docker run --rm -v "$PWD":/repo:ro -w /repo <luxarch image> --sweep attack-surface --json > <scratch>/surface.json
```

Also read the text form (the same command without `--json`). Its header lines say how many routes, jobs and entry points there are, the audit state (`attacked` / `stale` / `never` / `retired` slices), the profile state (`profile: none | current | needs re-check (<reasons>)`), and this run's `surface:` counts. Every route or job under `unresolved` is a target in its own right: a surface the guard cannot see is one nobody has checked. A route whose `auth` is `unknown` is attacked as if it were `anon`.

## 2. The profile: set up once, re-checked when the guard says so

The repo's committed `.adversarial-audit.toml` holds a `[profile]`: what an attacker wants here and where it sits. It exists so that "riskiest" is decided once, by the owner, and not re-derived from the code on every run.

- **`profile: none`** (first audit): before attacking anything, write it. One agent (the strongest model) reads `surface.json`, the repo's CLAUDE.md and docs, its LuxPM history (past incidents, security issues) and, where the inventory points, the code. It writes:

  ```toml
  [profile]
  written = "<today>"
  commit = "<HEAD>"
  crown_jewels = ["<what an attacker wants: money movement, customer PII, another tenant's data, admin>"]
  actors = ["<who reaches it: anonymous visitors, users, tenant admins, partner API keys, webhooks>"]
  boundaries = ["<where data crosses in: uploads, URL fetches, LLM prompts, imports, integrations holding credentials>"]
  hot_spots = [{ path = "<file or slice id>", why = "<why it matters more than its tier>" }]
  out_of_scope = [{ path = "<file or slice id>", why = "<why>" }]
  history = ["<past incident or finding, with its tracker key>"]

  [profile.surface]   # copy the sweep's `surface:` counts verbatim; never compute them
  routes = 0
  anon = 0
  money = 0
  credential = 0
  upload = 0
  webhook = 0
  mounts = 0
  jobs = 0
  ```

  Commit it, show it to the owner, and **stop for their review**: what counts as a crown jewel is the owner's judgment, not the code's. Attack after they confirm (or correct) it.

- **`profile: needs re-check`**: the sweep lists why (older than 90 days, a new kind of surface, routes grew by a quarter, or a field missing). Re-check before attacking: edit the profile, never rewrite it; update `written`, `commit` and `[profile.surface]`; and show the owner the diff. Never remove or downgrade a crown jewel or a hot spot without the owner saying so.

- **`profile: current`**: use it as it is.

## 3. Read the direction

The owner directs in plain words, or not at all. Map what they say onto these levers (the levers are yours to apply; the owner never has to name them):

| lever     | what it ranks or limits by                                                                                           | where the fact comes from                                                    |
| --------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| risk      | tier 1 auth > 2 tenancy > 3 money/webhooks > 4 writes > 5 reads                                                      | the sweep's slice tier                                                       |
| exposure  | `anon` > `user` > `tenant_user` > `superuser`                                                                        | each route's `auth`                                                          |
| change    | slices whose files changed in a window ("since the last release", "this week", "since v2026.10.0")                   | `git log --name-only` over the window, intersected with each slice's `files` |
| staleness | `never` first, then `stale` by the age of its last attack                                                            | the audit state                                                              |
| lens      | every slice in scope, attacked through ONE class of attack ("tenant isolation", "webhook replay", "rate-limit keys") | narrows the attacker brief, not the slices                                   |
| history   | slices with past findings, and the slices they call                                                                  | `[slices]` `findings`, the profile's `history`                               |
| budget    | how many attackers, how deep                                                                                         | see the three words                                                          |
| explicit  | named areas or slices, even ones marked `attacked` (a forced re-attack)                                              | a substring of `id` or `files`                                               |

Three words cover the common cases, and they combine with anything else said:

- **(nothing)**: the default. In scope: every `stale` and `never` slice. Ranked by the profile (crown jewels and hot spots first), then risk, then exposure, then staleness. Up to 8 attackers, every finding verified.
- **`quick`**: tier 1–2 slices and hot spots only, up to 4 attackers, every finding verified.
- **`deep`**: everything in scope, every finding verified, plus one chaining pass at the end (step 6).

What the owner says is a hard limit, applied in the order they said it; the default ranking breaks ties and fills whatever they left open. Inside that, you may promote a slice the ranking put lower, for a reason you state ("a tier-4 slice, but it calls the payment client"). Never drop one silently: everything in scope that you do not attack is listed as skipped, with why.

**Before spending anything, print one line**, then go:

```
Plan: <the direction as you read it> · tiers <…> · <n> slices · <k> attackers (+ verify[, chaining]) · ≈<n × 450k> tokens · skipping <m> (<why>)
```

Ask the owner first only when their words conflict ("quick but everything"), when the plan would spend more than twice the default, or when the profile needs their review (step 2).

## 4. Attack, one slice per attacker

Batch the planned slices into rounds of at most 8 attackers. Run each round as a workflow (or as parallel background agents with the Agent tool), every attacker a **general-purpose** agent on the strongest model, never a cheaper tier. A round that stops early leaves the rest for the next run: the registry records only what was attacked.

The attacker prompt, filled in per slice:

```
You are attacking one slice of <repo>, a platform you did not write. Your job is to make it WRONG.

WHAT MATTERS HERE (the repo's audit profile): crown jewels <…>; actors <…>; boundaries <…>;
hot spots <…>. Out of scope: <…>.
THE SLICE: <slice id>, risk tier <tier>. Its routes, jobs and entry points, with the guard's own
facts about each (auth, tenant reach, writes, credential/money/webhook/upload flags, rate limit):
<the slice's JSON from surface.json>
The files its call graph reaches: <files>. Read them; follow calls out of the slice when an
attack needs it.
<if a lens was given: ATTACK ONLY THROUGH: <the lens>.>

For each route, job or entry point, ask how a realistic request, state or environment makes it do
the wrong thing, and REPRODUCE it. Attack in this order:
1. security: another user's or tenant's data, an unauthenticated or under-authorised path (start
   with any `unknown` auth), a forged header or Host, a client-chosen rate-limit key, an
   injection, a secret or personal data reaching a log or a response;
2. data integrity: a partial write, a missing transaction, a race, dirty or legacy rows the test
   DB does not have (nulls, orphans, soft-deleted parents, duplicates); use the repo's
   adversarial corpus (`luxarch --emit adversarial`) when it has one;
3. money and irreversible actions: a double charge, a retry, a webhook replayed, forged or out of
   order;
4. the real stack: a service the test stack does not run, the production image, a standalone
   entry point that skips app.main's imports, a config default that differs in prod;
5. anything else in the slice.

EVIDENCE BAR: a finding counts only when reproduced: a failing test written under <scratch>/<slice
id>/ (never in the repo's tree), or a probe against the dev stack with its output. Show a control
that passes, so the failure is the code's and not the harness's. Otherwise mark it UNREPRODUCED
with the reason.

CONSTRAINTS: read-only on the repo except <scratch>/<slice id>/; no commits, pushes, git config
changes or tracker writes; never touch production.

REPORT: CONFIRMED findings, most severe first: the route/job, what goes wrong, the reproducing test
file or probe output, the one-line fix. Then UNREPRODUCED ones with the reason. Then what you did
not attack and why.
```

## 5. Verify every confirmed finding

A large sweep drifts toward plausible findings that are not real. Before anything is filed, give each CONFIRMED finding to a second **independent** agent (strongest model) with only the finding, its reproduction, and the repo:

```
Another agent claims this defect in <repo>: <finding>. Its reproduction: <test or probe>.
Decide whether it is REAL. Run the reproduction yourself; check that it fails for the reason
claimed and not because of the harness, a fixture, or a misread; check the control passes; look
for the guard or test that should already have caught it. Read-only except <scratch>/verify/.
REPORT: REAL or NOT REAL, with the run's output; for REAL, the severity and the smallest fix.
```

Tier the verification by what is at stake. **Full verification** (the second agent above) for every critical, high or medium finding, and for any finding about security, tenancy, money or data integrity whatever its rating. **Light verification** for a low-severity correctness finding (an unhandled error that returns 500 instead of 422, a missing validation): you re-run its reproduction once yourself, with no second agent, and mark it `verified: light` in the report and the issue. A light check that does not reproduce the failure is NOT REAL, the same as a full one.

Only REAL findings go on. A NOT REAL one is recorded in the run's report with its reason, never filed.

## 6. `deep` only: the chaining pass

One more independent agent gets every REAL finding and UNREPRODUCED lead from this run, plus the profile, and asks how two of them combine into something worse than either: a low-severity read that hands over the id a second slice trusts, an unauthenticated write that a background job later acts on. Same evidence bar; same verification for anything it confirms.

## 7. File the burn-down and record the run

For each REAL finding, search LuxPM first (`luxpm_semantic_search`) and comment on a matching issue if one exists. Otherwise create one issue per finding under the repo's audit epic (`luxpm_list_issues` with `search: "[adversarial-audit]"`; create `[adversarial-audit] <repo>` if none exists): the route or job, what goes wrong, severity, the reproducing test (its text, or its path and failing line), and the fix. Priority follows severity: a security or money finding is urgent or high. A finding a fleet guard or emitted asset claims to catch but passed is also a `/escalate`, so the guard learns it for every repo.

**Keep the reproductions where the burn-down can reach them.** `<scratch>` dies with this session, and the burn-down happens later, often in another one. Before filing, copy each attacker's `<scratch>/<slice id>/` and the verifiers' files into `.adversarial-audit/runs/<date>/<slice id>/` in the repo, and make sure `.gitignore` carries `/.adversarial-audit/` (commit that line; the run files themselves stay uncommitted). Each issue cites its reproduction there by path and failing line; never paste a whole verifier transcript into an issue. File the issues in one batch, not one call per issue.

Then record the run in two places:

- **`.adversarial-audit.toml`, committed.** For each slice attacked, write its table, copying the fingerprint from the sweep's output (never compute one):

  ```toml
  [slices."<slice id>"]
  fingerprint = "<the sweep's fingerprint for it>"
  commit = "<HEAD audited>"
  date = "<today>"
  epic = "<epic key>"
  findings = ["<issue keys>"]
  ```

  Delete the tables of the `retired` ids the sweep lists for the target you audited (in a repo with several targets, each id carries its target's `<app>:` prefix and the sweep only ever retires its own); leave unattacked slices' tables as they were. A slice whose round did not finish gets no table, so it stays `stale` or `never`.

- **The epic, in LuxPM.** One activity titled `adversarial-audit run <date>`: the Plan line, the commit, the slices attacked and skipped (with why), and the counts CONFIRMED, REAL, NOT REAL, UNREPRODUCED and filed. LuxPM holds the findings and their burn-down; the file holds what was attacked, when, and what matters.

## 8. Burn it down

Each finding is worked like any red: its reproducing test moves from `.adversarial-audit/runs/…` into the suite, is seen to fail, the fix makes it pass, and `/wrap-up` closes the issue with that evidence. Once every finding of a run is closed, delete that run's directory. Work them in severity order. Never fix a finding inside the audit run: the attacker and the fixer are different passes.

## 9. Report

One short report: the Plan line, slices attacked and skipped, the four counts, the issues filed with their severity, any escalations, and the profile's state. No narration of effort.
