---
title: "Research Memo: Current Main Graph Runtime Synthesis"
description: Cross-source synthesis of the graph-based durable runtime on current main, with issue plans for provenance/integrity, checkpoint unification, and Cortex.Workflow lowering
---

# Research Memo: Current Main Graph Runtime Synthesis

**Date:** 2026-04-09  
**Scope:** current `main` branch state of `Cortex.Graph`, `Cortex.Pulse`, admin/runtime inspection, `Cortex.Workflow`, nearby issues/PRs, and external prior art on durable execution and graph transformation  
**Artifacts examined:** implementation, tests, architecture docs, GitHub issues `#875 #876 #878 #879 #912 #913 #925 #934`, PRs `#935 #936`, external literature/docs  
**Method:** implementation-first cross-reference synthesis  
**Confidence profile:** high on implementation and issue-trajectory claims; medium on broader theory-to-roadmap extrapolations

---

## Executive Summary

Current `main` has moved further than the recent internal memos imply. The runtime is no longer just recovery-capable with partial operator visibility: it now has a canonical admin graph snapshot, blocked/waiting diagnostics, rewrite history, runtime-version-aware admin reconstruction, and watermark-filtered history.

The main unresolved foundation problems are now:

1. integrity of reconstructed views
2. unifying the still-split durable execution models
3. turning `Cortex.Workflow` from descriptive IR into an executable lowering boundary
4. proving stronger convergence properties before hierarchical or planner rewrites

The strategic center of gravity has shifted from "can the runtime survive crash and replay?" to "can operators trust what they see, and can future workflow compilation preserve those guarantees?".

---

## Key Findings

### [P1] The operator surface is now first-class, but it is still reconstructive rather than self-authenticating
**Category:** Correctness Gap  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `src/Portman/Server/Admin/API.hs`, `src/Portman/Server/Admin/Handler.hs`, `src/Cortex/Pulse/Executor.hs`, `sql/045_pulse_graph_rewrites.sql`, `sql/048_pulse_graph_rewrite_provenance.sql`, issue `#876`  
**Cross-reference:** PR `#935`, PR `#936`

Current `main` does have a canonical `AdminGraphSnapshot`; the earlier "no first-class graph payload yet" framing is already stale. But the snapshot is still derived by replaying persisted lineage against the current registered task-type plan plus `runtime_version`, not by reading a durably witnessed materialized topology.

**Why it matters:**  
This is good enough for inspection, but not yet for independent trust. The system can explain the graph by reconstruction; it still cannot cheaply prove that reconstruction and stored state agree.

**Next step:**  
Keep `#876` focused on an integrity witness: checksum, lowering fingerprint, or equivalent consistency guard tied to `graph_state` plus watermark.

### [P1] `runtime_version` is the right law today, but it will be too weak once `Cortex.Workflow` lowering starts changing
**Category:** Extension Risk  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `src/Cortex/Pulse/Executor.hs`, `src/Cortex/Pulse/Query.hs`, `test/Cortex/Pulse/ExecutorSpec.hs`, issue `#934`  
**Cross-reference:** Temporal determinism/versioning guidance; Restate durable execution guidance

The repo now consistently treats runtime-version mismatch as a compatibility boundary for both resume and admin reads. That matches durable-execution prior art: code changes must preserve deterministic replay or be versioned. But `runtime_version` is currently attached to stage-plan reconstruction, not to a future workflow-to-graph lowering pipeline.

**Why it matters:**  
Once `WorkflowIR -> Pulse graph` lowering becomes real, compatibility will depend on more than task type plus integer runtime version. A lowering fingerprint becomes the actual replay contract.

**Next step:**  
Promote `runtime_version` into a more explicit compatibility token before `#934` and `#925` move from IR display to executable lowering.

### [P1] The strongest missing abstraction is not graph algebra anymore; it is projection semantics
**Category:** Terminology Gap  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `sql/045_pulse_graph_rewrites.sql`, `sql/046_pulse_graph_state_rewrite_watermark.sql`, `src/Cortex/Pulse/Query.hs`, `src/Cortex/Pulse/Executor.hs`, issue `#876`  
**Cross-reference:** event-sourcing / projection literature

The shipped runtime has effectively adopted an event-sourced pattern:

- append-only rewrite lineage
- materialized graph state
- `applied_rewrite_id` as projection watermark
- replay to rebuild or repair the materialized view

The code already behaves this way, but the docs and backlog mostly still describe it as rewrite provenance and materialization.

**Why it matters:**  
Naming the pattern clarifies design choices: integrity checks become projection validation, admin reads become read models, and future rejected-rewrite history becomes part of the event stream rather than ad hoc metadata.

**Next step:**  
Write this up explicitly. It will sharpen `#875`, `#876`, and the admin-query surface.

