---
description: Fresh-context parity audit of a migrated slice against legacy evidence
---

Audit slice: $ARGUMENTS (a matrix row id from `migration/parity-matrix.md`;
if empty, the most recently changed `in-progress`/`audited-*` row).

Spawn the `parity-auditor` agent with fresh context. Provide it:
- the matrix row (claimed status + recorded intentional deviations),
- the legacy source paths from the row,
- fixture files in `migration/fixtures/` / captures in `migration/reference/`
  for the slice,
- the new implementation and test paths.

The auditor must NOT see any implementation rationale or chat history —
evidence and code only.

Then:
1. Run `bash migration/tools/gates.sh` yourself and include the result.
2. Present the auditor's findings as a pass/fail checklist: every behavior
   from the legacy analysis → matched / deviates (intentional, ADR ref) /
   deviates (BUG, severity blocker|minor) / not implemented.
3. Update the matrix row status accordingly (`audited-pass` only if zero
   unrecorded deviations and gates pass).

Do not fix anything in this command — report and record only.
