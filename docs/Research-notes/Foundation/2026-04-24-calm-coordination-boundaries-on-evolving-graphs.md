---
title: "Research Memo: CALM and Coordination Boundaries on Evolving Graphs"
description:
  Reading Cortex as a monotone execution substrate with a coordinated non-monotone substitution
  boundary, plus implications for rewrite admission.
date: 2026-04-24
status: active
related:
  - docs/Publications/Paper-2-algebraic-foundations/
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Publications/Notes/deterministic-multi-rewrite-admission.md
---

# Research Memo: CALM and Coordination Boundaries on Evolving Graphs

**Date:** 2026-04-24 **Scope:** Cortex staged reduction, rewrite admission/materialization, current
papers 2 and 3, runtime docs, and external coordination-avoidance literature **Artifacts examined:**
`src/Cortex/Pulse/GraphRuntime.hs`, `src/Cortex/Pulse/Rewrite.hs`, `src/Cortex/Pulse/Executor/*`,
papers 2 and 3, architecture chapters 06 and 07, the deterministic multi-rewrite admission note, and
selected CALM / I-confluence literature **Method:** implementation-first cross-reference synthesis
with targeted literature check **Confidence profile:** high on the local Runtime/paper alignment;
medium-high on the CALM framing; medium on stronger "minimality" claims that would need a dedicated
formal model

**External literature checked:**

