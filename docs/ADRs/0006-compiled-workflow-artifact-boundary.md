---
title: "ADR 0006 — Compiled Workflow Artifact Boundary"
description: "Workflow intent compiles into a first-class artifact that separates product semantics from Pulse lowering and execution."
sidebar:
  label: "0006. Workflow artifact"
  order: 6
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Publications/Paper-3-graph-substitution-semantics/manuscript.md
  - DIG-450
  - DIG-457
---

# ADR 0006 — Compiled Workflow Artifact Boundary

## Status

Accepted — the workflow compiler boundary landed in DIG-450 and DIG-457 and is the basis for current workflow architecture language.

## Context

Before the workflow compilation work, product workflows mostly lived as task-specific code paths and ad hoc lowering conventions. That made three things hard:

- expressing product intent as a reusable artifact
- exposing workflows honestly in APIs and UI
- keeping product semantics out of Pulse internals

The runtime already knew how to execute and materialize graph state. What was missing was a first-class artifact between product intent and runtime lowering.

## Decision

Workflow intent compiles into a first-class compiled artifact.

- product or domain code defines workflow intent above Pulse
- the compiler lowers that intent into a reusable workflow artifact
- Pulse lowers and executes that artifact; it does not own the product compiler semantics that produced it

The compiled artifact is therefore the canonical boundary between product semantics and durable runtime execution. It is useful even when a given construct is not yet fully executable, because it carries the honest shape of the workflow contract above the runtime.

## Alternatives considered

- **Lower product workflows directly into Pulse stage plans** — rejected because it tangles product semantics with runtime mechanics and leaves no honest artifact boundary.
- **Treat compiled workflows as documentation-only shadow structures** — rejected because the same artifact is needed for APIs, UI, and runtime lowering.
- **Move workflow compilation entirely into Pulse** — rejected because workflow compilation is a semantic layer above the generic runtime, not part of the executor core.

## Consequences

### Positive

- Product workflow intent has a stable place to live above Pulse.
- APIs and UI can talk about compiled workflows directly instead of reverse-engineering task code.
- Conditional and rewrite-aware execution can be framed as artifact-lowering questions instead of ad hoc runtime patches.

### Negative

- The system now has to maintain one more explicit layer boundary.
- Some workflow constructs can exist in the artifact before they are fully dogfooded end to end.

### Obligations

- Keep product compilers above the artifact boundary and Pulse below it.
- Use the compiled artifact as the source for operator and API vocabulary where possible.
- Avoid treating the artifact as optional once product code exists.

## Related

- [../Architecture/04-graph-and-circuit.md](../Architecture/04-graph-and-circuit.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Publications/Paper-3-graph-substitution-semantics/manuscript.md](../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
