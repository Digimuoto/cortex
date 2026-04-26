---
title: "Research Memo: Cortex Formalism Stack Synthesis"
description: Compact synthesis of the formal layers Cortex uses for topology, execution intent, and structural authority.
---

# Research Memo: Cortex Formalism Stack Synthesis

**Date:** 2026-04-11
**Scope:** Cortex graph topology, Pulse execution outcomes, Wire/Circuit
authoring boundaries, and the algebraic split needed for rewrite-capable
execution.
**Method:** Retained synthesis note, rewritten after Cortex became a standalone
repository to remove stale branch and consumer-path detail.
**Confidence profile:** high on the layer split; medium on the exact formal
presentation that should appear in papers and mechanization.

## Executive Summary

Cortex wants several small formal layers, not one universal metaphor.

The graph layer is algebraic topology: `Empty`, `Vertex`, `Overlay`, and
`Connect` describe causal shape and lower to relations. Pulse then interprets
that topology through a small execution outcome surface. Rewrites are a third
thing again: bounded structural authority over a materialized graph.

The useful split is:

- **Topology algebra** - what may depend on what.
- **Intent/effect algebra** - what a vertex may do when evaluated.
- **Authority algebra** - how much structural change a vertex may propose.

This explains the implementation better than treating the runtime as a single
graph monad. Graphs describe structure; Pulse interprets node outcomes;
rewrites are admitted through a separate authority boundary.

## Findings

### Topology Is Not Execution

`Cortex.Graph` gives Cortex a small topology language and analysis substrate.
That layer should remain pure: it should know about vertices, edges, reachability,
DAG validation, and graph traversal, not about checkpoints, host actions, model
calls, signals, or product policy.

The runtime consumes topology; it should not be smuggled back into the graph
layer.

### Pulse Has A Small Handled-Effect Kernel

Pulse stage execution is centered around a narrow outcome surface:

- complete with output
- suspend on signal
- complete with output and propose a structural rewrite

The executor handles those outcomes into durable state transitions,
checkpointing, frontier scheduling, signal waiting, rewrite admission, and
terminal classification.

Naming this as an execution-intent layer is useful because replay policy,
timeout behavior, side-effect classification, signal waiting, and operator
explanation can hang off the same small surface instead of being hidden inside
task-specific code.

### Closed Branch Choice Differs From Open Rewrite

Closed-world conditionals and open-world planner rewrites should not be treated
as the same semantic phenomenon.

A closed conditional chooses among known continuations. Its branches are part of
the compiled artifact, and the runtime materializes the selected branch. This
resembles selective continuation choice: possible future obligations are known,
but only one path is activated.

An open rewrite proposes new future topology within a bounded authority budget.
It needs admission, structural validation, budget accounting, and provenance.

The runtime may implement both through shared materialization machinery, but the
formal semantics and operator explanation should keep them distinct.

### Rewrite Is Structural Authority

Runtime graph rewriting is budgeted relation surgery over the materialized
graph. It is not arbitrary mutation and not general computation in the source
language.

The authority question is separate from node intent:

- who may propose topology change?
- which rewrite forms are allowed?
- which anchors and interfaces are valid?
- how much gas remains?
- what provenance and recovery facts are persisted?

This suggests a small structural-authority lattice, for example:

```text
NoChange < ChooseKnownContinuation < Append < ExpandEnvelope < ExpandReplace
```

The exact order may change, but the architectural point should stay: structural
authority is explicit and bounded.

### Contract Witnesses Are The Main Theory Gap

The paper-level story wants compiled artifacts with interface environments,
compatibility witnesses, effect classes, and authority classes. The
implementation has the beginning of this through Circuit/Wire contracts and
runtime rewrite validation, but the full witness discipline is not yet the
central API.

That gap is the right place to invest if Cortex wants reusable fragments,
stronger artifact contracts, and safer rewrite composition.

### Concurrent Rewrite Admission Is A Proof Problem

Admitting multiple same-wave rewrites is not just a scheduler optimization. It
requires a commutation or independence law:

- compatible anchors
- non-overlapping interface effects
- deterministic budget composition
- stable replay ordering

Until that law exists, deterministic ordered admission is the conservative
runtime contract.

## Consequences

The formal stack should be presented as layered:

1. Graph topology.
2. Circuit/Wire authoring and compatibility.
3. Pulse execution outcomes.
4. Rewrite authority and materialization.
5. Artifact, memory, and provenance surfaces above execution.

This keeps proofs and docs from upgrading implementation convenience into
semantics. It also makes downstream examples clearer: a consumer registers
authority and product meaning into Cortex; it does not redefine the substrate.

## Related

- [../../Architecture/03-formalism-stack.md](../../Architecture/03-formalism-stack.md)
- [../../Architecture/04-graph-and-circuit.md](../../Architecture/04-graph-and-circuit.md)
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md)
- [../../Publications/Paper-2-algebraic-foundations/](../../Publications/Paper-2-algebraic-foundations/)
- [../../Publications/Paper-3-graph-substitution-semantics/](../../Publications/Paper-3-graph-substitution-semantics/)
