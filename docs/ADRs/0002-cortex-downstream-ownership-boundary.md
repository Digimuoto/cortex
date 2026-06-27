---
title: "ADR 0002 - Cortex and Downstream Ownership Boundary"
description:
  "Reusable AI substrate lives in Cortex; host applications own domain semantics, product policy,
  transport, and persistence."
sidebar:
  label: "0002. Ownership boundary"
  order: 2
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/02-ownership-and-boundaries.md
---

# ADR 0002 - Cortex and Downstream Ownership Boundary

## Status

Accepted. Cortex is a standalone substrate. Downstream consumers integrate it through product
bindings and host actions.

## Context

Cortex started inside a product codebase, so early module and documentation boundaries followed the
first consumer's call sites. That was useful for shipping, but it is not a stable architecture. A
reusable substrate must be defined by semantic ownership, not by whichever product first exercised a
runtime path.

Portman remains the primary downstream example in this repository. That is intentional: concrete
consumer documentation keeps Cortex honest. The boundary problem appears only when Portman becomes
the frame through which Cortex itself is defined.

## Decision

Adopt a strict three-part ownership boundary:

- **Cortex substrate** owns reusable authoring, topology, execution, capability, provenance, memory,
  and artifact mechanics. Generic external-call execution is a substrate capability, but
  model-provider adapters, response schemas, and structured-output policy are Logos-owned (ADR
  0040).
- **Downstream product binding** owns prompts, tools, domain semantics, product policy, task
  registration, artifact meaning, and operator choices.
- **Host edge** owns transport, auth, persistence, streaming, route conversion, and delivery
  behavior.

Dependency direction follows ownership:

`host edge -> product binding -> Cortex substrate`

Runtime callbacks may move the other way through registered handlers, but those callbacks do not
change ownership. A Cortex module must not import downstream domain or host-edge concepts.

## Consequences

Positive consequences:

- Cortex can be adopted by another host without inheriting Portman semantics.
- Portman can remain a rich downstream example without becoming Cortex's architectural boundary.
- Code review has a clear placement rule for reusable runtime and provider work.
- Consumer-specific docs can stay under `docs/Consumers/` without polluting canonical architecture
  chapters.

Costs and obligations:

- Some refactors are larger because ownership has to be corrected, not only local helper placement.
- Generic abstractions sometimes need to be introduced before the second consumer exists.
- Documentation must distinguish "Portman as example" from "Portman as frame".

## Alternatives Considered

- **Let the first consumer define Cortex's shape.** Rejected because it bakes a product boundary
  into a substrate.
- **Forbid consumer docs from Cortex.** Rejected because downstream examples are useful when they
  are clearly scoped.
- **Move all product workflow semantics into Cortex.** Rejected because domain meaning and product
  policy belong downstream.

## Related

- [Chapter 01 - Overview](../Architecture/01-overview.md)
- [Chapter 02 - Ownership and boundaries](../Architecture/02-ownership-and-boundaries.md)
