# probes/

The **fixture generator** — the ONLY new legacy-stack code allowed in this
repository (CLAUDE.md hard rule 1).

A probe runs the frozen legacy code and dumps `input → output` vectors as JSON
into `migration/fixtures/`. The migrated implementation is then tested against
those exact vectors, which is how numeric/behavioral parity is proven bit-for-bit
(CLAUDE.md hard rule 4) without ever editing the frozen oracle.

## Rules

- Probes are legacy-stack code (they import and exercise the legacy source).
  They are the one exception to "no new legacy-stack code" — everything else new
  goes in the target tree.
- A probe must be **deterministic**: seed any RNG so re-running produces
  identical vectors. If the legacy code uses an RNG (e.g. an LCG), the probe
  captures its seeded output so the target can reproduce it exactly.
- Never edit the frozen oracle to make it probe-able. Wrap it, drive it, read
  its output — but leave it byte-identical.
- Commit generated fixtures under `migration/fixtures/`, not here.

## Layout (suggested)

```
probes/
  <feature>_probe.<ext>   # runs legacy <feature>, writes migration/fixtures/<feature>.json
```

Delete this README once you have real probes, or keep it as the directory's
contract.
