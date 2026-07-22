#!/usr/bin/env bash
# Install the migration harness into a target repository.
#
#   bash install.sh [--force] [TARGET_DIR]      (TARGET_DIR default: .)
#
# Copies the template, makes the scripts executable, gitignores the local proof
# state, and prints a setup status report. Refuses to overwrite existing harness
# files unless --force is given, so it is safe to run in a populated repo.
set -euo pipefail

force=0; target=""
for a in "$@"; do
  case "$a" in
    --force)   force=1 ;;
    -h|--help) echo "Usage: bash install.sh [--force] [TARGET_DIR]"; exit 0 ;;
    -*)        echo "install: unknown option: $a" >&2; exit 2 ;;
    *)         target="$a" ;;
  esac
done
target="${target:-.}"

here="$(cd "$(dirname "$0")" && pwd -P)"
src="$here/template"
[ -d "$src/.claude/hooks" ] || { echo "install: template/ not found next to install.sh ($src)" >&2; exit 1; }

mkdir -p "$target"
target="$(cd "$target" && pwd -P)"
[ "$target" != "$src" ] || { echo "install: target must differ from the template dir" >&2; exit 1; }
# A target INSIDE the template dir would make cp copy the template into itself:
# it errors mid-copy and leaves a half-installed junk tree polluting the template.
# Remove ONLY the just-created leaf if it is empty — NOT `rmdir -p`, which walks
# up deleting every empty ancestor and would take out a pre-existing empty dir
# inside template/ that we did not create.
case "$target" in
  "$src"/*)
    echo "install: target must not be inside the template dir ($src)" >&2
    rmdir "$target" 2>/dev/null || true
    exit 1 ;;
esac

echo "Installing harness"
echo "  from: $src"
echo "  into: $target"

# Build the complete output manifest before the first write. Besides making the
# clash check honest, this is the transaction boundary used for rollback.
files=()
while IFS= read -r rel; do files+=("$rel"); done \
  < <(cd "$src" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)

# Refuse to clobber unless --force: collect template files that already exist.
clashes=()
for rel in "${files[@]}"; do
  if [ -e "$target/$rel" ]; then clashes+=("$rel"); fi
done
if [ "${#clashes[@]}" -gt 0 ] && [ "$force" -ne 1 ]; then
  echo "install: these files already exist in the target (re-run with --force to overwrite):" >&2
  printf '  %s\n' "${clashes[@]}" >&2
  case " ${clashes[*]} " in
    *" CLAUDE.md "*|*" .claude/settings.json "*)
      echo "install: NOTE — --force OVERWRITES wholesale, it does not merge. Your existing CLAUDE.md / .claude/settings.json would be replaced by the template; back them up and merge your content back by hand." >&2 ;;
  esac
  exit 1
fi

# Back up every destination this invocation can touch, including the two files
# augmented after the template copy. If any later copy/append fails, restore
# original bytes and modes and remove files/directories created by this run.
tx="$(mktemp -d "${TMPDIR:-/tmp}/harness-install.XXXXXX")"
existing="$tx/existing.list"
new_files="$tx/new-files.list"
new_dirs="$tx/new-dirs.list"
cleanup_install_setup(){
  rc=$?
  trap - EXIT INT TERM
  rm -rf -- "$tx"
  exit "$rc"
}
trap cleanup_install_setup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$tx/backup"
: > "$existing"; : > "$new_files"; : > "$new_dirs"

all_outputs=("${files[@]}" .gitignore .gitattributes)
for rel in "${all_outputs[@]}"; do
  dest="$target/$rel"
  probe="$target"
  remainder="$rel"
  while :; do
    component="${remainder%%/*}"
    probe="$probe/$component"
    if [ -L "$probe" ]; then
      echo "install: output path traverses a symlink, refusing: $rel" >&2
      exit 1
    fi
    [ "$remainder" != "$component" ] || break
    remainder="${remainder#*/}"
  done
  if [ -d "$dest" ]; then
    echo "install: output path is a directory, expected a file: $rel" >&2
    exit 1
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    echo "install: output path is not a regular file, refusing: $rel" >&2
    exit 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    mkdir -p "$tx/backup/$(dirname "$rel")"
    cp -pP "$dest" "$tx/backup/$rel"
    printf '%s\n' "$rel" >> "$existing"
  else
    printf '%s\n' "$rel" >> "$new_files"
  fi

  case "$rel" in */*) parent="${rel%/*}" ;; *) parent="." ;; esac
  while [ "$parent" != "." ]; do
    if [ ! -d "$target/$parent" ] && ! grep -qxF "$parent" "$new_dirs"; then
      printf '%s\n' "$parent" >> "$new_dirs"
    fi
    case "$parent" in */*) parent="${parent%/*}" ;; *) parent="." ;; esac
  done
done

