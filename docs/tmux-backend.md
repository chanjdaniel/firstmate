# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Worktree-path discovery: two races, multiple defenses

tmux is a session provider only, so [treehouse](https://github.com/kunchenguid/treehouse) still owns the worktree: `bin/fm-spawn.sh` runs `treehouse get` inside the new window and then polls that pane's cwd through `fm_backend_tmux_current_path` until it moves off the project clone.

Two independent races can cause the discovery poll to read a bogus path:

### Race 1: a bad `display-message` target falls back to the active window

`tmux display-message -p -t <target> '#{pane_current_path}'` does not fail when `<target>` does not resolve.
It silently falls back to the ACTIVE client's window, prints that pane's path, and exits 0.
For the discovery poll that is a dangerous answer rather than an error - if the target were lost, the poll could accept firstmate's own pane path (the active window, since firstmate is the one driving tmux) as the crewmate's worktree, and the task's `worktree=` meta, turn-end hook, and harness exclude-path lines would all be written into the primary checkout.

### Race 2: a freshly created window reports the tmux server's cwd before its shell settles

`tmux new-window ... -c <project-dir>` creates a window whose shell will `chdir` into `<project-dir>`, but the window's first `#{pane_current_path}` read can report the TMUX SERVER's own cwd (firstmate's repo root) instead, before the shell has entered the `-c` directory.
This path differs from `PROJ_ABS_REAL` (so a naive "has the pane left the project?" poll accepts it immediately), yet the window id is CORRECT the whole time (so race #1's window-id guard does not fire).
Without further defenses the poll locks onto firstmate's own repo as the worktree, with all the same consequences.

### Defenses

Five defenses close both races, and they are independent on purpose:

- **Target verification in the read itself** (race #1 only).
  `fm_backend_tmux_current_path` takes an optional second argument, the expected window id.
  When it is supplied, the adapter reads `'#{window_id} #{pane_current_path}'` in ONE `display-message` call and checks that the window which answered is the window that was asked; a mismatch returns empty and exits non-zero instead of a plausible wrong path.
  Called with one argument it behaves exactly as before, so callers that do not know a window id are unaffected.
  This catches race #1 but not race #2 (the window id is correct in both cases).
- **No target to lose.** `fm_backend_tmux_create_task` and `fm-spawn.sh` both treat an empty window id from `tmux new-window -dP -F '#{window_id}'` as fatal.
  The adapter kills the just-created window first - it exists even when its id was not printed, and would otherwise trip the duplicate-name check when the same task id is retried - then fails.
  The spawn aborts rather than degrading from the stable window id to the rename-fragile `<session>:<window-name>` target form.
- **Repository identity in the poll itself** (race #2, and defense-in-depth for race #1).
  Before accepting a candidate path, the poll loop verifies it is the ROOT of a git worktree belonging to the same repository as the project clone (`git rev-parse --git-common-dir` equality, anchored as below).
  A transient pre-chdir path (the tmux server's cwd) is not a worktree root of the project, so the poll rejects it and keeps waiting.
  There is no early-accept for a path that stays wrong: any such shortcut would need a timing assumption about how long the pre-chdir window lasts, which is exactly the assumption that produced race #2.
  A permanently wrong path therefore just runs the poll budget out (60s by default; `FM_SPAWN_WORKTREE_TIMEOUT` overrides it with a positive integer number of seconds, and tests set it low to keep refusal cases fast), and the timeout error names the last candidate path and why it was rejected so the failure is diagnosable without a live pane.
- **Repository identity is anchored at the working-tree root, on both sides of the comparison** (the condition that makes every identity check sound).
  `git rev-parse` walks UP the tree, so a directory that is not a working-tree root of its own reports the identity of whatever repository ENCLOSES it.
  `git_worktree_common_dir_real` reports an identity only when the directory it is asked about is itself the ROOT of a git working tree, and empty otherwise, which is what distinguishes "a different repository" from "no repository" and "somewhere inside a repository".
  It anchors the check in both directions:
    - The **project** side: projects live at `$FM_HOME/projects/<name>`, inside firstmate's own repo by construction, so a project directory that is not a git repo (an interrupted clone, a hand-made directory) would otherwise be handed firstmate's OWN repository identity, and a pre-chdir read of firstmate's repo root would then match "the project's repository" and sail through both the poll and the backstop.
      Such a project has no identity at all, so nothing can be verified as a worktree of it; `fm-spawn.sh` refuses the spawn before the first pane read, naming the malformed project directory rather than blaming whatever path the pane happened to report.
    - The **candidate** side: a pane path INSIDE the clone or one of its worktrees (a subdirectory the tmux server's cwd happened to sit in) would otherwise report the project's own repository, be accepted, and lock the poll onto a transient path - turning race #2 into a spurious isolation abort instead of a tangle, and failing every spawn for that project.
      Only a worktree ROOT of the project's repository is accepted; anything below one keeps the loop polling and is named in the timeout diagnostic.
- **Repository identity as the final backstop.** `fm-spawn.sh`'s `validate_spawn_worktree` requires the discovered worktree to belong to the project's own repository.
  A path belonging to a different one - firstmate's own repo or home, or another clone - aborts the spawn loudly instead of being recorded (see [`architecture.md`](architecture.md), "Worktrees, not branches in your checkout").
  This is the safety net that caught race #2 before the poll-level fix; it now serves as defense-in-depth for both races.

`tests/fm-tangle-guard.test.sh` pins the defenses hermetically: the two-field target verification against matching and mismatched window ids, the empty-window-id spawn abort, the refusal of a worktree that resolves into firstmate's own repo while a pooled worktree of the project is still accepted, the poll's rejection of a transient non-worktree path on the first read, and the refusal of a spawn whose non-repo project directory sits inside firstmate's own repo (the identity-inheritance case above, in the production `projects/`-inside-`FM_ROOT` layout).

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
