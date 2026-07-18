---
title: "Paper 1 — Lean-Haskell Pulse Boundary"
description:
  "Companion artifact note for the Staged Reduction paper: what the Lean circuit-engine kernel
  models, what the Pulse host must establish, and where assumptions remain."
date: 2026-04-28
updated: 2026-07-18
status: draft
related:
  - docs/Publications/Paper-1-staged-reduction/manuscript.md
  - docs/Publications/Paper-1-staged-reduction/lean-mechanization.md
  - docs/Roadmap/Plans/lean-mechanization.md
---

# Paper 1 — Lean-Haskell Pulse Boundary

This note states the boundary between the target-independent fixed-topology circuit-engine kernel
mechanized in Lean and the live Haskell Pulse runtime host. It is the artifact note for the Staged
Reduction manuscript's implementation claim. Pulse is one durable host of this kernel, not the
exclusive definition of its scheduling semantics.

## Boundary Summary

Lean proves structural safety for a finite DAG and an extensional graph state after recovery
normalization and failure closure. The Haskell runtime is responsible for decoding, validating, and
persisting concrete state; running node executors; and admitting only topology-valid node results.
The Lean theorem begins once the runtime has supplied a candidate graph state and the stated
persisted preconditions hold.

The mechanization is intentionally structural. It does not model worker I/O, JSON schemas, database
transactions, retry policy, signal delivery, or the semantic correctness of a node's payload.

## Lean Kernel Model

The Lean model under `theory/Cortex/Pulse/` uses these abstractions:

- `DAG`: a finite node set with an edge relation whose endpoints are in the node set. Reachability
  is the edge-path transitive closure, not a free relation supplied by callers.
- `GraphState`: total functions from nodes to statuses and optional outputs. The `topologyDomain`
  predicate makes off-topology state inert: off-topology statuses are pending and off-topology
  outputs are absent.
- `NodeStatus`: the eight runtime lifecycle statuses, with operational payloads erased.
  `NodeInterrupted reason` becomes `interrupted`; `NodeWaiting signal` becomes `waiting`.
- `payload`: an abstract type. Lean tracks whether an output exists and whether its status may own
  it; it does not inspect JSON values.
- `NodeOutcome` and `NodeResult`: abstract worker results used for the pure accumulation phase. The
  admissibility predicate requires the target node to be in the topology and executable from the
  direct runtime frontier.

The public recovered-state structure is `WellFormedGraphState`, exposed through the stable
`wellFormedGraphState` predicate name. Its fields are the proof-side version of the runtime
boundary:

- `topologyDomain`
- `outputsRespectStatuses`
- `outputsCompleteForStatuses`
- `noRunningNodes`
- `noInterruptedNodes`
- `failureClosureComplete`
- `causalHistoryClosed`
- `frontierBridge`

`frontierBridge` states that proof-level reachability readiness and the runtime's direct-predecessor
frontier coincide. Lean proves this bridge from failure closure plus causal-history closure.

`causalHistoryClosed` is the structure field for the standalone predicate `CausalHistoryClosed`; the
two names denote the same conceptual obligation at different levels of the Lean API.

## Runtime Responsibilities

The Haskell runtime carries concrete identifiers, maps, JSON payloads, durable storage, and executor
effects. To use the Lean theorem as the structural justification for recovery, the runtime side must
establish or preserve the following obligations.

| Runtime obligation                                                                             | Lean boundary predicate                                         |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Build a finite acyclic topology and reject persisted status keys outside the rebuilt topology. | `DAG` well-formedness and `topologyDomain`                      |
| Insert missing topology statuses as pending during reconciliation.                             | `topologyDomain`                                                |
| Normalize in-flight execution state before resumption.                                         | `resetRunningToPending`, `noRunningNodes`, `noInterruptedNodes` |
| Keep outputs only on payload-owning statuses.                                                  | `outputsRespectStatuses`                                        |
| Ensure payload-owning terminal statuses have outputs.                                          | `outputsCompleteForStatuses`                                    |
| Persist only node facts produced for topology nodes admitted by the executable frontier.       | `NodeResult.Admissible` preservation lemmas                     |
| Preserve the causal history of successor-unblocking statuses.                                  | `CausalHistoryClosed`                                           |
| Re-run failure propagation before authoritative classification.                                | `failureClosureComplete`, closure idempotence                   |

Some of these are local runtime mechanisms: `initialGraphState` creates pending statuses for
topology nodes, `reconcileGraphState` rejects unknown status nodes and fills missing topology
statuses as pending, and `normalizeForResume` maps running and interrupted nodes back to pending.
Others are end-to-end contracts on the execution path: node results must come from the ready
frontier, persisted outputs must match their statuses, and persisted state must not acquire stray
topology identifiers.

## Status And Output Correspondence

| Haskell status           | Lean status   | Boundary meaning                                                                                                                                                                                        |
| ------------------------ | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NodePending`            | `pending`     | Waiting to run; no output.                                                                                                                                                                              |
| `NodeRunning`            | `running`     | Volatile in-flight state; reset to pending on recovery.                                                                                                                                                 |
| `NodeCompleted`          | `completed`   | Terminal success; owns and requires an output.                                                                                                                                                          |
| `NodeFailed`             | `failed`      | Terminal failure; owns no output and drives failure closure.                                                                                                                                            |
| `NodeSkipped`            | `skipped`     | Terminal non-output status; unblocks successors and contributes no input payload.                                                                                                                       |
| `NodeInterrupted reason` | `interrupted` | Volatile interruption; the reason is operational and erased by Lean.                                                                                                                                    |
| `NodeWaiting signal`     | `waiting`     | Suspended on an external signal; the signal name is operational and erased by Lean.                                                                                                                     |
| `NodeRewritten`          | `rewritten`   | Terminal rewrite marker; Lean treats well-formed rewritten nodes as payload-owning. Rewrite correctness itself belongs to the rewrite-materialization proof path, not the fixed-topology Paper 1 claim. |

The important invariant is negative as much as positive: failed, skipped, pending, running,
interrupted, and waiting nodes must not carry durable outputs in a well-formed recovered state. This
is what prevents stale payloads from being read after a skipped or failed dependency.

## Frontier And Classification Boundary

The runtime computes readiness from direct predecessors. The Lean proof defines readiness over all
strict ancestors because that is the natural shape for antichain and stuck-freeness arguments. These
agree only under the recovered-state invariants:

- failure closure ensures failed ancestors have propagated through propagatable descendants
- causal-history closure ensures a successor-unblocking node has terminal strict ancestors
- topology-domain validity prevents off-topology statuses from affecting the runtime-style scan

With those invariants, Lean proves `readyNodes_eq_directReadyNodes`. Classification then follows the
runtime order: failure, progressing, completed, suspended, stuck. The theorem
`classifyGraphState_not_stuck_of_wellFormed` states that well-formed states cannot reach the stuck
branch after the runtime closure step.

## What Remains Outside Lean

The fixed-topology kernel does not prove these runtime properties:

- executor I/O is deterministic or replay-equivalent
- JSON payloads satisfy executor-specific schemas
- database writes are atomic or ordered correctly
- host cancellation and signal delivery are fair
- dynamic rewrite materialization is sound
- Haskell's concrete map representation is extensionally equal to the Lean total-function model

Those are separate runtime, registry, or rewrite-materialization obligations. Paper 1's Lean-backed
claim is narrower: if the runtime supplies a finite topology-valid recovered state satisfying the
persisted boundary preconditions, then normalization and failure closure produce a structurally
well-formed state whose frontier and classifier are safe to use.
