---
title: "ADR 0005 — Budgeted Rewrite Admission and Materialization"
description: "Runtime graph evolution happens only through admitted rewrite deltas that fit a durable rewrite budget and materialize into graph state."
sidebar:
  label: "0005. Rewrite admission"
  order: 5
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Roadmap/Plans/rewrite-materialization-and-recovery.md
  - docs/Reference/rewrites.md
  - DIG-417
  - DIG-418
  - DIG-419
---

# ADR 0005 — Budgeted Rewrite Admission and Materialization

## Status

Accepted — structured rewrite admission, rewrite budgets, and durable materialization are implemented and now anchor the graph-execution architecture.

## Context

Static DAG execution is not enough for Cortex's target workflows. A running node may discover missing evidence, need to elaborate follow-up work, or need to prune and repair future topology. Allowing that kind of evolution without a law would turn the runtime into arbitrary mutable control flow.

The runtime therefore needed a way to support dynamic topology while preserving:

- replay and recovery
- operator inspection
- structural validation
- bounded authority over graph growth

## Decision

Graph evolution during execution is allowed only through runtime-admitted rewrite deltas.

- stages and planners may propose rewrites
- only the runtime may admit them
- admission requires validation against rewrite safety rules and a finite per-run rewrite budget
- admitted rewrites materialize durably into the graph state and become part of the run's execution history

Budget is a runtime law, not a prompt convention. Structural change consumes explicit authority measured in bounded dimensions such as added nodes, edges, depth, frontier breadth, and rewrite operations.

## Alternatives considered

- **Let planner prompts impose the growth limit informally** — rejected because prompt discipline is not a correctness boundary and cannot support replay or auditability.
- **Allow arbitrary mutation of the materialized graph** — rejected because it destroys analyzability and makes runtime trust too expensive.
- **Ban execution-time graph evolution entirely** — rejected because real repair, adaptation, and conditional elaboration would collapse back into ad hoc imperative stage logic.

## Consequences

### Positive

- Dynamic workflows stay constrained enough to validate and inspect.
- Rewrite authority is explicit and auditable.
- Materialized graph state remains the canonical runtime reality after adaptation.

### Negative

- Rewrite-capable tasks must encode their changes through the runtime algebra rather than directly mutating future work.
- Budget design becomes part of runtime correctness, not just tuning.

### Obligations

- Keep rewrite admission centralized in runtime code, not in product binders or planner prompts.
- Persist enough rewrite facts to reconstruct how the current graph was reached.
- Keep the rewrite algebra small and closed unless a new operation is justified as a runtime law.

## Related

- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Roadmap/Plans/rewrite-materialization-and-recovery.md](../Roadmap/Plans/rewrite-materialization-and-recovery.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
