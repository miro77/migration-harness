#!/usr/bin/env bash
# Regression guard for the migration harness itself.
#
# Spins up throwaway git repos, installs the harness (.claude + migration) into
# each, and asserts the enforcement behavior the three code reviews pinned down:
# content-addressed proof (commit-invariant, deletion-aware), the Stop-hook
# challenge on un-gated/committed/no-proof states, the audited-fail/split escape,
# and the frozen / command guards. Run it after ANY edit to the hooks or the
# tools/ scripts. Exit 0 = all pass; 1 = at least one failure.
#
# Self-contained: needs only bash + git + GNU sed (the TEST SUITE uses GNU-only
# `sed -i` / range-`c\` constructs; product scripts stay POSIX). No project
# toolchain required (the scenario gates.sh is neutralised to a no-op pass).
set -uo pipefail

# Fail fast on BSD/macOS sed — GNU-only sed edits below would half-apply and
# every downstream assertion would fail for the wrong reason.
if ! sed --version >/dev/null 2>&1; then
  echo "FATAL: the harness TEST SUITE requires GNU sed (BSD/macOS sed detected)." >&2
  echo "       brew install gnu-sed and put gsed first in PATH as 'sed'. Product scripts remain POSIX." >&2
  exit 2
fi

# --- locate the installed harness (dir containing .claude/hooks + migration/tools)
self="$(cd "$(dirname "$0")" && pwd)"
H=""
d="$self"
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/hooks/stop-require-gates.sh" ] && [ -f "$d/migration/tools/working-tree-hash.sh" ]; then
    H="$d"; break
  fi
  d="$(dirname "$d")"
done
[ -n "$H" ] || { echo "FATAL: could not locate harness (.claude + migration) above $self"; exit 1; }

pass=0; fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL: %s (got %s want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

# Cleanup on ANY exit (incl. Ctrl-C / set -u aborts): remove whichever throwaway
# repo is current and kill any background sleep still running. $R/$T2 point at
# already-removed dirs on the happy path — rm -rf of a gone dir is a no-op.
R=""; T2=""; npid=""
cleanup(){
  cd / 2>/dev/null || true
  [ -n "${npid:-}" ] && kill "$npid" 2>/dev/null
  [ -n "${R:-}" ]  && rm -rf "$R"
  [ -n "${T2:-}" ] && rm -rf "$T2"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- build a fresh repo with the harness installed and scope $1 configured
mkrepo(){
  local scope="$1" T
  T="$(mktemp -d)"
  ( cd "$T"
    git init -q
    git config core.autocrlf false
    git config user.email selftest@local
    git config user.name selftest
    cp -r "$H/.claude" "$H/migration" .
    mkdir -p legacy/src src
    printf 'class A{}\n' > legacy/src/A.java
    printf 'x\n' > src/a.txt
    printf 'placeholder\n' > CLAUDE.md
    # Replace everything between the HARNESS:PROJECT-GATES markers with a no-op
    # pass, so the selftest exercises the enforcement plumbing regardless of what
    # real gates the install wired. Anchoring on the sentinels (not the editable
    # `# ===` banners) survives a user's configured gates and any internal `# ===`.
    sed -i '/# HARNESS:PROJECT-GATES-START/,/# HARNESS:PROJECT-GATES-END/c\true  # selftest no-op gate' migration/tools/gates.sh
    printf 'HARNESS_SCOPE="%s"\nHARNESS_FROZEN="legacy/src"\nHARNESS_LOCKED="migration/tools/ .claude/hooks/ .claude/settings.json .claude/settings.local.json migration/harness.env migration/frozen-baseline.sha"\n' "$scope" > migration/harness.env
    # Record the frozen-oracle baseline, exactly as a human does once during
    # bootstrap. Without it check-frozen.sh (and so gates.sh) fails closed — an
    # unbaselined oracle is UNPROVEN, not a pass — and every gate test here would
    # be failing for the wrong reason. (stderr: stdout is the captured repo path.)
    bash migration/tools/check-frozen.sh --record >/dev/null 2>&1 \
      || echo "SETUP FAILED: check-frozen.sh --record failed in $T — downstream gate FAILs are misattributed" >&2
    git add -A; git commit -qm init
  )
  echo "$T"
}
STOP(){ printf '{"stop_hook_active":false}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1; echo $?; }
GUARD(){ printf '{"tool_input":{"command":"%s"}}' "$1" | bash .claude/hooks/pretooluse-command-guard.sh >/dev/null 2>&1; echo $?; }
FROZEN(){ printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash .claude/hooks/pretooluse-frozen-legacy.sh >/dev/null 2>&1; echo $?; }
GATE(){ bash migration/tools/gates.sh >/dev/null 2>&1; }

# --- bootstrap sanity: fail FAST if mkrepo's frozen-baseline recording is broken.
# Without this, a broken check-frozen.sh --record surfaces as dozens of unrelated
# downstream gate FAILs instead of one clear setup error (e2e-smoke asserts the
# same step; the selftest must too).
R="$(mkrepo 'src')"
if ! ( cd "$R" && bash migration/tools/check-frozen.sh >/dev/null 2>&1 ); then
  echo "FATAL: selftest bootstrap broken — check-frozen.sh --record did not yield a passing baseline in a fresh repo" >&2
  exit 1
fi
rm -rf "$R"

# ============================================================ content hash
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
h1="$(bash migration/tools/working-tree-hash.sh)"
printf 'edit\n' > src/a.txt; h2="$(bash migration/tools/working-tree-hash.sh)"
[ "$h1" != "$h2" ] && ok "hash: edit changes hash" || no "hash: edit changes hash" "$h2" "!=$h1"
git add -A; git commit -qm c1 >/dev/null; h3="$(bash migration/tools/working-tree-hash.sh)"
chk "hash: commit does NOT change hash" "$h3" "$h2"
git rm -q src/a.txt; h4="$(bash migration/tools/working-tree-hash.sh)"
[ "$h3" != "$h4" ] && ok "hash: file deletion changes hash" || no "hash: file deletion changes hash" "$h4" "!=$h3"
cd /; rm -rf "$R"

# ============================================================ core Stop flow
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
printf 'y\n' > src/a.txt; git add -A; git commit -qm ungated >/dev/null
chk "stop: no-proof clean commit blocks" "$(STOP)" 2
GATE; chk "stop: after gate allows" "$(STOP)" 0
printf 'z\n' > src/a.txt; chk "stop: dirty ungated blocks" "$(STOP)" 2
GATE; chk "stop: re-gate allows" "$(STOP)" 0
git add -A; git commit -qm gated >/dev/null
chk "stop: commit of gated content still allows" "$(STOP)" 0
printf 'w\n' > src/a.txt; git add -A; git commit -qm ungated2 >/dev/null
chk "stop: committed ungated blocks" "$(STOP)" 2
git commit -q --allow-empty -m "migrate E01: audited-fail" >/dev/null
chk "stop: empty audited-fail cannot launder prior ungated commit" "$(STOP)" 2
git reset -q --hard HEAD~1
GATE; git add -A; git commit -q --allow-empty -m "migrate E01: audited-pass" >/dev/null
chk "stop: audited-pass allows" "$(STOP)" 0
rm -rf .harness; chk "stop: deleted-proof reopen blocks" "$(STOP)" 2
# retry (stop_hook_active) always releases
printf '{"stop_hook_active":true}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1
chk "stop: retry (stop_hook_active) releases" "$?" 0
cd /; rm -rf "$R"

# A legitimate non-pass checkpoint is allowed only when it layers a
# bookkeeping-only commit on top of a gated parent.
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
GATE
printf '\ncheckpoint\n' >> migration/parity-matrix.md
git add migration/parity-matrix.md; git commit -qm "migrate E01: audited-fail" >/dev/null
chk "stop: audited-fail bookkeeping checkpoint allows" "$(STOP)" 0
cd /; rm -rf "$R"

# ============================================================ sole scoped root
R="$(mkrepo 'src')"; cd "$R"
GATE; chk "sole: gated clean allows" "$(STOP)" 0
rm -r src; chk "sole: rm root uncommitted blocks" "$(STOP)" 2
git add -A; git commit -qm "removed src" >/dev/null
chk "sole: rm root committed normal-subject blocks" "$(STOP)" 2
git commit -q --allow-empty -m "migrate X: audited-fail" >/dev/null
chk "sole: audited-fail cannot launder committed deletion" "$(STOP)" 2
cd /; rm -rf "$R"

# no-proof committed deletion of the only scoped root must still block
R="$(mkrepo 'src')"; cd "$R"
rm -r src; git add -A; git commit -qm "delete src without proof" >/dev/null
chk "sole: no-proof committed rm root blocks" "$(STOP)" 2
cd /; rm -rf "$R"

# but a scope that was never created / never committed has nothing to protect
R="$(mkrepo 'ghost')"; cd "$R"
chk "sole: never-committed empty scope allows" "$(STOP)" 0
cd /; rm -rf "$R"

# ============================================================ doc-gate (check-docs.sh)
# Assertions run on an ISOLATED fixture dir, not the copied migration/ docs:
# in a configured install those are user-filled, and any incidental "](...)"
# shaped text in them (e.g. a PowerShell "[ref]($r" snippet in a runtime
# recipe) would fail the valid-link assertions spuriously.
R="$(mkrepo 'src')"; cd "$R"
DOCS(){ bash migration/tools/check-docs.sh "$@" >/dev/null 2>&1; echo $?; }
mkdir -p docgate-fixtures
printf '# stub plan\n' > docgate-fixtures/PLAN.md
printf '# Doc\n[plan](PLAN.md)\n' > docgate-fixtures/good.md
chk "docgate: valid file link passes"        "$(DOCS docgate-fixtures)" 0
printf '[bad](does-not-exist.md)\n' >> docgate-fixtures/good.md
chk "docgate: broken file link fails"        "$(DOCS docgate-fixtures)" 1
printf '# Title Here\n[a](#title-here)\n' > docgate-fixtures/good.md
chk "docgate: valid same-file anchor passes" "$(DOCS docgate-fixtures)" 0
printf '# Title Here\n[a](#missing)\n' > docgate-fixtures/good.md
chk "docgate: broken anchor fails"           "$(DOCS docgate-fixtures)" 1
# multi-heading file: anchor to a LATER heading must resolve (slug list must be
# newline-separated, not concatenated)
printf '# One\n## Two Words\n### Three\n[a](#two-words)\n' > docgate-fixtures/good.md
chk "docgate: anchor to later heading passes (multi-heading)" "$(DOCS docgate-fixtures)" 0
rm -rf docgate-fixtures
cd /; rm -rf "$R"

# ============================================================ config gate (unconfigured harness)
# gates.sh must refuse to pass while CLAUDE.md still has ship-time placeholders —
# ALL-CAPS, lower-hyphen, AND the descriptive/multi-line prose ones.
R="$(mkrepo 'src')"; cd "$R"
printf '# <PROJECT> migration\n' > CLAUDE.md
GATE; chk "config: gate fails on ALL-CAPS placeholder" "$?" 1
printf 'see `<legacy-paths>`\n' > CLAUDE.md
GATE; chk "config: gate fails on lower-hyphen placeholder" "$?" 1
printf '## Target architecture\n<Describe the target architecture: modules,\nwhere UI lives.>\n' > CLAUDE.md
GATE; chk "config: gate fails on multi-line <Describe ...> placeholder" "$?" 1
printf '5. <Platform/runtime constraints for the target stack.>\n' > CLAUDE.md
GATE; chk "config: gate fails on <Platform/...> (rule 5)" "$?" 1
printf '6. <Concurrency/performance constraints, if any.>\n' > CLAUDE.md
GATE; chk "config: gate fails on <Concurrency/...> (rule 6)" "$?" 1
printf 'Goal: <one line - what it does and for whom>\n' > CLAUDE.md
GATE; chk "config: gate fails on <one line ...> (feature profile)" "$?" 1
printf '# Acme migration; uses a <Foo> generic and <T>\n' > CLAUDE.md
GATE; chk "config: gate passes on configured CLAUDE.md (no false-positive on <Foo>/<T>)" "$?" 0
printf '# Acme migration\nUse `<Widget />` in views; the shell is a <my-element> custom element.\n' > CLAUDE.md
GATE; chk "config: gate passes on JSX/custom-element content (no false-positive)" "$?" 0
cd /; rm -rf "$R"

# ============================================================ gate-neutralization robustness
# The test suites replace the PROJECT GATES block via the HARNESS:PROJECT-GATES
# sentinels. An internal `# ===` line between the markers (what broke the old
# banner-range approach — it stopped the replacement there) must NOT stop it early.
R="$(mkrepo 'src')"; cd "$R"
sed -i '/# HARNESS:PROJECT-GATES-START/a\# ==================== internal ====================' migration/tools/gates.sh
sed -i '/# HARNESS:PROJECT-GATES-START/,/# HARNESS:PROJECT-GATES-END/c\true  # neutralized' migration/tools/gates.sh
grep -q 'internal ====' migration/tools/gates.sh && no "neutralize: internal === stops replacement early" "present" "removed" || ok "neutralize: internal === does not stop replacement early"
grep -q 'record-gates.sh' migration/tools/gates.sh && ok "neutralize: record-gates line survives" || no "neutralize: record-gates line survives" "removed" "present"
cd /; rm -rf "$R"

# ============================================================ kick-loop (resume driver) + check-complete
R="$(mkrepo 'src')"; cd "$R"
out="$(bash migration/tools/kick-loop.sh --check 2>&1)"
case "$out" in *"STATE: resume"*) ok "kick-loop: --check resume when no HANDOFF";; *) no "kick-loop: --check resume when no HANDOFF" "$out" "STATE: resume";; esac

# an arbitrary HANDOFF.md must NOT read as done (it used to no-op every run)
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: no handoff is invalid" "$?" 1
printf 'nothing left\n' > migration/HANDOFF.md
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: untracked handoff is invalid" "$?" 1
out="$(bash migration/tools/kick-loop.sh --check 2>&1)"
case "$out" in *"STATE: invalid-handoff"*) ok "kick-loop: --check flags invalid handoff";; *) no "kick-loop: --check flags invalid handoff" "$out" "STATE: invalid-handoff";; esac
bash migration/tools/kick-loop.sh >/dev/null 2>&1
chk "kick-loop: invalid handoff exits 65 (not silent no-op)" "$?" 65

