---
title: "Paper 2 — Algebraic Foundations"
description:
  Landing page for the Algebraic Foundations paper. Abstract, status, figures, and related material.
sidebar:
  label: Paper 2
  order: 2
status: superseded
date: 2026-04-28
updated: 2026-06-10
related:
  - docs/Publications/Paper-1-staged-reduction/
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Roadmap/Plans/lean-mechanization.md
  - docs/Roadmap/Plans/rewrite-materialization-and-recovery.md
---

# Paper 2 — Algebraic Foundations

The algebraic calculus of fixed-topology staged durable execution. **Superseded:** this material is
merged into [Paper 1](../Paper-1-staged-reduction/), which now carries the algebraic framing, the
forward-fragment order, the extension-boundary analysis, and the results table citing the delivered
Lean mechanization. The directory is retained until Paper 1's submission freeze, then removed.

## Status

Superseded by the merged Paper 1 manuscript. The manuscript here is kept for reference; do not edit
it further.

## Abstract

This paper isolates the fixed-topology algebraic kernel of Cortex durable execution: node-local fact
accumulation, failure closure, deterministic classification, and structural recovery safety after
partial persistence. It also marks the extension boundary where those results stop carrying over and
a different machine is required.

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export status.
- Publication-exported figures are not checked in yet.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [../Paper-1-staged-reduction/](../Paper-1-staged-reduction/) — staged reduction refining this
  calculus.
- [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) —
  supporting research plan for mechanized proofs.
- [../../Roadmap/Plans/rewrite-materialization-and-recovery.md](../../Roadmap/Plans/rewrite-materialization-and-recovery.md)
  — runtime rewrite plan building on this extension boundary.
- [../Paper-3-graph-substitution-semantics/](../Paper-3-graph-substitution-semantics/) —
  substitution extension of this.
- [../../Architecture/03-formalism-stack.md](../../Architecture/03-formalism-stack.md) —
  architecture chapter citing this paper.
