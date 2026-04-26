---
title: Cortex Consumers
description: Per-consumer bindings of Cortex. Each downstream product using Cortex gets its own subdirectory documenting its binding, extensions, and domain-specific integrations.
sidebar:
  label: Consumers
  order: 5
---

# Cortex Consumers

Cortex is a generic AI substrate; consumers bind it into product-specific runtimes. This directory holds per-consumer documentation for those bindings.

## Current consumers

- **[Portman/](Portman/)** — Portman: finance portfolio platform. Binds Cortex for Clerk assistant runtime, deep-report workflows, and Pulse durable execution.

## What belongs here

Consumer-specific design docs that describe:

- How the consumer binds Cortex's runtime seams.
- Product-domain extensions (e.g., finance-specific contracts, tools, report shapes).
- Domain-specific ADRs (e.g., how finance policy attaches to Cortex actions).
- Consumer-side workflow specs built on Cortex primitives.

What does **not** belong here: generic Cortex substrate concerns, which stay in `Architecture/` or `Reference/`.

## Adding a consumer

Create `Consumers/{name}/` with its own `index.md`. Use the [architecture-page template](../Templates/architecture-page.md) or [section-index template](../Templates/section-index.md) as a starting point.

## Related

- [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) — the Cortex/consumer boundary rules.
- [../ADRs/](../ADRs/) — substrate-level decisions that affect all consumers.
