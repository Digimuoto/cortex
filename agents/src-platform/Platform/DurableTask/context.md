# Platform DurableTask Context

The `src-platform/Platform/DurableTask/` directory contains shared durable-task infrastructure that
is generic enough to sit below Pulse and future runtime adapters.

Current contents:

- `Cron.hs` for shared cron parsing and next-fire-time calculation.
- `Types.hs` for shared run status, trigger source, and schedule-facing run outcome types.
- `Schedule.hs` for pure schedule-finalization decisions.
- `Pool.hs` for bounded concurrent task execution pools.
- `Polling.hs` for jittered polling utilities.
- `Checkpoint.hs` for versioned checkpoint envelopes.
- `Error.hs` for best-effort DB failure logging combinators.
- `Workflow.hs` for generic plan/execute/persist worker loop skeleton.

This directory holds stable shared durable-task contracts used by Pulse and generic runtime
infrastructure.

## Boundary Rules

- Code here must remain runtime-generic.
- Do not import downstream product modules.
- Do not hardcode Pulse-specific table shapes, task names, or checkpoint formats.
- If logic needs concrete task registration, run state machines, or domain task implementations, it
  belongs above this layer.

## Cron Rules

- Keep cron parsing deterministic and side-effect free.
- Preserve the existing five-field cron semantics unless there is an explicit migration plan.
- Treat parser behavior as operator-visible infrastructure. Avoid accidental semantic drift.

## Type And Schedule Rules

- `RunStatus` is the persisted runtime-status space shared across runtimes.
- `RunOutcome` is the scheduler-facing abstraction; it is allowed to be lossy relative to persisted
  statuses.
- `OutcomeShutdown` is a sentinel used by Pulse drain/shutdown paths and must map to "do not
  finalize schedule state".
- `Schedule` stays pure. Cron advancement, backoff timestamps, and "record outcome only" are decided
  here; database writes stay in adapters.
- Scheduled recurring work always advances to the next cron fire time, regardless of
  success/failure/cancel/timeout.
- Manual or retry-triggered recurring work records outcome only and does not advance cron.

## Runtime Model Principles

- A run is the unit of durable execution identity. Checkpoints belong to a run.
- Resume means same-run continuation after crash or lease loss, automatic via scheduler reclaim.
- Retry means a fresh new run, linked to its parent for audit.
- Any future checkpoint-based restart is a distinct Tier 2 operation, not retry.
- Host-action calls with side effects must use idempotency keys to prevent double writes on resume
  or retry. The concrete idempotency layer belongs above this directory.

## Future Work Boundary

These do not belong in this directory yet unless the follow-up issue explicitly moves them:

- shared task registry abstractions
- domain task implementations

## Anti-Patterns

- Treating this directory as a dumping ground for random helpers.
- Hiding domain behavior behind generic-sounding durable-task utilities.
- Changing shared cron, status, or schedule semantics without focused regression coverage.
