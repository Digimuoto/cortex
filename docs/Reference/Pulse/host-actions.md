---
title: "Pulse Host-Action Contract"
description: "Normative contract for Pulse → host callouts: direction, authentication, idempotency, retry and timeout semantics, response shape."
sidebar:
  label: "Pulse host actions"
  order: 13
status: accepted
---

# Pulse Host-Action Contract

Pulse does not execute domain work. When a stage needs host-owned state — to read, validate, or mutate — it calls the host through a host-action endpoint the host provides. This page states the generic contract. A specific host's endpoint catalog is its own downstream binding.

Architectural framing is in [chapter 06](../../Architecture/06-pulse-runtime.md). Service-API fundamentals (auth, idempotency) repeat in both directions and are specified here for the Pulse → host direction.

## 1. Direction and scope

| Direction       | Transport | Purpose                                        |
|-----------------|-----------|------------------------------------------------|
| Host → Pulse    | Pulse service API ([`service-api.md`](./service-api.md)) | Task lifecycle: create, trigger, cancel, retry, signal, inspect.       |
| **Pulse → host**| Host-action API (this contract)                         | **Per-stage domain work**: fetches, validations, persistence writes, irreversible side effects. |

Host actions are internal endpoints. They are never exposed to end users. The host may serve them from a dedicated internal port or gate them on the service credential.

## 2. Authentication

Every request carries the shared service credential:

```
X-Pulse-Credential: <service-secret>
```

The host validates the credential with constant-time comparison and fails closed when unconfigured. The same secret is used in both directions so a single deployment-time rotation covers the full boundary.

## 3. Idempotency

Every mutating host-action call carries the Pulse-assigned idempotency key:

```
X-Idempotency-Key: <run_id>/<stage_name>/<action_name>
```

The host is expected to implement exactly-once semantics keyed on this header: a duplicate key returns the original response without re-executing the domain work. Pulse guarantees the key is stable across crash-resume and network-retry boundaries.

Read-only host actions may omit the header.

## 4. Retry and timeout semantics

Host-action failures surface as `host_action_failure` in Pulse's error taxonomy ([`service-api.md §6`](./service-api.md#6-error-taxonomy)). Retryability is decided by the stage's retry policy, not by the host response.

- A host that wants Pulse to retry responds with a retryable error shape (see §5).
- A host that wants the run to fail non-retryably responds with a terminal error shape.
- The per-stage timeout (`sdTimeoutSeconds` or the task default) applies to the whole Pulse → host call. A host action that does not complete within it produces `stage_timeout`.
- Cancellation is not propagated over host-action calls. If Pulse is cancelled mid-call, it waits for the response, records it, and finalizes at the next safe boundary.

## 5. Response shape

Success responses return the JSON body the stage action expects. There is no success envelope — the response schema is bilateral between the stage's declared output type and the host endpoint.

Failure handling is host-negotiated today: Cortex has no generic host-action response decoder, so the stage action itself interprets the host's error response and surfaces the resulting `host_action_failure` to the taxonomy ([`service-api.md §6`](./service-api.md#6-error-taxonomy)). The recommended error shape is:

```json
{
  "error_type": "<category>",
  "message":    "<human-readable description>",
  "retryable":  true | false,
  "details":    { /* optional, error-specific */ }
}
```

A stage action that adopts this envelope preserves the retryability and category information through to the stage log and run events without additional mapping. Hosts may define categories beyond Pulse's generic taxonomy; consumer-specific categories are documented in that consumer's binding page.

## 6. What does not route through host actions

Model calls and tool invocations stay inside Cortex and do not go through the host:

| Action       | Owner   | Protocol                                 |
|--------------|---------|------------------------------------------|
| `callModel`  | Cortex  | Provider-neutral LLM interface.          |
| `callTool`   | Cortex  | Gatherer tool dispatch.                  |

A host must not proxy these. Model and tool usage is tracked in Pulse's own records and surfaced through Pulse's API.

## Related

- [./service-api.md](./service-api.md) — the inverse direction (host → Pulse).
- [./types.md](./types.md) — `StageAction`, `StageContext`, stage-result alphabet.
- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — runtime framing.
- [../../Consumers/](../../Consumers/) — downstream binding examples.

---

*End of Pulse Host-Action Contract.*
