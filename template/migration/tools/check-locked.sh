#!/usr/bin/env bash
# Locked-tooling integrity — OUTCOME-based, not action-based.
#
# WHY THIS EXISTS. The harness's own gates/hooks/config (HARNESS_LOCKED:
# migration/tools/, .claude/hooks/, .claude/settings*.json, migration/harness.env)
# are the programs that DEFINE the proof. pretooluse-command-guard (Bash) and
# pretooluse-frozen-legacy (Edit/Write) block the ACTIONS that would mutate them —
# but action interception is bypassable by construction (a subagent whose calls
# never fire the parent's PreToolUse hooks, an interpreter `python -c "open(...,'w')"`,
# a path spelled to miss a substring match). A single such write to gates.sh — turn
# it into a no-op — lets the agent then record a self-consistent "pass" over any
# tree. Locking the ACTION does not catch the bypass; nothing did, until this.
#
# So this gate never asks "is this call allowed?". It rebuilds the locked fileset's
# content hash and compares it to a committed baseline. It does not care WHICH tool
# changed a gate, WHICH agent ran it, or whether a hook fired: an edit, an added
# file, a deleted file, a mode change — any drift, by any route — fails the gate.
# It is exactly the trick check-frozen.sh uses for the oracle, pointed at the
# harness's own enforcement files instead. Verify the outcome, not the action.
#
# LIMIT (honest, same as check-frozen.sh): this check is itself a locked script,
# so an agent that neuters check-locked.sh or gates.sh in the SAME tree it gates
# defeats it. That residual is the reason CI/human review runs gates from a
# trusted checkout — the adversarial backstop the threat model already names. What
# this closes is the far larger surface: every Bash/interpreter/odd-path bypass of
# the action guards now fails a gate instead of silently voiding every later proof.
#
# BOOTSTRAP: a human records the baseline once, after configuring gates.sh for the
# stack and before slice 1:
#   bash migration/tools/check-locked.sh --record
# It refuses to overwrite an existing baseline (re-baselining is how a neutered
# gate gets re-blessed), and the agent is blocked from invoking --record at all
# (command-guard), so only a human can move the reference.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-locked: not a git repository" >&2; exit 2; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && . migration/harness.env

baseline="migration/locked-baseline.sha"
mode="${1:-verify}"

read -r -a LOCKED <<< "${HARNESS_LOCKED:-}"
if [ "${#LOCKED[@]}" -eq 0 ]; then
  echo "check-locked: HARNESS_LOCKED empty — locked-tooling integrity not enforced"
  exit 0
fi

