---
title: "Wire Reference — Configured Executors and Execution Boundary"
description:
  Scoped reference for configured executor values, explicit node admission, and the boundary between
  Wire source and Pulse runtime execution.
sidebar:
  label: Configured executors
  order: 4
status: draft
date: 2026-04-29
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/rewrites.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
---

# Wire Reference — Configured Executors and Execution Boundary

Configured executor values are reusable authority/config values:

```wire
let analyst = @llm.analyst {
  temperature = 0.2 ;
} ;
```

They are not nodes. They have no graph identity, no typed port boundary, and no place in graph
composition. A configured executor becomes executable only when an explicit `node` declaration
admits it into graph position:

```wire
node analyze
  <- evidence: EvidenceSet ;
  -> analysis: AnalysisRecord ;
  = analyst (evidence) ;
```

## Boundary Rules

- `@qualified.name { ... }` stages registered authority with inert config data.
- A node declaration supplies the graph identity and typed port boundary.
- Once admitted into graph position, every executor invocation has a concrete typed port boundary.
- The boundary may be authored directly and then checked against a registered projection; it is not
  inferred from neighboring graph expressions.
- Configured executors cannot appear on either side of `<>` or `=>`.
- There is no implicit fan-in, list aggregation, or context concatenation at the graph boundary.

## Evaluation Boundary

Wire type-checking admits graph values with open boundaries. Runtime preparation is stricter:
required input boundaries must be supplied before Pulse evaluates the circuit.

Pulse evaluates materialized nodes only after the compiler and binding layer have established:

- executor identity;
- validated config;
- concrete input/output ports;
- known contract schemas;
- effect class and host authority;
- output validation path.

The runtime may still observe provider failures, invalid outputs, timeouts, cancellation, or host
errors. Those are runtime failures of admitted authority, not new authority discovered during
execution.

## Memory And Retrieval

Executor config may grant memory or retrieval authority:

```wire
memory = topological { preset = "analyst" ; } ;
```

That authority belongs to the executor binding. It is legal as registered config/tool authority, but
it is not hidden node-to-node message passing and not part of the proven Wire topology core.

## Relationship To Rewrites

Runtime rewrites can introduce or replace executor nodes only if the resulting graph passes the same
admission boundary:

- executor exists;
- config validates;
- concrete ports are typed;
- contracts are known;
- host authority remains explicit;
- topology invariants and rewrite budgets are preserved.

See [Rewrites](../rewrites.md) for materialization and admission details.
