# Cortex Theory Architecture

The Lean tree lives under `theory/` and mechanizes substrate guarantees.
It is not a separate research playground.

## Tracks

- `Cortex.Graph.*`: Mokhov graph algebra and graph equivalence.
- `Cortex.Pulse.*`: frontier safety, progress, and determinism modulo
  external sparks.
- `Cortex.Wire.*`: rewrite admission and soundness.
- Future provider/spark and substrate/consumer boundary models should
  stay under `Cortex.*` and mirror the documentation roadmap.

## Boundaries

- Lean should model the substrate, not downstream product behavior.
- Consumer examples may appear only as downstream examples, never as the
  identity of Cortex.
- Haskell executable modules are the implementation counterpart; Lean
  modules are the proof counterpart. Cross-reference exact Haskell files
  when a definition mirrors runtime behavior.

## Build Files

Review these as part of Lean changes:

- `theory/lean-toolchain`
- `theory/lakefile.lean`
- `theory/lake-manifest.json`
- `nix/lean.nix`

Rules:

- Lean, Lake, mathlib, and Nix package versions must agree.
- Manifest changes must correspond to intentional `lakefile.lean`
  changes.
- Nix checks should build the proof surface used by CI.
- Do not add dependencies unless they materially simplify proof work or
  replace bespoke fragile reasoning.

## Validation

For Lean-only edits, run:

```bash
nix develop -c just lean-build
just lean-check
```

Run this when executable, Lake target, dependency, or `Main.lean` wiring
changes:

```bash
nix develop -c just lean-build-exe
```

Run formatting for any committed branch:

```bash
just fmt-check
```

If pre-commit hooks run during commit, record their result in the final
summary.

## Review Expectations

- A proof module should say which obligations it discharges and which
  remain.
- A scaffold module should make proof debt explicit and finite.
- A completed mechanization should replace assumptions, not add another
  abstraction layer above them.
- Any theorem expected to support later tracks should have a reusable
  name and theorem statement, not merely prove the current file compiles.
