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

# A dequoted copy for name/flag guards. `check-frozen.sh --rec''ord`,
# `--rec'o'rd`, `record-gate""s.sh` all EXECUTE the real thing — the shell
# concatenates across quotes — but a literal match sees the quotes and misses.
# Stripping every quote collapses each to its effective spelling. Used only for
# detection that does not depend on quoting; the -m/-F message mask further down
# still runs on the quoted $cmd.
cmd_dequoted=$(printf '%s' "$cmd" | tr -d "'\"")

# --- Universal guards -----------------------------------------------------
case "$cmd_dequoted" in
  *--no-verify*)
    block "Blocked: --no-verify skips hooks. Fix the failing check instead of bypassing it." ;;
  *check-frozen.sh*--record*|*--record*check-frozen.sh*)
    block "Blocked: --record writes the frozen-oracle baseline, i.e. it declares whatever the legacy tree contains RIGHT NOW to be the reference. An agent that can re-baseline can launder any drift it caused, which voids the oracle. A human records it once during bootstrap. To VERIFY the oracle: bash migration/tools/check-frozen.sh" ;;
  *check-locked.sh*--record*|*--record*check-locked.sh*)
    block "Blocked: --record writes the LOCKED-tooling baseline (migration/locked-baseline.sha), i.e. it blesses whatever the harness's own gates/hooks/config contain RIGHT NOW as the reference. An agent that can re-baseline can neuter a gate and then re-bless it. A human records it once during bootstrap. To VERIFY: bash migration/tools/check-locked.sh" ;;
esac

# record-gates.sh writes the gate proof and must only be called by gates.sh
# after the gates actually pass. Match the literal name CASE-INSENSITIVELY: a
# case-folding filesystem (Windows/macOS) resolves RECORD-GATES.SH to the real
# script, so a case-sensitive guard is a documented forgery route.
if printf '%s' "$cmd_dequoted" | grep -Eqi 'record-g[^[:space:];|&<>]*\.sh'; then
  block "Blocked: record-gates.sh writes the gate proof and must only be called by gates.sh after the gates actually pass. Run: bash migration/tools/gates.sh"
fi
# GLOB spellings expand, in the shell, to the same proof-writer while dodging the
# literal-name match above: `record-?ates.sh`, `record-*.sh`, `record-[g]ates.sh`
# all run record-gates.sh. Block any record- token that carries a glob
# metacharacter (?, *, [); a legitimate call spells the name in full.
if printf '%s' "$cmd_dequoted" | grep -Eqi 'record-[^[:space:];|&<>/]*[?*[][^[:space:];|&<>/]*\.sh'; then
  block "Blocked: glob-spelled invocation of a record-*.sh proof/audit writer — the shell expands it to the real script, sidestepping the name guard. Spell the script in full. The proof is written only by gates.sh: bash migration/tools/gates.sh"
fi

# Block WRITES to (and, since the board snapshots joined the proof, DELETION
# of) the gate-proof state. The 'gates-passed' prefix covers the content hash
# (gates-passed.diffsha) AND the board snapshots (gates-passed.parity-matrix.md
# / .spec-matrix.md) that check-audits.sh compares against — deleting a
# snapshot would drop check-audits back to its trust-HEAD bootstrap fallback,
# which commit-then-gate can launder. Detection is intentionally CONSERVATIVE:
# any write/delete operator anywhere in a command that also names the proof
# state is blocked, including one inside quotes — this is what catches a nested
# write such as `bash -c "echo x > <proof>"`. The cost is that a read whose
# argument contains a literal '>' (e.g. `grep '>' <proof>`) is also blocked;
# that over-block is an acceptable trade against letting a real write slip
# through. Plain reads (`cat <proof>`, `grep foo <proof>`) pass.
if printf '%s' "$cmd" | grep -qi 'gates-passed' \
   && printf '%s' "$cmd" | grep -Eq '(>|\btee\b|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\bln\b|\btruncate\b|\brm\b|\bunlink\b|\bshred\b|\bsed\b[[:space:]]+(-i|--in-place))'; then
  block "Blocked: writing or deleting gate-proof state (gates-passed.*) directly. It is written only by gates.sh on a real pass. Run: bash migration/tools/gates.sh"
fi

