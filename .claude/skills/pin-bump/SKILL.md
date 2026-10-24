---
name: pin-bump
description: Move this repo to the latest fleet guards (luxarch, luxlint, luxaudit) the fleet way — bump the pins, read what changed, re-emit every asset whose version moved, leave new reds red, review every open guard escalation this repo filed against the new version, and regenerate and commit the status files. Use whenever guard-version-check says a pin is behind.
---

<!-- luxarch:pin-bump-skill asset v4 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit pin-bump-skill`. -->

# Pin bump

The runnable guard upgrade for this repo. Emitted from luxarch (`luxarch --emit pin-bump-skill`); re-emit, never hand-edit. Rationale: `luxarch --doc FLEET-MAKEFILE-STANDARD` (pins, `guard-version-check`, `guard-upgrade`) and `luxarch --doc FLEET-STATUS`.

**Every step ends with its evidence.**

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

## 4. Run the gate, and leave new reds red

`make check`. A new rule that fires is the point of the bump: another repo was held to a stricter bar and this one now is too.

- Fix what is yours to fix now. **You touched it, you own it** applies to every file you edit (conduct standard #11), and `luxlint --playbook mypy-sweep` comes first for mypy.
- Anything genuinely wrong with a guard: `/escalate`. A red stays red while its escalation is open; never defer or allowlist it to get green.

**Evidence:** the red count before and after, and any escalation keys.

## 5. Review this repo's open guard escalations

A pin bump is when the guard fixes this repo was waiting on arrive. An escalation left open after its fix has shipped reads as still blocked, and the red it covered is never re-checked.

- List every guard escalation this repo filed: `luxpm_list_issues` with `project` set to this repo's project and `labels` `fleet-escalation`, with **no state and no date filter** (open escalations sit in `backlog`, `todo`, `in_progress` and `on_hold`). Skip the ones already `done` or `cancelled`.
- For each, read the body **and** the maintainer's latest reply (`luxpm_get_context`), then re-run the site it names on the new pins (`docker run … <guard image> --rule <rule id>`, or the asset's own check).
  - **Resolved by the new version:** apply the remedy the reply names, if any (a re-emit, a setting, a code change), then close the escalation with the guard version, the rule's result on the site and the commit.
  - **Still wrong:** comment with the version you checked and what still fails, and keep the red lit. Never close it, defer it or allowlist it.
  - **Answered as working as intended:** align the code as the reply says, then close the escalation with the commit.

**Evidence:** each escalation key, the version it was checked on, and its new state (closed, or open with the comment).

## 6. Status files, committed

`make status` regenerates `.luxarch-status.json`, `.luxlint-status.json` and `.luxaudit-status.json`; `repo.guard_status_current` requires them committed with the pins. Commit the pin change, the re-emitted assets and the status files together, as `luxardolabs`, no AI attribution; push.

**Evidence:** the commit SHA.
