---
title: Cortex Foundation Refactor
description: Active refactor plan for establishing long-term Cortex module boundaries before extracting Cortex into its own repository
---

# Cortex Foundation Refactor

Issue: `#944`

## Goal

Prepare Cortex to become its own repository by tightening module boundaries, shrinking oversized modules, and making the runtime contracts explicit.

This is not a single rename pass. The work should preserve behavior while moving the codebase toward a shape where:

- `Cortex` exposes generic workflow and runtime building blocks.
- `Portman` compiles product behavior into Cortex contracts instead of leaking domain semantics downward.
- `Platform.DurableTask` remains a generic scheduling and persistence substrate rather than becoming a second workflow layer.

## Boundary Rules

### `Cortex.Graph`

Owns generic algebraic graph primitives and analysis only:

- algebraic graph DSL
- lowered relation representation
- graph traversal and validation algorithms

`Cortex.Graph` must not depend on:

- `Platform.DurableTask.*`
- Pulse executor persistence concerns
- Portman task semantics
- Pulse node identity or rewrite lineage semantics

Runtime state transitions, durable execution classification, node identity, and rewrite lifecycle policy should move out of the root graph module into narrower Cortex runtime modules.

### `Cortex.Wire` / `Cortex.Circuit`

Owns source and executable-topology semantics above raw graph structure:

- Wire source parsing and endpoint validation
- circuit IR
- lowering boundaries
- future compilation from circuit semantics into Pulse-executable plans

This is the correct home for concepts that are more structured than generic graph algebra but not yet runtime execution concerns.

### `Cortex.Pulse`

Owns durable runtime execution:

- claiming and resuming work
- graph-state persistence
- durable node identity
- rewrite lineage hydration and application
- signal suspension and resume
- executor scheduling and frontier coordination

Pulse is the runtime context for executing Cortex plans durably. It should consume circuit/graph contracts, not define product semantics.

### `Platform.DurableTask`

Owns generic task substrate only:

- shared run/status/scheduling types
- generic checkpoint envelope support
- polling/pool/schedule helpers

It should not accumulate Cortex-specific execution semantics. If a concept requires graph topology, circuit lowering, or Pulse rewrite semantics, it belongs under `Cortex.*`.

## Target Module Shape

### Near-term

- `Cortex.Graph`
  - keep only generic graph primitives and algorithms
- `Cortex.Wire/`
  - source syntax, parser, endpoint contracts, compiler
- `Cortex.Circuit/`
  - circuit IR, compiled topology, lowering contracts
- `Cortex.Pulse/`
  - node identity and rewrite semantics
  - runtime plan types
  - rewrite hydration/serialization
  - executor orchestration
  - query/scheduler/signal support

### Executor split

`Cortex.Pulse.Executor` is currently too large and should become a façade over narrower runtime modules. The first extraction pass is:

- `Cortex.Pulse.Plan`
- `Cortex.Pulse.PlanHydration`
- `Cortex.Pulse.Materialization`

Follow-up extractions should target:

- frontier worker orchestration
- replay-policy enforcement
- terminal outcome handling
- application-owned task and diagnostic-plan registry wiring

## Current Refactor Status

Completed in this pass:

- made `Cortex.Graph` a stable façade and moved the generic implementation under `Cortex.Graph.Core`
- split generic source/topology into `Cortex.Wire` and `Cortex.Circuit`; product Templates/rendering live under `Portman.Workflow`
- extracted Pulse plan semantics from `Cortex.Pulse.Executor` into `Cortex.Pulse.Plan`
- extracted rewrite serialization and hydration into `Cortex.Pulse.PlanHydration`
- extracted rewrite replay/materialization helpers into `Cortex.Pulse.Materialization`
- moved `NodeId` into `Cortex.Pulse.Node`
- moved rewrite planning and budgeting into `Cortex.Pulse.Rewrite`
- moved task-type and diagnostic-plan lookup out of Cortex into application wiring
- extracted replay-policy enforcement out of `Cortex.Pulse.Executor`
- extracted frontier execution and signal-resolution flow into `Cortex.Pulse.Executor.Frontier`
- extracted resume hydration and admin topology reconstruction into `Cortex.Pulse.Executor.Resume`
- extracted settled/suspended/stuck outcome handling into `Cortex.Pulse.Executor.Outcome`
- extracted the core graph run loop into `Cortex.Pulse.Executor.Loop`
- reduced `Cortex.Graph` to pure graph primitives and analysis

Still pending:

- decide whether `Cortex.Pulse.Executor` should remain a façade module or collapse further into pure re-exports and entrypoints
- audit all Cortex imports for `Platform.DurableTask` boundary violations
- decide whether `Cortex.Pulse.Query` should remain one persistence surface or split admin/read models from runtime writes

## Acceptance Criteria

- Cortex runtime code can be read by layer without jumping between product-specific modules.
- `Cortex.Graph` contains no Pulse node identity, rewrite lineage, task scheduler, or run-outcome coupling.
- `Platform.DurableTask` contains no Cortex-specific graph/workflow runtime logic.
- Portman task modules depend on Cortex contracts, but Cortex does not depend on Portman concepts.
- `Cortex.Pulse.Executor` is decomposed into smaller modules with clear ownership.
