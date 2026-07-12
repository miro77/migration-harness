#!/usr/bin/env bash
# The gate suite. Run before claiming any slice done. On success, records a
# content-hash proof consumed by the Stop hook.
#
# EDIT the PROJECT GATES section (between the HARNESS:PROJECT-GATES markers) for
# your stack. Leave those markers and the proof-recording line at the very end
# intact. The gates MUST exit non-zero on ANY failure — a gate that can't fail
# is not a gate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# shellcheck source=/dev/null
[ -f migration/harness.env ] && source migration/harness.env

# Capture gate stderr to a failure file so the next fresh-context tick can
# read the exact diagnostic (which test failed, what lint error was). On
# success the file is cleared (rm at the end); on failure it persists and
# SINGLE-TICK-PROMPT instructs the next tick to read it first. fd 3
# preserves the original stderr so output is still visible in the terminal.
mkdir -p .harness/state
_failfile=.harness/state/last-gate-failure.txt
exec 3>&2
exec 2> >(tee "$_failfile" >&3)

# The summary line is ALSO appended synchronously: stderr flows through an
# async process-substitution tee, which bash does not wait for on exit — so
# the tail of the failure file can lose a race against the next fresh-context
# tick reading it. The synchronous append guarantees the authoritative summary
# is on disk before exit (the tee copy may duplicate it — harmless).
fail() {
  printf 'GATES FAILED: %s\n' "$*" >> "$_failfile" 2>/dev/null || true
  echo "GATES FAILED: $*" >&2
  exit 1
}

if [ ! -f migration/parity-matrix.md ] && [ ! -f migration/spec-matrix.md ]; then
  fail "missing status matrix (expected migration/parity-matrix.md or migration/spec-matrix.md)"
fi

# An unconfigured harness must not report a green slice. Fail while ship-time
# placeholders remain in CLAUDE.md: multi-letter ALL-CAPS tokens (<PROJECT>,
# <LEGACY STACK>), the template's path tokens (<legacy-paths>, <target-paths>,
# <source-paths>), and the descriptive/multi-line ones the template ships
# (<Describe the...>, <one line ...>, <Platform/...>, <Concurrency/...>) —
# matched on their opening text so multi-line placeholders count too. The
# match is deliberately NARROW: legitimate configured content like a JSX
# `<Widget />` example, a custom element `<my-element>`, or a generic <T>/<Foo>
# must never brick a LOCKED gate. doctor.sh reports these; here they block.
if grep -EqI '<[A-Z]{2,}( [A-Z]+)*>|<(legacy|target|source)-paths>|<Describe |<one line|<Platform/|<Concurrency/' CLAUDE.md 2>/dev/null; then
  fail "CLAUDE.md still has ship-time <PLACEHOLDER> markers — configure it before gating (details: bash migration/tools/doctor.sh)"
fi

# Doc-gate: internal Markdown references in the harness docs must resolve.
# Scoped to the harness-owned docs so a slice isn't blocked by broken links in
# the user's unrelated documentation.
bash migration/tools/check-docs.sh CLAUDE.md AGENTS.md migration >&2 \
  || fail "broken internal Markdown reference(s) in the harness docs (see above; re-run: bash migration/tools/check-docs.sh CLAUDE.md AGENTS.md migration)"

# ===== IN-PLACE ORACLE GATES (opt-in: HARNESS_ORACLE="baselines") ==========
# For in-place migrations (docs/IN-PLACE-PROFILE.md): validate the status
# board mechanically and enforce the captured-baseline oracle. No-op unless
# harness.env sets HARNESS_ORACLE="baselines"; check-baselines.sh ships with
# a CONFIGURE step and fails until wired — an unconfigured oracle must not
# report green.
if [ "${HARNESS_ORACLE:-}" = "baselines" ]; then
  bash migration/tools/check-matrix.sh >&2 \
    || fail "status board inconsistent (migration/tools/check-matrix.sh)"
  bash migration/tools/check-baselines.sh >&2 \
    || fail "baseline oracle (migration/tools/check-baselines.sh)"
fi
# ==========================================================================

