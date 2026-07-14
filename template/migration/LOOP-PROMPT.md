# Loop Kickoff Prompt (self-paced, single session)

Paste this as one message into a fresh Claude Code session at the repo root to
run the migration unattended in ONE session. Self-paced on purpose: each tick
schedules the next when its slice is done, so work runs back-to-back until the
termination condition — no wall-clock interval.

What a tick IS — the unit of work, the idle-tick bookkeeping, the termination
condition — is defined once, in [SINGLE-TICK-PROMPT.md](SINGLE-TICK-PROMPT.md);
this prompt only adds in-session pacing and the delegation wrapper below.

**Prefer `migration/tools/kick-loop.sh --drive` when you can.** It runs the same
ticks but gives each one a genuinely fresh process, and — fired from a scheduler
— survives account/usage-limit resets (see [RESUMING.md](RESUMING.md)). This
prompt exists for when you have no scheduler.

## Why this prompt delegates every tick to a subagent

`/loop` does **not** reset context between iterations. Every tick is a new turn
in the *same* conversation, so an inline tick pours its legacy reads, fixture
dumps, audit rounds and gate logs into a context that only grows. Eventually
compaction starts summarizing that history away — and compaction cannot know
that a fixture's exact value is load-bearing while the prose around it is not.
Left alone, tick #30 runs on the compacted residue of the previous 29, which is
the exact "quality degrades as a session fills" failure `--drive` exists to
avoid.

So the tick body here is **orchestration only**. Each tick spawns ONE subagent
to do the work and returns a summary. That buys the same property `--drive`
buys: **every tick gets a full, fresh context window**, instead of whatever is
left over. The loop's own context grows by a few lines per tick, not by a
transcript.

This works only because the harness already resumes from disk — the status
board, `decisions.md`, `HANDOFF.md` and the gate proofs are the memory between
ticks, not the conversation. Two consequences to accept up front:

- **A tick agent knows only what is written down.** Conventions it needs belong
  in `CLAUDE.md` / `PLAN.md` / `decisions.md`. If ticks keep rediscovering the
  same fact, write it down — do not inline the work again.
- **Delegation moves the context limit, it does not abolish it.** A large slice
  can still fill the *subagent's* window. That is fine: a slice is a bounded
  unit, and a fresh window is the most budget you can give it. If a slice
  reliably exhausts one, the slice is too big — split the row.

**Before first run**, pre-authorize the commands each tick repeats — the harness
tools (`bash migration/tools/gates.sh`, `kick-loop.sh`, `doctor.sh`,
`check-docs.sh`) and your stack's build/test/format commands — in
`.claude/settings.json` (`permissions.allow`). A permission dialog parks an
unattended loop on every tick no matter what this prompt says; wording cannot
dismiss it, only an allow-list can. **Subagents inherit the same allow-list**, so
a gap parks a delegated tick just as hard.

**`/loop` availability:** the prompt below opens with `/loop`, a scheduling
skill not every Claude Code install ships. If yours reports an unknown command,
drop the leading `/loop ` token and paste the rest (the self-pacing instructions
still apply) — or use `bash migration/tools/kick-loop.sh --drive`, which needs
no in-session scheduling at all.

---

/loop Drive the <LEGACY> → <TARGET> migration until every row in
migration/parity-matrix.md is resolved AND migration/integration-ledger.md has
no open rows (see the two-axis TERMINATION in SINGLE-TICK-PROMPT.md). Read
CLAUDE.md and migration/PLAN.md first.

You are the ORCHESTRATOR, not the implementer. Each tick delegates ONE unit of
work to ONE subagent. Do not read legacy source, write target code, generate
fixtures, or run gates in this conversation — that is the subagent's job, and
doing it here fills the context this delegation exists to protect.

Each tick:

