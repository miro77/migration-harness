#!/usr/bin/env bash
# Read-only harness diagnostic. Reports configuration completeness and whether
# the current tree is covered by a recorded gate proof. Writes NOTHING to the
# work tree — safe to run any time.
#
# Exit 0 on a valid harness repo (this is a report, not a gate). Exit 1 only if
# it cannot run at all (not a git repo / no harness.env).
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "doctor: not inside a git repository"; exit 1; }
cd "$root"
[ -f migration/harness.env ] || { echo "doctor: migration/harness.env not found — is the harness installed here?"; exit 1; }

# shellcheck source=/dev/null
source migration/harness.env

echo "=== harness config ==="
echo "HARNESS_SCOPE  = ${HARNESS_SCOPE:-<unset>}"
echo "HARNESS_FROZEN = ${HARNESS_FROZEN:-<unset>}"
echo "HARNESS_LOCKED = ${HARNESS_LOCKED:-<unset>}"
echo "MAX_CALLS/TICK = ${HARNESS_MAX_CALLS_PER_TICK:-0}"
echo "LOOP_THRESH    = ${HARNESS_LOOP_THRESHOLD:-3} (window ${HARNESS_LOOP_WINDOW:-6})"
echo "PROFILE        = ${HARNESS_PROFILE:-migration}"
echo "ORACLE         = ${HARNESS_ORACLE:-none}"
echo "(HARNESS_* path lists are space-separated: paths containing spaces are unsupported)"

echo
echo "=== setup ==="
if grep -q 'unconfigured gates' migration/tools/gates.sh 2>/dev/null; then
  echo "gates.sh     : NOT CONFIGURED — still the ship-time stub. Edit migration/tools/gates.sh."
else
  echo "gates.sh     : configured"
fi

# Locked-tooling integrity baseline (opt-in hardening: once recorded, any bypass
# of the action guards that mutates a gate/hook/config fails the gate).
if [ -f migration/locked-baseline.sha ]; then
  echo "locked base  : recorded (check-locked.sh enforces tooling integrity)"
else
  echo "locked base  : NOT recorded — the harness's own gates/hooks/config have no integrity baseline. As a human, after configuring gates.sh: bash migration/tools/check-locked.sh --record && git add migration/locked-baseline.sha"
fi

