#!/usr/bin/env bash
# PreToolUse guard for Edit/Write/NotebookEdit: the legacy source is the
# frozen oracle. Blocks edits under any path fragment in HARNESS_FROZEN.
# Probes and adapters belong in probes/ (or your designated new-code dir).
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f migration/harness.env ] || exit 0
# shellcheck source=/dev/null
source migration/harness.env

input=$(cat)
fp=$(printf '%s' "$input" | tr '\n\r' '  ' \
  | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\(\(\\.\|[^"\\]\)*\)".*/\1/p')
[ -z "$fp" ] && exit 0

# normalize JSON-escaped backslashes to single forward slashes
norm=$(printf '%s' "$fp" | tr '\\' '/' | tr -s '/')

# Only guard paths inside THIS repository. Fragment matching on the raw path
# would otherwise block same-shaped paths in OTHER repos on the same machine
# (verified: editing a template/vendored copy of the harness elsewhere was
# blocked because its path contains ".claude/hooks/").
root="$(pwd -P)"
case "$norm" in
  /*) case "$norm" in "$root"/*) ;; *) exit 0 ;; esac ;;
esac

# The gate proof is written only by gates.sh on a real pass — never by hand.
# Match on the (unique) filename so dot-segment path variants
# (.harness/./state/..., .../state/../state/...) can't slip past. Enforced
# regardless of HARNESS_FROZEN/HARNESS_LOCKED so an empty config never reopens it.
case "$norm" in
  *gates-passed.diffsha)
    echo "Blocked: the gate proof (.harness/state/gates-passed.diffsha) is written only by gates.sh on a successful run — don't edit it directly. Run: bash migration/tools/gates.sh" >&2
    exit 2 ;;
esac

# Locked enforcement files: the harness's own gates/hooks/config. Blocking the
# Edit/Write path here; pretooluse-command-guard.sh blocks the Bash-write path.
for frag in ${HARNESS_LOCKED:-}; do
  case "$norm" in
    *"$frag"*)
      echo "Blocked: '$frag' is a LOCKED harness enforcement file (HARNESS_LOCKED) — the agent must not weaken its own gates/hooks/config. A human edits these outside the agent session. See CLAUDE.md." >&2
      exit 2 ;;
  esac
done

for frag in ${HARNESS_FROZEN:-}; do
  case "$norm" in
    *"$frag"*)
      echo "Blocked: '$frag' is FROZEN legacy oracle source — it must stay byte-identical to remain a trustworthy migration reference. New probe/adapter code goes in probes/. See CLAUDE.md hard rule 1." >&2
      exit 2 ;;
  esac
done

exit 0
