---
title: Graph Execution Engine v2
description: Architecture spec for Pulse graph execution v2 — bounded dynamic graph rewriting, concurrent frontier execution, rewrite budgets, and planner integration
---

# Graph Execution Engine v2 — Epic

**Status:** Proposed epic
**Last updated:** April 23, 2026 — DIG-544 (cross-references aligned with Wire v1 spec).

> **Related.** This page covers the execution-time side of bounded dynamic rewrites. The source language that produces the topology is specified at [`wire-v1-spec.md`](/docs/Reference/Wire/grammar-v1/) (normative grammar) and documented at [Cortex Wire Architecture](/docs/Architecture/05-wire-language/) (substrate).

## Summary

Graph Execution Engine v1 proved the core thesis: a durable runtime can use an algebraic graph as its execution topology rather than treating graphs as a presentation layer over an imperative workflow engine.

The current runtime already has a strong base:

* algebraic graph DSL (`Empty | Vertex | Overlay | Connect`) lowered to a concrete `Relation`
* DAG validation, topological analysis, SCC, DFS/BFS/PFS
* durable `GraphState` with node status and outputs
* frontier computation from graph semantics rather than stage index
* signal suspension (`NodeWaiting`) and durable wake-up
* replay policy and compatibility barriers
* legacy linear plans modeled as a degenerate graph path

Graph Execution Engine v2 turns that foundation into a **graph-native durable execution VM**.

The core step-change in v2 is this:

> a stage may return structured output, or it may spend bounded structural authority to rewrite the future execution graph.

This enables dynamic workflows, planner-generated subgraphs, repair branches, conditional fan-out, hierarchical execution, and richer operator control, while preserving durability, replayability, and analyzability.

The defining guardrail for v2 is **bounded graph evolution**. A run has a finite graph rewrite budget. Rewrites are admitted only if they fit within the budget and pass runtime safety checks.

---

## Why v2

v1 solves durable graph execution for static DAGs with suspension and resume. That is necessary but not sufficient for serious agentic runtime composition.

The next set of problems require graph evolution during execution:

* a planner discovers missing evidence and must insert a repair subgraph
* a reviewer expands a node into parallel validation branches
* a gatherer chooses one of several retrieval strategies based on runtime state
* a run must suspend for human input, then continue with a refined branch
* a runtime must bound fan-out and graph growth instead of trusting planner prompts to “be reasonable”

Without first-class graph rewriting, these behaviors either become ad hoc control flow in giant stage functions or devolve into loosely structured agent loops that are difficult to replay, inspect, or constrain.

v2 makes graph evolution explicit, durable, and budgeted.

---

## Product Thesis

Cortex Pulse should evolve from a durable stage runner into a **graph-native durable execution engine** with the following properties:

1. **Graph topology is executable state**, not just configuration.
2. **Graph evolution is explicit** via structured rewrites, not hidden inside stage-local imperative logic.
3. **Graph evolution is bounded** by per-run rewrite budgets and admission policies.
4. **Execution is partial-order native**: scheduling operates on ready frontiers, not stage indices.
5. **Replay safety is graph-aware**: deterministic, idempotent, irreversible, compensatable, and operator-gated semantics are carried by nodes and edges.
6. **Operator visibility is graph-native**: the system explains why a run is waiting, blocked, expanded, pruned, or rejected.
7. **Agentic orchestration becomes planner-over-graph**, not prompt-chained imperative tool loops.

---

## Goals

### Primary Goals

#### 1. Bounded dynamic graph rewriting

Introduce a structured graph rewrite model that allows a stage to propose changes to the execution graph at runtime.

Examples:

* expand a node into a subgraph
* append a repair branch after a node
* insert a precondition subgraph before a node
* prune a branch that is no longer needed
* add a join/gate node with explicit semantics

All rewrites must be admitted through runtime validation and budget checks.

#### 2. Rewrite budgets as runtime law

A run has a finite rewrite budget. Graph rewrites consume that budget.

The initial budget model should be explicit and auditable:

* maximum added nodes
* maximum added edges
* maximum added depth
* maximum added frontier breadth
* maximum number of rewrite operations

The budget is enforced by the runtime, not by planner prompts.

#### 3. Concurrent frontier execution

