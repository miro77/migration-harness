# <PROJECT> — <FEATURE NAME>

This repository is building <FEATURE NAME>: <one line - what it does and for
whom>. The work is driven slice-by-slice - unattended via fresh-context ticks
(`migration/tools/kick-loop.sh --drive`, tick defined in
[`migration/SINGLE-TICK-PROMPT.md`](migration/SINGLE-TICK-PROMPT.md)) or the
self-paced single-session loop in
[`migration/LOOP-PROMPT.md`](migration/LOOP-PROMPT.md).

> **Feature profile.** This is the harness's *feature* profile: the same
> enforcement engine as a migration (gate proof + Stop hook + locked gates +
> fresh-context audit), but the oracle is the **written spec** in
> [`migration/spec-matrix.md`](migration/spec-matrix.md), not captured legacy
> behavior. There is no frozen legacy - `HARNESS_FROZEN` is empty. See
> `docs/FEATURE-PROFILE.md` in the harness repo for the full mapping.

## Repository layout

| Path | Role |
|---|---|
| `<source-paths>` | The code you edit to build the feature. |
| [`migration/spec-matrix.md`](migration/spec-matrix.md) | The spec: acceptance criteria + their tests. The status board. |
| [`migration/`](migration/) | Plan, decisions, tools, config. |
| [`.claude/`](.claude/) | Commands, agents, enforcement hooks. |

## Target architecture

<Describe where the feature's logic lives: module boundaries, what is
pure/testable vs I/O, where UI lives, any layering rules. Observable behavior
should be driven by testable units, not buried in glue.>

## Gates — run before claiming ANY slice done

```
bash migration/tools/gates.sh
```

This runs format-check, static analysis, and the FULL test suite (the new
acceptance tests AND the existing suite as a regression guard), then records a
content-hash proof in `.harness/state/`. The Stop hook blocks ending a turn with
scoped changes and no recorded gate run for the exact current tree. **No success
claim without a gate run. Never cite a gate that wasn't executed.**

## Enforcement threat model — what the hooks do and don't do

The real control is the **content-addressed proof**: a turn may only end when the
scoped tree hashes to a recorded successful gate run. A commit does not launder
un-gated changes, and neither does deleting a scoped path. That, plus the
git-visible audit trail and the fresh-context `spec-auditor`, is what makes a
"done" claim trustworthy.

The PreToolUse hooks (frozen-legacy, command-guard) are **guard rails that keep an
honest agent on the supported path — not an adversarial sandbox.** They match on
command/path strings, which a determined process can obfuscate. Do not treat them
as a security boundary. Two consequences you must respect rather than route around:

- The harness's own enforcement files — `migration/tools/`, `.claude/hooks/`,
  `.claude/settings*.json`, `migration/harness.env` — are **locked**
  (`HARNESS_LOCKED`). Never weaken your own gates: editing `gates.sh` to a no-op
  and then recording a "pass" is the exact bypass these locks exist to stop. If a
  gate genuinely needs to change, a human edits it outside the agent session.
- If the hash tool is broken/missing, the Stop hook fails **closed** (challenges
  once). A red or missing tool means stop and fix it, not proceed.
- The recorded-checkpoint escape (a clean commit whose subject contains
  `audited-fail` or `split into sub-slices`) is the one way a turn ends
  WITHOUT a gate proof for the current tree. That is deliberate — anti-wedge,
  and git-visible — but it makes those commits the **un-audited trust
  boundary**: treat every `audited-fail` commit as needing human review
  (`kick-loop.sh --drive --review` pauses exactly there), never as gated work.

## Hard rules

1. The **spec is the oracle**: every criterion in
   [`migration/spec-matrix.md`](migration/spec-matrix.md) is met by a real,
   executable acceptance test that would fail on wrong behavior. A criterion
   with no such test is not done.
2. One slice per pass. No cross-cutting rewrites. Splitting an oversized
   criterion into sub-rows counts as a full unit of work.
3. **Scope is the matrix.** Implement only the listed criteria. Behavior beyond
   them is a separate decision - add a row, or an ADR in
   [`migration/decisions.md`](migration/decisions.md) - never a silent add.
4. **No regression.** The full existing test suite stays green on every slice;
   the feature adds behavior without breaking what exists.
5. Tests must be honest: they exercise real behavior, not mocks asserting
   themselves, tautologies, or snapshots that lock in whatever was produced. No
   skipped/filtered cases without a justified, recorded entry.
6. <Platform/runtime constraints for the stack. New dependencies must be recorded
   in [`migration/decisions.md`](migration/decisions.md) as an ADR BEFORE editing
   the manifest.>
7. No inline lint suppressions without a justified, recorded entry.
8. `git mv` (renames) and content changes go in separate commits (so rename
   detection stays clean).
9. Every slice ends with [`migration/spec-matrix.md`](migration/spec-matrix.md)
   updated and one commit: `feat ID: STATUS` (e.g. `feat S03: audited-pass`).
   Never leave the tree dirty between slices - commit `audited-fail` states too.
10. Audits are performed by a fresh-context subagent (`spec-auditor`) that did
    not write the code.

## Definition of done (per slice)

Gates pass on the current tree (new acceptance tests + full regression suite),
fresh-context audit reports no blockers (or blockers are recorded as
`audited-fail` in the matrix), matrix row updated, the
[`migration/integration-ledger.md`](migration/integration-ledger.md) updated
(a feature shipped without a wired entry point, or behind a runtime stub, is
recorded there and gets a wiring row — an unreachable feature is not done, no
matter how green its tests), single commit created.

Termination (the TERMINATION section of
[`migration/SINGLE-TICK-PROMPT.md`](migration/SINGLE-TICK-PROMPT.md)) requires
BOTH the spec matrix and the integration ledger clear, validated by
`bash migration/tools/check-complete.sh`. Set `HARNESS_PROFILE="feature"` in
[`migration/harness.env`](migration/harness.env) so the loop drives
`/feature-slice` against the spec matrix.

## Resumability — checkpoint to disk

The harness resumes from disk, not from the conversation. Checkpoint slice
progress as you go - update the [`migration/spec-matrix.md`](migration/spec-matrix.md)
row and a worklog (or `migration/HANDOFF.md`) - so a fresh session, or the
context after compaction, continues cleanly. Never hold un-saved state only in
context. A PreCompact hook fires when the conversation is about to be summarized:
when it reminds you, flush to disk before proceeding.
