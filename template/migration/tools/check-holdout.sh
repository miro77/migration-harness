#!/usr/bin/env bash
# Held-out parity: cases the implementer never saw.
#
# WHY. The committed fixtures in migration/fixtures/ are visible to the agent that
# has to satisfy them — and an agent that can see the test can write code shaped to
# the test rather than to the behavior. That is not a hypothetical failure mode:
# coding agents are documented obtaining green by "modifying tests, or overfitting
# to visible tests" (Do Coding Agents Deceive Us?, arXiv 2606.07379), and the
# mitigation that holds up is evaluating on cases generated AFTER the code was
# written.
#
# WHAT IT DOES. At gate time, generate a FRESH batch of input->output vectors from
# the ORACLE, run the new implementation against them, and compare. The cases:
#   * do not exist while the code is being written  -> nothing to overfit to
#   * are never committed                           -> nothing to tune against next pass
#   * are ephemeral: a temp dir, deleted on success -> nothing to read afterwards
# The defense here is EPHEMERALITY, not access control. There is no need to hide
# the cases from the agent, because while it matters they do not exist.
#
# On FAILURE the directory is kept and named, together with the seed, so the
# failure is reproducible and debuggable — a gate you cannot reproduce is a gate
# nobody will trust.
#
# This does NOT replace the committed fixtures. Those are the fast, deterministic
# regression suite and they answer "did I break what I already ported?". This one
# answers "does the port actually generalize, or did it learn the answer key?".
# Different questions; keep both.
#
# Opt-in via HARNESS_HOLDOUT="on" in harness.env. Like the PROJECT GATES block,
# it ships FAILING once enabled but unconfigured: an oracle that is switched on
# but wired to nothing must never report green.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-holdout: not a git repository" >&2; exit 2; }

# shellcheck source=/dev/null
[ -f migration/harness.env ] && . migration/harness.env

[ "${HARNESS_HOLDOUT:-}" = "on" ] || exit 0

n="${HARNESS_HOLDOUT_N:-25}"
case "$n" in ''|*[!0-9]*) n=25 ;; esac

# A seed that did not exist when the code was written. Reproducible after the
# fact (it is printed on failure), unpredictable before it (nothing to pin the
# implementation to).
seed="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$seed" ] || seed="$$"

dir="$(mktemp -d)" || { echo "check-holdout: cannot create a temp dir" >&2; exit 1; }

# Keep the cases on failure, delete them on success. A randomized gate you cannot
# reproduce is a gate nobody will trust — and "it failed, and I cannot show you
# on what" is how a real oracle gets switched off. The seed reproduces the batch;
# the directory is the batch itself.
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "check-holdout: the failing cases are kept for reproduction:" >&2
    echo "    dir:  $dir" >&2
    echo "    seed: $seed" >&2
  else
    rm -rf "$dir"
  fi
}
trap cleanup EXIT

# ===== HOLDOUT ORACLE (edit for your stack) ================================
# Wire TWO steps between the markers. Both must exit non-zero on failure.
#
#   1. GENERATE — run the ORACLE (the frozen legacy, or a probe built against it)
#      to produce $n fresh input->output vectors into "$dir", using "$seed".
#      This must come from the oracle, never from the new code: a "holdout" the
#      port generates for itself proves only that it agrees with itself.
#
#   2. COMPARE — run the NEW implementation over the inputs in "$dir" and fail on
#      any mismatch against the oracle's recorded outputs. Exact comparison; the
#      same bit-for-bit rule as the committed fixtures (hard rule 4).
#
# Examples:
#   probes/bin/gen-vectors --seed "$seed" --count "$n" --out "$dir" \
#     || fail "holdout: oracle vector generation failed"
#   dart run tool/check_vectors.dart --dir "$dir" \
#     || fail "holdout: new implementation disagrees with the oracle"
#
#   ( cd probes && dotnet run --project Gen -- --seed "$seed" -n "$n" -o "$dir" ) || exit 1
#   pytest tests/holdout_test.py --vectors "$dir" -q || exit 1
#
# KEEP the marker lines — the self-tests replace everything between them.
# HARNESS:HOLDOUT-START
echo "check-holdout: HARNESS_HOLDOUT is 'on' but no holdout oracle is configured." >&2
echo "  Wire the generate + compare steps between the HARNESS:HOLDOUT markers in" >&2
echo "  migration/tools/check-holdout.sh. An oracle switched on and wired to nothing" >&2
echo "  must not report green — that is a worse lie than having no oracle at all." >&2
exit 1
# HARNESS:HOLDOUT-END
# ==========================================================================

# Reached only when the configured steps above both succeeded.
echo "check-holdout: $n freshly generated cases match the oracle (seed $seed)"
exit 0
