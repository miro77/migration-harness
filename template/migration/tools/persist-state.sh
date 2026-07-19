#!/usr/bin/env bash
# Persist intermediate slice state to survive context compaction.
#
# The virtual-filesystem analogue: long-running tasks exceed the context
# window, and without a persistent store the agent loses its work. This
# tool writes a key-value pair to .harness/state/slice-state/ so a fresh
# session (or the context after compaction) can resume from the last
# checkpoint.
#
# Usage:
#   echo '{"step":2,"result":"..."}' | bash migration/tools/persist-state.sh <key>
#   bash migration/tools/persist-state.sh <key> < file.json
#
# The key is sanitised to a filename-safe string. State is local (gitignored
# via .harness/) and regenerated per session — it is working memory, not a
# committed artifact. For committed state, use the parity matrix and
# migration/HANDOFF.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "persist-state: not a git repository" >&2; exit 1; }

key="${1:?usage: persist-state.sh <key>  (reads value from stdin)}"
# Sanitise: keep alnum, dash, underscore, dot; replace everything else.
safe=$(printf '%s' "$key" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')
[ -n "$safe" ] || { echo "persist-state: key sanitised to empty — use a meaningful key" >&2; exit 1; }
# Disambiguate LOSSY sanitisation: 'foo/bar' and 'foo_bar' both sanitise to
# 'foo_bar' and would share one file, silently clobbering each other. When the
# sanitised form differs from the raw key, suffix a short hash of the RAW key so
# distinct keys never collide. Already-safe keys keep their bare name (and
# read-state.sh applies the identical rule, so the round-trip matches).
[ "$safe" = "$key" ] || safe="${safe}.$(printf '%s' "$key" | cksum | cut -d' ' -f1)"

dir=.harness/state/slice-state
mkdir -p "$dir"
# Atomic write: a concurrent read-state must never see a half-written value.
tmp="$dir/.$safe.tmp.$$"
cat > "$tmp"
mv -f "$tmp" "$dir/$safe"
printf 'persisted: %s\n' "$dir/$safe" >&2