transaction_active=1
rollback_install(){
  set +e
  rollback_failures=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$target/$rel" ] || [ -L "$target/$rel" ]; then
      rm -f -- "$target/$rel" || rollback_failures+=("remove $rel")
    fi
  done < "$new_files"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! mkdir -p "$target/$(dirname "$rel")"; then
      rollback_failures+=("create parent for $rel")
      continue
    fi
    cp -pP "$tx/backup/$rel" "$target/$rel" || rollback_failures+=("restore $rel")
  done < "$existing"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$target/$rel" ] || [ -L "$target/$rel" ]; then
      rmdir "$target/$rel" 2>/dev/null || rollback_failures+=("remove directory $rel")
    fi
  done < <(awk -F/ 'NF { print NF "\t" $0 }' "$new_dirs" | sort -rn | cut -f2-)
  if [ "${#rollback_failures[@]}" -eq 0 ]; then
    echo "install: failed; restored the target to its pre-install state" >&2
    rollback_incomplete=0
  else
    echo "install: failed; ROLLBACK INCOMPLETE:" >&2
    printf '  %s\n' "${rollback_failures[@]}" >&2
    rollback_incomplete=1
  fi
}
finish_install(){
  rc=$?
  trap - EXIT
  trap '' INT TERM
  rollback_incomplete=0
  if [ "${transaction_active:-0}" -eq 1 ]; then rollback_install; fi
  if [ "$rollback_incomplete" -eq 0 ]; then
    rm -rf -- "$tx"
  else
    echo "install: recovery backup retained at: $tx" >&2
  fi
  trap - INT TERM
  exit "$rc"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Test-only fault injection used to prove rollback after a partial write. It is
# deliberately an environment variable rather than a user-facing option.
write_count=0
fail_after="${HARNESS_INSTALL_FAIL_AFTER:-0}"
case "$fail_after" in ''|*[!0-9]*) fail_after=0 ;; esac
install_write_complete(){
  write_count=$((write_count + 1))
  if [ "$fail_after" -gt 0 ] && [ "$write_count" -eq "$fail_after" ]; then
    echo "install: injected failure after write $write_count" >&2
    return 97
  fi
}

# Copy manifest entries individually so each write participates in rollback.
for rel in "${files[@]}"; do
  mkdir -p "$target/$(dirname "$rel")"
  cp -p "$src/$rel" "$target/$rel"
  install_write_complete
done

# Make the scripts executable (no-op-ish on Windows; harmless).
chmod +x "$target"/migration/tools/*.sh "$target"/.claude/hooks/*.sh "$target"/test/*.sh 2>/dev/null || true

# Gitignore the local proof state (idempotent). Same no-final-newline guard as
# .gitattributes below: appending to a file whose last line has no newline would
# merge '.harness/' onto the user's last rule (e.g. '*.log' -> '*.log.harness/'),
# silently voiding BOTH — the user's rule stops matching and the proof state
# becomes committable.
gi="$target/.gitignore"
if [ ! -f "$gi" ] || ! grep -qxF '.harness/' "$gi"; then
  if [ -f "$gi" ] && [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then printf '\n' >> "$gi"; fi
  printf '.harness/\n' >> "$gi"
  install_write_complete
  echo "  + added '.harness/' to .gitignore"
fi

# Pin the harness scripts to LF in the target (idempotent). On Windows
# checkouts with core.autocrlf=true, CRLF in a hook/tool breaks bash — and a
# CRLF-mangled hash tool makes the Stop hook fail closed.
ga="$target/.gitattributes"
# Ensure the file ends in a newline before appending, or the first rule merges
# onto a pre-existing last line (e.g. `*.log binary`) and silently voids BOTH.
if [ -f "$ga" ] && [ -s "$ga" ] && [ -n "$(tail -c1 "$ga")" ]; then printf '\n' >> "$ga"; fi
for rule in '*.sh text eol=lf' '*.ps1 text eol=lf' 'harness.env text eol=lf'; do
  # Whitespace-tolerant idempotency: squeeze spaces/tabs (keeping newlines) so an
  # already-present but differently-aligned rule isn't re-appended as a duplicate.
  if [ ! -f "$ga" ] || ! tr -s ' \t' ' ' < "$ga" | grep -qxF "$rule"; then
    printf '%s\n' "$rule" >> "$ga"
    install_write_complete
    echo "  + added '$rule' to .gitattributes"
  fi
done

# The target is complete. From this point diagnostics may fail or be absent,
# but the installer no longer owns a live transaction.
transaction_active=0
trap - EXIT INT TERM
rm -rf -- "$tx"

echo
echo "== status =="
( cd "$target" && bash migration/tools/doctor.sh ) || true

cat <<'EOF'

Next steps (see GETTING-STARTED.md):
  1. Edit migration/harness.env     — set HARNESS_SCOPE and HARNESS_FROZEN
  2. Configure migration/tools/gates.sh for your stack (it ships failing)
  3. Fill the <...> placeholders in CLAUDE.md / migration/*.md
  4. Verify:  bash test/run-all.sh
EOF
