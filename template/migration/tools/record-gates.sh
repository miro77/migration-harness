#!/usr/bin/env bash
# Record proof that gates passed for the exact current tree state.
# Called by gates.sh ONLY after all gates succeeded. The Stop hook compares
# against this. Never call manually to fake a pass — that defeats the harness.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p .harness/state
bash migration/tools/working-tree-hash.sh > .harness/state/gates-passed.diffsha

# Also snapshot the status board(s) as they stood when the gates passed.
# check-audits.sh compares against THIS snapshot — not HEAD — to decide which
# audited-pass rows are new claims: a board state can only enter the snapshot
# by first passing check-audits, so writing `audited-pass` and committing it
# BEFORE gating no longer exempts the row (git commit is un-gated; "it is at
# HEAD" proves only that someone committed the claim — found by external
# review). Like the proof file, never write these by hand.
for b in migration/parity-matrix.md migration/spec-matrix.md; do
  if [ -f "$b" ]; then cp "$b" ".harness/state/gates-passed.${b##*/}"; fi
done
