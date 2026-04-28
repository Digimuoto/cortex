---
title: "Wire Reference — Partials and Execution Boundary"
description: Scoped reference for partial nodes in graph position, the port-determined rule, and the evaluation-boundary check.
sidebar:
  label: Partials and execution
  order: 4
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/rewrites.md
  - docs/Architecture/05-wire-language.md
---

# Wire Reference — Partials and Execution Boundary

> **Stub.** This page is a scoped entry point into the partial-node and execution-boundary rules in [grammar.md](grammar.md). Until it is fleshed out, jump directly to the grammar sections below.

## Where the rules live

- **[§5.4 Partial nodes in graph position](grammar.md#54-partial-nodes-in-graph-position)** — the **port-determined rule**. Whether a partial may appear in graph position depends only on the partial and the registry; no whole-expression inference.
- **[§11 Type-checking summary](grammar.md#11-type-checking-summary)** — well-formedness checks; evaluation-boundary check for runnable wires.

For the `//`-on-partials rule (`base // { delta }` producing a new partial), see **[§5.3 Config merge on partial nodes](grammar.md#53-config-merge-on-partial-nodes)**, covered in the [Executors and the alphabet](./executors-and-alphabet.md) stub.

Executor registration, application, and config-merge rules are covered separately in [Executors and the alphabet](./executors-and-alphabet.md). The rewrite algebra, admission, and materialization — the runtime-side picture — are in the [Rewrites reference](../rewrites.md); this page does not restate them.

## Summary of the rules

- A **partial node** `@executor { config }` is a staged value with no ports pinned. Mergeable with `//`, pinnable via a `node` declaration.
- A partial may appear in graph position **iff its executor is port-determined** — its structural constraints uniquely pin its port signature from config alone. Port-polymorphic executors must be pinned via `node` declaration first.
- The rule is **local**: admissibility depends only on the partial and the registry, not on the enclosing expression tree.
- **Well-typed wires may have open boundaries.** An unconnected singular input is permitted on any well-typed wire.
- The **evaluation-boundary check** is stricter: a wire prepared for execution must have every singular input connected exactly once. This check runs at evaluation-preparation, not at compile time.

See the grammar for the full definitions.
