#!/usr/bin/env bash
# Doc-gate: every internal Markdown reference must resolve. For each relative
# link [text](target) (skipping http/https/mailto and <placeholder> targets),
# the target file must exist (resolved relative to the linking file) and any
# #anchor must match a heading slug in that file. Inline-code `path` references
# are checked repo-wide, and inline `path:N` / `path:N-M` LINE references are
# checked in both modes against the cited file's actual length (N>=1, N<=M,
# M<=lines) whenever the file resolves. Catches broken cross-references, stale
# anchors, and hallucinated/stale file:line ranges — the drift that makes docs
# quietly lie.
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

# GitHub-ish heading slug: trim the raw text, lowercase, drop punctuation
# except space/underscore/hyphen, then EACH space becomes its own hyphen —
# GitHub's slugger does not collapse runs, so "A — B" slugs to a--b, not a-b
# (the em-dash is dropped and both surrounding spaces survive as hyphens).
# [:alnum:] instead of a-z0-9 keeps non-ASCII letters (GitHub preserves them)
# in any multibyte locale; awk tolower() lowercases them too where the awk is
# locale-aware (gawk) and degrades to ASCII-only lowering elsewhere — a
# best-effort that never REJECTS more than the old ASCII slugger did.
slug(){ printf '%s\n' "$1" | awk '{ print tolower($0) }' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/`//g; s/[^[:alnum:] _-]//g; s/ /-/g'; }

# Drop fenced code blocks. Shared by the link, anchor, and inline-span scans:
# content inside a fence is illustrative (an example link is not a reference,
# a "# comment" in a shell example is not a heading). CommonMark rules, not a
# naive ``` toggle: a fence opens with 3+ backticks OR tildes, and closes only
# on a run of the SAME character AT LEAST as long with nothing else on the
# line — so a ~~~ block hides its contents, and a ````-outer fence showing a
# ```-inner example does not flip state mid-block (both were false fails).
strip_fences(){ awk '
  {
    l = $0; sub(/^[[:space:]]+/, "", l)
    if (!infence) {
      if (match(l, /^```*/) && RLENGTH >= 3) { fc = "`"; flen = RLENGTH; infence = 1; next }
      if (match(l, /^~~~*/) && RLENGTH >= 3) { fc = "~"; flen = RLENGTH; infence = 1; next }
      print; next
    }
    if (fc == "`" && l ~ /^``*[[:space:]]*$/ && match(l, /^``*/) && RLENGTH >= flen) { infence = 0; next }
    if (fc == "~" && l ~ /^~~*[[:space:]]*$/ && match(l, /^~~*/) && RLENGTH >= flen) { infence = 0; next }
    next
  }' "$1" 2>/dev/null; }

# Duplicate headings get GitHub'\''s -1/-2/... suffixes (the first occurrence
# keeps the bare slug), so a link to the second "## Setup" as #setup-1 resolves.
anchors_of(){ strip_fences "$1" | grep -E '^#{1,6}[[:space:]]' | sed -E 's/^#+[[:space:]]+//' \
  | while IFS= read -r h; do slug "$h"; done \
  | awk '{ n = seen[$0]++; print (n ? $0 "-" n : $0) }'; }

# Lexically resolve . and .. in a path (no filesystem access).
norm(){ printf '%s' "$1" | awk -F/ '{n=0;for(i=1;i<=NF;i++){s=$i;
  if(s=="."||s==""){continue} else if(s==".."){ if(n>0&&a[n]!=".."){n--}else{a[++n]=s} } else {a[++n]=s} }
  o="";for(i=1;i<=n;i++)o=o (i>1?"/":"") a[i]; print o}'; }

# Regex-escape a literal string for a grep -E pattern.
esc(){ printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'; }

# Emit the content of every inline-code span in a Markdown file (fenced ```
# blocks already dropped by strip_fences, same as the link/anchor scans).
spans_of(){ strip_fences "$1" | awk '
  { s=$0; while (match(s, /`[^`]+`/)) { print substr(s, RSTART+1, RLENGTH-2); s=substr(s, RSTART+RLENGTH) } }
'; }

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
  done < <(strip_fences "$f" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//; s/[[:space:]].*$//')
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
      migration/locked-baseline.sha) continue ;;           # recorded once at bootstrap
      migration/reference/*|migration/fixtures/*) continue ;;  # runtime-populated
    esac
    if ! printf '%s\n' "${TRACKED[@]}" | grep -qE "(^|/)$(esc "$tok")($|/)"; then
      note "$f -> \`$tok\`  (inline-code path names no tracked file/dir — renamed or stale?)"
    fi
  done < <(spans_of "$f")
done
fi

# Inline-code LINE references: a `path:N` or `path:N-M` span must point at lines
# that actually EXIST. The path-existence scan above skips anything with a colon,
# so a stale/hallucinated range (`engine/lcg.cpp:120-145` naming a real file but a
# range past its end) sails through today — the file:line drift that Claude Code
# references invite.
#
# REPO-WIDE MODE ONLY, like the inline-code path scan above and for the same
# reasons: (1) the scoped per-slice `gates.sh` call runs on LOCKED docs
# (CLAUDE.md, the tick prompts) — a stale line-ref there, on a file that
# legitimately shrank during migration, would brick every future gate on a
# reference only a human can edit; range-checking there is a footgun. (2) a
# consumer repo ships only a subset of the harness, so a doc-relative citation
# may not resolve. This is a maintainer/CI lint; the link/anchor checks above
# still run in both modes.
if [ "$#" -eq 0 ]; then
for f in "${MD[@]:-}"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  dir=$(dirname "$f")
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in *'://'*) continue ;; esac        # a URL:port is not a code ref
    # Shape: PATH:START or PATH:START-END, PATH containing a '/' (like the path
    # scan, a bare word:N such as a `12:30` timestamp is not a code reference).
    printf '%s' "$tok" | grep -qE '^.+/[^:[:space:]]*:[0-9]+(-[0-9]+)?$' || continue
    pathpart=${tok%:*}; spec=${tok##*:}
    start=${spec%%-*}; end=""; case "$spec" in *-*) end=${spec#*-} ;; esac
    # An absolute path or one with a '..' segment resolves OUTSIDE this repo — its
    # line count would then depend on whatever sits at that path on the machine
    # running the gate (green locally, red on CI, or flagged against an unrelated
    # system file the agent cannot touch). Only resolve in-repo citations.
    case "$pathpart" in /*|../*|*/../*|*/..) continue ;; esac
    # Resolve pathpart to a single IN-REPO file: relative to the doc, then a
    # UNIQUE path-segment suffix among tracked files. No raw `[ -f "$pathpart" ]`
    # branch — that resolved absolute/out-of-tree paths against the live FS.
    # Unresolved/ambiguous -> skip (path existence is the scan above's job).
    if [ "$dir" = "." ]; then cand="$pathpart"; else cand="$dir/$pathpart"; fi
    cand="$(norm "$cand")"
    tf=""
    if [ -f "$cand" ]; then tf="$cand"
    else
      matches="$(printf '%s\n' "${TRACKED[@]}" | grep -E "(^|/)$(esc "$pathpart")\$")"
      [ "$(printf '%s\n' "$matches" | grep -c .)" = "1" ] && tf="$matches"
    fi
    [ -n "$tf" ] && [ -f "$tf" ] || continue
    case "$tf" in /*|../*|*/../*) continue ;; esac   # never step outside the repo
    # Numbers past ~18 digits overflow bash's 64-bit arithmetic and make the
    # comparisons below abort with "integer expression expected" (a stderr leak
    # AND a silent false-negative). A line number that long is never valid.
    if [ "${#start}" -gt 18 ] || { [ -n "$end" ] && [ "${#end}" -gt 18 ]; }; then
      note "$f -> \`$tok\`  (line number is implausibly large — stale or malformed reference)"
      continue
    fi
    # awk NR, not `wc -l`: wc undercounts a file with no trailing newline by one.
    lc="$(awk 'END{print NR}' "$tf" 2>/dev/null)"; [ -n "$lc" ] || lc=0
    if [ "$start" -lt 1 ]; then
      note "$f -> \`$tok\`  (line $start is invalid; lines start at 1)"
    elif [ -n "$end" ] && [ "$start" -gt "$end" ]; then
      note "$f -> \`$tok\`  (start line $start is after end line $end)"
    elif [ -n "$end" ] && [ "$end" -gt "$lc" ]; then
      note "$f -> \`$tok\`  (line $end exceeds $tf's $lc line(s))"
    elif [ -z "$end" ] && [ "$start" -gt "$lc" ]; then
      note "$f -> \`$tok\`  (line $start exceeds $tf's $lc line(s))"
    fi
  done < <(spans_of "$f")
done
fi

echo "----------------------------------------"
if [ "$fails" -eq 0 ]; then echo "doc-gate: all internal Markdown references resolve"; else echo "doc-gate: $fails broken reference(s)"; fi
[ "$fails" -eq 0 ]
