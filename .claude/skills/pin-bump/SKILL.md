---
name: pin-bump
description: Move this repo to the latest fleet guards (luxarch, luxlint, luxaudit) the fleet way — bump the pins, read what changed, re-emit every asset whose version moved, regenerate and commit the status files, and leave new reds red. Use whenever guard-version-check says a pin is behind.
---

<!-- luxarch:pin-bump-skill asset v1 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit pin-bump-skill`. -->

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

Emitted assets carry a version marker (`luxarch:<name> asset vN`). Run `make arch`: `repo.emitted_assets_current` names each asset whose marker is behind, and `repo.claude_pointer_present` the CLAUDE.md block. For each one, `luxarch --emit <name>` and replace your copy with it, keeping only the lines the asset marks as yours to edit (an `EDIT THIS` variable, `APP_IMPORT`, …). Never hand-patch an emitted asset to make it pass.

**Evidence:** each asset re-emitted, `vN -> vM`.

## 4. Run the gate, and leave new reds red

`make check`. A new rule that fires is the point of the bump: another repo was held to a stricter bar and this one now is too.

- Fix what is yours to fix now. **You touched it, you own it** applies to every file you edit (conduct standard #11), and `luxlint --playbook mypy-sweep` comes first for mypy.
- Anything genuinely wrong with a guard: `/escalate`. A red stays red while its escalation is open; never defer or allowlist it to get green.

**Evidence:** the red count before and after, and any escalation keys.

## 5. Status files, committed

`make status` regenerates `.luxarch-status.json`, `.luxlint-status.json` and `.luxaudit-status.json`; `repo.guard_status_current` requires them committed with the pins. Commit the pin change, the re-emitted assets and the status files together, as `luxardolabs`, no AI attribution; push.

**Evidence:** the commit SHA.