# committed but without a STATUS line: still invalid
git add migration/HANDOFF.md >/dev/null 2>&1; git commit -qm h1 >/dev/null
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: missing STATUS line is invalid" "$?" 1

# valid COMPLETE terminal state
cat > migration/parity-matrix.md <<'EOF'
| id | slice | legacy source | target path | deps | status | deviations | findings |
|----|-------|---------------|-------------|------|--------|------------|----------|
| B01 | bootstrap | - | - | - | audited-pass | - | - |
| F01 | thing | - | - | B01 | audited-pass | - | - |
EOF
printf 'STATUS: COMPLETE\n\nall rows pass\n' > migration/HANDOFF.md
git add migration/parity-matrix.md migration/HANDOFF.md >/dev/null 2>&1; git commit -qm h2 >/dev/null
out="$(bash migration/tools/check-complete.sh 2>&1)"; rc=$?
chk "complete: COMPLETE fixture validates" "$rc" 0
case "$out" in *"STATUS: COMPLETE"*) ok "complete: prints STATUS: COMPLETE";; *) no "complete: prints STATUS: COMPLETE" "$out" "STATUS: COMPLETE";; esac
bash migration/tools/kick-loop.sh >/dev/null 2>&1
chk "kick-loop: COMPLETE exits 0" "$?" 0
out="$(bash migration/tools/kick-loop.sh --check 2>&1)"
case "$out" in *"done:COMPLETE"*) ok "kick-loop: --check reports done:COMPLETE";; *) no "kick-loop: --check reports done:COMPLETE" "$out" "done:COMPLETE";; esac

# claim/board mismatch: audited-fail row under a COMPLETE claim is invalid
sed -i 's/^| F01 | thing | - | - | B01 | audited-pass /| F01 | thing | - | - | B01 | audited-fail /' migration/parity-matrix.md
git add migration/parity-matrix.md >/dev/null 2>&1; git commit -qm h3 >/dev/null
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: COMPLETE claim over audited-fail row is invalid" "$?" 1
bash migration/tools/kick-loop.sh >/dev/null 2>&1
chk "kick-loop: mismatched handoff exits 65" "$?" 65

# FAILED terminal state -> exit 20
printf 'STATUS: FAILED\n\nF01 failed audit\n' > migration/HANDOFF.md
git add migration/HANDOFF.md >/dev/null 2>&1; git commit -qm h4 >/dev/null
bash migration/tools/kick-loop.sh >/dev/null 2>&1
chk "kick-loop: FAILED exits 20" "$?" 20

# BLOCKED via an open gate proposal -> exit 10; COMPLETE past one is invalid
sed -i 's/^| F01 | thing | - | - | B01 | audited-fail /| F01 | thing | - | - | B01 | audited-pass /' migration/parity-matrix.md
printf '## PROPOSAL: widen a gate\n' >> migration/PROPOSED-GATE-CHANGES.md
printf 'STATUS: BLOCKED\n\nopen proposal remains\n' > migration/HANDOFF.md
git add migration/parity-matrix.md migration/PROPOSED-GATE-CHANGES.md migration/HANDOFF.md >/dev/null 2>&1; git commit -qm h5 >/dev/null
bash migration/tools/kick-loop.sh >/dev/null 2>&1
chk "kick-loop: BLOCKED (open proposal) exits 10" "$?" 10
printf 'STATUS: COMPLETE\n' > migration/HANDOFF.md
git add migration/HANDOFF.md >/dev/null 2>&1; git commit -qm h6 >/dev/null
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: COMPLETE claim past an open proposal is invalid" "$?" 1

# open integration-ledger rows CAP the state at BLOCKED. The idle-backstop
# handoff (prompt-mandated, listing open rows) must be a VALID record — an
# invalid-by-construction one looped the driver on exit 65 forever. COMPLETE
# past an open row stays invalid.
sed -i '/^## PROPOSAL: widen a gate$/d' migration/PROPOSED-GATE-CHANGES.md
cat > migration/integration-ledger.md <<'EOF'
| id | feature | status | closes-in |
|----|---------|--------|-----------|
| INTEG-01 | export | built-unwired | - |
EOF
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: COMPLETE claim over open ledger row is invalid" "$?" 1
printf 'STATUS: BLOCKED\n\nidle backstop fired; INTEG-01 open\n' > migration/HANDOFF.md
git add migration/integration-ledger.md migration/HANDOFF.md migration/PROPOSED-GATE-CHANGES.md >/dev/null 2>&1; git commit -qm h6b >/dev/null
out="$(bash migration/tools/check-complete.sh 2>&1)"; rc=$?
chk "complete: open ledger row with BLOCKED claim validates" "$rc" 0
case "$out" in *"STATUS: BLOCKED"*) ok "complete: open ledger row derives BLOCKED";; *) no "complete: open ledger row derives BLOCKED" "$out" "STATUS: BLOCKED";; esac
# wire the row back so the feature-profile COMPLETE fixture below stays green
sed -i 's/built-unwired/wired/' migration/integration-ledger.md
git add migration/integration-ledger.md >/dev/null 2>&1; git commit -qm h6c >/dev/null

# feature profile: check-complete validates the SPEC board
printf 'HARNESS_PROFILE="feature"\n' >> migration/harness.env
cat > migration/spec-matrix.md <<'EOF'
| id | criterion (observable, testable) | area / component | deps | status | acceptance test | findings |
|----|----------------------------------|------------------|------|--------|-----------------|----------|
| S00 | bootstrap | - | - | audited-pass | - | - |
| S01 | works | api | S00 | audited-pass | t1 | - |
EOF
sed -i '/^## PROPOSAL: widen a gate$/d' migration/PROPOSED-GATE-CHANGES.md
printf 'STATUS: COMPLETE\n\nspec met\n' > migration/HANDOFF.md
git add migration/spec-matrix.md migration/PROPOSED-GATE-CHANGES.md migration/HANDOFF.md migration/harness.env >/dev/null 2>&1; git commit -qm h7 >/dev/null
bash migration/tools/check-complete.sh >/dev/null 2>&1
chk "complete: feature profile validates spec-matrix" "$?" 0
cd /; rm -rf "$R"

# --- profile plumbing is shipped, not prose ---
cd "$H"
[ -f .claude/commands/feature-slice.md ] && ok "profile: /feature-slice command shipped" || no "profile: /feature-slice command shipped" "missing" "file"
grep -q "feature-slice" migration/SINGLE-TICK-PROMPT.md && ok "profile: tick prompt selects slice command by profile" || no "profile: tick prompt selects slice command by profile" "missing" "feature-slice"
grep -q "HARNESS_PROFILE" migration/harness.env && ok "profile: HARNESS_PROFILE in harness.env" || no "profile: HARNESS_PROFILE in harness.env" "missing" "HARNESS_PROFILE"
grep -q "S00" migration/spec-matrix.md && ok "profile: spec-matrix ships bootstrap row S00" || no "profile: spec-matrix ships bootstrap row S00" "missing" "S00"

# --- kick-loop argument / prompt-file validation (no claude needed) ---
R="$(mkrepo 'src')"; cd "$R"
chk "kick-loop: missing --prompt file exits 2" "$( (bash migration/tools/kick-loop.sh --prompt does-not-exist.md >/dev/null 2>&1); echo $? )" 2
chk "kick-loop: --prompt without arg exits 2"  "$( (bash migration/tools/kick-loop.sh --prompt >/dev/null 2>&1); echo $? )" 2
cd /; rm -rf "$R"