# Resolve HARNESS_LOCKED's path fragments to an actual fileset. MUST run in the
# current shell (a subshell's arrays don't survive), or a silently-empty fileset
# hashes the empty tree forever while reporting green — the same false-pass trap
# check-frozen.sh documents.
#
# TWO deliberate exclusions:
#  - the baseline FILES (migration/locked-baseline.sha, migration/frozen-baseline.sha):
#    a baseline cannot hash itself (recording would depend on its own content), and
#    they are references, not tooling — their integrity is the trackedness + HEAD
#    checks below, not this hash.
#  - anything under .git/ : HARNESS_LOCKED may list .git/hooks as an ACTION guard
#    (blocking writes to it), but git never lists paths inside .git, so it simply
#    contributes nothing to the hash. That is correct: .git/hooks is guarded, not
#    hashed. Untracked-but-not-ignored files ARE included — dropping a new script
#    into migration/tools/ is drift too.
MATCHED=()
while IFS= read -r f; do
  case "$f" in
    migration/locked-baseline.sha|migration/frozen-baseline.sha) continue ;;
    .git/*) continue ;;
  esac
  for frag in "${LOCKED[@]}"; do
    frag="${frag%/}"
    case "$f" in *"$frag"*) MATCHED+=("$f"); break ;; esac
  done
done < <(git ls-files --cached --others --exclude-standard)

# A fragment list that matches NOTHING hashable is a misconfiguration, not a pass.
if [ "${#MATCHED[@]}" -eq 0 ]; then
  echo "check-locked: HARNESS_LOCKED ('${HARNESS_LOCKED}') matches no hashable files in this repo." >&2
  echo "  The locked tooling is NOT being verified. Fix the fragments in migration/harness.env" >&2
  echo "  (matched as substrings of tracked paths, e.g. 'migration/tools/')." >&2
  exit 1
fi

# Content hash of the locked fileset: a real git tree object, content-only and
# HEAD-independent, so committing a change does not launder it (same reasoning as
# check-frozen.sh / working-tree-hash.sh). Throwaway index inside .git.
locked_hash() {
  local gitdir tmp rc
  gitdir="$(git rev-parse --git-dir)"
  tmp="$(mktemp "$gitdir/harness-locked.XXXXXX")" || return 1
  rm -f "$tmp"
  if ! printf '%s\n' "${MATCHED[@]}" \
      | GIT_INDEX_FILE="$tmp" git add -f --pathspec-from-file=- -- 2>/dev/null; then
    echo "check-locked: cannot stage the locked fileset for hashing" >&2
    rm -f "$tmp"; return 1
  fi
  GIT_INDEX_FILE="$tmp" git write-tree; rc=$?
  rm -f "$tmp"
  return "$rc"
}

current="$(locked_hash)" || exit 1
if [ -z "$current" ]; then
  echo "check-locked: could not hash the locked fileset" >&2
  exit 1
fi

# ---- --record: human-only bootstrap ---------------------------------------
if [ "$mode" = "--record" ]; then
  if [ -f "$baseline" ]; then
    echo "check-locked: baseline already exists ($baseline) — refusing to overwrite." >&2
    echo "  Re-recording is how a neutered gate gets re-blessed: it would bless whatever the" >&2
    echo "  enforcement files contain NOW as the reference. If the tooling legitimately must" >&2
    echo "  change, delete the baseline in your own terminal, review the diff, and re-record." >&2
    exit 1
  fi
  printf '%s\n' "$current" > "$baseline"
  echo "check-locked: baseline recorded in $baseline ($current)"
  echo "  Commit it. It is kept in HARNESS_LOCKED so the agent cannot move the reference."
  exit 0
fi

# ---- verify ---------------------------------------------------------------
# OPT-IN BY PRESENCE (deliberately weaker than check-frozen's fail-closed).
# When no baseline exists this is a no-op PASS, not a hard fail. Rationale: the
# agent cannot create a valid baseline (--record is blocked; a hand-written one
# fails the HEAD/hash checks below) and cannot delete a committed one (it is in
# HARNESS_LOCKED). So once a human records+commits it during bootstrap the agent
# is fully bound and cannot turn it off — full protection — while a repo that has
# not opted in keeps today's behavior instead of bricking every gate run. doctor.sh
# nudges the human to record it. A fail-closed default would instead break the
# common "installed but not yet baselined" state and the harness's own test suite,
# which mutates these files to exercise scenarios.
if [ ! -f "$baseline" ]; then
  echo "check-locked: no locked-tooling baseline recorded — integrity of the harness's own" \
       "gates/hooks/config is NOT enforced. As a human, after configuring gates.sh, run:" \
       "bash migration/tools/check-locked.sh --record && git add $baseline"
  exit 0
fi

# An UNCOMMITTED baseline is worthless — whoever can create the file can choose
# the answer. Require it tracked, so moving the reference is a visible diff.
if ! git ls-files --error-unmatch "$baseline" >/dev/null 2>&1; then
  echo "check-locked: $baseline exists but is NOT committed. An untracked baseline can be" >&2
  echo "  authored at will, so it proves nothing. Commit it: git add $baseline" >&2
  exit 1
fi

# Read the reference from GIT, never from the working tree (a working-tree read
# would let the same bypass that mutates a gate also rewrite the baseline to
# match — exactly the laundering this exists to catch). HEAD is the reference
# when it has the file; during bootstrap (recorded + git add, first commit not
# yet made) accept the INDEX copy, still requiring the working copy to match it.
if git cat-file -e "HEAD:$baseline" 2>/dev/null; then
  if ! git diff --quiet HEAD -- "$baseline" 2>/dev/null; then
    echo "check-locked: $baseline differs from its committed (HEAD) version." >&2
    echo "  The committed baseline is the reference; an edited local copy is how a neutered" >&2
    echo "  gate gets re-blessed. Restore it: git checkout HEAD -- $baseline" >&2
    exit 1
  fi
  want="$(git show "HEAD:$baseline" 2>/dev/null | tr -d '[:space:]')"
else
  if ! git diff --quiet -- "$baseline" 2>/dev/null; then
    echo "check-locked: $baseline is staged but the working copy differs from the index." >&2
    echo "  Restore or re-stage it as a human before gating: git checkout -- $baseline" >&2
    exit 1
  fi
  want="$(git show ":$baseline" 2>/dev/null | tr -d '[:space:]')"
fi
if [ "$current" != "$want" ]; then
  echo "check-locked: LOCKED TOOLING HAS DRIFTED." >&2
  echo "  baseline: $want" >&2
  echo "  current:  $current" >&2
  echo "  The harness's own gates/hooks/config define the proof. If they can move, a 'pass'" >&2
  echo "  means nothing — and no gate run after this point is trustworthy." >&2
  echo "  Changed under HARNESS_LOCKED:" >&2
  git status --porcelain --untracked-files=all 2>/dev/null | while IFS= read -r line; do
    case "$line" in *locked-baseline.sha|*frozen-baseline.sha) continue ;; esac
    for frag in "${LOCKED[@]}"; do
      frag="${frag%/}"
      case "$line" in *"$frag"*) echo "    $line" >&2; break ;; esac
    done
  done
  echo "  Restore it (git checkout -- <paths>) — do NOT re-record the baseline." >&2
  exit 1
fi

echo "check-locked: locked tooling intact ($current)"
exit 0
