---
title: "ADR 0008 — Pulse Operator Visibility Surfaces"
description: "Pulse operator visibility is built from append-only run events and graph-native inspection rather than inferred mutable state alone."
sidebar:
  label: "0008. Operator visibility"
  order: 8
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/events.md
  - docs/Reference/Pulse/service-api.md
---

# ADR 0008 — Pulse Operator Visibility Surfaces

## Status

Accepted — append-only run events and graph-native admin inspection are now part of the runtime's operator contract.

## Context

Mutable run rows, checkpoints, and stage logs are necessary for execution, but they are not enough for operators. Once Pulse became graph-native and rewrite-capable, operators needed to answer questions that mutable state alone does not answer well:

- what happened to this run over time
- why is it blocked or waiting now
- which rewrites were proposed or applied
- what budget and topology changes produced the current state

Relying on host logs or task-specific reconstruction would make inspection partial and inconsistent.

## Decision

Pulse exposes operator visibility through two first-class surfaces:

- an append-only per-run event history for lifecycle-significant facts
- graph-native run inspection that exposes the materialized execution state in terms of rewrites, waiting and blocked diagnostics, and graph evolution

These surfaces supplement mutable runtime state rather than being inferred from it after the fact. Event recording is best-effort and must never block run progress, but the operator model itself is part of the runtime contract.

## Alternatives considered

- **Infer operator history from mutable run rows and stage logs only** — rejected because rewrite-capable graph execution loses too much explanatory structure when collapsed to latest state plus attempt history.
- **Rely on observability logs outside the runtime contract** — rejected because operators need queryable per-run facts, not just external log streams.
- **Build task-specific inspection paths in each host product for each workflow kind** — rejected because graph-native visibility belongs to the generic runtime, not to each downstream product task.

## Consequences

### Positive

- Operators get a stable way to inspect lifecycle transitions and graph evolution.
- Runtime explanation is expressed in graph terms instead of in task-specific ad hoc language.
- Later admin and UI surfaces can build on one durable inspection substrate.

### Negative

- The runtime must persist and query more than the minimum needed to execute.
- Operator surface design becomes part of the core architecture rather than optional tooling.

### Obligations

- Keep new lifecycle-significant transitions visible through run events or graph inspection, not only through logs.
- Preserve the graph-native vocabulary of blocked, waiting, rewritten, and materialized state.
- Avoid baking task-specific explanation formats into the generic Pulse surfaces.

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
- [../Reference/Pulse/events.md](../Reference/Pulse/events.md)
- [../Reference/Pulse/service-api.md](../Reference/Pulse/service-api.md)
