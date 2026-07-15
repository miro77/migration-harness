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
# (rmdir -p undoes only the empty dirs the mkdir above just made; it cannot touch
# anything non-empty.)
case "$target" in
  "$src"/*)
    echo "install: target must not be inside the template dir ($src)" >&2
    rmdir -p "$target" 2>/dev/null || true
    exit 1 ;;
esac

echo "Installing harness"
echo "  from: $src"
echo "  into: $target"

# Refuse to clobber unless --force: collect template files that already exist.
clashes=()
while IFS= read -r rel; do
  if [ -e "$target/$rel" ]; then clashes+=("$rel"); fi
done < <(cd "$src" && find . -type f | sed 's#^\./##')
if [ "${#clashes[@]}" -gt 0 ] && [ "$force" -ne 1 ]; then
  echo "install: these files already exist in the target (re-run with --force to overwrite):" >&2
  printf '  %s\n' "${clashes[@]}" >&2
  case " ${clashes[*]} " in
    *" CLAUDE.md "*|*" .claude/settings.json "*)
      echo "install: NOTE — --force OVERWRITES wholesale, it does not merge. Your existing CLAUDE.md / .claude/settings.json would be replaced by the template; back them up and merge your content back by hand." >&2 ;;
  esac
  exit 1
fi

# Copy template contents (including dotfiles) into the target.
cp -R "$src/." "$target/"

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
    echo "  + added '$rule' to .gitattributes"
  fi
done

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
