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
# Self-contained: needs only bash + git. No project toolchain required (the
# scenario gates.sh is neutralised to a no-op pass).
set -uo pipefail

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
    printf 'HARNESS_SCOPE="%s"\nHARNESS_FROZEN="legacy/src"\nHARNESS_LOCKED="migration/tools/ .claude/hooks/ .claude/settings.json .claude/settings.local.json migration/harness.env"\n' "$scope" > migration/harness.env
    git add -A; git commit -qm init
  )
  echo "$T"
}
STOP(){ printf '{"stop_hook_active":false}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1; echo $?; }
GUARD(){ printf '{"tool_input":{"command":"%s"}}' "$1" | bash .claude/hooks/pretooluse-command-guard.sh >/dev/null 2>&1; echo $?; }
FROZEN(){ printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash .claude/hooks/pretooluse-frozen-legacy.sh >/dev/null 2>&1; echo $?; }
GATE(){ bash migration/tools/gates.sh >/dev/null 2>&1; }

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
chk "stop: audited-fail escape (clean) allows" "$(STOP)" 0
GATE; git add -A; git commit -q --allow-empty -m "migrate E01: audited-pass" >/dev/null
chk "stop: audited-pass allows" "$(STOP)" 0
rm -rf .harness; chk "stop: deleted-proof reopen blocks" "$(STOP)" 2
# retry (stop_hook_active) always releases
printf '{"stop_hook_active":true}' | bash .claude/hooks/stop-require-gates.sh >/dev/null 2>&1
chk "stop: retry (stop_hook_active) releases" "$?" 0
cd /; rm -rf "$R"

# ============================================================ sole scoped root
R="$(mkrepo 'src')"; cd "$R"
GATE; chk "sole: gated clean allows" "$(STOP)" 0
rm -r src; chk "sole: rm root uncommitted blocks" "$(STOP)" 2
git add -A; git commit -qm "removed src" >/dev/null
chk "sole: rm root committed normal-subject blocks" "$(STOP)" 2
git commit -q --allow-empty -m "migrate X: audited-fail" >/dev/null
chk "sole: rm root committed audited-fail allows" "$(STOP)" 0
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

# ============================================================ kick-loop (resume driver)
R="$(mkrepo 'src')"; cd "$R"
out="$(bash migration/tools/kick-loop.sh --check 2>&1)"
case "$out" in *"STATE: resume"*) ok "kick-loop: --check resume when no HANDOFF";; *) no "kick-loop: --check resume when no HANDOFF" "$out" "STATE: resume";; esac
printf 'nothing left\n' > migration/HANDOFF.md
out="$(bash migration/tools/kick-loop.sh --check 2>&1)"
case "$out" in *"STATE: done"*) ok "kick-loop: --check done when HANDOFF present";; *) no "kick-loop: --check done when HANDOFF present" "$out" "STATE: done";; esac
bash migration/tools/kick-loop.sh >/dev/null 2>&1; chk "kick-loop: no-op exit 0 when terminated" "$?" 0
cd /; rm -rf "$R"

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
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
bash migration/tools/gates.sh >/dev/null 2>&1
exit 0
FAKE
chk "kick-loop: gated exit-0 run returns 0" "$( KL >/dev/null 2>&1; echo $? )" 0
rm -rf .harness

mkfake <<'FAKE'
#!/usr/bin/env bash
echo "you have reached your usage limit; resets at 3am"
exit 1
FAKE
chk "kick-loop: usage limit on nonzero exit -> 75" "$( KL >/dev/null 2>&1; echo $? )" 75
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

# --drive: one gated slice per tick, committed HANDOFF on the second tick -> clean 0
mkfake <<'FAKE'
#!/usr/bin/env bash
echo x >> calls.log
n=$(wc -l < calls.log | tr -d '[:space:]')
if [ "$n" -ge 2 ]; then
  printf 'nothing left\n' > migration/HANDOFF.md
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
chk "kick-loop: --drive runs ticks until committed HANDOFF, exits 0" "$( KL --drive >/dev/null 2>&1; echo $? )" 0
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
POSTTOOL '{"tool_name":"Edit","tool_input":{"file_path":"src/a.txt"}}' >/dev/null
[ -s .harness/state/telemetry.ndjson ] && ok "telemetry: logs tool call to telemetry.ndjson" || no "telemetry: logs tool call to telemetry.ndjson" "empty" "nonempty"
grep -q '"tool":"Edit"' .harness/state/telemetry.ndjson && ok "telemetry: log entry has tool name" || no "telemetry: log entry has tool name" "missing" "Edit"

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
  git commit -q --allow-empty -m "migrate E01: audited-fail" >/dev/null 2>&1
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
chk "scope-dot: audited-fail clean w/ untracked proof allows" "$(STOP)" 0
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
GATE
out="$(bash migration/tools/doctor.sh 2>&1)"; has "proof: GATED" "$out" "doctor: GATED after gate"
printf 'changed\n' > src/a.txt
out="$(bash migration/tools/doctor.sh 2>&1)"; has "proof: STALE" "$out" "doctor: STALE after edit"
# read-only: running doctor must not alter the tree hash
GATE; before="$(bash migration/tools/working-tree-hash.sh)"
bash migration/tools/doctor.sh >/dev/null 2>&1
after="$(bash migration/tools/working-tree-hash.sh)"
chk "doctor: read-only (tree hash unchanged)" "$after" "$before"
cd /; rm -rf "$R"

echo "----------------------------------------"
echo "harness self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