# Degraded enforcement looks identical to healthy from the outside: a hook that
# fails to PARSE silently never fires, and if 'bash' is off PATH the hooks cannot
# run at all. Exercise the machinery so a broken install is visible, not silent.
if command -v bash >/dev/null 2>&1; then
  _bad=""
  for _h in .claude/hooks/*.sh migration/tools/*.sh; do
    [ -f "$_h" ] || continue
    bash -n "$_h" 2>/dev/null || _bad="$_bad $_h"
  done
  if [ -n "$_bad" ]; then
    echo "hooks/tools  : SYNTAX ERROR in$_bad — enforcement is DEGRADED (a hook that does not parse does not run). Fix before relying on the harness."
  else
    echo "hooks/tools  : parse OK"
  fi
else
  echo "hooks/tools  : cannot verify — 'bash' is not on PATH, so the hooks cannot run at all."
fi

# Consumer-build seam: is anything wired between the CONSUMER-BUILD markers?
# (Empty is fine — only matters if a consumer resolves your source by path.)
if awk '/# HARNESS:CONSUMER-BUILD-START/{f=1;next} /# HARNESS:CONSUMER-BUILD-END/{f=0}
        f && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/{print}' \
       migration/tools/gates.sh 2>/dev/null | grep -q .; then
  echo "consumer gate: wired"
else
  echo "consumer gate: none (fine if nothing resolves your source directly — see PLAN.md Phase-0 survey)"
fi

# Shipped-target build seam: is the app's production/target compile wired?
# (VM tests do not prove the shipped artifact compiles.)
if awk '/# HARNESS:SHIP-BUILD-START/{f=1;next} /# HARNESS:SHIP-BUILD-END/{f=0}
        f && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/{print}' \
       migration/tools/gates.sh 2>/dev/null | grep -q .; then
  echo "ship build   : wired"
else
  echo "ship build   : none (wire your app's production compile — e.g. flutter build web --wasm — unless this migration ships no separately-built app)"
fi

# Runtime-stub gate + integration ledger (reachability tracking).
if [ -n "${STUB_SENTINEL:-}" ]; then
  if [ -f migration/integration-ledger.md ]; then
    # Don't count the shipped INTEG-example row as real ledger debt.
    rows=$(grep -E '^\| INTEG-' migration/integration-ledger.md 2>/dev/null | grep -cv '^| INTEG-example ' || true)
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    echo "stub check   : enabled; integration-ledger has $rows row(s) (termination needs every row wired/blocked)"
  else
    echo "stub check   : enabled but migration/integration-ledger.md is MISSING — create it"
  fi
else
  echo "stub check   : disabled (set STUB_SENTINEL in harness.env to enforce that shipped stubs are registered)"
fi

# Locked-file gate changes proposed by the agent, awaiting a human (P2).
pgc=migration/PROPOSED-GATE-CHANGES.md
if [ -f "$pgc" ] && grep -qE '^## PROPOSAL' "$pgc" 2>/dev/null; then
  n=$(grep -cE '^## PROPOSAL' "$pgc")
  echo "gate proposals: PENDING ($n) — a human must apply $pgc, then re-gate. Migration is not done while open."
else
  echo "gate proposals: none"
fi

# Terminal state: HANDOFF.md is a validated claim, not a marker file.
if [ -f migration/HANDOFF.md ]; then
  if _cc="$(bash migration/tools/check-complete.sh 2>&1)"; then
    echo "handoff      : $(printf '%s\n' "$_cc" | head -n 1) (validated)"
  else
    echo "handoff      : PRESENT but INVALID - $(printf '%s\n' "$_cc" | head -n 1)"
  fi
fi

# Unfilled <...> placeholders in the docs the operator is expected to fill.
# Deliberately NARROW: a broad any-<word> scan flags legitimate content in
# real repos (C++ '#include <gtest/gtest.h>', '<ls_libname>' in build docs,
# the '<unit>'/'<key>' notation in harness prose) and then reports stale
# noise forever. Instead the pattern ENUMERATES every operator-fill marker
# the template actually ships — including the lowercase ones in
# legacy-runtime.md, spec-matrix.md, and PLAN.md that an all-caps-only scan
# missed while reporting "placeholders : none".
ph=$(grep -rIlE '<[A-Z]{2,}( [A-Z]+)*>|<(legacy|target|source)-paths>|<Describe |<one line|<Platform/|<Concurrency/|<How |<e\.g\. |<N source files>|<component>|<test id|<Language/runtime|<Build tool|<Any required|<exact ' CLAUDE.md AGENTS.md migration/*.md 2>/dev/null || true)
if [ -n "$ph" ]; then
  echo "placeholders : REMAIN — fill the <...> markers in:"
  # shellcheck disable=SC2086
  printf '  %s\n' $ph
else
  echo "placeholders : none"
fi

# Paths the scaffold references; informational.
for p in probes AGENTS.md; do
  if [ -e "$p" ]; then echo "path $p : present"; else echo "path $p : ABSENT (referenced by the scaffold)"; fi
done

echo
echo "=== gate proof ==="
read -r -a SCOPE <<< "${HARNESS_SCOPE:-}"
state=.harness/state/gates-passed.diffsha
if [ "${#SCOPE[@]}" -eq 0 ]; then
  echo "proof: N/A (HARNESS_SCOPE empty — nothing is protected)"
elif [ ! -f "$state" ]; then
  echo "proof: NONE (no gate recorded — run: bash migration/tools/gates.sh)"
else
  hash_err="$(mktemp)"
  current=$(bash migration/tools/working-tree-hash.sh 2>"$hash_err"); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$current" ]; then
    echo "proof: UNKNOWN (working-tree-hash.sh failed — the hash tool may be broken)"
    sed 's/^/  /' "$hash_err" 2>/dev/null | head -4
  elif [ "$current" = "$(cat "$state")" ]; then
    echo "proof: GATED (current tree matches the recorded gate run)"
  else
    echo "proof: STALE (tree changed since the last gate — re-run: bash migration/tools/gates.sh)"
  fi
  rm -f "$hash_err" 2>/dev/null || true
fi

if [ "${#SCOPE[@]}" -gt 0 ]; then
  PATHS=()
  for p in "${SCOPE[@]}"; do [ -e "$p" ] && PATHS+=("$p"); done
  if [ "${#PATHS[@]}" -gt 0 ]; then
    dirty=$(git status --porcelain --untracked-files=all -- "${PATHS[@]}" ':(exclude).harness' 2>/dev/null)
    if [ -n "$dirty" ]; then echo "scoped tree: DIRTY (uncommitted changes in scope)"; else echo "scoped tree: clean"; fi
  fi
fi

echo
echo "=== within-slice controls ==="
runlog=.harness/state/runs.ndjson
if [ -f "$runlog" ]; then
  starts=$(grep -c '"event":"run.start"' "$runlog" 2>/dev/null || true)
  ends=$(grep -c '"event":"run.end"' "$runlog" 2>/dev/null || true)
  case "$starts" in ''|*[!0-9]*) starts=0 ;; esac
  case "$ends" in ''|*[!0-9]*) ends=0 ;; esac
  latest=$(grep '"event":"run.end"' "$runlog" 2>/dev/null | tail -n 1)
  outcome=$(printf '%s' "$latest" | sed -n 's/.*"outcome":"\([^"]*\)".*/\1/p')
  exit_code=$(printf '%s' "$latest" | sed -n 's/.*"exit_code":\([0-9][0-9]*\).*/\1/p')
  duration=$(printf '%s' "$latest" | sed -n 's/.*"duration_s":\([0-9][0-9]*\).*/\1/p')
  calls=$(printf '%s' "$latest" | sed -n 's/.*"tool_calls":\([0-9][0-9]*\).*/\1/p')
  inflight=$((starts - ends)); [ "$inflight" -lt 0 ] && inflight=0
  if [ "$ends" -gt 0 ]; then
    echo "run journal   : $ends completed, $inflight interrupted/in-flight; latest=$outcome rc=$exit_code duration=${duration}s calls=$calls"
  else
    echo "run journal   : 0 completed, $inflight interrupted/in-flight in $runlog"
  fi
else
  echo "run journal   : none yet (kick-loop has not started a tick)"
fi
telemetry=.harness/state/telemetry.ndjson
if [ -f "$telemetry" ]; then
  calls=$(wc -l < "$telemetry" | tr -d '[:space:]')
  echo "telemetry     : $calls tool-call(s) logged in $telemetry"
else
  echo "telemetry     : none yet (no PostToolUse calls recorded this session)"
fi
failfile=.harness/state/last-gate-failure.txt
if [ -f "$failfile" ]; then
  lines=$(wc -l < "$failfile" | tr -d '[:space:]')
  echo "gate feedback : PENDING ($lines line(s) of failure output from the last tick — next tick reads it first)"
else
  echo "gate feedback : none (last gates passed or no tick has run)"
fi
if [ -d .harness/state/slice-state ]; then
  keys=$(find .harness/state/slice-state -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  echo "slice state   : $keys key(s) in .harness/state/slice-state/"
else
  echo "slice state   : empty"
fi

exit 0
