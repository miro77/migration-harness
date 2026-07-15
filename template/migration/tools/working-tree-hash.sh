#!/usr/bin/env bash
# Content hash of the migration-relevant working tree state.
#
# The hash is a real git tree object built over the scoped paths, so it is
# CONTENT-ONLY and HEAD-INDEPENDENT: the same file contents always hash the
# same, whether committed or not. Running gates then committing exactly those
# changes keeps the proof valid; any UN-gated change (committed or not) produces
# a different hash. Deletions, renames, and the executable/symlink bits git
# tracks are all represented, because presence/content in the freshly built
# tree is what is hashed — not the text of `git status`/`git diff`.
#
# Scoped via HARNESS_SCOPE so unrelated (frozen legacy) working-tree noise does
# not invalidate proofs. Do not edit to widen/narrow scope — change harness.env.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# shellcheck source=/dev/null
source migration/harness.env
read -r -a SCOPE <<< "${HARNESS_SCOPE:-}"

# Put the throwaway index INSIDE the git dir. git never stages anything under
# .git, so the index (and its .lock) can never leak into the hash — this holds
# regardless of TMPDIR or a HARNESS_SCOPE of ".". The real index is untouched
# (GIT_INDEX_FILE override).
gitdir="$(git rev-parse --git-dir)"
tmp_index="$(mktemp "$gitdir/harness-index.XXXXXX")"
rm -f "$tmp_index"                       # git wants an absent or valid index file
trap 'rm -f "$tmp_index"' EXIT

# Seed the throwaway index with HEAD's version of the scoped paths BEFORE the
# `git add`. Into an EMPTY index, `git add -A` treats every file as untracked,
# so a file that is tracked in HEAD but matched by .gitignore (a pattern added
# after the file was committed, never untracked) would be silently SKIPPED —
# edits to it would never move the hash, and the Stop hook would wave through
# un-gated changes to it (verified). Seeding makes those files tracked in the
# throwaway index too, so `git add -A` updates and deletes them exactly as it
# would against the real index. It also keeps this hash consistent with the
# Stop hook's committed-tree rebuild (hash_commit), which is ls-tree-based and
# always saw them. .harness is filtered here for the same reason it is
# excluded from the add below. A repo with no commits yet has nothing to seed.
if git rev-parse -q --verify HEAD >/dev/null 2>&1 && [ "${#SCOPE[@]}" -gt 0 ]; then
  git ls-tree -r HEAD -- ${SCOPE[@]+"${SCOPE[@]}"} 2>/dev/null \
    | awk -F '\t' '$2 !~ /^\.harness($|\/)/ { split($1, m, " "); print m[1] " " m[3] "\t" $2 }' \
    | GIT_INDEX_FILE="$tmp_index" git update-index --index-info
fi

# Add scope entries that exist on disk OR were seeded from HEAD. A seeded entry
# whose working copy was deleted MUST still be passed to `git add -A` so the
# deletion is staged out of the seed — otherwise the rebuilt tree would keep
# showing HEAD's copy and a deletion would stop changing the hash. An entry in
# neither place would make `git add` fail on an unmatched pathspec; skip those.
PATHS=()
for p in ${SCOPE[@]+"${SCOPE[@]}"}; do
  if [ -e "$p" ] || [ -n "$(GIT_INDEX_FILE="$tmp_index" git ls-files -- "$p" 2>/dev/null)" ]; then
    PATHS+=("$p")
  fi
done

# Exclude the local proof state from the hash so a proof can never reference
# itself (independent of whether the target repo .gitignores .harness/).
#
# The exclude pathspec is only needed when .harness is NOT gitignored — then it
# stops the proof dir being staged as an untracked file. When .harness IS
# gitignored, `git add -A` already skips it, AND passing the explicit exclude
# would make git error out on the ignored path ("paths are ignored... use -f"),
# failing the gate. So add the exclude only when .harness isn't already ignored.
if [ "${#PATHS[@]}" -gt 0 ]; then
  excl=()
  git check-ignore -q .harness 2>/dev/null || excl=(':(exclude).harness')
  # Stage entry by entry so a refusal NAMES the offending scope entry. The
  # classic trap: an entry inside a gitignored directory (e.g. a committed
  # tools dir shadowed by a generic '**/build' pattern) makes `git add`
  # refuse the pathspec ("paths are ignored... use -f"), which otherwise
  # surfaces only as "no hash" and a closed Stop hook.
  # ${excl[@]+...}: expanding an EMPTY array under set -u is an 'unbound
  # variable' error on bash <= 4.3 (macOS system bash) — and empty is the
  # default install (.harness gitignored). The +-expansion emits nothing
  # when the array is empty and the quoted elements when it is not.
  for p in "${PATHS[@]}"; do
    if ! GIT_INDEX_FILE="$tmp_index" git add -A -- "$p" ${excl[@]+"${excl[@]}"} 2>/dev/null; then
      echo "working-tree-hash: HARNESS_SCOPE entry '$p' cannot be staged for hashing" >&2
      echo "  (most likely it is inside a gitignored directory - re-include it in" >&2
      echo "  .gitignore, e.g. '!/$p/', or remove it from HARNESS_SCOPE)" >&2
      exit 1
    fi
  done
fi
GIT_INDEX_FILE="$tmp_index" git write-tree