Independent ready nodes should execute concurrently within configurable resource limits.

Concurrency must preserve:

* durable graph state updates
* replay semantics
* signal suspension correctness
* deterministic auditability of graph evolution

#### 4. Hierarchical subgraphs

Support composite nodes whose execution expands into nested subgraphs with clear parent/child lifecycle semantics.

This enables reusable graph fragments and prevents top-level plans from becoming unreadable.

#### 5. Richer node and edge semantics

Move from plain dependency edges toward typed or annotated execution semantics, for example:

* hard dependency
* soft dependency
* quorum dependency (`k-of-n`)
* human-approval dependency
* temporal wait dependency
* compensation dependency

Readiness and scheduling should be driven by these semantics, not by a single “all predecessors completed or skipped” rule.

#### 6. Graph provenance and operator visibility

Persist not only current graph state, but also graph evolution history:

* rewrite proposal
* rewrite admission or rejection
* graph diff applied
* budget consumed
* operator override
* branch pruning reason

Operators should be able to inspect the current materialized graph and the sequence of graph evolution events that produced it.

#### 7. Static analysis and safety checks

Add graph-native analyzers before and during execution:

* cycle detection for proposed rewrites
* rewrite budget estimation
* irreversibility boundary analysis
* compensation coverage
* critical path estimation
* blocked frontier diagnosis
* unreachable node detection after rewrite

---

## Non-Goals

The following are explicitly out of scope for the first v2 delivery slices:

* unrestricted arbitrary graph mutation from model output
* unbounded recursive self-elaboration
* generic distributed multi-process graph execution across machines
* full child-workflow ecosystem with independent run lifecycles
* replacing the existing v1 static graph path immediately for all task types
* broad BPMN compatibility or external standards mapping
* “AI decides everything” runtime behavior without runtime policy control

v2 should harden the graph runtime model first. Large ecosystem or protocol expansion can follow later.

---

## Design Principles

### 1. Structured rewrites, not arbitrary mutation

A stage should propose a value from a closed rewrite algebra, not emit raw mutation commands over the entire materialized graph.

### 2. Runtime admission owns safety

Stages and planners may **propose** rewrites. Only the runtime may **admit** them.

### 3. Budget is a first-class resource

Graph shape is not free. Structural change consumes budget and is visible in run history.

### 4. Graph semantics remain pure below the runtime

Pure graph definitions, analysis, and rewrite validation should remain below Pulse-specific IO, DB, and scheduler concerns.

### 5. Durable provenance over implicit behavior

Every material graph evolution event must be explainable after the fact.

### 6. Backward compatibility via degenerate cases

Static DAGs and linear stage paths must remain valid v2 programs.

### 7. Semantic layer discipline

The generic graph kernel belongs in Cortex, not in application-specific task
machinery:

* `Cortex.Graph` owns pure graph algebra, graph state, rewrite algebra, and
  validation
* `Cortex.Wire` / `Cortex.Circuit` modules should own generic Wire source,
  circuit IR, provenance-friendly boundaries, and compiler targets
* `Cortex.Pulse` owns durable execution, scheduling, signal delivery, and
  materialization
* Portman owns finance-domain workflow ASTs, finance-specific rewrite intents,
  and compilation from product requests into generic Cortex circuits

This means v2 should not revive stringly workflow planning surfaces such as
`workflowStageGraph` as an executable contract. Product or domain semantics
must compile down into generic Cortex workflow/graph representations.

---

## Target Runtime Model

Graph Execution Engine v2 introduces a layered execution model:

### 1. Plan graph

The initial graph declared by the task definition.

### 2. Materialized graph

The current executable graph after applying admitted rewrites.

### 3. Rewrite log

Append-only history of proposed, accepted, rejected, and operator-overridden rewrites.

### 4. Graph state

Per-node execution state:

* status
* outputs
* waiting or signal metadata
* attempt counters
* timing and observability metadata

### 5. Budget state

Current remaining structural authority for the run.

### 6. Scheduler view

Computed frontier, blocked reasons, critical path hints, concurrency limits, and queue decisions.

This model should support deterministic reconstruction of the current graph and its execution state from durable storage.

---

## Core v2 Concepts

### 1. Rewrite-capable stage outcome

Introduce a richer stage result shape.

