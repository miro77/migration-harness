#!/usr/bin/env bash
# ADR immutability — migration/decisions.md says it in prose ("Accepted ADRs are
# immutable; corrections are new ADRs with Supersedes"); this makes it mechanical.
#
# decisions.md is bookkeeping: the agent edits it EVERY slice (new ADRs, PENDING
# updates, the approved-deps table) and it is excluded from the audit hash. So
# nothing stopped an agent from silently REWRITING the rationale of a decision
# that was already accepted — rewriting history instead of superseding it. This
# gate compares the working tree against HEAD and refuses any change to the
# title/body of an ADR that was already `accepted` (or `superseded`) at HEAD, and
# refuses deleting one. The ONLY allowed change to such an ADR is its status
# token transitioning (e.g. `(accepted)` -> `(superseded by ADR-0007)`); to
# correct a decision, add a NEW ADR that supersedes it. (Idea adapted from
# pt9912/ddd-agent-rules' doc-immutable.)
#
# No-op when HEAD has no decisions.md or no closed ADR blocks (a fresh install,
# or a project not using the ADR format). Read-only. bash + git + awk.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-adr-immutable: not a git repository" >&2; exit 1; }

f=migration/decisions.md

# Nothing committed yet (first commit / fresh install) -> nothing is immutable.
git cat-file -e "HEAD:$f" 2>/dev/null || { echo "check-adr-immutable: no committed $f yet — nothing to protect"; exit 0; }
[ -f "$f" ] || {
  echo "check-adr-immutable: $f existed at HEAD but is GONE from the working tree — an accepted-decision ledger must not be deleted. Restore it: git checkout -- $f" >&2
  exit 1
}

# ids of ADR-NNNN blocks whose status token is a CLOSED one (accepted/superseded/
# deprecated) — i.e. immutable. Reads a decisions.md on stdin.
closed_ids() {
  awk '
    /^## ADR-[0-9]+/ {
      id=""; if (match($0, /ADR-[0-9]+/)) id=substr($0, RSTART, RLENGTH)
      st=""; if (match($0, /\(([^)]*)\)[[:space:]]*$/)) st=substr($0, RSTART+1, RLENGTH-2)
      sub(/[[:space:]].*/, "", st)               # first word of the status token
      st=tolower(st)
      if (id != "" && (st=="accepted" || st=="superseded" || st=="deprecated")) print id
    }'
}

# Normalized block for one ADR id: the heading with its trailing (status) token
# stripped, then the body up to the next heading. Status-agnostic on purpose, so
# a pure status transition compares equal. Reads a decisions.md on stdin.
adr_block() {
  awk -v want="$1" '
    /^#{1,6} / {
      id=""; if ($0 ~ /^## ADR-[0-9]+/ && match($0, /ADR-[0-9]+/)) id=substr($0, RSTART, RLENGTH)
      if (id == want) {
        h=$0; sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", h)   # drop trailing (status)
        print h; inblk=1; next
      }
      inblk=0; next            # any other heading ends the block
    }
    inblk { print }'
}

head_src="$(git show "HEAD:$f" 2>/dev/null)"
ids="$(printf '%s\n' "$head_src" | closed_ids)"
[ -n "$ids" ] || { echo "check-adr-immutable: no accepted/superseded ADRs at HEAD — nothing to protect"; exit 0; }

rc=0
for id in $ids; do
  # Capture BOTH blocks the same way ($(...) strips trailing newlines equally),
  # then hash identically — otherwise a pipeline vs a capture differ by a
  # trailing newline and identical blocks hash differently.
  want_block="$(printf '%s\n' "$head_src" | adr_block "$id")"
  cur_block="$(adr_block "$id" < "$f")"
  if [ -z "$cur_block" ]; then
    echo "check-adr-immutable: $id was an accepted decision at HEAD but is GONE from $f." >&2
    echo "  Accepted ADRs are immutable — supersede with a new ADR, never delete. Restore $id." >&2
    rc=1; continue
  fi
  want_hash="$(printf '%s' "$want_block" | git hash-object --stdin 2>/dev/null)"
  cur_hash="$(printf '%s' "$cur_block" | git hash-object --stdin 2>/dev/null)"
  if [ "$cur_hash" != "$want_hash" ]; then
    echo "check-adr-immutable: $id was accepted at HEAD but its title/body CHANGED in the working tree." >&2
    echo "  Accepted ADRs are immutable (see the top of $f). To correct the decision, add a NEW" >&2
    echo "  ADR that Supersedes $id and flip $id's status to '(superseded by ADR-XXXX)' — do not" >&2
    echo "  rewrite its rationale. (A status-only transition is allowed and does not trip this.)" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] || exit 1
echo "check-adr-immutable: accepted ADRs unchanged since HEAD"
exit 0
