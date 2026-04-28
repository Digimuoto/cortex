---
title: "Chapter 07 — Rewrites and Materialization"
description:
  "Bounded dynamic graph evolution during execution. Rewrite algebra, gas budgets, admission policy,
  materialization into durable state, provenance of rewrite events."
sidebar:
  label: "07. Rewrites and materialization"
  order: 7
status: active
---

# Chapter 07 — Rewrites and Materialization

A static Circuit is enough only when the work is known at compile time. Planners discover a missing
dimension; reviewers expand a node into validation branches; gatherers choose a retrieval strategy
after seeing intermediate output. This chapter specifies how Cortex admits topology change without
dissolving into arbitrary mutation. The answer is a **rewire**: a bounded runtime topology
modification over an existing Circuit, drawn from a closed algebra, metered in gas, admitted by the
runtime, and materialized into durable state with an explicit audit trail. Rewires obey the same
vocabulary, endpoint-compatibility, and validity rules a compiled Wire source must satisfy, plus a
structural resource budget the runtime enforces at admission time.

## Core model

A rewire is a structured proposal, not a mutation. A stage produces its ordinary output **and** a
rewrite value from a closed algebra; the runtime validates, checks against the remaining budget, and
admits or rejects with a structured reason. No stage writes to the graph directly.

| Concept            | Role                                                         |
| ------------------ | ------------------------------------------------------------ |
| Plan graph         | Initial Circuit compiled from Wire source.                   |
| Materialized graph | Plan graph plus all admitted rewires.                        |
| Rewrite log        | Append-only provenance of proposals and admission decisions. |
| Gas                | Five-dimensional structural-change budget.                   |
| Watermark          | Monotone id up to which rewires have been materialized.      |

Authorship is split: stages and planners **propose**; the runtime **admits**. Only the runtime
mutates durable graph state, and only through the narrow algebra below.

## Rewrite algebra

The algebra is intentionally narrow. Two constructors cover the highest-value dynamic patterns;
additional forms are deferred until a real task requires them.

```haskell
data GraphRewrite
  = ExpandNode   NodeId ExpansionMode SubgraphSpec
  | AppendAfter  NodeId SubgraphSpec

data ExpansionMode
  = ExpandReplaceNode
  | ExpandRetainNodeAsEnvelope
```

`ExpandNode` replaces a node with a subgraph — a planner turns a single step into a repair or
evidence-gathering branch. `AppendAfter` inserts a subgraph downstream of a node — a reviewer queues
validation once the anchor finishes. `InsertBefore`, `PruneSubgraph`, `AddJoin`, and `ReplaceNode`
are recognized future forms but not part of the admitted alphabet.

A `SubgraphSpec` is a self-contained fragment: local topology, stage definitions for every local
node, explicit entry nodes where inbound edges attach, explicit exit nodes where outbound edges
continue. Entry and exit declarations are serialized lists but semantically sets, so duplicates are
invalid. Validation rejects duplicate entry/exit nodes, missing definitions, orphan nodes,
definitions outside the fragment, and any cycle in the resulting materialized graph. New nodes
receive deterministic ids namespaced by their parent (`planner:repair_branch_1:step_1`), keeping
identity stable across replay. Local inserted node ids cannot contain `:`, and the namespaced ids
must be fresh against the current topology so namespace mapping cannot silently merge nodes.

Stages signal rewrites via a richer outcome:

```haskell
data StageResult
  = StageComplete Aeson.Value
  | StageSuspend  SignalName
  | StageRewrite  Aeson.Value GraphRewrite
```

`StageRewrite` carries both the node's durable output and the proposed edit; retained or appended
subgraphs insert entry nodes that depend on that output, so a rewire is "output and rewrite," not
"output or rewrite." See
[Paper 3](../Publications/Paper-3-graph-substitution-semantics/manuscript.md) for the formal
substitution treatment.

## Gas accounting

Gas is a **structural-change budget**, structural only; semantic weighting (latency, cost class,
effect class) is deferred. The five dimensions:

