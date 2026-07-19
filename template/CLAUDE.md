# <PROJECT> — <LEGACY STACK> → <TARGET STACK> Migration

This repository contains the legacy <LEGACY> application (`<legacy-paths>`)
and the in-progress migration to <TARGET>. The migration is driven
slice-by-slice via `/migrate-slice` — unattended via fresh-context ticks
(`migration/tools/kick-loop.sh --drive`, tick defined in
[`migration/SINGLE-TICK-PROMPT.md`](migration/SINGLE-TICK-PROMPT.md)) or the
self-paced single-session loop in
[`migration/LOOP-PROMPT.md`](migration/LOOP-PROMPT.md).

## Repository layout

| Path | Role |
|---|---|
| `<legacy-paths>` | **Legacy. FROZEN.** Read-only oracle. Never edit (hook-enforced via `HARNESS_FROZEN`). |
| [`probes/`](probes/) | Fixture generator (the ONLY new legacy-stack code allowed). Runs legacy code and dumps input→output vectors as JSON. |
| [`migration/`](migration/) | Plan, inventory, parity matrix, decisions, fixtures, tools, config. |
| `<target-paths>` | The new implementation. |
| [`.claude/`](.claude/) | Commands, agents, enforcement hooks. |

> **In-place migration?** If you transform the existing code in place (remove a
> dependency, swap a stdlib) rather than build a new tree, there is no separate
> frozen legacy: leave `HARNESS_FROZEN` empty in
> [`migration/harness.env`](migration/harness.env) (unless the repo vendors the
> old dependency's own sources — freeze those as the semantics oracle), edit the
> existing tree directly, and capture fixtures from the pre-change code (a probe
> run at the base commit). Work tests-first: a unit gets a T-row (tests pinning
> current behavior + a committed baseline snapshot) before its M-row (the edit).
> The table above shows the freeze-and-replace shape — adjust it to your tree.
> Full playbook: the harness repo's `docs/IN-PLACE-PROFILE.md`.

## Target architecture

<Describe the target architecture: module boundaries, what is pure/testable,
where UI lives, where computation lives, any layering rules. All observable
values should trace back to the migrated core, never re-derived in the UI.>

## Gates — run before claiming ANY slice done

```
bash migration/tools/gates.sh
```

This runs format-check, static analysis, and the FULL test suite (including
parity fixtures), then records a content-hash proof in `.harness/state/`. The
Stop hook blocks ending a turn with migration changes and no recorded gate
run for the exact current tree. **No success claim without a gate run. Never
cite a gate that wasn't executed.**

The test suite runs on a DEV runtime, which is not the artifact users get. Wire
your app's production compile into the `HARNESS:SHIP-BUILD` block of `gates.sh`
(e.g. `flutter build web --wasm`, `npm run build`, `cargo build --release`) so
the proof covers the shipped target — a compile that fails only for the ship
backend is invisible to `flutter test` / `pytest`. Separately, if anything
resolves your SOURCE by path (a browser loading modules by URL, a bundler
resolving by extension/alias, a downstream package), wire that consumer's build
into the `HARNESS:CONSUMER-BUILD` block — the behavior tests do not prove the
consumer still resolves after a rename. See the Phase-0 consumer-resolution
survey in [`migration/PLAN.md`](migration/PLAN.md).

Fidelity is not completeness. A slice can be `audited-pass` (a faithful port) and
still ship its feature wired to nothing, surfacing a "not implemented" stub the
per-slice audit never sees. Track that separately in
[`migration/integration-ledger.md`](migration/integration-ledger.md): the matrix
is the fidelity axis, the ledger is the reachability axis, and the migration is
done only when BOTH are clear (see hard rule 11).

## Enforcement threat model — what the hooks do and don't do

The normal control is the **content-addressed proof**: a turn may only end when
the scoped tree hashes to a recorded successful gate run. A commit does not
launder un-gated changes, and neither does deleting a scoped path. That, plus the
git-visible audit trail and the fresh-context `parity-auditor`, is what makes a
cooperating agent's "done" claim trustworthy. It is not a sandbox: an agent that
directly forges `.harness/state/gates-passed.diffsha` or weakens `gates.sh` can
lie to the Stop hook. The command/path hooks block the obvious route to that,
but CI or human review is the adversarial backstop.

> **Hardening the backstop (optional).** The residual above is that the checker
> runs in the same environment the agent can write. The stronger boundary is to
> run the verification from a context the agent never touched: your CI already
> does this (it re-runs `gates.sh` from a clean checkout on every push). For a
> local equivalent, run the read-only integrity checks — `check-frozen`,
> `check-locked`, `check-audits`, `check-complete`, `check-docs`,
> `check-adr-immutable`, `check-rule-refs` — inside a pinned, network-isolated,
> read-only container (e.g. `docker run --rm --network none -v "$PWD:/repo:ro"`),
> so the checker the agent is judged by cannot be the one it may have edited.
> Only the read-only checks fit that mould; the build/test gates need write
> access (and usually network). This is defense-in-depth, not a new requirement.

The frozen oracle gets the same treatment, and for the same reason. The PreToolUse
hooks block the *actions* that would edit it — but action interception is
bypassable by construction (a subagent whose calls never fire the parent's hooks,
an interpreter write, a path spelled to miss a substring match). So
`migration/tools/check-frozen.sh` runs inside `gates.sh` and checks the *outcome*:
it rebuilds the frozen fileset's content hash and compares it against the
committed baseline in `migration/frozen-baseline.sha`. Any drift — an edit, an
added file, a deletion, by any tool, committed or not — fails the gate. A human
records that baseline once during bootstrap; the agent is blocked from
`--record`ing it, because an agent that can move the reference can launder any
drift it caused. **If the oracle can move, parity means nothing.**

The PreToolUse hooks (frozen-legacy, command-guard) are **guard rails that keep an
honest agent on the supported path — not an adversarial sandbox.** They match on
command/path strings, which a determined process can obfuscate (variable
indirection, interpreters, `cd` + relative paths). Do not treat them as a security
boundary. Note that "mutation" includes **deletion**: an enforcement file that is
not on disk does not run, so `rm`, `git rm`, `git checkout --`, `git restore` and
`chmod` on a locked path are blocked exactly like a write. Two consequences you
must respect rather than route around:

- The harness's own enforcement files — `migration/tools/`, `.claude/hooks/`,
  `.claude/settings*.json`, `migration/harness.env` — are **locked**
  (`HARNESS_LOCKED`). Never weaken your own gates: editing `gates.sh` to a no-op
  and then recording a "pass" is the exact bypass these locks exist to stop.
  Like the frozen oracle, these files can be given a committed integrity baseline:
  a human runs `bash migration/tools/check-locked.sh --record` once during
  bootstrap, and `gates.sh` then hashes the locked fileset against
  `migration/locked-baseline.sha` on every run — so a bypass of the action guard
  (an interpreter write, a subagent, an odd path spelling) that mutates a gate is
  caught at the next gate, not silently trusted. It is opt-in by presence (absent
  baseline = action-guard only, today's behavior); `doctor.sh` reports whether it
  is recorded. If a gate genuinely
  needs to change (e.g. a missing consumer-build check), do NOT route around the
  lock and do NOT leave it as an ad-hoc note: record the exact proposed edit in
  [`migration/PROPOSED-GATE-CHANGES.md`](migration/PROPOSED-GATE-CHANGES.md)
  (not locked), which `doctor.sh` surfaces and `HANDOFF.md` must list. A human
  applies it and re-gates outside the agent session. The migration is not done
  while an open proposal remains — the proof only covers gates that actually ran.
- If the hash tool is broken/missing, the Stop hook now fails **closed** (challenges
  once). A red or missing tool means stop and fix it, not proceed.
- The Stop hook challenges once per turn-end and releases on the automatic
  retry (anti-wedge). If a slice is legitimately blocked on long-running
  background work (a compile, a browser test run) that would race the gate
  suite's build directories, that challenge-then-release is the designed path:
  let the background step finish, then gate BEFORE the slice commit. Never run
  gates concurrently with a build sharing the same build dirs, and never treat
  the release as permission to skip the gate on the final tree. This
  wait-for-background pattern assumes an INTERACTIVE session (one that resumes
  when background work completes). A headless `--drive` tick or a delegated
  subagent has no later turn: it must run the gate to completion within the
  turn — see the AUTONOMY rules in
  [`migration/SINGLE-TICK-PROMPT.md`](migration/SINGLE-TICK-PROMPT.md).
- The recorded-checkpoint escape is narrow: the subject must be
  `migrate <id>: audited-fail...` or `migrate <id>: split into sub-slices...`
  (the hook also accepts the feature profile's `feat <id>: ...` spelling),
  the parent tree must match the last gate proof, and the checkpoint commit may
  touch only migration bookkeeping. It exists so a row can be recorded honestly
  without pretending the current tree is gated. Treat every `audited-fail`
  commit as needing human review (`kick-loop.sh --drive --review` pauses there),
  never as gated work.

## Within-slice controls — observability, budget, loop detection

Beyond the between-slice boundaries (gates, proof, auditor), the harness has
three PostToolUse controls that operate **inside** a single tick:

- **Observability** — every tool call is logged as structured JSON to
  `.harness/state/telemetry.ndjson` (timestamp, run/session ID, tool name,
  argument fingerprint). `kick-loop.sh` records each attempt's lifecycle and
  classified outcome in `.harness/state/runs.ndjson`; the shared `run_id`
  correlates both logs. This is the within-slice audit trail: what the model
  did, in what order, and how often. Inspect it after a run to understand
  failure patterns or cost.
- **Call budget** — `HARNESS_MAX_CALLS_PER_TICK` (default 200) caps tool calls
  per session. When exceeded, a wrap-up warning is injected (not a hard kill —
  the model self-corrects). In `--drive` mode each tick is a fresh session, so
  this is effectively per-tick. Set to 0 to disable. The count covers EVERY
  tool call in the session, including those made by subagents — a read-heavy
  parity audit shares the tick's budget, and the wrap-up nudge can land in the
  auditor's context (it is told to finish its report, not to end the tick).
- **Loop detection** — `HARNESS_LOOP_THRESHOLD` (default 3) in a
  `HARNESS_LOOP_WINDOW` (default 6) sliding window. If the same tool+args
  fingerprint repeats, a reconsideration prompt is injected telling the model
  to change approach. Set threshold to 0 to disable.

These are "inject, don't kill": the hook never blocks a tool result. The model
gets a nudge and decides what to do. A hard stop is the tick budget
(`HARNESS_MAX_TICKS`, set in `migration/harness.env` like the other knobs; an
environment variable on the kick-loop invocation overrides it) and the
idle-tick backstop — both at the driver level.

## Gate-failure feedback — the next tick sees why the last one failed

When `gates.sh` fails, it writes the exact diagnostic (test output, lint errors)
to `.harness/state/last-gate-failure.txt`. The next fresh-context tick reads this
file first (see `SINGLE-TICK-PROMPT.md`) so a retry addresses the actual failure
rather than repeating the same mistake in a fresh context with no memory of why
it failed. The file is cleared on a successful gate run.

## Working state — the virtual filesystem for intermediate results

For multi-step work that should survive context compaction, persist intermediate
state with:
```
echo '<state json>' | bash migration/tools/persist-state.sh <key>
bash migration/tools/read-state.sh <key>
```
State lives in `.harness/state/slice-state/` (local, not committed). This is the
analogue of a database transaction log for within-slice progress. The committed
state lives in the parity matrix and `HANDOFF.md`; this is for working memory that
bridges compaction boundaries.

## Hard rules

1. Legacy source listed in `HARNESS_FROZEN` ([`migration/harness.env`](migration/harness.env))
   is frozen (hook-enforced); probes/adapters go in `probes/`. In an in-place
   migration `HARNESS_FROZEN` is empty and you edit the existing tree directly —
   the oracle is the captured fixtures, not frozen source.
2. One slice per pass. No cross-feature rewrites. Splitting an oversized
   matrix row into sub-rows counts as a full unit of work.
3. Preserve legacy behavior exactly unless [`migration/parity-matrix.md`](migration/parity-matrix.md)
   records an intentional deviation. The deviation list is exhaustive:
   anything not listed is a bug.
4. Numeric parity is exact where the legacy code is deterministic:
   reimplement any legacy RNG (e.g. an LCG) so seeded fixture runs match
   bit-for-bit. Statistical "close enough" comparison is forbidden.
5. <Platform/runtime constraints for the target stack. New dependencies must
   be recorded in [`migration/decisions.md`](migration/decisions.md) as an ADR BEFORE editing the
   manifest.>
6. <Concurrency/performance constraints, if any.>
7. No skipped/excluded tests, no inline lint suppressions without a justified,
   recorded entry.
8. `git mv` (renames) and content changes go in separate commits (so rename
   detection stays clean).
9. Every slice ends with `migration/parity-matrix.md` updated and one commit:
   `migrate ID: STATUS` (e.g. `migrate F03: audited-pass`). Never leave the
   tree dirty between slices — commit `audited-fail` states too.
10. Parity audits are performed by a fresh-context subagent (`parity-auditor`)
    that did not write the code. The auditor records its verdict itself
    (`migration/tools/record-audit.sh`), and `gates.sh` refuses to let a row be
    marked `audited-pass` without a matching record for the code currently in
    the tree — so the status cannot be written before the audit returns, and a
    code change after the audit invalidates it. Never record a verdict on the
    auditor's behalf.
11. A user-facing feature is not done until it is REACHABLE in the running app.
    When a slice ships a feature without wiring its entry point, or leaves a
    runtime stub, record it in [`migration/integration-ledger.md`](migration/integration-ledger.md)
    and ensure a matrix row will wire it. The migration cannot terminate
    COMPLETE while that ledger holds an open
    (`built-unwired`/`stub`/`deferred-impl`) row — an idle-backstop stop with
    open rows is at best BLOCKED.

## Definition of done (per slice)

Gates pass on the current tree (including the shipped-target build and the
stub-registration check), fresh-context audit reports no blockers (or blockers
are recorded as `audited-fail` in the matrix), matrix row updated, the
integration ledger updated (any feature shipped unwired or stubbed is recorded;
any feature this slice wired is flipped to `wired`), single commit created.

## Resumability — checkpoint to disk

The harness resumes from disk, not from the conversation. Checkpoint slice
progress as you go — update the [`migration/parity-matrix.md`](migration/parity-matrix.md)
row and a worklog (or `migration/HANDOFF.md`) — so a fresh session, or the
context after compaction, continues cleanly. Never hold un-saved migration state
only in context. A PreCompact hook fires when the conversation is about to be
summarized: when it reminds you, flush to disk before proceeding.
