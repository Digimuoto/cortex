---
title: "Paper 6 - Executable Causal Diagrams with Typed Linear Frontiers"
description:
  Landing page for the Executable Causal Diagrams with Typed Linear Frontiers draft. Abstract,
  status, figures, and related material for the frontier-transformer causal pipeline framing.
sidebar:
  label: Paper 6
  order: 6
status: draft
date: 2026-05-08
updated: 2026-05-13
related:
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Publications/Paper-4-wire-language/
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/proof-status.md
  - docs/Reference/Wire/style.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
  - examples/wire/dashboard-request.wire
  - theory/Cortex/Wire/ElaborationIR.lean
---

# Paper 6 - Executable Causal Diagrams with Typed Linear Frontiers

This draft frames Wire as executable causal diagram syntax: `<>` forms incomparable frontiers, `=>`
consumes compatible endpoint pairs while carrying unmatched endpoints forward, and named typed ports
determine which observations may cross the composed boundary. Typed linear frontiers provide the
accounting discipline for that diagram.

## Status

Draft manuscript. See [manuscript.md](manuscript.md) for the Markdown text and
[typst/manuscript.typ](typst/manuscript.typ) for the submission-ready PDF source registered as a Nix
docs output. The PDF uses the shared profile-driven Cortex submission template under
`docs/Publications/_typst/`.

Public artifact context is available through the
[Cortex documentation](https://digimuoto.github.io/cortex/) and the
[proof-status dashboard](https://digimuoto.github.io/cortex/Reference/proof-status/), the live
source of truth for current Lean mechanization and Haskell correspondence.

## Abstract

Wire is a source language for executable causal diagrams. Its surface is a typed
frontier-transformer calculus: `<>` forms incomparable frontier union, `=>` consumes compatible
endpoint pairs and carries unmatched endpoints forward, and typed ports decide which observations
may cross the composed boundary. The draft uses an async dashboard diamond as its canonical example:
fetch a user, derive distinct branch facts in CorePure (Wire's deterministic expression layer),
fetch posts and friends independently, carry the profile fact directly to the join, then assemble
the response. In host languages the diamond is a property of execution; in Wire the admitted diagram
is the shared object. The Cortex artifact aligns algebraic graph syntax, source elaboration, circuit
lowering to Pulse, Cortex's durable runtime, proof-track admission slices, and a Lean-facing
post-elaboration IR. The public proof-status dashboard links the relevant Lean declarations and
distinguishes proven claims, runtime hooks, tests, witnesses, and remaining correspondence
obligations.

## Figures

- [Figures/index.md](Figures/index.md) - figure inventory and export status.
- [dashboard-topology.mmd](Figures/dashboard-topology.mmd) - admitted dashboard topology with the
  carried `profile` dependency.
- [dashboard-topology-module.typ](Figures/dashboard-topology-module.typ) - reusable Typst figure
  body used by the manuscript.
- [executable-diagram-layers.mmd](Figures/executable-diagram-layers.mmd) - source diagram, admitted
  frontier, causal topology, circuit, runtime trace, and proof-facing IR as one layered view.
- [executable-diagram-layers-module.typ](Figures/executable-diagram-layers-module.typ) - reusable
  Typst figure body used by the manuscript.
- [executable-diagram-layers.typ](Figures/executable-diagram-layers.typ) - standalone Typst export
  for the same figure.

## Related

- [manuscript.md](manuscript.md) - full draft.
- [typst/manuscript.typ](typst/manuscript.typ) - submission-ready Typst manuscript.
- [../../../examples/wire/dashboard-request.wire](../../../examples/wire/dashboard-request.wire) -
  build-backed canonical Wire example.
- [../../Reference/proof-status.md](../../Reference/proof-status.md) - Lean proof and Haskell
  correspondence status dashboard.
- [../Paper-2-algebraic-foundations/](../Paper-2-algebraic-foundations/) - algebraic substrate.
- [../Paper-3-graph-substitution-semantics/](../Paper-3-graph-substitution-semantics/) - dynamic
  substitution and materialization semantics.
- [../Paper-4-wire-language/](../Paper-4-wire-language/) - Wire as an authoring language.
- [../../Architecture/04-graph-and-circuit.md](../../Architecture/04-graph-and-circuit.md) -
  topology layers below Wire.
- [../../Reference/Wire/style.md](../../Reference/Wire/style.md) - topology-first formatting rules.
- [../../ADRs/0047-wire-frontier-linearity-and-precedence.md](../../ADRs/0047-wire-frontier-linearity-and-precedence.md)
  - linear frontier semantics.
- [../../ADRs/0049-wire-fan-phantom-adapter.md](../../ADRs/0049-wire-fan-phantom-adapter.md) - `*`
  as an explicit phantom adapter.
- [../../ADRs/0052-wire-bounded-indexed-boundary-products.md](../../ADRs/0052-wire-bounded-indexed-boundary-products.md)
  - bounded indexed products and finite-product adapters.
