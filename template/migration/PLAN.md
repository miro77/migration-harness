# Migration Plan: <LEGACY> → <TARGET>

## Strategy

Agentic rewrite, not transpilation. The legacy app is the **executable
oracle**: correctness is enforced by running legacy code (via `probes/`) and
comparing outputs, not by reading it. See ADR-0001 in [`decisions.md`](decisions.md).

Scale: <N source files>. <How they break down — presentation vs core logic vs
persistence.> This shapes the migration order below.

## Phases

### Phase 0 — Bootstrap (first loop tick)
0. Verify/record the legacy toolchain in this clone (build, run, any
   capture pipeline) — recipes in [`migration/legacy-runtime.md`](legacy-runtime.md); capture
   reference evidence into `migration/reference/`.
1. Implement `probes/` — a small program that instantiates legacy classes,
   feeds inputs, and writes fixtures. Verify one probe end-to-end.
2. Generate the first fixture packs into `migration/fixtures/` with fixed RNG
   seeds where randomness is involved.
3. Scaffold the target project(s); wire the parity test runner that consumes
   `migration/fixtures/*.json`.
4. Complete [`migration/inventory.md`](inventory.md) (every module/screen with source paths)
   and expand [`migration/parity-matrix.md`](parity-matrix.md) to full coverage, splitting
   oversized rows.
5. Verify `bash migration/tools/gates.sh` passes and records proof.
6. Commit. That is the whole first tick.

> **Consumer-resolution survey (do this in Phase 0, before any rename).** List
> every consumer that resolves your SOURCE by path — a browser loading modules
> by URL, a bundler with path/extension/alias resolution, another package
> importing the built artifact. Behavior tests (types, unit tests) will NOT
> catch a rename or a moved file that breaks such a consumer. For each one, wire
> its build/resolve check into the `HARNESS:CONSUMER-BUILD` block of
> [`migration/tools/gates.sh`](tools/gates.sh) so the recorded proof covers it.
> If nothing resolves your source directly, record that finding here and leave
> the block empty. `doctor.sh` reports whether the block is wired.

### Phase 1 — Core logic
<Order the core modules by dependency (leaf-first). Reimplement any legacy RNG
first so downstream deterministic tests are possible. Every module lands with
fixture-backed parity tests.>

### Phase 2 — Persistence
<Parse legacy save/config formats to the same object graph the legacy loader
produces. Fixture = legacy-load → JSON dump of the graph.>

### Phase 3 — UI
<Feature slices per legacy screen area. Reference evidence: captures of the
running legacy app in `migration/reference/`. Routing/navigation wiring is the
final step of each tick, never mid-slice.> Optionally, `migration/tools/gui-compare.py`
diffs a legacy vs new screenshot into `migration/reference/diff/` as advisory
review evidence (not a hard gate).

### Phase 4 — Integration & handoff
End-to-end flows vs legacy golden runs; `migration/HANDOFF.md` lists every
`audited-fail` row and pending decision.

## The oracle (probes/ + fixtures)

- Probe = small program that instantiates legacy classes, feeds inputs,
  writes `migration/fixtures/<area>/<case>.json`:
  `{ "id", "legacyEntry", "seed", "inputs": {...}, "expected": {...} }`
- New side: one parametrized test runner per area reads the same JSON and
  asserts exact equality (deterministic values compared exactly via seeded
  runs).
- Fixtures are committed. Regenerating them requires a probe run, never
  hand-editing.

## Driver

Unattended runs use `migration/tools/kick-loop.sh --drive` (one fresh context
per tick — recommended) or the single-session loop in
[`migration/LOOP-PROMPT.md`](LOOP-PROMPT.md). Either way each tick advances
exactly one unit of work, as defined in
[`migration/SINGLE-TICK-PROMPT.md`](SINGLE-TICK-PROMPT.md), and the next tick
starts when its slice is done.
