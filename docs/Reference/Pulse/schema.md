---
title: "Pulse Schema Reference"
description:
  "Normative DB schema for the Pulse durable runtime: enums, task definitions, runs, checkpoints,
  stage log, stage attempt log."
sidebar:
  label: "Pulse schema"
  order: 10
status: accepted
---

# Pulse Schema Reference

Pulse owns its own schema (`pulse`) and DB role. Host tables are never read or written by Pulse;
operator surfaces read Pulse state through the [Pulse service API](./service-api.md), not by
querying these tables directly.

All columns below are in the `pulse` schema.

## 1. Enums

```sql
pulse.run_status      -- pending | running | waiting | completed | failed
                      -- cancelled | timeout | skipped
pulse.trigger_source  -- schedule | manual | retry
pulse.stage_status    -- started | completed | failed | skipped
```

`waiting` is the run-level state used while at least one node is suspended on a signal and no other
node is runnable.

Status and source columns use PostgreSQL enums for type safety.

## 2. Task definitions

```text
pulse.task_definitions
  task_id            uuid primary key
  task_type          text not null
  task_name          text not null unique
  config             jsonb not null              -- CortexTaskEnvelope
  cron_expression    text not null               -- empty for one-off
  enabled            boolean not null default true
  scheduler_claimed  boolean not null default false
  next_run_at        timestamptz
  last_run_at        timestamptz
  last_run_status    pulse.run_status
  timeout_seconds    integer not null default 3600
  created_at         timestamptz not null
  updated_at         timestamptz not null
```

`scheduler_claimed` is the atomic claim flag. The scheduler sets it `true` under CAS when it creates
a run, and resets it to `false` during schedule finalization (on completion, failure, cancellation,
or lease-expiry recovery). The enabled-tasks index filters on
`WHERE enabled = true AND scheduler_claimed = false`.

