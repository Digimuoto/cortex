---
title: "Pulse Run-Event Catalog"
description:
  "Normative event catalog for Pulse: lifecycle, stage, scheduler, and diagnostic events. Severity,
  field set, retention contract."
sidebar:
  label: "Pulse run events"
  order: 15
status: accepted
---

# Pulse Run-Event Catalog

Pulse emits a structured event on every material run transition and on diagnostic conditions. Events
are persisted per run and surfaced through the run-detail endpoint; event persistence is best-effort
and never blocks the run itself.

This page is the event catalog and field contract. Architectural framing is in
[chapter 06](../../Architecture/06-pulse-runtime.md); persistence is in
[`schema.md §7`](./schema.md#7-run-events).

Event-type identifiers are dot-separated and namespaced by subject (`run.`, `stage.`, `schedule.`,
`lease.`). New entries should follow the same convention.

## 1. Severity

```haskell
data RunEventSeverity
  = RunEventInfo
  | RunEventWarn
  | RunEventError
```

- **info** — ordinary lifecycle progress.
- **warn** — degraded behavior that did not fail the run, or a recoverable scheduler decision.
- **error** — the run or stage reached a failure state, or a persistence write failed.

## 2. Event record

Every event carries the fields below. `event_type` identifies the event; `details` is an
event-specific JSON object.

| Field        | Description                       |
| ------------ | --------------------------------- |
| `run_id`     | Run identity.                     |
| `event_type` | One of the catalog entries in §3. |
| `severity`   | `info` / `warn` / `error`.        |
| `message`    | Human-readable description.       |
| `details`    | Optional event-specific JSON.     |
| `created_at` | Event timestamp.                  |

Common `details` fields observed across events (present when applicable):

| Field         | Description                                                                |
| ------------- | -------------------------------------------------------------------------- |
| `stage`       | Stage identity (stage events).                                             |
| `error_type`  | Error category ([`service-api.md §6`](./service-api.md#6-error-taxonomy)). |
| `next_run_at` | Scheduler target time (schedule events).                                   |
| `outcome`     | Run-outcome tag (schedule events).                                         |

## 3. Catalog

### Run lifecycle

| `event_type`                     | Severity | Emitted when                                                                                                                                 |
| -------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `run.claimed`                    | info     | Scheduler claimed the run; details carry `queue_seconds`, the pending wait before claim (queue time and execution time are distinct clocks). |
| `run.completed`                  | info     | All stages completed successfully.                                                                                                           |
| `run.failed`                     | error    | Scheduler observed an executor exception.                                                                                                    |
| `run.failed.settled`             | error    | Graph settled with failures at the end of execution.                                                                                         |
| `run.suspended`                  | info     | Run suspended waiting on an external signal.                                                                                                 |
| `run.cancelled`                  | info     | Task cancelled by operator request.                                                                                                          |
| `run.shutdown`                   | info     | Shutdown requested; executor stopping at a stage boundary.                                                                                   |
| `run.stuck`                      | error    | Frontier empty but not all nodes settled (blocked-graph diagnostic).                                                                         |
| `run.graph_state_persist_failed` | error    | Graph-state persistence write failed mid-run.                                                                                                |
| `run.graph_state_stale_write`    | warn     | Executor lost a graph-state CAS race and stopped without overwrite.                                                                          |

### Stage

| `event_type`                               | Severity | Emitted when                                                                  |
| ------------------------------------------ | -------- | ----------------------------------------------------------------------------- |
| `stage.completed`                          | info     | Stage returned `StageComplete`.                                               |
| `stage.failed`                             | error    | Stage returned a terminal failure.                                            |
| `stage.skipped`                            | warn     | Stage skipped after retry exhaustion under `ExhaustionSkipsStage` policy.     |
| `stage.rewritten`                          | info     | Stage emitted `StageRewrite` and the runtime admitted the proposal.           |
| `stage.rewrite_degraded`                   | warn     | Stage accepted degraded output after rewrite-budget exhaustion.               |
| `stage.worker_exception_reified`           | error    | Async worker exception escaped `spawnNodeWorker`; reified into a node result. |
| `stage.worker_exception_unattributed`      | error    | Async worker exception escaped with no matching worker handle.                |
| `stage.cancel_before_retry_persist_failed` | warn     | Cancel-before-retry state failed to persist.                                  |

### Scheduler

| `event_type`        | Severity | Emitted when                                                            |
| ------------------- | -------- | ----------------------------------------------------------------------- |
| `schedule.advanced` | info     | Scheduler advanced `next_run_at` after run finalization.                |
| `schedule.restored` | warn     | One-off task visibility restored (e.g. after failure) for manual retry. |
| `lease.lost`        | error    | Run's lease expired; scheduler observed the loss before reclaim.        |

## 4. Persistence contract

- Persistence is best-effort: a write failure is logged and the run continues. Event history is
  supplementary observability and is never load-bearing for correctness.
- Events are append-only once written; there is no update path.
- Retention is governed at the schema level; callers should not depend on unbounded history.
- Events are read through the run-detail API, not by querying the event table directly.

## Related

- [./schema.md](./schema.md) — run-event table.
- [./service-api.md](./service-api.md) — run-detail endpoint and error taxonomy.
- [./signals.md](./signals.md) — signal-related events (`run.suspended`).
- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — runtime
  framing.
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md)
  — rewrite event semantics.

---

_End of Pulse Run-Event Catalog._
