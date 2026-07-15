#!/usr/bin/env bash
# Frozen-oracle integrity — OUTCOME-based, not action-based.
#
# WHY THIS EXISTS. pretooluse-frozen-legacy.sh (Edit/Write) and command-guard
# (Bash) block the ACTIONS that would mutate the oracle. Action interception is
# bypassable by construction, and the bypasses are documented, not theoretical:
# a subagent whose tool calls never fire the parent session's PreToolUse hooks
# (anthropics/claude-code#43772), an interpreter (`python -c "open(...,'w')"`),
# a path spelled to miss a substring match. Every one of those defeats a guard
# that asks "is this call allowed?".
#
# So this gate never asks that. It rebuilds the frozen fileset's content hash and
# compares it to a committed baseline. It does not care WHICH tool changed the
# oracle, WHICH agent ran it, or whether a hook fired: an edit, an added file, a
# deleted file, a mode change — any drift, by any route — fails the gate. Every
# bypass of the action check becomes moot, permanently, without chasing regexes.
#
# It is the same trick the Stop hook already uses for HARNESS_SCOPE, pointed at
# the oracle instead. Verify the outcome, not the action.
#
# BOOTSTRAP: a human records the baseline once, before slice 1:
#   bash migration/tools/check-frozen.sh --record
# It refuses to overwrite an existing baseline — re-baselining is exactly how
# drift gets laundered — and the agent is blocked from invoking --record at all
# (command-guard), so only a human can ever move the reference.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-frozen: not a git repository" >&2; exit 2; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && . migration/harness.env

baseline="migration/frozen-baseline.sha"
mode="${1:-verify}"

read -r -a FROZEN <<< "${HARNESS_FROZEN:-}"
if [ "${#FROZEN[@]}" -eq 0 ]; then
  echo "check-frozen: HARNESS_FROZEN empty (in-place profile) — no frozen oracle to verify"
  exit 0
fi

# Resolve HARNESS_FROZEN's path fragments to an actual fileset. This MUST run in
# the current shell, not inside a command substitution: a subshell's variables do
# not survive, and a silently-empty fileset hashes the empty tree forever while
# reporting green — a false pass on the one check the whole parity argument rests
# on. (That exact bug was caught by the self-test before this shipped.)
#
# Untracked-but-not-ignored files are included deliberately: ADDING a file under
# the oracle is drift too — a "helper" dropped into legacy/src is new oracle
# behavior, and a naive "compare the files we already know about" check is blind
# to it.
MATCHED=()
while IFS= read -r f; do
  for frag in "${FROZEN[@]}"; do
    case "$f" in *"$frag"*) MATCHED+=("$f"); break ;; esac
  done
done < <(git ls-files --cached --others --exclude-standard)

# A fragment list that matches NOTHING is a misconfiguration, not a pass.
if [ "${#MATCHED[@]}" -eq 0 ]; then
  echo "check-frozen: HARNESS_FROZEN ('${HARNESS_FROZEN}') matches no files in this repo." >&2
  echo "  The oracle is NOT being verified. Fix the fragments in migration/harness.env" >&2
  echo "  (they are matched as substrings of tracked paths, e.g. 'legacy/src')." >&2
  exit 1
fi

# Content hash of the frozen fileset: a real git tree object, so it is
# content-only and HEAD-independent — committing the oracle does not launder
# drift, exactly as the Stop hook's scope proof does not launder an un-gated
# commit. The throwaway index lives inside .git, where git never stages anything,
# so the index can never leak into the hash (same reasoning as
# working-tree-hash.sh). One `git add` for the whole set, not one per file: a
# real oracle is thousands of files and a per-file fork makes the gate crawl.
frozen_hash() {
  local gitdir tmp rc
  gitdir="$(git rev-parse --git-dir)"
  tmp="$(mktemp "$gitdir/harness-frozen.XXXXXX")" || return 1
  rm -f "$tmp"
  if ! printf '%s\n' "${MATCHED[@]}" \
      | GIT_INDEX_FILE="$tmp" git add -f --pathspec-from-file=- -- 2>/dev/null; then
    echo "check-frozen: cannot stage the frozen fileset for hashing" >&2
    rm -f "$tmp"; return 1
  fi
  GIT_INDEX_FILE="$tmp" git write-tree; rc=$?
  rm -f "$tmp"
  return "$rc"
}

current="$(frozen_hash)" || exit 1
if [ -z "$current" ]; then
  echo "check-frozen: could not hash the frozen fileset" >&2
  exit 1
fi

# ---- --record: human-only bootstrap ---------------------------------------
if [ "$mode" = "--record" ]; then
  if [ -f "$baseline" ]; then
    echo "check-frozen: baseline already exists ($baseline) — refusing to overwrite." >&2
    echo "  Re-recording is how oracle drift gets laundered: it would bless whatever the" >&2
    echo "  tree contains NOW as the reference. If the oracle legitimately must change," >&2
    echo "  delete the baseline in your own terminal, review the diff, and re-record." >&2
    exit 1
  fi
  printf '%s\n' "$current" > "$baseline"
  echo "check-frozen: baseline recorded in $baseline ($current)"
  echo "  Commit it, and keep it in HARNESS_LOCKED so the agent cannot move the reference."
  exit 0
