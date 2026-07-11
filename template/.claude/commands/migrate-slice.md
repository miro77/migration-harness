---
description: Migrate exactly one slice from migration/parity-matrix.md (or the given slice id)
---

Migrate exactly ONE slice. Slice: $ARGUMENTS (if empty: the first row in
`migration/parity-matrix.md` that is `in-progress` or `audited-fail`;
otherwise the first `open` or `split-required` row whose dependencies are
`audited-pass`).

Steps — all of them, in order:

1. **Claim.** Set the row to `in-progress` in the matrix.
   - If the row is `split-required`: split it into sub-rows with concrete
     legacy source paths, commit `migrate <id>: split into sub-slices`, and
     STOP — splitting is this pass's whole unit of work.
   - If the row is `blocked` on a PENDING decision: do not implement; report
     what decision is needed and stop.
2. **Analyze.** Spawn the `legacy-analyst` agent on the row's legacy sources.
   It reports behavior only (API, defaults, validation, edge cases, numerics,
   listeners) with file:line evidence. No implementation in this step.
3. **Fixtures first** (engine/logic/persistence slices). Ensure golden
   fixtures for this slice exist in `migration/fixtures/`; if missing, extend
   `probes/` and generate them from the running legacy code. UI slices:
   ensure reference captures exist in `migration/reference/`, else capture
   per `migration/legacy-runtime.md`.
4. **Implement** in the row's target path only, tests written alongside
   (fixture-driven parity tests for logic; view/widget tests for UI). Match
   legacy behavior exactly unless the matrix row records an intentional
   deviation. Do not touch other features; shared wiring (routing/navigation)
   is the last step of the pass, never mid-slice. **If you ship a user-facing
   feature without connecting its entry point, or leave a runtime stub, add a
   row to `migration/integration-ledger.md`** (state `built-unwired`/`stub`) AND
   make sure a matrix row exists that will wire it (its `closes-in`) — a deferred
   feature with no wiring row never gets wired. An `audited-pass` port that the
   user cannot reach is not done.
5. **Gates.** `bash migration/tools/gates.sh` — must pass in full.
6. **Audit.** Spawn the `parity-auditor` agent (fresh context, did not write
   the code) with: the matrix row, legacy analyst report, fixture/capture
   evidence, and the new code paths. It reports every deviation with severity
   (blocker/minor). Repair blockers and re-audit, max 2 rounds; remaining
   blockers ⇒ status `audited-fail` with findings recorded.
7. **Re-gate after repairs.** If step 6 (or the matrix-row update in step 8)
   changed any file since the last gate run, re-run `bash
   migration/tools/gates.sh` so the recorded proof covers the exact tree you
   are about to commit. The Stop hook enforces this — a stale proof blocks the
   turn.
8. **Record & commit.** Update the matrix row (status, findings, deviations)
   AND `migration/integration-ledger.md` — add any feature this slice shipped
   unwired or stubbed, and flip to `wired` any ledger row this slice connected
   (if the slice's whole job was wiring, that is its deliverable). Then ensure
   gates have been run on the final content (step 7). One commit:
   `migrate <id>: <status>`. If gates fail after the final repair round, commit
   as `audited-fail` anyway — never leave the tree dirty between slices.

Report only: slice id, files changed, tests added, parity status, risks.
