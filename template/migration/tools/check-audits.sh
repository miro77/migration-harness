#!/usr/bin/env bash
# Hard rule 10 ("audits are performed by a fresh-context subagent") was, until
# now, prose. /migrate-slice ASKED the model to spawn the auditor; nothing checked
# that it had. On a live migration a tick wrote `audited-pass` into the matrix
# before the auditor returned — gates were green, it felt done — and downstream
# ticks trust the status field without re-checking. This gate makes the rule
# mechanical.
#
# WHAT IT CHECKS. Any row that is `audited-pass` on the board NOW but was not
# `audited-pass` at the last SUCCESSFUL gate run (the snapshot record-gates.sh
# writes) is a claim being made since then. Each such row must have an audit
# record (written by record-audit.sh, i.e. by the auditor when it actually
# finished) whose verdict is `pass` and whose code-hash equals the current
# audit-hash. So:
#
#   * claiming audited-pass with no audit at all      -> FAIL (no record)
#   * claiming audited-pass before the auditor returns -> FAIL (no record yet)
#   * auditing, then editing the code, then claiming   -> FAIL (hash moved)
#
# Rows already `audited-pass` in the snapshot are not re-checked: a board state
# only enters the snapshot by passing this gate first, and re-verifying old rows
# against a hash that every later slice legitimately moves would fail every
# board forever. The snapshot — not HEAD — is the reference because `git commit`
# is un-gated: "audited-pass at HEAD" proves only that someone committed the
# claim, so write-row -> commit -> gate would launder exactly the failure this
# gate exists to stop (found by external review). HEAD is trusted only as a
# bootstrap fallback when no snapshot exists yet (fresh clone, first gate run),
# where committed history is the best evidence available.
#
# HONEST LIMIT. record-audit.sh is a script, and the main agent can run scripts.
# This does not stop a model that deliberately forges a verdict for code it never
# audited; nothing at this layer can (see the threat model in CLAUDE.md — the
# hooks are guard rails for an honest agent, not an adversarial sandbox). What it
# does close is the failure that actually happens: claiming the audit passed
# without, or before, running it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-audits: not a git repository" >&2; exit 2; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && . migration/harness.env

case "${HARNESS_PROFILE:-migration}" in
  feature) board="migration/spec-matrix.md" ;;
  *)       board="migration/parity-matrix.md" ;;
esac
[ -f "$board" ] || { echo "check-audits: board not found: $board" >&2; exit 1; }

# id<TAB>status for every data row. The header is the row whose FIRST cell is
# "id" (case-insensitive), so the status-vocabulary legend table cannot donate
# the column — same rule as check-baselines.sh/check-matrix.sh.
parse_board() {
  awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\|/ {
      saw = 1
      n = split($0, c, "|")
      if (col == 0) {
        if (tolower(trim(c[2])) == "id")
          for (i = 3; i <= n; i++) if (tolower(trim(c[i])) == "status") { col = i; break }
        next
      }
      id = trim(c[2])
      if (id == "" || id ~ /^:?-+:?$/) next        # separator row
      print id "\t" trim(c[col])
    }
    END { if (saw && col == 0) print "__NO_STATUS_COLUMN__\t-" }
  ' "$1"
}

now="$(parse_board "$board")"
case "$now" in
  *__NO_STATUS_COLUMN__*)
    echo "check-audits: $board has a table but no 'status' header column — cannot locate row statuses" >&2
    exit 1 ;;
esac

# The board as it stood at the last successful gate run (see the header). The
# HEAD fallback covers a fresh clone / first gate run only.
snap=".harness/state/gates-passed.${board##*/}"
prev=""
if [ -f "$snap" ]; then
  prev="$(parse_board "$snap")"
elif git cat-file -e "HEAD:$board" 2>/dev/null; then
  tmp_prev="$(mktemp)"
  git show "HEAD:$board" > "$tmp_prev" 2>/dev/null
  prev="$(parse_board "$tmp_prev")"
  rm -f "$tmp_prev"
fi

current_hash="$(bash migration/tools/audit-hash.sh 2>/dev/null)"
if [ -z "$current_hash" ]; then
  echo "check-audits: could not compute the audit hash (migration/tools/audit-hash.sh)" >&2
  exit 1
fi

rc=0
while IFS="$(printf '\t')" read -r id status; do
  [ -n "$id" ] || continue
  [ "$status" = "audited-pass" ] || continue

  # Already audited-pass at the last gate run -> went through this gate then.
  was="$(printf '%s\n' "$prev" | awk -F'\t' -v k="$id" '$1==k {print $2; exit}')"
  [ "$was" = "audited-pass" ] && continue

  rec=".harness/state/audits/$id"
  if [ ! -f "$rec" ]; then
    echo "check-audits: row '$id' is audited-pass but NO audit was recorded." >&2
    echo "  The status field is what downstream ticks trust without re-checking, so writing" >&2
    echo "  it before the auditor returns is a fabricated claim even if the audit later agrees." >&2
    echo "  Spawn the fresh-context auditor; it records its verdict itself:" >&2
    echo "    bash migration/tools/record-audit.sh $id pass|fail" >&2
    rc=1
    continue
  fi

  rec_hash="$(awk '{print $1; exit}' "$rec" 2>/dev/null)"
  rec_verdict="$(awk '{print $2; exit}' "$rec" 2>/dev/null)"

  if [ "$rec_verdict" != "pass" ]; then
    echo "check-audits: row '$id' is audited-pass but the recorded verdict is '$rec_verdict'." >&2
    echo "  Record the board honestly (audited-fail) or fix the code and re-audit." >&2
    rc=1
    continue
  fi

  if [ "$rec_hash" != "$current_hash" ]; then
    echo "check-audits: row '$id' was audited against DIFFERENT code than is now in the tree." >&2
    echo "    audited: $rec_hash" >&2
    echo "    current: $current_hash" >&2
    echo "  The code changed after the audit returned, so the audit no longer covers it." >&2
    echo "  Re-run the fresh-context auditor on the current tree." >&2
    rc=1
    continue
  fi
done <<EOF
$now
EOF

[ "$rc" -eq 0 ] || exit 1
echo "check-audits: every newly audited-pass row has a matching fresh-context audit"
exit 0
