#!/usr/bin/env bash
# Record proof that gates passed for the exact current tree state.
# Called by gates.sh ONLY after all gates succeeded. The Stop hook compares
# against this. Never call manually to fake a pass — that defeats the harness.
set -euo pipefail

# Defense-in-depth: this script writes the gate proof and must run only from
# gates.sh, which sets HARNESS_GATES_ACTIVE=1 after every gate has passed. A
# direct invocation (the shortest forgery: write a valid-looking proof without
# running the gates) is missing the sentinel and refused here. This is NOT a
# security boundary — an agent can prepend `HARNESS_GATES_ACTIVE=1` — it is a
# tripwire that makes the honest-mistake and the lazy-forgery cases fail loudly;
# the command-guard name/glob guards are what stop the deliberate call.
if [ "${HARNESS_GATES_ACTIVE:-}" != "1" ]; then
  echo "record-gates: refusing to write the gate proof — this script is called only by gates.sh after the gates pass, never directly. Run: bash migration/tools/gates.sh" >&2
  exit 1
fi

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
