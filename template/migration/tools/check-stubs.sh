#!/usr/bin/env bash
# Stub-sentinel gate: every runtime stub in shipped source must be registered in
# migration/integration-ledger.md. A "stub" is any occurrence of STUB_SENTINEL —
# a "not implemented"/placeholder marker the user can hit. The contract: each
# sentinel hit must carry its ledger id as an `INTEG-<id>` tag on the same line,
# and that id must appear in the ledger table. This turns silent stub
# accumulation into a gate failure — you cannot ship an unreachable/placeholder
# path without recording it, so the aggregate stays visible instead of hiding
# behind a placeholder string until a human launches the app.
#
# OPT-IN: does nothing until STUB_SENTINEL is set in migration/harness.env.
#   STUB_SENTINEL — extended-regex matching your runtime placeholder string
#                   (e.g. 'not yet implemented' or 'UnimplementedError').
#   STUB_SCAN     — space-separated shipped-source paths to scan (NOT tests);
#                   required when STUB_SENTINEL is set.
#
# Read-only. Needs bash + git + grep. No `set -o pipefail` (grep -q closes pipes
# early, which pipefail would misread — same reason as check-docs.sh).
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "stub-check: not a git repository"; exit 1; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && source migration/harness.env

SENTINEL="${STUB_SENTINEL:-}"
if [ -z "$SENTINEL" ]; then
  echo "stub-check: disabled (STUB_SENTINEL unset in migration/harness.env)"
  exit 0
fi

read -r -a SCAN <<< "${STUB_SCAN:-}"
if [ "${#SCAN[@]}" -eq 0 ]; then
  echo "stub-check: STUB_SENTINEL is set but STUB_SCAN is empty — set STUB_SCAN to your shipped source paths in migration/harness.env" >&2
  exit 1
fi

ledger=migration/integration-ledger.md

# Files under the scan paths, tracked or untracked-not-ignored (so build dirs,
# node_modules, .harness runtime state are skipped automatically). while-read
# instead of mapfile: stock macOS bash 3.2 has no mapfile, and this runs under
# gates.sh on whatever bash is on PATH.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done \
  < <(git ls-files -co --exclude-standard -- "${SCAN[@]}" 2>/dev/null | sort -u)

# Ledger ids: TABLE ROWS' id column only, with their state. An id merely
# MENTIONED in the ledger prose is not a registration, and the shipped
# INTEG-example row never counts — it exists to show the format, and letting it
# register real stubs would make copying the example tag onto every stub a
# universal amnesty that terminates the migration COMPLETE with live
# placeholders shipped (found by external review). The state matters too: a
# sentinel still in shipped source while its row says `wired` is a
# contradiction, not a registration. Header/column detection mirrors
# check-audits.sh, so the legend table cannot donate rows.
LEDGER_ROWS=""
if [ -f "$ledger" ]; then
  LEDGER_ROWS="$(awk -F'|' '
    function trim(s){ gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
    /^\|/ {
      n = split($0, c, "|")
      if (col == 0) {
        if (tolower(trim(c[2])) == "id")
          for (i = 3; i <= n; i++) if (tolower(trim(c[i])) == "state") { col = i; break }
        next
      }
      id = trim(c[2])
      if (id !~ /^INTEG-/) next
      print id "\t" trim(c[col])
    }
  ' "$ledger" 2>/dev/null)"
fi
row_state(){ printf '%s\n' "$LEDGER_ROWS" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'; }

fails=0
note(){ printf 'STUB: %s\n' "$1"; fails=$((fails+1)); }

for f in "${FILES[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    n=${hit%%:*}; text=${hit#*:}
    tag=$(printf '%s' "$text" | grep -oE 'INTEG-[A-Za-z0-9_.-]+' | head -n1)
    if [ -z "$tag" ]; then
      note "$f:$n  stub with no INTEG-<id> ledger tag — register it in $ledger and tag this line"
    elif [ "$tag" = "INTEG-example" ]; then
      note "$f:$n  tagged INTEG-example — the shipped format example never registers a real stub; add a real ledger row and tag this line with its id"
    else
      st="$(row_state "$tag")"
      if [ -z "$st" ]; then
        note "$f:$n  references $tag, which is not a table row in $ledger"
      elif [ "$st" = "wired" ]; then
        note "$f:$n  tagged $tag but that ledger row is 'wired' — a sentinel still in shipped source contradicts the row; wire the feature for real or reopen the row"
      fi
    fi
  done < <(grep -nEI "$SENTINEL" "$f" 2>/dev/null)   # -I: a binary match would emit a garbage note line
done

echo "----------------------------------------"
if [ -z "${FILES[*]:-}" ]; then
  echo "stub-check: no files matched STUB_SCAN (${STUB_SCAN}) — check the paths" >&2
  exit 1
fi
if [ "$fails" -eq 0 ]; then
  echo "stub-check: every shipped stub is registered in $ledger"
else
  echo "stub-check: $fails untracked stub(s) — add each to $ledger (or wire the feature so the stub is gone)"
fi
[ "$fails" -eq 0 ]
