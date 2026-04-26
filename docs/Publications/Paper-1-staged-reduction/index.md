---
title: "Paper 1 — Staged Reduction"
description: Landing page for the Staged Reduction paper. Abstract, status, figures, and related material.
sidebar:
  label: Paper 1
  order: 1
status: draft
---

# Paper 1 — Staged Reduction

Staged reduction for durable workflow execution over fixed DAG topology. The paper argues that incremental persistence is structurally safe because recovery normalizes partially persisted state and reapplies failure closure before lifecycle classification.

## Status

Draft manuscript. See [manuscript.md](manuscript.md) for the full text.

This paper stays `draft` until the fixed-topology kernel claims used by the manuscript are backed by the Lean 4 work tracked in [lean-mechanization.md](lean-mechanization.md).

## Abstract

The manuscript presents a durable workflow runtime organized as a staged pure reduction over fixed algebraic graph topology. Its central claim is deliberately narrow: crash recovery after partial persistence remains structurally safe because normalization and failure closure restore a valid schedulable state before classification resumes.

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export notes.
- [staged-reduction-overview.mmd](Figures/staged-reduction-overview.mmd) — source for the staged-reduction overview figure used in the manuscript.
- Publication-exported figures are not checked in yet.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [lean-mechanization.md](lean-mechanization.md) — paper-local Lean 4 plan and draft exit criteria.
- [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) — portfolio-level mechanization plan shared with Paper 2.
- [../Paper-2-algebraic-foundations/](../Paper-2-algebraic-foundations/) — companion algebraic foundations paper.
