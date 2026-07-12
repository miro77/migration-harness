# The in-place profile: tests-first migration of a codebase you edit directly

*Distilled from a real run: a large C++ monorepo migrated in place off a
legacy vendor container library onto the standard library, driven by this
harness. See also: [ADAPTING.md](ADAPTING.md) · [PHILOSOPHY.md](PHILOSOPHY.md)*

Freeze-and-replace migrations get their oracle for free: the legacy tree stays
byte-identical and executable. An **in-place** migration (remove a dependency,
swap a framework, modernize types) has no frozen tree — the code being edited
IS the legacy code. The oracle must be **captured before each edit**, and the
capture must be **mechanically protected**, because the same agent that wants
its slice green also controls the tests.

## The T-row / M-row pattern

Split every migratable unit's matrix row in two, worked strictly in order:

| row | work | oracle produced |
|-----|------|-----------------|
| `T-<unit>` | Write tests that pin the unit's CURRENT (pre-migration) observable behavior, running against unmigrated code. | A committed **baseline** snapshot of the passing test results (e.g. gtest JSON). |
| `M-<unit>` | Perform the migration edit. | Baseline must still pass, byte-name-identical. |

Order M-rows bottom-up the dependency graph: migrated types in a unit's public
interface leak into every dependent, so leaves go first. An M-row's deps are
its unit's T-row plus the M-rows of its affected direct dependencies.

Pre-mark oversized units `split-required`, and give splits quality rules:
explicit non-overlapping file sets per sub-row, union = the whole unit, a
final unit-wide cleanup sub-row. An M-row may only start when **ALL** of its
unit's T sub-rows are audited-pass — `any()` is a bypass (found by review).

## The enforcement suite (what keeps the oracle honest)

Four mechanisms, all of which earned their place by an attack a reviewer
found or a failure that actually happened:

1. **Baseline capture guard** (a capture script under `probes/`, unlocked
   but reviewed): refuses to snapshot a red suite (pre-existing failures are
   recorded findings, not contract); refuses a near-empty baseline (a
   minimum passing-test count — an empty pin is a rubber stamp); refuses to
   RE-capture with fewer contractual tests unless an override env var is set
   AND the status board records the justification (the env var alone is not
   evidence).
2. **Baseline parity gate** (locked, in gates.sh): every test that passed at
   capture must still exist and pass. Missing fixtures for
   captured-and-audited units FAIL (derive the manifest from the status
   board — with zero fixtures the naive check exits green, so deleting both
   the tests and the fixture would otherwise pass). Empty fixtures FAIL.
   Purge stale test-run evidence at the start of full runs, and treat a
   deleted test project whose fixture is committed as a FAILURE, not a skip
   — stale JSON from a previous run otherwise satisfies the comparison.
3. **Status-board validator** (locked, in gates.sh): recompute the affected
   set from the tree (grep for the dependency being removed) and fail when a
   unit lacks rows — the field run's Phase-0 scan MISSED a library because
   `grep` was shell-aliased; only this validator class catches that
   permanently. Enforce T-before-M and dep ordering mechanically, not as
   prose. Parse the matrix STRICTLY: spacing-insensitive cells, malformed
   ids are errors, duplicate ids are errors, unknown status spellings are
   errors (a misspelled status must not dodge the active-row checks).
4. **Format/encoding diff gate** (locked, when the codebase has a legacy
   encoding): compare changed files against HEAD and fail on an encoding
   flip. Do NOT trust a vendor checker until you have verified it fails on
   the exact corruption you fear, in BOTH directions — the field run's
   checker caught UTF-8 em-dashes but silently passed `é` (0xE9 → C3 A9,
   every byte individually plausible in CP1252), the single most likely
   corruption in that codebase.

What ships in the template vs what you adapt (set
`HARNESS_ORACLE="baselines"` in `harness.env` to wire the shipped parts into
`gates.sh`):

- **Shipped, works out of the box**: the strict status-board validator
  (`migration/tools/check-matrix.sh` — strict parsing, dep ordering,
  T-before-M when the convention is used, plus a coverage seam: create a
  `list-affected-units.sh` under `migration/tools/` that prints your affected
  units one per line, and every unit must have a row) and the baseline MANIFEST check
  (`migration/tools/check-baselines.sh` part 1 — an audited-pass T-row whose
  fixture is missing or empty fails the gates).
- **Shipped FAILING until you configure it**: baseline CONTENT parity
  (`check-baselines.sh` part 2, between the `HARNESS:BASELINE-PARITY`
  markers) — comparing captured results against the current run needs your
  test runner's format. Like the PROJECT GATES block, an unconfigured oracle
  refuses to report green. Sketch for gtest JSON: parse each fixture's
  passing test names, parse the current run's JSON for the same unit, fail
  on any name missing or no longer passing.
- **Adapt per stack**: the capture script itself (mechanism 1) and the
  encoding-diff gate (mechanism 4) — battle-tested gtest/CP1252-flavored
  implementations live in the LS libraries migration branch and can be
  lifted with minor changes.

## Phase-0 lessons that generalize

- **Discovery must be reproducible**: the affected-unit scan belongs in a
  committed script run with `command grep` (never through shell aliases),
  and the validator (mechanism 3) re-runs it forever after.
- **A green baseline may need pre-baseline fixes** (version-drifted test
  pins, latent crashes the swallowing test runner never surfaced). Keep them
  minimal, behavior-preserving where possible, and record each as an
  explicit deviation — a crash fix IS a behavior change for someone.
- **Check the fresh checkout is clean before any work**: mass modifications
  right after checkout mean the EOL/encoding config is wrong on this
  machine. Stop; never commit or "clean up" that diff.
- **Verify the test runner propagates failures.** The field run's wrapper
  printed a warning and exited 0 on failing tests; nobody had noticed
  because nothing ever went red. The exit-code-propagating replacement is
  the migration's most durable legacy — plan to promote it into the repo's
  own CI at teardown.

## Bake teardown into the definition of done

The migration is not finished when the last unit compiles without the old
dependency. It terminates when (1) the dependency is gone, (2) the checks the
harness added (the honest test runner, the encoding gate) have moved into the
repo's OWN CI, and (3) the harness scaffolding is REMOVED from the branch
before merge — the next developer inherits the migrated code and its tests,
not a locked harness. The agent prepares the teardown (CI wiring, handoff
checklist, dangling-reference sweep); a human executes the deletion of
HARNESS_LOCKED files. Re-instantiate fresh from this repo for the next
migration; never leave an instance rotting in-tree.

## Review the setup before slice 1

Before the first real slice, have a DIFFERENT model/vendor adversarially
review the configured harness (see the review-prompt sketch in
[ADAPTING.md](ADAPTING.md#review-the-setup-before-slice-1)). In the field run
this found, among others: the proof not covering the gates' own inputs, a
missed library, and the encoding blind spot — four blockers the same-model
fresh-context audit had passed. Fold the findings back through
`PROPOSED-GATE-CHANGES.md` (locked files) and direct edits (unlocked files),
and have the reviewer re-review the applied state.
