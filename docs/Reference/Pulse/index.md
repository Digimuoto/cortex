---
title: "Pulse Reference"
description: "Normative reference for the Pulse durable runtime: schema, types, service API."
sidebar:
  label: "Pulse"
  order: 20
status: accepted
---

# Pulse Reference

Consultable normative material for the Pulse runtime. Architectural framing lives in [chapter 06](../../Architecture/06-pulse-runtime.md); this directory states the rules.

## Contents

- **[schema.md](schema.md)** — DB enums, task definitions, runs, checkpoints, stage log, stage attempt log, run events, signals.
- **[types.md](types.md)** — task envelope, checkpoint envelope, stage plan, retry policy, memory strategy, stage result.
- **[service-api.md](service-api.md)** — inbound HTTP endpoints, authentication, idempotency, cancellation protocol, error taxonomy.
- **[host-actions.md](host-actions.md)** — outbound contract for Pulse → host callouts.
- **[signals.md](signals.md)** — signal protocol, state machine, producer and consumer semantics.
- **[events.md](events.md)** — run-event catalog: lifecycle, stage, and rewrite events.

## Related

- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — Pulse runtime architecture.
- [../terminology.md](../terminology.md) — normative vocabulary.
- [../../Consumers/](../../Consumers/) — downstream binding examples.