# --- kick-loop with a stubbed 'claude' on PATH: gated verdict / limit / lock recovery ---
R="$(mkrepo 'src')"; cd "$R"; mkdir -p .fakebin; FAKEBIN="$PWD/.fakebin"
mkfake(){ cat > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"; }
KL(){ ( PATH="$FAKEBIN:$PATH" bash migration/tools/kick-loop.sh "$@" ); }

mkfake <<'FAKE'
#!/usr/bin/env bash
printf 'edited\n' > src/a.txt
exit 0
FAKE
chk "kick-loop: un-gated exit-0 run flagged 65" "$( KL >/dev/null 2>&1; echo $? )" 65
grep -q '"event":"run.start"' .harness/state/runs.ndjson \
  && ok "run journal: records attempt start" || no "run journal: records attempt start" "missing" "run.start"
grep -q '"outcome":"ungated","exit_code":65' .harness/state/runs.ndjson \
  && ok "run journal: classifies ungated exit" || no "run journal: classifies ungated exit" "missing" "ungated rc=65"
chk "run journal: completed attempt has start/end pair" \
  "$(grep -c '"event":"run.start"\|"event":"run.end"' .harness/state/runs.ndjson)" 2
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
printf '{"session_id":"fake-session","tool_name":"Bash","tool_input":{"command":"gates"}}' \
  | bash .claude/hooks/posttooluse-telemetry.sh >/dev/null 2>&1
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: gated exit-0 run returns 0" "$( KL >/dev/null 2>&1; echo $? )" 0
grep -q '"outcome":"gate_covered","exit_code":0' .harness/state/runs.ndjson \
  && ok "run journal: classifies gate-covered attempt" || no "run journal: classifies gate-covered attempt" "missing" "gate_covered rc=0"
run_id=$(sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p' .harness/state/runs.ndjson | head -n 1)
grep -q "\"run_id\":\"$run_id\"" .harness/state/telemetry.ndjson \
  && ok "run journal: tool telemetry correlates by run_id" || no "run journal: tool telemetry correlates by run_id" "missing" "$run_id"
grep -q '"tool_calls":1' .harness/state/runs.ndjson \
  && ok "run journal: captures per-attempt tool count" || no "run journal: captures per-attempt tool count" "missing" "tool_calls=1"
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
echo "you have reached your usage limit; resets at 3am"
exit 1
FAKE
chk "kick-loop: usage limit on nonzero exit -> 75" "$( KL >/dev/null 2>&1; echo $? )" 75
grep -q '"outcome":"usage_limit","exit_code":75' .harness/state/runs.ndjson \
  && ok "run journal: classifies usage-limit pause" || no "run journal: classifies usage-limit pause" "missing" "usage_limit rc=75"
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
echo "no rate limit problems here, all good"
exit 0
FAKE
chk "kick-loop: limit text on exit-0 not mis-flagged 75" "$( KL >/dev/null 2>&1; echo $? )" 65
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
mkdir -p .harness/kick-loop.lock; touch -t 200001010000 .harness/kick-loop.lock 2>/dev/null || true
out="$(KL 2>&1)"; case "$out" in *"recovering stale lock"*) ok "kick-loop: recovers stale lock";; *) no "kick-loop: recovers stale lock" "$out" "recovering";; esac
rm -rf .harness
mkdir -p .harness/kick-loop.lock
out="$(KL 2>&1)"; case "$out" in *"another run holds"*) ok "kick-loop: respects a fresh lock";; *) no "kick-loop: respects a fresh lock" "$out" "another run holds";; esac
rm -rf .harness

# stale mtime but LIVE bash owner pid: must NOT recover (no concurrent
# drivers) — and must exit 65, not 0: the heartbeat keeps a live owner's
# mtime fresh, so reaching this state at all needs a human look, and a
# scheduler must not read an indefinite stall as success.
mkdir -p .harness/kick-loop.lock
printf 'pid=%s started=x\n' "$$" > .harness/kick-loop.lock/meta
touch -t 200001010000 .harness/kick-loop.lock 2>/dev/null || true
out="$(KL 2>&1)"; rc=$?
case "$out" in *ALIVE*) ok "kick-loop: old lock with LIVE owner not recovered";; *) no "kick-loop: old lock with LIVE owner not recovered" "$out" "ALIVE";; esac
chk "kick-loop: old lock with LIVE owner exits 65 (not silent 0)" "$rc" 65
rm -rf .harness

# stale mtime, live owner that is NOT a bash process: a RECYCLED pid (reboot
# handed the dead driver's pid to an unrelated process) — must recover, or
# the migration stalls forever behind a pid that never exits.
sleep 300 & npid=$!
mkdir -p .harness/kick-loop.lock
printf 'pid=%s started=x\n' "$npid" > .harness/kick-loop.lock/meta
touch -t 200001010000 .harness/kick-loop.lock 2>/dev/null || true
out="$(KL 2>&1)"
case "$out" in *"recovering stale lock"*) ok "kick-loop: recycled-pid (non-bash) owner recovered";; *) no "kick-loop: recycled-pid (non-bash) owner recovered" "$out" "recovering";; esac
kill "$npid" 2>/dev/null
rm -rf .harness

# stale mtime and DEAD owner pid: recovered
sleep 0.1 & deadpid=$!; wait "$deadpid" 2>/dev/null
mkdir -p .harness/kick-loop.lock
printf 'pid=%s started=x\n' "$deadpid" > .harness/kick-loop.lock/meta
touch -t 200001010000 .harness/kick-loop.lock 2>/dev/null || true
out="$(KL 2>&1)"
case "$out" in *"recovering stale lock"*) ok "kick-loop: old lock with DEAD owner recovered";; *) no "kick-loop: old lock with DEAD owner recovered" "$out" "recovering";; esac
rm -rf .harness

# headless --review must STOP (exit 70), --review-log-only continues
mkfake <<'FAKE'
#!/usr/bin/env bash
bash migration/tools/gates.sh >/dev/null 2>&1
printf '\nreview checkpoint\n' >> migration/parity-matrix.md
git add migration/parity-matrix.md >/dev/null 2>&1
git commit -qm "migrate T01: audited-fail" >/dev/null 2>&1
exit 0
FAKE
KL --drive --review </dev/null >/dev/null 2>&1
chk "kick-loop: headless --review stops with 70" "$?" 70
rm -rf .harness
out="$( ( export HARNESS_MAX_TICKS=1; KL --drive --review-log-only </dev/null 2>&1 ) )"; rc=$?
chk "kick-loop: --review-log-only continues to budget (0)" "$rc" 0
case "$out" in *"review-log-only, continuing"*) ok "kick-loop: --review-log-only logs and continues";; *) no "kick-loop: --review-log-only logs and continues" "$out" "continuing";; esac
rm -rf .harness
cd /; rm -rf "$R"

# ============================================================ in-place oracle gates (HARNESS_ORACLE)
R="$(mkrepo 'src')"; cd "$R"
printf 'HARNESS_ORACLE="baselines"\n' >> migration/harness.env
out="$(bash migration/tools/gates.sh 2>&1)"; rc=$?
chk "oracle: unconfigured baseline parity FAILS gates" "$rc" 1
case "$out" in *"BASELINE-PARITY"*|*"content parity NOT CONFIGURED"*) ok "oracle: failure names the CONFIGURE step";; *) no "oracle: failure names the CONFIGURE step" "$out" "BASELINE-PARITY";; esac
sed -i '/# HARNESS:BASELINE-PARITY-START/,/# HARNESS:BASELINE-PARITY-END/c\true # selftest: configured' migration/tools/check-baselines.sh
GATE; chk "oracle: configured oracle passes gates" "$?" 0

# strict board parsing: duplicate id + unknown status are ERRORS
cat > migration/parity-matrix.md <<'EOF'
| id | slice | legacy source | target path | deps | status | deviations | findings |
|----|-------|---------------|-------------|------|--------|------------|----------|
| B01 | bootstrap | - | - | - | open | - | - |
| B01 | dup | - | - | - | open | - | - |
| F02 | odd | - | - | - | inprogress | - | - |
EOF
out="$(bash migration/tools/check-matrix.sh 2>&1)"; rc=$?
chk "oracle: strict matrix parse fails on bad board" "$rc" 1
case "$out" in *"duplicate row id B01"*) ok "oracle: duplicate row id detected";; *) no "oracle: duplicate row id detected" "$out" "duplicate";; esac
case "$out" in *"unknown status"*) ok "oracle: unknown status spelling detected";; *) no "oracle: unknown status spelling detected" "$out" "unknown status";; esac

# T-before-M convention + coverage seam
cat > migration/parity-matrix.md <<'EOF'
| id | slice | legacy source | target path | deps | status | deviations | findings |
|----|-------|---------------|-------------|------|--------|------------|----------|
| T-unita | pin | - | - | - | open | - | - |
| M-unita | edit | - | - | T-unita | in-progress | - | - |
EOF
out="$(bash migration/tools/check-matrix.sh 2>&1)"; rc=$?
chk "oracle: M active before T audited-pass fails" "$rc" 1
case "$out" in *"T sub-row(s) not audited-pass"*|*"no T-"*) ok "oracle: names the unmet T row";; *) no "oracle: names the unmet T row" "$out" "T sub-row";; esac
printf '#!/usr/bin/env bash\necho missing_unit\n' > migration/tools/list-affected-units.sh
chmod +x migration/tools/list-affected-units.sh
out="$(bash migration/tools/check-matrix.sh 2>&1)"
case "$out" in *"missing_unit"*) ok "oracle: coverage seam flags unit without rows";; *) no "oracle: coverage seam flags unit without rows" "$out" "missing_unit";; esac

# coverage is EXACT on the base row id: unit "unit" is NOT covered by rows
# T-unita/M-unita (substring matching hid exactly this silent miss), while
# unit "unita" IS covered by them.
printf '#!/usr/bin/env bash\necho unita\necho unit\n' > migration/tools/list-affected-units.sh
out="$(bash migration/tools/check-matrix.sh 2>&1)"
case "$out" in *"affected unit 'unit' has no row"*) ok "oracle: coverage is exact, not substring";; *) no "oracle: coverage is exact, not substring" "$out" "unit has no row";; esac
case "$out" in *"affected unit 'unita'"*) no "oracle: unit with rows still covered" "$out" "unita covered";; *) ok "oracle: unit with rows still covered";; esac
rm -f migration/tools/list-affected-units.sh

# id-anchored, case-insensitive header hunt: the status-vocabulary legend
# must not donate the status column, and a capitalized real header must
# still parse (it used to make the validator pass an UNPARSED board).
cat > migration/parity-matrix.md <<'EOF'
| Status | Meaning |
|---|---|
| `open` | not started |

