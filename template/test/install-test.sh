#!/usr/bin/env bash
# Test the installer (install.sh). Locates the distribution root (the dir that
# holds both install.sh and template/), installs into a throwaway git repo, and
# asserts the files land, .harness/ is gitignored, doctor runs, pre-existing
# files survive, and clobber protection works.
#
# When run from an INSTALLED copy (no install.sh present) there is nothing to
# test, so it skips cleanly. Needs only bash + git.
set -uo pipefail

self="$(cd "$(dirname "$0")" && pwd)"
DIST=""; d="$self"
while [ "$d" != "/" ]; do
  if [ -f "$d/install.sh" ] && [ -f "$d/template/.claude/hooks/stop-require-gates.sh" ]; then DIST="$d"; break; fi
  d="$(dirname "$d")"
done
if [ -z "$DIST" ]; then
  echo "SKIP: install.sh not found above $self (installed copy) — installer test not applicable"
  echo "install test: 0 passed, 0 failed"
  exit 0
fi

pass=0; fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (got $2 want $3)"; }

# static checks on the installer itself
bash -n "$DIST/install.sh" && ok "install.sh parses (bash -n)" || no "install.sh syntax error"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$DIST/install.sh" && ok "install.sh shellcheck clean" || no "install.sh shellcheck"
else
  ok "install.sh shellcheck skipped (not installed)"
fi

# T2/T3 are created later for the .gitattributes scenarios; the trap must cover
# them too, or an interrupt between their mktemp and their explicit rm leaks them.
T="$(mktemp -d)"; T2=""; T3=""
trap 'cd /; rm -rf "$T" ${T2:+"$T2"} ${T3:+"$T3"}' EXIT
cd "$T"; git init -q; git config core.autocrlf false; git config user.email i@i; git config user.name i
printf '# my project\n' > README-mine.md   # pre-existing file must survive

bash "$DIST/install.sh" "$T" >/dev/null 2>&1; chk "install: exits 0 into fresh repo" "$?" 0
for f in .claude/hooks/stop-require-gates.sh .claude/hooks/posttooluse-telemetry.sh \
         .claude/settings.json .claude/agents/coder.md \
         migration/tools/gates.sh migration/tools/doctor.sh migration/tools/persist-state.sh \
         migration/tools/read-state.sh migration/tools/benchmark.sh migration/harness.env \
         migration/LOOP-PROMPT.md migration/SINGLE-TICK-PROMPT.md \
         migration/tools/_git-bash.ps1 migration/tools/gates.ps1 \
         migration/tools/doctor.ps1 migration/tools/kick-loop.ps1 migration/run-loop.ps1 \
         CLAUDE.md AGENTS.md probes/README.md test/run-all.sh test/run-all.ps1 \
         test/powershell-selftest.ps1; do
  [ -e "$T/$f" ] && ok "install: landed $f" || no "install: missing $f"
done
[ -f "$T/README-mine.md" ] && ok "install: preserves pre-existing files" || no "install: clobbered pre-existing file"
grep -qxF '.harness/' "$T/.gitignore" && ok "install: gitignored .harness/" || no "install: .gitignore missing .harness/"
( cd "$T" && bash migration/tools/doctor.sh >/dev/null 2>&1 ); chk "install: doctor runs in target" "$?" 0

# clobber protection: MODIFY an installed file first, so the refusal and the
# --force overwrite are both proven on real content (not a no-op re-copy)
printf 'MY LOCAL EDITS\n' > "$T/CLAUDE.md"
out="$(bash "$DIST/install.sh" "$T" 2>&1)"; chk "install: refuses to clobber without --force" "$?" 1
case "$out" in *"does not merge"*) ok "install: refusal warns overwrite does not merge";; *) no "install: refusal warns overwrite does not merge" "$out" "does not merge";; esac
case "$out" in *CLAUDE.md*) ok "install: refusal names the clashing file";; *) no "install: refusal names the clashing file" "$out" "CLAUDE.md";; esac
grep -qF 'MY LOCAL EDITS' "$T/CLAUDE.md" && ok "install: refusal left local file untouched" || no "install: refusal left local file untouched" "overwritten" "kept"
bash "$DIST/install.sh" --force "$T" >/dev/null 2>&1; chk "install: --force overwrites"                 "$?" 0
grep -qF 'MY LOCAL EDITS' "$T/CLAUDE.md" && no "install: --force restored template CLAUDE.md" "local content kept" "template" || ok "install: --force restored template CLAUDE.md"
n=$(grep -cxF '.harness/' "$T/.gitignore"); chk "install: .harness/ not duplicated on re-run" "$n" 1

# .gitattributes append must not corrupt a pre-existing file with no final newline
T2="$(mktemp -d)"; git -C "$T2" init -q
printf '*.log binary' > "$T2/.gitattributes"        # deliberately NO trailing newline
bash "$DIST/install.sh" "$T2" >/dev/null 2>&1
a="$(cd "$T2" && git add -A -f >/dev/null 2>&1; git check-attr eol -- migration/tools/gates.sh 2>/dev/null)"
case "$a" in *"eol: lf"*) ok "install: eol=lf applies even when target .gitattributes lacked a final newline";; *) no "install: eol=lf applies with no-final-newline .gitattributes" "$a" "eol: lf";; esac
pa="$(cd "$T2" && git check-attr eol -- migration/tools/gates.ps1 2>/dev/null)"
case "$pa" in *"eol: lf"*) ok "install: eol=lf applies to PowerShell entry points";; *) no "install: PowerShell eol=lf rule" "$pa" "eol: lf";; esac
grep -q '^\*\.log binary$' "$T2/.gitattributes" && ok "install: pre-existing no-newline rule preserved intact" || no "install: pre-existing rule preserved" "merged" "intact"
rm -rf "$T2"

# idempotency must be whitespace-tolerant: an aligned pre-existing rule must not
# be re-appended as a duplicate
T3="$(mktemp -d)"; git -C "$T3" init -q
printf '*.sh        text eol=lf\n' > "$T3/.gitattributes"   # aligned (multiple spaces)
bash "$DIST/install.sh" "$T3" >/dev/null 2>&1
c=$(grep -c '\*\.sh' "$T3/.gitattributes"); chk "install: aligned *.sh rule not duplicated (whitespace-tolerant)" "$c" 1
rm -rf "$T3"

echo "----------------------------------------"
echo "install test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