- [Consistency Analysis in Bloom: a CALM and Collected Approach](https://db.cs.berkeley.edu/papers/cidr11-bloom.pdf)
- [Relational transducers for declarative networking](https://arxiv.org/abs/1012.2858)
- [Coordination Avoidance in Database Systems](https://www.vldb.org/pvldb/vol8/p185-bailis.pdf)

---

## Executive Summary

The strongest new framing is that Cortex already separates two different semantic fragments:

- a **within-topology reduction fragment** that accumulates node-local facts over a fixed
  materialized graph
- a **cross-topology substitution fragment** that changes the graph itself through rewrite admission
  and materialization

That split aligns cleanly with the CALM line of work. The reduction kernel described in Paper 2 is
the coordination-friendly fragment: frontier execution is order-insensitive, fact accumulation is
disjoint-key commutative, and closure/classification are deterministic over the resulting normalized
state. Rewrite admission is different. It is non-monotone not only when fragments delete structure,
but also when admission depends on budgets, overlap checks, and compatibility against the current
set of proposals.

The important payoff is architectural. The Cortex epoch/watermark boundary is not merely a
taste-level barrier. It is the current system's natural coordination boundary: inside the epoch,
reduction can proceed concurrently over a fixed topology; at the boundary, substitution is
serialized because admissibility is non-monotone. That is a stronger and more general story than
"rewrites are scary, so we inserted a stop-the-world phase."

The main caution is about overclaiming. CALM supports "non-monotone fragments need coordination"; it
does not by itself prove that Cortex's exact epoch/watermark structure is the unique possible
implementation. The safer statement is that the current epoch boundary is the natural minimal
coordination boundary induced by Cortex's present semantics.

---

## Key Findings

### [P1] The staged reduction kernel is already Cortex's monotone fragment

**Category:** Novel Idea **Status:** Observed **Confidence:** High **Primary evidence:**
[paper 2](../../Publications/Paper-2-algebraic-foundations/manuscript.md),
[GraphRuntime.hs](../../../src/Cortex/Pulse/GraphRuntime.hs),
[paper 1](../../Publications/Paper-1-staged-reduction/manuscript.md) **Cross-reference:**
`applyNodeFact`, `propagateFailure`, `classifyGraphState`, `readyNodes`

The current fixed-topology kernel already has the shape that a CALM-style argument wants. Within one
materialized topology:

- frontier nodes are chosen from an antichain
- each node contributes node-local facts
- accumulation is permutation-invariant over disjoint keys
- closure is idempotent
- classification is deterministic over the normalized, closed state

This does not mean the whole runtime is monotone in every operational detail. `Running`, `Waiting`,
resume normalization, and persistence boundaries are still operational concerns. The useful
monotonic object is narrower: the fact-reduction kernel over a fixed topology.

**Why it matters:** This gives Cortex a principled name for what Paper 2 actually proves. It is not
only a runtime discipline; it is the coordination-free fragment that later topology-changing work
can rest on.

**Next step:** State this explicitly in the papers: the reduction kernel is the fixed-topology fact
fragment, not the full evolving-graph machine.

### [P1] Rewrite admission is non-monotone even in addition-only settings

**Category:** Missed Abstraction **Status:** Observed **Confidence:** High **Primary evidence:**
[Rewrite.hs](../../../src/Cortex/Pulse/Rewrite.hs),
[chapter 07](../../Architecture/07-rewrites-and-materialization.md),
[paper 3](../../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
**Cross-reference:** rewrite budgets, anchor/compatibility checks, same-wave admission semantics

Deletion is only the most obvious source of non-monotonicity. Cortex rewrite admission is already
non-monotone because:

1. additional proposals can invalidate a previously acceptable proposal through budget consumption
2. additional proposals can create overlap or interface conflicts
3. a topology change can alter later well-formedness and admissibility conditions

So even a hypothetical "addition-only" Cortex would still need coordination at the admission layer
unless the admitted class were further restricted.

**Why it matters:** This is the key distinction between "we only append" and "we are monotone."
Append-like topology change can still be non-monotone once admission depends on the proposal set and
the remaining budget.

**Next step:** Make the paper language precise: node execution and rewrite admission are different
semantic questions because only the latter is proposal-set-sensitive.

### [P1] The epoch/watermark boundary is the current system's natural coordination boundary

**Category:** Novel Idea **Status:** Inferred **Confidence:** High **Primary evidence:**
[chapter 07](../../Architecture/07-rewrites-and-materialization.md),
[deterministic multi-rewrite admission note](../../Publications/Notes/deterministic-multi-rewrite-admission.md),
[paper 3](../../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
**Cross-reference:** same-wave proposal semantics, ordered materialization, watermark-based resume

The runtime already implements the exact split this framing predicts:

1. frontier nodes execute concurrently from one settled snapshot
2. node facts are accumulated and classified against the current materialized topology
3. admitted rewrites are serialized through the admission gate and shared remaining budget
4. materialization advances the watermark before scheduling resumes on the new topology

That makes the watermark boundary more than a crash-recovery detail. It is also the point where the
machine stops doing coordination-friendly fact reduction and starts doing coordinated topology
change.

The strongest safe claim is therefore:

> Cortex's epoch boundary is the natural coordination boundary induced by its current semantics.

The stronger claim that this is the unique minimal architecture should be deferred until there is a
dedicated formal model of alternative implementations.

**Why it matters:** This turns a design choice into a theorem-shaped systems argument without
overclaiming beyond what CALM actually proves.

**Next step:** Thread this sentence into Paper 3's concurrency section and reserve the stronger
minimality claim for a later dedicated paper.

### [P2] I-confluence is the right refinement for future same-wave parallel admission

**Category:** Design Tension **Status:** Inferred **Confidence:** Medium **Primary evidence:**
[Coordination Avoidance in Database Systems](https://www.vldb.org/pvldb/vol8/p185-bailis.pdf),
[deterministic multi-rewrite admission note](../../Publications/Notes/deterministic-multi-rewrite-admission.md),
[ExecutorSpec same-wave tests](../../../test/Cortex/Pulse/ExecutorSpec.hs) **Cross-reference:**
same-wave proposals, shared budget, ordered materialization

CALM explains why the current admission layer needs coordination. I-confluence suggests the next
refinement: identify a subclass of rewrite sets whose admissibility is invariant under reordering
and merge. In Cortex terms, that likely means something like:

- disjoint anchor dominions
- no interface overlap
- budget effects that compose independently
- lineage/provenance that remains explanation-stable under either admission order

If such a criterion can be checked cheaply, Cortex could parallelize some same-wave admissions
without pretending that all rewrite concurrency is safe.

**Why it matters:** This is the credible bridge between the current ordered machine and a stronger
future machine. It also gives a rigorous answer to "when can we relax the barrier?".

**Next step:** Turn the current validation list into a real research program: order-sensitivity
tests, counterexamples, and a candidate independence predicate.

---

## Design Tensions

Two legitimate goals pull against each other here.

- **Minimal coordination:** push as much work as possible into the within-topology reduction phase.
- **Dynamic structure:** allow planner- or operator-driven topology change at runtime.

CALM does not eliminate the tension; it clarifies where it lives. The runtime can avoid coordination
inside the fixed-topology fact fragment, but topology admission remains the place where consistency
forces a barrier unless a stronger independence law is proved.

---

## Recommended Actions

### Act Now

- [ ] Add the monotone-phase / coordinated-phase split to Paper 3's concurrency section.
- [ ] Keep the claim scoped to "natural coordination boundary" rather than "unique minimal
      architecture."

### Design Next

- [ ] Define a candidate rewrite-independence criterion over anchors, interfaces, and budget
      effects.
- [ ] Add order-sensitivity tests that force different same-wave admission orders and compare
      topology, budget, lineage, and outcome.

### Write Up

- [ ] Treat this as a likely Paper 5 direction: CALM on evolving graph topologies, or monotone
      execution with coordinated substitution.

### Parked

- Strong uniqueness/minimality theorem — defer until there is a formal comparison against plausible
  alternative evolving-graph execution models.
