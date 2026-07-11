# Architecture Decisions

Accepted ADRs are immutable; corrections are new ADRs with "Supersedes".
Gate/threshold changes require an ADR, not a commit comment. Intentional
behavior changes must reference an ADR from the parity-matrix row.

Decisions the migration is blocked on are recorded as `PENDING-NNNN` with the
question and, where possible, a default assumption the loop may apply.

## ADR-0001 — Rewrite against an executable oracle (accepted)

Transpilation is rejected. We rewrite, and correctness comes from executing
legacy code: the `probes/` module runs real legacy classes and dumps
input→output JSON fixtures; the new port must reproduce them exactly. An agent
migrating many files unattended will silently invent behavior unless wrong
ports fail tests.

## ADR-0002 — Exact determinism / RNG parity (accepted)

Where the legacy code is deterministic, the new code reproduces it exactly —
including reimplementing any legacy RNG so seeded runs match bit-for-bit.
Statistical comparison is forbidden: exact match makes the audit gate
mechanical instead of judgment-based.

<Add ADRs for: the target architecture/layering, platform/runtime constraints,
which classes of output are intentional-deviation (e.g. charts), the legacy
toolchain pinning, and an approved-dependencies table.>

### Approved dependencies

| package | version | why | evidence |
|---|---|---|---|
| (none yet) | | | |

## PENDING decisions

| id | question | default assumption (if any) |
|----|----------|-----------------------------|
| (none yet) | | |
