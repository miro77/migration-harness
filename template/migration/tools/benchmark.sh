#!/usr/bin/env bash
# Benchmark: run a slice with vs without the harness and compare gate results.
#
# Demonstrates the value of the harness: the same model, the same slice,
# with and without enforcement. The "without" path temporarily disables
# hooks (backs up settings.json) and uses a stripped prompt (no CLAUDE.md
# rules, no gate enforcement, no auditor). Both paths run the SAME gates
# afterward so the comparison is apples-to-apples.
#
# Usage:
#   bash migration/tools/benchmark.sh <slice-id> [--rounds N]
#
# Requires: claude CLI on PATH, a configured harness with real gates.
#
# The script saves the git HEAD before each run and resets after, so both
# paths start from the same tree. It does NOT auto-reset the parity matrix
# — inspect and update migration/parity-matrix.md manually after.
#
# Exit 0 = both paths ran; the comparison table is on stdout. Non-zero =
# setup or run error (the hooks/settings.json are always restored).
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "benchmark: not a git repository" >&2; exit 1; }
[ -f migration/harness.env ] || { echo "benchmark: harness not installed here" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "benchmark: the 'claude' CLI must be on PATH" >&2; exit 2; }

# This script uses `git reset --hard` between paths — uncommitted work would be
# destroyed without a trace. Refuse to start on a dirty tree.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "benchmark: working tree is not clean — commit or stash first (this script runs 'git reset --hard' between paths)" >&2
  exit 2
fi

slice_id=""
rounds=1
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) rounds="${2:?}"; shift 2 ;;
    -h|--help)
      echo "Usage: bash migration/tools/benchmark.sh <slice-id> [--rounds N]"
      exit 0 ;;
    *) slice_id="$1"; shift ;;
  esac
done
[ -n "$slice_id" ] || { echo "benchmark: a slice-id is required" >&2; exit 2; }

sj=.claude/settings.json
backup=""
restore_hooks(){
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    mv "$backup" "$sj"
    echo "benchmark: restored $sj" >&2
  fi
}
trap restore_hooks EXIT

run_path(){
  local label="$1" prompt="$2"
  echo "=== $label ===" >&2
  # Reset to the saved HEAD so both paths start clean.
  git reset --hard "$save_head" >/dev/null 2>&1
  rm -rf .harness/state/tool-stats 2>/dev/null || true
  # Transcript goes to stderr (visible, but NOT captured): this function's
  # stdout is the machine-readable verdict the comparison table prints, and a
  # full transcript in the result variable would drown the table.
  claude -p "$prompt" >&2 2>&1 || true
  # Run gates and record the result.
  if bash migration/tools/gates.sh >/dev/null 2>&1; then
    echo "GATE:PASS"
  else
    echo "GATE:FAIL"
  fi
}

save_head=$(git rev-parse HEAD)

# --- PATH A: full harness ---
stripped_prompt="Migrate slice ${slice_id} for this repository. Read the source code and port it to the target stack. Implement the code and tests, then run the project's test suite to verify."

harness_prompt="Advance the migration by exactly ONE tick. Run /migrate-slice for slice ${slice_id}. Read CLAUDE.md and migration/PLAN.md first. Follow the TICK PROCEDURE in migration/SINGLE-TICK-PROMPT.md exactly: implement the slice, run bash migration/tools/gates.sh, spawn the parity-auditor for a fresh-context audit, update migration/parity-matrix.md, and commit. One slice only."

echo "benchmark: slice=${slice_id} rounds=${rounds}" >&2
echo >&2

# --- PATH B (without harness) first so the harness state is clean for A ---
backup="${sj}.benchmark-backup"
cp "$sj" "$backup"
# Disable hooks: replace settings.json with a hooks-free version.
cat > "$sj" <<'NOHOOKS'
{
  "permissions": {
    "allow": [
      "Bash(bash migration/tools/gates.sh:*)"
    ]
  }
}
NOHOOKS

b_result=$(run_path "WITHOUT HARNESS (no hooks, no CLAUDE.md, no auditor)" "$stripped_prompt")

# --- Restore hooks for PATH A ---
restore_hooks
backup=""  # trap already restored
trap - EXIT

a_result=$(run_path "WITH HARNESS (hooks, CLAUDE.md, gates, auditor)" "$harness_prompt")

# --- Reset to the original tree ---
git reset --hard "$save_head" >/dev/null 2>&1

# --- Print comparison ---
echo
echo "════════════════════════════════════════════════════════════"
echo "  BENCHMARK: slice ${slice_id}"
echo "════════════════════════════════════════════════════════════"
printf '  %-40s  %s\n' "WITH harness (A):" "$a_result"
printf '  %-40s  %s\n' "WITHOUT harness (B):" "$b_result"
echo "════════════════════════════════════════════════════════════"
echo
echo "A = PASS, B = FAIL  → the harness caught a problem the raw model missed."
echo "A = PASS, B = PASS  → the harness adds overhead but no delta this slice."
echo "A = FAIL, B = FAIL  → both paths failed; the slice may be too large."
echo "A = FAIL, B = PASS  → unexpected; the harness may have over-constrained."
