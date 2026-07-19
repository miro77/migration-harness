#!/usr/bin/env bash
# End-to-end smoke test: install the harness into a throwaway repo, wire a TINY
# but REAL gate, and drive the full cycle end to end:
#   proof NONE -> real gate PASS -> GATED/stop allows -> real gate FAIL blocks
#   -> fix -> re-gate -> commit-invariant allow.
#
# Unlike harness-selftest.sh (which neuters gates.sh to a no-op so it can focus
# on the enforcement plumbing), THIS exercises the real gates.sh -> record-gates
# path and a gate that genuinely fails — the coverage the selftest can't give.
# Needs only bash + git + GNU sed (the TEST SUITE uses GNU-only `sed -i` range
# constructs; product scripts stay POSIX).
set -uo pipefail

# Fail fast on BSD/macOS sed — the GNU-only sed edit below would half-apply and
# the assertions would fail for the wrong reason.
if ! sed --version >/dev/null 2>&1; then
  echo "FATAL: the harness TEST SUITE requires GNU sed (BSD/macOS sed detected)." >&2
  echo "       brew install gnu-sed and put gsed first in PATH as 'sed'. Product scripts remain POSIX." >&2
  exit 2
fi

self="$(cd "$(dirname "$0")" && pwd)"
H=""; d="$self"
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/hooks/stop-require-gates.sh" ] && [ -f "$d/migration/tools/working-tree-hash.sh" ]; then H="$d"; break; fi
  d="$(dirname "$d")"
done
[ -n "$H" ] || { echo "FATAL: harness root not found above $self"; exit 1; }

pass=0; fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL: %s (got %s want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
# match doctor output without a pipe (grep -q + pipefail would false-negative)
has(){ case "$2" in *"$1"*) ok "$3";; *) no "$3" "<missing>" "$1";; esac; }

T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
cd "$T"
git init -q; git config core.autocrlf false; git config user.email e2e@local; git config user.name e2e
cp -r "$H/.claude" "$H/migration" .
[ -e "$H/AGENTS.md" ] && cp "$H/AGENTS.md" .
[ -d "$H/probes" ] && cp -r "$H/probes" .
mkdir -p legacy/src src
printf 'class A{}\n'  > legacy/src/A.java
printf 'seed\n'       > src/a.txt
printf 'placeholder\n'> CLAUDE.md
printf '.harness/\n'  > .gitignore
printf 'HARNESS_SCOPE="src"\nHARNESS_FROZEN="legacy/src"\nHARNESS_LOCKED="migration/tools/ .claude/hooks/ .claude/settings.json migration/harness.env migration/frozen-baseline.sha migration/locked-baseline.sha"\n' > migration/harness.env

# Baseline the frozen oracle, exactly as a human does once before slice 1. Without
# it check-frozen.sh fails the gate closed — an unverified oracle is UNPROVEN, not
# a pass — so this is part of a real bootstrap, not test scaffolding.
bash migration/tools/check-frozen.sh --record >/dev/null 2>&1 \
  || { echo "e2e SETUP FAILED: could not record the frozen-oracle baseline" >&2; exit 1; }

# Wire a REAL gate: replace everything between the HARNESS:PROJECT-GATES markers
# (ship-time stub or user-configured alike) with a genuine check that fails iff a
# BROKEN marker exists in scope. Anchoring on the sentinels — not the editable
# `# ===` banners — keeps this working after a user configures real gates, and an
# internal `# ===` in their gates can't stop the range early. Assert the swap
# actually happened (and left record-gates intact) so a mis-match fails loudly
# instead of silently running a fake or user gate.
sed -i '/# HARNESS:PROJECT-GATES-START/,/# HARNESS:PROJECT-GATES-END/c\test ! -e src/BROKEN || fail "BROKEN marker present"' migration/tools/gates.sh
grep -q 'BROKEN marker present' migration/tools/gates.sh || { echo "e2e SETUP FAILED: gate not neutralized (missing HARNESS:PROJECT-GATES markers?)" >&2; exit 1; }
grep -q 'record-gates.sh'      migration/tools/gates.sh || { echo "e2e SETUP FAILED: record-gates line was removed" >&2; exit 1; }

# Baseline the locked tooling AFTER the real gate is wired in (so the configured
# gates.sh is what the baseline pins), exactly as a human does after configuring
# gates.sh for their stack. From here, any drift in the harness's own
# gates/hooks/config fails the gate.
bash migration/tools/check-locked.sh --record >/dev/null 2>&1 \
  || { echo "e2e SETUP FAILED: could not record the locked-tooling baseline" >&2; exit 1; }

git add -A; git commit -qm init >/dev/null

STOP(){ printf '{"stop_hook_active":false}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1; echo $?; }
GATE(){ bash migration/tools/gates.sh >/dev/null 2>&1; echo $?; }
DOC(){  bash migration/tools/doctor.sh 2>&1; }

# 1. nothing gated yet
has "proof: NONE" "$(DOC)" "e2e: doctor NONE before any gate"
chk "e2e: stop blocks before any gate" "$(STOP)" 2

# 2. the real gate passes and records a proof
chk "e2e: real gate passes (clean tree)"       "$(GATE)" 0
has "proof: GATED" "$(DOC)" "e2e: doctor GATED after passing gate"
chk "e2e: stop allows after gated pass"         "$(STOP)" 0

# 3. a genuinely FAILING gate records no new proof; the ungated change blocks
printf 'x\n' > src/BROKEN
chk "e2e: real gate FAILS on BROKEN marker"     "$(GATE)" 1
has "proof: STALE" "$(DOC)" "e2e: doctor STALE after failed-gate change"
chk "e2e: stop blocks with ungated change"      "$(STOP)" 2

# 4. fix + edit, re-gate, allowed again
rm src/BROKEN; printf 'edited\n' > src/a.txt
chk "e2e: real gate passes after fix"           "$(GATE)" 0
chk "e2e: stop allows after re-gate"            "$(STOP)" 0

# 5. committing the gated content still allows (content-addressed, commit-invariant)
git add -A; git commit -qm "migrate S01: audited-pass" >/dev/null
chk "e2e: stop allows after committing gated content" "$(STOP)" 0

# 6. locked-tooling integrity: neutering a gate fails the gate at check-locked,
#    even though the (fake) project gate would still 'pass'. This is the bypass
#    the action guards can't see (simulated here by a direct write, as an
#    interpreter/subagent would do). Restore afterwards so the tree is clean.
cp migration/tools/gates.sh "$T/e2e-gates.orig"
printf '\n# tampered\n' >> migration/tools/gates.sh
chk "e2e: gate FAILS when locked tooling drifts"  "$(GATE)" 1
has "check-locked" "$(bash migration/tools/gates.sh 2>&1)" "e2e: failure names check-locked"
cp "$T/e2e-gates.orig" migration/tools/gates.sh
chk "e2e: gate passes again after restoring tooling" "$(GATE)" 0

echo "----------------------------------------"
echo "e2e smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