| Id | Slice | Deps | Status |
|----|-------|------|--------|
| B01 | bootstrap | - | open |
EOF
out="$(bash migration/tools/check-matrix.sh 2>&1)"; rc=$?
chk "oracle: legend + capitalized header validates" "$rc" 0
case "$out" in *"1 row(s) validated"*) ok "oracle: capitalized header parses the data row";; *) no "oracle: capitalized header parses the data row" "$out" "1 row(s) validated";; esac
# no recognizable header: must FAIL, not exit 0 having validated nothing
printf '| key | state |\n|---|---|\n| B01 | open |\n' > migration/parity-matrix.md
bash migration/tools/check-matrix.sh >/dev/null 2>&1
chk "oracle: board without id/status header fails" "$?" 1
# header-only board with zero data rows: must FAIL too
printf '| id | deps | status |\n|---|---|---|\n' > migration/parity-matrix.md
bash migration/tools/check-matrix.sh >/dev/null 2>&1
chk "oracle: header-only board with zero rows fails" "$?" 1
cd /; rm -rf "$R"

# --- kick-loop --tick / --drive: fresh-context ticks ---
# mkfake/KL are reused from the stub block above — they resolve $FAKEBIN at
# call time, so pointing it at this repo's .fakebin is enough (and shellcheck
# 0.9 errors on redefining a function after its first use, SC2218).
R="$(mkrepo 'src')"; cd "$R"; mkdir -p .fakebin; FAKEBIN="$PWD/.fakebin"
calls(){ wc -l < calls.log | tr -d '[:space:]'; }

chk "kick-loop: --tick with --drive exits 2" "$( KL --tick --drive >/dev/null 2>&1; echo $? )" 2

# --tick: exactly one session, single-tick prompt by default, gated verdict
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
printf '%s' "${2:-}" > prompt.txt
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --tick gated run returns 0" "$( KL --tick >/dev/null 2>&1; echo $? )" 0
chk "kick-loop: --tick invokes claude exactly once" "$(calls)" 1
grep -q 'exactly ONE tick' prompt.txt && ok "kick-loop: --tick defaults to SINGLE-TICK-PROMPT.md" || no "kick-loop: --tick defaults to SINGLE-TICK-PROMPT.md" "$(head -c 60 prompt.txt)" "exactly ONE tick"
rm -f calls.log prompt.txt; rm -rf .harness

# --drive: one gated slice per tick, VALID committed HANDOFF on the second
# tick -> clean 0. The handoff must carry a STATUS line and match the board
# (check-complete.sh validates it — a bare marker file no longer counts).
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
n=$(wc -l < calls.log | tr -d '[:space:]')
if [ "$n" -ge 2 ]; then
  {
    printf '| id | slice | legacy source | target path | deps | status | deviations | findings |\n'
    printf '|----|-------|---------------|-------------|------|--------|------------|----------|\n'
    printf '| B01 | bootstrap | - | - | - | audited-pass | - | - |\n'
  } > migration/parity-matrix.md
  printf 'STATUS: COMPLETE\n\nnothing left\n' > migration/HANDOFF.md
  bash migration/tools/gates.sh >/dev/null 2>&1
  git add -A >/dev/null 2>&1
  git commit -qm "migrate HANDOFF: done" >/dev/null 2>&1
else
  printf 'tick %s\n' "$n" > src/a.txt
  bash migration/tools/gates.sh >/dev/null 2>&1
  git add -A >/dev/null 2>&1
  git commit -qm "migrate D0$n: audited-pass" >/dev/null 2>&1
fi
exit 0
FAKE
out="$( KL --drive 2>&1 )"; rc=$?
chk "kick-loop: --drive runs ticks until VALID committed HANDOFF, exits 0" "$rc" 0
case "$out" in *"terminated COMPLETE"*) ok "kick-loop: --drive reports terminated COMPLETE";; *) no "kick-loop: --drive reports terminated COMPLETE" "$out" "terminated COMPLETE";; esac
chk "kick-loop: --drive stopped after the HANDOFF tick" "$(calls)" 2
rm -f calls.log; git rm -q migration/HANDOFF.md >/dev/null 2>&1; git commit -qm "reset HANDOFF" >/dev/null 2>&1; rm -rf .harness

# --drive: a HANDOFF that was written but never committed is NOT a clean stop
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
printf 'nothing left\n' > migration/HANDOFF.md
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --drive flags uncommitted HANDOFF 65" "$( KL --drive >/dev/null 2>&1; echo $? )" 65
rm -f calls.log migration/HANDOFF.md; rm -rf .harness

# --drive backstop: gate-covered but changeless ticks must stop at 64, not spin
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --drive flags a stuck loop 64 after two idle ticks" "$( KL --drive >/dev/null 2>&1; echo $? )" 64
chk "kick-loop: --drive stuck loop stopped after two ticks" "$(calls)" 2
rm -f calls.log; rm -rf .harness

# --drive backstop: empty-commit spam changes HEAD but no scoped content —
# it must still count as idle (the signature ignores HEAD on purpose)
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
bash migration/tools/gates.sh >/dev/null 2>&1
git commit -q --allow-empty -m "migrate EMPTY: audited-fail" >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --drive commit-spam without content change still 64" "$( KL --drive >/dev/null 2>&1; echo $? )" 64
chk "kick-loop: --drive commit-spam stopped after two ticks" "$(calls)" 2
rm -f calls.log; rm -rf .harness

# --drive: a usage limit mid-drive pauses the whole drive with 75
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
n=$(wc -l < calls.log | tr -d '[:space:]')
if [ "$n" -ge 2 ]; then echo "you have reached your usage limit; resets at 3am"; exit 1; fi
printf 'limit tick\n' > src/a.txt
bash migration/tools/gates.sh >/dev/null 2>&1
git add -A >/dev/null 2>&1
git commit -qm "migrate L01: audited-pass" >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --drive pauses 75 on a mid-drive usage limit" "$( KL --drive >/dev/null 2>&1; echo $? )" 75
rm -f calls.log; rm -rf .harness

# --drive: HARNESS_MAX_TICKS bounds a run that always makes progress
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
n=$(wc -l < calls.log | tr -d '[:space:]')
printf 'progress %s\n' "$n" > src/a.txt
bash migration/tools/gates.sh >/dev/null 2>&1
git add -A >/dev/null 2>&1
git commit -qm "migrate P0$n: audited-pass" >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: --drive respects HARNESS_MAX_TICKS" "$( HARNESS_MAX_TICKS=2 KL --drive >/dev/null 2>&1; echo $? )" 0
chk "kick-loop: --drive spent exactly the tick budget" "$(calls)" 2
rm -f calls.log; rm -rf .harness
chk "kick-loop: --max requires --drive" "$( KL --max 1 >/dev/null 2>&1; echo $? )" 2
chk "kick-loop: --max rejects non-numeric values" "$( KL --drive --max nope >/dev/null 2>&1; echo $? )" 2

# HARNESS_MAX_TICKS set in harness.env must take effect (kick-loop sources the
# config like every other consumer of HARNESS_* settings)...
printf 'HARNESS_MAX_TICKS="3"\n' >> migration/harness.env
chk "kick-loop: harness.env HARNESS_MAX_TICKS honored" "$( KL --drive >/dev/null 2>&1; echo $? )" 0
chk "kick-loop: harness.env tick budget spent (3)" "$(calls)" 3
rm -f calls.log; rm -rf .harness
# ...and an explicit environment variable on the invocation still wins.
chk "kick-loop: env HARNESS_MAX_TICKS overrides harness.env" "$( HARNESS_MAX_TICKS=1 KL --drive >/dev/null 2>&1; echo $? )" 0
chk "kick-loop: env-override tick budget spent (1)" "$(calls)" 1
rm -f calls.log; rm -rf .harness
chk "kick-loop: --max overrides harness.env" "$( KL --drive --max 2 >/dev/null 2>&1; echo $? )" 0
chk "kick-loop: --max tick budget spent (2)" "$(calls)" 2
rm -f calls.log; rm -rf .harness
cd /; rm -rf "$R"

# ============================================================ precompact checkpoint hook
PRECOMPACT(){ printf '{"trigger":"%s","session_id":"s"}' "$1" | bash .claude/hooks/precompact-checkpoint.sh 2>/dev/null; }
R="$(mkrepo 'src')"; cd "$R"
out="$(PRECOMPACT auto)"
case "$out" in *'"hookEventName":"PreCompact"'*) ok "precompact: emits PreCompact additionalContext";; *) no "precompact: emits PreCompact additionalContext" "$out" "hookEventName";; esac
case "$out" in *parity-matrix*) ok "precompact: reminder names the checkpoint targets";; *) no "precompact: reminder names the checkpoint targets" "$out" "parity-matrix";; esac
case "$out" in *'trigger: auto'*) ok "precompact: echoes the trigger";; *) no "precompact: echoes the trigger" "$out" "trigger: auto";; esac
printf '{"trigger":"manual"}' | bash .claude/hooks/precompact-checkpoint.sh >/dev/null 2>&1; chk "precompact: exit 0 (never blocks)" "$?" 0
[ -s .harness/compaction.log ] && ok "precompact: writes compaction.log audit line" || no "precompact: writes compaction.log audit line" "empty" "nonempty"
cd /; rm -rf "$R"

# ============================================================ PostToolUse telemetry hook
POSTTOOL(){ printf '%s' "$1" | bash .claude/hooks/posttooluse-telemetry.sh 2>/dev/null; }
R="$(mkrepo 'src')"; cd "$R"

# Observability: a tool call is logged as structured JSON
HARNESS_RUN_ID=run-test POSTTOOL '{"session_id":"session-test","tool_name":"Edit","tool_input":{"file_path":"src/a.txt"}}' >/dev/null
[ -s .harness/state/telemetry.ndjson ] && ok "telemetry: logs tool call to telemetry.ndjson" || no "telemetry: logs tool call to telemetry.ndjson" "empty" "nonempty"
grep -q '"tool":"Edit"' .harness/state/telemetry.ndjson && ok "telemetry: log entry has tool name" || no "telemetry: log entry has tool name" "missing" "Edit"
grep -q '"run_id":"run-test"' .harness/state/telemetry.ndjson && ok "telemetry: log entry has run correlation id" || no "telemetry: log entry has run correlation id" "missing" "run-test"
grep -q '"session_id":"session-test"' .harness/state/telemetry.ndjson && ok "telemetry: log entry has session id" || no "telemetry: log entry has session id" "missing" "session-test"

# Budget: counter increments; warning injected when exceeded
POSTTOOL '{"tool_name":"Bash","tool_input":{"command":"ls"}}' >/dev/null
count=$(cat .harness/state/tool-stats/call_count)
chk "telemetry: call count increments" "$count" "2"
# Set a low budget and exceed it
printf 'HARNESS_MAX_CALLS_PER_TICK=2\n' >> migration/harness.env
out="$(POSTTOOL '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
case "$out" in *budget*exceeded*|*budget*exceed*) ok "telemetry: budget warning injected";; *) no "telemetry: budget warning injected" "$out" "budget exceeded";; esac
# Reset budget to disabled
printf 'HARNESS_MAX_CALLS_PER_TICK=0\n' >> migration/harness.env

