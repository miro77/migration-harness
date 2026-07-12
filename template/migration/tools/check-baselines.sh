#!/usr/bin/env bash
# Baseline oracle guard (in-place oracle, opt-in via HARNESS_ORACLE in
# harness.env; see docs/IN-PLACE-PROFILE.md).
#
# In an in-place migration the oracle is CAPTURED, not frozen: each unit's
# T-row pins pre-change behavior with tests and snapshots the passing results
# as a committed fixture (migration/fixtures/<unit>.baseline.*). This gate
# keeps that oracle honest against the agent that would like its slice green:
#
#   1. MANIFEST (generic, works out of the box): every unit whose T-row is
#      audited-pass on the board must still have a committed fixture file.
#      Without this, deleting BOTH the tests and the fixture passes a naive
#      "compare what exists" check.
#   2. CONTENT PARITY (stack-specific, CONFIGURE below): every test that
#      passed at capture time must still exist and pass in the current run.
#      This is what stops "fix the failure by deleting the test". It needs
#      your test runner's result format, so it ships FAILING - like the
#      PROJECT GATES block in gates.sh, an unconfigured oracle must not
#      report green.
#
# Requires bash + awk. Board: parity-matrix.md (MATRIX_FILE overrides).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-baselines: not a git repository" >&2; exit 2; }

board="${MATRIX_FILE:-migration/parity-matrix.md}"
[ -f "$board" ] || { echo "check-baselines: board not found: $board" >&2; exit 1; }

# ---- 1. manifest: audited-pass T-rows require a committed fixture ----------
rc=0
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  if [ "$unit" = "__NO_STATUS_COLUMN__" ]; then
    echo "check-baselines: $board has a table but no 'status' header column - cannot locate T-row statuses" >&2
    rc=1
    continue
  fi
  found=""
  for f in "migration/fixtures/$unit".baseline.*; do
    [ -e "$f" ] && { found="$f"; break; }
  done
  if [ -z "$found" ]; then
    echo "check-baselines: T-$unit is audited-pass but migration/fixtures/$unit.baseline.* is MISSING" >&2
    rc=1
  elif [ ! -s "$found" ]; then
    echo "check-baselines: fixture $found is EMPTY - not a baseline" >&2
    rc=1
  fi
done < <(awk -F'|' '
  function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^\|/ {
    saw = 1
    n = split($0, c, "|")
    # Header = the row whose FIRST cell is "id" (case-insensitive); other
    # tables (the status-vocabulary legend) must not donate the column.
    if (col == 0) { if (tolower(trim(c[2])) == "id") for (i = 3; i <= n; i++) if (tolower(trim(c[i])) == "status") { col = i; break }; next }
    id = trim(c[2])
    if (id ~ /^T-/ && trim(c[col]) == "audited-pass") {
      sub(/^T-/, "", id); sub(/\..*$/, "", id); print id
    }
  }
  # A header with no status cell would otherwise consume every row above
  # (col stays 0), emit zero units, and let the manifest stage pass green
  # on a board it never parsed. Emit a sentinel the shell loop fails on.
  END { if (saw && col == 0) print "__NO_STATUS_COLUMN__" }
' "$board" | sort -u)
[ "$rc" -eq 0 ] || exit 1

# ---- 2. content parity (CONFIGURE for your stack) ---------------------------
# Wire your comparison between the markers: for each fixture, re-run or read
# the unit's current test results and FAIL if any test that passed at capture
# is missing, renamed, or failing now. Keep the marker lines. A worked
# gtest-JSON implementation is sketched in docs/IN-PLACE-PROFILE.md.
# HARNESS:BASELINE-PARITY-START
echo "check-baselines: content parity NOT CONFIGURED - wire your stack's comparison between the HARNESS:BASELINE-PARITY markers (an unconfigured oracle must not report green)" >&2
exit 1
# HARNESS:BASELINE-PARITY-END

echo "check-baselines: manifest + content parity OK"
exit 0
