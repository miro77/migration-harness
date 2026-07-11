# Loop Kickoff Prompt (self-paced, single session)

Paste this as one message into a fresh Claude Code session at the repo root to
run the migration unattended in ONE session. Self-paced on purpose: each tick
schedules the next when its slice is done, so work runs back-to-back until the
termination condition — no wall-clock interval.

What a tick IS — the unit of work, the idle-tick bookkeeping, the termination
condition — is defined once, in [SINGLE-TICK-PROMPT.md](SINGLE-TICK-PROMPT.md);
this prompt only adds in-session pacing. For long migrations prefer
`migration/tools/kick-loop.sh --drive`, which runs the same ticks but gives
each one a FRESH context (quality does not degrade as a session fills) and,
fired from a scheduler, survives account/usage-limit resets — see
[RESUMING.md](RESUMING.md).

**Before first run**, pre-authorize the commands each tick repeats — the harness
tools (`bash migration/tools/gates.sh`, `kick-loop.sh`, `doctor.sh`,
`check-docs.sh`) and your stack's build/test/format commands — in
`.claude/settings.json` (`permissions.allow`). A permission dialog parks an
unattended loop on every tick no matter what this prompt says; wording cannot
dismiss it, only an allow-list can.

**`/loop` availability:** the prompt below opens with `/loop`, a scheduling
skill not every Claude Code install ships. If yours reports an unknown command,
drop the leading `/loop ` token and paste the rest (the self-pacing instructions
still apply) — or use `bash migration/tools/kick-loop.sh --drive`, which needs
no in-session scheduling at all.

---

/loop Drive the <LEGACY> → <TARGET> migration until every row in
migration/parity-matrix.md is resolved AND migration/integration-ledger.md has
no open rows (see the two-axis TERMINATION in SINGLE-TICK-PROMPT.md). Read
CLAUDE.md and migration/PLAN.md first. Each tick: execute the TICK PROCEDURE, IDLE TRACKING, and TERMINATION
sections of migration/SINGLE-TICK-PROMPT.md exactly — one unit of work, fully
checkpointed to disk. That includes reading .harness/state/last-gate-failure.txt
first if it exists, and using persist-state.sh/read-state.sh for intermediate
state that should survive compaction. Ignore that file's STOP section: instead of ending
the session, schedule the next tick immediately after finishing a slice — the work
is the clock, not wall time.

Never end a turn by asking the user a question and never wait on an interactive
command — follow the AUTONOMY rule in SINGLE-TICK-PROMPT.md
(assume-record-proceed). The only clean stop is TERMINATION; if you are about to
stop for any other reason, instead select the next unfinished row, checkpoint to
disk, and schedule the next tick.

END THE LOOP when TERMINATION has written and committed migration/HANDOFF.md:
report it and stop scheduling ticks.