# Loop detection: same fingerprint repeated triggers reconsideration
rm -f .harness/state/tool-stats/fingerprints
printf 'HARNESS_LOOP_THRESHOLD=3\nHARNESS_LOOP_WINDOW=6\n' >> migration/harness.env
POSTTOOL '{"tool_name":"Read","tool_input":{"file_path":"src/a.txt"}}' >/dev/null
POSTTOOL '{"tool_name":"Read","tool_input":{"file_path":"src/a.txt"}}' >/dev/null
out="$(POSTTOOL '{"tool_name":"Read","tool_input":{"file_path":"src/a.txt"}}')"
case "$out" in *Loop*detected*|*loop*detected*) ok "telemetry: loop detection fires on 3rd repeat";; *) no "telemetry: loop detection fires on 3rd repeat" "$out" "Loop detected";; esac
case "$out" in *reconsider*) ok "telemetry: loop message says reconsider";; *) no "telemetry: loop message says reconsider" "$out" "reconsider";; esac

# No git repo / no harness → fail-open (exit 0)
cd /; rm -rf "$R"
T2="$(mktemp -d)"; cd "$T2"
printf '{"tool_name":"Bash"}' | bash "$self/../.claude/hooks/posttooluse-telemetry.sh" 2>/dev/null
chk "telemetry: fail-open outside git repo" "$?" 0
cd /; rm -rf "$T2"

# ============================================================ persist/read-state tools
R="$(mkrepo 'src')"; cd "$R"
echo '{"step":2,"note":"halfway"}' | bash migration/tools/persist-state.sh mykey >/dev/null 2>&1
chk "persist-state: exits 0" "$?" 0
[ -f .harness/state/slice-state/mykey ] && ok "persist-state: writes file" || no "persist-state: writes file" "missing" ".harness/state/slice-state/mykey"
out="$(bash migration/tools/read-state.sh mykey 2>/dev/null)"
case "$out" in *halfway*) ok "read-state: returns persisted value";; *) no "read-state: returns persisted value" "$out" "halfway";; esac
bash migration/tools/read-state.sh nonexistent 2>/dev/null; chk "read-state: exits 1 on missing key" "$?" 1
cd /; rm -rf "$R"

# ============================================================ gates failure feedback
R="$(mkrepo 'src')"; cd "$R"
# Gate passes → failure file should NOT exist
GATE; [ ! -f .harness/state/last-gate-failure.txt ] && ok "gates: success clears failure file" || no "gates: success clears failure file" "present" "absent"
# Make a gate fail → failure file should exist with content.
# mkrepo replaced the PROJECT GATES block (including markers) with a no-op
# `true` line, so we replace THAT line directly (not via the markers).
printf 'BROKEN\n' > src/BROKEN
sed -i 's/^true  # selftest no-op gate/test ! -e src\/BROKEN || fail "BROKEN marker present"/' migration/tools/gates.sh
grep -q 'BROKEN marker present' migration/tools/gates.sh || { no "gates: test setup failed (gate not replaced)" "missing" "BROKEN marker present"; cd /; rm -rf "$R"; }
bash migration/tools/gates.sh >/dev/null 2>&1
[ -f .harness/state/last-gate-failure.txt ] && ok "gates: failure writes last-gate-failure.txt" || no "gates: failure writes last-gate-failure.txt" "missing" "present"
[ -s .harness/state/last-gate-failure.txt ] && ok "gates: failure file has content" || no "gates: failure file has content" "empty" "nonempty"
grep -q 'BROKEN marker present' .harness/state/last-gate-failure.txt && ok "gates: failure file contains the gate diagnostic" || no "gates: failure file contains the gate diagnostic" "missing" "BROKEN marker present"
# Fix and re-gate → failure file cleared
rm src/BROKEN
GATE
[ ! -f .harness/state/last-gate-failure.txt ] && ok "gates: re-gate after fix clears failure file" || no "gates: re-gate after fix clears failure file" "present" "absent"
cd /; rm -rf "$R"

# ============================================================ kick-loop --review flag
# mkfake/KL are reused from the stub block above — they resolve $FAKEBIN at
# call time, so pointing it at this repo's .fakebin is enough. Do NOT redefine
# them here: shellcheck errors on a use that precedes a later redefinition
# (SC2218), which is exactly what broke CI once before.
R="$(mkrepo 'src')"; cd "$R"; mkdir -p .fakebin; FAKEBIN="$PWD/.fakebin"
# --review with --drive: an audited-fail commit should trigger the REVIEW
# message. The fake claude commits audited-fail on the first tick and writes
# HANDOFF on the second, so the review check fires between them (after tick 1,
# before HANDOFF exists).
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
n=$(wc -l < calls.log | tr -d '[:space:]')
if [ "$n" -ge 2 ]; then
  bash migration/tools/gates.sh >/dev/null 2>&1
  printf 'nothing left\n' > migration/HANDOFF.md
  git add -A >/dev/null 2>&1
  git commit -qm "migrate HANDOFF: done" >/dev/null 2>&1
else
  bash migration/tools/gates.sh >/dev/null 2>&1
  printf '\nreview checkpoint\n' >> migration/parity-matrix.md
  git add migration/parity-matrix.md >/dev/null 2>&1
  git commit -qm "migrate E01: audited-fail" >/dev/null 2>&1
fi
exit 0
FAKE
out="$(KL --drive --review 2>&1)"
case "$out" in *REVIEW*audited-fail*) ok "kick-loop: --review detects audited-fail commit";; *) no "kick-loop: --review detects audited-fail commit" "$out" "REVIEW.*audited-fail";; esac
case "$out" in *no\ TTY*) ok "kick-loop: --review logs no-TTY in headless mode";; *) no "kick-loop: --review logs no-TTY in headless mode" "$out" "no TTY";; esac
rm -f calls.log; rm -rf .harness
cd /; rm -rf "$R"

# ============================================================ .harness gitignored (regression)
# A real install typically gitignores .harness/ (local proof state). The content
# hash must still work — an explicit exclude pathspec used to error on the
# ignored path and fail the gate.
R="$(mkrepo 'src')"; cd "$R"
printf '.harness/\n' > .gitignore; git add .gitignore; git commit -qm "ignore .harness" >/dev/null
GATE; chk "gitignore: gate succeeds with .harness ignored" "$?" 0
chk "gitignore: stop allows after gate" "$(STOP)" 0
cd /; rm -rf "$R"
# scope="." + .harness gitignored: exclude and ignore interact; must not error
R="$(mkrepo '.')"; cd "$R"
printf '.harness/\n' > .gitignore; git add .gitignore; git commit -qm "ignore .harness" >/dev/null
GATE; chk "gitignore+scopedot: gate succeeds" "$?" 0
chk "gitignore+scopedot: stop allows"    "$(STOP)" 0
cd /; rm -rf "$R"

# ============================================================ broken hash tool → fail-CLOSED
R="$(mkrepo 'src')"; cd "$R"
GATE; chk "toolbroken: gated clean allows" "$(STOP)" 0
# corrupt the hash tool so it emits no hash (exit nonzero, no stdout)
printf '#!/usr/bin/env bash\nexit 3\n' > migration/tools/working-tree-hash.sh
chk "toolbroken: broken hash tool blocks (fail-closed)" "$(STOP)" 2
# anti-wedge: the stop_hook_active retry still releases despite the broken tool
printf '{"stop_hook_active":true}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1
chk "toolbroken: retry releases despite broken tool" "$?" 0
cd /; rm -rf "$R"

# ============================================================ SCOPE="." + hostile TMPDIR
R="$(mkrepo '.')"; cd "$R"
export TMPDIR=.tmp; mkdir -p .tmp
bash migration/tools/record-gates.sh
now="$(bash migration/tools/working-tree-hash.sh)"
chk "scope-dot: proof stable w/ TMPDIR=.tmp (no self-ref)" "$now" "$(cat .harness/state/gates-passed.diffsha)"
unset TMPDIR
printf 'evil\n' > src/evil.txt; git add -A; git commit -qm "migrate Y: audited-fail" >/dev/null
chk "scope-dot: audited-fail code commit blocks despite untracked proof" "$(STOP)" 2
printf 'more\n' >> src/evil.txt
chk "scope-dot: dirty audited-fail blocks" "$(STOP)" 2
cd /; rm -rf "$R"

# ============================================================ guards
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "frozen: edit legacy blocks"                  "$(FROZEN 'legacy/src/A.java')" 2
chk "frozen: edit proof file blocks"              "$(FROZEN '.harness/state/gates-passed.diffsha')" 2
chk "frozen: dot-segment proof variant blocks"    "$(FROZEN '.harness/./state/gates-passed.diffsha')" 2
chk "frozen: parent-segment proof variant blocks" "$(FROZEN '.harness/state/../state/gates-passed.diffsha')" 2
chk "frozen: normal src edit allowed"             "$(FROZEN 'src/a.txt')" 0
chk "frozen: locked gates.sh edit blocks"         "$(FROZEN 'migration/tools/gates.sh')" 2
chk "frozen: locked hook edit blocks"             "$(FROZEN '.claude/hooks/stop-require-gates.sh')" 2
chk "frozen: locked settings edit blocks"         "$(FROZEN '.claude/settings.json')" 2
chk "frozen: locked harness.env edit blocks"      "$(FROZEN 'migration/harness.env')" 2
chk "frozen: parity-matrix edit allowed"          "$(FROZEN 'migration/parity-matrix.md')" 0
chk "guard: --no-verify blocks"                   "$(GUARD 'git commit --no-verify -m x')" 2
chk "guard: direct record-gates blocks"           "$(GUARD 'bash migration/tools/record-gates.sh')" 2
chk "guard: globbed record-gates blocks"          "$(GUARD 'bash migration/tools/record-g*.sh')" 2
chk "guard: quoted record-gates spelling blocks"  "$(GUARD 'bash migration/tools/record-gate\"\"s.sh')" 2
chk "guard: redirect write to proof blocks"       "$(GUARD 'echo x > .harness/state/gates-passed.diffsha')" 2
chk "guard: sed --in-place on proof blocks"       "$(GUARD 'sed --in-place s/a/b/ .harness/state/gates-passed.diffsha')" 2
chk "guard: cat proof allowed"                    "$(GUARD 'cat .harness/state/gates-passed.diffsha')" 0
chk "guard: plain grep read of proof allowed"     "$(GUARD 'grep foo .harness/state/gates-passed.diffsha')" 0
chk "guard: nested bash -c proof write blocks"    "$(GUARD "bash -c 'echo x > .harness/state/gates-passed.diffsha'")" 2
chk "guard: literal > in read over-blocks (conservative)" "$(GUARD "grep '"'>'"' .harness/state/gates-passed.diffsha")" 2
# locked tooling: writes blocked, execute/read allowed (target-aware)
chk "guard: sed -i on locked gates.sh blocks"     "$(GUARD 'sed -i s/a/b/ migration/tools/gates.sh')" 2
chk "guard: redirect write to locked hook blocks" "$(GUARD 'echo x > .claude/hooks/stop-require-gates.sh')" 2
chk "guard: cp over locked harness.env blocks"    "$(GUARD 'cp /dev/null migration/harness.env')" 2
chk "guard: exec locked gates.sh allowed"         "$(GUARD 'bash migration/tools/gates.sh')" 0
chk "guard: read locked gates.sh allowed"         "$(GUARD 'cat migration/tools/gates.sh')" 0
chk "guard: exec gates.sh redirect elsewhere allowed" "$(GUARD 'bash migration/tools/gates.sh > /tmp/g.log')" 0
chk "guard: gates.sh piped to tee elsewhere allowed"  "$(GUARD 'bash migration/tools/gates.sh 2>&1 | tee /tmp/g.log')" 0

