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
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
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

Entry and exit declarations are serialized as lists but are semantically sets. Duplicate entry or
exit nodes are invalid. Validation rejects duplicates, missing definitions, orphan nodes,
definitions outside the fragment, and any cycle in the resulting materialized graph.

New node ids inside a spec are deterministic and namespaced by their parent anchor (for example
`planner:repair_branch_1:step_1`). Deterministic namespacing is required so identity is stable
across replay. Local node ids inside the inserted spec must be non-empty and must not contain the
namespace delimiter `:`. After namespacing, inserted node ids must also be fresh against the current
topology; a proposal that would collide with an existing node is rejected before planning continues.

### 1.3 Deferred forms

The following constructors are recognized future forms but **not part of the admitted alphabet in
v1**: `InsertBefore`, `PruneSubgraph`, `AddJoin`, `ReplaceNode`. Introducing any of them requires a
new ADR and a runtime-version bump.

### 1.4 Boundary laws and runtime constructors

The v1 constructors are operational forms. The conceptual boundary laws are the stable semantic
vocabulary:

| Boundary law                     | v1 realization                | Contract/resource effect                                                                           |
| -------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------- |
| Contract-preserving substitution | `ExpandNode anchor mode spec` | Consumes one rewrite slot and the anchor boundary; the replacement exposes the consumed boundary.  |
| Append continuation              | `AppendAfter anchor spec`     | Consumes one rewrite slot while retaining the anchor; the continuation consumes the anchor output. |
| Conditional branch actualization | `AppendAfter anchor spec`     | When the anchor is a conditional owner, the selected guarded branch becomes live topology.         |

`SelectActualize owner selectedArm` is the compiler/proof vocabulary for the restricted
actualization capability of a compiled `select(...)`. It is not a v1 `GraphRewrite` constructor and
is not a separately persisted runtime token. Current runtime materialization records the admitted
selected branch as an ordinary rewrite row.

Observation/instrumentation is future boundary-law vocabulary only. There is no admitted v1
constructor for it, and observers must not consume or alter the anchor boundary unless a later ADR
adds a resource path.

## 2. Stage-result extension

Stages signal rewrite proposals through a richer `StageResult`:

```haskell
data StageResult
  = StageComplete Aeson.Value
  | StageSuspend  SignalName
  | StageRewrite  Aeson.Value GraphRewrite
  | StageLoopStep Aeson.Value LoopStepWitness GraphRewrite
```

`StageRewrite` carries **both** the stage's durable output and the proposed edit. Retained or
appended subgraphs whose entry nodes depend on that output read it from the retained anchor on
resume (see §5.1). Producing a rewrite is therefore "output _and_ rewrite," never "output _or_
rewrite." `StageLoopStep` is the certified self-append form; it carries the same durable output plus
the loop-frontier witness the executor must check before gas-neutral admission. The registration's
bound source decides what gates each step: an iteration-capped registration (ADR 0055) admits
`witnessed` against the finite per-run bound, while an externally-driven registration (ADR 0088)
admits `external` — bounded by one delivered durable signal per step via the delivery-entry law,
with an optional operator step valve. Either way the path is authorized by the run's loop
registration: static policy, bound state, and mutable loop control. A static policy match alone is
not enough to admit a gas-neutral append.

A stage cannot both suspend and rewrite in a single outcome; the type makes this exclusive by
construction.

## 3. Budget

### 3.1 `RewriteBudget`

```haskell
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax    :: Natural  -- nodes added
  , rbAddedEdgesMax    :: Natural  -- edges added
  , rbAddedDepthMax    :: Natural  -- depth added below any anchor
  , rbFrontierDeltaMax :: Natural  -- peak frontier breadth delta
  , rbRewriteOpsMax    :: Natural  -- admitted rewrite operations
  }
```

Gas dimensions are natural quantities. Negative serialized values are invalid and fail before
admission. Gas is **structural-change only** in v1. Semantic weighting (latency, cost class, effect
class) is not part of the budget and is deferred to a future ADR.

### 3.2 `RewriteCost`

Each admitted rewrite consumes a `RewriteCost` computed **statically** from its `SubgraphSpec`:

- `nodes` — count of new nodes introduced by the spec.
- `edges` — count of new edges (internal + reattachment edges from the anchor).
- `depth` — maximum depth increase below the anchor.
- `frontierDelta` — peak frontier-breadth increase attributable to the fragment.
- `ops` — 1 per admitted rewrite.

Admission draws only against remaining budget on every dimension. A proposal whose cost exceeds any
dimension is rejected with `rewrite_budget_exceeded`; no partial consumption.

The proof contract is the leader here: runtime `RewriteBudget` and `RewriteCost` use the same
natural-vector shape as the mechanized rewrite-admission model, and runtime validation rejects list
or JSON shapes that cannot denote the proof-side sets and natural numbers.

### 3.3 Selected-cost latent branches

Latent branch families use selected-cost accounting in the current runtime:

- unselected arms do not consume runtime rewrite budget;
- the selected arm consumes ordinary rewrite budget when actualized;
- branch actualization is admitted or rejected through the same durable rewrite admission path as
  other topology changes;
- the runtime does not yet reserve capacity for every compiled latent arm.

This differs from max-reserved capacity. A future reservation policy would need to say whether it
reserves `max(branchCosts)`, reserves per branch family, or changes the rewrite-budget algebra.

### 3.4 Budget visibility

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
   cardinality-one inputs obey the same arity rules at the rewrite boundary as at compile time;
   aggregation must be expressed by explicit transformation nodes.
3. **Topology validity.** The post-application materialized graph remains a DAG. The anchor exists
   in the current topology and definition map, and the current definition domain exactly covers the
   current topology. Entry and exit sets are non-empty and duplicate-free where the rewrite form
   requires them. Definition-domain updates follow the anchor disposition: replacing an anchor
   deletes its definition before overlaying inserted definitions; retaining or appending keeps the
   old domain and overlays inserted definitions. No orphans, no dangling references.
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

For selected branches, the admitted selected rewrite is the durable fact replayed by recovery.
Unselected latent arms remain sealed alternatives in the compiled artifact and are not materialized
for that run. The current model has no durable "discard branch" event.

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
- the **admission mode** (`gassed`, `witnessed`, or `external`): a gassed rewrite debits the budget
  at admission; a witnessed compile-bounded step (a runtime-bounded-iteration self-append, ADR 0055
  / ADR 0056) records its cost but is gas-neutral; an externally-driven step (ADR 0088) is likewise
  gas-neutral with its repetition bounded by one delivered durable signal per step. Recovery
  re-validates witnessed and external rows against the loop registration and replays them
  gas-neutral rather than trusting the stored tag,
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
- [../ADRs/0032-wire-boundary-contract-resources.md](../ADRs/0032-wire-boundary-contract-resources.md)
  — boundary obligations as planning resources.
- [../ADRs/0034-wire-pure-select-actualization-authority.md](../ADRs/0034-wire-pure-select-actualization-authority.md)
  — pure selectors and restricted actualization authority.
- [../ADRs/0035-wire-rewrite-algebra-forms.md](../ADRs/0035-wire-rewrite-algebra-forms.md) —
  conceptual boundary laws and v1 runtime constructors.
- [../ADRs/0036-wire-latent-branch-budget-recovery.md](../ADRs/0036-wire-latent-branch-budget-recovery.md)
  — selected-cost branch actualization and recovery policy.

---

_End of Rewrites Reference._
