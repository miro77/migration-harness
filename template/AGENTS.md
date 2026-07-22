# Agent operating rules

The operating contract for working in this repository lives in **[`CLAUDE.md`](CLAUDE.md)** —
read it first and follow it exactly. `AGENTS.md` exists only so agents that look
for this filename (e.g. Codex and other tools using the AGENTS.md convention)
find the same rules.

`CLAUDE.md` is canonical. If you edit one, mirror the change in the other — both
are in `HARNESS_SCOPE`, so a change here requires a passing gate run like any
other scoped file.

## Authority by concern

These sources govern different questions; they are not one global precedence
ladder.

| Concern | Authority |
|---|---|
| Operating constraints and per-slice done criteria | `CLAUDE.md` |
| Current slice status and acceptance evidence | `migration/parity-matrix.md` or `migration/spec-matrix.md`, according to `HARNESS_PROFILE` |
| Phase order and migration/feature strategy | `migration/PLAN.md` |
| Architecture decisions and recorded assumptions | `migration/decisions.md` |
| Checks that actually execute | `migration/tools/gates.sh` |

If two sources conflict within the same concern, stop and record the conflict;
do not silently choose the more convenient interpretation.
