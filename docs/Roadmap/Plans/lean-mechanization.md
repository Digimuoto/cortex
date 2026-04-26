---
title: Lean Mechanization Research Plan
description: Research plan for mechanizing the fixed-topology staged-reduction core in Lean 4.
sidebar:
  label: Lean mechanization
  order: 3
status: proposed
related:
  - docs/Publications/Paper-1-staged-reduction/
  - docs/Publications/Paper-2-algebraic-foundations/
---

# Lean Mechanization Research Plan

**Status:** proposed
**Scope:** machine-checked support for the fixed-topology staged-reduction core
used by Papers 1 and 2

## Summary

This plan turns the fixed-topology staged-reduction core into a Lean 4
mechanization target. The goal is not end-to-end workflow correctness or
replayed I/O equivalence. The goal is to mechanize the structural safety
contract the runtime actually relies on: commutative accumulation of node-local
facts, idempotent failure closure, deterministic classification, and recovery
safety after persisted-prefix crashes.

The central artifact is an explicit `wellFormedGraphState` predicate for
normalized, closed states. Without that predicate, Paper 1's recovery claim and
Paper 2's algebraic presentation remain too rhetorical.

## Core Definitions

Mechanization starts by fixing the objects the paper set depends on:

- finite DAGs with reachability and topological order
- `NodeStatus`
- `GraphState`
- `applyNodeFact`
- `resetRunningToPending`
- `propagateFailure`
- `readyNodes`
- `classifyGraphState`

The hub predicate should be:

```lean
def wellFormedGraphState (G : DAG) (s : GraphState) : Prop :=
  statusDomainExact G s
  ∧ outputDomainWithinTopology G s
  ∧ outputsRespectStatuses s
  ∧ noRunningNodes s
  ∧ failureClosureComplete G s
  ∧ frontierExact G s
```

Here `frontierExact` means `readyNodes G s` is sound and complete for the
readiness predicate.

## Theorem Stack

### Tier 1: Core algebraic lemmas

```lean
theorem frontier_antichain (G : DAG) (s : GraphState) :
  PairwiseReachabilityIncomparable (readyNodes G s)
```

```lean
theorem applyNodeFact_comm (r1 r2 : NodeResult) (s : GraphState)
  (h : r1.nid ≠ r2.nid) :
  applyNodeFact r1 (applyNodeFact r2 s) =
  applyNodeFact r2 (applyNodeFact r1 s)
```

```lean
theorem fold_applyNodeFact_perm
  (results1 results2 : List NodeResult) (s : GraphState)
  (h_perm : results1 ~ results2)
  (h_distinct : results1.Pairwise (fun a b => a.nid ≠ b.nid)) :
  results1.foldl (flip applyNodeFact) s =
  results2.foldl (flip applyNodeFact) s
```

### Tier 2: Closure operator laws

```lean
theorem propagateFailure_extensive (G : DAG) (s : GraphState) :
  s ≤ propagateFailure G s
```

```lean
theorem propagateFailure_monotone (G : DAG) (s1 s2 : GraphState)
  (h : s1 ≤ s2) :
  propagateFailure G s1 ≤ propagateFailure G s2
```

```lean
theorem propagateFailure_idempotent (G : DAG) (s : GraphState) :
  propagateFailure G (propagateFailure G s) = propagateFailure G s
```

### Tier 3: Recovery normalization

```lean
theorem resetRunning_preserves_domains (G : DAG) (s : GraphState) :
  domainsPreserved G s (resetRunningToPending s)
```

```lean
theorem resetRunning_no_running (s : GraphState) :
  noRunningNodes (resetRunningToPending s)
```

```lean
theorem closure_failure_complete (G : DAG) (s : GraphState) :
  failureClosureComplete G (propagateFailure G s)
```

```lean
theorem frontier_exact_closed (G : DAG) (s : GraphState)
  (h_norm : noRunningNodes s)
  (h_closed : failureClosureComplete G s) :
  frontierExact G s
```

### Tier 4: Structural recovery safety

```lean
theorem persistence_safety
  (G : DAG) (S' : List NodeResult) (s0 : GraphState) :
  let sPersisted := S'.foldl (flip applyNodeFact) s0
  let sRecovered := propagateFailure G (resetRunningToPending sPersisted)
  wellFormedGraphState G sRecovered
```

This is the load-bearing theorem for the crash-recovery model. It should match
Paper 1's structural persistence-safety claim and Paper 2's recovery theorem in
intent.

## Explicit Non-Goals

Do not expand this plan into:

- end-to-end workflow correctness
- replayed I/O equivalence
- dynamic graph rewriting correctness
- operator-facing persistence semantics

Those belong either to assumptions outside the fixed-topology kernel or to the
separate rewrite-materialization track.

## Suggested Lean Module Structure

```text
DurableTask/
  Graph.lean
  State.lean
  Fact.lean
  Closure.lean
  Classify.lean
  Validity.lean
  Properties/
    Antichain.lean
    Commutativity.lean
    Closure.lean
    Recovery.lean
    Safety.lean
```

`Validity.lean` should appear early, not as an afterthought. The point of this
plan is to make valid graph state a first-class theorem object.

## Expected Challenges

- Finite DAG representation may need an adapter from the runtime's relation-style graph model.
- Closure idempotence is the hardest proof burden in the current stack.
- `Waiting(signal)` complicates any local status order because waiting carries data.
- `outputsRespectStatuses` should be stated so later rewrite theory can extend it without contradiction.

## Relationship to the Paper Set

- **Paper 1** uses the theorems operationally and reports implementation evidence.
- **Paper 2** states the sharpened algebraic claims and separates proof from assumption.
- **This plan** is where closure laws and structural recovery safety become machine-checked.

The paper set should share the same names for:

- `wellFormedGraphState`
- disjoint-key accumulation commutativity
- structural persistence safety
- piecewise determinism assumption

If the names drift, the portfolio becomes incoherent again.

## Internal Value

This plan provides three concrete benefits:

- it turns the recovery contract into an executable specification
- it forces later extensions to name the invariant they depend on
- it prevents implementation tests from being rhetorically upgraded into proofs

## Related

- [../../Publications/Paper-1-staged-reduction/](../../Publications/Paper-1-staged-reduction/) — runtime-grounded fixed-topology paper.
- [../../Publications/Paper-2-algebraic-foundations/](../../Publications/Paper-2-algebraic-foundations/) — algebraic companion paper.
- [rewrite-materialization-and-recovery.md](rewrite-materialization-and-recovery.md) — separate plan for dynamic topology.
