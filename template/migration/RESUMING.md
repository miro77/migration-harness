# Resuming — running unattended across usage limits

The harness state lives entirely on disk (parity matrix, decisions, fixtures,
partial slice work), so a migration is always **resumable**: point a fresh
session at the repo and it continues from where it stopped. Re-running a driver
prompt ([`SINGLE-TICK-PROMPT.md`](SINGLE-TICK-PROMPT.md) or
[`LOOP-PROMPT.md`](LOOP-PROMPT.md)) resumes automatically — no special step,
because nothing important lived only in the dead session.

What an unattended run does **not** survive on its own is an
account/usage-limit stop: when the model runs out of budget mid-slice, the
process dies and does not come back by itself. The fix is an **external
scheduler** that re-kicks it — the harness supplies the resumability, the
scheduler supplies the retry and timing.

## kick-loop.sh

[`migration/tools/kick-loop.sh`](tools/kick-loop.sh) is a scheduler-friendly
driver with three modes:

- **`--drive` (recommended)** — runs one slice per **fresh headless session**,
  back-to-back, until the migration terminates. Every slice starts with an
  empty context, so model quality does not degrade as a long migration
  accumulates history; each tick reads its state from disk and checkpoints
  back to disk. Stops cleanly on the tick budget (`HARNESS_MAX_TICKS`,
  default 50 per run — set it in [`harness.env`](harness.env); an environment
  variable on the invocation overrides it; `--max N` overrides it for one
  invocation), and with exit `64` if two consecutive ticks change nothing
  without writing `HANDOFF.md`.
- **`--drive --review`** — same as `--drive`, but pauses after any tick whose
  commit is an `audited-fail` or a row-split — the human-in-the-loop gate.
  On a TTY it waits for Enter (press `s` to skip future reviews); headless it
  logs the pause and continues. Use interactively when you want to inspect
  failed slices before the loop advances.
- **`--tick`** — exactly one fresh-context slice, then return. Useful for
  cautious supervision (inspect between slices) or very tight schedules.
- **default** — one headless run of [`LOOP-PROMPT.md`](LOOP-PROMPT.md): a
  single session that self-paces through as many slices as its budget allows.

All modes share the same behavior around completion and limits:

- If the migration has terminated (it writes `migration/HANDOFF.md` on
  termination), the script no-ops. Delete `HANDOFF.md` to force another round.
- A run that hits the usage limit exits `75` and stops; the next scheduled run
  after the reset continues. A lock prevents overlapping runs from stacking.
- A run that finishes but leaves an end state needing inspection exits `65`:
  the tree is not covered by a gate proof, or (`--drive`) `HANDOFF.md` was
  written but never committed. Inspect before trusting it.

Requires the Claude Code CLI on `PATH`. `kick-loop.sh --check` reports whether
there is work to resume (`STATE: resume` / `STATE: done`) without invoking
anything — handy for a scheduler guard.

## ⚠️ The orphaned tick — read this before you ever Ctrl-C the driver

`kick-loop.sh` runs the tick as `out="$(claude -p …)"`, which forks a subshell
whose pid the driver never learns. **Kill the driver and its `claude -p` child is
ORPHANED**: it keeps writing the working tree with nobody supervising it. It will
race the next tick, race a live session, and produce work that was never gated or
audited.

This is not theoretical. On a real migration, orphans ran ~40 minutes unattended,
created scratch files in a tick's tree, `git restore`d another tick's uncommitted
claim, and wrote an `audited-pass` status for code no auditor had seen. Four
separate orphans accumulated over one session.

A bash reaper (background the child, record `$!`, trap `EXIT/INT/TERM`) was tried
and **reverted**: under MinGW, backgrounding a Windows `.exe` and `wait`-ing on it
makes the child die with **SIGTERM (143) on every start**, so the driver could not
run at all. A deterministic "won't start" is worse than a hazard that only bites
when you kill it.

**So: do not kill the driver mid-tick.** Let it finish, or bound it with `--max`.
On Windows, use the supervisor below, which reaps orphans properly. If you must
stop it by hand, kill the `claude` child too and **wait for the tree to go static
before touching anything** — then READ any uncommitted work before reverting a
byte of it. Reverting a fixture generator orphans the fixtures it produced; they
become unreproducible.

**A live agent session and the driver must never share a branch.** Both write the
tree; the session's Stop hook demands a gate-covered tree at every turn boundary
while the driver keeps it dirty for an hour. Every escape from that deadlock
damages something.

