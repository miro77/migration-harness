---
description: Implement exactly one acceptance-criterion row from migration/spec-matrix.md (or the given row id)
---

Implement exactly ONE spec row. Row: $ARGUMENTS (if empty: the first row in
`migration/spec-matrix.md` that is `in-progress` or `audited-fail`; otherwise
the first `open` or `split-required` row whose dependencies are
`audited-pass`).

Steps — all of them, in order:

0. **Pre-flight (machine-check even when a row id was passed explicitly).**
   Verify by reading the spec matrix: every dep in the row's deps cell is
   `audited-pass`. If not, do not claim the row; report which dep failed and
   pick the next actionable row instead.

1. **Claim.** Set the row to `in-progress` in the matrix.
   - If the row is `split-required`: split it into sub-rows, each a single
     independently testable criterion, commit
     `feat <id>: split into sub-slices`, and STOP — splitting is this
     pass's whole unit of work.
   - If the row is `blocked` on a PENDING decision: do not implement; report
     what decision is needed and stop.

2. **Acceptance test FIRST.** Author the test from the row's criterion —
   BEFORE the implementation. It must fail on wrong behavior, not merely
   exercise code (the spec-auditor hunts hollow tests). Record the test
   id/path in the row's acceptance-test cell.

3. **Implement** the smallest change that meets the criterion, in the
   feature's source scope only. Do not touch unrelated behavior; the full
   existing suite is the regression oracle and must stay green. **If you
   ship the feature without connecting its entry point, or leave a runtime
   stub, add a row to `migration/integration-ledger.md`** (state
   `built-unwired`/`stub`) AND make sure a matrix row exists that will wire
   it (its `closes-in`) — an unreachable feature is not done, no matter how
   green its tests.

4. **Gates.** `bash migration/tools/gates.sh` — must pass in full (new
   acceptance tests AND the full regression suite).

5. **Audit.** Spawn the `spec-auditor` agent (fresh context, did not write
   the code) with: the matrix row, the acceptance test(s), and the new code
   paths. It reports every gap with severity (blocker/minor). Repair
   blockers and re-audit, max 2 rounds; remaining blockers ⇒ status
   `audited-fail` with findings recorded.

6. **Re-gate after repairs.** If step 5 (or the matrix-row update in step 7)
   changed any file since the last gate run, re-run
   `bash migration/tools/gates.sh` so the recorded proof covers the exact
   tree you are about to commit. The Stop hook enforces this.

7. **Record & commit.** Update the matrix row (status, findings) AND
   `migration/integration-ledger.md` (anything shipped unwired/stubbed is
   recorded; anything this slice wired is flipped to `wired`). One commit:
   `feat <id>: <status>`. If gates fail after the final repair round,
   commit as `audited-fail` anyway — never leave the tree dirty between
   slices.

Report only: row id, files changed, tests added, criterion status, risks.
