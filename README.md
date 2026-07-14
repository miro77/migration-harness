# migrate-projects-with-claude

A reusable, stack-agnostic **harness** for running large legacy-code migrations
autonomously with Claude Code — the kind that runs slice-by-slice, gate-checked,
and mostly unattended.

It is extracted from a real, large production migration (a legacy desktop
application → a modern cross-platform stack, driven entirely by this harness).
This repo generalizes the parts that were *not* specific to that project so you
can drop them onto the next migration and keep the properties that made the
first one work:

- **Nothing is "done" without executable proof.** A Stop hook refuses to let a
  turn end if migration files changed but no gate run is recorded for that exact
  tree state.
- **The legacy code is a frozen oracle.** Correctness comes from running it and
  matching its output on committed fixtures — not from reading it and hoping.
- **One slice per pass, audited by a fresh context** that didn't write the code.
- **Unattended but bounded.** A driver advances one unit of work per tick —
  each tick in a fresh context, so quality doesn't degrade over a long run —
  and stops on a defined termination condition.
- **Every tick is inspectable.** An append-only local journal records attempt
  starts, classified outcomes, duration, tool-call count, and tree hashes, and
  correlates them with the existing per-tool telemetry.

## What's in here

```
template/                 # copy this into your target repo
├── CLAUDE.md             # the operating contract (hard rules, done criteria)
├── CLAUDE-feature.md     # alternate contract for spec-driven feature work
├── .claude/
│   ├── settings.json     # wires the hooks (PreToolUse, PostToolUse, Stop, PreCompact)
│   ├── hooks/            # stop-require-gates, frozen-legacy, command-guard,
│   │                     #   precompact-checkpoint, posttooluse-telemetry
│   ├── agents/           # legacy-analyst, parity-auditor, spec-auditor, coder
│   └── commands/         # /migrate-slice, /parity-check
└── migration/
    ├── harness.env       # the ONE place you configure scope + frozen paths + budget
    ├── PLAN.md           # phased strategy (bootstrap → core → persistence → UI)
    ├── parity-matrix.md  # single source of truth for slice status
    ├── spec-matrix.md    # feature-profile status board
    ├── decisions.md      # ADRs + PENDING decisions
    ├── SINGLE-TICK-PROMPT.md # one unit of work per fresh context (kick-loop --drive)
    ├── LOOP-PROMPT.md    # same ticks, self-paced in one session; delegates
    │                     #   each tick to a subagent for a fresh window
    ├── inventory.md      # map of migratable units
    ├── legacy-runtime.md # verified build/run recipes for the oracle
    └── tools/            # gates.sh, record-gates.sh, working-tree-hash.sh,
                          #   doctor.sh, check-docs.sh, check-stubs.sh,
                          #   kick-loop.sh, persist-state.sh, read-state.sh,
                          #   benchmark.sh, gui-capture.py, gui-compare.py
```

**Docs:** [GETTING-STARTED.md](GETTING-STARTED.md) · [docs/PHILOSOPHY.md](docs/PHILOSOPHY.md) · [docs/ADAPTING.md](docs/ADAPTING.md) · [docs/IN-PLACE-PROFILE.md](docs/IN-PLACE-PROFILE.md) · [docs/FEATURE-PROFILE.md](docs/FEATURE-PROFILE.md)

## Quick start

See **[GETTING-STARTED.md](GETTING-STARTED.md)**. In short: run
`bash install.sh` from your repo root, or `.\install.ps1 -TargetDir .` on
Windows (or `cp -R template/. .` — NOT
`cp -r template/* .`: the `*` glob drops the dot-dir `.claude/` with every
hook, agent, and command), edit `migration/harness.env` (scope + frozen
paths) and the
PROJECT GATES block in `migration/tools/gates.sh`, fill the `<...>` placeholders
in `CLAUDE.md`/`PLAN.md`, then run `bash migration/tools/kick-loop.sh --drive`
(one slice per fresh context, back-to-back) — or paste
`migration/LOOP-PROMPT.md` into a fresh Claude Code session for a single
self-paced run.

Windows also ships `.ps1` entry points for gates, diagnostics, the tick driver,
and tests. They resolve Git Bash explicitly and execute the same `.sh` files, so
there is only one proof and enforcement implementation.

## Example prompts

Use these after installing the harness from this repo into the target
repository. Fill only the intent placeholders — what you're migrating and where
to; everything the repo can reveal (stack, paths, gate commands) the prompt
tells Claude to discover during Phase 0 and record as assumptions. They are
starting prompts; the real contract lives in `CLAUDE.md`, `migration/PLAN.md`,
and the matrix.

