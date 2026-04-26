---
title: "Handoff: DIG-417 / PR #918 — Rewrite Runtime Follow-ups"
description: Continuation handoff for the Pulse rewrite-runtime branch after watermark/template hydration work
---

# Handoff: DIG-417 / PR #918 — Rewrite Runtime Follow-ups

**Generated:** 2026-04-08  
**Branch:** `pulse-graph-v2-structured-rewrite-algebra-and-valid`  
**Issue:** `DIG-417` — Pulse graph v2: structured rewrite algebra and validation  
**PR:** #918 — `feat: Pulse graph v2: structured rewrite algebra and validation`

---

## Status Overview

| Aspect | Status |
|--------|--------|
| Issue | `DIG-417` — In Progress |
| PR | #918 — Open |
| CI | 9 checks complete/success-or-skipped, `Test (PostgreSQL + Cabal)` still in progress at capture time |
| Reviews | No open tracker discussion yet; review-derived follow-ups routed to `DIG-447`, `DIG-448`, `DIG-449` |

---

## Context

### Issue Description

Introduce a structured graph rewrite model that allows a stage to propose
changes to the execution graph at runtime. Rewrites are typed, inspectable, and
validated before application.

### Acceptance Criteria Snapshot

- [x] `GraphRewrite` type with initial structured constructors
- [x] Deterministic rewrite application and namespaced node identity
- [x] Invalid rewrites rejected with structured reasons for inserted-subgraph shape
- [x] Resume/materialization hardened with durable rewrite watermark
- [x] Rewritten-stage hydration moved to `StageTemplateId`
- [ ] Anchor-node validation for missing rewrite targets (`DIG-447`)
- [ ] `StageTemplateId` uniqueness/consistency invariant enforcement (`DIG-448`)
- [ ] Direct retry-predicate parity evidence across rewrite resume (`DIG-449`)
- [ ] Budget admission / rejection fallback (`DIG-418`)
- [ ] Rich rewrite provenance and operator read surfaces (`DIG-419`, `DIG-420`)

### Epic

`DIG-82` — Durable portfolio agent: strategy-driven autonomous paper portfolio cycle

---

## What’s Done

### 1. Rewrite-capable runtime semantics landed

- Files:
  - `src/Cortex/Pulse/Executor.hs`
  - `src-platform/Platform/DurableTask/Graph.hs`
  - `src/Cortex/Pulse/Query.hs`
  - `sql/045_pulse_graph_rewrites.sql`
  - `sql/046_pulse_graph_state_rewrite_watermark.sql`
- Highlights:
  - `StageRewrite output rewrite`
  - `NodeRewritten` / `OutcomeRewritten`
  - materialization watermark via `applied_rewrite_id`
  - sink rewrite admission before old-topology completion
  - pruning removed nodes for `ExpandReplaceNode`

### 2. Rewrite hydration moved from semantic `stageId` to executable `StageTemplateId`

- Files:
  - `src/Cortex/Pulse/Executor.hs`
  - `src/Portman/Task/PaperPortfolioCycle.hs`
- Highlights:
  - rewritten-stage rehydration now uses a runtime-local template registry
  - checkpoint/runtime version bumped to `3`

### 3. Rewrite docs and papers were aligned to the intended machine

- Files:
  - `docs/Roadmap/Epics/graph-execution-engine-v2.md`
  - `docs/Architecture/06-pulse-runtime.md`
  - `docs/Publications/Paper-1-staged-reduction/manuscript.md`
  - `docs/Publications/Paper-2-algebraic-foundations/manuscript.md`
- Highlights:
  - identity split: `NodeId` / `StageTemplateId` / `stageId`
  - lineage + watermark crash model
  - `StageRewrite` as output plus structural proposal

### 4. Rewrite-focused tests were added

- Files:
  - `test/Cortex/Pulse/ExecutorSpec.hs`
  - `test/Cortex/Pulse/GraphRewriteSpec.hs`
- Coverage added for:
  - sink-node rewrite admission
  - watermark-gap materialization on resume
  - repaired graph-state resume
  - missing-template hydration failure
  - reused semantic `stageId` with distinct template ids

---

## What’s Left

### 1. Enforce rewrite-anchor existence before topology mutation

- Tracker: `DIG-447`
- Why:
  - current validation proves inserted-subgraph shape, not anchor existence
  - `addEdge` inserts missing vertices, so malformed rewrites can synthesize
    topology without a corresponding definition
- Suggested approach:
  - extend rewrite admission to reject absent anchors in both topology and definitions
  - add pure tests for missing-anchor `ExpandNode` / `AppendAfter`

### 2. Enforce `StageTemplateId` registry invariants

- Tracker: `DIG-448`
- Why:
  - first-match hydration is order-dependent if duplicate template ids diverge
- Suggested approach:
  - precompute template registry by `StageTemplateId`
  - reject conflicting duplicates up front
  - decide whether semantically identical duplicates are allowed