# Deleting the local state ROOT is the wholesale version of the same laundering:
# wipe .harness/state (audit records + gate proof + board snapshots) and both
# check-audits and the Stop hook fall back to their trust-committed-history
# bootstrap paths. Only the roots are blocked — deleting a single bookkeeping
# file the prompts own (.harness/state/idle-ticks) stays allowed.
if printf '%s' "$cmd" | grep -Eq "\b(rm|unlink|shred|mv)\b[^|;&]*\.harness(/state)?/?([[:space:];&|()<>\`\\'\"]|\$)"; then
  block "Blocked: deleting the harness state root (.harness or .harness/state). It holds the gate proof, the board snapshots, and the audit records — wiping it resets the harness to its trust-committed-history bootstrap, which launders un-audited claims. Delete specific bookkeeping files (e.g. .harness/state/idle-ticks) instead."
fi

# Same for the audit records. An audit record says a fresh-context auditor read
# this exact code and passed it; hand-writing one is forging that. It is written
# only by record-audit.sh, which the AUDITOR calls when it has actually finished.
if printf '%s' "$cmd" | grep -qi '\.harness/state/audits' \
   && printf '%s' "$cmd" | grep -Eq '(>|\btee\b|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\bln\b|\btruncate\b|\brm\b|\bsed\b[[:space:]]+(-i|--in-place))'; then
  block "Blocked: writing or deleting an audit record directly. A record asserts that a fresh-context auditor read THIS code and passed it. It is written only by the auditor, via: bash migration/tools/record-audit.sh <row-id> pass|fail"
fi

# git config that creates an EXECUTION channel. core.hooksPath repoints git's
# hooks at an agent-writable directory; alias.<x>='!cmd' runs a shell payload on
# `git <x>`; core.fsmonitor runs a program on every git command. Each executes
# on the NEXT git invocation, outside every PreToolUse guard — the same
# out-of-band route that makes .git/hooks/ dangerous. A human sets these outside
# the agent session if a repo legitimately needs them.
#
# Run on $cmd_dequoted, not $cmd: `git config "alias.z" '!evil'` quotes the key
# so a raw match loses the space before `alias`; dequoting restores the
# effective spelling `git config alias.z ...` (same reason the record-* guards
# use the dequoted copy). The alias alternative anchors on a word boundary
# rather than a literal space so a dequoted `config alias.x` still matches.
if printf '%s' "$cmd_dequoted" | grep -Eqi '\bgit\b[^|;&]*\bconfig\b[^|;&]*(core\.hookspath|core\.fsmonitor|\balias\.[a-z])'; then
  block "Blocked: git config of an execution channel (core.hooksPath / core.fsmonitor / alias.*). These run code on the next git command, invisibly to every PreToolUse guard. A human configures them outside the agent session if genuinely needed."
fi
# The SAME channels set via git's inline `-c KEY=VAL` form, which needs no
# `config` subcommand — `git -c core.hooksPath=/tmp/x commit` runs a hook from
# an agent-controlled dir for that one (hook-firing) invocation.
if printf '%s' "$cmd_dequoted" | grep -Eqi '\bgit\b[^|;&]*[[:space:]]-c[[:space:]]+[^|;&]*(core\.hookspath|core\.fsmonitor|alias\.[a-z])'; then
  block "Blocked: git -c inline config of an execution channel (core.hooksPath / core.fsmonitor / alias.*). It runs code on that git invocation, invisibly to every PreToolUse guard. Drop the -c override."
