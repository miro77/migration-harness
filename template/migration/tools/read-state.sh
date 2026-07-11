#!/usr/bin/env bash
# Read intermediate slice state persisted by persist-state.sh.
#
# Usage:
#   bash migration/tools/read-state.sh <key>
#
# Prints the stored value to stdout. Exits 1 if no state exists for the key
# (so the caller can fall back to a default or start fresh).
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "read-state: not a git repository" >&2; exit 1; }

key="${1:?usage: read-state.sh <key>}"
safe=$(printf '%s' "$key" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')
file=.harness/state/slice-state/$safe

if [ -f "$file" ]; then
  cat "$file"
else
  echo "read-state: no state for key '$key' (file: $file)" >&2
  exit 1
fi
