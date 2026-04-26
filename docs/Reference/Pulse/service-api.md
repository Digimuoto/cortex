---
title: "Pulse Service API Reference"
description: "Normative HTTP contract for the Pulse runtime: task management, run inspection, cancellation, health, authentication, idempotency."
sidebar:
  label: "Pulse service API"
  order: 12
status: accepted
---

# Pulse Service API Reference

Pulse exposes its own HTTP API for task management. Downstream consumers (operator surfaces, admin panels, product APIs) communicate with Pulse through this contract, never by reading or writing Pulse tables directly.

Architectural framing is in [chapter 06](../../Architecture/06-pulse-runtime.md). This reference states the endpoints, auth, and idempotency rules.

## 1. Endpoints

| Endpoint                                      | Description                                                                      |
|-----------------------------------------------|----------------------------------------------------------------------------------|
| `POST /Pulse/v1/tasks`                        | Create a task definition. Validates the `CortexTaskEnvelope` eagerly.            |
| `GET  /Pulse/v1/tasks`                        | List task definitions with schedule state.                                       |
| `GET  /Pulse/v1/tasks/:id`                    | Task detail.                                                                     |
| `POST /Pulse/v1/tasks/:id/trigger`            | Manual trigger. Creates a run with `trigger_source = manual`.                    |
| `GET  /Pulse/v1/runs/:id`                     | Run detail: status, checkpoint, stage log with per-attempt history.              |
| `POST /Pulse/v1/runs/:id/cancel`              | Request cancellation. Sets `cancel_requested_at`; the executor finalizes.        |
| `POST /Pulse/v1/runs/:id/retry`               | Create a fresh run linked by `parent_run_id`. Accepts all terminal states.       |
| `POST /Pulse/v1/runs/:id/signal`              | Deliver a named external signal to a waiting node. Wakes the run if pending.     |
| `GET  /Pulse/v1/health`                       | Heartbeat, active run count, max concurrent limit, scheduler state.              |

The health endpoint reports per-type active counts under `phsActiveRunsByType` when per-task-type caps are configured.

## 2. Authentication

All requests carry a service credential:

```
X-Pulse-Credential: <service-secret>
```

The credential is a shared secret provisioned at deployment time, distinct from user authentication. The server validates it with constant-time comparison and fails closed when unconfigured.

## 3. Idempotency

Every mutating request must include:

```
X-Idempotency-Key: <run_id>/<stage_name>/<action_name>
```

The server reserves the key before execution and caches the response after. Duplicate requests with the same key return the cached response without re-executing. Idempotency keys are retained for 7 days.

This gives Pulse exactly-once semantics across crash-resume and network-retry boundaries: a retry after a timeout cannot cause a second execution.

## 4. Cancellation protocol

1. Caller issues `POST /Pulse/v1/runs/:id/cancel`.
2. Pulse sets `cancel_requested_at` on `pulse.runs`.
3. The executor checks the flag at stage boundaries, between tool-loop steps, and before any irreversible stage action.
4. When cancelled, Pulse writes a checkpoint at the last completed stage, transitions the run to `cancelled` with a reason, and advances the schedule.

Only Pulse moves runs to terminal states. No caller may write these transitions directly.

## 5. Observability

Pulse emits structured events on lifecycle transitions, stage transitions, and scheduler decisions. The full event catalog, severity classification, and field contract live in [`events.md`](./events.md). Events are read through `GET /Pulse/v1/runs/:id`, not by querying the event table directly.

Model-call and tool-invocation cost is tracked in Pulse's own usage records. Consumers that need aggregate cost visibility query it through the API or subscribe to the event stream; they do not read Pulse tables.

## 6. Error taxonomy

Error categories used across run and stage failures. Consumer-specific error categories live in the consumer's own page.

| Category                | Retryable    | Description                                  |
|-------------------------|--------------|----------------------------------------------|
| `model_timeout`         | yes          | LLM call exceeded deadline.                  |
| `model_refusal`         | no           | LLM refused the request.                     |
| `model_rate_limit`      | yes (backoff)| Provider rate limit hit.                     |
| `tool_failure`          | depends      | Tool call failed.                            |
| `stale_data`            | yes (refresh)| Upstream data too old.                       |
| `config_decode_error`   | no           | Operator must fix config.                    |
| `checkpoint_corruption` | no           | Manual intervention required.                |
| `checkpoint_incompatible`| no          | Envelope version does not match current code.|
| `stage_timeout`         | per retry policy | Per-stage timeout fired.                 |
| `host_action_failure`   | depends      | Downstream host-action call failed.          |

The error category and retryable flag are persisted in the stage log and emitted in observability events.

## Related

- [./schema.md](./schema.md) — DB rows backing these endpoints.
- [./types.md](./types.md) — request and response shapes.
- [./host-actions.md](./host-actions.md) — the inverse direction: Pulse → host callouts.
- [./events.md](./events.md) — run-event catalog.
- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — runtime framing.
- [../../Consumers/Portman/pulse-host-actions.md](../../Consumers/Portman/pulse-host-actions.md) — Portman's concrete binding of the host-action contract.

---

*End of Pulse Service API Reference.*