```haskell
data StageResult
  = StageComplete Aeson.Value
  | StageSuspend SignalName
  | StageRewrite Aeson.Value GraphRewrite
```

A rewrite-producing stage does not mutate the graph directly. It emits both a
forward fact for the rewriting node and a structured proposal for future graph
evolution.

`StageRewrite output rewrite` is therefore not "output or rewrite". It is one
result carrying the node's durable output together with the proposed rewrite.
This is required for `AppendAfter` and `ExpandRetainNodeAsEnvelope`, where the
inserted entry nodes depend on the rewriting node's output.

The corresponding runtime node outcome is `OutcomeRewritten output rewriteJson`.
It is:

* terminal for the current scheduling wave
* predecessor-satisfying for downstream readiness checks on the old boundary
* output-preserving unless the rewrite mode removes the node from the
  materialized graph

**Implementation note:** in code, this extends the existing `StageResult` type with a `StageRewrite` constructor rather than introducing a separate V2 type. The V2 suffix here is for spec clarity only.

### 2. Structured rewrite algebra

The first delivery should keep the rewrite algebra intentionally narrow and high-signal.

```haskell
data GraphRewrite
  = ExpandNode NodeId ExpansionMode SubgraphSpec
  | AppendAfter NodeId SubgraphSpec
```

These two constructors cover the most valuable first dynamic patterns:

* planner expands a node into a repair or evidence-gathering subgraph
* reviewer or controller appends follow-up validation after a node

The following forms are recognized as likely future work but are explicitly deferred until a real task needs them:

* `InsertBefore`
* `PruneSubgraph`
* `AddJoin`
* `ReplaceNode`

### 3. SubgraphSpec

`SubgraphSpec` is the portable description of the graph fragment introduced by a rewrite.

Illustrative initial shape:

```haskell
data SubgraphSpec = SubgraphSpec
  { sgsTopology :: Graph LocalRewriteNodeId
  , sgsDefinitions :: Map LocalRewriteNodeId StageDefinitionV2
  , sgsEntryNodes :: [LocalRewriteNodeId]
  , sgsExitNodes :: [LocalRewriteNodeId]
  }
```

Initial requirements:

* the subgraph must define its own local topology
* the subgraph must carry stage definitions for every local node
* entry nodes define where inbound dependencies attach
* exit nodes define where outbound dependencies continue
* validation must reject malformed specs:
  * missing definitions
  * definitions for nodes outside the inserted subgraph
  * entry/exit nodes outside the inserted subgraph
  * empty entry/exit sets where the rewrite form requires them
  * orphan inserted nodes
  * cycles in the resulting materialized graph

The concrete type names may change, but the implementation path requires these concepts.

### 4. ExpansionMode

`ExpansionMode` controls how an expanded node connects to the surrounding graph.

Initial direction:

```haskell
data ExpansionMode
  = ExpandReplaceNode
  | ExpandRetainNodeAsEnvelope
```

Meaning:

* `ExpandReplaceNode`: inbound edges to the original node are rewired to the subgraph entry nodes; outbound edges are rewired from the subgraph exit nodes; the original node becomes a structural placeholder or is retired from scheduling
* `ExpandRetainNodeAsEnvelope`: the original node remains as a durable boundary node and owns the lifecycle of the inserted subgraph

The first implementation should choose **one** of these modes and defer the other unless needed. The runtime must not ship multiple expansion semantics unless one is concretely used.

### 5. Rewrite budget

Introduce a first-class budget record.

```haskell
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax    :: Int
  , rbAddedEdgesMax    :: Int
  , rbAddedDepthMax    :: Int
  , rbFrontierDeltaMax :: Int
  , rbRewriteOpsMax    :: Int
  }
```

And a corresponding consumed-cost value:

```haskell
data RewriteCost = RewriteCost
  { rcAddedNodes    :: Int
  , rcAddedEdges    :: Int
  , rcAddedDepth    :: Int
  , rcFrontierDelta :: Int
  , rcRewriteOps    :: Int
  }
```

Initial budget policy is **structural only**. Semantic weighting is explicitly deferred.

Admission requires:

1. rewrite validates structurally
2. rewrite preserves graph invariants
3. estimated cost fits remaining budget
4. runtime policy allows the rewrite for this node, run, and task type