### [P2] `Cortex.Workflow` exists in code, but only as descriptive IR and UI/report context, not as an executable semantic boundary
**Category:** Evidence Gap  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `src/Cortex/Workflow/IR.hs`, `src/Cortex/Workflow/Integration.hs`, `test/Cortex/Workflow/IRSpec.hs`, issue `#934`, issue `#925`  
**Cross-reference:** PR `#935`

`Cortex.Workflow` now has a small, sensible IR: sequence, parallel, conditional, signal, artifact, rewrite scope. But the integration function explicitly projects templates into a descriptive rather than executable skeleton and still carries `legacyStageGraph` metadata.

**Why it matters:**  
This is enough to stabilize vocabulary and UI contracts, but not enough to protect the runtime from future Portman semantics leaking downward.

**Next step:**  
Treat the current IR as phase 0 of `#934`, not closure. The critical next artifact is a lowering contract into Pulse, not more IR shape alone.

### [P2] The clean graph-runtime story is still weakened by a second durable execution model
**Category:** Design Tension  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `src/Portman/Task/ResponseEvalRun.hs`, `src/Cortex/Pulse/Executor.hs`, issue `#913`, `docs/Consumers/Portman/response-eval-run.md`  
**Cross-reference:** issue `#912`

The graph runtime is coherent. The codebase as a whole is not yet. `ResponseEvalRun` still uses checkpoint-envelope resume and dedicated checkpoint IO, while graph tasks use graph-state plus rewrite lineage. That preserves delivery momentum, but it means the repo still has two durable semantics.

**Why it matters:**  
This blocks the theoretical simplification the architecture is aiming for. It also makes future guarantees harder to state globally.

**Next step:**  
Keep `#913` high priority. Before hierarchical graphs or planner rewrites, unify the proving-ground task onto graph-state execution.

---

## Missed Abstractions

| Abstraction | Current state | Needed next |
| --- | --- | --- |
| Projection contract | append-only rewrites + watermark + reconstructed snapshot | explicit event-sourced/projection vocabulary and integrity rules |
| Compatibility token | `runtime_version` on graph-state reads/resume | lowering fingerprint for future `WorkflowIR` compilation |
| Workflow boundary | descriptive IR and UI payload | executable generic lowering into Pulse |
| Durable execution model | graph-native runtime plus checkpoint-based `ResponseEvalRun` | one durable semantics |

## Evidence Gaps

| Claim | Source | Current Evidence | Missing Evidence | Recommended Validation |
| --- | --- | --- | --- | --- |
| Reconstructed admin graph is always trustworthy | `#935/#936`, admin code | version-aware reconstruction and watermark filtering exist | independent integrity witness | add checksum/fingerprint and mismatch handling |
| Graph-state runtime converges under injected persist faults | issue `#912` | some safety behavior is specified | no fault-injection proof path | add write-failure injection tests |
| `Cortex.Workflow` can prevent Portman/Pulse semantic leakage | issue `#934`, current IR | vocabulary exists | no lowering semantics yet | write lowering ADR and first executable compiler seam |

## Design Tensions

- Reconstructive admin views are flexible and cheap to evolve, but they make trust depend on replaying current code.
- Rich rewrite provenance improves operator explanation, but without a compact integrity contract it risks becoming expensive history rather than reliable state.
- The team is correctly pushing generic semantics upward into `Cortex.Workflow`, but product pressure from Portman workflows will arrive before the lowering boundary is finished.

## Novel Ideas & Hypotheses

- **Speculative, Medium confidence:** model `graph_state` as a projection with a stored "projection signature" composed from runtime version, lowering version, and maybe normalized topology hash.  
  Validation path: prototype signature generation on write and verify on admin read/resume.
- **Speculative, Medium confidence:** hierarchical and planner rewrites should not be framed mainly as "more rewrite constructors". The better frame is controlled derivation spaces with explicit non-confluence policy.  
  Validation path: design note using DPO/concurrency vocabulary before `#878` and `#879`.

## Dead Ends / Rejected Directions

- Reviving `workflowStageGraph` as the executable workflow contract. Current code already treats it as legacy metadata, and the architecture docs explicitly reject using it as the durable execution surface.
- Treating richer admin graph reads as sufficient substitute for integrity guards. Better read models improve explanation; they do not by themselves prove consistency.

---

## Concrete Issue Plans

### Issue `#876` — rewrite provenance, graph diffs, and integrity guards

**Desired outcome**

Operators can inspect graph evolution without mentally replaying executor code, and the runtime can cheaply detect when durable lineage and materialized graph state diverge.

**Recommended scope split**

1. Projection integrity
   - add a persisted integrity witness on `pulse.graph_state`
   - bind it to `runtime_version`, `applied_rewrite_id`, and normalized graph-state/topology facts
   - define admin/runtime behavior on mismatch
