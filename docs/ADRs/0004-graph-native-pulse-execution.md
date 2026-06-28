---
title: "ADR 0004 — Graph-Native Pulse Execution"
description:
  "Pulse executes algebraic graph topology directly rather than treating graphs as presentation over
  linear stage counters."
sidebar:
  label: "0004. Graph-native execution"
  order: 4
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
---

# ADR 0004 — Graph-Native Pulse Execution

## Status

Accepted — graph-native execution semantics replaced linear stage plans and the later runtime work
builds on that substrate.

## Context

Linear stage lists are easy to schedule, but they misrepresent the workflows Cortex needs to
execute:

- fan-out and join become awkward encodings instead of first-class topology
- ready work is derived from stage position rather than predecessor satisfaction
- restart and inspection center on counters rather than on the actual graph state

Cortex's broader direction is graph-native: Wire authors topology, Circuit validates executable
topology, and Pulse executes that topology durably. The runtime therefore needed to stop treating
graphs as a UI or planning convenience over an imperative core.

## Decision

Pulse executes graph topology directly.

- the execution topology is a graph relation derived from the algebraic graph layer
- ready work is computed from predecessor satisfaction over the current relation
- suspension, resume, and recovery operate over graph state, not stage counters
- legacy linear workflows remain valid only as the degenerate path case inside the graph model

The runtime model is therefore partial-order native. Scheduling is over frontiers of ready nodes,
not over "current stage index plus next stage."

## Alternatives considered

- **Keep a linear executor and treat graphs as presentation only** — rejected because it hides the
  real execution semantics and makes fan-out, joins, and inspection unnatural.
- **Encode workflow behavior as imperative control flow inside large stage bodies** — rejected
  because it weakens replay, operator visibility, and structural validation.
- **Introduce graph notation only at authoring time, then erase it before runtime** — rejected
  because the runtime still needs graph semantics for correctness and recovery.

## Consequences

### Positive

- Fan-out, joins, and frontier concurrency are natural runtime concepts.
- Recovery and inspection can talk about graph state directly.
- Later rewrite and memory work compose onto one execution model instead of replacing it.

### Negative

- The runtime must own graph analysis and validation machinery, not just a scheduler loop.
- More subsystems now depend on graph identity and topology stability.

### Obligations

- Keep linear compatibility as a degenerate case rather than as a separate runtime path.
- Keep graph semantics below Pulse-specific IO and persistence concerns.
- Explain new runtime features in graph-native terms rather than reintroducing stage-list
  vocabulary.

## Traceability

- Feature keys: `pulse.graph_native_execution`
- Public surface: `Cortex.Pulse`, `docs/Architecture/06-pulse-runtime.md`
- Implementation: `src/Cortex/Pulse/GraphRuntime.hs` (`readyNodes`, `predecessors` — ready work from
  predecessor satisfaction over the graph relation), `src/Cortex/Pulse/Plan.hs` (`StagePlan`),
  `src/Cortex/Pulse/Executor/Loop.hs` (frontier-wave scheduling)
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`, `test/Cortex/Pulse/GraphRewriteSpec.hs`
- Theory/proof:
  [Graph safety / Graph quotient rows — `proof-status.md`](../Reference/proof-status.md) (Lean
  `theory/Cortex/Pulse/DAG.lean`, `theory/Cortex/Graph/Safety.lean`)

## Related

- [../Architecture/04-graph-and-circuit.md](../Architecture/04-graph-and-circuit.md)
- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
