# Adapting the harness to your stack

*See also: [README.md](../README.md) · [GETTING-STARTED.md](../GETTING-STARTED.md) · [PHILOSOPHY.md](PHILOSOPHY.md)*

The enforcement mechanics are stack-agnostic; only a few seams are
project-specific. Here's every seam and how to retarget it.

## Which mode are you in?

Two shapes of migration (see [PHILOSOPHY.md](PHILOSOPHY.md) → *Two shapes of
migration*):

- **In-place transform** — you edit the existing code to change what it's built on
  (e.g. remove a dependency) while preserving behavior. Put the edited tree in
  `HARNESS_SCOPE`, leave `HARNESS_FROZEN` **empty** (unless the repo VENDORS the
  dependency's own sources — then freeze those as the semantics oracle), and
  capture fixtures from the pre-change code (a probe run at the base commit). If
  a shim you add shares a path fragment with the frozen oracle, make the frozen
  fragment specific enough to exclude it (plain substring match — freeze
  `legacy/vendor/VendorLib`, not `vendor/`). The full battle-tested playbook — tests-first
  T-row/M-row rows, baseline anti-deletion machinery, status-board validation,
  teardown-as-done — is in [IN-PLACE-PROFILE.md](IN-PLACE-PROFILE.md).
- **Freeze-and-replace** — legacy stays a live oracle and you build a new tree
  alongside it. Set `HARNESS_FROZEN` to the legacy path fragment(s); new
  legacy-stack code goes in `probes/` / your new tree.

Building a **new feature** rather than migrating? Same engine, spec instead of a
legacy oracle — see [FEATURE-PROFILE.md](FEATURE-PROFILE.md).

Everything below applies to both unless noted.

## The seams

| What | Where | Change to |
|---|---|---|
| Which paths need a gate proof | [`migration/harness.env`](../template/migration/harness.env) → `HARNESS_SCOPE` | the source tree you edit (in-place) or add (new tree) + `migration .claude CLAUDE.md` |
| Which paths are the frozen oracle (optional) | [`migration/harness.env`](../template/migration/harness.env) → `HARNESS_FROZEN` | legacy fragment(s) for freeze-and-replace; **leave empty for in-place**. Plain substring match — make each fragment specific enough not to also catch your new code (freeze `legacy/vendor/VendorLib`, not a bare `vendor/`) |
| Baseline the frozen oracle (once, as a human) | [`migration/tools/check-frozen.sh`](../template/migration/tools/check-frozen.sh) `--record` | records `migration/frozen-baseline.sha`, the hash the gate checks the oracle against every run. **Do this during bootstrap, before slice 1**, then commit it — until it exists the gate fails closed (an unverified oracle is unproven, not a pass). The agent is blocked from `--record` on purpose |
| Stop the port from CALLING the oracle (optional) | [`migration/harness.env`](../template/migration/harness.env) → `HARNESS_LINKAGE_SCAN` | your TARGET source paths. A port that shells out to the legacy binary passes every parity fixture while migrating nothing. Scan only the new tree — `migration/` and the docs name the oracle legitimately |
| The actual gates | [`migration/tools/gates.sh`](../template/migration/tools/gates.sh) → PROJECT GATES block | your format-check + static analysis + full test suite |
| Command guards | [`.claude/hooks/pretooluse-command-guard.sh`](../template/.claude/hooks/pretooluse-command-guard.sh) | your test-filter + dep-add patterns (uncomment/adapt) |
| The contract & rules | [`template/CLAUDE.md`](../template/CLAUDE.md) | fill `<...>`; keep the 10 hard rules |
| Phased plan | [`migration/PLAN.md`](../template/migration/PLAN.md) | your module dependency order |
| Oracle run recipe | [`migration/legacy-runtime.md`](../template/migration/legacy-runtime.md) | your build/run/capture commands |

Nothing else should need editing. `working-tree-hash.sh`,
`record-gates.sh`, `stop-require-gates.sh`, and `pretooluse-frozen-legacy.sh`
are driven entirely by `harness.env` — don't hand-edit their scope.

## Gate examples by stack

Drop one of these into the PROJECT GATES block (each must abort on failure):

```bash
# Dart / Flutter
( cd packages/engine && dart format --set-exit-if-changed --output=none . \
    && dart analyze && dart test ) || fail "engine gates"

# Node / TypeScript
npm ci && npm run lint && npm run typecheck && npm test || fail "node gates"

# Python
ruff format --check . && ruff check . && mypy . && pytest -q || fail "py gates"

# Go
test -z "$(gofmt -l .)" && go vet ./... && go test ./... || fail "go gates"

# Rust
cargo fmt --check && cargo clippy -- -D warnings && cargo test || fail "rust gates"
```

## Cross-platform / multi-toolchain gates

`gates.sh` certifies only what it actually runs. If your codebase builds on more
than one toolchain (e.g. CMake on Linux *and* MSBuild on Windows), decide
deliberately what the gate covers:

- **Portable checks over platform binaries.** Prefer a check that runs anywhere
  (e.g. `dotnet tool.dll`) over a platform-specific binary, so the same gate runs
  on any host rather than failing with an exec-format error off its native OS.
- **Skip units not buildable on the gate host.** Keep an exclude list (a file, or
  a `HARNESS_*` glob) of units that can't build on the gate platform — e.g. a
  managed / `/clr` assembly the Linux gate can't compile — have the gate read it,
  and **log what it skipped** (a silent skip reads as "covered"). Otherwise
  touching one such unit spuriously fails the whole gate.
- **Platform-tagged proofs (not shipped — you'd extend the proof flow).** The
  shipped flow records ONE proof (`record-gates.sh` writes a single
  `.harness/state/gates-passed.diffsha`) and the Stop hook matches only that
  file — it is single-tree, not per-platform. For real multi-platform coverage
  you would extend `record-gates.sh` / `stop-require-gates.sh` to write and match
  a per-platform proof. Until then, one platform's gate is what "done" attests;
  run the others in CI / branch protection.
- **Build-config vs behavior.** Files like `.vcxproj` / `.props` may sit inside
  `HARNESS_SCOPE` yet be validated by no gate. The Stop hook still demands a proof
  for them, so either narrow `HARNESS_SCOPE` to gate-relevant content or accept
  that build-config changes ride a platform proof, not the default gate.

## The fixture contract

The oracle pattern doesn't care about language. A fixture is JSON:

```json
{ "id": "...", "legacyEntry": "...", "seed": 12345,
  "inputs": { ... }, "expected": { ... } }
```

A probe (in the legacy language) writes it by running real legacy code. A
parametrized test (in the new language) reads the same file and asserts exact
equality. Both live in the repo; regenerating a fixture requires a probe run,
never a hand-edit. For non-deterministic legacy code, pin the seed and port the
RNG (ADR-0002) so the run becomes deterministic — if you truly can't, that
class of output becomes a recorded intentional deviation, not a loosened test.

## Migrations without a UI, or without persistence

Drop the phases you don't need from `PLAN.md`. The core-logic phase and the
oracle/fixture machinery are the parts that carry every migration; the UI and
persistence phases are optional.

## GUI parity (optional, advisory)

For UI slices you can diff a legacy screenshot against the migrated screen as
review evidence. This is deliberately **not** a hard gate: migrating across UI
toolkits is never pixel-identical, so a fuzzy threshold would false-fail
legitimate slices. The artifacts inform the `parity-auditor`'s judgement, they
don't replace it.

- `migration/tools/gui-compare.py LEGACY.png NEW.png` (needs Pillow; uses numpy
  and scikit-image/SSIM if present) writes a diff image and a `legacy | new |
  diff` side-by-side, plus a similarity score, to `migration/reference/diff/`.
  Advisory by default; pass `--fail-under 0.9` to opt into a gating exit code.
- Capturing the screenshots is stack-specific. For web apps,
  `migration/tools/gui-capture.py --url URL --out shot.png` uses Playwright
  (`pip install playwright && playwright install chromium`). For a desktop or
  native legacy GUI, capture with your platform's tools or the app's own
  render-to-image — `gui-compare.py` does not care how the PNG was produced.

## Unattended across usage limits

An unattended run dies when the account hits its weekly/usage cap and does not
revive itself. Because the harness resumes from disk, the fix is an external
re-kick: [`migration/tools/kick-loop.sh`](../template/migration/tools/kick-loop.sh)
is a driver you run from cron / Windows Task Scheduler / a cloud routine —
`--drive` (recommended) runs one slice per fresh headless session back-to-back;
the default runs the single-session loop prompt once. A run that hits the limit
stops with exit 75 and the next scheduled run after the reset continues. See
[`template/migration/RESUMING.md`](../template/migration/RESUMING.md)
for the scheduling recipes.

## Review the setup before slice 1

The fresh-context audit inside the harness shares the model (and its blind
spots) with the agent that configured it. Before the first real slice, have a
**different model/vendor** adversarially review the configured harness. On a
real migration this found four blockers the internal audit had passed: the
proof hash not covering the gates' own inputs (build scripts, CI configs, the
checker binary), a unit missing from the status board (a shell-alias bug in
the discovery scan), a format checker blind to the most likely corruption,
and a deletable oracle.

Shape the prompt like this: state what was configured and where; forbid the
expensive full gate run; demand file:line evidence and a severity-ranked
findings list; and point the reviewer at the trust chain, not the file list —
"can any gate pass without proving what it claims?", "can the oracle be
deleted, emptied, or renamed while gates stay green?", "which prose rules are
not machine-checked?". Route locked-file fixes through
`PROPOSED-GATE-CHANGES.md`, fix unlocked files directly, then have the
reviewer **re-review the applied state** — a remediation can open new holes
(a real fix for guard false-positives introduced a bypass the second review
caught). Make sure re-reviews run against the branch HEAD, not a stale
sandbox snapshot.

## Template, not a generator

This harness ships as a copy-in template plus a thin stamping installer
(`install.sh`): the installer copies the template, `chmod`s the scripts,
gitignores `.harness/`, and prints a status report — it does NOT generate or
transform code, so the template stays the single source of truth and there is
no generator to keep working as Claude Code's hook/settings format evolves.
The remaining cost is ~30 min of fill-in-the-placeholders per project.