### 3. Add direct retry-predicate resume evidence

- Tracker: `DIG-449`
- Why:
  - current design is plausible, but there is no regression test proving
    nontrivial `srpRetryable` parity across rewrite resume
- Suggested approach:
  - add a rewrite-resume integration test where the custom predicate forbids
    retry for a specific failure mode

### 4. Finish the already-tracked backlog beyond DIG-417

- `DIG-418` — budget admission and rejection fallback remain unimplemented
- `DIG-419` — rewrite provenance is still recovery-oriented, not operator-complete
- `DIG-420` — operator-facing graph/rewrite introspection still depends on richer persistence

---

## Open Review / Research Routing

This branch already absorbed several earlier review fixes. Remaining
research-derived gaps have been routed explicitly:

- `DIG-447` — missing anchor-node validation
- `DIG-448` — `StageTemplateId` uniqueness / consistency
- `DIG-449` — retry-predicate parity evidence

The broader runtime/docs mismatch around budgets stays on `DIG-418`. Richer
provenance and operator visibility stay on `DIG-419` / `DIG-420`.

---

## Key Files

| File | Purpose | Status |
|------|---------|--------|
| `src/Cortex/Pulse/Executor.hs` | Rewrite execution, hydration, resume, validation | Core implementation landed; follow-up gaps remain |
| `src-platform/Platform/DurableTask/Graph.hs` | Pure graph algebra and rewritten-node semantics | Updated and in use |
| `src/Cortex/Pulse/Query.hs` | Durable graph-state + rewrite persistence | Updated for watermark |
| `sql/045_pulse_graph_rewrites.sql` | Rewrite event table | Added |
| `sql/046_pulse_graph_state_rewrite_watermark.sql` | Graph-state watermark column | Added |
| `test/Cortex/Pulse/ExecutorSpec.hs` | Rewrite integration coverage | Expanded |
| `test/Cortex/Pulse/GraphRewriteSpec.hs` | Pure rewrite validation coverage | Added |
| `docs/Research-notes/Runtime/2026-04-08-pr918-rewrite-runtime-hydration-materialization-followups.md` | Cross-reference research memo | Added in this pass |

---

## Technical Notes

- Current PR diff should be judged against `origin/main`, not local `main`. In
  this workspace, local `main` is stale.
- CI snapshot at capture time:
  - success/skipped: Detect Changes, Clerk Eval Suite, CodeQL Analyze,
    Format Check, Build Supported Outputs, Lint (UI) skipped, UI Unit Tests
    skipped, HLint, Flake Check
  - still running: `Test (PostgreSQL + Cabal)`
- The current runtime is recovery-complete enough for rewrite resume, but not
  yet operator-complete from a provenance/inspection standpoint.

---

## Recent Activity

### Commits (origin/main..HEAD)

```text
82c21fc fix(pulse): implement rewrite watermark and template hydration
0ff2660 fix(pulse-graph): review fixes for node cleanup, hydration, and dataflow (DIG-417)
68ad97a fix(review): normalize adjacency maps on deletion; propagate Stuck persist failure
3d2f347 fix(pulse): harden rewrite resume recovery
b922cf4 feat(pulse-graph): harden rewrite implementation with validation and namespacing (DIG-417)
212f318 fix(pulse-graph): fix rewrite topology bugs and update StageId constraints (DIG-417)
ea71466 fix(pulse-graph): resolve non-exhaustive pattern match on NodeOutcome (DIG-417)
53c87b8 feat(pulse-graph): implement structured rewrite algebra and log-based replay (DIG-417)
b98a02e chore(pulse-graph): start implementation
```

---

## Quick Start

To continue this work:

```bash
git fetch origin
git checkout pulse-graph-v2-structured-rewrite-algebra-and-valid
git pull origin pulse-graph-v2-structured-rewrite-algebra-and-valid

issue scope
issue show DIG-417 --relations
issue show DIG-447 --relations
issue show DIG-448 --relations
issue show DIG-449 --relations

gh pr view 918
```

Then choose one of:

- fix remaining correctness gaps on this branch (`DIG-447`, `DIG-448`)
- add rewrite-resume evidence coverage (`DIG-449`)
- keep the branch narrow and merge, then pick follow-ups separately

---

## Related Links

- Issue: https://linear.app/digimuoto/issue/DIG-417/pulse-graph-v2-structured-rewrite-algebra-and-validation
- PR: https://github.com/Digimuoto/cortex/pull/918
- Follow-ups:
  - https://linear.app/digimuoto/issue/DIG-447/pulse-rewrite-validator-enforce-anchor-node-existence-for-expandnode
  - https://linear.app/digimuoto/issue/DIG-448/template-registry-invariants-for-rewrite-hydration-stagetemplateid
  - https://linear.app/digimuoto/issue/DIG-449/rewrite-resume-hardening-prove-custom-srpretryable-predicate-parity