# DESTRUCTION of a locked file is a mutation. Blocking only writers left the
# shortest bypass in the harness open: a Stop hook that is not on disk does not
# run, so `rm` of the hook disabled enforcement outright without writing a byte.
chk "guard: rm of locked Stop hook blocks"        "$(GUARD 'rm .claude/hooks/stop-require-gates.sh')" 2
chk "guard: rm -rf of locked hooks dir blocks"    "$(GUARD 'rm -rf .claude/hooks/')" 2
chk "guard: rm of locked gates.sh blocks"         "$(GUARD 'rm -f migration/tools/gates.sh')" 2
chk "guard: git rm of locked hook blocks"         "$(GUARD 'git rm .claude/hooks/stop-require-gates.sh')" 2
chk "guard: git checkout revert of locked gates blocks" "$(GUARD 'git checkout HEAD~1 -- migration/tools/gates.sh')" 2
chk "guard: git restore of locked harness.env blocks"   "$(GUARD 'git restore migration/harness.env')" 2
chk "guard: chmod -x on locked hook blocks"       "$(GUARD 'chmod -x .claude/hooks/stop-require-gates.sh')" 2
chk "guard: rm of an UNprotected file allowed"    "$(GUARD 'rm src/scratch.txt')" 0

# The frozen ORACLE was guarded only on the Edit/Write path — Bash never checked
# it, so a redirect or an rm mutated the reference parity is measured against.
chk "guard: redirect write into frozen oracle blocks" "$(GUARD 'echo x > legacy/src/x.cpp')" 2
chk "guard: heredoc-style write to frozen blocks"     "$(GUARD 'cat > legacy/src/x.cpp')" 2
chk "guard: rm -rf of frozen oracle blocks"           "$(GUARD 'rm -rf legacy/src')" 2
chk "guard: sed -i on frozen oracle blocks"           "$(GUARD 'sed -i s/a/b/ legacy/src/x.cpp')" 2
chk "guard: reading the frozen oracle allowed"        "$(GUARD 'cat legacy/src/x.cpp')" 0
chk "guard: grepping the frozen oracle allowed"       "$(GUARD 'grep -rn foo legacy/src')" 0
chk "guard: RUNNING the oracle allowed"               "$(GUARD './legacy/build/app --dump-fixtures')" 0

# --- blanket staging guard (message masking, no quote-strip bypass) ---
# JGUARD feeds raw JSON so payloads can contain escaped double quotes.
JGUARD(){ printf '%s' "$1" | bash .claude/hooks/pretooluse-command-guard.sh >/dev/null 2>&1; echo $?; }
chk "guard: git add -A blocks"                    "$(GUARD 'git add -A')" 2
chk "guard: git add . blocks"                     "$(GUARD 'git add .')" 2
chk "guard: git add -u blocks"                    "$(GUARD 'git add -u')" 2
chk "guard: git add --update blocks"              "$(GUARD 'git add --update')" 2
chk "guard: git commit -am blocks"                "$(GUARD 'git commit -am x')" 2
chk "guard: git commit -a -m blocks"              "$(GUARD 'git commit -a -m x')" 2
chk "guard: git commit --all blocks"              "$(GUARD 'git commit --all -m x')" 2
chk "guard: explicit-path git add allowed"        "$(GUARD 'git add src/a.txt CLAUDE.md')" 0
chk "guard: git status allowed"                   "$(GUARD 'git status')" 0
chk "guard: commit -F message file allowed"       "$(GUARD 'git commit -F /tmp/msg.txt')" 0
# message text mentioning staging flags must NOT block (false-positive lesson)
chk "guard: message text 'add -A docs' allowed"   "$(JGUARD '{"tool_input":{"command":"git commit -m \"add -A docs\""}}')" 0
chk "guard: message text 'use -a flag' allowed"   "$(JGUARD '{"tool_input":{"command":"git commit -m \"use -a flag\""}}')" 0
chk "guard: single-quoted message allowed"        "$(JGUARD "{\"tool_input\":{\"command\":\"git commit -m 'add -A quoted'\"}}")" 0
# quote-strip bypass regression: stray quotes around a REAL flag must still
# block (a global quote-stripper would delete the -a between them)
chk "guard: stray quotes around real -a still block" "$(JGUARD '{"tool_input":{"command":"git commit \" -a \" -m msg"}}')" 2
chk "guard: real -a after a message still blocks"    "$(JGUARD '{"tool_input":{"command":"git commit -m \"x\" -a"}}')" 2
# dot-slash spelling of whole-tree staging is the same blanket add
chk "guard: git add ./ blocks (dot-slash spelling)"  "$(GUARD 'git add ./')" 2
chk "guard: git add ./path allowed"                  "$(GUARD 'git add ./src/a.txt')" 0
# the message mask must stop at each message's own closing quote: a real -a
# BETWEEN two -m messages used to be swallowed by a mask running to the LAST
# quote (confirmed bypass); -a as message TEXT must still be masked.
chk "guard: real -a between two messages still blocks" "$(JGUARD '{"tool_input":{"command":"git commit -m \"feat: subject\" -a -m \"body\""}}')" 2
chk "guard: two messages without -a allowed"           "$(JGUARD '{"tool_input":{"command":"git commit -m \"one\" -m \"two\""}}')" 0
chk "guard: escaped quotes and -a text inside message allowed" "$(JGUARD '{"tool_input":{"command":"git commit -m \"say \\\"hi -a there\\\" ok\" f.md"}}')" 0
chk "guard: message ending in backslash then real -a blocks"   "$(JGUARD '{"tool_input":{"command":"git commit -m \"x\\\\\" -a -m \"y\""}}')" 2
cd /; rm -rf "$R"

# ============================================================ hash: gitignored scope entry
# A HARNESS_SCOPE entry inside a gitignored directory must fail closed WITH
# the entry named — not silently produce no hash (field incident: a committed
# tools dir shadowed by a generic '**/build' ignore pattern).
R="$(mkrepo 'src tools_dir migration .claude CLAUDE.md')"; cd "$R"
mkdir -p tools_dir; printf 'tool\n' > tools_dir/t.txt
git add tools_dir; git commit -qm tools >/dev/null
printf 'tools_dir\n' > .gitignore
git add .gitignore; git commit -qm ignore >/dev/null
herr="$(bash migration/tools/working-tree-hash.sh 2>&1 >/dev/null)"; hrc=$?
chk "hash: gitignored scope entry fails closed" "$hrc" 1
case "$herr" in *tools_dir*) ok "hash: failure names the offending entry";;
  *) no "hash: failure names the offending entry" "$herr" "*tools_dir*";; esac
cd /; rm -rf "$R"

# ============================================================ frozen: out-of-repo paths
# Fragment matching must not block same-shaped paths in OTHER repos (field
# incident: editing a template copy of the harness elsewhere on disk was
# blocked because its absolute path contains '.claude/hooks/').
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "frozen: out-of-repo .claude/hooks path allowed" "$(FROZEN '/somewhere/else/template/.claude/hooks/x.sh')" 0
chk "frozen: out-of-repo legacy-fragment path allowed" "$(FROZEN '/other/repo/legacy/src/A.java')" 0
chk "frozen: in-repo absolute locked path still blocks" "$(FROZEN "$R/.claude/hooks/stop-require-gates.sh")" 2
chk "frozen: in-repo relative locked path still blocks" "$(FROZEN '.claude/hooks/stop-require-gates.sh')" 2
# aliased spellings of an in-repo path must still be guarded: a logical-vs-
# physical prefix mismatch (symlinked checkout) or dot-segments used to exit
# 0 BEFORE any guard, silently disabling all of them.
ln -s "$R" "$R.lnk"
chk "frozen: symlink-aliased locked path still blocks" "$(FROZEN "$R.lnk/.claude/hooks/stop-require-gates.sh")" 2
chk "frozen: symlink-aliased frozen path still blocks" "$(FROZEN "$R.lnk/legacy/src/A.java")" 2
chk "frozen: dot-segment absolute path still blocks"   "$(FROZEN "$R/./legacy/src/A.java")" 2
rm -f "$R.lnk"
cd /; rm -rf "$R"

# ============================================================ telemetry: loop fingerprints
# Different edits to the SAME file must not read as a loop; identical edits must.
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
printf 'HARNESS_LOOP_THRESHOLD="3"\nHARNESS_LOOP_WINDOW="6"\n' >> migration/harness.env
rm -f .harness/state/tool-stats/fingerprints
out=""
for i in 1 2 3; do
  out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.txt","old_string":"version %s","new_string":"version %s"}}' "$i" "$((i+1))" \
    | bash .claude/hooks/posttooluse-telemetry.sh 2>/dev/null)"
done
case "$out" in *Loop*detected*) no "telemetry: distinct edits to one file do NOT fire loop" "loop fired" "no loop";;
  *) ok "telemetry: distinct edits to one file do NOT fire loop";; esac
rm -f .harness/state/tool-stats/fingerprints
out=""
for i in 1 2 3; do
  out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.txt","old_string":"same","new_string":"same2"}}' \
    | bash .claude/hooks/posttooluse-telemetry.sh 2>/dev/null)"
done
case "$out" in *Loop*detected*) ok "telemetry: identical edits still fire loop";;
  *) no "telemetry: identical edits still fire loop" "$out" "Loop detected";; esac
# second tier: a spin whose edits DIFFER slightly each try must still surface
# once same-file edits fill the ENTIRE window (5 of 6 stays quiet).
rm -f .harness/state/tool-stats/fingerprints
out=""
for i in 1 2 3 4 5; do
  out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.txt","old_string":"try %s","new_string":"fix %s"}}' "$i" "$i" \
    | bash .claude/hooks/posttooluse-telemetry.sh 2>/dev/null)"
done
case "$out" in *"Possible loop"*) no "telemetry: same-file edits below window stay quiet" "nudged at 5" "quiet";;
  *) ok "telemetry: same-file edits below window stay quiet";; esac
out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.txt","old_string":"try 6","new_string":"fix 6"}}' \
  | bash .claude/hooks/posttooluse-telemetry.sh 2>/dev/null)"
case "$out" in *"Possible loop"*) ok "telemetry: window full of same-file edits fires nudge";;
  *) no "telemetry: window full of same-file edits fires nudge" "$out" "Possible loop";; esac
