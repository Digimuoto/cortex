---
title: "ADR 0076 — Wire CLI Proof-Fixture and Grammar-Acceptance Subcommands"
description:
  "Makes the `wire` CLI the first-party entry point for grammar-differential acceptance (`wire
  parse`) and Lean admission-artifact fixture regeneration (`wire lean-fixtures`) that feed the
  proof track."
sidebar:
  label: "0076. Wire CLI proof fixtures"
  order: 76
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/proof-status.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
---

# ADR 0076 — Wire CLI Proof-Fixture and Grammar-Acceptance Subcommands

## Status

Proposed — this ADR records that two non-execution proof-track subcommands already live in the
`wire` command surface, and fixes the contract those subcommands must keep. It does not introduce a
new executable.

## Context

ADR 0041 shaped `wire` as a small command family for working with Wire source _locally_:
`wire FILE`, `wire build`, and `wire run`. Its command table lists only build/run roles, and it
explicitly leaves room for "future subcommands [that] can add checks, formatting,
package/build-cache behavior, registry inspection, or durable submission" without changing the
executable name.

Two such subcommands have since landed, and neither fits the local-execution framing 0041 governs:

- **Grammar-acceptance.** Cortex maintains two Wire front ends — the megaparsec parser in the
  library and the `editors/tree-sitter-wire` grammar used by docs and editors. They can drift in
  what they accept or reject. The differential harness `scripts/wire-grammar-diff` (recipe
  `just wire-grammar-diff`) checks them against each other over the corpus under
  `test/fixtures/wire` and `examples/wire`. It needs a stable accept/reject probe for the megaparsec
  side. There was no first-party command that parses a file and exits non-zero on rejection without
  also compiling or running it.

- **Proof-fixture regeneration.** ADR 0038 names the Wire proof-track theorem targets, including the
  admission-artifact `validatorReady*` surface, but it stops at the theorem ledger — it does not own
  a CLI that produces the Lean inputs those theorems consume. The theory track checks in generated
  Lean modules under `theory/Cortex/Wire/AdmissionArtifact/Emitted/` (and a `Differential/` kernel
  corpus): each is real compiler output rendered as a Lean value plus a `#guard`/soundness theorem,
  so `just lean-check` validates actual emitted artifacts. Those files must be regenerable from a
  single command, not hand-edited.

Both are proof-track and tooling concerns, not the local authoring loop. Folding them into
`wire run` or a separate script would either blur the `run` role or scatter the proof-track entry
points across ad hoc binaries. The `wire` command is the natural home, exactly as 0041 anticipated.

## Decision

Treat the `wire` command as the first-party entry point for Wire proof-track and grammar-acceptance
tooling, and keep two non-execution subcommands there alongside the local-execution family:

```bash
wire parse FILE              # expand includes and parse; no compilation
wire lean-fixtures OUTDIR    # regenerate emitted Lean artifact fixtures
```

`wire parse FILE` is a parse-only acceptance probe. It expands source includes, runs the megaparsec
parser, prints `parse ok: <path>` on success, and exits non-zero with a rendered parse error on
failure. It performs no compilation, lowering, or execution. It exists to give the grammar
differential harness a megaparsec accept/reject signal: `scripts/wire-grammar-diff` runs
`wire parse` against `tree-sitter parse` per fixture, and a disagreement that is not in the
`scripts/wire-grammar-diff.known` allowlist fails the run. Because `wire parse` expands includes
while the tree-sitter pass sees raw source, include-expansion failures are a known boundary
difference, not grammar drift — the allowlist, not the command, absorbs them.

`wire lean-fixtures OUTDIR` regenerates the checked-in Lean fixture corpus from the live compiler.
For each fixture in `Cortex.Wire.LeanFixture` it compiles the Wire source, extracts the attached
`WireAdmissionArtifact`, and writes `OUTDIR/<Slug>.lean` plus a sibling `Emitted.lean` umbrella; it
then writes a `Differential/<Slug>.lean` kernel corpus and a `Differential.lean` umbrella. The
canonical invocation is `just wire-lean-fixtures`, which targets
`theory/Cortex/Wire/AdmissionArtifact/Emitted`. The fixture set and renderer are library code
(`Cortex.Wire.LeanFixture`), so the CLI subcommand stays a thin driver: it owns argument handling,
directory creation, and file writes, while the corpus, compile environment, and Lean rendering are
pure functions the Haskell test suite re-evaluates.

The generated modules are not editable artifacts. The Haskell suite re-renders every fixture and
fails on any drift between the renderer's output and the checked-in `theory/` files, so the command
is the only sanctioned way to change them.

