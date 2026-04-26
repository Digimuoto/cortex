---
title: "Research Memo: PR #918 — Rewrite Runtime, Hydration, and Materialization Follow-ups"
description: Cross-reference synthesis of DIG-417, PR #918, the v2 Architecture/papers, and follow-up tracker routing
---

# Research Memo: PR #918 — Rewrite Runtime, Hydration, and Materialization Follow-ups

**Date:** 2026-04-08  
**Scope:** DIG-417, PR #918, branch `pulse-graph-v2-structured-rewrite-algebra-and-valid` against `origin/main`  
**Layers examined:** Code | Papers (1, 3, IDEAS) | Architecture (v2 spec, Cortex Pulse) | Issues | Literature (algebraic graphs, event sourcing, dynamic process migration)

---

## Key Findings

### [P1] `StageTemplateId` is now the durable executable identity, but uniqueness is not enforced

**Category:** Correctness Gap  
**Files:** `src/Cortex/Pulse/Executor.hs:483-490`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:381-396`, `test/Cortex/Pulse/ExecutorSpec.hs:2208-2299`  
**Cross-reference:** DIG-417, DIG-448

`hydrateRewrite` resolves a persisted rewritten stage by scanning all registry
definitions and taking the first matching `sdTemplateId`. That makes resumed
semantics order-dependent if two definitions share a template id but differ in
action or retry policy.

This is now a real contract problem because the docs define `StageTemplateId`
as the durable executable identity used for resume-time rehydration. Duplicate
template ids must therefore either be proven semantically identical or rejected.

**Captured follow-up:** `DIG-448` — template registry invariants for rewrite hydration.

### [P1] Rewrite validation still does not prove that the target anchor node exists

**Category:** Correctness Gap  
**Files:** `src/Cortex/Pulse/Executor.hs:510-549`, `src/Cortex/Pulse/Executor.hs:739-782`, `src-platform/Platform/DurableTask/Graph.hs:349-357`, `test/Cortex/Pulse/GraphRewriteSpec.hs:75-151`  
**Cross-reference:** DIG-417, DIG-447

`validateSubgraphSpec` validates only the inserted subgraph shape. It does not
check that the rewritten anchor node is present in the current topology and
definition map. That matters because `addEdge` inserts absent vertices, so a
malformed `AppendAfter` or retained-envelope rewrite can synthesize a topology
vertex with no stage definition.

Today that hole is mostly masked because stage-produced rewrites originate from
real executing nodes. It becomes concrete for malformed persisted rewrites,
future planner/operator rewrite surfaces, and the exported pure `applyRewrite`
API.

**Captured follow-up:** `DIG-447` — anchor-node existence validation.

### [P2] The v2 doc still overstates budgeted admission and rejection fallback as if they are part of the shipped surface

**Category:** Design Tension  
**Files:** `docs/Roadmap/Epics/graph-execution-engine-v2.md:29-34`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:61-99`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:372-377`, `src/Cortex/Pulse/Executor.hs:859-863`  
**Cross-reference:** DIG-418

The updated docs correctly describe template hydration and watermark
materialization, but the front half of the v2 architecture spec still presents
rewrite budgets and configurable rejection fallback as defining runtime law.
PR #918 does not implement `RewriteBudget`, `RewriteCost`, durable budget state,
or task-type rejection fallback. Invalid rewrites still fail the run directly.

This is not a narrow code bug in the DIG-417 slice, but it is a live
contract/roadmap mismatch that should stay explicitly routed to `DIG-418`.

### [P2] Rewrite provenance is now recovery-complete enough to resume, but still not operator-complete

**Category:** Design Tension  
**Files:** `sql/045_pulse_graph_rewrites.sql:1-12`, `sql/046_pulse_graph_state_rewrite_watermark.sql:1-7`, `src/Cortex/Pulse/Query.hs:1217-1241`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:131-142`  
**Cross-reference:** DIG-419, DIG-420

The durable rewrite surface now supports recovery:

- append-only accepted `rewrite_spec`
- durable `rewrite_id`
- `applied_rewrite_id` watermark on `pulse.graph_state`

That is enough to reconstruct materialized graph state safely across resume.
It is not yet the richer operator/provenance surface described in the issue and
architecture intro. There is still no persisted graph diff, no admit/reject
decision record, no budget snapshot, and no operator override trail.

This should remain explicitly owned by `DIG-419` and surfaced as an operator
dependency for `DIG-420`.

### [P2] The new retry-semantics contract still lacks direct rewrite-resume evidence

**Category:** Evidence Gap  
**Files:** `src/Cortex/Pulse/Executor.hs:215-221`, `src/Cortex/Pulse/Executor.hs:456-490`, `test/Cortex/Pulse/ExecutorSpec.hs:1973-2299`  
**Cross-reference:** DIG-417, DIG-449

`StageRetryPolicy` still decodes from persisted JSON with
`srpRetryable = const True`. The branch now relies on
template-registry hydration to restore the real retry semantics on resume.
That is a defensible design, but there is no rewrite-focused regression test
that proves a nontrivial `srpRetryable` predicate survives crash/resume
unchanged.

**Captured follow-up:** `DIG-449` — direct retry-predicate parity test.

---

## What PR #918 Actually Shipped

Against `origin/main`, the PR delta is focused on the rewrite/runtime/doc/test
surface:

