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

T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
cd "$T"; git init -q; git config core.autocrlf false; git config user.email i@i; git config user.name i
printf '# my project\n' > README-mine.md   # pre-existing file must survive

bash "$DIST/install.sh" "$T" >/dev/null 2>&1; chk "install: exits 0 into fresh repo" "$?" 0
for f in .claude/hooks/stop-require-gates.sh .claude/hooks/posttooluse-telemetry.sh \
         .claude/settings.json .claude/agents/coder.md \
         migration/tools/gates.sh migration/tools/doctor.sh migration/tools/persist-state.sh \
         migration/tools/read-state.sh migration/tools/benchmark.sh migration/harness.env \
         migration/LOOP-PROMPT.md migration/SINGLE-TICK-PROMPT.md \
         CLAUDE.md AGENTS.md probes/README.md test/run-all.sh; do
  [ -e "$T/$f" ] && ok "install: landed $f" || no "install: missing $f"
done
[ -f "$T/README-mine.md" ] && ok "install: preserves pre-existing files" || no "install: clobbered pre-existing file"
grep -qxF '.harness/' "$T/.gitignore" && ok "install: gitignored .harness/" || no "install: .gitignore missing .harness/"
( cd "$T" && bash migration/tools/doctor.sh >/dev/null 2>&1 ); chk "install: doctor runs in target" "$?" 0

# clobber protection
bash "$DIST/install.sh" "$T"         >/dev/null 2>&1; chk "install: refuses to clobber without --force" "$?" 1
bash "$DIST/install.sh" --force "$T" >/dev/null 2>&1; chk "install: --force overwrites"                 "$?" 0
n=$(grep -cxF '.harness/' "$T/.gitignore"); chk "install: .harness/ not duplicated on re-run" "$n" 1

# .gitattributes append must not corrupt a pre-existing file with no final newline
T2="$(mktemp -d)"; git -C "$T2" init -q
printf '*.log binary' > "$T2/.gitattributes"        # deliberately NO trailing newline
bash "$DIST/install.sh" "$T2" >/dev/null 2>&1
a="$(cd "$T2" && git add -A -f >/dev/null 2>&1; git check-attr eol -- migration/tools/gates.sh 2>/dev/null)"
case "$a" in *"eol: lf"*) ok "install: eol=lf applies even when target .gitattributes lacked a final newline";; *) no "install: eol=lf applies with no-final-newline .gitattributes" "$a" "eol: lf";; esac
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