cd /; rm -rf "$R"

# ============================================================ doctor (read-only report)
# NB: capture output into a var and match with `case`, not `doctor | grep -q`.
# grep -q closes the pipe on first match → doctor gets SIGPIPE → under this
# script's `set -o pipefail` the pipeline reports non-zero and the assertion
# would misfire even on a correct match.
has(){ case "$2" in *"$1"*) ok "$3";; *) no "$3" "<missing>" "$1";; esac; }
R="$(mkrepo 'src')"; cd "$R"
out="$(bash migration/tools/doctor.sh 2>&1)"; chk "doctor: exits 0 on valid repo" "$?" 0
has "proof: NONE"  "$out" "doctor: NONE before gate"
mkdir -p .harness/state
printf '%s\n' \
  '{"event":"run.start","ts":"t1","run_id":"r1"}' \
  '{"event":"run.end","ts":"t2","run_id":"r1","outcome":"usage_limit","exit_code":75,"duration_s":4,"tool_calls":9,"tree":"abc"}' \
  > .harness/state/runs.ndjson
out="$(bash migration/tools/doctor.sh 2>&1)"
has "latest=usage_limit rc=75 duration=4s calls=9" "$out" "doctor: summarizes latest run journal entry"
GATE
out="$(bash migration/tools/doctor.sh 2>&1)"; has "proof: GATED" "$out" "doctor: GATED after gate"
printf 'changed\n' > src/a.txt
out="$(bash migration/tools/doctor.sh 2>&1)"; has "proof: STALE" "$out" "doctor: STALE after edit"
# read-only: running doctor must not alter the tree hash
GATE; before="$(bash migration/tools/working-tree-hash.sh)"
bash migration/tools/doctor.sh >/dev/null 2>&1
after="$(bash migration/tools/working-tree-hash.sh)"
chk "doctor: read-only (tree hash unchanged)" "$after" "$before"
# the template ships lowercase operator-fill placeholders (legacy-runtime.md
# '<exact build command(s)>', spec-matrix.md '<component>') — an all-caps-only
# scan reported "placeholders : none" on an unconfigured install.
out="$(bash migration/tools/doctor.sh 2>&1)"
has "placeholders : REMAIN" "$out" "doctor: lowercase shipped placeholders reported"
has "legacy-runtime.md" "$out" "doctor: placeholder report names legacy-runtime.md"
cd /; rm -rf "$R"

# ==================================================== frozen-oracle integrity
# OUTCOME-based: the gate does not care which tool moved the oracle, so the
# documented PreToolUse bypasses (subagent hooks not firing, interpreter writes,
# odd path spellings) cannot get past it.
FZ(){ bash migration/tools/check-frozen.sh >/dev/null 2>&1; echo $?; }

R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "frozen-hash: intact oracle passes"           "$(FZ)" 0
chk "guard: check-frozen --record is agent-blocked" "$(GUARD 'bash migration/tools/check-frozen.sh --record')" 2

# drift, by every route a bypass would take
printf 'class A{int x;}\n' > legacy/src/A.java
chk "frozen-hash: edited oracle file fails"        "$(FZ)" 1
# committing the drift must NOT launder it (the hash is content-only, HEAD-free)
git add -A >/dev/null 2>&1; git commit -qm "sneak" >/dev/null 2>&1
chk "frozen-hash: COMMITTED drift still fails"     "$(FZ)" 1
# restoring the CONTENT restores the hash even though history now has two extra
# commits — the proof is content-addressed, so neither committing nor reverting
# is what matters, only what the bytes are
printf 'class A{}\n' > legacy/src/A.java
git add -A >/dev/null 2>&1; git commit -qm "restore" >/dev/null 2>&1
chk "frozen-hash: restored oracle passes again"    "$(FZ)" 0

# an ADDED file under the oracle is drift too — a "helper" in legacy/src is new
# oracle behavior, and a naive "compare the files we know about" check misses it
printf 'class B{}\n' > legacy/src/B.java
chk "frozen-hash: ADDED oracle file fails"         "$(FZ)" 1
rm -f legacy/src/B.java
chk "frozen-hash: removing the addition passes"    "$(FZ)" 0

# deletion
rm -f legacy/src/A.java
chk "frozen-hash: DELETED oracle file fails"       "$(FZ)" 1
git checkout -- legacy/src/A.java 2>/dev/null
chk "frozen-hash: restored deletion passes"        "$(FZ)" 0

# the gate itself must refuse a drifted oracle
printf 'class A{int y;}\n' > legacy/src/A.java
GATE && no "gates: drifted oracle fails the gate" "pass" "fail" || ok "gates: drifted oracle fails the gate"
git checkout -- legacy/src/A.java 2>/dev/null

# baseline integrity: absent, untracked, and re-record are all refused.
# Drop it from the INDEX as well as the worktree — mkrepo commits the baseline, so
# merely deleting the file leaves it tracked and the untracked case never arises.
git rm -q --cached migration/frozen-baseline.sha >/dev/null 2>&1
rm -f migration/frozen-baseline.sha
chk "frozen-hash: MISSING baseline fails (unproven, not a pass)" "$(FZ)" 1
# an untracked baseline proves nothing — whoever can create the file picks the answer
bash migration/tools/check-frozen.sh --record >/dev/null 2>&1
chk "frozen-hash: UNCOMMITTED baseline fails"     "$(FZ)" 1
git add migration/frozen-baseline.sha >/dev/null 2>&1
git commit -qm baseline >/dev/null 2>&1
chk "frozen-hash: committed baseline passes"      "$(FZ)" 0
bash migration/tools/check-frozen.sh --record >/dev/null 2>&1
chk "frozen-hash: --record refuses to overwrite"  "$?" 1

# misconfiguration must not read as green
sed -i 's|HARNESS_FROZEN="legacy/src"|HARNESS_FROZEN="no/such/path"|' migration/harness.env
chk "frozen-hash: fragments matching NOTHING fail" "$(FZ)" 1
sed -i 's|HARNESS_FROZEN="no/such/path"|HARNESS_FROZEN=""|' migration/harness.env
chk "frozen-hash: empty HARNESS_FROZEN passes (in-place)" "$(FZ)" 0
cd /; rm -rf "$R"

# ==================================================== unskippable audit (rule 10)
# The rule was prose: /migrate-slice ASKED for the auditor. On a live migration a
# tick wrote audited-pass while the gates were green and no auditor had run.
AUD(){ bash migration/tools/check-audits.sh >/dev/null 2>&1; echo $?; }
# '#' delimiter: the row is made of '|' characters, so '|' cannot delimit the sed.
setrow(){ sed -i "s#^| B01 |.*#| B01 | bootstrap | - | - | - | $1 | - | - |#" migration/parity-matrix.md; }

R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "audits: untouched board passes"              "$(AUD)" 0
chk "guard: direct write of an audit record blocks" "$(GUARD 'echo deadbeef pass > .harness/state/audits/B01')" 2
chk "guard: rm of an audit record blocks"           "$(GUARD 'rm .harness/state/audits/B01')" 2

# claiming audited-pass with no auditor having run
setrow 'audited-pass'
chk "audits: audited-pass with NO record fails"   "$(AUD)" 1
GATE && no "gates: unaudited audited-pass fails the gate" "pass" "fail" || ok "gates: unaudited audited-pass fails the gate"

# the auditor runs and records a pass for THIS code
bash migration/tools/record-audit.sh B01 pass >/dev/null 2>&1
chk "audits: recorded pass for current code passes" "$(AUD)" 0

# a 'fail' verdict cannot be laundered into an audited-pass row
bash migration/tools/record-audit.sh B01 fail >/dev/null 2>&1
chk "audits: recorded FAIL vs audited-pass row fails" "$(AUD)" 1
bash migration/tools/record-audit.sh B01 pass >/dev/null 2>&1
chk "audits: back to pass"                        "$(AUD)" 0

# auditing, then editing the code, invalidates the audit (the hash moves)
printf 'changed after the audit\n' > src/a.txt
chk "audits: code edited AFTER the audit fails"   "$(AUD)" 1
bash migration/tools/record-audit.sh B01 pass >/dev/null 2>&1
chk "audits: re-audit of the new code passes"     "$(AUD)" 0

# bookkeeping edits must NOT invalidate an audit — otherwise writing the very row
# the auditor just cleared would break its own record
printf '\n<!-- ledger note -->\n' >> migration/integration-ledger.md
chk "audits: ledger edit does not invalidate"     "$(AUD)" 0
printf '\n<!-- adr note -->\n' >> migration/decisions.md
chk "audits: decisions edit does not invalidate"  "$(AUD)" 0

# once committed, the row is grandfathered: later slices legitimately move the
# code hash, and re-checking old rows against it would fail every board forever
git add -A >/dev/null 2>&1; git commit -qm "migrate B01: audited-pass" >/dev/null 2>&1
rm -rf .harness/state/audits
printf 'a later slice edits the code\n' > src/a.txt
chk "audits: row audited-pass at HEAD is not re-checked" "$(AUD)" 0
cd /; rm -rf "$R"

# ==================================================== held-out parity
# Cases generated from the oracle AT GATE TIME: they did not exist while the code
# was written, so there was nothing to overfit to. Ephemerality is the defense.
HOLD(){ bash migration/tools/check-holdout.sh >/dev/null 2>&1; echo $?; }
# Replace the HOLDOUT block with a stub that succeeds or fails on demand. sed's
# 'c' command deletes the MARKER lines along with the range, so re-wiring a second
# time would match nothing and silently leave the previous stub in place — restore
# the pristine tool first.
wire_holdout(){
  cp "$H/migration/tools/check-holdout.sh" migration/tools/check-holdout.sh
  sed -i "/# HARNESS:HOLDOUT-START/,/# HARNESS:HOLDOUT-END/c\\$1" migration/tools/check-holdout.sh
}

R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "holdout: disabled by default (no-op)"        "$(HOLD)" 0
GATE && ok "holdout: gate passes with holdout off" || no "holdout: gate passes with holdout off" "fail" "pass"

# switched ON but not wired must FAIL — an oracle enabled and connected to nothing
# reporting green is a worse lie than having no oracle at all
printf 'HARNESS_HOLDOUT="on"\n' >> migration/harness.env
chk "holdout: enabled but UNCONFIGURED fails"     "$(HOLD)" 1
GATE && no "gates: unconfigured holdout fails the gate" "pass" "fail" || ok "gates: unconfigured holdout fails the gate"

# wired and agreeing with the oracle
wire_holdout 'true  # selftest: oracle and port agree'
chk "holdout: wired + agreeing passes"            "$(HOLD)" 0
GATE && ok "gates: wired holdout passes the gate" || no "gates: wired holdout passes the gate" "fail" "pass"

# wired and DISAGREEING must fail the gate — this is the whole point
wire_holdout 'exit 1  # selftest: port disagrees on unseen cases'
chk "holdout: port disagreeing on unseen cases fails" "$(HOLD)" 1
GATE && no "gates: holdout mismatch fails the gate" "pass" "fail" || ok "gates: holdout mismatch fails the gate"
cd /; rm -rf "$R"

