#!/usr/bin/env bash
# Static consistency checks for the harness FILES (no throwaway repos, no runtime).
# Catches drift the runtime selftest can't see: a settings.json hook path that
# doesn't resolve to a real file, a scaffold reference to something never shipped,
# a harness.env missing a required variable. Exit 0 = all consistent.
#
# Self-locating: works from the template repo (harness under template/) or an
# installed copy (harness at the repo root). Needs only bash + grep.
set -uo pipefail

self="$(cd "$(dirname "$0")" && pwd)"
H=""; d="$self"
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/hooks/stop-require-gates.sh" ] && [ -f "$d/migration/tools/working-tree-hash.sh" ]; then H="$d"; break; fi
  d="$(dirname "$d")"
done
[ -n "$H" ] || { echo "FATAL: harness root not found above $self"; exit 1; }
cd "$H"

pass=0; fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }
exists(){ if [ -e "$1" ]; then ok "$2 ($1)"; else no "$2 — missing: $1"; fi; }

echo "== settings.json hook wiring =="
sj=.claude/settings.json
if [ -f "$sj" ]; then
  # settings.json must be PARSEABLE JSON. A syntax error here (one trailing
  # comma) makes Claude Code silently drop the whole hook config — every
  # enforcement hook, Stop hook included — while all runtime tests stay green,
  # because they invoke the hooks directly with bash, never via this wiring.
  if command -v python3 >/dev/null 2>&1; then
    for j in .claude/settings.json .claude/settings.local.json; do
      [ -f "$j" ] || continue
      if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$j" >/dev/null 2>&1; then
        ok "parses as JSON ($j)"
      else
        no "INVALID JSON — Claude Code would silently load NO hooks ($j)"
      fi
    done
  else
    echo "SKIP: python3 not available — settings.json JSON validity NOT checked (a syntax error would disable all hooks unnoticed)"
  fi
  # Every hook path named in settings.json must resolve to a real file — catches
  # a rename/typo that would make Claude Code try to run a missing hook.
  hooks=$(grep -oE '\.claude/hooks/[A-Za-z0-9._-]+\.sh' "$sj" | sort -u)
  [ -n "$hooks" ] || no "settings.json names no hooks"
  for h in $hooks; do exists "$h" "settings.json hook resolves"; done
  # And every hook file present should be wired, or it silently never runs.
  for f in .claude/hooks/*.sh; do
    base=".claude/hooks/$(basename "$f")"
    if printf '%s\n' "$hooks" | grep -qxF "$base"; then ok "hook is wired ($base)"; else no "hook present but NOT referenced in settings.json ($base)"; fi
  done
else
  no "missing $sj"
fi

echo "== scaffold references =="
exists probes    "probes/ dir (fixture generator, CLAUDE.md rule 1)"
exists AGENTS.md "AGENTS.md (listed in HARNESS_SCOPE)"
exists CLAUDE.md "CLAUDE.md"
for t in gates.sh record-gates.sh working-tree-hash.sh doctor.sh check-docs.sh check-stubs.sh kick-loop.sh gui-compare.py gui-capture.py persist-state.sh read-state.sh benchmark.sh; do
  exists "migration/tools/$t" "tool present"
done
for p in migration/tools/_git-bash.ps1 migration/tools/gates.ps1 \
         migration/tools/doctor.ps1 migration/tools/kick-loop.ps1 \
         migration/run-loop.ps1 test/run-all.ps1 test/powershell-selftest.ps1; do
  exists "$p" "PowerShell entry point present"
done
# kick-loop.sh defaults to these prompt files per mode — both must ship.
for p in LOOP-PROMPT.md SINGLE-TICK-PROMPT.md; do
  exists "migration/$p" "driver prompt present"
done

echo "== harness.env required vars =="
env=migration/harness.env
if [ -f "$env" ]; then
  for v in HARNESS_SCOPE HARNESS_FROZEN HARNESS_LOCKED; do
    if grep -qE "^${v}=" "$env"; then ok "harness.env defines $v"; else no "harness.env missing $v"; fi
  done
  # Budget/loop/driver config (optional but should be present so every knob
  # documented in CLAUDE.md is configurable in the one config file)
  for v in HARNESS_MAX_CALLS_PER_TICK HARNESS_LOOP_THRESHOLD HARNESS_LOOP_WINDOW HARNESS_MAX_TICKS HARNESS_LOCK_TTL_MIN; do
    if grep -qE "^${v}=" "$env"; then ok "harness.env defines $v"; else no "harness.env missing $v"; fi
  done
else
  no "missing $env"
fi

echo "== portability =="
# Product scripts (tools + hooks) must run on stock macOS bash 3.2: no mapfile.
# (Test scripts may use GNU-isms; they are dev/CI-facing.)
if grep -lE '^[^#]*\bmapfile\b' migration/tools/*.sh .claude/hooks/*.sh 2>/dev/null | grep -q .; then
  no "mapfile used in a product script (breaks stock macOS bash 3.2):"
  grep -lE '^[^#]*\bmapfile\b' migration/tools/*.sh .claude/hooks/*.sh 2>/dev/null | sed 's/^/  /'
else
  ok "no mapfile in product scripts (bash 3.2 compatible)"
fi

echo "== sub-agents =="
for a in legacy-analyst.md parity-auditor.md spec-auditor.md coder.md; do
  exists ".claude/agents/$a" "agent present"
done

echo "----------------------------------------"
echo "consistency check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
