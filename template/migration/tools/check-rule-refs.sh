#!/usr/bin/env bash
# Contract ↔ enforcement cross-reference lint.
#
# Two machine gates enforce specific HARD RULES by number: check-audits.sh is
# "hard rule 10" (fresh-context audit) and check-complete.sh is rule 11
# (reachability / the integration ledger). If a human customizing CLAUDE.md guts
# or drops one of those rules while the gate still enforces it, the contract and
# the enforcement silently disagree — the agent is bound by a rule its own
# operating contract no longer states. And a doc that hardcodes a rule COUNT
# ("the 10 hard rules") rots the moment the list grows (a real drift this repo
# hit: a doc said 10, there were 11). This lint catches both.
#
# Assertions are keyword-based, not exact-phrase, so legitimate rewording of the
# rules does not trip it — only DROPPING a load-bearing rule does. Read-only.
# bash + grep + awk. (assert-style idea adapted from pt9912/ddd-agent-rules'
# policy-contract.sh, but pinned to the rules the gates actually enforce.)
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-rule-refs: not a git repository" >&2; exit 1; }

c=CLAUDE.md
[ -f "$c" ] || { echo "check-rule-refs: $c is missing" >&2; exit 1; }

# The hard-rules section only (so a stray 'fresh-context' elsewhere in CLAUDE.md
# does not satisfy the assertion).
rules="$(awk '/^## Hard rules/{f=1;next} /^## /{f=0} f' "$c")"
# No hard-rules section = a minimal/unconfigured CLAUDE.md (the placeholder gate
# governs that separately). This lint keeps a contract that HAS rules consistent
# with what the gates enforce; with no rules there is nothing to be consistent
# with, so skip rather than fail.
if [ -z "$rules" ]; then
  echo "check-rule-refs: no '## Hard rules' section in $c — nothing to cross-check (skip)"
  exit 0
fi

rc=0
need() {  # $1 = human label, $2 = extended-regex the hard-rules section MUST match
  if ! printf '%s' "$rules" | grep -Eiq "$2"; then
    echo "check-rule-refs: the $c hard rules no longer state the '$1' rule, but a gate still enforces it —" >&2
    echo "  contract and enforcement disagree. Restore the rule (reword freely; do not drop it)." >&2
    rc=1
  fi
}
# Rule 10 — check-audits.sh enforces a fresh-context audit.
need "fresh-context audit (check-audits.sh / rule 10)" 'fresh[- ]context.*audit|audit.*fresh[- ]context'
# Rule 11 — check-complete.sh enforces reachability via the integration ledger.
need "reachability / integration ledger (check-complete.sh / rule 11)" 'integration-ledger|reachab'

# Count consistency: any "N hard rules" phrase (in CLAUDE.md or AGENTS.md) must
# match the actual number of top-level numbered rules in the hard-rules section.
n_rules="$(printf '%s\n' "$rules" | grep -cE '^[0-9]+\. ')"
for d in CLAUDE.md AGENTS.md; do
  [ -f "$d" ] || continue
  while IFS= read -r claimed; do
    [ -n "$claimed" ] || continue
    if [ "$claimed" != "$n_rules" ]; then
      echo "check-rule-refs: $d says '$claimed hard rules' but CLAUDE.md defines $n_rules — update the count (or don't hardcode one)." >&2
      rc=1
    fi
  done < <(grep -oiE '[0-9]+ hard rules' "$d" 2>/dev/null | grep -oE '^[0-9]+' | sort -u)
done

[ "$rc" -eq 0 ] || exit 1
echo "check-rule-refs: contract states every gate-enforced hard rule ($n_rules rules)"
exit 0
