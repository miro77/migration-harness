#!/usr/bin/env bash
# Doc-gate: every internal Markdown reference must resolve. For each relative
# link [text](target) (skipping http/https/mailto and <placeholder> targets),
# the target file must exist (resolved relative to the linking file) and any
# #anchor must match a heading slug in that file. Catches broken cross-references
# and stale anchors — the drift that makes docs quietly lie.
#
#   check-docs.sh                 # scan every tracked/untracked .md in the repo
#   check-docs.sh PATH [PATH...]  # scan only .md under the given files/dirs
#
# gates.sh calls the scoped form (harness docs only) so a slice isn't blocked by
# broken links in the user's unrelated docs. run-all calls the repo-wide form.
# Read-only; needs bash + git + grep + sed + awk. NOTE: no `set -o pipefail` on
# purpose — grep -q closes pipes early (SIGPIPE), which pipefail would misread.
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "doc-gate: not a git repository"; exit 1; }

fails=0
note(){ printf 'BROKEN: %s\n' "$1"; fails=$((fails+1)); }

# GitHub-ish heading slug: lowercase, drop punctuation except space/underscore/
# hyphen, trim, spaces -> hyphens.
slug(){ printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/`//g; s/[^a-z0-9 _-]//g; s/^ +//; s/ +$//; s/ +/-/g'; }

anchors_of(){ grep -E '^#{1,6}[[:space:]]' "$1" 2>/dev/null | sed -E 's/^#+[[:space:]]+//' | while IFS= read -r h; do slug "$h"; done; }

# Lexically resolve . and .. in a path (no filesystem access).
norm(){ printf '%s' "$1" | awk -F/ '{n=0;for(i=1;i<=NF;i++){s=$i;
  if(s=="."||s==""){continue} else if(s==".."){ if(n>0&&a[n]!=".."){n--}else{a[++n]=s} } else {a[++n]=s} }
  o="";for(i=1;i<=n;i++)o=o (i>1?"/":"") a[i]; print o}'; }

# Regex-escape a literal string for a grep -E pattern.
esc(){ printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'; }

# Emit the content of every inline-code span in a Markdown file, skipping fenced
# ``` code blocks (paths shown in a fenced example are illustrative, not refs).
spans_of(){ awk '
  /^[[:space:]]*```/ { fence = 1 - fence; next }
  fence { next }
  { s=$0; while (match(s, /`[^`]+`/)) { print substr(s, RSTART+1, RLENGTH-2); s=substr(s, RSTART+RLENGTH) } }
' "$1" 2>/dev/null; }

# NB: while-read instead of mapfile — gates.sh runs this on whatever bash is
# on PATH, and stock macOS still ships bash 3.2 (no mapfile). A mapfile here
# fails the gate with a misleading "broken reference" diagnosis.
MD=()
if [ "$#" -gt 0 ]; then
  while IFS= read -r m; do MD+=("$m"); done \
    < <(git ls-files -co --exclude-standard -- "$@" | grep -E '\.md$' | sort -u)
else
  while IFS= read -r m; do MD+=("$m"); done \
    < <(git ls-files -co --exclude-standard -- '*.md' | sort -u)
fi

# Known repo paths (tracked + untracked-not-ignored, same scope as the MD list):
# an inline-code path is validated as a path-segment suffix of one of these, so
# `migration/tools/gates.sh` resolves whether the repo IS the harness root or
# stores the template under template/ — and whether or not it's committed yet
# (the e2e installs before committing). Ignored runtime state (.harness/) is out.
TRACKED=()
while IFS= read -r t; do TRACKED+=("$t"); done < <(git ls-files -co --exclude-standard)

for f in "${MD[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  dir=$(dirname "$f")
  while IFS= read -r tgt; do
    [ -z "$tgt" ] && continue
    case "$tgt" in
      http://*|https://*|mailto:*) continue ;;
      *'<'*|*'>'*) continue ;;                # skip <placeholder> targets
    esac
    path=${tgt%%#*}; anchor=""; case "$tgt" in *#*) anchor=${tgt#*#} ;; esac
    if [ -z "$path" ]; then
      tf="$f"                                 # pure #anchor -> same file
    else
      if [ "$dir" = "." ]; then rel="$path"; else rel="$dir/$path"; fi
      tf="$(norm "$rel")"
      if [ ! -e "$tf" ]; then note "$f -> $tgt  (missing file: $tf)"; continue; fi
    fi
    if [ -n "$anchor" ] && [ -f "$tf" ]; then
      # capture first: `anchors_of | grep -q` lets grep exit on the first
      # match and SIGPIPE the generator mid-write (noisy on some platforms)
      _anchors="$(anchors_of "$tf")"
      if ! printf '%s\n' "$_anchors" | grep -qxF "$anchor"; then note "$f -> $tgt  (no heading '#$anchor' in $tf)"; fi
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//; s/[[:space:]].*$//')
done

# Inline-code path references: a `backtick path` that names a harness file/dir
# must resolve to a real path. Catches a rename that the [](link) check above
# misses because the reference is written as inline code, not a link.
#
# REPO-WIDE MODE ONLY (no path args). This is a maintainer/CI lint on the
# harness's OWN documentation, which needs the full tree present. The scoped
# call gates.sh makes (`check-docs.sh CLAUDE.md AGENTS.md migration`) runs in
# consumer/test repos that ship only a subset of the harness, so a per-slice
# gate must NOT apply it — it would flag installed docs that legitimately point
# at unshipped paths. The link/anchor checks above stay active in both modes.
if [ "$#" -eq 0 ]; then
for f in "${MD[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      *[[:space:]]*|*'<'*|*'>'*|*'*'*|*'?'*|*'['*|*']'*|*'://'*|*'$'*|*:*|-*) continue ;;
    esac
    case "$tok" in */*) : ;; *) continue ;; esac          # must look like a path
    # Scoped to the harness's own top-level dirs so illustrative user/example
    # paths (e.g. `legacy/src`) are never flagged. `docs/` is intentionally
    # absent: it lives at the harness-repo root, is never installed, and shipped
    # docs point at it deliberately. `.harness/` runtime state is excluded too.
    case "$tok" in
      migration/*|.claude/*|probes/*|test/*|template/*) : ;;
      *) continue ;;
    esac
    tok=${tok%/}                                           # tolerate a trailing slash
    # Scaffolding dirs populated during a migration (not shipped): a deep path
    # under them can't be validated at template time. The dirs themselves ship a
    # .gitkeep, so a rename of the dir is still caught; only their contents are exempt.
    case "$tok" in
      migration/HANDOFF.md) continue ;;                    # written at termination
      migration/frozen-baseline.sha) continue ;;           # recorded once at bootstrap
      migration/reference/*|migration/fixtures/*) continue ;;  # runtime-populated
    esac
    if ! printf '%s\n' "${TRACKED[@]}" | grep -qE "(^|/)$(esc "$tok")($|/)"; then
      note "$f -> \`$tok\`  (inline-code path names no tracked file/dir — renamed or stale?)"
    fi
  done < <(spans_of "$f")
done
fi

echo "----------------------------------------"
if [ "$fails" -eq 0 ]; then echo "doc-gate: all internal Markdown references resolve"; else echo "doc-gate: $fails broken reference(s)"; fi
[ "$fails" -eq 0 ]