# ==================================================== cross-model escalation
# A fresh context of the SAME model is still the same model: the tick buys
# independence from the conversation, not from the blind spot.
R="$(mkrepo 'src')"; cd "$R"; mkdir -p .fakebin; FAKEBIN="$PWD/.fakebin"
KL(){ ( PATH="$FAKEBIN:$PATH" bash migration/tools/kick-loop.sh "$@" ); }

# A fake claude that records every --model it is invoked with, leaves a VALID gate
# proof, and changes nothing in scope — so the tick is gate-covered (rc 0) but
# idle. That combination is what the idle backstop and the escalation path key on;
# a tick that leaves no proof exits 65 immediately and never reaches either.
# .harness/ is outside HARNESS_SCOPE, so the bookkeeping file below is not progress.
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
mkdir -p .harness/state
m="(default)"
while [ $# -gt 0 ]; do
  case "$1" in --model) m="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$m" >> .harness/state/models-used
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chmod +x "$FAKEBIN/claude"

# escalation OFF (default): both ticks run on the session default, backstop at 64
rm -f .harness/state/models-used
KL --drive >/dev/null 2>&1; rc=$?
chk "escalate: off by default — idle backstop still 64" "$rc" 64
chk "escalate: off — no --model was passed" "$(sort -u .harness/state/models-used | tr -d '\n')" "(default)"

# escalation ON: tick 1 idles -> tick 2 runs on the escalation model
rm -f .harness/state/models-used
printf 'HARNESS_ESCALATE_MODEL="opus"\n' >> migration/harness.env
KL --drive >/dev/null 2>&1; rc=$?
chk "escalate: on — still stops 64 when BOTH models idle" "$rc" 64
chk "escalate: tick 1 on the default model" "$(sed -n 1p .harness/state/models-used)" "(default)"
chk "escalate: tick 2 escalated to the other model" "$(sed -n 2p .harness/state/models-used)" "opus"

# a productive tick resets the escalation — the next tick returns to the default
rm -f .harness/state/models-used
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
mkdir -p .harness/state
m="(default)"
while [ $# -gt 0 ]; do
  case "$1" in --model) m="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$m" >> .harness/state/models-used
n=$(wc -l < .harness/state/models-used)
# tick 2 (the escalated one) actually makes progress; every other tick idles
[ "$n" -eq 2 ] && printf 'progress\n' > src/a.txt
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
KL --drive --max 4 >/dev/null 2>&1
chk "escalate: tick 2 escalated after the idle tick 1" "$(sed -n 2p .harness/state/models-used)" "opus"
chk "escalate: tick 3 back to default after progress"  "$(sed -n 3p .harness/state/models-used)" "(default)"
cd /; rm -rf "$R"

# ==================================================== tracked-but-ignored files
# A file committed BEFORE a matching .gitignore pattern was added stays tracked
# in the real index — but the hash tool builds a THROWAWAY index, where (without
# seeding it from HEAD) the file looks untracked-and-ignored and `git add -A`
# silently skips it: edits to it never move the hash and the Stop hook waves
# them through (confirmed bypass; fixed by seeding the temp index from HEAD).
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
printf 'prod-v1\n' > src/config.prod.txt
git add -f src/config.prod.txt >/dev/null 2>&1; git commit -qm prod >/dev/null
printf '*.prod.txt\n' > .gitignore
git add .gitignore >/dev/null 2>&1; git commit -qm ignore >/dev/null
hI1="$(bash migration/tools/working-tree-hash.sh)"
printf 'prod-v2 TAMPERED\n' > src/config.prod.txt
hI2="$(bash migration/tools/working-tree-hash.sh)"
[ "$hI1" != "$hI2" ] && ok "hash: tracked-but-ignored edit moves the hash" \
  || no "hash: tracked-but-ignored edit moves the hash" "$hI2" "!=$hI1"
git checkout -q -- src/config.prod.txt
rm src/config.prod.txt
hI3="$(bash migration/tools/working-tree-hash.sh)"
[ "$hI1" != "$hI3" ] && ok "hash: tracked-but-ignored deletion moves the hash" \
  || no "hash: tracked-but-ignored deletion moves the hash" "$hI3" "!=$hI1"
git checkout -q -- src/config.prod.txt
# and the Stop hook actually holds the un-gated edit to such a file
GATE; chk "stop: gated tree with ignored-tracked file allows" "$(STOP)" 0
printf 'sneaky\n' > src/config.prod.txt
chk "stop: un-gated ignored-tracked edit blocks" "$(STOP)" 2
cd /; rm -rf "$R"

# ==================================================== audit snapshot (commit-then-gate)
# check-audits compares against the board snapshot record-gates.sh wrote at the
# last SUCCESSFUL gate run — not HEAD. `git commit` is un-gated, so trusting
# HEAD let write-row -> commit -> gate launder an unaudited audited-pass
# (confirmed bypass; the HEAD fallback survives only for fresh clones).
AUD(){ bash migration/tools/check-audits.sh >/dev/null 2>&1; echo $?; }
setrow(){ sed -i "s#^| B01 |.*#| B01 | bootstrap | - | - | - | $1 | - | - |#" migration/parity-matrix.md; }
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
GATE   # records the proof AND the board snapshot
[ -f .harness/state/gates-passed.parity-matrix.md ] \
  && ok "record-gates: board snapshot written on gate pass" \
  || no "record-gates: board snapshot written on gate pass" "missing" "present"
setrow 'audited-pass'
git add migration/parity-matrix.md; git commit -qm "migrate B01: audited-pass" >/dev/null
chk "audits: commit-then-gate no longer exempts the row" "$(AUD)" 1
bash migration/tools/record-audit.sh B01 pass >/dev/null 2>&1
chk "audits: honest record still satisfies it" "$(AUD)" 0
GATE   # snapshot now contains the settled row
printf 'later slice\n' > src/a.txt
rm -rf .harness/state/audits
chk "audits: row settled in the snapshot stays settled" "$(AUD)" 0
cd /; rm -rf "$R"

# ==================================================== frozen baseline provenance
# The reference must be read from git, not the working tree: an agent that can
# mutate the oracle through a hook bypass can forge the working-tree baseline
# the same way, and trackedness alone would still verify (confirmed launder).
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
FRZ(){ bash migration/tools/check-frozen.sh >/dev/null 2>&1; echo $?; }
chk "frozen: committed baseline verifies" "$(FRZ)" 0
printf 'class A{ drifted }\n' > legacy/src/A.java
forged="$( { printf '%s\n' legacy/src/A.java \
  | GIT_INDEX_FILE=.git/selftest-forge git add -f --pathspec-from-file=- -- 2>/dev/null
  GIT_INDEX_FILE=.git/selftest-forge git write-tree; } )"
printf '%s\n' "$forged" > migration/frozen-baseline.sha
chk "frozen: forged working-tree baseline cannot launder drift" "$(FRZ)" 1
git checkout -q -- migration/frozen-baseline.sha legacy/src/A.java
chk "frozen: restored oracle verifies again" "$(FRZ)" 0
cd /; rm -rf "$R"

# ==================================================== feature-profile checkpoint subject
# The escape must accept the feature profile's `feat <id>:` convention
# (CLAUDE-feature.md rule 9), not only `migrate <id>:` — a compliant feature
# checkpoint used to be classified un-gated for its prefix alone.
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
GATE
printf '\ncheckpoint\n' >> migration/parity-matrix.md
git add migration/parity-matrix.md; git commit -qm "feat S03: audited-fail" >/dev/null
chk "stop: feat-prefixed bookkeeping checkpoint allows" "$(STOP)" 0
printf '\nmore\n' >> migration/parity-matrix.md
git add migration/parity-matrix.md; git commit -qm "wip S03: audited-fail" >/dev/null
chk "stop: unknown-prefix checkpoint still blocks" "$(STOP)" 2
cd /; rm -rf "$R"

# ==================================================== stub-tag integrity
# Registration means a real OPEN table row: the shipped INTEG-example row is a
# format sample (else copying its tag onto every stub is a universal amnesty),
# prose mentions are not rows, and a `wired` row cannot cover a sentinel that
# is still in the source.
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
STUBS(){ bash migration/tools/check-stubs.sh >/dev/null 2>&1; echo $?; }
mkdir -p app
printf 'STUB_SENTINEL="not yet implemented"\nSTUB_SCAN="app"\n' >> migration/harness.env
printf 'x = "not yet implemented" // INTEG-example\n' > app/a.txt
git add app >/dev/null 2>&1
chk "stubs: INTEG-example tag is rejected" "$(STUBS)" 1
printf '| INTEG-real | thing | stub | B01 | menu | F-w | - |\n' >> migration/integration-ledger.md
printf 'x = "not yet implemented" // INTEG-real\n' > app/a.txt
chk "stubs: open-row registration accepted" "$(STUBS)" 0
printf 'prose mentions INTEG-prose casually\n' >> migration/integration-ledger.md
printf 'x = "not yet implemented" // INTEG-prose\n' > app/a.txt
chk "stubs: prose mention is not a registration" "$(STUBS)" 1
sed -i 's/| INTEG-real | thing | stub |/| INTEG-real | thing | wired |/' migration/integration-ledger.md
printf 'x = "not yet implemented" // INTEG-real\n' > app/a.txt
chk "stubs: wired row cannot cover a live sentinel" "$(STUBS)" 1
cd /; rm -rf "$R"

# ==================================================== guard: state root + tree-wide reverts
R="$(mkrepo 'src migration .claude CLAUDE.md')"; cd "$R"
chk "guard: rm of .harness/state root blocks"      "$(GUARD 'rm -rf .harness/state')" 2
chk "guard: rm of .harness root blocks"            "$(GUARD 'rm -rf .harness')" 2
chk "guard: rm of idle-ticks stays allowed"        "$(GUARD 'rm .harness/state/idle-ticks')" 0
chk "guard: rm of a board snapshot blocks"         "$(GUARD 'rm .harness/state/gates-passed.parity-matrix.md')" 2
chk "guard: write to a board snapshot blocks"      "$(GUARD 'echo x > .harness/state/gates-passed.parity-matrix.md')" 2
chk "guard: git checkout -- . blocks"              "$(GUARD 'git checkout -- .')" 2
chk "guard: git checkout . blocks"                 "$(GUARD 'git checkout .')" 2
chk "guard: git restore . blocks"                  "$(GUARD 'git restore .')" 2
chk "guard: git clean -fd blocks"                  "$(GUARD 'git clean -fd')" 2
chk "guard: branch checkout allowed"               "$(GUARD 'git checkout main')" 0
chk "guard: explicit-path restore allowed"         "$(GUARD 'git checkout -- src/a.txt')" 0
chk "guard: git clean dry-run allowed"             "$(GUARD 'git clean -nd')" 0
cd /; rm -rf "$R"

echo "----------------------------------------"
echo "harness self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
