---
title: "Paper 5 — Causal Programming"
description:
  Landing page for the Causal Programming paper. Abstract, status, figures, and related material.
sidebar:
  label: Paper 5
  order: 5
status: draft
date: 2026-05-04
updated: 2026-06-10
related:
  - docs/Publications/Paper-1-staged-reduction/
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Publications/Paper-4-wire-language/
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/proof-status.md
---

# Paper 5 — Causal Programming

Causal programming is the paradigm umbrella over the Cortex papers: computation modeled as typed,
partially ordered event flow, with **temporal honesty** — the program asserts no more temporal order
than the computation possesses — as the foundational property.

## Status

Draft manuscript, position-paper shape. See [manuscript.md](manuscript.md) for the full text. Vision
venue or journal target; the demonstrations (quantum eraser on IBM hardware, production agentic
system) double as evidence sections for the technical papers.

## Abstract

Mainstream languages inherit a single-stack model that is dishonest about the temporal structure of
distributed, durable, concurrent, and agentic systems. The paper makes three nested claims: a
semantic diagnosis (many engineering burdens are the cost of reconstructing causal structure the
language erased), a paradigm proposal (causal programming, organized around eight structural
commitments), and an existence proof (Wire and the Pulse runtime, mechanized in Lean 4, show the
proposal is workable and its central claims tractable to prove).

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export status.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [../Paper-1-staged-reduction/](../Paper-1-staged-reduction/) — fixed-topology runtime kernel the
  paradigm executes on.
- [../Paper-4-wire-language/](../Paper-4-wire-language/) — the authoring language used as the
  existence proof.
- [../../Reference/proof-status.md](../../Reference/proof-status.md) — verification numbers cited by
  the manuscript.
