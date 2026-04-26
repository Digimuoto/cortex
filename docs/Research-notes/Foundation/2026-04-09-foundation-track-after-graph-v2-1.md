---
title: "Research Memo: Foundation Track After Graph v2.1"
description: Cross-reference synthesis of the current Cortex and Platform foundation track after graph v2.1, with focus on operator introspection and the missing workflow middle layer
---

# Research Memo: Foundation Track After Graph v2.1

**Date:** 2026-04-09
**Scope:** current foundation-layer state after graph v2.1 shipped, with focus on `Cortex`, `Platform`, research backlog shaping, and the new operator/runtime introspection work on PR #935
**Artifacts examined:** current branch history, PR #935, `DIG-418`, `DIG-419`, `DIG-420`, `DIG-450`, `DIG-457`, `Cortex.Pulse` query/executor/admin code, and architecture docs
**Method:** implementation-first cross-reference synthesis
**Confidence profile:** high on code and backlog findings; medium on DB-backed admin behavior because PostgreSQL-backed specs were not runnable locally in this shell

---

## Executive Summary

The foundation track is in a better place than the backlog names still suggest. The core rewrite-capable runtime problems are no longer the priority: bounded rewrite admission, watermark-based materialization, anchor replay, and the `Cortex.Graph` split are already shipped. The center of gravity has moved to operator-facing graph introspection, richer provenance, and the missing generic workflow layer above `Cortex.Graph` and below Portman product semantics.

The current PR #935 is the right next move. It turns rewrite lineage and graph-state persistence into a real operator surface: watermark, rewrite history, blocked nodes, waiting signals, rewrite deltas, and budget snapshots. The highest-impact next phase after that is not more Portman workflow logic. It is to finish the generic Cortex foundation: clearer persisted provenance contracts, integrity guards, and `Cortex.Workflow` as the semantic middle layer.

---

## Key Findings

### [P1] The main foundation gap has shifted from crash safety to explanation and integrity
**Category:** Missed Abstraction
**Status:** Observed
**Confidence:** High
**Primary evidence:** `DIG-418`, `DIG-419`, `DIG-420`, [graph-execution-engine.md](../Architecture/graph-execution-engine.md), [pulse.md](../Architecture/pulse.md)
**Cross-reference:** `DIG-417` shipped scope, narrowed `DIG-419`

The old high-risk runtime gaps are mostly closed. The remaining foundation work is now about understanding and trusting graph evolution after it happens:

- what the current materialized graph is
- why nodes are blocked or waiting
- what each rewrite changed
- what budget was consumed
- whether persisted lineage and materialized state still agree

**Why it matters:**  
The system now has recovery-grade persistence. The next differentiator is operator-grade explanation and integrity, not another round of basic replay hardening.

**Next step:**  
Treat `DIG-419` as provenance plus integrity only, and treat `DIG-420` as the query/surface layer over that durable substrate.

### [P1] PR #935 is establishing the right operator baseline, but the current graph itself is still not a first-class admin payload
**Category:** Evidence Gap
**Status:** Observed
**Confidence:** High
**Primary evidence:** [Query.hs](../../src/Cortex/Pulse/Query.hs), [API.hs](../../src/Portman/Server/Admin/API.hs), [Handler.hs](../../src/Portman/Server/Admin/Handler.hs)
**Cross-reference:** `DIG-420`, PR #935

The admin surface now exposes meaningful graph-native diagnostics:

- applied rewrite watermark
- rewrite history
- blocked nodes and reasons
- waiting nodes and signals
- structural rewrite deltas
- budget-before and budget-after snapshots

That is a strong baseline. But the current materialized graph is still reconstructed as an internal helper rather than surfaced as a durable, frontend-friendly payload with adjacency and node metadata.

**Why it matters:**  
Without a stable current-graph payload, graph inspection remains partially interpretive. Operators can see events and statuses, but not yet a canonical materialized graph view.

**Next step:**  
Add a generic graph snapshot contract for admin use:

- current nodes
- current edges / adjacency
- node status / outputs-present flags
- blocked / waiting annotations
- watermark / budget summary

### [P1] The semantic middle layer is now the most important missing abstraction
**Category:** Missed Abstraction
**Status:** Observed
**Confidence:** High
**Primary evidence:** `DIG-450`, `DIG-457`, [pulse.md](../Architecture/pulse.md), [2026-04-08-portman-workflow-killer-app-synthesis.md](2026-04-08-portman-workflow-killer-app-synthesis.md)
**Cross-reference:** narrowed `DIG-450`, new `DIG-457`

The backlog cleanup made the architecture clearer:

- `Platform` should remain machinery only
- `Cortex.Graph` and `Cortex.Pulse` now own generic graph/runtime semantics
- Portman product workflows should not be lowered directly into Pulse internals

