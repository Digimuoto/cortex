---
title: "Paper 4 — Wire Language"
description: Landing page for the Wire Language paper. Abstract, status, figures, and related material.
sidebar:
  label: Paper 4
  order: 4
status: draft
date: 2026-04-24
updated: 2026-04-28
related:
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
---

# Paper 4 — Wire Language

Wire is the author-facing language layer of Cortex: a small graph language for composing registered authority into executable topology and bounded structural proposals.

## Status

Draft manuscript. See [manuscript.md](manuscript.md) for the full text.

## Abstract

This paper presents Wire, a source language for authoring typed workflow and reasoning graphs above the Cortex substrate. Its central claim is that authoring should keep **authority closed** and **composition open**: executors, contracts, tools, and policy are registered externally, while the language itself exposes a small algebra for composing them into executable graphs and candidate rewrite fragments. The paper argues for homogeneous topological edges, endpoint-owned compatibility, partial-node reuse, and a shared authoring surface for both initial topology and bounded structural proposals.

## Figures

- [Figures/index.md](Figures/index.md) — figure inventory and export status.
- [wire-layering-overview.mmd](Figures/wire-layering-overview.mmd) — source for the main Wire layering figure.
- Publication-exported vector figures are not checked in yet.

## Related

- [manuscript.md](manuscript.md) — full manuscript.
- [../Paper-2-algebraic-foundations/](../Paper-2-algebraic-foundations/) — algebraic substrate beneath Wire.
- [../Paper-3-graph-substitution-semantics/](../Paper-3-graph-substitution-semantics/) — substitution and materialization semantics that Wire hands off to.
- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — architecture chapter.
- [../../Reference/Wire/grammar.md](../../Reference/Wire/grammar.md) — current normative grammar surface.
