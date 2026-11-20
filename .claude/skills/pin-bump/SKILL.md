---
name: pin-bump
description: Move this repo to the latest fleet guards (luxarch, luxlint, luxaudit) the fleet way — bump the pins, read what changed, re-emit every asset whose version moved, fix every new red in the bump's own change (escalating a guard that is wrong), review every open guard escalation this repo filed against the new version, and regenerate and commit the status files. Use whenever guard-version-check says a pin is behind.
---

<!-- luxarch:pin-bump-skill asset v8 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit pin-bump-skill`. -->

# Pin bump

The runnable guard upgrade for this repo. Emitted from luxarch (`luxarch --emit pin-bump-skill`); re-emit, never hand-edit. Rationale: `luxarch --doc FLEET-MAKEFILE-STANDARD` (pins, `guard-version-check`, `guard-upgrade`) and `luxarch --doc FLEET-STATUS`.

**Every step ends with its evidence.**

## 0. The bump's issue

A bump runs in its issue's worktree. When no open issue in this repo's project covers this bump, file it yourself: search first (`luxpm_list_issues(project=<this repo's project>, search="guard bump")`), then `luxpm_create_issue` with `project` set to this repo's project, `state: in_progress`, titled with the versions (`Guard bump to luxarch <version>`), and no `waiting_on`. The emitted `no-new-follow-ups` hook allows a create of work started now; never ask the owner to file it, and never reopen the last bump's closed issue. Then enter its worktree.

**Evidence:** the issue key and the worktree entered.

## 1. Bump the pins

`make guard-upgrade`. It moves each guard pin to the published latest and says what it moved.

**Evidence:** the `old -> new` line per guard.

## 2. Read what changed, before running anything

For each guard that moved:

- `docker run --rm <guard image> --changelog --since <old version>`, and for luxarch also `--new-rules --since <old version>`.
- Note every entry that says **"may newly flag"**, **"re-emit"**, or changes a standard you follow.

**Evidence:** the versions read and the entries that apply to this repo.

## 3. Re-emit every asset whose version moved

Emitted assets carry a version marker (`luxarch:<name> asset vN`). Run `make arch`: `repo.emitted_assets_current` names each asset whose marker is behind, and `repo.claude_pointer_present` the CLAUDE.md block. For each one, re-apply it in place with the image, mounted read-write:

```sh
docker run --rm -v <checkout>:/repo -w /repo <luxarch image> --emit <name> --update <file>
```

`<checkout>` is the checkout's absolute path, written out: inside a worktree Claude Code refuses a mount computed at run time, such as `"$PWD"`.

It replaces the asset in `<file>` (a whole file, or the block inside your Makefile or CLAUDE.md) and carries your `EDIT THIS` regions and your make variable settings (`?=`, `:=` or `=`) across. It refuses, changing nothing, when your copy was edited anywhere else: undo that edit, or `/escalate` if the asset needs it. Do not merge by hand, and never hand-patch an emitted asset to make it pass.

**Evidence:** each asset re-emitted, `vN -> vM`.

## 4. Run the gate, and fix every new red in the bump's own change

`make check`. A new rule that fires is the point of the bump: another repo was held to a stricter bar and this one now is too.

- **Every new red the bump lights is fixed in the pin bump's own change**, in this worktree, before it lands. Aligning to a ratified standard is do-it class: never ask, and never a new issue for the repo-side work, nor a plan to do it "after this lands" (`luxarch --doc FLEET-AGENT-CONDUCT-STANDARD`, "Work what you find; never defer it"). **You touched it, you own it** applies to every file you edit (conduct standard #11), and `luxlint --playbook mypy-sweep` comes first for mypy.
- **A fix with a step that is not this repo's still lands its repo-side part now.** When the remedy also needs an infra or owner step (an edge map line, a secret, a DNS change), do every repo-side step in this change. Only the part that genuinely needs the owner or infra waits, and it goes to the owner. A dev edge change is the standard's infra request (`luxarch --doc FLEET-BUILD-DEPLOY-STANDARD`, "Infra's part is a request"): its own issue, `infra-request`, parked on `waiting_on: "owner: infra, <the change?>"`. Any other owner step is one question on the bump's issue, which names the step and what it unblocks, parked `on_hold` with `waiting_on: "owner: <the question?>"`. Every such `waiting_on` starts with `owner:`: infra is reached through the owner.
- A guard that is genuinely wrong: `/escalate`. A red stays red while its escalation is open; never defer or allowlist it to get green.

**Evidence:** the red count before and after, the commit that fixed each new red, and any escalation key or `waiting_on` set.

## 5. Review this repo's open guard escalations

A pin bump is when the guard fixes this repo was waiting on arrive. An escalation left open after its fix has shipped reads as still blocked, and the red it covered is never re-checked. `/fleet-start` brings you here between bumps too, for each escalation whose `waiting_on` names your step.

- List every guard escalation this repo filed: `luxpm_list_issues` with `project` set to this repo's project and `labels` `fleet-escalation`, with **no state and no date filter** (open escalations sit in `backlog`, `todo`, `in_progress` and `on_hold`). Skip the ones already `done` or `cancelled`.
- For each, read the body **and** the maintainer's latest reply (`luxpm_get_context`), then run its **Verify** command on the new pins, as written, and compare the output with its "when fixed" line. An escalation with no Verify block gets one first: write the command that shows the defect, what it prints now and what it prints when fixed, add it to the issue, then run it.
  - **Resolved by the new version:** apply the remedy the reply names, if any (a re-emit, a setting, a code change), then close the escalation with the guard version, the Verify command's output and the commit.
  - **Still wrong:** comment with the version you checked and the Verify command's actual output, set `waiting_on` to `<guard> maintainer: still fails on <version>: <what>`, and keep the red lit. Never close it, defer it or allowlist it.
  - **Answered as working as intended:** align the code as the reply says, then close the escalation with the commit.

**Evidence:** each escalation key, the version it was checked on, and its new state (closed, or open with the comment and the `waiting_on` you set).

## 6. Status files, committed

`make status` regenerates `.luxarch-status.json`, `.luxlint-status.json` and `.luxaudit-status.json`; `repo.guard_status_current` requires them committed with the pins. Commit the pin change, the re-emitted assets and the status files together, as `luxardolabs`, no AI attribution; push.

**Evidence:** the commit SHA.
