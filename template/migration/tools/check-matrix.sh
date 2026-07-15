#!/usr/bin/env bash
# Status-board validator (in-place oracle, opt-in via HARNESS_ORACLE in
# harness.env; see docs/IN-PLACE-PROFILE.md). Machine-checks what is
# otherwise prose interpreted by the same agent that selects rows:
#
#   (a) STRICT parsing - a malformed T-/M-looking row id, a duplicate row id,
#       or an unknown status spelling is an ERROR, not a silently skipped
#       row (a typo must not drop a row from validation);
#   (b) ordering - a row may only be audited-pass when every dep row named
#       in its deps cell is audited-pass; when the board uses the T-<unit> /
#       M-<unit> convention (tests-first in-place migrations), an M row may
#       only be in-progress/audited-* when ALL of its unit's T sub-rows are
#       audited-pass;
#   (c) coverage (optional seam) - if migration/tools/list-affected-units.sh
#       exists and is executable, every unit it prints (one per line) must
#       have at least one row. Wire it to your project's affected-unit scan
#       (e.g. grep for the dependency being removed) so a unit can never
#       silently miss the board. A real migration DID miss one this way.
#
# Board file: parity-matrix.md, or spec-matrix.md when HARNESS_PROFILE=feature.
# MATRIX_FILE overrides (self-tests). Requires bash + awk only.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-matrix: not a git repository" >&2; exit 2; }
# shellcheck source=/dev/null
[ -f migration/harness.env ] && source migration/harness.env

board="${MATRIX_FILE:-}"
if [ -z "$board" ]; then
  if [ "${HARNESS_PROFILE:-migration}" = "feature" ]; then board="migration/spec-matrix.md"; else board="migration/parity-matrix.md"; fi
fi
[ -f "$board" ] || { echo "check-matrix: board not found: $board" >&2; exit 1; }

units_file=""
if [ -x migration/tools/list-affected-units.sh ]; then
  units_file="$(mktemp)"
  bash migration/tools/list-affected-units.sh > "$units_file" \
    || { echo "check-matrix: list-affected-units.sh failed" >&2; rm -f "$units_file"; exit 1; }
fi

# The em-dash (a legitimate "no deps" cell) is passed in via -v: \x hex
# escapes in awk regex/string literals are a gawk/mawk extension that
# one-true-awk (macOS) does not support.
awk -F'|' -v UNITS="${units_file:-}" -v ED="$(printf '\342\200\224')" '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function err(m){ print "  " m > "/dev/stderr"; nerr++ }
BEGIN {
  valid["open"]=1; valid["split-required"]=1; valid["in-progress"]=1
  valid["audited-pass"]=1; valid["audited-fail"]=1; valid["blocked"]=1
}
/^\|/ {
  sawtable = 1
  n = split($0, c, "|")
  if (statuscol == 0) {
    # The header is the row whose FIRST cell is "id" (case-insensitive):
    # the board file holds OTHER tables first (the status-vocabulary
    # legend, headed "Status | Meaning") whose cells must not be mistaken
    # for the matrix header.
    if (tolower(trim(c[2])) == "id") {
      for (i = 3; i <= n; i++) {
        h = tolower(trim(c[i]))
        if (h == "status") statuscol = i
        if (h == "deps")   depscol = i
      }
    }
    next
  }
  id = trim(c[2])
  if (id == "" || id ~ /^[-: ]+$/ || id == "...") next
  line = NR
  # (a) strict parsing
  if (id !~ /^[A-Za-z][A-Za-z0-9_.-]*$/) { err("line " line ": malformed row id \x27" id "\x27"); next }
  if (n - 1 < statuscol)                 { err("line " line ": row " id " has too few cells"); next }
  if (id in rows)                        { err("line " line ": duplicate row id " id); next }
  st = trim(c[statuscol])
  if (!(st in valid))                    { err("line " line ": row " id " has unknown status \x27" st "\x27"); next }
  rows[id] = st
  deps[id] = (depscol > 0 && n - 1 >= depscol) ? trim(c[depscol]) : ""
}
END {
  # (b) dep ordering + T-before-M
  for (id in rows) {
    st = rows[id]
    # Normalize em-dashes (ED, from -v above) to "-" so a "no deps" cell is
    # recognized portably; row ids cannot contain an em-dash, so this is safe.
    dstr = deps[id]
    gsub(ED, "-", dstr)
    if (st == "audited-pass" && dstr != "" && dstr !~ /^[- ]*$/) {
      m = split(dstr, dtok, /[,;][ \t]*| +/)
      for (j = 1; j <= m; j++) {
        d = trim(dtok[j])
        if (d == "" || d == "-") continue
        if (!(d in rows)) { err("row " id ": dep \x27" d "\x27 not found on the board"); continue }
        if (rows[d] != "audited-pass") err("row " id " is audited-pass but dep " d " is " rows[d])
      }
    }
    if (id ~ /^M-/ && (st == "in-progress" || st == "audited-pass" || st == "audited-fail")) {
      unit = id; sub(/^M-/, "", unit); sub(/\..*$/, "", unit)
      tfound = 0; tbad = ""
      for (r in rows) {
        if (r == "T-" unit || index(r, "T-" unit ".") == 1) {
          tfound = 1
          if (rows[r] != "audited-pass") tbad = tbad " " r "(" rows[r] ")"
        }
      }
      if (!tfound)        err("row " id " is " st " but there is no T-" unit " row")
      else if (tbad != "") err("row " id " is " st " but T sub-row(s) not audited-pass:" tbad)
    }
  }
  # (c) coverage via the optional seam. A row covers a unit only when its
  # BASE id (T-/M- prefix and .sub suffix stripped) EQUALS the unit —
  # substring matching counted unit "net" as covered by row "T-network",
  # the exact silent miss this check exists to catch.
  if (UNITS != "") {
    while ((getline u < UNITS) > 0) {
      u = trim(u); if (u == "") continue
      covered = 0
      for (r in rows) {
        base = r; sub(/^[TM]-/, "", base); sub(/\..*$/, "", base)
        if (base == u) { covered = 1; break }
      }
      if (!covered) err("coverage: affected unit \x27" u "\x27 has no row on the board")
    }
  }
  # A validator that parsed NOTHING must not report green: a reformatted
  # header (no cell reading exactly status) previously consumed every row
  # in the header hunt and exited 0 with "0 row(s) validated".
  if (sawtable && statuscol == 0) err("no header row with first cell \x27id\x27 and a \x27status\x27 column found - the board cannot be validated")
  else if (length(rows) == 0)     err("no data rows parsed - an empty board validates nothing")
  if (nerr > 0) { print "check-matrix: " nerr " problem(s) on " ARGV[1] > "/dev/stderr"; exit 1 }
  printf "check-matrix: %d row(s) validated on %s\n", length(rows), ARGV[1]
}
' "$board"
rc=$?
[ -n "$units_file" ] && rm -f "$units_file"
exit "$rc"
