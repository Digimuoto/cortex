---
title: "ADR 0007 — Latent-Branch Conditional Lowering"
description:
  "Conditionals compile to condition anchors with latent branch fragments; Pulse materializes only
  the selected branch."
sidebar:
  label: "0007. Conditional lowering"
  order: 7
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Reference/Wire/conditionality.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Publications/Paper-3-graph-substitution-semantics/manuscript.md
---

# ADR 0007 — Latent-Branch Conditional Lowering

## Status

Accepted — the conditional lowering model is now the documented execution semantics for built-in
workflow conditionals.

## Context

Conditionals exposed a real semantic gap in the workflow stack. If a conditional were lowered as
plain DAG fan-out, both branches would become runnable under ordinary readiness rules. If it were
hidden in stage-local imperative code, the workflow artifact would stop telling the truth about
future obligations.

The missing piece was not a new runtime mutation mechanism. The runtime already had rewrite and
materialization machinery. What was missing was a truthful representation of latent alternatives at
the workflow boundary.

## Decision

Compile conditionals as condition anchors with latent branch fragments.

- the compiled artifact carries a real condition node plus the branch alternatives attached to it
- at runtime, evaluating the condition selects one branch
- Pulse materializes only the selected branch into the materialized graph
- the condition anchor remains available for lineage and provenance

This makes branch selection a first-class lowering concept rather than plain graph fan-out or hidden
imperative logic.

## Alternatives considered

- **Lower conditionals as ordinary fan-out** — rejected because both branches would appear runnable
  under current graph readiness semantics.
- **Hide branch choice inside stage-local imperative code** — rejected because it destroys the
  honesty of the compiled artifact and weakens operator explanation.
- **Treat every conditional as an open-ended rewrite authored at runtime** — rejected because
  built-in conditionals are structured semantic alternatives, not arbitrary planner invention.

## Consequences

### Positive

- The compiled artifact can represent what obligations may arise without materializing all of them.
- Pulse reuses existing rewrite and materialization machinery instead of gaining a special
  conditional executor path.
- Provenance and lineage remain attached to the condition anchor rather than disappearing into
  branch-local code.

### Negative

- The workflow layer must now model latent possibilities, not just already-materialized topology.
- Conditional semantics are more explicit and therefore more demanding to document.

### Obligations

- Keep conditional branch selection expressed at the workflow or circuit boundary, not as
  product-only convention.
- Preserve the distinction between the compiled artifact and the materialized graph in docs and
  operator tooling.
- Revisit this ADR only if the retained-anchor model is intentionally replaced by a different
  provenance law.

## Related

- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Publications/Paper-3-graph-substitution-semantics/manuscript.md](../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
