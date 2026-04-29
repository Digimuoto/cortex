---
title: Cortex Consumers
description:
  Downstream consumers of Cortex. Consumer docs show how products and libraries attach domain
  semantics, policy, tools, persistence, or reasoning workflows to the substrate.
sidebar:
  label: Consumers
  order: 5
---

# Cortex Consumers

Cortex is a generic AI substrate; consumers bind it into downstream libraries or product-specific
runtimes. These pages show binding patterns without making any consumer the frame for Cortex itself.

## Documented consumers

- **[Logos](Logos/)** - downstream reasoning library. Shows how reusable model-mediated workflows,
  archetypes, memory, and patterns sit above Cortex without becoming substrate runtime authority.
- **[Portman](Portman.md)** - private downstream example. Shows how one product binds Cortex to
  product policy, artifacts, persistence, and Pulse host actions.

## What belongs here

Consumer-specific design docs that describe:

- How the consumer binds Cortex's runtime seams.
- Library or product-domain extensions, such as host-specific contracts, tools, reusable reasoning
  patterns, and report shapes.
- Domain-specific decisions, such as how host policy attaches to Cortex actions.
- Consumer-side workflow specs built on Cortex primitives.

What does **not** belong here: generic Cortex substrate concerns, which stay in `Architecture/` or
`Reference/`.

## Adding a consumer

Start with one page under `Consumers/{Name}.md`. Create a subdirectory only when the consumer is
public enough and broad enough to justify a multi-page binding reference.

## Related

- [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) -
  Cortex and consumer boundary rules.
- [../ADRs/](../ADRs/) - substrate-level decisions that affect all consumers.
