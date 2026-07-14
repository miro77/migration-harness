#!/usr/bin/env bash
# Run the full LOCAL test surface for the harness and exit non-zero if anything
# fails. This is the one command for "test this repo":
#   1. syntax        — bash -n on every shell script
#   2. shellcheck    — static analysis (skipped with a note if not installed)
#   2b. gui-compare  — Python image-diff selftest (skipped without python+Pillow)
#   2c. PowerShell   — Windows installer/launcher tests (when PowerShell exists)
#   3. selftest      — runtime enforcement regression guard (throwaway repos)
#   4. consistency   — static wiring/reference checks on the harness files
#   4b. doc-gate     — internal Markdown links/anchors resolve (repo-wide)
#   5. e2e-smoke     — real install + real gate, full pass/fail/re-gate cycle
#   6. install-test  — install.sh into a throwaway repo (skips in installed copies)
#
# Self-locating: works from the template repo or an installed copy.
set -uo pipefail

self="$(cd "$(dirname "$0")" && pwd)"
H=""; d="$self"
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/hooks/stop-require-gates.sh" ] && [ -f "$d/migration/tools/working-tree-hash.sh" ]; then H="$d"; break; fi
  d="$(dirname "$d")"
done
[ -n "$H" ] || { echo "FATAL: harness root not found above $self"; exit 1; }

rc=0
line(){ echo; echo "==================== $1 ===================="; }

line "1. syntax (bash -n)"
n=0
for f in "$H"/.claude/hooks/*.sh "$H"/migration/tools/*.sh "$H"/test/*.sh; do
  if bash -n "$f"; then n=$((n+1)); else echo "SYNTAX ERROR: $f"; rc=1; fi
done
echo "$n scripts parse OK"

line "2. shellcheck (-S error)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$H"/.claude/hooks/*.sh "$H"/migration/tools/*.sh "$H"/test/*.sh; then
    echo "clean"
  else
    rc=1
  fi
else
  echo "shellcheck not installed — skipped (CI runs it)"
fi

line "2b. gui-compare selftest (optional, needs python+Pillow)"
# Pick the first interpreter that can ACTUALLY import Pillow — on Windows,
# python3 often resolves to a broken WindowsApps shim while python works.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import PIL' >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -n "$PY" ]; then
  "$PY" "$H/migration/tools/gui-compare.py" --selftest || rc=1
  # bad input must honour the exit-code contract (2), not crash with a traceback (1)
  bad="$("$PY" "$H/migration/tools/gui-compare.py" "$H/README.md" "$H/README.md" >/dev/null 2>&1; echo $?)"
  [ "${bad:-x}" = "2" ] && echo "gui-compare: bad-input exit 2 OK" || { echo "gui-compare: bad-input expected exit 2, got $bad"; rc=1; }
else
  echo "python+Pillow not available - skipped"
fi

line "2c. PowerShell entry points"
# Windows PowerShell cannot open a POSIX path. Under WSL, powershell.exe IS on the
# PATH (Windows interop) but "/mnt/m/..." means nothing to it: it printed "the
# argument ... does not exist", returned 0, and the whole stage silently counted as
# a pass. An entire test suite that never ran, reported green. So: translate the
# path with whatever translator this shell has (cygpath under Git Bash, wslpath
# under WSL), and if we cannot hand PowerShell a path it can open, SKIP loudly
# rather than "run" it and read the error as success.
psscript="$H/test/powershell-selftest.ps1"
psout=""; psrc=0; psran=0
if command -v pwsh >/dev/null 2>&1; then
  psout="$(pwsh -NoProfile -File "$psscript" 2>&1)"; psrc=$?; psran=1
elif command -v powershell.exe >/dev/null 2>&1; then
  winpath=""
  if command -v cygpath >/dev/null 2>&1; then   winpath="$(cygpath -w "$psscript" 2>/dev/null)"
  elif command -v wslpath >/dev/null 2>&1; then winpath="$(wslpath -w "$psscript" 2>/dev/null)"
  fi
  if [ -n "$winpath" ]; then
    psout="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$winpath" 2>&1)"; psrc=$?; psran=1
  else
    echo "powershell.exe found but no cygpath/wslpath to translate '$psscript' - skipped"
  fi
else
  echo "PowerShell not available - skipped"
fi
if [ "$psran" -eq 1 ]; then
  printf '%s\n' "$psout"
  # Silence is not success. The suite prints a summary line on every run; if it is
  # absent the script never executed, whatever exit code we were handed.
  if ! printf '%s' "$psout" | grep -q 'PowerShell self-test:'; then
    echo "run-all: the PowerShell self-test printed no summary - it did not run. Counting as FAILURE, not a skip." >&2
    rc=1
  elif [ "$psrc" -ne 0 ]; then
    rc=1
  fi
fi

line "3. harness-selftest.sh"
bash "$H/test/harness-selftest.sh" || rc=1

line "4. check-consistency.sh"
bash "$H/test/check-consistency.sh" || rc=1

line "4b. doc-gate (check-docs.sh, repo-wide)"
bash "$H/migration/tools/check-docs.sh" || rc=1

line "5. e2e-smoke.sh"
bash "$H/test/e2e-smoke.sh" || rc=1

line "6. install-test.sh"
bash "$H/test/install-test.sh" || rc=1

echo
if [ "$rc" -eq 0 ]; then
  echo "########## ALL LOCAL TESTS PASSED ##########"
else
  echo "########## SOME LOCAL TESTS FAILED ##########"
fi
exit "$rc"