`config` carries a `CortexTaskEnvelope` ([types reference](./types.md#1-task-envelope)) that the
launch path decodes eagerly at creation and at execution time.

## 3. Runs

```text
pulse.runs
  run_id               uuid primary key
  task_id              uuid not null references pulse.task_definitions(task_id)
  status               pulse.run_status not null
  trigger_source       pulse.trigger_source not null
  started_at           timestamptz           -- null while pending
  completed_at         timestamptz
  duration             interval
  lease_owner          text                  -- hostname/pid for crash detection
  lease_expires_at     timestamptz
  cancel_requested_at  timestamptz           -- polled by executor
  cancel_reason        text
  error_type           text
  error_message        text
  error_retryable      boolean
  skip_reason          text
  parent_run_id        uuid references pulse.runs(run_id)
  created_at           timestamptz not null
```

`parent_run_id` links a retry to its origin. Retry creates a fresh run and does not inherit the
parent's checkpoint lineage — see
[run identity](../../Architecture/06-pulse-runtime.md#run-identity-and-operator-verbs) for the full
verb table.

## 4. Checkpoints

```text
pulse.checkpoints
  run_id            uuid primary key references pulse.runs(run_id)
  task_type         text not null
  checkpoint_name   text not null
  state             jsonb not null             -- CheckpointEnvelope
  summary           jsonb
  updated_at        timestamptz not null
```

Mutable latest-checkpoint per run. The `state` payload is a versioned
[`CheckpointEnvelope`](./types.md#2-checkpoint-envelope); mismatched envelopes fail the run
non-retryably on resume rather than silently resuming against changed code.

## 5. Stage log

```text
pulse.stage_log
  id              bigserial primary key
  run_id          uuid not null references pulse.runs(run_id)
  stage_name      text not null
  status          pulse.stage_status not null
  state_summary   jsonb
  started_at      timestamptz not null
  completed_at    timestamptz
```

Append-only audit trail. Does not depend on observability log retention.

## 6. Stage attempt log

```text
pulse.stage_attempt_log
  attempt_id       bigserial primary key
  stage_log_id     bigint not null references pulse.stage_log(id) on delete cascade
  run_id           uuid not null references pulse.runs(run_id) on delete cascade
  attempt_number   integer not null   -- unique per (stage_log_id, attempt_number)
  status           pulse.stage_status not null
  summary          jsonb              -- error_type, error message on failure
  started_at       timestamptz not null
  completed_at     timestamptz
```

One row per stage attempt. Stages with retry policies produce a row per retry, preserving the
failure/retry timeline for operator inspection.

## 7. Run events

```text
pulse.run_events
  event_id     bigserial primary key
  run_id       uuid not null references pulse.runs(run_id) on delete cascade
  event_type   text not null
  severity     text not null               -- info | warn | error
  message      text not null
  details      jsonb
  created_at   timestamptz not null default now()
```

Append-only per-run event log. The normative event catalog, severity, and field contract live in
[`events.md`](./events.md); persistence is best-effort — event writes never block or fail a run.

## 8. Graph state

```text
pulse.graph_state
  run_id                    uuid primary key references pulse.runs(run_id) on delete cascade
  node_statuses             jsonb not null
  node_outputs              jsonb not null
  remaining_rewrite_budget  jsonb
  runtime_version           integer
  applied_rewrite_id        bigint references pulse.graph_rewrites(rewrite_id)
  node_provenance           jsonb
  topology_hash             text
  updated_at                timestamptz not null
```

Mutable latest graph snapshot for durable resume. `node_statuses` and `node_outputs` carry the
runtime graph-state maps; rewrite fields bind the snapshot to the materialized rewrite lineage.

`updated_at` is also the optimistic compare-and-swap revision token. The first graph-state write is
insert-only. Later writes update the row only when the caller's expected revision matches the
current `updated_at`; stale owners stop without overwriting newer graph state and emit
[`run.graph_state_stale_write`](./events.md#run-lifecycle).

## 9. Signals

```text
pulse.signals
  signal_id     bigserial primary key
  run_id        uuid not null references pulse.runs(run_id) on delete cascade
  signal_name   text not null
  node_id       text                        -- nullable: which node registered the wait
  status        text not null default 'pending'   -- pending | delivered | expired
  payload       jsonb                       -- null until delivered
  created_at    timestamptz not null
  delivered_at  timestamptz
  expires_at    timestamptz

  -- At most one pending signal per (run, name); the same name may be reused
  -- across stages within a run once a prior wait has been delivered or expired.
  unique index (run_id, signal_name) where status = 'pending'
  -- Run-terminal delivery updates pending signals by signal_name across runs;
  -- this partial index keeps that off a full pending-signal scan.
  index (signal_name) where status = 'pending'
```

Durable external-event storage. The signal protocol, delivery semantics, and `StageSuspend`
interaction are in [`signals.md`](./signals.md).

## 10. External-call attempts

```
pulse.external_call_attempts
  attempt_id          bigserial primary key
  run_id              uuid not null
  node_id             text not null            -- the realize stage node
  runtime_binding_id  text not null
  frontier_id         text not null            -- canonical hash of the frozen frontier
  idempotency_key     text not null
  frozen_plan         jsonb not null           -- the canonical frozen external-call payload
  job_handle          jsonb                     -- null until the provider submit is recorded
  signal_name         text                      -- reserved external-call: wake token (ADR 0059 §3)
  status              text not null default 'reserved'   -- reserved | submitted | settled | failed
  failure_reason      text                      -- typed failure reason when status = 'failed'
  created_at, submitted_at, settled_at  timestamptz

  unique index (run_id, node_id, runtime_binding_id, frontier_id)
  foreign key (run_id) references pulse.runs(run_id) on delete cascade
```

The Pulse-owned durable home for a `submit_park_resume` external call's executor metadata (ADR 0059
§3). ADR 0058 suspend settlement commits only graph state, signal wait rows, and run status, so this
record — not the signal rows — carries the idempotency key, frozen payload, and provider job handle.
Reserve is idempotent on the key, so crash recovery re-entry never creates a duplicate provider
task; provider fields are opaque JSON that Pulse does not interpret. The stored `idempotency_key` is
the **Pulse-side** dedup anchor; it is distinct from the driver-owned provider submit/dedup token
(which may fold request parameters such as region/device/shots/bucket/prefix and is not persisted
here). The `external-call:` wake is a reserved name family that ordinary `deliverSignal` refuses
(only the trusted external-call delivery path may mark it delivered); its delivery re-arms the
waiting node so the bound stage fetches and validates the provider result rather than completing
from the signal payload (see [`signals.md §4.2`](./signals.md#42-external-call-wake-signals)). A
typed backend failure is recorded in `failure_reason` and read back on resume, so a crash between
the failure write and the node-completion graph write reproduces the same typed reason rather than
losing it.

## Appendix A — Ownership

The `pulse` DB role has full ownership of every table in this schema and no access to host tables.
Cross-boundary reads are mediated by Pulse's HTTP API. Running Pulse and a host application in the
same PostgreSQL cluster is an operational shortcut; the architectural boundary is service-API-first
so migrating to a separate database is cheap.

`Cortex.Pulse.Database.provisionPulseSchema` is the library surface for consumer-owned provisioning:
it applies the shipped schema data-file when `pulse` is absent, serializes concurrent first
provisioners with a transaction-scoped advisory lock, and rejects an existing schema that is missing
required current tables, columns, or enum labels.

## Appendix B — Migrations

This file is a generated dump of the applied `pulse` schema, and there is no in-repo migration
runner for already-deployed databases. `provisionPulseSchema` can create or validate the current
shape, but it does not migrate a stale deployed schema in place. Forward, idempotent DDL for
bringing **deployed** databases up to the current shape lives in the repo-root `migrations/`
directory (see `migrations/README.md`). Apply the relevant migration before rolling out code that
depends on the new shape — e.g. `migrations/0001_graph_rewrites_admission_mode.sql` adds
`pulse.graph_rewrites.admission_mode` (ADR 0055 / 0056), backfilling existing rows to `gassed`.

## Related

- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — architectural
  framing.
- [./types.md](./types.md) — Haskell types carried in the jsonb columns.
- [./service-api.md](./service-api.md) — endpoints that read and mutate these tables.
- [./host-actions.md](./host-actions.md) — the Pulse → host callout contract.
- [./signals.md](./signals.md) — signal protocol and delivery semantics.
- [./events.md](./events.md) — run-event catalog.

---

_End of Pulse Schema Reference._
