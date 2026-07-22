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

# T2-T7 are created later for additional scenarios; the trap must cover
# them too, or an interrupt between their mktemp and their explicit rm leaks them.
T="$(mktemp -d)"; T2=""; T3=""; T4=""; T5=""; T6=""; T7=""
trap 'cd /; rm -rf "$T" ${T2:+"$T2"} ${T3:+"$T3"} ${T4:+"$T4"} ${T5:+"$T5"} ${T6:+"$T6"} ${T7:+"$T7"}' EXIT
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

# A failed forced upgrade must restore every overwritten file, not leave a
# mixed-version harness. Commit the exact pre-run state so git can compare the
# complete file inventory and contents after the injected mid-copy failure.
printf 'LOCAL BEFORE FAILED FORCE\n' > "$T/CLAUDE.md"
git -C "$T" add -A; git -C "$T" commit -qm rollback-baseline
HARNESS_INSTALL_FAIL_AFTER=4 bash "$DIST/install.sh" --force "$T" >/dev/null 2>&1
chk "install: injected forced-upgrade failure exits 97" "$?" 97
status="$(git -C "$T" status --porcelain --untracked-files=all)"
chk "install: failed forced upgrade restores complete target" "$status" ""
grep -qF 'LOCAL BEFORE FAILED FORCE' "$T/CLAUDE.md" \
  && ok "install: rollback restores overwritten CLAUDE.md" \
  || no "install: rollback restores overwritten CLAUDE.md"

# The same transaction must remove files and directories created during a
# failed fresh install, while preserving unrelated pre-existing project files.
T4="$(mktemp -d)"; git -C "$T4" init -q
git -C "$T4" config user.email i@i; git -C "$T4" config user.name i
printf 'keep\n' > "$T4/README-mine.md"
git -C "$T4" add -A; git -C "$T4" commit -qm before-install
HARNESS_INSTALL_FAIL_AFTER=4 bash "$DIST/install.sh" "$T4" >/dev/null 2>&1
chk "install: injected fresh-install failure exits 97" "$?" 97
status="$(git -C "$T4" status --porcelain --untracked-files=all)"
chk "install: failed fresh install removes all partial output" "$status" ""
[ ! -e "$T4/.claude" ] && ok "install: failed fresh install removes created directories" \
  || no "install: failed fresh install removes created directories"
rm -rf "$T4"
T4=""

# Refuse output paths that escape through either a leaf or parent symlink. The
# installer must never overwrite content outside the resolved target root.
T5="$(mktemp -d)"
mkdir -p "$T5/external-parent" "$T5/leaf-target" "$T5/parent-target"
printf 'PRECIOUS EXTERNAL CONTENT\n' > "$T5/external.txt"
if ln -s "$T5/external.txt" "$T5/leaf-target/CLAUDE.md" 2>/dev/null \
    && [ -L "$T5/leaf-target/CLAUDE.md" ]; then
  out="$(bash "$DIST/install.sh" --force "$T5/leaf-target" 2>&1)"
  chk "install: refuses a symlinked output file" "$?" 1
  case "$out" in *"traverses a symlink"*) ok "install: explains symlink refusal";; *) no "install: explains symlink refusal";; esac
  grep -qxF 'PRECIOUS EXTERNAL CONTENT' "$T5/external.txt" \
    && ok "install: symlink refusal preserves external file" \
    || no "install: symlink refusal preserves external file"

  ln -s "$T5/external-parent" "$T5/parent-target/.claude"
  out="$(bash "$DIST/install.sh" "$T5/parent-target" 2>&1)"
  chk "install: refuses a symlinked output parent" "$?" 1
  [ -z "$(find "$T5/external-parent" -mindepth 1 -print -quit)" ] \
    && ok "install: parent-symlink refusal leaves external directory untouched" \
    || no "install: parent-symlink refusal leaves external directory untouched"
else
  echo "SKIP: install symlink refusal tests (symlink creation unavailable)"
fi
rm -rf "$T5"
T5=""

# .gitignore and .gitattributes participate in the transaction even though they
# are not template files. Reject a directory there cleanly and remove the
# preflight transaction directory.
T6="$(mktemp -d)"
mkdir -p "$T6/target/.gitignore" "$T6/tmp"
out="$(TMPDIR="$T6/tmp" bash "$DIST/install.sh" "$T6/target" 2>&1)"
chk "install: refuses a directory at an output path" "$?" 1
case "$out" in *"output path is a directory"*) ok "install: explains output-directory refusal";; *) no "install: explains output-directory refusal";; esac
[ -z "$(find "$T6/tmp" -mindepth 1 -print -quit)" ] \
  && ok "install: cleans transaction after preflight failure" \
  || no "install: cleans transaction after preflight failure"
rm -rf "$T6"
T6=""

# A failed restore must be reported honestly and must retain the backup for
# manual recovery. The cp shim fails only when rollback reads from backup/.
T7="$(mktemp -d)"
mkdir -p "$T7/target" "$T7/tmp" "$T7/bin"
bash "$DIST/install.sh" "$T7/target" >/dev/null 2>&1
real_cp="$(command -v cp)"
cat > "$T7/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -u
source_path=""
for arg in "$@"; do
  case "$arg" in -*) ;; *) source_path="$arg"; break;; esac
done
case "$source_path" in */harness-install.*/backup/*) exit 88;; esac
exec "$REAL_CP" "$@"
EOF
chmod +x "$T7/bin/cp"
out="$(PATH="$T7/bin:$PATH" REAL_CP="$real_cp" TMPDIR="$T7/tmp" \
  HARNESS_INSTALL_FAIL_AFTER=4 bash "$DIST/install.sh" --force "$T7/target" 2>&1)"
chk "install: preserves injected failure exit after incomplete rollback" "$?" 97
case "$out" in *"ROLLBACK INCOMPLETE"*) ok "install: reports incomplete rollback";; *) no "install: reports incomplete rollback";; esac
case "$out" in *"recovery backup retained at"*) ok "install: reports retained recovery backup";; *) no "install: reports retained recovery backup";; esac
find "$T7/tmp" -maxdepth 1 -type d -name 'harness-install.*' -print -quit | grep -q . \
  && ok "install: retains transaction after incomplete rollback" \
  || no "install: retains transaction after incomplete rollback"
rm -rf "$T7"
T7=""

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