### 6. Durable identities

Rewrite-capable execution uses three distinct identities:

* `NodeId`: durable execution identity for graph state, stage logs,
  checkpoints, replay checks, and observability
* `StageTemplateId`: durable executable identity used to rehydrate actions and
  retry policy from a runtime-local registry
* `stageId`: semantic stage kind / operator-facing label

Implications:

* `NodeId` is the only persisted execution identity for rewrite-capable graph
  runs
* duplicate `stageId` values are legal
* duplicate `StageTemplateId` values mean identical executable semantics and
  retry semantics
* hydration by scanning `stageId` is not part of the target design

### 7. Deterministic node identity allocation

To ensure global uniqueness and replay stability, all nodes introduced by a rewrite are namespaced using the parent node's ID:

```text
{parent_node_id}:{local_subgraph_node_id}
```

Examples:
* `reviewer:evidence_fetch`
* `reviewer:critique`
* `planner:repair_branch_1`

This scheme is recursive: if `planner:repair_branch_1` further expands, its children become `planner:repair_branch_1:step_1`, etc.

### 8. Rewrite timing invariant

Rewrite application timing must be explicit.

Initial invariant:

* a stage returns `StageRewrite`
* the runtime validates and admits or rejects the rewrite immediately after that stage result
* the admitted rewrite is applied before the next `readyNodes` computation
* the admitted rewrite is applied before the runtime may conclude completion,
  suspension, or stuckness from the old topology
* the current shipped runtime permits concurrent frontier execution for
  ordinary nodes, and multiple frontier nodes may emit rewrites in one wave
* same-wave rewrites are admitted in deterministic order against shared
  remaining budget, then materialized in rewrite-id order
* a stronger commutation law for truly concurrent rewrite admission remains
  deferred until rewrite semantics and materialized-graph persistence are proven

This keeps graph evolution deterministic and easy to reason about.

### 9. Materialization and crash consistency

Rewrite provenance and rewrite materialization are distinct.

The normative durability model is:

* `graph_rewrites` is append-only provenance
* durable graph state carries a monotone materialization watermark such as
  `applied_rewrite_id`
* retained/appended rewrite lineage also persists the source node output needed
  to restore the rewritten anchor before scheduling resumes
* durable graph state carries `remaining_rewrite_budget`; materialization
  applies node-state changes, budget consumption, and watermark advance in one
  atomic commit
* the watermark means all rewrite events up to that id have been reflected into
  durable graph state
* resume reconstructs the materialized graph only through the watermark
* if rewrite lineage exists beyond the watermark, resume must deterministically
  finish materialization before any scheduling decision

This avoids relying on raw lineage replay alone and makes crash recovery
explicit at the rewrite boundary.

Adopting template-registry hydration and watermark-based materialization
requires a runtime/checkpoint version bump. Pre-watermark rewrite-capable runs
are legacy and are not guaranteed resumable across that semantic cut.

### 10. Public interface implications

The target rewrite-capable interfaces should make the above identity split
explicit:

* `StageDefinition` gains `sdTemplateId :: StageTemplateId`
* `StageDefinition` gains `sdActionId :: StageActionId`
* `SerializableStageDefinition` gains `ssdTemplateId :: StageTemplateId`
* `SerializableStageDefinition` gains `ssdActionId :: StageActionId`
* hydration is keyed by `StageTemplateId`, then verified against
  `StageActionId`, not by scanning `stageId`
* duplicate `StageTemplateId`s within a materialized plan are strictly
  rejected unless they map to the same `StageActionId` and identical policy
  metadata (including the `StageRetryPolicy` predicate name), safely allowing
  idempotent cloning
* retry-policy semantics are recovered from the runtime registry entry for the
  template/action pair
* graph-state persistence gains `applied_rewrite_id` or an equivalent monotone
  materialization watermark
* graph-state persistence also carries `remaining_rewrite_budget`
* rewrite lineage rows persist `source_node_output` and `rewrite_cost`
* `graph_rewrites` remains append-only provenance and is not the sole source of
  current graph materialization state

### 11. Rewrite rejection policy

Rewrite rejection must be explicit.

Current shipped policy:

* reject the rewrite
* fail the node/run with a structured reason such as
  `invalid_rewrite` or `rewrite_budget_exceeded`

