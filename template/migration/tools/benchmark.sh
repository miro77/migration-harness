#!/usr/bin/env bash
# Benchmark: run a slice with vs without the harness and compare gate results.
#
# Demonstrates the value of the harness: the same model, the same slice,
# with and without enforcement. The "without" path disables hooks (a
# hooks-free settings.json), parks CLAUDE.md out of the way (claude -p
# auto-loads it no matter what the prompt says), and uses a stripped prompt
# (no gate enforcement, no auditor). Both paths run the SAME gates afterward
# so the comparison is apples-to-apples.
#
# Usage:
#   bash migration/tools/benchmark.sh <slice-id> [--rounds N]
#
# Requires: claude CLI on PATH, a configured harness with real gates.
#
# Each path starts from the SAME tree: tracked content is reset to the saved
# HEAD and untracked leftovers are cleaned (reset --hard alone leaves them,
# and a slice's primary output is new UNTRACKED source files — one path
# inheriting the other's files would invalidate the whole comparison). It does
# NOT auto-reset the parity matrix in your history — inspect and update
# migration/parity-matrix.md manually after.
#
# Exit 0 = both paths ran; the comparison table is on stdout. Non-zero =
# setup or run error (settings.json / CLAUDE.md are always restored).
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "benchmark: not a git repository" >&2; exit 1; }
[ -f migration/harness.env ] || { echo "benchmark: harness not installed here" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "benchmark: the 'claude' CLI must be on PATH" >&2; exit 2; }

# This script uses `git reset --hard` + `git clean -fd` between paths —
# uncommitted or untracked work would be destroyed without a trace. Refuse to
# start on a dirty tree (which also means: no untracked files exist that the
# clean below could eat).
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "benchmark: working tree is not clean — commit or stash first (this script runs 'git reset --hard' and 'git clean -fd' between paths)" >&2
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
case "$rounds" in ''|*[!0-9]*|0) echo "benchmark: --rounds needs a positive integer" >&2; exit 2 ;; esac

sj=.claude/settings.json
slj=.claude/settings.local.json
# Path-local mutations (the hooks-free settings.json, the parked local
# overrides and CLAUDE.md) are backed up under .harness: it is outside the
# proof hash, gitignored by the installer, and — critically — SURVIVES the
# `git clean -fd` between paths (clean without -x skips ignored paths; the
# explicit -e is belt and braces for repos that never gitignored .harness).
mkdir -p .harness
sj_backup=".harness/benchmark-settings.json.bak"
slj_backup=".harness/benchmark-settings.local.json.bak"
cm_backup=".harness/benchmark-CLAUDE.md.bak"
cml_backup=".harness/benchmark-CLAUDE.local.md.bak"
state_orig=".harness/benchmark-state-orig"
restore_all(){
  if [ -f "$sj_backup" ]; then mv -f "$sj_backup" "$sj"; echo "benchmark: restored $sj" >&2; fi
  if [ -f "$slj_backup" ]; then mv -f "$slj_backup" "$slj"; echo "benchmark: restored $slj" >&2; fi
  if [ -f "$cm_backup" ]; then mv -f "$cm_backup" CLAUDE.md; echo "benchmark: restored CLAUDE.md" >&2; fi
  if [ -f "$cml_backup" ]; then mv -f "$cml_backup" CLAUDE.local.md; echo "benchmark: restored CLAUDE.local.md" >&2; fi
}
trap restore_all EXIT

# Hooks the harness cannot disable for the B arm: Claude Code also loads user
# (~/.claude/settings.json), managed, and plugin settings — outside this repo,
# so outside this script's remit. Warn instead of silently mislabeling the arm.
if grep -qs '"hooks"' "$HOME/.claude/settings.json" 2>/dev/null; then
  echo "benchmark: WARNING — user-level hooks exist in ~/.claude/settings.json; the 'WITHOUT HARNESS' arm cannot disable those." >&2
fi

# Snapshot the pre-benchmark local harness state ONCE. Each arm then starts
# from this snapshot: .harness/state carries the gate proof, board snapshots,
# audit records and gate-failure feedback, and letting arm B's state leak into
# arm A contaminates the comparison exactly like leaked source files would
# (confirmed: A's gate verdict could be decided by B's leftovers).
rm -rf "$state_orig"
[ -d .harness/state ] && cp -R .harness/state "$state_orig"

