---
title: "Paper 1 — Staged Reduction"
description:
  Landing page for the Staged Reduction paper. Abstract, status, figures, and related material.
sidebar:
  label: Paper 1
  order: 1
status: draft
date: 2026-04-28
updated: 2026-04-28
related:
  - docs/Publications/Paper-1-staged-reduction/manuscript.md
  - docs/Publications/Paper-1-staged-reduction/lean-haskell-boundary.md
  - docs/Publications/Paper-1-staged-reduction/lean-mechanization.md
---

# Paper 1 — Staged Reduction

Staged reduction for durable workflow execution over fixed DAG topology. The paper argues that
incremental persistence is structurally safe because recovery normalizes partially persisted state
and reapplies failure closure before lifecycle classification.

## Status

Draft manuscript. See [manuscript.md](manuscript.md) for the full text.

The fixed-topology kernel is mechanized in Lean 4 under `theory/Cortex/Pulse/`, including the
structural recovery theorem (`persistence_safety`), frontier antichain, disjoint-key accumulation
commutativity, fold permutation invariance, classification exhaustiveness, and the extensiveness,
monotonicity, and idempotence closure laws. The Lean-Haskell modeling boundary is documented in
[lean-haskell-boundary.md](lean-haskell-boundary.md).

## Abstract

The manuscript presents a durable workflow runtime organized as a staged pure reduction over fixed
algebraic graph topology. Its central claim is deliberately narrow: crash recovery after partial
persistence remains structurally safe because normalization and failure closure restore a valid
schedulable state before classification resumes.

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export notes.
- [staged-reduction-overview.mmd](Figures/staged-reduction-overview.mmd) — source for the
  staged-reduction overview figure used in the manuscript.
- Publication-exported figures are not checked in yet.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [lean-mechanization.md](lean-mechanization.md) — paper-local Lean 4 plan and draft exit criteria.
- [lean-haskell-boundary.md](lean-haskell-boundary.md) — companion note on the Lean model and
  Haskell runtime boundary.
- [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) —
  program-level mechanization plan shared with Paper 2.
- [../Paper-2-algebraic-foundations/](../Paper-2-algebraic-foundations/) — companion algebraic
  foundations paper.