The runtime must not silently discard a rejected rewrite.

Deferred policy work:

* task-specific rejection fallback
* continue-with-structured-output modes
* operator escalation or planner-visible rejection handling

### 12. Future considerations for node semantics

The following node metadata ideas are recognized as valuable but are **not initial delivery commitments**:

* compensation capability
* cost class
* priority class
* richer semantic effect classes beyond current replay-safety concepts

They should be introduced only when they have a concrete execution path and delivery slice.

## Delivery Plan

## Phase 0 — Foundation hardening

**Goal:** close the remaining correctness and operator-surface gaps in the shipped graph runtime.

Status: **Done for the current v2.1 scope**.

Current reality:

* graph DSL, executor, durable graph state, signals, and resume shipped in `DIG-345`
* failure-state hardening landed after the initial graph execution rollout
* admin signal delivery endpoint and operator surface shipped in `DIG-423`
* concurrent frontier execution is shipped
* rewrite-capable execution now ships with:
  * watermark-based materialization
  * persisted `source_node_output` for retained/appended replay
  * durable `remaining_rewrite_budget`
  * `StageTemplateId` + `StageActionId` hydration checks
  * pure rewrite planning in `Cortex.Graph`
  * monotone `NodeInterrupted` states with resume normalization

Slices:

* tighten any remaining graph-state persistence invariants where needed
* improve stuck-graph diagnostics and blocked-node reporting where needed
* keep graph runtime tests strong around resume, waiting, and failure
* keep deferred rewrite semantics explicit rather than implied

## Phase 1 — Concurrent frontier execution

**Goal:** exploit partial-order parallelism for existing static graph tasks before introducing graph mutation.

Status: **Shipped for the current runtime scope**.

Rationale:

* immediate value for existing tasks
* originally independent of rewrite semantics
* proved the runtime under concurrent load before adding bounded structural mutation
* builds directly on current frontier computation and ready-node machinery

Slices:

* concurrent ready-node execution
* per-run concurrency cap
* deterministic graph-state update discipline
* race-heavy integration test suite
* observability for frontier scheduling and concurrent node completion

## Phase 2 — Rewrite core and budgets

**Goal:** introduce bounded graph evolution after concurrent execution has been proven.

Status: **Core shipped for the current v2.1 scope**.

Slices:

* narrow structured rewrite algebra
* rewrite validation and application
* rewrite budgets and admission policy
* rewrite rejection reasons
* single-rewrite-per-frontier dynamic graph execution first
* watermark-based materialization boundary for crash-safe resume
* template-registry hydration for rewritten stages

Deferred within this phase:

* configurable rejection fallback policy
* true concurrent rewrite admission
* richer rewrite forms beyond the current narrow algebra

Initial rewrite scope is intentionally narrow:

* `ExpandNode`
* `AppendAfter`

These cover the most valuable first patterns:

* planner inserts repair or evidence-gathering branch
* reviewer expands a node into validation or critique branches

The following rewrite forms are explicitly deferred until justified by real use:

* `InsertBefore`
* `PruneSubgraph`
* `AddJoin`
* `ReplaceNode`

## Phase 3 — Materialized graph persistence and operator visibility

**Goal:** make the dynamic graph inspectable, reconstructable, and operationally legible.

Slices:

* rewrite event persistence
* materialized graph reconstruction model
* applied rewrite watermark on graph state
* admin read API for current graph
* admin read API for rewrite history
* blocked and waiting reason surfaces
* budget state visibility

## Phase 4 — Hierarchical subgraphs and richer semantics

**Goal:** widen composition only after rewrite-capable execution has been proven on a real task.

Slices:

* composite nodes or nested graphs
* explicit sub-budget assignment for child graphs
* selected richer semantics only when demanded by real use
* deeper operator introspection for graph-of-graphs execution

## Phase 5 — Planner integration

**Goal:** make planners first-class graph-producing citizens of the runtime.

Slices:

* planner nodes that may propose rewrites
* policy-gated rewrite authority
* budget-aware planner contracts
* operator escalation on rewrite rejection or budget exhaustion
* first rewrite-capable validation task

**Named validation candidate:**