fi

# ---- verify ---------------------------------------------------------------
if [ ! -f "$baseline" ]; then
  echo "check-frozen: no frozen baseline recorded ($baseline is missing)." >&2
  echo "  The oracle is unverified, which is UNPROVEN, not a pass. As a human, run:" >&2
  echo "    bash migration/tools/check-frozen.sh --record && git add $baseline" >&2
  exit 1
fi

# An UNCOMMITTED baseline is worthless — whoever can create the file can choose
# the answer. Require it tracked, so moving the reference is a visible diff.
if ! git ls-files --error-unmatch "$baseline" >/dev/null 2>&1; then
  echo "check-frozen: $baseline exists but is NOT committed. An untracked baseline can be" >&2
  echo "  authored at will, so it proves nothing. Commit it: git add $baseline" >&2
  exit 1
fi

# Read the reference from GIT, never from the working tree. Trackedness alone
# proves nothing about the working COPY: mutate the oracle by any of the hook
# bypasses the header lists, write the drifted hash into the working-tree
# baseline by the same route, and a working-tree read would report "intact" —
# exactly the laundering this outcome check exists to catch. When HEAD has the
# file, HEAD is the reference and ANY divergence of the index/working copy from
# it is itself treated as tampering. During bootstrap (recorded and `git add`ed,
# first commit not made yet) HEAD lacks it: accept the INDEX copy then, still
# requiring the working copy to match the index.
if git cat-file -e "HEAD:$baseline" 2>/dev/null; then
  if ! git diff --quiet HEAD -- "$baseline" 2>/dev/null; then
    echo "check-frozen: $baseline differs from its committed (HEAD) version." >&2
    echo "  The committed baseline is the reference; an edited local copy is how oracle" >&2
    echo "  drift gets laundered. Restore it: git checkout HEAD -- $baseline" >&2
    exit 1
  fi
  want="$(git show "HEAD:$baseline" 2>/dev/null | tr -d '[:space:]')"
else
  if ! git diff --quiet -- "$baseline" 2>/dev/null; then
    echo "check-frozen: $baseline is staged but the working copy differs from the index." >&2
    echo "  Restore or re-stage it as a human before gating: git checkout -- $baseline" >&2
    exit 1
  fi
  want="$(git show ":$baseline" 2>/dev/null | tr -d '[:space:]')"
fi
if [ "$current" != "$want" ]; then
  echo "check-frozen: FROZEN ORACLE HAS DRIFTED." >&2
  echo "  baseline: $want" >&2
  echo "  current:  $current" >&2
  echo "  The legacy tree is the reference behavior is measured against. If it can move," >&2
  echo "  parity means nothing — and no gate run after this point is trustworthy." >&2
  echo "  Changed under HARNESS_FROZEN:" >&2
  git status --porcelain --untracked-files=all 2>/dev/null | while IFS= read -r line; do
    for frag in "${FROZEN[@]}"; do
      case "$line" in *"$frag"*) echo "    $line" >&2; break ;; esac
    done
  done
  echo "  Restore it (git checkout -- <paths>) — do NOT re-record the baseline." >&2
  exit 1
fi

# ---- linkage scan (opt-in via HARNESS_LINKAGE_SCAN) ------------------------
# A frozen oracle stops the agent EDITING the reference. It does not stop the
# port from CALLING it — and a port that shells out to the legacy binary, or
# links the legacy library, passes every parity fixture perfectly while having
# migrated nothing. (MirrorCode, arXiv 2606.30182, removes the reference during
# scoring for exactly this reason; we cannot, so we scan for the dependency.)
#
# Opt-in, because a generic scan cannot tell a real runtime dependency from the
# string "legacy/src" in a comment, and a false gate failure on a LOCKED tool is
# unfixable by the agent. Set it to your TARGET source paths only (never
# migration/ or the docs, which name the oracle legitimately).
if [ -n "${HARNESS_LINKAGE_SCAN:-}" ]; then
  read -r -a LSCAN <<< "$HARNESS_LINKAGE_SCAN"
  lrc=0
  for p in ${LSCAN[@]+"${LSCAN[@]}"}; do
    [ -e "$p" ] || continue
    for frag in "${FROZEN[@]}"; do
      # Capture, THEN test. The obvious `grep -r | head -5 | grep -q .` is a
      # false-pass generator under pipefail: with many matches head exits after
      # 5 lines, grep -r dies of SIGPIPE (141), the pipeline is "false", and the
      # MORE linkage there is the more likely the gate misses it (verified).
      hits="$(grep -rInI -- "$frag" "$p" 2>/dev/null | head -5)" || true
      if [ -n "$hits" ]; then
        echo "check-frozen: target tree '$p' references the frozen oracle ('$frag'):" >&2
        printf '%s\n' "$hits" | sed 's/^/    /' >&2
        echo "  A port that calls the oracle passes parity trivially without migrating" >&2
        echo "  anything. Remove the dependency, or narrow HARNESS_LINKAGE_SCAN." >&2
        lrc=1
      fi
    done
  done
  [ "$lrc" -eq 0 ] || exit 1
fi

echo "check-frozen: oracle intact ($current)"
exit 0
