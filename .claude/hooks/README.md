# Fleet Claude-Code hooks — emitted, never hand-written

Installed by `luxarch --emit hooks > <scratch>/install_hooks.py`, then `python3 <scratch>/install_hooks.py` (`<scratch>`: a directory outside the checkout that is yours alone, such as your session's scratchpad; inside a worktree Claude Code refuses generated code piped into `python3`). **Do not hand-edit these files.** They are emitted from the pinned guard image so every repo runs the byte-identical set; re-emit to update. `repo.hooks_current` reds when what's committed here has drifted from the pin.

## The boundary — why these exist and the rules don't live here

luxarch/luxlint own the CODE. These hooks own what a file-scanning guard **structurally cannot judge**:

- **Who made the change.** The guard reads `.luxarch.toml` as data — it cannot tell an owner-approved `[rules.deferred]` from an agent quietly routing around a red. `no-agent-deferral.py` can, because it sees the edit happening.
- **The command, not the tree.** A commit message, an identity override, a silenced `git add`, a force push, a `DROP TABLE` — none of these are files at check time.
- **The turn.** Unlogged work and unpushed commits are absences; a Stop hook is the only thing that can refuse to finish on them.

A hook here must never re-implement a rule the guard already owns. Eleven repos each grew a hand-rolled copy of `view-services-no-crud` / `crud-no-fastapi` / … — eleven parallel copies of a standard with one home, unable to see the allowlists, INERT states or site-waivers the real rule honours. They were deleted; the guard was always the authority.

## Writing a Bash hook: two texts, two questions

Every Bash hook reads its command through `_cmdtext`. There is one rule, and three over-firing defects were shipped before it was written down — each one caught by the hook blocking its own author mid-task:

| question                                       | ask it of                        | why                                                                                                                           |
| ---------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| is this dangerous verb actually being **run**? | **masked** text (`command_text`) | a heredoc body or a quoted literal containing the pattern is DATA — writing a test or a doc about `rm -rf` is not running it  |
| what is it **pointing at**?                    | **raw** text                     | a path is routinely quoted, and masking deletes the target — `rm -rf "$DIR"` loses its own argument                           |
| does it pair two things?                       | **one segment**                  | a compound line silences or creates something unrelated; `docker run … 2>/dev/null && git add -A` is not a silenced `git add` |

`segments(cmd)` returns aligned `(masked, raw)` pairs, one per segment — masking preserves length, so the two strings share offsets. Use it rather than splitting either text alone.

The exception is `no-ai-attribution`, which must NOT mask: a commit message *is* the quoted payload. It is safe because it is already scoped to commit/PR commands.

**And the discipline that matters more than any of this:** for every hook, test that it FIRES on the real thing *and* passes the legitimate neighbour. A hook that over-fires gets switched off, taking its real catches with it — strictly worse than no hook.

## What's here

| hook                           | fires                                      | effect                                                                                                                                  |
| ------------------------------ | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| `no-agent-deferral`            | Edit/Write on a guard config               | **deny** — deferrals/allowlists are the owner's call                                                                                    |
| `no-suppression`               | Edit/Write                                 | **deny** — no `# noqa` / `# type: ignore`                                                                                               |
| `no-golden-edit`               | Edit/Write on `*.golden`                   | **deny** — use `make parity-update`                                                                                                     |
| `no-test-weakening`            | Edit/Write on a test                       | **deny** — no skip/xfail to reach green                                                                                                 |
| `no-gate-bypass`               | Bash                                       | **deny** — `--no-verify`, `--deselect`, `SKIP=`                                                                                         |
| `confirm-destructive`          | Bash                                       | **deny** — `rm -rf`, `reset --hard`, force push, `DROP TABLE`                                                                           |
| `no-identity-override`         | Bash                                       | **deny** — `git -c user.email=`                                                                                                         |
| `no-ai-attribution`            | Bash                                       | **deny** — Co-Authored-By: Claude                                                                                                       |
| `no-silenced-staging`          | Bash                                       | **deny** — `2>/dev/null` on mutating git                                                                                                |
| `targeted-guard-run`           | Bash                                       | **deny** — a full luxarch scan piped into grep/head/tail; use `--rule <id> [--path <file>]`                                             |
| `luxpm-search-before-create`   | `luxpm_create_issue`                       | **deny** — no LuxPM search since the last issue created                                                                                 |
| `luxpm-close-tracks-deferrals` | `luxpm_update_issue`, `luxpm_create_issue` | **deny** — a close summary that defers work without naming the open issue tracking it, or `dropped: <why>`                              |
| `delete-proposal-evidence`     | `AskUserQuestion`, Stop                    | **deny** — a removal ask without a checked block per candidate; Stop only reminds once                                                  |
| `edit-history`                 | Edit/Write/Bash writes                     | **deny** — a session's first change to a tracked file before it has searched LuxPM for that file                                        |
| `commit-leftover-check`        | Bash (post)                                | advisory — partial-commit warning                                                                                                       |
| `luxpm-record-commit`          | Bash (post)                                | records the commit in the ledger                                                                                                        |
| `luxpm-clear-ledger`           | LuxPM log tools (post)                     | clears the ledger                                                                                                                       |
| `luxpm-stop-guard`             | Stop                                       | **blocks** — work not logged in LuxPM                                                                                                   |
| `unpushed-stop-guard`          | Stop                                       | **blocks** — commits not pushed                                                                                                         |
| `fleet-start-after-compact`    | SessionStart (`compact`)                   | context — tells the agent to run `/fleet-start`                                                                                         |
| `context-watch`                | every tool (post)                          | context + owner message — once at 85% context: finish the step, run `/wrap-up`                                                          |
| `worktree`                     | `EnterWorktree` (post)                     | repairs `core.hooksPath`, links the main checkout's ignored `Makefile.local` into the worktree; also the `list` / `land` lifecycle tool |

`statusline.py` is not a hook: the installer wires it as `statusLine` (never over one the repo already sets). A user's own status line (`~/.claude/settings.json`) is run on the same input and the percentage appended to it, so nobody's is replaced. It shows `[Model] N% context` and records that percentage per session in `~/.claude/context-watch/` for `context-watch`. Hooks and the status line are read when a session starts: a session already running keeps the old set.

Emergency override for the stop guards: delete `.claude/.luxpm-ledger.json`, or push.
