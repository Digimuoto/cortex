---
title: "Rewrites Reference"
description:
  "Normative reference for bounded dynamic graph rewrites: algebra, budget, admission,
  materialization, hydration, provenance."
sidebar:
  label: "Rewrites"
  order: 30
status: accepted
date: 2026-04-24
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
---

# Rewrites Reference

Pulse admits bounded structural edits to a live Circuit through a closed algebra, metered in gas,
validated at admission, materialized into durable state with explicit provenance. This reference
states the normative surface. Architectural framing — why the algebra is narrow, why gas is
structural, why authorship is split — lives in
[chapter 07](../Architecture/07-rewrites-and-materialization.md).

## Scope

This reference covers the rewrite **algebra**, the **budget** that meters it, the **admission**
checks that gate it, the **materialization** contract that commits it, the **hydration** rules that
bind rewritten nodes back to runtime actions, and the **structural provenance** persisted per
rewrite. Value provenance (where a specific value flowing on an edge came from) is out of scope and
is specified in chapter 08.

## 1. Algebra

### 1.1 `GraphRewrite` constructors

```haskell
data GraphRewrite
  = ExpandNode   NodeId ExpansionMode SubgraphSpec
  | AppendAfter  NodeId SubgraphSpec

data ExpansionMode
  = ExpandReplaceNode
  | ExpandRetainNodeAsEnvelope
```

- **`ExpandNode anchor mode spec`** — replace the anchor node with the subgraph. With
  `ExpandReplaceNode`, the anchor disappears; inbound and outbound edges reattach to the subgraph's
  entry and exit sets. With `ExpandRetainNodeAsEnvelope`, the anchor persists as the envelope around
  the fragment and its output is available to the inserted entry nodes on resume (see §5.1).
- **`AppendAfter anchor spec`** — insert the subgraph downstream of the anchor. The anchor keeps its
  identity and outbound edges; the subgraph's entry set connects behind the anchor, its exit set
  continues downstream.

No other constructors are admitted in v1. Proposals using unrecognized forms are rejected as
`invalid_rewrite`.

### 1.2 `SubgraphSpec`

A `SubgraphSpec` is a self-contained fragment carrying:

- local topology (nodes and edges internal to the fragment),
- stage definitions for every local node,
- an explicit **entry set** where inbound edges attach,
- an explicit **exit set** where outbound edges continue.

Validation rejects missing definitions, orphan nodes, definitions outside the fragment, and any
cycle in the resulting materialized graph.

New node ids inside a spec are deterministic and namespaced by their parent anchor (for example
`planner:repair_branch_1:step_1`). Deterministic namespacing is required so identity is stable
across replay.

### 1.3 Deferred forms

The following constructors are recognized future forms but **not part of the admitted alphabet in
v1**: `InsertBefore`, `PruneSubgraph`, `AddJoin`, `ReplaceNode`. Introducing any of them requires a
new ADR and a runtime-version bump.

## 2. Stage-result extension

Stages signal rewrite proposals through a richer `StageResult`:

```haskell
data StageResult
  = StageComplete Aeson.Value
  | StageSuspend  SignalName
  | StageRewrite  Aeson.Value GraphRewrite
```

`StageRewrite` carries **both** the stage's durable output and the proposed edit. Retained or
appended subgraphs whose entry nodes depend on that output read it from the retained anchor on
resume (see §5.1). Producing a rewrite is therefore "output _and_ rewrite," never "output _or_
rewrite."

A stage cannot both suspend and rewrite in a single outcome; the type makes this exclusive by
construction.

## 3. Budget

### 3.1 `RewriteBudget`

```haskell
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax    :: Int  -- nodes added
  , rbAddedEdgesMax    :: Int  -- edges added
  , rbAddedDepthMax    :: Int  -- depth added below any anchor
  , rbFrontierDeltaMax :: Int  -- peak frontier breadth delta
  , rbRewriteOpsMax    :: Int  -- admitted rewrite operations
  }
```

Gas is **structural-change only** in v1. Semantic weighting (latency, cost class, effect class) is
not part of the budget and is deferred to a future ADR.

### 3.2 `RewriteCost`

Each admitted rewrite consumes a `RewriteCost` computed **statically** from its `SubgraphSpec`:

- `nodes` — count of new nodes introduced by the spec.
- `edges` — count of new edges (internal + reattachment edges from the anchor).
- `depth` — maximum depth increase below the anchor.
- `frontierDelta` — peak frontier-breadth increase attributable to the fragment.
- `ops` — 1 per admitted rewrite.

Admission draws only against remaining budget on every dimension. A proposal whose cost exceeds any
dimension is rejected with `rewrite_budget_exceeded`; no partial consumption.

### 3.3 Budget visibility

Remaining budget is persisted in graph state and surfaced on operator surfaces (run detail, rewrite
history). Each admitted rewrite records budget-before and budget-after snapshots so operators can
identify which rewrite exhausted which dimension.

## 4. Admission

Admission is the runtime's gate. A proposal is admitted only when **every** check passes.

### 4.1 Checks

1. **Vocabulary bounds.** Every node instance in the spec references a registered executor; every
   port contract is a registered `ContractId`. No executors or contracts outside the closed
   alphabet.
2. **Endpoint compatibility.** Every new edge connects ports whose contracts are compatible under
   the port-semantic rules of [chapter 05](../Architecture/05-wire-language.md). Singular and
   list-valued inputs obey the same arity rules at the rewrite boundary as at compile time.
3. **Topology validity.** The post-application materialized graph remains a DAG. The anchor exists
   in the current topology and definition map. Entry and exit sets are non-empty where the rewrite
   form requires them. No orphans, no dangling references.
