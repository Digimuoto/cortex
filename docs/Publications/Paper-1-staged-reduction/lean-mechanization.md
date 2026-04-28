---
title: "Paper 1 — Lean 4 Mechanization Plan"
description:
  Paper-local Lean 4 plan for discharging the fixed-topology staged-reduction obligations used by
  the Staged Reduction manuscript.
date: 2026-04-28
updated: 2026-04-28
status: draft
related:
  - docs/Publications/Paper-1-staged-reduction/manuscript.md
  - docs/Publications/Paper-1-staged-reduction/lean-haskell-boundary.md
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Roadmap/Plans/lean-mechanization.md
---

# Paper 1 — Lean 4 Mechanization Plan

This note keeps the proof work for Paper 1 next to the manuscript.

The program-level plan in
[../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) still
matters, but this file is the paper-local contract: what must be mechanized before the manuscript
should stop calling itself a draft.

## Goal

Mechanize the fixed-topology staged-reduction kernel used by Paper 1:

- frontier computation over a finite DAG
- node-local fact accumulation
- failure closure
- lifecycle classification
- crash recovery after a persisted-prefix failure

The target is structural safety, not end-to-end workflow correctness.

## Exit Criteria

Paper 1 should stay `draft` until all of the following exist in Lean 4:

1. A machine-checked `wellFormedGraphState` predicate for normalized, closed recovered states.
   **Done** (`theory/Cortex/Pulse/Validity.lean`).
2. Proofs of the three closure laws for `propagateFailure`: extensiveness, monotonicity,
   idempotence. **Done** — `propagateFailure_extensive`, `propagateFailure_monotone`, and
   `propagateFailure_idempotent` are discharged in `theory/Cortex/Pulse/Closure.lean`.
3. A machine-checked structural recovery theorem matching Proposition 1 in the manuscript. **Done**
   (`persistence_safety` in `theory/Cortex/Pulse/Recovery.lean`), conditional on persisted
   topology-domain, output-ownership, output-completeness, and causal-history preconditions.
4. A machine-checked classification exhaustiveness theorem for normalized, closed states. **Done**
   (`classifyClosedGraphState_exhaustive_of_wellFormed` and
   `classifyGraphState_not_stuck_of_wellFormed` in `theory/Cortex/Pulse/Classify.lean`).
5. A short artifact note explaining the modeling boundary between the Lean kernel and the live
   Haskell runtime. **Done** ([lean-haskell-boundary.md](lean-haskell-boundary.md)).

## What Must Be Proved

Load-bearing theorems for the paper, with their current Lean status:

- `frontier_antichain` — done (`theory/Cortex/Pulse/Frontier.lean`)
- `applyNodeFact_comm` — done (`theory/Cortex/Pulse/Fact.lean`)
- `NodeResult.applyNodeFacts_perm_invariant` — done (`theory/Cortex/Pulse/Fact.lean`)
- `propagateFailure_extensive` — done (`theory/Cortex/Pulse/Closure.lean`)
- `propagateFailure_monotone` — done (`theory/Cortex/Pulse/Closure.lean`)
- `propagateFailure_idempotent` — done (`theory/Cortex/Pulse/Closure.lean`)
- normalization lemmas for `resetRunningToPending` — done (`theory/Cortex/Pulse/State.lean`,
  `Recovery.lean`)
- `frontierBridge` on normalized, closed states — done (`theory/Cortex/Pulse/Validity.lean`); the
  non-trivial bridge `readyNodes_eq_directReadyNodes` lives in the same file
- classification exhaustiveness on normalized, closed states — done
  (`theory/Cortex/Pulse/Classify.lean`)
- structural persistence safety after persisted-prefix crashes — done (`persistence_safety` in
  `theory/Cortex/Pulse/Recovery.lean`)

## What May Stay Abstract

These should be parameterized or axiomatized so the mechanization stays focused:

- payload values
- failure details
- signal payload contents
- worker internals and business semantics
- replayed I/O equivalence
- scheduler fairness and timing
- concrete map implementation details

The Lean model should be extensional: finite vertex type, status function, optional output function,
finite DAG relation.

## What Must Not Be Axiomatized

If these are assumed instead of proved, the mechanization adds too little:

- readiness / frontier semantics
- `applyNodeFact`
- `propagateFailure`
- closure laws
- `wellFormedGraphState`
- the main recovery theorem

## Lean Structure

The mechanization lives under `theory/Cortex/Pulse/` (rather than a separate `Paper1/` subtree, so
it can share the substrate's `theory/Cortex/Graph/` algebra with Paper 2):

```text
theory/Cortex/Pulse/
  DAG.lean        -- finite topology, edge-derived reachability, acyclicity
  State.lean      -- NodeStatus, GraphState, resetRunningToPending
  Fact.lean       -- NodeOutcome, NodeResult, applyNodeFact, Admissible
  Frontier.lean   -- Ready / DirectReady, antichain
  Closure.lean    -- propagateFailure, extensiveness, monotonicity, idempotence
  Validity.lean   -- wellFormedGraphState, frontier-bridge theorems
  Recovery.lean   -- recoveredState, persistence_safety
  Classify.lean    -- classifyGraphState, classification exhaustiveness
```

Build order followed by the existing artifacts:

1. finite DAG basics and reachability
2. state representation and `applyNodeFact`
3. frontier lemmas and antichain proof
4. closure operator laws
5. recovered-state validity
6. persisted-prefix recovery theorem
7. classification correctness

## Manuscript Mapping

| Manuscript section                               | Lean artifact                                                                                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Lemma 1: frontier antichain                      | `frontier_antichain` in `theory/Cortex/Pulse/Frontier.lean`                                                                                 |
| Lemma 2: disjoint-key accumulation commutativity | `NodeResult.applyNodeFact_comm` and `NodeResult.applyNodeFacts_perm_invariant` in `theory/Cortex/Pulse/Fact.lean`                           |
| Phase 2 closure laws                             | `propagateFailure_extensive`, `propagateFailure_monotone`, `propagateFailure_idempotent` in `theory/Cortex/Pulse/Closure.lean`              |
| Definition 1: valid recovered graph state        | `wellFormedGraphState` in `theory/Cortex/Pulse/Validity.lean`                                                                               |
| Proposition 1: structural persistence safety     | `persistence_safety` in `theory/Cortex/Pulse/Recovery.lean`                                                                                 |
| Phase 3 classification split                     | `classifyClosedGraphState_exhaustive_of_wellFormed` and `classifyGraphState_not_stuck_of_wellFormed` in `theory/Cortex/Pulse/Classify.lean` |

## Manuscript Notes

The mechanized obligations now have direct Lean references in the manuscript body. Remaining
manuscript-side guidance:

- keep Proposition 1's preconditions explicit — the Lean theorem is conditional on persisted
  topology-domain, output-ownership, output-completeness, and causal-history invariants that the
  runtime must establish
- keep the Lean-Haskell modeling boundary linked from the manuscript and synchronized with the Pulse
  runtime contract ([lean-haskell-boundary.md](lean-haskell-boundary.md))

## Immediate Next Steps

1. Keep the boundary note synchronized when `wellFormedGraphState`, recovery normalization, or Pulse
   persisted-state handling changes.

## Related

- [manuscript.md](manuscript.md) — Paper 1 manuscript.
- [index.md](index.md) — paper landing page.
- [lean-haskell-boundary.md](lean-haskell-boundary.md) — Lean-Haskell runtime boundary note.
- [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) —
  program-level plan shared with Paper 2.