The preferred first rewrite-capable real task is **PaperPortfolioCycle**, because it naturally contains strategy-driven conditional branching, evidence repair, and validation expansion patterns. If portfolio-cycle coupling proves too heavy, the fallback is a dedicated **AgentPlannerTask** used purely to validate rewrite-capable runtime behavior.

## Acceptance Criteria for the Epic

The epic is complete when all of the following are true:

1. A task run can execute from an initial static graph and admit bounded runtime graph rewrites durably.
2. Rewrites are validated, budgeted, and recorded in durable provenance.
3. The runtime can reconstruct the current materialized graph after crash or restart.
4. Independent frontier nodes can execute concurrently with preserved correctness.
5. Operators can inspect the current graph, rewrite history, blocked reasons, waiting reasons, and remaining budget.
6. Static graph tasks remain supported without rewrite-specific coupling.
7. At least one real task type uses rewrite-capable execution in production or controlled staging.

---

## Risks

### 1. Graph-state complexity explosion

Dynamic graph evolution plus concurrency can make the executor hard to reason about if introduced too early or without clear layering.

**Mitigation:**

* keep concurrent frontier execution separate from concurrent rewrite admission
* keep rewrite core pure and small
* introduce rewrite-capable execution first in a single-rewrite-per-frontier mode
* preserve explicit durable event history

### 2. Planner over-elaboration

A model may keep expanding the graph instead of converging.

**Mitigation:**

* hard rewrite budgets
* per-node rewrite authority flags
* rejection + fallback policy
* operator escalation path

### 3. Replay ambiguity after rewrite

If rewrite provenance is incomplete, crash recovery may reconstruct the wrong materialized graph.

**Mitigation:**

* append-only rewrite log
* explicit rewrite materialization watermark
* deterministic rewrite application
* materialized graph checksum or equivalent integrity guard

### 4. Operator invisibility

Dynamic graphs are dangerous if operators cannot see why the graph changed.

**Mitigation:**

* make rewrite history and blocked reasons part of the admin surface from the beginning

### 5. Premature edge-semantics explosion

Too many edge kinds too early can collapse clarity.

**Mitigation:**

* start with one or two additional semantics beyond hard dependency
* keep the readiness model explicit and testable

---

## Open Questions

The following questions are considered resolved for the initial v2 delivery path:

1. **Weighted vs structural budgets**

   * Decision: start with **structural-only** budgets.
   * Rationale: semantic weighting is valuable but premature for the first rewrite-capable runtime.

2. **Child budget inheritance**

   * Decision: use **explicit sub-budget assignment**, not fractions.
   * Rationale: explicit assignment is easier to reason about and audit.

3. **Rewrite rejection behavior**

   * Decision: the shipped runtime is **fail-fast with a structured error**.
   * Deferred direction: configurable per-task fallback remains future work,
     including a possible structured-output-only mode.

4. **Minimal initial planner rewrite surface**

   * Decision: planner-produced rewrites are initially restricted to:

     * `ExpandNode`
     * `AppendAfter`

The following questions remain open:

1. What is the minimal first rewrite-capable production task: `PaperPortfolioCycle` directly, or a dedicated `AgentPlannerTask` validation target first?
2. How much of the materialized graph should be stored directly versus reconstructed from plan graph plus rewrite log?
3. Where should graph visualization land first: API payloads only, or explicit admin UI work in the same epic?
4. What is the first real use case that justifies moving beyond hard-dependency edge semantics?
5. When should the runtime move from single-rewrite-per-frontier admission to
   true concurrent rewrite admission?
6. What is the minimal operator-facing contract for rejected rewrites beyond
   current fail-fast diagnostics?

## Expected Outcome

If this epic succeeds, Cortex Pulse will no longer be merely a durable runner for fixed stage plans.

It will become a **bounded, analyzable, graph-native durable execution engine** where:

* workflows can evolve during execution
* the runtime remains in control of safety and growth
* operators can explain what happened and why
* static and dynamic graphs share one semantic foundation
* agent planners synthesize and refine executable graph structure rather than improvising opaque tool loops

That is the intended end state for Graph Execution Engine v2.

---

## Proposed Issue Backlog

The following issue set is intentionally pragmatic and follows the recommended phase order.

### Phase 0 — Foundation hardening

#### DIG-423 — Add admin signal delivery endpoint for waiting graph runs