> **Prefer to tick boxes?** Use the hosted generator at
> **[miro77.github.io/prompt-generator.html](https://miro77.github.io/prompt-generator.html)**,
> or open [`prompt-generator.html`](prompt-generator.html) locally — same page.
> Pick freeze-and-replace / in-place / feature, fill your stack, and it assembles
> the matching prompt below (blank fields stay `<placeholder>`). It generates a
> prompt to paste, not harness code — the copy-in template stays the source of
> truth.

### 1. Freeze-and-replace migration

Use this when the old implementation remains in the repo as a live oracle and
the new implementation is built beside it.

```text
Install and configure the migration harness from
https://github.com/miro77/autonomous-work-harness for this repository.

Goal: migrate <legacy system/module> to <target stack>, building the new
implementation beside the legacy code and keeping the legacy tree as the frozen
executable oracle.

Discover the rest from the repo during Phase 0 — do not ask:
- the legacy stack and the legacy source paths (set HARNESS_FROZEN to them);
- a conventional target path for the new implementation (set HARNESS_SCOPE to
  "<target-paths> migration .claude CLAUDE.md AGENTS.md");
- the FULL real project checks from the CI config and manifests — wire them into
  migration/tools/gates.sh and cite the CI file they came from.
Record each discovered choice in migration/decisions.md as an assumption.

Fill CLAUDE.md, migration/PLAN.md, migration/legacy-runtime.md, and
migration/parity-matrix.md. Phase 0 should inventory the legacy units, define
fixture probes, and split the migration into one observable parity row per
slice. Do not implement migration slices until the harness config and gates are
working.
```

### 2. In-place migration

Use this when the code is edited in place, such as removing a dependency or
swapping a framework, while preserving behavior.

```text
Configure the migration harness from
https://github.com/miro77/autonomous-work-harness for an in-place migration.

Goal: transform the existing code from <old dependency/framework/runtime> to
<new dependency/framework/runtime> without changing observable behavior.

Discover the rest from the repo during Phase 0 — do not ask:
- the source paths that use <old dependency/framework/runtime> (set
  HARNESS_SCOPE to "<source-paths> migration .claude CLAUDE.md AGENTS.md",
  PLUS the build/CI scripts, CI configs, and any vendored tool binaries the
  gates execute — the proof must cover the gates' own inputs);
  leave HARNESS_FROZEN empty — there is no separate legacy tree to freeze
  (unless the repo vendors the old dependency's own sources: freeze those);
- the FULL real project checks from the CI config and manifests — wire them into
  migration/tools/gates.sh and cite the CI file they came from.
Record each discovered choice in migration/decisions.md as an assumption.

Before editing each unit, capture its current behavior as fixtures from the base
commit using probes in migration/fixtures/ or probes/. Tests-first: a unit gets
a T-row (pin behavior with tests on unmigrated code, snapshot a baseline)
before its M-row (the edit) — see docs/IN-PLACE-PROFILE.md.

Fill CLAUDE.md and migration/parity-matrix.md so each row names one behavior to
preserve, the fixture/probe that captures it, and the source paths to edit.
Work one row at a time; no success claim without gates and fresh-context audit.
```

The full playbook for this mode — baseline anti-deletion machinery,
status-board validation, teardown-as-done, and the setup-review loop — is in
[docs/IN-PLACE-PROFILE.md](docs/IN-PLACE-PROFILE.md).

### 3. New feature with the harness

Use this when there is no legacy oracle and correctness comes from a written
spec plus acceptance tests.

```text
Use the feature profile of the harness from
https://github.com/miro77/autonomous-work-harness to build <feature name>.

Goal: add <feature name> for <users/callers>. Correctness is the written spec,
not legacy parity.

Rename the installed CLAUDE-feature.md (at the repo root after install) to
CLAUDE.md, and set HARNESS_PROFILE="feature" in migration/harness.env — the
loop then drives /feature-slice against migration/spec-matrix.md, used as
the status board. Leave HARNESS_FROZEN empty.

Discover the rest from the repo during Phase 0 — do not ask:
- the source paths the feature lives in (set HARNESS_SCOPE to
  "<source-paths> migration .claude CLAUDE.md AGENTS.md");
- the FULL existing checks from the CI config and manifests — wire them plus the
  new acceptance tests into migration/tools/gates.sh.
Record each discovered choice in migration/decisions.md as an assumption.

During Phase 0, break the feature into one row per observable acceptance
criterion. Write or name the acceptance test for each row before implementation.
Use spec-auditor for fresh-context audits. Keep the existing suite green on
every slice.
```

## Template, not a generator

This ships as a **copy-in template plus a design guide** — the template, not
generated code, is the source of truth. A template is legible and Claude can
adapt it in place. A thin `install.sh` wraps it for one-command setup (copy,
`chmod`, gitignore, status report), but it only *stamps* the template: there is
no generator to keep working as Claude Code's hook/settings format evolves.
Either way the real cost is ~30 min of copy-and-fill per project. See
[docs/ADAPTING.md](docs/ADAPTING.md).

## Provenance

Distilled from a real, large migration. The concrete, project-specific gate
commands, platform constraints, and legacy-oracle specifics were replaced with
placeholders; the enforcement mechanics (hooks, proof hashing, slice loop,
fresh-context audit) are carried over as-is.