1. **CONCURRENT-WRITER CHECK — before anything else, and this one is yours, not
   the subagent's.** Run step 0 of SINGLE-TICK-PROMPT.md: `git log`, `git
   status`, the driver lock (`.harness/kick-loop.lock`), and snapshot the scoped
   tree with `bash migration/tools/working-tree-hash.sh`.

   A dirty tree you did not create is a SIGNAL, NOT MESS TO TIDY. Read it before
   you touch it: an uncommitted status-board row set to `in-progress` is a live
   claim from another writer, not a stale marker — the code behind it may simply
   not be written yet. Reverting it, or "cleaning up" the tree, destroys work in
   flight. (This has really happened, in both directions.)

   **NEVER SPAWN A SUBAGENT INTO A CONTESTED TREE** — a `git checkout` or gate
   run from the other writer will corrupt the subagent mid-slice, and your own
   gate run can make *their* slice fail spuriously. If the tree is contested:
   write HANDOFF.md naming the other writer, and STOP. Do not schedule another
   tick.

2. **Pick the unit.** Read HARNESS_PROFILE from migration/harness.env (default:
   migration) to select the status board and slice command — migration:
   migration/parity-matrix.md + /migrate-slice; feature: migration/spec-matrix.md
   + /feature-slice. If the bootstrap row (B01 / S00) is not audited-pass, the
   unit is Phase 0 of migration/PLAN.md. Otherwise select the next row exactly as
   SINGLE-TICK-PROMPT.md step 2 does. Also read `.harness/state/last-gate-failure.txt`
   if it exists — the previous tick's gate failure is the first thing the next
   subagent must fix.

   Name the row id explicitly, and **copy the row's text into the spawn prompt**.
   Status-board rows run to kilobytes; making a cold subagent scan the whole
   board to find one row is pure overhead you can pay once, here.

3. **Delegate the tick.** Spawn ONE general-purpose subagent, roughly:

   > Execute the TICK PROCEDURE of migration/SINGLE-TICK-PROMPT.md for row
   > <ROW-ID>, following CLAUDE.md and every step of <SLICE-COMMAND> <ROW-ID>.
   > Skip step 0 (the concurrent-writer check) — it has already passed; the tree
   > is yours alone. The row reads: <PASTE ROW TEXT>. Prior gate failure to fix
   > first, if any: <PASTE last-gate-failure.txt>.
   >
   > You own the whole slice: claim the row, spawn the analyst agent for evidence,
   > fixtures/reference captures first, implement in the row's target path only,
   > run `bash migration/tools/gates.sh`, spawn the fresh-context auditor (it must
   > not be you) to audit, repair blockers, re-gate so the recorded proof covers
   > the exact tree you commit, update the row, and make the single commit. Leave
   > the tree CLEAN — commit audited-fail states too. Follow the AUTONOMY rule:
   > never ask a question, record assumptions in decisions.md as `status: assumed`
   > and proceed.
   >
   > Report back ONLY: row id, final status, commit sha, files changed, and any
   > blocker or recorded assumption. Do NOT paste code, diffs, fixture contents,
   > legacy source, or gate logs into your report.

   The analyst and auditor stay the tick agent's own children — both are fresh
   contexts, and the auditor still did not write the code, so the audit rule holds.

4. **VERIFY FROM DISK — a subagent's report is a claim, not proof.** Before
   accepting the tick: `git status --short` is clean; the last commit is the
   expected `<id>: <status>` subject; the status-board row shows that status; and
   re-run `bash migration/tools/working-tree-hash.sh` — if files you and the
   subagent did not touch changed, a second writer appeared mid-tick, so treat it
   as step 1 and STOP.

   If the tree is dirty, no commit exists, or the row is untouched, the tick did
   NOT land: leave the row as the unfinished work it is and let the next tick pick
   it up. NEVER edit the status board here to make a failed tick look successful —
   the status field is the one thing downstream ticks trust without re-checking.

5. **Idle tracking and termination** exactly as SINGLE-TICK-PROMPT.md defines
   (`.harness/state/idle-ticks`, the two-axis TERMINATION, `check-complete.sh`).

Keep the loop's own context thin: carry forward the row id, status and sha —
nothing else. If you catch yourself reading engine source or gate output in this
conversation, you have taken the subagent's job.

AUTONOMY — never end a turn by asking the user a question, and never wait on an
interactive command; follow the AUTONOMY rule in SINGLE-TICK-PROMPT.md
(assume-record-proceed), and state it in the spawn prompt so the subagent obeys it
too. A subagent that dies, returns nothing, or reports an unusable result is a
FAILED TICK, not a reason to stop: re-read the board, checkpoint what is true on
disk, and schedule the next tick. If the SAME row fails to land twice running,
record it audited-fail with the reason, commit that, and move on — do not grind
one row forever. Apart from TERMINATION and a contested tree (step 1), there is no
clean stop: select the next unfinished row, checkpoint, schedule the next tick.

END THE LOOP when TERMINATION has written and committed migration/HANDOFF.md
and `bash migration/tools/check-complete.sh` accepts it (it prints STATUS:
COMPLETE, BLOCKED, or FAILED): report that terminal state and stop scheduling
ticks.
