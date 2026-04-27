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
- repo-docs renders each Lean file under `theory/` as a separate Theory
  document. Module organization is therefore also publication structure:
  split or section files so each rendered page has one coherent proof
  topic.
- Rendered pages get their title from the Lean module path. The first
  module doc block should begin with an overview section and explain the
  page's proof context rather than repeating the module name as an H1.

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

When Lean modules are rendered by the documentation site, also run:

```bash
just docs-build
```

Inspect the generated `result/Theory/` page for new public modules when
the edit changes module prose, declarations, or import topology. The page
should read as coherent reference material, not just as a compiled proof
dump.

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

Paper 1 Pulse kernel work is tracked by Issue #51. Implementation commits
on that branch should use `git commit -s -S` and include an `Issue: #51`
trailer unless the commit is pure process scaffolding.

## Review Expectations

- A proof module should say which obligations it discharges and which
  remain.
- A rendered theory page should have enough prose and declaration
  docstrings for a reader to understand the model boundary without
  opening the corresponding Haskell file or roadmap note first.
- Longer rendered theory pages should be divided with Markdown section
  prose so they read like theorem notes rather than unstructured code
  dumps.
- A scaffold module should make proof debt explicit and finite.
- A completed mechanization should replace assumptions, not add another
  abstraction layer above them.
- Any theorem expected to support later tracks should have a reusable
  name and theorem statement, not merely prove the current file compiles.