## Alternatives considered

- **Leave both behaviors as standalone scripts/binaries.** Rejected. The grammar probe needs the
  exact megaparsec accept/reject decision the library already implements, and the fixture generator
  needs the live compiler and the shared fixture corpus. Re-implementing either outside `wire` would
  duplicate compiler surface and risk diverging from what `wire build`/`wire run` actually parse and
  compile. 0041 already reserved subcommand space for precisely this.

- **Fold grammar acceptance into `wire build`.** Rejected. `build` compiles and emits a
  `CompiledCircuit`; the differential harness wants a parse-stage verdict with no compilation, and
  conflating the two would make a compile-stage failure look like a grammar divergence. A dedicated
  `wire parse` keeps the front-end boundary the harness measures crisp.

- **Generate the Lean fixtures inside the Haskell test suite instead of via a CLI.** Rejected for
  the write path. The suite already re-renders and _checks_ the fixtures as a drift gate, but tests
  must not rewrite checked-in proof inputs as a side effect. A regenerate command keeps authoring
  explicit and reviewable while the test stays a read-only gate.

## Consequences

### Positive

- The proof track gains a single, reproducible regeneration command, so the checked-in Lean fixtures
  provably reflect current compiler output rather than stale hand edits.
- Grammar drift between the megaparsec parser and the tree-sitter grammar is caught by a first-party
  probe over the shared corpus, with intentional boundary differences quarantined in an allowlist.
- The `wire` command stays the one entry point for Wire tooling, matching the family shape ADR 0041
  set out; no extra executable to build, package, or document.

### Negative

- The `wire` surface now spans two audiences: local authors (`run`/`build`/`fmt`) and proof/grammar
  maintainers (`parse`/`lean-fixtures`). The help text and docs must keep that split legible.
- `wire lean-fixtures` writes into `theory/`, coupling a CLI subcommand to the proof tree's layout
  (the umbrella and `Differential/` siblings are derived from `OUTDIR`). Moving the fixture tree
  means updating the recipe and the drift-test paths together.
- The grammar probe's value depends on the corpus and the `known` allowlist staying curated; a stale
  allowlist entry is reported but only fails when the harness runs.

### Obligations

- Keep `wire parse` parse-only: it must not acquire compilation or execution behavior, or the
  grammar differential loses its front-end boundary.
- Keep the fixture corpus, compile environments, and Lean rendering in `Cortex.Wire.LeanFixture` as
  pure functions so the drift test in `test/Cortex/Wire/CompileSpec.hs` can re-render without the
  CLI.
- When a fixture, the renderer, or the artifact schema changes, regenerate with
  `just wire-lean-fixtures` and review the resulting `theory/` diff; never hand-edit the generated
  modules.
- Document the two subcommands in the Usage guide alongside the local-execution family so the proof
  surface is discoverable.

## Traceability

- Feature keys: `cli.proof_fixtures`
- Public surface: `Cortex.Wire` (the `wire` command and `Cortex.Wire.LeanFixture`),
  [`docs/Reference/Wire/grammar.md`](../Reference/Wire/grammar.md)
- Implementation: `app/wire/Main.hs` (`parseWireOnly`, `leanFixturesWire`, `CommandParse`,
  `CommandLeanFixtures`), `src/Cortex/Wire/LeanFixture.hs`, `scripts/wire-grammar-diff`
- Tests: `test/Cortex/Wire/CompileSpec.hs` (the "emitted Lean fixtures" drift gate)
- Theory/proof:
  [The Emission-Soundness Target](../Reference/proof-status.md#the-emission-soundness-target) —
  clauses 2 (`validatorReadyCheck` at every `lean-check`) and 4 (per-fixture kernel differential)
  consume these regenerated fixtures

## Related

- [Chapter 03 — Formalism stack](../Architecture/03-formalism-stack.md)
- [Chapter 05 — Wire language](../Architecture/05-wire-language.md)
- [Wire grammar](../Reference/Wire/grammar.md) — the normative grammar the parse-acceptance probe
  defends.
- [Cortex Proof Status](../Reference/proof-status.md) — the emission-soundness target the fixtures
  feed.
- [Cortex Feature Status](../Reference/feature-status.md) — the `cli.proof_fixtures` capability row.
- [ADR 0041 — Wire CLI Command Surface](./0041-wire-cli-command-surface.md) — the command family
  this ADR extends.
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — the
  theorem targets whose fixtures `wire lean-fixtures` regenerates.
