---
title: "Portman × Pulse — Host Actions and Task Types"
description: "How Portman binds to Pulse: the inbound host-action contract, Portman-specific task types, and Portman's operator surface on top of Pulse."
sidebar:
  label: "Pulse host actions"
  order: 4
---

# Portman × Pulse — Host Actions and Task Types

Portman is the reference Pulse consumer. This page documents how Portman binds to the generic Pulse runtime: the inbound host-action contract Pulse calls for domain work, the Portman-specific task types Pulse executes, and Portman's operator surface that proxies into Pulse.

Generic Pulse behavior (schema, service API, runtime model) lives in [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) and [../../Reference/Pulse/](../../Reference/Pulse/). Everything below is Portman-specific.

## Host-action API (Pulse → Portman)

Pulse calls Portman for every domain operation via HTTP/JSON. These are internal endpoints, never exposed to end users.

| Endpoint                                                  | Description                                                                          |
|-----------------------------------------------------------|--------------------------------------------------------------------------------------|
| `POST /internal/v1/Pulse/resolve-strategy`                | Load strategy folder, resolve entities, compute hash, validate floors. Returns full snapshot. |
| `POST /internal/v1/Pulse/load-portfolio-snapshot`         | Load current positions, NAV, cash, market status for a portfolio.                    |
| `POST /internal/v1/Pulse/evaluate-guardrails`             | Run guardrail policy against a proposal. Returns structured per-rule results.        |
| `POST /internal/v1/Pulse/validate-execution-preflight`    | Cash/position/lot-size dry-run validation.                                           |
| `POST /internal/v1/Pulse/persist-cycle-record`            | Write structured cycle record to `paper_portfolio_cycle_runs`.                       |
| `POST /internal/v1/Pulse/execute-paper-trade`             | Mutate paper-portfolio positions and cash balances.                                  |
| `POST /internal/v1/Pulse/render-workspace-report`         | Generate the workspace markdown from the canonical JSONB artifact.                   |

### Authentication

Every request carries the shared service credential (`X-Pulse-Credential`). Portman validates it with constant-time comparison and fails closed when unconfigured.

### Idempotency

Every mutating request carries the Pulse idempotency key:

```
X-Idempotency-Key: <pulse_run_id>/<stage_name>/<action_name>
```

Portman implements exactly-once semantics: a duplicate key returns the original response without re-executing. This is the defense against double-writes on retries and lease recovery.

### Cortex-internal actions

Model calls and tool invocations stay inside Cortex and do not route through Portman:

| Action       | Owner   | Protocol                                 |
|--------------|---------|------------------------------------------|
| `callModel`  | Cortex  | Direct (provider-neutral LLM interface). |
| `callTool`   | Cortex  | Direct (gatherer tool dispatch).         |

## Portman-specific error categories

In addition to the generic categories in the [Pulse error taxonomy](../../Reference/Pulse/service-api.md#6-error-taxonomy):

| Category               | Retryable | Description                          |
|------------------------|-----------|--------------------------------------|
| `guardrail_violation`  | no        | Proposal violates Portman guardrails.|

## Portman task types

### PaperPortfolioCycle

The first product-facing durable task. Config is thin:

```haskell
data PaperPortfolioCycleConfig = PaperPortfolioCycleConfig
  { strategyId :: UUID
  }
```

12-stage linear pipeline exercising the full host-action contract. `executionMode` is resolved from the strategy, not carried in the envelope. The stage sequence:

```haskell
data PaperPortfolioCycleStage
  = StrategyResolution
  | PreflightSnapshot
  | Planner
  | Gatherer
  | RequiredEvidenceRepair
  | Analyst
  | Reviewer
  | Guardrails
  | ExecutionPreflight
  | PersistDecision
  | FinalizeReport
  | PaperExecute
  | ShadowComplete
  deriving (Eq, Show, Bounded, Enum)
```

Conditional stages (e.g. `RequiredEvidenceRepair` when evidence is complete) are represented as explicit `Skipped` outcomes in the stage log.

`Irreversible` stages (`PersistDecision`, `PaperExecute`) trigger a warning event if a prior stage-log entry is detected on resume, since the side effect may have partially completed.

Detailed design: [Durable Portfolio Agent MVP](../../../Architecture/durable-portfolio-agent-mvp.md).

### ResponseEvalRun

Runtime-proving task. Exercises the full Pulse lifecycle without portfolio mutations: checkpoint writes, cancellation, timeouts, partial persistence, typed error taxonomy. Detailed design: [ResponseEvalRun on Pulse](./response-eval-run.md).

## Portman operator surface

Portman wraps Pulse with its own admin API and CLI. These forward into Pulse's service API — Portman never transitions Pulse run state directly.

### Admin endpoints

- `GET  /admin/v1/agent-tasks`
- `POST /admin/v1/agent-tasks`
- `POST /admin/v1/agent-tasks/:taskId/trigger`
- `GET  /admin/v1/agent-tasks/:taskId/runs`
- `GET  /admin/v1/agent-task-runs/:runId`
- `POST /admin/v1/agent-task-runs/:runId/cancel`
- `POST /admin/v1/agent-task-runs/:runId/retry`
- `POST /admin/v1/agent-task-runs/:runId/signal`

### CLI commands

- `portman admin agent-tasks list`
- `portman admin agent-tasks create`
- `portman admin agent-tasks trigger <task-id>`
- `portman admin agent-tasks runs <task-id>`
- `portman admin agent-task-runs show <run-id>`
- `portman admin agent-task-runs cancel <run-id>`
- `portman admin agent-task-runs retry <run-id>`
- `portman admin agent-task-runs signal <run-id> <signal-name> [--payload <json>]`

### Current constraints

- Admin task creation is limited to `ResponseEvalRun`.
- `retry` creates a fresh Pulse run linked by `parent_run_id`; it is not checkpoint resume.
- Pending cancellation is finalized immediately as `cancelled`.
- Task-specific portfolio `cycle-history` remains follow-up work.

### System status integration

Portman's `GET /admin/v1/system/status` includes Pulse health by calling `GET /Pulse/v1/health`. It never reads Pulse tables or logs.

## Related

- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — generic Pulse runtime.
- [../../Reference/Pulse/](../../Reference/Pulse/) — Pulse schema, types, and service API.
- [./response-eval-run.md](./response-eval-run.md) — ResponseEvalRun detailed design.
- [../../../Architecture/durable-portfolio-agent-mvp.md](../../../Architecture/durable-portfolio-agent-mvp.md) — Portman MVP spec: strategy, guardrails, shadow mode, admin API.
- [../../../Architecture/observability-and-error-handling.md](../../../Architecture/observability-and-error-handling.md) — Portman observability.