fi
# Direct writes to .git/config reach the same execution-channel keys without ever
# naming `git config` — and .git/config is NOT hashed by check-locked (nothing
# under .git can be), so this guard is its ONLY backstop. Block any write/delete
# operator that also names .git/config. (Reads — `grep alias .git/config` — carry
# no write operator and pass, as with the gate-proof guard above.)
if printf '%s' "$cmd" | grep -Eq '\.git/config' \
   && printf '%s' "$cmd" | grep -Eq '(>|\btee\b|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\bln\b|\btruncate\b|\bsed\b[[:space:]]+(-i|--in-place))'; then
  block "Blocked: writing .git/config directly. It carries the same execution-channel keys (core.hooksPath / core.fsmonitor / alias.*) as 'git config', runs code out-of-band on the next git command, and is not covered by check-locked. A human edits git config outside the agent session."
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
# target or an argument to a mutating verb, not merely present. A negated
# separator class keeps each match inside one command segment so an unrelated
# later command isn't implicated (`[^|;&<>]` after a redirection operator,
# where <> would start a new redirection; `[^|;&]` after a verb, where a
# redirection between verb and path is still the same segment). A read whose ARGUMENTS happen to contain a verb word (`grep -r rm
# migration/tools/`) is over-blocked; that trade is deliberate and matches the
# existing tee/cp/mv posture — a false block stalls one call, a missed mutation
# silently voids every proof that follows.
_mutating_verbs='tee|cp|mv|dd|install|ln|truncate|rm|unlink|shred|chmod|chown'
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$root" ] && [ -f "$root/migration/harness.env" ]; then
  # shellcheck source=/dev/null
  . "$root/migration/harness.env"
  for frag in ${HARNESS_LOCKED:-}; do
    frag="${frag%/}"   # a trailing-slash fragment (migration/tools/) must still
                       # match the no-slash spelling `rm -rf migration/tools`
    esc=$(printf '%s' "$frag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    # -i: on a case-folding FS, MIGRATION/TOOLS/gates.sh hits the real file.
    if printf '%s' "$cmd" | grep -Eqi \
      "(>>?[[:space:]]*[^|;&<>]*${esc})|(\b(${_mutating_verbs})\b[^|;&]*${esc})|(\bsed\b[^|;&]*(-i|--in-place)[^|;&]*${esc})|(\bgit\b[^|;&]*\b(rm|checkout|restore|clean|stash)\b[^|;&]*${esc})"; then
      block "Blocked: mutating locked harness enforcement file matching '$frag' (HARNESS_LOCKED) — this includes DELETING or reverting it, not just writing it. The agent must not weaken its own gates/hooks/config: a Stop hook that is not on disk does not run. A human edits these outside the agent session. Executing/reading them (e.g. bash migration/tools/gates.sh, cat) is allowed."
    fi
  done
  for frag in ${HARNESS_FROZEN:-}; do
    frag="${frag%/}"
    esc=$(printf '%s' "$frag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    if printf '%s' "$cmd" | grep -Eqi \
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
  | sed "s/\\(-m\\|--message=\\{0,1\\}\\|--file=\\{0,1\\}\\|-F\\)[[:space:]]*'[^']*'//g" \
  | sed 's/\(-m\|--message=\{0,1\}\|--file=\{0,1\}\|-F\)[[:space:]]*\\\{0,1\}"\(\\\\\\\\\|\\\\\\"\|[^"\\]\)*\\\{0,1\}"//g')

if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^;&|]*\badd\b[^;&|]*([[:space:]]-A\b|[[:space:]]-u\b|[[:space:]]--all\b|[[:space:]]--update\b|[[:space:]]--no-ignore-removal\b|[[:space:]]\./?([[:space:];&|()<>`\\]|$)|[[:space:]]:/)'; then
  block "Blocked: blanket staging (git add -A/-u/./--all). It sweeps unrelated edits into the commit. Stage the explicit files of THIS slice by path."
fi

if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^;&|]*\bcommit\b[^;&|]*([[:space:]]-a\b|[[:space:]]-am\b|[[:space:]]--all\b)'; then
  block "Blocked: git commit -a stages all tracked edits. git add the explicit slice files, then commit. Tip: a message that must MENTION staging flags goes in a file (git commit -F <file>)."
fi

# --- Pathless tree-wide reverts (universal) ---------------------------------
# The HARNESS_LOCKED/HARNESS_FROZEN blocks above are TARGET-AWARE: they fire
# only when a protected path is NAMED in the command. `git checkout -- .`,
# `git restore .` and `git clean -f` mutate those same paths without naming
# any of them — and, mid-slice, destroy uncommitted work tree-wide (the exact
# orphan-writer incident SINGLE-TICK-PROMPT.md step 0 recounts). Branch
# switches (`git checkout <branch>`) and explicit-path reverts stay allowed:
# only the whole-tree pathspecs ('.', ':/') and clean -f are blocked. Uses
# cmd_noq so a commit MESSAGE mentioning these does not false-positive.
if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^|;&]*\b(checkout|restore)\b[^|;&]*[[:space:]](\.|:/|\*|migration/?|\.claude/?)([[:space:];&|()<>`\\]|$)'; then
  block "Blocked: tree-wide or harness-dir revert (git checkout/restore of '.', ':/', '*', or a whole migration//.claude/ directory). It silently mutates locked enforcement files and the frozen oracle without naming them, and destroys any other writer's uncommitted work. Revert the EXPLICIT file paths of this slice instead."
fi
# --force is the long spelling of -f (the [-A-Za-z]* lets the second dash through).
if printf '%s' "$cmd_noq" | grep -Eq '\bgit\b[^|;&]*\bclean\b[^|;&]*[[:space:]]-[-A-Za-z]*f'; then
  block "Blocked: git clean -f deletes untracked files tree-wide — including another writer's in-flight work and any not-yet-committed harness files. Delete the explicit paths you mean instead (rm <path>)."
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
