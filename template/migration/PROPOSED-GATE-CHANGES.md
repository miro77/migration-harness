# Proposed gate changes — locked-file edits awaiting a human

The harness's own enforcement files are **locked** (`HARNESS_LOCKED` in
`migration/harness.env`): `gates.sh`, the hooks, `settings.json`, and
`harness.env` itself. The agent cannot edit them — that lock is the integrity
core, and it is why "edit `gates.sh` to a no-op then record a pass" is
impossible.

But a migration sometimes **discovers** that a gate genuinely must change — most
often that a needed check is missing (e.g. a consumer/bundle build the test
suite can't see). When that happens, the agent must NOT route around the lock
and must NOT leave the finding as an ad-hoc note that outlives the migration.
Instead it records the exact proposed change here, as a `## PROPOSAL` entry.

This file is **not locked** — the agent can append to it. `doctor.sh` reports
the open-proposal count, so a pending proposal stays visible instead of being
forgotten. A migration is **not truly done while an open proposal remains**: the
recorded proof only covers the gates that actually ran, so a needed-but-unwired
gate means the "done" claim is weaker than it looks. `HANDOFF.md` must list every
open proposal.

## Workflow

1. **Agent** — on discovering a needed locked-file change, append a `## PROPOSAL`
   entry below with: what to change, in which file, the exact before/after text,
   and why the test suite doesn't already catch it. Keep migrating the rows that
   don't depend on it; note in affected matrix rows that the gate is proposed but
   not yet wired (run the check manually meanwhile and say so).
2. **Human** — apply the edit to the locked file, run `bash migration/tools/gates.sh`
   to re-record the proof, then delete the applied `## PROPOSAL` entry and commit.

## Open proposals

_None yet._ Add each as a `## PROPOSAL: short title` heading below this line (at
column 0 — `doctor.sh` counts headings that start with `## PROPOSAL`).

<!--
Entry template — copy the block below, un-indent the heading to column 0, and
fill it in. It is indented here on purpose so this example is NOT counted as an
open proposal.

  ## PROPOSAL: add the consumer-bundle build to gates.sh

  - FILE: migration/tools/gates.sh (HARNESS_LOCKED)
  - WHY: renames pass tsc + unit tests but break the browser/bundler resolve;
    only a consumer build catches it. See the CONSUMER-BUILD block already
    stubbed in gates.sh.
  - CHANGE: between the `# HARNESS:CONSUMER-BUILD-START/END` markers, add:
      ( cd frontend && npm run build ) || fail "consumer bundle (vite build)"
  - INTERIM: run that command by hand each slice until applied; matrix rows note it.
-->