```haskell
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax    :: Natural  -- nodes added
  , rbAddedEdgesMax    :: Natural  -- edges added
  , rbAddedDepthMax    :: Natural  -- depth added below any anchor
  , rbFrontierDeltaMax :: Natural  -- peak frontier breadth delta
  , rbRewriteOpsMax    :: Natural  -- admitted rewrite operations
  }
```

Each admitted rewire consumes a natural-valued `RewriteCost` computed statically from its
`SubgraphSpec`; admission draws only against remaining budget. Negative serialized values are
invalid before admission. Runaway planner elaboration becomes a runtime impossibility rather than a
prompt-discipline problem. Gas is visible in run history: operators can inspect remaining budget,
each rewrite's cost, and the rewire that exhausted a dimension.

## Admission policy

Admission is the runtime's gate. A proposal is admitted only when every check passes:

1. **Vocabulary bounds.** Every node instance references a registered executor; every port contract
   is a registered `ContractId`. No executors or contracts outside the closed alphabet.
2. **Endpoint compatibility.** Every new edge connects ports whose contracts are compatible under
   the port-semantic rules of [Chapter 05](./05-wire-language.md). Singular and list-valued inputs
   obey the same arity rules at the rewire boundary as at compile time.
3. **Topology validity.** The post-application materialized graph remains a DAG. The anchor exists
   in the current topology and definition map, and the current definition domain exactly covers the
   current topology. Entry/exit sets are non-empty and duplicate-free where the rewrite form
   requires them. Local inserted node ids are delimiter-free, and their namespaced ids are fresh.
   Definition-domain updates follow the anchor disposition: replacement deletes the anchor
   definition before overlaying inserted definitions; retention and append keep the old domain and
   overlay inserted definitions. No orphans, no dangling references.
4. **Resource bounds.** Estimated `RewriteCost` fits within the remaining budget on every dimension.
5. **Runtime policy.** The anchor, the run, and the task type permit rewrites of this form. Planner
   nodes may be restricted to a subset of the algebra.

A proposal that fails any check is rejected with a structured reason (`invalid_rewrite`,
`rewrite_budget_exceeded`, `vocabulary_violation`, `cycle_introduced`, …). Default policy is
fail-fast: the node and run fail with a legible error. Task-specific fallback modes —
structured-output-only continuation, operator escalation — are deferred.

Admission is deterministic per frontier wave. Multiple frontier nodes may emit proposals in the same
wave. The runtime serializes admission through a shared admission gate and shared remaining budget,
persists admitted rewrite rows individually with monotone rewrite ids, and materializes admitted
rows in rewrite-id order after frontier classification. This is deterministic ordered admission, not
a proof that same-wave rewrites commute or can be treated as one concurrent semantic step. See
[Chapter 06](./06-pulse-runtime.md) for scheduler-loop placement and blocked-graph diagnostics.

This boundary is architectural, not just procedural. Within one materialized topology, Pulse can
reduce node-local facts concurrently over the current frontier. Rewrite admission is different: it
is the coordinated phase where topology-changing proposals are checked against the ambient graph,
the remaining budget, and the other proposals in flight. The phase boundary therefore separates
coordination-friendly fact reduction from coordinated topology change.

The proof contract leads the implementation. The runtime admission path must construct the same
natural budget vectors, duplicate-free entry/exit sets, topology-diff facts, and definition-domain
update shape used by the mechanized rewrite model, or reject the proposal before materialization.

## Materialization

Admission and application are separate events with crash-safety obligations between them. The
normative durability contract:

- The **rewrite log** is append-only. Each entry carries the accepted rewrite specification, the
  anchor's output needed to replay into inserted entry nodes, the static cost, and a monotone
  rewrite id.
- The **graph state** carries the watermark (highest rewrite id materialized) and the remaining
  budget. Materialization applies node-state changes, budget consumption, and watermark advance in
  one atomic commit.