## Windows: `migration/run-loop.ps1` (recommended)

The common commands have PowerShell entry points:

```powershell
.\migration\tools\doctor.ps1
.\migration\tools\gates.ps1
.\migration\tools\kick-loop.ps1 --tick
.\test\run-all.ps1
```

These resolve Git Bash explicitly and delegate to the corresponding `.sh`
implementation, preserving its output and exit code. For a long unattended run,
use the supervisor below; it additionally owns retry policy and reaps orphaned
Windows CLI processes.

```powershell
.\migration\run-loop.ps1                          # 30 slices, 10 per batch
.\migration\run-loop.ps1 -MaxSlices 5 -Batch 5
.\migration\run-loop.ps1 -LimitWaitMin 45 -Review
```

A PowerShell supervisor around `kick-loop.sh --drive`. PowerShell can track a
Windows process tree, so it fixes what bash on MinGW cannot:

- **Reaps orphaned ticks** — before the run, after every batch, and in a `finally`
  block, so even Ctrl-C cannot leak one. It passes a repo-marked tick prompt and
  matches that marker, never a bare `-p`, so it can kill neither your interactive
  session nor an unrelated headless `claude -p` of your own.
- **Resolves Git Bash explicitly.** `bash` on a Windows PATH is usually
  `C:\Windows\system32\bash.exe` (WSL), which cannot see `claude.exe` and reports
  *"the 'claude' CLI must be on PATH"* — a misdiagnosis. It refuses any shell whose
  `uname` is not MINGW/MSYS, and checks that claude is visible **to that shell**,
  which is the check that actually matters.
- **Refuses to start on a dirty tree** (unless `-Force`). An uncommitted scoped
  change is indistinguishable from a rogue writer.
- **Retries only what is safe to retry.** A usage limit (75) is a *pause* — it waits
  and resumes. A crash on a **clean** tree is transient — bounded backoff. A crash
  on a **dirty** tree, or the loop's own `10`/`20`/`64`/`65`/`70` signals, **stop for
  a human**: re-running compounds the damage.

⚠️ It is a **launcher, not a gate**. It lives outside `migration/tools/`, so an agent
can edit it — it is not a trust boundary. `gates.sh`, the Stop hook and the proof
are `HARNESS_LOCKED` and run unchanged; the supervisor only decides *when* to invoke
the driver. Move it into `migration/tools/` yourself if you want it locked too.

**After ANY hand-edit or `git apply` under a scoped path — gate and commit before
starting the driver.** An uncommitted scoped change looks exactly like a rogue
writer, and will abort the tick you just started.

## Scheduling it

The reset time of a weekly cap is account-specific, so schedule at (or shortly
after) it, and/or on a modest interval — an idempotent re-kick is safe to fire
repeatedly.

**Linux/macOS (cron)** — every 30 minutes:

```
*/30 * * * * cd /path/to/repo && bash migration/tools/kick-loop.sh --drive >> .harness/kick-loop.log 2>&1
```

**Windows (Task Scheduler)** — daily at 03:10. Use the PowerShell supervisor and
set the working directory explicitly; Task Scheduler otherwise starts it under
`C:\Windows\System32`, outside the repository:

```powershell
$repo = 'C:\path\to\repo'
$action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$repo\migration\run-loop.ps1`"" `
  -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Daily -At '03:10'
Register-ScheduledTask -TaskName 'migrate-resume' -Action $action -Trigger $trigger
```

**Cloud routine** — if the repo is on GitHub, schedule a cloud agent for just
after the reset that pulls, runs `kick-loop.sh --drive`, and pushes. No local
machine required — BUT the runner must have a **persistent workspace/volume**
(or archive-and-restore the working tree between invocations). "State lives on
disk" includes the parts a push does NOT carry: uncommitted mid-slice work
after a usage-limit interruption, and the local `.harness/` state
(`last-gate-failure.txt`, idle-ticks, slice-state, the gate proof, and the
append-only `runs.ndjson` lifecycle journal). An
ephemeral runner that only `git pull`s silently discards all of that — the
next tick re-does or, worse, half-trusts lost work. If a persistent workspace
is impossible, at minimum `tar` the worktree + `.harness/` to durable storage
at the end of each invocation and restore it at the start of the next.

Stop the schedule when a run exits with a terminal state — 0 (COMPLETE),
10 (BLOCKED), or 20 (FAILED); `kick-loop.sh --check` prints it any time
(`STATE: done:COMPLETE` etc.). Exit 70 means `--review` wants a human to look
before the loop continues.
