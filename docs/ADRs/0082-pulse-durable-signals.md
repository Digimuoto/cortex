---
title: "ADR 0082 - Pulse Durable Signal Primitive"
description:
  "Govern Pulse's base durable signal primitive: run-scoped opaque names, pending/delivered state,
  at-most-one pending wait per name, reserved runtime-owned signal families, and the staged expiry
  field."
sidebar:
  label: "0082. Durable signals"
  order: 82
status: proposed
date: 2026-06-30
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/signals.md
  - docs/Reference/Pulse/schema.md
  - docs/Reference/Pulse/service-api.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0082 - Pulse Durable Signal Primitive

## Status

Proposed. This records the generic durable signal primitive already implemented and documented in
the Pulse signal reference. ADR 0058 and ADR 0059 specialize this primitive for run-terminal and
external-call signal families; they do not own the base mechanism.

## Context

Pulse can park a node until an out-of-band event arrives. The implementation already has
`SignalName`, `SignalWait`, `SignalDelivery`, and `SignalStatus`, a `pulse.signals` table, delivery
queries, an `expires_at` field plus `SignalExpired` representation, and service API delivery. The
active expiry transition/sweep is not yet implemented; the reference page describes the intended
state, while this ADR governs the shipped primitive honestly.

## Decision

Pulse owns a durable signal primitive for run-scoped external events.

- A signal name is an opaque `Text` scoped to one `run_id`.
- At most one pending wait may exist for `(run_id, signal_name)`; a name can be reused after the
  prior wait is delivered. Reuse after expiry is reserved by the schema but depends on the future
  expiry transition.
- The shipped base state machine is `pending -> delivered`; delivered rows are terminal for ordinary
  signals. `pending -> expired` is represented in schema/types and remains staged until a runtime
  expiry path is implemented and tested.
- Delivery is an atomic Pulse mutation: it records payload and timestamp, marks the wait delivered,
  and wakes the waiting run when applicable.
- The public service delivery path may deliver ordinary host-named signals only. Runtime-owned
  reserved families such as `run-terminal:` and `external-call:` are delivered only by trusted
  runtime paths.
- A signal payload is not a general authority channel. Ordinary delivered payloads satisfy ordinary
  waits; reserved families define their own resolution rule in the ADR that owns that family.

## Consequences

### Positive

- ADR 0058 and ADR 0059 now rest on one named base primitive instead of implicitly defining it.
- Pending uniqueness, delivery idempotency, and the staged expiry field have a single governance
  anchor.
- Future runtime-produced signal families must explicitly state their reserved namespace and
  resolution rule.

### Negative

- Signals remain a low-level Pulse primitive. Higher-level timers, child-run await, and
  external-call completion need separate ADRs or amendments for their family-specific semantics.
- Expiry is not yet an active runtime transition; callers must not rely on `expires_at` being
  advanced to `expired` until that follow-up lands.

### Obligations

- Keep `docs/Reference/Pulse/signals.md` as the normative signal protocol reference.
- Keep reserved-family delivery out of the public `deliverSignal` path.
- Any new reserved signal family must document its namespace, producer, delivery path, payload
  interpretation, and wake/resume rule.
- Tests covering ordinary delivery, duplicate delivery, pending uniqueness, and reserved namespace
  rejection must continue to exercise the base primitive.
- Implementing signal expiry requires a runtime transition path plus regression coverage before the
  ADR or feature-status row may claim active expiry handling.

## Traceability

- Feature keys: `pulse.durable_signals`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/signals.md`,
  `docs/Reference/Pulse/service-api.md`
- Implementation: `src/Cortex/Pulse/Signal.hs`, `src/Cortex/Pulse/Query.hs`,
  `src/Cortex/Pulse/Schema.hs`
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`
- Theory/proof: none

## Related

- [ADR 0003 - Pulse Service and Host-Action Boundary](./0003-pulse-service-and-host-action-boundary.md)
- [ADR 0058 - Pulse Atomic Suspend Settlement](./0058-pulse-atomic-suspend-settlement.md)
- [ADR 0059 - Durable External-Call Frontiers on Pulse](./0059-durable-external-call-frontiers-on-pulse.md)
- [Pulse Signals Reference](../Reference/Pulse/signals.md)