2. Provenance explainability
   - keep `rewrite_delta`, `budget_before`, and `budget_after` as the operator baseline
   - add explicit rejected-rewrite history only when rejection events become durable
3. Causal queryability
   - define how to answer "why does node X exist?" without replaying arbitrary code paths

**Suggested acceptance additions**

- [ ] `graph_state` carries an integrity witness or equivalent projection signature
- [ ] resume path validates the witness when enough information exists
- [ ] admin surface exposes whether the current graph snapshot is verified or best-effort reconstructed
- [ ] mismatch behavior is explicit: fail, warn, or degrade with audit trail

**Suggested implementation order**

1. design note for witness format
2. schema extension
3. write-path population
4. admin/runtime validation
5. mismatch-focused tests

### Issue `#913` — migrate remaining legacy checkpoint artifacts

**Desired outcome**

Pulse has one durable execution model for generic tasks: graph state plus lineage, not graph state for some tasks and checkpoint envelopes for others.

**Recommended scope split**

1. `ResponseEvalRun` migration
   - define a `StagePlan` or graph-native equivalent
   - move durable cursor semantics into graph state
2. checkpoint demotion
   - keep per-stage checkpoint rows only if they remain useful as pure audit artifacts
   - otherwise delete the envelope path
3. cleanup
   - remove `readCheckpoint`
   - remove `taskEnvelopeVersionOrDefault` uses that exist only for checkpoint envelopes
   - simplify `StageEnv`

**Suggested acceptance additions**

- [ ] `ResponseEvalRun` resume no longer depends on `PulseQ.readCheckpoint`
- [ ] no production task type requires checkpoint-envelope compatibility for forward progress
- [ ] per-stage checkpoint persistence is either pure audit or removed
- [ ] docs describe one durable execution model in Pulse

**Suggested implementation order**

1. minimal graph-native `ResponseEvalRun` driver
2. parity tests against current behavior
3. remove resume dependency on checkpoints
4. remove or demote envelope helpers

### Issue `#934` — `Cortex.Workflow` lowering boundary

**Desired outcome**

`Cortex.Workflow` becomes the semantic middle layer between Portman workflow compilers and Pulse graph execution, with an explicit lowering contract and compatibility story.

**Recommended scope split**

1. IR law
   - define minimal semantics of sequence, parallel, conditional, signal, artifact, rewrite boundary
2. lowering contract
   - specify how IR lowers to Pulse graph or stage-plan form
   - specify which metadata is semantic vs decorative
3. compatibility
   - define lowering version or fingerprint
   - tie it to resume/admin reconstruction contracts
4. first executable consumer
   - route one real workflow through the boundary

**Suggested acceptance additions**

- [ ] lowering from `WorkflowIR` to executable Pulse graph is documented
- [ ] the lowering contract has a compatibility token stronger than bare task type
- [ ] one real Portman workflow compiles through this seam
- [ ] `workflowStageGraph` remains non-authoritative

**Suggested implementation order**

1. ADR for lowering semantics
2. executable prototype for one narrow workflow
3. compatibility token wiring
4. admin/runtime explanation hooks for lowered nodes

---

## Recommended Actions

### Act Now

- Reframe `#876` explicitly as provenance plus integrity, not just richer history.
- Keep `#913` ahead of hierarchical and planner rewrite work.
- Update foundation notes to reflect that `AdminGraphSnapshot` is already shipped on current `main`.

### Design Next

- Turn `#934` into a lowering-boundary issue, not an IR-shape issue.
- Introduce a stronger compatibility token than bare `runtime_version`.

### Write Up

- Document the runtime pattern explicitly as append-only lineage plus materialized projection.
- Add a short note on how projection validation differs from admin explanation.

### Parked

- `#878` hierarchical subgraphs until integrity and single-model durability are cleaner.
- `#879` planner-over-graph until rejection policy, provenance, and compatibility law are more explicit.

---

## Sources

### Implementation and repo context

- `src/Cortex/Pulse/Executor.hs`
- `src/Cortex/Pulse/Query.hs`
- `src/Portman/Server/Admin/API.hs`
- `src/Portman/Server/Admin/Handler.hs`
- `src/Cortex/Workflow/IR.hs`
- `src/Cortex/Workflow/Integration.hs`
- `src/Portman/Task/ResponseEvalRun.hs`
- `docs/Roadmap/Epics/graph-execution-engine-v2.md`
- `docs/Architecture/06-pulse-runtime.md`

### External prior art

- Temporal replay and determinism material
- Restate durable execution documentation
- CQRS / event-sourcing guidance
- algebraic graphs paper/repository
- graph transformation / DPO literature

