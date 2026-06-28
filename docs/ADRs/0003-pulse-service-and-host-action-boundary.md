---
title: "ADR 0003 — Pulse Service and Host-Action Boundary"
description:
  "Pulse runs as a standalone durable execution service; host applications own operator and domain
  behavior through authenticated host-action APIs."
sidebar:
  label: "0003. Pulse boundary"
  order: 3
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
---

# ADR 0003 — Pulse Service and Host-Action Boundary

## Status

Accepted — the standalone Pulse runtime and host-action split are reflected in the shipped runtime
design and surrounding implementation.

## Context

Durable execution needs its own scheduler, checkpoints, leases, recovery path, and health model.
Embedding those concerns directly inside a host application's request-serving process would couple
workflow runtime behavior to API restarts, handler concerns, and product persistence.

At the same time, Pulse cannot directly own host domain tables and product semantics. Domain
mutations, host artifacts, and operator-facing admin surfaces remain host responsibilities.

The system therefore needed a boundary that keeps runtime mechanics isolated without allowing Pulse
to become a second application server for any consumer.

## Decision

Pulse is a standalone durable execution service.

- Pulse owns task definitions, runs, checkpoints, scheduling, leases, signals, and lifecycle
  transitions
- the host owns operator surfaces, product APIs, artifact stores, domain tables, and domain-specific
  semantics
- Pulse reaches domain behavior only through authenticated, idempotent host-action APIs exposed by
  the host
- Pulse does not write host-owned tables directly

This makes Pulse the runtime owner and the host the domain and operator owner. Communication between
them is HTTP or JSON with a dedicated service credential and idempotency keys on mutating host
actions.

## Alternatives considered

- **Embed Pulse directly in the host server or worker process** — rejected because runtime restarts,
  resource isolation, and health management would stay entangled with product serving.
- **Let Pulse write host tables directly** — rejected because it breaks ownership boundaries and
  turns runtime code into domain persistence code.
- **Use a single shared scheduler for both Pulse and host jobs** — rejected because durable workflow
  execution has different lifecycle and recovery semantics from ordinary worker jobs.

## Consequences

### Positive

- Pulse can restart, scale, and recover independently of any host API process.
- Domain mutation remains behind host-owned policy and persistence edges.
- The runtime boundary is explicit enough to support multiple consumers.

### Negative

- The system pays an extra service boundary for host actions and operator queries.
- Idempotency and credential handling are mandatory, not optional cleanup.

### Obligations

- Keep host-action endpoints stable, authenticated, and idempotent.
- Keep Pulse-owned state behind Pulse APIs rather than direct table reads from hosts.
- Document new task types in terms of what Pulse owns versus what must stay downstream.

## Note (2026-06-28)

Pulse provisions its own schema as a library surface: `Cortex.Pulse.Database.provisionPulseSchema`
applies the shipped `data/pulse-schema.sql` data-file when the `pulse` schema is absent, serializing
first provisioning with a transaction-scoped advisory lock, and validates that an existing schema
has the required current shape before returning success. This realizes "Pulse owns its schema" as a
consumer-facing capability — downstreams provision their own Postgres without reaching into Cortex
test SQL — and does not change the ownership boundary.

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
