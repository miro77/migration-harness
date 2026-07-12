# Spec Matrix

The single source of truth for feature progress. Each row is one acceptance
criterion (a thin, observable, testable slice of the feature). The slice driver
picks the next actionable row; the Stop hook and audit gate key off these
statuses. Keep it current - it is updated at the end of every slice.

*Feature profile status board - the analog of `parity-matrix.md` in a migration
(see the harness repo's `docs/FEATURE-PROFILE.md`).*

## Status vocabulary

| Status | Meaning |
|---|---|
| `open` | Not started; dependencies may or may not be met. |
| `split-required` | Too large for one pass; next visit splits it into sub-rows. |
| `in-progress` | Claimed by the current pass. |
| `audited-pass` | Implemented, gates pass, fresh-context audit confirms the criterion is met by a real test. |
| `audited-fail` | Implemented but audit found unresolved gaps (recorded below). |
| `blocked` | Waiting on a PENDING decision in [`decisions.md`](decisions.md). |

## The spec is the oracle

Unlike a migration (whose oracle is captured legacy behavior), a feature's
oracle is the WRITTEN SPEC in this file. Each row states an observable
acceptance criterion in terms a user or caller can verify, plus the test that
asserts it. "Correct" means "meets the criterion" - not "matches some prior
behavior" (there is none). Author the acceptance test from the criterion BEFORE
or alongside the implementation; a criterion with no test that would fail on
wrong behavior is not done.

## Out-of-scope / non-goals

Anything not represented by a row is out of scope. Behavior beyond the listed
criteria is a separate decision - add a row, or record it in
[`decisions.md`](decisions.md) - never something a slice silently adds. This
list of criteria is the boundary of the feature.

## Regression guard

A feature must not break existing behavior. The full existing test suite runs in
`gates.sh` and must stay green on every slice - that is the regression oracle,
non-negotiable alongside the new acceptance tests.

## Matrix

| id | criterion (observable, testable) | area / component | deps | status | acceptance test | findings |
|----|----------------------------------|------------------|------|--------|-----------------|----------|
| S00 | bootstrap: spec broken into rows, gates configured and green on the untouched tree | - | - | open | gate run recorded in `.harness/state/` | - |
| S01 | <e.g. "POST /widgets with a valid body returns 201 and the new id"> | <component> | S00 | open | <test id / path> | - |
| ... | ... | ... | ... | open | ... | - |

<Expand to full coverage during Phase 0 (spec breakdown). One row per
independently testable criterion. Split any row whose criterion needs more code
than one pass can implement + audit.>
