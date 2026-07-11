# Integration Ledger

The **completeness** counterpart to [`parity-matrix.md`](parity-matrix.md).

The matrix tracks *fidelity* — is each ported slice faithful to the legacy
oracle? This ledger tracks *reachability* — is each user-facing feature actually
wired into the running app, or does it exist only as an orphan the user cannot
reach? The two axes are independent: a slice can be `audited-pass` (a perfect
port) and still ship its feature connected to nothing, surfacing a "not
implemented" placeholder at runtime. A per-slice audit cannot see this, because
it judges a slice in isolation; only the assembled app does.

Every entry here is a DEBT until it is wired or explicitly signed off.
**Termination requires this ledger to be clear** (see the TERMINATION section of
[`SINGLE-TICK-PROMPT.md`](SINGLE-TICK-PROMPT.md)): the migration is not done
while a built feature is unreachable.

## When to add a row

Add (or update) a row the moment a slice does either of these:

- **Ships a user-facing feature without connecting its entry point.**
  `/migrate-slice` defers shared wiring (routing / menus / navigation) out of
  feature slices — *"the last step of the pass, never mid-slice."* That deferral
  is legitimate, but it is a debt, not a free pass: record it here so the
  aggregate is visible instead of scattered across `audited-pass` cells.
- **Leaves a runtime stub** — a placeholder path the user can hit with no real
  feature behind it yet.

When you defer wiring, also make sure a **matrix row exists that will do that
wiring** and put its id in the `closes-in` column. The loop schedules work from
the matrix, so an unwired feature with no wiring row will simply never get wired.
Deferral therefore means TWO writes: a ledger row here, and a matrix row that
closes it. Closing a ledger row (wiring the feature) is a full unit of slice work.

## State vocabulary

| State | Meaning | Counts as |
|---|---|---|
| `built-unwired` | Implemented + audited, but no user entry point reaches it yet. | OPEN |
| `stub` | A placeholder the user can hit at runtime (no real feature behind it). | OPEN |
| `deferred-impl` | Reachable, but its behavior is intentionally incomplete (a recorded partial). | OPEN |
| `wired` | Reachable from a user entry point in the assembled app. | CLOSED |
| `blocked` | Waiting on a human decision (link the `decisions.md` id in notes). | CLOSED for termination |

## Stub code tag — enforced by `check-stubs.sh`

When `STUB_SENTINEL` is configured in [`harness.env`](harness.env), every
occurrence of the stub sentinel in shipped source MUST carry its ledger id as an
`INTEG-...` tag in a same-line comment, and that id must appear in the table
below. `bash migration/tools/check-stubs.sh` (run by `gates.sh`) fails otherwise
— so a stub cannot be shipped without being registered here. A single generic
"not implemented" fallback that covers many commands should carry one `INTEG-...`
tag pointing at a ledger row whose notes enumerate the still-stubbed commands.

## Ledger

| id | feature (user-facing) | state | created-by | entry point (how the user reaches it) | closes-in | notes |
|----|-----------------------|-------|------------|----------------------------------------|-----------|-------|
| INTEG-example | delete this example row once real rows exist | built-unwired | F0x | File menu -> Import | F-wiring | the `closes-in` slice wires it and flips this to `wired` |
