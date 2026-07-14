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
  *check-frozen.sh*--record*|*--record*check-frozen.sh*)
    block "Blocked: --record writes the frozen-oracle baseline, i.e. it declares whatever the legacy tree contains RIGHT NOW to be the reference. An agent that can re-baseline can launder any drift it caused, which voids the oracle. A human records it once during bootstrap. To VERIFY the oracle: bash migration/tools/check-frozen.sh" ;;
esac

if printf '%s' "$cmd" | grep -Eq 'record-g[^[:space:];|&<>]*\.sh'; then
  block "Blocked: record-gates.sh writes the gate proof and must only be called by gates.sh after the gates actually pass. Run: bash migration/tools/gates.sh"
fi

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

# Same for the audit records. An audit record says a fresh-context auditor read
# this exact code and passed it; hand-writing one is forging that. It is written
# only by record-audit.sh, which the AUDITOR calls when it has actually finished.
if printf '%s' "$cmd" | grep -q '\.harness/state/audits' \
   && printf '%s' "$cmd" | grep -Eq '(>|\btee\b|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\bln\b|\btruncate\b|\brm\b|\bsed\b[[:space:]]+(-i|--in-place))'; then
  block "Blocked: writing or deleting an audit record directly. A record asserts that a fresh-context auditor read THIS code and passed it. It is written only by the auditor, via: bash migration/tools/record-audit.sh <row-id> pass|fail"
fi

# --- Protected paths: locked enforcement (HARNESS_LOCKED) + oracle (HARNESS_FROZEN)
# Block Bash MUTATIONS of the harness's own gates/hooks/config so the agent cannot
# neuter its own enforcement (e.g. `sed -i` gates.sh into a no-op, then record a
# valid proof; or truncate the Stop hook), and of the frozen oracle so parity
# cannot be won by editing the reference. Edit/Write on both is covered by
# pretooluse-frozen-legacy.sh; this is the Bash path it cannot see.
#
# HARNESS_FROZEN is guarded HERE TOO, not only in the Edit/Write hook: without it
# `cat > legacy/src/x.cpp` or `rm -rf legacy/src` mutates the oracle through a
# tool the frozen-legacy hook never fires on.
#
# DESTRUCTION is a mutation. Blocking only writers (`>`, tee, sed -i) leaves the
# shortest bypass in the harness wide open: `rm .claude/hooks/stop-require-gates.sh`
# does not write anything — it deletes the Stop hook, and a hook that is not on
# disk does not run. Same for reverting a locked file out from under the proof
# (`git checkout -- `, `git restore`, `git rm`). Deleters and reverters are in the
# verb list for exactly that reason.
#
# Unlike the proof block above (which is never executed, so a conservative
# co-occurrence match is fine), locked TOOLING is legitimately run and read:
# `bash migration/tools/gates.sh`, `cat`/`grep` must stay allowed. So detection
# is TARGET-AWARE — a protected path is blocked only when it is a redirection
# target or an argument to a mutating verb, not merely present. `[^|;&<>]` keeps
# each match inside one command segment so an unrelated later command isn't
# implicated. A read whose ARGUMENTS happen to contain a verb word (`grep -r rm
# migration/tools/`) is over-blocked; that trade is deliberate and matches the
# existing tee/cp/mv posture — a false block stalls one call, a missed mutation
# silently voids every proof that follows.
_mutating_verbs='tee|cp|mv|dd|install|ln|truncate|rm|unlink|shred|chmod|chown'
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$root" ] && [ -f "$root/migration/harness.env" ]; then
  # shellcheck source=/dev/null
  . "$root/migration/harness.env"
  for frag in ${HARNESS_LOCKED:-}; do
    esc=$(printf '%s' "$frag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    if printf '%s' "$cmd" | grep -Eq \
      "(>>?[[:space:]]*[^|;&<>]*${esc})|(\b(${_mutating_verbs})\b[^|;&]*${esc})|(\bsed\b[^|;&]*(-i|--in-place)[^|;&]*${esc})|(\bgit\b[^|;&]*\b(rm|checkout|restore|clean|stash)\b[^|;&]*${esc})"; then
      block "Blocked: mutating locked harness enforcement file matching '$frag' (HARNESS_LOCKED) — this includes DELETING or reverting it, not just writing it. The agent must not weaken its own gates/hooks/config: a Stop hook that is not on disk does not run. A human edits these outside the agent session. Executing/reading them (e.g. bash migration/tools/gates.sh, cat) is allowed."
    fi
  done
  for frag in ${HARNESS_FROZEN:-}; do
    esc=$(printf '%s' "$frag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    if printf '%s' "$cmd" | grep -Eq \
      "(>>?[[:space:]]*[^|;&<>]*${esc})|(\b(${_mutating_verbs})\b[^|;&]*${esc})|(\bsed\b[^|;&]*(-i|--in-place)[^|;&]*${esc})|(\bgit\b[^|;&]*\b(rm|checkout|restore|clean|stash)\b[^|;&]*${esc})"; then
      block "Blocked: mutating the frozen oracle matching '$frag' (HARNESS_FROZEN) via Bash. The legacy tree is the reference behavior is measured against — editing or deleting it wins parity by moving the target. Reading and RUNNING it is allowed (that is the whole point). Probes/adapters go in probes/."
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
#  - The command arrives JSON-ESCAPED (the extraction above keeps escapes):
#    the message delimiter is the 2-char sequence \" while message CONTENT is
#    built from raw-level units — a literal backslash pair (raw \\, encoded
#    \\\\) or a bash-escaped quote (raw \", encoded \\\") or a plain char.
#    The content alternatives below match exactly those units. The previous
#    \\. content alternative also matched the closing \" itself, so with TWO
#    -m messages the mask ran leftmost-longest to the LAST quote and
#    swallowed a real -a sitting between them (confirmed bypass).
cmd_noq=$(printf '%s' "$cmd" \
  | sed "s/\\(-m\\|--message=\\{0,1\\}\\|-F\\)[[:space:]]*'[^']*'//g" \
  | sed 's/\(-m\|--message=\{0,1\}\|-F\)[[:space:]]*\\\{0,1\}"\(\\\\\\\\\|\\\\\\"\|[^"\\]\)*\\\{0,1\}"//g')

if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^;&|]*\badd\b[^;&|]*([[:space:]]-A\b|[[:space:]]-u\b|[[:space:]]--all\b|[[:space:]]--update\b|[[:space:]]--no-ignore-removal\b|[[:space:]]\./?([[:space:]]|$)|[[:space:]]:/)'; then
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
