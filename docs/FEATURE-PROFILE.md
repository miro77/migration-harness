# Feature profile — building new behavior with the same engine

*See also: [README.md](../README.md) · [PHILOSOPHY.md](PHILOSOPHY.md) · [ADAPTING.md](ADAPTING.md)*

The harness is not migration-specific. Its load-bearing parts — the content-hash
gate proof + Stop hook, `HARNESS_LOCKED`, the fresh-context auditor, one-slice
cadence, resume-from-disk — enforce "no *done* without proof" for **any** work.
Migration and feature are two **profiles** over that one engine; they differ only
in the **oracle** — what "correct" is measured against.

| | Migration profile | Feature profile |
|---|---|---|
| oracle ("correct" =) | captured legacy behavior | the **written spec** (acceptance criteria) |
| status board | [`parity-matrix.md`](../template/migration/parity-matrix.md) | [`spec-matrix.md`](../template/migration/spec-matrix.md) |
| `HARNESS_FROZEN` | legacy / removed dependency | **empty** (nothing to freeze) |
| contract | [`CLAUDE.md`](../template/CLAUDE.md) | [`CLAUDE-feature.md`](../template/CLAUDE-feature.md) |
| auditor | [`parity-auditor`](../template/.claude/agents/parity-auditor.md) | [`spec-auditor`](../template/.claude/agents/spec-auditor.md) |
| dropped rules | — | exact-parity / RNG reproduction (there is no prior behavior to match) |
| added concern | — | write the acceptance test up front; keep the existing suite green (regression) |

Everything else — `gates.sh`, `working-tree-hash.sh`, `record-gates.sh`, the
hooks, the Stop gate — is byte-for-byte identical.

## Switching a fresh install to the feature profile

1. Use [`CLAUDE-feature.md`](../template/CLAUDE-feature.md) as your `CLAUDE.md`
   (rename it) and fill the `<...>` markers.
2. Use [`spec-matrix.md`](../template/migration/spec-matrix.md) instead of
   `parity-matrix.md` as the status board. During Phase 0, break the feature into
   one row per observable, testable acceptance criterion. The shared gate accepts
   either matrix filename.
3. Leave `HARNESS_FROZEN=""` in
   [`harness.env`](../template/migration/harness.env) — there is no legacy to
   freeze — and set `HARNESS_SCOPE` to the source tree you edit.
4. Point audits at the [`spec-auditor`](../template/.claude/agents/spec-auditor.md)
   agent (spec conformance + test honesty) instead of `parity-auditor`.
5. Your `gates.sh` PROJECT-GATES block runs your normal format + lint + types +
   the FULL test suite — same as a migration. The new acceptance tests are just
   part of that suite; the rest of the suite is your regression guard.

## Write the acceptance test first

The feature analog of a migration's "capture fixtures before you touch a unit"
is **author the acceptance test from the criterion before (or alongside) the
implementation**. A criterion whose test is written after the fact, to match
whatever the code happened to do, proves nothing — that is exactly the hollow
test the `spec-auditor` hunts for.

## Selecting the profile

Set `HARNESS_PROFILE="feature"` in
[`harness.env`](../template/migration/harness.env). The tick/loop prompts
([`SINGLE-TICK-PROMPT.md`](../template/migration/SINGLE-TICK-PROMPT.md),
[`LOOP-PROMPT.md`](../template/migration/LOOP-PROMPT.md)) read it and drive
[`/feature-slice`](../template/.claude/commands/feature-slice.md) against
[`spec-matrix.md`](../template/migration/spec-matrix.md) (bootstrap row S00);
the completion validator
([`check-complete.sh`](../template/migration/tools/check-complete.sh))
validates the same board. The enforcement plumbing (gates, proof, Stop hook,
locks) is profile-agnostic and needs no changes.

Still adapted per project: `PLAN.md` (phase breakdown is inherently yours) and
the `<...>` placeholders in `CLAUDE-feature.md` — rename the installed
`CLAUDE-feature.md` (at your repo root after install) to `CLAUDE.md` as the
operating contract.

## Why this works

The discipline that makes an autonomous loop trustworthy is oracle-independent:
**you cannot claim done without a recorded pass of the full check suite on the
exact tree, and a fresh context re-derives whether the work meets its bar.** A
feature just swaps "matches legacy" for "meets the spec, proven by a test that
would fail otherwise."
