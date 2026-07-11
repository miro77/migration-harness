# Parity Matrix

The single source of truth for migration progress. Each row is one slice.
`/migrate-slice` picks the next actionable row; the Stop hook and audit gate
key off these statuses. Keep it current — it is updated at the end of every
slice.

## Status vocabulary

| Status | Meaning |
|---|---|
| `open` | Not started; dependencies may or may not be met. |
| `split-required` | Too large for one pass; next visit splits it into sub-rows. |
| `in-progress` | Claimed by the current pass. |
| `audited-pass` | Implemented, gates pass, fresh-context audit found zero blockers. |
| `audited-fail` | Implemented but audit found unresolved blockers (recorded below). |
| `blocked` | Waiting on a PENDING decision in [`decisions.md`](decisions.md). |

## Intentional deviations

Deviations from legacy behavior are only allowed if listed in the row's
**Deviations** cell with an ADR reference. This list is EXHAUSTIVE: anything
the auditor finds that is not listed here is a bug, not a choice.

This matrix is the **fidelity** axis (is each slice a faithful port?). It does
NOT track whether a shipped feature is reachable in the running app — an
`audited-pass` port can still be wired to nothing. That is the **reachability**
axis, tracked in [`integration-ledger.md`](integration-ledger.md); the migration
terminates only when both are clear.

## Matrix

| id | slice | legacy source | target path | deps | status | deviations | findings |
|----|-------|---------------|-------------|------|--------|------------|----------|
| B01 | bootstrap (Phase 0) | — | — | — | open | — | — |
| ... | ... | ... | ... | ... | open | — | — |

<Expand to full coverage during Phase 0. One row per migratable unit. Split
any row whose legacy source spans more files than one pass can faithfully
port + audit.>
