---
title: "ADR 0003 — Pulse Service and Host-Action Boundary"
description: "Pulse runs as a standalone durable execution service; Portman remains the operator and domain edge through authenticated host-action APIs."
sidebar:
  label: "0003. Pulse boundary"
  order: 3
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Consumers/Portman/response-eval-run.md
  - DIG-320
  - DIG-321
  - DIG-345
  - DIG-353
---

# ADR 0003 — Pulse Service and Host-Action Boundary

## Status

Accepted — the standalone Pulse runtime and host-action split are reflected in the shipped runtime design and surrounding implementation.

## Context

Durable execution needs its own scheduler, checkpoints, leases, recovery path, and health model. Embedding those concerns directly inside Portman's request-serving process would couple workflow runtime behavior to API restarts, handler concerns, and product persistence.

At the same time, Pulse cannot directly own Portman's domain tables and product semantics. Portfolio mutations, workspace artifacts, and operator-facing admin surfaces remain Portman responsibilities.

The system therefore needed a boundary that keeps runtime mechanics isolated without allowing Pulse to become a second Portman application server.

## Decision

Pulse is a standalone durable execution service.

- Pulse owns task definitions, runs, checkpoints, scheduling, leases, signals, and lifecycle transitions
- Portman owns operator surfaces, product APIs, workspace and portfolio tables, and domain-specific semantics
- Pulse reaches domain behavior only through authenticated, idempotent host-action APIs exposed by Portman
- Pulse does not write Portman-owned tables directly

This makes Pulse the runtime owner and Portman the domain and operator owner. Communication between them is HTTP or JSON with a dedicated service credential and idempotency keys on mutating host actions.

## Alternatives considered

- **Embed Pulse directly in the Portman server or worker process** — rejected because runtime restarts, resource isolation, and health management would stay entangled with product serving.
- **Let Pulse write Portman tables directly** — rejected because it breaks ownership boundaries and turns runtime code into domain persistence code.
- **Use a single shared scheduler for both Pulse and Portman jobs** — rejected because durable workflow execution has different lifecycle and recovery semantics from ordinary worker jobs.

## Consequences

### Positive

- Pulse can restart, scale, and recover independently of `portman-api`.
- Domain mutation remains behind Portman-owned policy and persistence edges.
- The runtime boundary is explicit enough to support future non-Portman consumers.

### Negative

- The system pays an extra service boundary for host actions and operator queries.
- Idempotency and credential handling are mandatory, not optional cleanup.

### Obligations

- Keep host-action endpoints stable, authenticated, and idempotent.
- Keep Pulse-owned state behind Pulse APIs rather than direct table reads from Portman.
- Document new task types in terms of what Pulse owns versus what must stay downstream.

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
- [../Consumers/Portman/response-eval-run.md](../Consumers/Portman/response-eval-run.md)

