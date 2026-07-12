#!/usr/bin/env bash
# PreToolUse guard for Bash commands. Blocks the small set of commands that
# undermine the migration harness. Exit 2 = block (stderr goes to the agent).
# Deliberately narrow: false positives stall unattended loops.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | tr '\n\r' '  ' \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\(\\.\|[^"\\]\)*\)".*/\1/p')
[ -z "$cmd" ] && exit 0

block() { printf '%s\n' "$1" >&2; exit 2; }

# --- Universal guards -----------------------------------------------------
case "$cmd" in
  *--no-verify*)
    block "Blocked: --no-verify skips hooks. Fix the failing check instead of bypassing it." ;;
  *record-gates.sh*)
    block "Blocked: record-gates.sh writes the gate proof and must only be called by gates.sh after the gates actually pass. Run: bash migration/tools/gates.sh" ;;
esac

# Block WRITES to the proof file. Detection is intentionally CONSERVATIVE: any
# write operator anywhere in a command that also names the proof file is blocked,
# including one inside quotes — this is what catches a nested write such as
# `bash -c "echo x > <proof>"`. The cost is that a read whose argument contains a
# literal '>' (e.g. `grep '>' <proof>`) is also blocked; that over-block is an
# acceptable trade against letting a real write slip through. Plain reads
# (`cat <proof>`, `grep foo <proof>`) contain no write operator and pass.
if printf '%s' "$cmd" | grep -q 'gates-passed\.diffsha' \
   && printf '%s' "$cmd" | grep -Eq '(>|\btee\b|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\bln\b|\btruncate\b|\bsed\b[[:space:]]+(-i|--in-place))'; then
  block "Blocked: writing the gate proof file directly. It is written only by gates.sh on a real pass. Run: bash migration/tools/gates.sh"
fi

# --- Locked enforcement files (HARNESS_LOCKED) ----------------------------
# Block Bash WRITES to the harness's own gates/hooks/config so the agent cannot
# neuter its own enforcement (e.g. `sed -i` gates.sh into a no-op, then record a
# valid proof; or truncate the Stop hook). The Edit/Write path is covered by
# pretooluse-frozen-legacy.sh.
#
# Unlike the proof block above (which is never executed, so a conservative
# co-occurrence match is fine), locked TOOLING is legitimately run and read:
# `bash migration/tools/gates.sh`, `cat`/`grep` must stay allowed. So detection
# is TARGET-AWARE — a locked path is blocked only when it is a redirection target
# or an argument to a mutating verb, not merely present. `[^|;&<>]` keeps each
# match inside one command segment so an unrelated later command isn't implicated.
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$root" ] && [ -f "$root/migration/harness.env" ]; then
  # shellcheck source=/dev/null
  . "$root/migration/harness.env"
  for frag in ${HARNESS_LOCKED:-}; do
    esc=$(printf '%s' "$frag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    if printf '%s' "$cmd" | grep -Eq \
      "(>>?[[:space:]]*[^|;&<>]*${esc})|(\b(tee|cp|mv|dd|install|ln|truncate)\b[^|;&]*${esc})|(\bsed\b[^|;&]*(-i|--in-place)[^|;&]*${esc})"; then
      block "Blocked: writing locked harness enforcement file matching '$frag' (HARNESS_LOCKED). The agent must not weaken its own gates/hooks/config. A human edits these outside the agent session. Executing/reading them (e.g. bash migration/tools/gates.sh, cat) is allowed."
    fi
  done
fi

# --- Blanket staging guard (universal) -------------------------------------
# `git add -A` / `git add .` in an autonomous session sweeps unrelated
# worktree edits into the slice commit (a real migration lost an evening to
# ~50 swept files, several encoding-corrupted). Slices stage EXPLICIT paths.
# Delete this block only if your project genuinely relies on bulk staging.
#
# Matching lessons, learned in both directions on a live migration:
#  - Do NOT match the raw command naively: commit-message text such as
#    `git commit -m "add -A docs"` is not staging, and a substring match
#    blocks the agent's own commit messages.
#  - Do NOT fix that by stripping ALL quoted regions: substitution-produced
#    quotes (`git commit $(printf X) -a $(printf X)` where X emits a quote
#    character) then hide a REAL -a between them - a confirmed bypass.
#    Mask ONLY the -m/--message/-F argument; leave every other quote visible.
cmd_noq=$(printf '%s' "$cmd" \
  | sed "s/\\(-m\\|--message=\\{0,1\\}\\|-F\\)[[:space:]]*'[^']*'//g" \
  | sed 's/\(-m\|--message=\{0,1\}\|-F\)[[:space:]]*\\\{0,1\}"\(\\.\|[^"\\]\)*\\\{0,1\}"//g')

if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^;&|]*\badd\b[^;&|]*([[:space:]]-A\b|[[:space:]]-u\b|[[:space:]]--all\b|[[:space:]]--update\b|[[:space:]]--no-ignore-removal\b|[[:space:]]\.([[:space:]]|$)|[[:space:]]:/)'; then
  block "Blocked: blanket staging (git add -A/-u/./--all). It sweeps unrelated edits into the commit. Stage the explicit files of THIS slice by path."
fi

if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^;&|]*\bcommit\b[^;&|]*([[:space:]]-a\b|[[:space:]]-am\b|[[:space:]]--all\b)'; then
  block "Blocked: git commit -a stages all tracked edits. git add the explicit slice files, then commit. Tip: a message that must MENTION staging flags goes in a file (git commit -F <file>)."
fi

# --- Project-specific guards (edit for your stack) ------------------------
# Block selective test exclusion so gates always run the full suite. Adapt the
# pattern to your test runner. Examples (uncomment/adapt as needed):
#
# if printf '%s' "$cmd" | grep -Eq '(jest|vitest|pytest|go test)[^;&|]*(-k|--grep|-run|--testNamePattern)'; then
#   block "Blocked: selective test filtering. Gates require the full suite: bash migration/tools/gates.sh."
# fi
#
# Block ungated dependency additions so new deps get recorded in decisions.md
# (as an ADR) before landing:
#
# if printf '%s' "$cmd" | grep -Eq '(npm|pnpm|yarn|pip|cargo|go get|flutter|dart)[^;&|]*[[:space:]](add|install)[[:space:]]'; then
#   block "Blocked: dependency add. Record it in migration/decisions.md (ADR) first, then edit the manifest directly."
# fi

exit 0
