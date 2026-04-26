---
title: "ADR 0012 — Topological Memory as Deterministic Graph Query"
description: "Memory is a deterministic stage-entry query over settled graph state, with the read surface selected per node."
sidebar:
  label: "0012. Topological memory"
  order: 12
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Wire/partials-and-execution-boundary.md
---

# ADR 0012 — Topological Memory as Deterministic Graph Query

## Status

Accepted — topological memory and per-node memory strategy are now part of the shipped runtime and Wire surface.

## Context

Classic chain-scoped inputs work for simple linear flows, but they are too narrow for graph-native workflows where a node may need principled access to settled upstream observations beyond its direct input bundle. At the same time, turning memory into a separate mutable store would weaken replay, inspection, and causal clarity.

The runtime needed a memory surface that respects graph topology, remains deterministic, and does not blur past observations with live orchestration state.

## Decision

Define memory as a deterministic graph query over settled graph state at stage entry.

- memory is read from the Pulse substrate, not from a separate mutable memory database
- the snapshot is bound at stage entry so same-frontier execution does not bleed into the current node's view
- the memory read surface is selected per node through declared strategy rather than by one global runtime switch

Classic direct-input reads remain valid, but topological memory is the graph-native read model when a node needs broader settled context.

## Alternatives considered

- **Keep memory as direct chain inputs only** — rejected because graph-native review and rewrite nodes need a principled way to read settled upstream context beyond one chain-shaped bundle.
- **Introduce a separate mutable memory store** — rejected because it would weaken determinism and make memory diverge from the actual graph substrate.
- **Use only a run-level environment override** — rejected because memory policy belongs to node semantics and workflow authoring, not to one global toggle.

## Consequences

### Positive

- Memory reads stay tied to durable graph state and causal topology.
- Per-node strategy keeps the read surface explicit in the authoring layer.
- Review and rewrite nodes can ground themselves in settled upstream evidence without violating replay discipline.

### Negative

- Memory policy becomes part of workflow authoring and runtime metadata.
- The runtime has to maintain walk, scoring, and snapshot rules as semantic infrastructure rather than as incidental helpers.

### Obligations

- Keep topological memory restricted to settled observations rather than live orchestration state.
- Preserve stage-entry snapshot semantics.
- Add new memory strategies only as explicit runtime surfaces with clear semantics.

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
- [../Reference/Wire/partials-and-execution-boundary.md](../Reference/Wire/partials-and-execution-boundary.md)
