---
title: "ADR 0010 — Wire as Closed-Authority Language over the Graph/Circuit/Wire Stack"
description: "Cortex separates Graph, Circuit, and Wire, and Wire composes only registered authority rather than inventing executors, contracts, or domain semantics."
sidebar:
  label: "0010. Wire authority"
  order: 10
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/index.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
---

# ADR 0010 — Wire as Closed-Authority Language over the Graph/Circuit/Wire Stack

## Status

Accepted — the current Cortex vocabulary and Wire architecture already assume this split and authority rule.

## Context

Cortex needed a source language small enough to author and rewrite graph topology safely, while still preserving a principled substrate below it. The design pressure came from both human authoring and LLM-proposed rewrites: if the language could invent new executors, new contracts, or ad hoc edge semantics at runtime, validation would become too semantic and too expensive.

At the same time, collapsing topology, executable artifact, and source language into one layer would hide which invariants belong to pure graph algebra, which belong to validated execution, and which belong only to authoring syntax.

## Decision

Cortex adopts a three-layer stack:

- **Graph** owns pure topology and algebraic graph laws
- **Circuit** owns validated executable topology
- **Wire** owns source-level authoring and rewrite syntax over that topology

Within that stack, Wire is a closed-authority language:

- Wire may reference registered nodes, contracts, prompts, and wiring
- Wire may not invent new executors, tools, payload types, or domain authority
- edge semantics stay homogeneous; type meaning lives on ports and contracts defined outside Wire

The design rule is: Wire composes registered authority, and Haskell owns what the authority means.

## Alternatives considered

- **Make Wire a host language that invents executors, contracts, or rich edge semantics inline** — rejected because it would turn topology authoring into an open semantic programming surface and make rewrites harder to trust.
- **Collapse Graph, Circuit, and Wire into one undifferentiated layer** — rejected because pure graph laws, executable validation, and authoring syntax have different responsibilities and different invariants.
- **Put semantic meaning on edges rather than endpoints** — rejected because it makes the core graph model heavier and weakens cheap compatibility checks during composition and rewrite admission.

## Consequences

### Positive

- Wire remains small, mechanically checkable, and suitable for bounded rewrites.
- The substrate has explicit places for pure topology, executable artifacts, and authoring syntax.
- Contracts and executors stay owned by typed Haskell registries rather than by ad hoc source text.

### Negative

- Some seemingly convenient inline language features are ruled out on purpose.
- Authoring ergonomics must respect the closed-authority rule rather than reaching for general-purpose language escape hatches.

### Obligations

- Keep grammar growth aligned with topology authoring, not with general programming.
- Keep contract and executor authority outside Wire source.
- Maintain architecture docs so the Graph/Circuit/Wire split stays visible rather than collapsing back into "workflow" as one vague layer.

## Related

- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md)
- [../Architecture/04-graph-and-circuit.md](../Architecture/04-graph-and-circuit.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Reference/Wire/grammar.md](../Reference/Wire/grammar.md)