- `StageRewrite output rewrite` semantics in the executor
- `StageTemplateId`-based hydration for rewritten stages on resume
- `applied_rewrite_id` watermark persistence on `pulse.graph_state`
- deterministic resume/materialization of admitted-but-unapplied rewrites
- sink-node rewrite admission before old-topology completion
- stronger rewrite validation for malformed inserted subgraphs
- doc and paper alignment with the runtime model now being implemented

Recent branch commits:

```text
82c21fc fix(pulse): implement rewrite watermark and template hydration
0ff2660 fix(pulse-graph): review fixes for node cleanup, hydration, and dataflow (DIG-417)
68ad97a fix(review): normalize adjacency maps on deletion; propagate Stuck persist failure
3d2f347 fix(pulse): harden rewrite resume recovery
b922cf4 feat(pulse-graph): harden rewrite implementation with validation and namespacing (DIG-417)
212f318 fix(pulse-graph): fix rewrite topology bugs and update StageId constraints (DIG-417)
ea71466 fix(pulse-graph): resolve non-exhaustive pattern match on NodeOutcome (DIG-417)
53c87b8 feat(pulse-graph): implement structured rewrite algebra and log-based replay (DIG-417)
```

---

## Tracker Routing

### New follow-up issues created from this memo

- `DIG-447` — Pulse rewrite validator: enforce anchor-node existence for `ExpandNode` and `AppendAfter`
- `DIG-448` — Template registry invariants for rewrite hydration (`StageTemplateId` uniqueness and consistency)
- `DIG-449` — Rewrite resume hardening: prove custom `srpRetryable` predicate parity through template hydration

### Existing backlog items that already own remaining scope

- `DIG-418` — rewrite budgets and rejection/admission policy
- `DIG-419` — richer rewrite provenance and durable evolution model
- `DIG-420` — operator graph inspection and runtime introspection
- `DIG-433` — paper/research follow-up on recovery semantics and materialization boundaries
- `DIG-432` — algebraic extension boundary and formal treatment of rewrite-capable execution

---

## Novel Ideas / Paper Directions

### 1. Rewrite watermark as a projection checkpoint over append-only lineage

The most useful framing for the new durability model is:

- `graph_rewrites` is append-only lineage
- `applied_rewrite_id` is a materialized projection checkpoint

That is stronger than “just replay the log” and more precise than “snapshot the
whole graph every time”. It matches the event-sourcing literature on
rebuildable projections and their evolution burden.

**Good home:** `DIG-433` (recovery semantics paper), with a shorter note in
Paper 1 if needed.

### 2. Local rewrite replay and non-local process migration are different problems

PR #918 still lives in the local substitution model: rewrite a node boundary,
then materialize and resume deterministically. Future planner/operator rewrites
that change broader graph regions may need explicit state-mapping or
history-equivalence machinery rather than “just more rewrite constructors”.

That boundary is worth capturing now so future work does not overclaim what the
current rewrite algebra guarantees.

**Good homes:** `DIG-433`, `DIG-432`, and `docs/Publications/Notes/frontier-ideas.md`.

**Literature touchpoints**

- Andrey Mokhov, *Algebraic Graphs with Class*, Haskell 2017  
  https://doi.org/10.1145/3122955.3122956
- Michiel Overeem et al., *An empirical characterization of event sourced systems and their schema evolution*, JSS 2021  
  https://doi.org/10.1016/j.jss.2021.110970
- Gargi Bakshi and Rushikesh K. Joshi, *A History Equivalence Algorithm for Dynamic Process Migration*, arXiv 2024  
  https://doi.org/10.48550/arXiv.2412.08314

---

## Evidence Gaps

| Claim | Source | Current Evidence | Needed |
|-------|--------|------------------|--------|
| `StageTemplateId` is the durable executable identity | v2 architecture §6 | Positive test for reused `stageId`; no negative uniqueness check | Validation + test for conflicting duplicate template ids |
| Retry semantics are recovered from template registry on resume | v2 architecture §10 | Implementation does this; no direct rewrite-resume proof | Rewrite-resume integration test with nontrivial `srpRetryable` |
| Rewrite admission includes valid anchor context | v2 architecture §5 | Inserted-subgraph checks exist; anchor existence is unchecked | Pure rejection tests for missing-anchor rewrites |

---

## Design Tensions

| Tension | Resolution Path |
|---------|-----------------|
| Normative v2 budgets vs shipped DIG-417 runtime | Keep the docs explicit that `DIG-418` remains outstanding |
| Recovery-complete rewrite lineage vs operator-complete provenance | Land `DIG-419`/`DIG-420` as separate visibility surfaces |
| Local rewrite substitution vs future non-local graph migration | Treat future broad planner/operator rewrites as migration/state-mapping work, not just “bigger rewrites” |

---

## Recommended Actions

### Act Now

- Route the two remaining correctness gaps to `DIG-447` and `DIG-448`
- Route the retry evidence gap to `DIG-449`
- Comment on `DIG-417`, `DIG-418`, `DIG-419`, `DIG-420`, and `DIG-433` so closure is auditable

### Design Next

- Decide whether duplicate `StageTemplateId` is forbidden or allowed only under semantic equivalence
- Tighten rewrite admission so missing anchors fail before topology mutation
- Decide how much richer rewrite provenance belongs in `DIG-419` before operator APIs arrive

### Write Up

- Capture the projection-checkpoint framing in `DIG-433`
- Capture the local-rewrite vs process-migration boundary in `DIG-432` / `DIG-433`
- Keep `docs/Publications/Notes/frontier-ideas.md` updated with the two new directions