4. **Resource bounds.** Estimated `RewriteCost` fits within the remaining budget on every dimension
   (§3.2).
5. **Runtime policy.** The anchor, the run, and the task type permit rewrites of this form. Planner
   nodes may be restricted to a subset of the algebra; the policy is consulted per proposal.

### 4.2 Rejection taxonomy

| Code                      | Failed check                                                     |
| ------------------------- | ---------------------------------------------------------------- |
| `invalid_rewrite`         | Spec structurally malformed, or uses a deferred / unknown form.  |
| `vocabulary_violation`    | Executor or contract not registered (check 1).                   |
| `cycle_introduced`        | Post-application graph is not a DAG (check 3).                   |
| `rewrite_budget_exceeded` | Static cost exceeds remaining budget on any dimension (check 4). |
| `policy_rejected`         | Runtime policy disallows this rewrite form here (check 5).       |

Each rejection carries a structured reason carrying at least the failing check and the proposing
node id.

### 4.3 Frontier-wave determinism

Admission is deterministic per frontier wave. Multiple frontier nodes may emit proposals in the same
wave. The runtime serializes admission against shared remaining budget, assigns monotone
`rewrite_id`s to admitted rows, and materializes admitted rows in `rewrite_id` order after frontier
classification.

This is deterministic ordered admission, not a commutation law for same-wave rewrites. Concurrent
frontier execution for ordinary (non-rewriting) nodes is unaffected.

### 4.4 Default policy on rejection

Default is **fail-fast**: the proposing node and its run fail with a legible error carrying the
rejection code. Task-specific fallback modes — structured-output-only continuation, operator
escalation — are deferred and require a new ADR.

## 5. Materialization

Admission and application are **separate events** with crash-safety obligations between them.

### 5.1 Rewrite log

Append-only. Each entry carries:

- the accepted rewrite specification (`GraphRewrite` + `SubgraphSpec`),
- the anchor's output needed to replay into inserted entry nodes (for retained and appended forms),
- the static `RewriteCost`,
- a monotone `rewrite_id`.

The log is the authoritative record of every admitted edit, in order.

### 5.2 Graph state

Carries two normative fields:

- **`watermark`** — highest `rewrite_id` materialized.
- **remaining budget** — per-dimension counters for all five budget axes.

### 5.3 Atomic commit

Materialization of a single rewrite applies all of the following in **one atomic commit**:

- node-state changes (new nodes inserted, anchor retained or replaced per mode),
- topology edges added or rewired,
- budget consumption,
- watermark advance.

No partial states are observable.

Admitted rewrite lineage may exist beyond the watermark. That means "admitted but not yet applied to
the materialized graph", not "applied but missing from persistence".

### 5.4 Resume through watermark

Resume reconstructs the materialized graph **only through the watermark**. If rewrite-log lineage
exists beyond the watermark, resume deterministically finishes materialization — in `rewrite_id`
order — before any scheduling decision.

Pre-watermark rewrite-capable runs are **legacy** and not guaranteed resumable. Any future watermark
schema change requires a runtime-version bump (see
[ADR 0011](./../ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md)).

## 6. Hydration

### 6.1 Keying

Hydration of rewritten stages is keyed by **stage-template identity** (`StageTemplateId`) — a
durable executable identity — and verified against **stage-action identity** (`StageActionId`) — the
action the template is expected to bind to. Hydration does not scan ad-hoc stage ids.

### 6.2 Duplicate template ids

A materialized plan may contain duplicate `StageTemplateId`s only when they map to the same
`StageActionId` and carry identical policy metadata. Any other duplication is rejected at hydration
with a structured failure.

### 6.3 Identity split

The normative split between `NodeId`, `stageId`, `StageTemplateId`, and `StageActionId` is stated in
the [Pulse types reference](./Pulse/types.md#3-stage-identity). Rewrite-capable plans must use
`NodeId` as the durable execution identity.

## 7. Structural provenance

For **every rewrite event**, admitted or rejected, the runtime persists:

- proposing node id and the originating `StageResult`,
- raw `GraphRewrite` proposal,
- admission decision — `admitted` or `rejected(code)` with the structured reason,
- static `RewriteCost` and post-admission **remaining budget**,
- structural diff applied (node-state changes, edge changes),
- any operator override (set / approved-by / reason).

### 7.1 Rejection rows

Rejected rewrites are **not** silently discarded. Rejection rows appear in the audit trail with the
same shape as admitted rows, minus the diff. Operators can inspect why a proposal was refused.

### 7.2 Exposure

Operator surfaces expose: the current materialized graph, the rewrite history per run, the remaining
budget, and any blocked or waiting reasons introduced by a rewrite. Surfaces are specified in the
admin-visibility decisions track ([ADR 0008](../ADRs/0008-pulse-operator-visibility-surfaces.md)).

## Related

- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
  — architectural framing.
- [./Pulse/types.md](./Pulse/types.md) — `StageResult`, identity types, retry policy.
- [./Pulse/schema.md](./Pulse/schema.md) — DB shape of runs, checkpoints, stage logs.
- [../ADRs/0005-budgeted-rewrite-admission-and-materialization.md](../ADRs/0005-budgeted-rewrite-admission-and-materialization.md)
  — gas and admission decision.
- [../ADRs/0009-rewrite-provenance-and-topology-integrity.md](../ADRs/0009-rewrite-provenance-and-topology-integrity.md)
  — provenance and integrity decision.
- [../ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md](../ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md)
  — watermark version discipline.

---

_End of Rewrites Reference._
