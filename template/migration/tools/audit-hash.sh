#!/usr/bin/env bash
# Content hash of the CODE an audit covered: HARNESS_SCOPE minus the bookkeeping
# files that legitimately change AFTER an auditor returns — the status board, the
# integration ledger, decisions, the handoff.
#
# Why not just reuse working-tree-hash.sh? Because an audit record bound to the
# FULL scope hash self-invalidates: the auditor returns, the agent writes the row
# it just audited, the hash moves, and the record no longer matches the tree it
# was made for. Excluding the bookkeeping files makes the record answer the only
# question that matters — "is the CODE still what the auditor read?" — so a code
# edit after the audit still invalidates it, which is the point.
#
# The exclusion list is HARDCODED and never read from the environment. An
# env-tunable exclude on a hashing tool is a laundering primitive: the agent sets
# the variable and the proof silently stops covering whatever it names. Same
# reason this file is HARNESS_LOCKED.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "audit-hash: not a git repository" >&2; exit 1; }

# A missing harness.env must produce a diagnostic (like the sibling tools), not
# a raw `set -e` abort mid-source — and never a silently-empty scope hash.
[ -f migration/harness.env ] || { echo "audit-hash: migration/harness.env not found - is the harness installed here?" >&2; exit 1; }
# shellcheck source=/dev/null
source migration/harness.env
read -r -a SCOPE <<< "${HARNESS_SCOPE:-}"

PATHS=()
for p in ${SCOPE[@]+"${SCOPE[@]}"}; do [ -e "$p" ] && PATHS+=("$p"); done

gitdir="$(git rev-parse --git-dir)"
tmp_index="$(mktemp "$gitdir/harness-audit-index.XXXXXX")"
rm -f "$tmp_index"
trap 'rm -f "$tmp_index"' EXIT

if [ "${#PATHS[@]}" -gt 0 ]; then
  excl=(':(exclude)migration/parity-matrix.md'
        ':(exclude)migration/spec-matrix.md'
        ':(exclude)migration/integration-ledger.md'
        ':(exclude)migration/decisions.md'
        ':(exclude)migration/HANDOFF.md')
  # Only exclude .harness explicitly when it is NOT already gitignored: naming an
  # ignored path in a pathspec makes `git add` error out ("paths are ignored"),
  # which would fail the gate. Same dance as working-tree-hash.sh.
  git check-ignore -q .harness 2>/dev/null || excl+=(':(exclude).harness')
  for p in "${PATHS[@]}"; do
    if ! GIT_INDEX_FILE="$tmp_index" git add -A -- "$p" "${excl[@]}" 2>/dev/null; then
      echo "audit-hash: HARNESS_SCOPE entry '$p' cannot be staged for hashing" >&2
      exit 1
    fi
  done
fi
GIT_INDEX_FILE="$tmp_index" git write-tree