# ===== PROJECT GATES (edit for your stack) ================================
# Run format-check, static analysis, and the FULL test suite (including the
# fixture/parity tests). Each must abort the script on failure. Examples:
#
#   Dart/Flutter:
#     ( cd packages/engine && dart format --set-exit-if-changed --output=none . \
#         && dart analyze && dart test ) || fail "engine gates"
#     ( cd app && dart format --set-exit-if-changed --output=none . \
#         && flutter analyze && flutter test ) || fail "app gates"
#
#   Node/TypeScript:
#     npm ci && npm run lint && npm run typecheck && npm test || fail "node gates"
#
#   Python:
#     ruff format --check . && ruff check . && mypy . && pytest -q || fail "py gates"
#
#   Go:
#     test -z "$(gofmt -l .)" && go vet ./... && go test ./... || fail "go gates"
#
#   Rust:
#     cargo fmt --check && cargo clippy -- -D warnings && cargo test || fail "rust gates"
#
# Put your gates BETWEEN the two markers below, and KEEP the marker lines — the
# harness self-tests replace everything between them to install a test gate.
# HARNESS:PROJECT-GATES-START
echo "No project gates configured yet — edit migration/tools/gates.sh" >&2
fail "unconfigured gates (this failure is intentional until you edit gates.sh)"
# HARNESS:PROJECT-GATES-END
# ==========================================================================

# ===== SHIPPED-TARGET BUILD (compile the app the way you SHIP it) ==========
# The project gates above run your test suite on a DEV runtime (a VM, a test
# harness). That is NOT the artifact users get. A production/target compile can
# fail on code the tests happily run — a literal the ship compiler rejects, a
# tree-shake that drops a needed symbol, an intrinsic the dev VM emulates but the
# target backend does not. Those breaks are INVISIBLE to `flutter test` /
# `pytest` / `go test` and only surface when someone launches the shipped build
# by hand. "Tests pass on the VM" is not "the app compiles for users."
#
# Wire your app's ACTUAL production build between the markers. This is DISTINCT
# from the CONSUMER-BUILD block below (that is a downstream resolver; this is
# YOUR app's ship compile). Examples:
#   ( cd app && flutter build web --wasm )  || fail "ship build (flutter web/wasm)"
#   ( cd frontend && npm run build )        || fail "ship build (production bundle)"
#   cargo build --release                   || fail "ship build (release)"
#
# COST: a full build is usually the slow part of the gate. If it dominates, scope
# it to run only when shipped code changed (guard on `git diff --name-only`), but
# do NOT drop it. Leave empty only if this migration produces no separately-built
# app (a pure library/in-place refactor). KEEP the marker lines.
# HARNESS:SHIP-BUILD-START
# HARNESS:SHIP-BUILD-END
# ==========================================================================

# ===== CONSUMER-BUILD GATE (wire this if anything resolves your SOURCE) =====
# The project gates above exercise your code's BEHAVIOR (format, types, tests).
# They do NOT prove that a downstream CONSUMER still resolves and builds after a
# rename or a moved file — a browser loading modules by URL, a bundler resolving
# by path/extension/alias, or another package importing the built artifact.
# That failure mode is INVISIBLE to the test suite. (Verified in the wild: after
# `X.js` -> `X.ts`, tsx/tsc resolve `./X.js` -> `X.ts` and mocha stays green,
# but Vite does NOT resolve it from a `.js` importer — the production bundle
# breaks while every test passes.)
#
# If your Phase-0 consumer-resolution survey (migration/PLAN.md) found any such
# consumer, wire its build/resolve check BETWEEN the markers below so the
# recorded proof covers it. Leave it empty if nothing resolves your source
# directly. This block is a no-op until you fill it. Examples:
#   ( cd frontend && npm run build )   || fail "consumer bundle (vite build)"
#   cargo build -p downstream-consumer || fail "downstream consumer crate"
# KEEP the marker lines (tools and docs key off them).
# HARNESS:CONSUMER-BUILD-START
# HARNESS:CONSUMER-BUILD-END
# ==========================================================================

# Stub-sentinel gate: every runtime "not implemented" placeholder in shipped
# source must be registered in migration/integration-ledger.md (opt-in via
# STUB_SENTINEL in harness.env). Keeps deferred/unwired features visible in one
# ledger instead of silently accumulating behind a placeholder string until a
# human launches the app and hits it.
bash migration/tools/check-stubs.sh >&2 \
  || fail "unregistered runtime stub(s) — see above (register in migration/integration-ledger.md, or wire the feature so the stub is gone)"

bash migration/tools/record-gates.sh \
  || fail "all gates PASSED but the proof could NOT be recorded (working-tree-hash refused; likely a HARNESS_SCOPE entry it cannot stage - see the error above). The Stop hook will hold turns until this is fixed."
rm -f "$_failfile"
echo "GATES PASSED - proof recorded in .harness/state/gates-passed.diffsha"