- Admitted lineage may exist beyond the watermark. That means "admitted but not yet applied to the
  materialized graph", not "applied and omitted".
- Resume reconstructs the materialized graph only through the watermark. If lineage exists beyond
  it, resume deterministically finishes materialization before any scheduling decision.

The watermark makes crash recovery explicit at the rewrite boundary: without it, raw lineage replay
cannot distinguish "persisted but not yet applied" from "applied and reflected." Watermark-based
materialization requires a Runtime/checkpoint version bump; pre-watermark rewrite-capable runs are
legacy and not guaranteed resumable.

Hydration of rewritten stages is keyed by stage-template identity (durable executable identity) and
verified against stage-action identity, not by scanning ad-hoc stage ids. Duplicate template ids in
a materialized plan are rejected unless they map to the same action and identical policy metadata.
See the
[rewrite materialization and recovery plan](../Roadmap/Plans/rewrite-materialization-and-recovery.md)
for the formal treatment of the materialization boundary and recovery invariants.

## Provenance of rewrite events

This chapter covers provenance of **structural events**; provenance of **values** flowing through
edges belongs to [Chapter 08](./08-artifacts-and-provenance.md).

Every material graph evolution event is explainable after the fact. For each rewrite the runtime
persists: the proposing node id and stage result, the raw `GraphRewrite` proposal, the admission
decision (admitted, or rejected-with-reason), the cost and post-admission remaining budget, the
structural diff applied, and any operator override. Rejected rewrites are not silently discarded —
rejection rows are part of the audit trail. Operator surfaces expose the current materialized graph,
rewrite history per run, and any blocked or waiting reasons introduced by rewrites.

## Boundaries and invariants

This layer enforces:

- stages and planners propose; only the runtime admits.
- rewrites stay inside the closed executor alphabet, contract registry, endpoint compatibility, DAG
  validity, and the five-dimensional gas budget.
- same-wave rewrite proposals are admitted in deterministic order against shared remaining budget;
  ordinary node execution across the frontier is still concurrent.
- the rewrite log is append-only, and watermark and remaining budget update atomically with the
  node-state changes they imply.
- static DAGs and linear stage paths remain valid programs — a run with no rewrites is a degenerate
  case, not a special mode.

It delegates graph algebra to [Chapter 04](./04-graph-and-circuit.md), scheduling and checkpointing
to [Chapter 06](./06-pulse-runtime.md), value-envelope provenance to
[Chapter 08](./08-artifacts-and-provenance.md), and Wire grammar and partial-node rules to
[Chapter 05](./05-wire-language.md).

## Extensibility

New rewrite forms enter by adding constructors to `GraphRewrite` and extending the validator — not
by letting stages emit arbitrary edits. `InsertBefore`, `PruneSubgraph`, `AddJoin`, and
`ReplaceNode` lie along this path. Richer gas dimensions (semantic weighting, effect classes,
irreversibility boundaries) enter by extending `RewriteBudget` and the static cost estimator with a
matching durability migration. Hierarchical subgraphs — composite nodes owning nested budgets — are
the planned composition extension once the flat algebra has been proven on a real task. Planner
integration proceeds by registering planner-capable nodes with a policy-gated, budget-aware
contract, not by loosening admission checks.

## Related

- [./03-formalism-stack.md](./03-formalism-stack.md),
  [./04-graph-and-circuit.md](./04-graph-and-circuit.md),
  [./05-wire-language.md](./05-wire-language.md), [./06-pulse-runtime.md](./06-pulse-runtime.md),
  [./08-artifacts-and-provenance.md](./08-artifacts-and-provenance.md)
- [../Reference/terminology.md](../Reference/terminology.md) — normative vocabulary.
- [../Roadmap/Plans/rewrite-materialization-and-recovery.md](../Roadmap/Plans/rewrite-materialization-and-recovery.md),
  [../Publications/Paper-3-graph-substitution-semantics/manuscript.md](../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
  — formal treatment.
