---
title: "Research Memo: PR #909 — Blocked Graph Diagnostics & Paper 1 Evidence"
description: Cross-reference synthesis of DIG-424, DIG-430, Papers 1/3, and the graph execution v2 architecture
---

# Research Memo: PR #909 — Blocked Graph Diagnostics & Paper 1 Evidence

**Date:** 2026-04-07
**Scope:** DIG-424, DIG-430, PR #909 (branch `pulse-graph-v2-strengthen-blocked-graph-diagnostics`)
**Layers examined:** Code | Papers (1, 3, IDEAS) | Architecture (v2 spec) | Issues | Literature (CALM, CKA, Mokhov)

---

## Key Findings

### [P1] Signal resolution is an implicit closure operator outside the algebra

**Category:** Missed Abstraction
**Files:** `Executor.hs:989-1023`, `Graph.hs:897-929`, Paper 1 §3.8, IDEAS.md §3
**Cross-reference:** Paper 2 §4.3 (composition criterion), Idea 3 (closure composition)

`resolveDeliveredSignals` performs the same structural operation as `propagateFailure`:
it transitions nodes from one status to another based on external state (delivered signals),
and applying it twice is a no-op (idempotent). But it lives entirely in IO, requires a
database lookup per waiting node, and has no algebraic specification.

Paper 1 §3.8 claims signal suspension "flows through the same staged reduction," which is
true for the *suspension* direction (`OutcomeSuspendedOn` → `NodeWaiting` via `applyNodeFact`).
But signal *resolution* (delivered → `NodeCompleted`) bypasses the algebra entirely. This
asymmetry means:

- The persistence safety theorem (Theorem 1) doesn't cover signal delivery races
- Adding more consequence-derivation phases (signal expiry, quorum accounting) will each
  require a new IO function with no shared interface
- Paper 2's composition criterion (§4.3: closures commute iff safe to compose) is
  unvalidatable because there's no shared `ClosureOperator` interface to test against

**Concrete next step:** Factor signal resolution into a pure phase:

```haskell
-- Pure: given delivered signals map, resolve waiting nodes
resolveSignals :: Map SignalName Value -> GraphState o -> GraphState o
```

The IO part (fetching deliveries from the DB) stays in the executor; the state transition
becomes a second closure operator composable with `propagateFailure`. Then Paper 2's
pairwise commutativity criterion becomes testable as a QuickCheck property.

---

### [P2] Incremental persistence safety (Theorem 1) has no property test

**Category:** Correctness Gap / Evidence Gap
**Files:** `Executor.hs:886-914`, `GraphSpec.hs`, Paper 1 §3.3-3.4
**Cross-reference:** Paper 2 §3.1 (formal statement), Idea 7 (`simulateRun` as oracle)

Theorem 1 is the paper's central correctness claim: "Incremental persistence during
accumulation preserves graph state validity." The proof sketch relies on closure
idempotency. But there is no property test that validates the full claim:

1. Generate a random frontier scenario
2. Persist a random prefix of results (simulating partial crash)
3. Apply `resetRunningToPending` (crash recovery)
4. Re-execute the unpersisted nodes (with a deterministic oracle)
5. Assert: final state after re-close matches full-frontier state

The existing "crash recovery preserves structural safety" test (`GraphSpec.hs:504-518`)
is weaker — it only checks that the recovered state is *classifiable*, not that it
converges to the *same final state* as uninterrupted execution.

`simulateRun` (Idea 7) is the perfect oracle for this. A property test using
`simulateRun` with partial persistence would directly validate Theorem 1.

---

### [P3] The ACC pattern as a parametric design pattern (publishable)

**Category:** Novel Idea
**Files:** Paper 2 §1, IDEAS.md §6, `Graph.hs:1029-1036`
**Cross-reference:** CALM theorem (Hellerstein 2010), CRDTs (Shapiro 2011), Petri net commutative processes

The accumulate-close-classify pattern is not specific to workflow execution. Paper 2 §1
formalizes it as: commutative monoid action (accumulation) → closure operator on status
semilattice (close) → decision procedure (classify). IDEAS.md §6 lists three other domains
where this applies.

What's missing is the *parametric formulation* — a generic ACC framework where:
- `accumulate` is parameterized by the fact monoid and its action on state
- `close` is parameterized by one or more composable closure operators
- `classify` is parameterized by the terminal predicate

This would allow instantiation to: consensus protocols (votes → quorum → decision),
build systems (compilation → dependency propagation → build status), game engines
(player actions → physics resolution → game state).

The contribution is not the individual instantiations but the *shared correctness
properties*: determinism (up to fact order), incremental persistence safety, and
sequential/concurrent observational equivalence all follow from the ACC structure
rather than the specific domain.

**Target:** Short paper or Functional Pearl at ICFP. The Haskell implementation
already exists as evidence; the novelty is the parametric formulation.

---

### [P2] Forward/reset partition is a runtime predicate, not a type-level guarantee

**Category:** Design Tension
**Files:** `Graph.hs:826-891` (`NodeOutcome` type), Paper 2 §2.2, IDEAS.md §4
**Cross-reference:** Session types (Honda 1993), Graph execution v2 spec (Phase 2)

`NodeOutcome` mixes forward outcomes (monotone status transitions) and reset outcomes
(non-monotone reversals to Pending) in the same sum type. The classification
`isForwardOutcome` / `isResetOutcome` is a runtime predicate.

Ideas.md §4 observes: "If we modeled node execution as a session type, workers would be
unable to produce reset outcomes — only the coordinator (via cancellation/shutdown) could."

