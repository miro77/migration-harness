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
  variable on the invocation overrides it), and with exit `64` if two
  consecutive ticks change nothing without writing `HANDOFF.md`.
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

## Scheduling it

The reset time of a weekly cap is account-specific, so schedule at (or shortly
after) it, and/or on a modest interval — an idempotent re-kick is safe to fire
repeatedly.

**Linux/macOS (cron)** — every 30 minutes:

```
*/30 * * * * cd /path/to/repo && bash migration/tools/kick-loop.sh --drive >> .harness/kick-loop.log 2>&1
```

**Windows (Task Scheduler)** — daily at 03:10. Two traps here: plain `bash`
often resolves to `C:\Windows\System32\bash.exe` (the WSL launcher), which
fails if no WSL distro is installed — use the **full Git Bash path**. And a
bare `bin\bash.exe` starts WITHOUT `/usr/bin` on `PATH` (`cat`, `grep`,
`find`, `touch` all missing, so the script dies before reaching Claude) — pass
`-l` so a login shell sets the PATH up first:

```
schtasks /Create /TN migrate-resume /SC DAILY /ST 03:10 /TR ^
  "\"C:\Program Files\Git\bin\bash.exe\" -lc 'cd /c/path/to/repo && bash migration/tools/kick-loop.sh --drive >> .harness/kick-loop.log 2>&1'"
```

**Cloud routine** — if the repo is on GitHub, schedule a cloud agent for just
after the reset that pulls, runs `kick-loop.sh --drive`, and pushes. No local
machine required.

Stop the schedule once `HANDOFF.md` shows the migration has terminated.