That makes `Cortex.Workflow` the next necessary layer. Without it, both operator inspection and future Portman workflow compilation will keep depending on task-type-specific lowering and fallback stage-plan conventions.

**Why it matters:**  
This is now the main abstraction debt in the foundation track. If skipped, product workflows and runtime mechanics will start to tangle again.

**Next step:**  
Start `DIG-457` after the current `DIG-420` introspection slice is stable. Define a generic workflow IR above `Cortex.Graph` and below Portman semantics.

### [P2] `DIG-419` and `DIG-420` are overlapping productively, but they need a stable contract boundary
**Category:** Design Tension
**Status:** Inferred
**Confidence:** High
**Primary evidence:** narrowed `DIG-419`, in-progress `DIG-420`, PR #935 schema and admin changes
**Cross-reference:** current rewrite provenance work in PR #935

The branch is using the overlap well:

- provenance is becoming richer in storage
- operator diagnostics are surfacing that provenance

But the issue boundary is still a little blurry.

**Why it matters:**  
If storage shape and admin query shape evolve together without a written boundary, later UI and integrity work will inherit an unstable contract.

**Next step:**  
Lock the split as:

- `DIG-419`: what rewrite and graph-evolution facts are durably persisted
- `DIG-420`: how those facts are reconstructed, queried, and exposed to operators

### [P2] The biggest extension risk is hierarchical workflows before `Cortex.Workflow`
**Category:** Extension Risk
**Status:** Inferred
**Confidence:** Medium-High
**Primary evidence:** `DIG-450`, `DIG-457`, [2026-04-08-portman-workflow-killer-app-synthesis.md](2026-04-08-portman-workflow-killer-app-synthesis.md)
**Cross-reference:** future child-workflow work, Portman production workflow track

Another track is rightly moving toward using graph rewriting in real Portman workflows. The risk is sequence. If child workflows, subgraphs, or product compilers land before a generic Cortex workflow IR exists, either:

- Portman semantics leak downward into Cortex, or
- Pulse runtime mechanics leak upward into Portman workflow code

**Why it matters:**  
This would recreate the exact layering problem the graph split just fixed.

**Next step:**  
Keep the sequence strict:

1. finish `DIG-420`
2. define `Cortex.Workflow` in `DIG-457`
3. only then expand Portman-side workflow compilation and child-workflow semantics

---

## Missed Abstractions

| Abstraction | Current state | Needed next |
|---|---|---|
| Operator graph view | rewrite history + statuses + blocked/waiting diagnostics | canonical current-graph payload |
| Rewrite provenance | durable events now include structural deltas and budget snapshots | integrity witness and richer causal explanation |
| Semantic workflow layer | task-type-specific lowering and fallback plan reconstruction | generic `Cortex.Workflow` IR |

## Evidence Gaps

| Claim | Source | Current Evidence | Missing Evidence | Recommended Validation |
|---|---|---|---|---|
| Admin graph diagnostics are operationally correct end-to-end | PR #935 code and tests | handler/query code exists; specs updated | DB-backed execution of new admin specs | run PG-backed CI or focused local PG suite |
| Rewrite provenance is now sufficient for operator-grade replay explanation | `DIG-419`, PR #935 | deltas and budget snapshots are persisted | integrity checks and canonical current-graph surface | add checksum/witness design and graph snapshot endpoint |
| `Cortex.Workflow` is the right next foundation layer | issue split + architecture docs | strong architectural evidence | concrete IR draft and compiler seam | write design note and minimal type proposal under `DIG-457` |

## Design Tensions

- The current branch is correctly building operator introspection on top of task-type-aware reconstruction helpers. That is a good bridge, but it should not become the permanent abstraction.
- Rich provenance is useful only if it remains queryable and compact. A flood of raw rewrite blobs without stable summaries will not improve inspection.
- The production-workflow track will pull toward product semantics quickly. The foundation track should resist that and keep Cortex generic one layer short of finance meaning.

## Recommended Actions

### Act Now
- Finish `DIG-420` by adding a canonical current materialized graph payload to the admin surface.
- Write the `DIG-419` / `DIG-420` contract boundary explicitly in docs or issue text.

### Design Next
- Start `DIG-457` as the next foundation abstraction after PR #935 stabilizes.
- Define the minimum generic `Cortex.Workflow` surface:
  - sequence
  - parallel
  - conditional
  - suspend/signal
  - boundary/artifact nodes
  - rewrite intent boundary

### Write Up
- Frame the foundation track as moving from recovery-grade runtime semantics to operator-grade graph explanation and generic workflow semantics.

### Parked
- Child workflows and Portman-side workflow compilation until `Cortex.Workflow` exists as a stable middle layer.

## Known Unknowns

- The new DB-backed admin integration cases could not be executed locally because PostgreSQL test env wiring was not available in this shell.
- This memo did not do a fresh external literature pass; the highest-value synthesis here was between code, docs, PR scope, and the narrowed issue backlog.