This matters for Phase 2 (graph rewriting): if workers can propose rewrites, distinguishing
"worker produced a forward fact" from "coordinator requested a reset" at the type level
prevents rewrite proposals from accidentally resetting nodes.

However, this is in tension with the current simplicity. The `NodeOutcome` type is used
in 40+ locations. Splitting it into `ForwardOutcome` and `ResetOutcome` is a significant
refactor with unclear ROI until Phase 2 is active.

**Recommendation:** Park until Phase 2 starts. When `GraphRewrite` is introduced, revisit
whether the rewrite algebra needs the type-level forward/reset distinction.

---

### [P2] `simulateRun` is an untapped test oracle

**Category:** Evidence Gap
**Files:** `Graph.hs` (simulateRun), `ExecutorSpec.hs`, IDEAS.md §7
**Cross-reference:** Idea 7a-d (oracle, specification, what-if, fuzzer)

`simulateRun` is a pure function that runs the entire lifecycle with no IO. It takes a
`WorkerOracle` and produces wave history + final `StepResult`. IDEAS.md §7 identifies
four uses, but only one is partially implemented (direct testing via `GraphSpec.hs`).

The most valuable untapped use is **7a (test oracle)**: any behavior observed in the
real IO executor should match what `simulateRun` produces given the same oracle. This
could be validated by:

1. Running `simulateRun` with a deterministic oracle
2. Running the real executor with matching stage actions
3. Comparing final graph states

This would catch any divergence between the pure algebra and the IO coordinator (e.g.,
the kind of persistence-race bugs that DIG-424 fixed).

---

### [P1] `updateRunFailed` first-writer-wins should be tested

**Category:** Correctness Gap
**Files:** `Query.hs:400-414`, `Executor.hs` (all `failRun` call sites)
**Cross-reference:** PR #909 fix commit `3a725e78`

The fix to prevent `handleSettled` from overwriting `graph_state_persist_failed` with
`graph_settled_with_failures` relies on `WHERE status != 'failed'` in `updateRunFailed`.
This is a critical invariant (first-writer-wins error classification) but has no test.

An integration test should:
1. Call `failRun` with `graph_state_persist_failed`
2. Call `failRun` again with `graph_settled_with_failures`
3. Assert the persisted `error_type` is still `graph_state_persist_failed`

---

## Missed Abstractions

| Pattern | Instances | Potential Abstraction |
|---------|-----------|----------------------|
| Closure operator (state → state, idempotent, extensive, monotone) | `propagateFailure`, `resolveDeliveredSignals`, planned signal expiry, planned quorum check | `ClosureOperator` typeclass with algebraic laws |
| Forward/reset classification | `isForwardOutcome`, `isResetOutcome`, `runTerminal`, coordinator short-circuit | `ForwardOutcome` / `ResetOutcome` phantom-tagged types or session types |
| "Require or fail run" pattern | `requireGraphStatePersist`, `requireTx`, `requirePulse*` | Already partially unified; `requireGraphStatePersist` follows the pattern |

## Evidence Gaps

| Claim | Source | Current Evidence | Needed |
|-------|--------|------------------|--------|
| Incremental persistence safety (Theorem 1) | Paper 1 §3.4, Paper 2 §3.1 | Partial: crash recovery test checks classifiability | Full: partial-persist + crash + re-execute converges to same state |
| Sequential = concurrent equivalence | Paper 1 §3.6, Idea 2 | Partial: batch = sequential reduction test | Full: `simulateRun` oracle comparison between sequential and concurrent paths |
| Closure operator composition | Paper 2 §4.3, Idea 3 | None | Pairwise commutativity of `propagateFailure` and signal resolution |
| First-writer-wins `failRun` | PR #909 fix | None | Integration test with double `failRun` |

## Design Tensions

| Tension | Resolution Path |
|---------|-----------------|
| Static topology (concurrent frontier) vs dynamic topology (graph rewriting, Phase 2) | Rewriting only at phase boundaries after classification (Paper 2 §4.2) |
| Pure algebra (deterministic, testable) vs IO operations (signals, persistence) | Factor IO into a "fetch" step that produces pure inputs to the algebra |
| Simple `NodeOutcome` sum type vs type-safe forward/reset distinction | Defer until Phase 2; evaluate then whether rewrite proposals need the distinction |
| Critical persistence (fail on write error) vs availability (best-effort for non-critical paths) | Already resolved: critical for frontier, best-effort for suspension (PR #909) |

---

## Recommended Actions

### Act Now (this sprint)
- [ ] Property test for Theorem 1: partial-persist + crash + recover convergence
- [ ] Integration test for first-writer-wins `failRun`
- [ ] `simulateRun` oracle comparison test (pure vs IO executor)

### Design Next (next sprint)
- [ ] Factor `resolveDeliveredSignals` into pure state transition + IO fetch
- [ ] Evaluate `ClosureOperator` typeclass feasibility (prototype, check ergonomics)
- [ ] Draft pairwise commutativity test for failure propagation + signal resolution

### Write Up (paper/doc contribution)
- [ ] ACC design pattern as Functional Pearl (parametric formulation + 3 instantiations)
- [ ] Update Paper 1 §3.8 to accurately describe the signal asymmetry
- [ ] Add Theorem 1 property test reference to Paper 1 §4.1 validation table

### Parked
- Forward/reset session types — defer until Phase 2 graph rewriting is active
- Brzozowski derivative connection (Idea 5) — interesting but too speculative for current papers
- Boolean algebra on closed states (Idea 1) — failure irreversibility blocks complement; investigate Heyting algebra instead
