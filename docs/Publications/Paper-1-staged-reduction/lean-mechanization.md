---
title: "Paper 1 — Lean 4 Mechanization Plan"
description: Paper-local Lean 4 plan for discharging the fixed-topology staged-reduction obligations used by the Staged Reduction manuscript.
status: draft
related:
  - docs/Publications/Paper-1-staged-reduction/manuscript.md
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Roadmap/Plans/lean-mechanization.md
---

# Paper 1 — Lean 4 Mechanization Plan

This note keeps the proof work for Paper 1 next to the manuscript.

The program-level plan in [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) still matters, but this file is the paper-local contract: what must be mechanized before the manuscript should stop calling itself a draft.

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
2. Proofs of the three closure laws for `propagateFailure`: extensiveness, monotonicity, idempotence.
3. A machine-checked structural recovery theorem matching Proposition 1 in the manuscript.
4. A short artifact note explaining the modeling boundary between the Lean kernel and the live Haskell runtime.

## What Must Be Proved

These are the load-bearing theorems for the paper:

- `frontier_antichain`
- `applyNodeFact_comm`
- permutation invariance of accumulation over frontier results
- `propagateFailure_extensive`
- `propagateFailure_monotone`
- `propagateFailure_idempotent`
- normalization lemmas for `resetRunningToPending`
- `frontierExact` on normalized, closed states
- classification exhaustiveness on normalized, closed states
- structural persistence safety after persisted-prefix crashes

## What May Stay Abstract

These should be parameterized or axiomatized so the mechanization stays focused:

- payload values
- failure details
- signal payload contents
- worker internals and business semantics
- replayed I/O equivalence
- scheduler fairness and timing
- concrete map implementation details

The Lean model should be extensional: finite vertex type, status function, optional output function, finite DAG relation.

## What Must Not Be Axiomatized

If these are assumed instead of proved, the mechanization adds too little:

- readiness / frontier semantics
- `applyNodeFact`
- `propagateFailure`
- closure laws
- `wellFormedGraphState`
- the main recovery theorem

## Suggested Lean Structure

```text
Paper1/
  Graph.lean
  State.lean
  Fact.lean
  Frontier.lean
  Closure.lean
  Classify.lean
  Validity.lean
  Recovery.lean
  Examples.lean
```

The proofs should build in this order:

1. finite DAG basics and reachability
2. state representation and `applyNodeFact`
3. frontier lemmas and antichain proof
4. closure operator laws
5. recovered-state validity
6. classification correctness
7. persisted-prefix recovery theorem

## Manuscript Mapping

Map each paper claim to one Lean artifact:

| Manuscript section | Lean target |
|---|---|
| Lemma 1: frontier antichain | `Frontier.lean` |
| Lemma 2: disjoint-key accumulation commutativity | `Fact.lean` |
| Phase 2 closure laws | `Closure.lean` |
| Definition 1: valid recovered graph state | `Validity.lean` |
| Proposition 1: structural persistence safety | `Recovery.lean` |
| Phase 3 classification split | `Classify.lean` |

## Draft Notes for the Manuscript

Until the mechanization lands:

- keep Proposition 1 conditional on the closure laws
- keep the closure laws described as implementation lemmas, not settled theorems
- keep QuickCheck evidence as implementation support, not proof replacement

Once the mechanization lands:

- replace the “supported by QuickCheck and code inspection” wording with a direct pointer to the Lean artifact
- upgrade the recovery theorem from proof sketch plus obligations to a theorem backed by mechanization
- add a short artifact appendix or companion note summarizing the Lean model boundary

## Immediate Next Steps

1. Choose the finite DAG representation and recovered-state predicate names.
2. Write the extensional `GraphState` model before any theorem proofs.
3. Prove the frontier and accumulation lemmas first.
4. Only then attack closure idempotence and the recovery theorem.

## Related

- [manuscript.md](manuscript.md) — Paper 1 manuscript.
- [index.md](index.md) — paper landing page.
- [../../Roadmap/Plans/lean-mechanization.md](../../Roadmap/Plans/lean-mechanization.md) — program-level plan shared with Paper 2.
