---
title: "Paper 3 — Graph Substitution Semantics"
description:
  Landing page for the Graph Substitution Semantics paper. Abstract, status, figures, and related
  material.
sidebar:
  label: Paper 3
  order: 3
status: draft
date: 2026-04-28
updated: 2026-04-28
related:
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Roadmap/Plans/rewrite-materialization-and-recovery.md
  - docs/Architecture/07-rewrites-and-materialization.md
---

# Paper 3 — Graph Substitution Semantics

## Status

Draft manuscript. See [manuscript.md](manuscript.md) for the full text.

## Abstract

This paper develops the implementation-independent theory of dynamic durable workflow execution by
graph substitution. It separates workflow meaning, compiled executable structure, and phase-based
durable execution, then shows how lineage, materialization, and interface admissibility give
topology change an explicit semantic boundary.

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export status.
- Mermaid figure sources are checked in for the main architecture and runtime diagrams.
- Publication-exported vector figures are not checked in yet.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [../Paper-2-algebraic-foundations/](../Paper-2-algebraic-foundations/) — algebraic base extended
  here.
- [../../Roadmap/Plans/rewrite-materialization-and-recovery.md](../../Roadmap/Plans/rewrite-materialization-and-recovery.md)
  — runtime-grounded rewrite plan realizing this substitution model.
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md)
  — architecture chapter.