Status: shipped in `DIG-423`.

**Goal**

Expose an operator-facing endpoint that delivers a named signal to a waiting run and wakes it safely.

**Scope**

* Pulse API endpoint for signal delivery
* Portman admin proxy or CLI surface
* validation that signal exists and is pending
* durable wake-up of waiting run
* audit and observability events

**Acceptance Criteria**

* operator can deliver a signal to a waiting run
* delivered signal transitions the run back into scheduler-visible execution state
* duplicate delivery is safe and returns a clear outcome
* operator surface shows success, not-found, already-delivered, and invalid-signal cases clearly

#### DIG-424 — Strengthen blocked-graph diagnostics and admin visibility

**Goal**

Improve operator visibility when a graph has no ready nodes but is not complete.

**Scope**

* richer blocked-node reason computation
* structured reporting of failed predecessors, waiting predecessors, and unsatisfied dependencies
* admin API payload improvements
* tests for representative stuck-graph scenarios

**Acceptance Criteria**

* operator can see exactly why a node is not ready
* stuck-run diagnostics distinguish waiting, failed-blocked, and inconsistent-state cases

### Phase 1 — Concurrent frontier execution

#### DIG-416 — Execute independent frontier nodes concurrently within a run

**Goal**

Allow multiple ready nodes from the same run to execute concurrently under a bounded per-run cap.

**Scope**

* frontier partitioning into concurrently runnable nodes
* per-run concurrency configuration
* graph-state coordination for completion, failure, waiting, and shutdown
* deterministic state transition discipline

**Acceptance Criteria**

* multiple ready nodes can run concurrently without state corruption
* failure and waiting semantics remain correct under concurrency
* scheduler and audit logs remain coherent

#### DIG-416 sub-slice — Add race-focused integration tests for concurrent graph execution

**Goal**

Prove concurrent frontier execution with targeted race and crash scenarios.

**Scope**

* concurrent completion of sibling nodes
* one sibling fails while another suspends
* shutdown during concurrent frontier execution
* resume after partially completed concurrent frontier
* repeated signal delivery during concurrent execution

**Acceptance Criteria**

* test suite covers race-heavy execution paths
* no invalid or unrecoverable graph states are produced

#### DIG-416 sub-slice — Add observability for frontier scheduling and concurrent node lifecycle

**Goal**

Make concurrent graph execution legible in logs and admin inspection.

**Scope**

* frontier size and scheduling events
* per-node start/completion/wait/failure events with graph context
* concurrency-cap hit visibility
* optional critical-path timing fields where cheap to compute

**Acceptance Criteria**

* operators can see when frontier concurrency was used and what happened within it

### Phase 2 — Rewrite core and budgets

#### DIG-417 — Introduce structured GraphRewrite core with ExpandNode and AppendAfter

**Goal**

Add the first narrow, typed rewrite algebra for runtime graph evolution.

**Scope**

* `GraphRewrite` type with `ExpandNode` and `AppendAfter`
* pure validation and application layer
* node identity allocation strategy for expanded nodes
* replay-safe rewrite application rules

**Acceptance Criteria**

* valid rewrites can be applied deterministically to the materialized graph
* invalid rewrites fail with structured reasons
* no cycles or dangling references can be introduced

#### DIG-418 — Add structural RewriteBudget and RewriteCost admission checks

**Goal**

Bound dynamic graph evolution with runtime-enforced structural budgets.

**Scope**

* `RewriteBudget` and `RewriteCost`
* static rewrite cost estimation
* admission checks before rewrite application
* budget consumption persistence
* structured rejection reasons

**Acceptance Criteria**

* rewrites that exceed budget are rejected before mutation
* remaining budget is durable and inspectable
* structural-only budget model is used initially

#### DIG-418 sub-slice — Add task-type rewrite rejection fallback policy

**Goal**

Widen rewrite rejection behavior beyond the shipped fail-fast baseline.

**Scope**

* per-task-type configuration
* optional fallback modes such as structured-output-only continuation
* observability and audit visibility for rejection path

**Acceptance Criteria**

* rejected rewrites never disappear silently
* task type can choose among explicitly supported rejection policies

#### DIG-417 sub-slice — Add single-rewrite-per-frontier rewrite-capable execution path

**Goal**