# One benchmark run: reset the tree, apply the path's enforcement mode, run
# the model, then gate. Stdout is ONLY the machine-readable verdict; the
# transcript goes to stderr so it stays visible without drowning the table.
run_path(){
  local label="$1" prompt="$2" nohooks="$3"
  echo "=== $label ===" >&2
  # Reset tracked, untracked, AND local harness state so this path cannot
  # inherit the other path's work (a GATE verdict earned by the other path's
  # files — or its recorded proof/audit state — is the exact contamination
  # this script exists to rule out).
  git reset --hard "$save_head" >/dev/null 2>&1
  git clean -fdq -e .harness >/dev/null 2>&1 || true
  rm -rf .harness/state
  [ -d "$state_orig" ] && cp -R "$state_orig" .harness/state
  rm -rf .harness/state/tool-stats 2>/dev/null || true
  # Enforcement swap AFTER the reset: settings.json is tracked, so a reset
  # inside this function after the swap would silently restore the hooks and
  # run the "without" path WITH them (the A/B was A/A; found by external
  # review). settings.local.json and CLAUDE.local.md are parked too — local
  # settings OVERRIDE project settings, so leaving them in place can keep the
  # "without" arm hooked (or contracted) despite the swapped settings.json.
  if [ "$nohooks" = "nohooks" ]; then
    cp "$sj" "$sj_backup"
    cat > "$sj" <<'NOHOOKS'
{
  "permissions": {
    "allow": [
      "Bash(bash migration/tools/gates.sh:*)"
    ]
  }
}
NOHOOKS
    if [ -f "$slj" ]; then mv "$slj" "$slj_backup"; fi
    if [ -f CLAUDE.md ]; then mv CLAUDE.md "$cm_backup"; fi
    if [ -f CLAUDE.local.md ]; then mv CLAUDE.local.md "$cml_backup"; fi
  fi
  claude -p "$prompt" >&2 2>&1 || true
  # Restore enforcement BEFORE gating so both paths are judged by the same
  # gates under the same config, and so a crash mid-gate leaves nothing
  # swapped (the EXIT trap is then a no-op).
  if [ "$nohooks" = "nohooks" ]; then
    restore_all
  fi
  if bash migration/tools/gates.sh >/dev/null 2>&1; then
    echo "GATE:PASS"
  else
    echo "GATE:FAIL"
  fi
}

save_head=$(git rev-parse HEAD)

stripped_prompt="Migrate slice ${slice_id} for this repository. Read the source code and port it to the target stack. Implement the code and tests, then run the project's test suite to verify."

harness_prompt="Advance the migration by exactly ONE tick. Run /migrate-slice for slice ${slice_id}. Read CLAUDE.md and migration/PLAN.md first. Follow the TICK PROCEDURE in migration/SINGLE-TICK-PROMPT.md exactly: implement the slice, run bash migration/tools/gates.sh, spawn the parity-auditor for a fresh-context audit, update migration/parity-matrix.md, and commit. One slice only."

echo "benchmark: slice=${slice_id} rounds=${rounds}" >&2
echo >&2

a_results=(); b_results=()
r=1
while [ "$r" -le "$rounds" ]; do
  # B (without harness) first so the harness state is clean for A.
  b_results+=("$(run_path "round $r: WITHOUT HARNESS (no hooks, no CLAUDE.md, no auditor)" "$stripped_prompt" nohooks)")
  a_results+=("$(run_path "round $r: WITH HARNESS (hooks, CLAUDE.md, gates, auditor)" "$harness_prompt" hooks)")
  r=$((r+1))
done

# --- Reset to the original tree and pre-benchmark harness state ---
git reset --hard "$save_head" >/dev/null 2>&1
git clean -fdq -e .harness >/dev/null 2>&1 || true
rm -rf .harness/state
[ -d "$state_orig" ] && mv "$state_orig" .harness/state

# --- Print comparison ---
echo
echo "════════════════════════════════════════════════════════════"
echo "  BENCHMARK: slice ${slice_id} (${rounds} round(s))"
echo "════════════════════════════════════════════════════════════"
i=0
while [ "$i" -lt "$rounds" ]; do
  printf '  round %-2s  %-28s  %s\n' "$((i+1))" "WITH harness (A):" "${a_results[$i]}"
  printf '  round %-2s  %-28s  %s\n' "$((i+1))" "WITHOUT harness (B):" "${b_results[$i]}"
  i=$((i+1))
done
echo "════════════════════════════════════════════════════════════"
echo
echo "A = PASS, B = FAIL  → the harness caught a problem the raw model missed."
echo "A = PASS, B = PASS  → the harness adds overhead but no delta this slice."
echo "A = FAIL, B = FAIL  → both paths failed; the slice may be too large."
echo "A = FAIL, B = PASS  → unexpected; the harness may have over-constrained."