Run rewrite-capable execution in a simpler mode first, before combining
rewrite admission with concurrent frontier mutation.

**Scope**

* stage result handling for `StageRewrite`
* rewrite admission, application, and continuation of the run
* crash/resume semantics for admitted rewrites
* integration tests for rewrite-heavy single-run execution

**Acceptance Criteria**

* a run can admit rewrites and continue correctly without concurrency
* crash/restart reconstructs the same materialized graph and execution state

### Phase 3 — Materialized graph persistence and operator visibility

#### DIG-419 — Persist materialized graph evolution and rewrite provenance

**Goal**

Store enough durable information to reconstruct the graph after rewrites.

**Scope**

* schema for rewrite events or graph diffs
* graph reconstruction strategy
* integrity checks or checksums where useful
* migration plan for runs with static graphs only

**Acceptance Criteria**

* runtime can reconstruct the current graph after restart
* rewrite history is append-only and auditable
* admitted rewrite history includes structural delta and budget movement

#### DIG-420 — Add admin read API for current materialized graph and budget state

**Goal**

Expose the current graph shape and remaining structural budget to operators.

**Scope**

* current graph payload shape
* remaining budget payload shape
* applied rewrite watermark in the operator surface
* node state summary in graph context
* blocked or waiting annotations in admin run detail

**Acceptance Criteria**

* operator can inspect current graph, remaining budget, applied rewrite watermark, and basic blocked/waiting annotations for a run

#### DIG-420 sub-slice — Add admin read API for rewrite history and blocked reasons

**Goal**

Expose the graph evolution story, not just the current graph snapshot.

**Scope**

* rewrite history endpoint or run detail expansion
* structured blocked reasons
* rejected-rewrite history
* operator override visibility if present

**Acceptance Criteria**

* operator can answer what rewrites happened for a run
* operator can answer which nodes are blocked or waiting from the admin surface

### Phase 4 — Hierarchical subgraphs and richer semantics

#### DIG-421 — Introduce composite node and nested subgraph execution model

**Goal**

Add hierarchical graph composition only after rewrite-capable execution is proven.

**Scope**

* parent or child graph boundary semantics
* summarized output contract for nested graphs
* explicit sub-budget assignment for child graphs
* drill-down inspection model

**Acceptance Criteria**

* nested graph execution is durable and inspectable
* child graphs consume explicitly assigned sub-budgets

#### DIG-421 sub-slice — Evaluate first richer execution semantics beyond hard dependency

**Goal**

Introduce additional edge or join semantics only when justified by a concrete task need.

**Scope**

* select one justified semantic extension
* readiness evaluator update
* blocked-reason diagnostics for the new semantic
* tests and documentation

**Acceptance Criteria**

* one real task uses a non-trivial readiness semantic successfully

### Phase 5 — Planner integration

#### DIG-422 — Integrate planner-produced rewrites with restricted authority

**Goal**

Allow planner nodes to propose rewrites while keeping runtime safety in control.

**Scope**

* planner nodes may emit only `ExpandNode` and `AppendAfter` initially
* policy gate for rewrite-capable nodes
* budget-aware planner contract
* rejection and escalation path

**Acceptance Criteria**

* planner-produced rewrites are bounded, validated, and replay-safe
* planner cannot emit unrestricted graph mutation

#### DIG-422 sub-slice — Validate rewrite-capable execution on first real task

**Goal**

Choose and land the first real task that uses rewrite-capable execution.

**Preferred candidate**

* `PaperPortfolioCycle`

**Fallback candidate**

* dedicated `AgentPlannerTask`

**Scope**

* identify one concrete rewrite pattern in the task
* execute it using the narrow initial rewrite algebra
* prove operator visibility and restart semantics

**Acceptance Criteria**

* at least one real task executes with rewrite-capable runtime behavior in staging or production-like validation

#### DIG-422 sub-slice — Add operator escalation path for budget exhaustion and rewrite rejection

**Goal**

Provide a clean operational path when graph evolution is denied.

**Scope**

* operator-visible budget exhaustion state
* escalation event model
* optional human review or override hook where appropriate
* task-type policy wiring

**Acceptance Criteria**

* budget exhaustion or rewrite rejection results in a legible, operator-manageable run state rather than opaque failure
