---
title: Deploying Pulse
description: Production checklist for a consumer-bound Pulse runtime.
sidebar:
  label: 09. Deploying Pulse
  order: 9
---

# Deploying Pulse

Production Pulse deployments are consumer-bound. Cortex supplies the runtime library and substrate
shell; your application supplies the registry, secrets, host API, persistence policy, and operator
environment.

## Deployment Checklist

1. Build a consumer binary that imports Cortex and passes a populated task registry to
   `Cortex.Pulse.runPulse`.
2. Provision Postgres and apply or validate the Cortex schema expected by the running version. New
   consumer-owned databases may use `Cortex.Pulse.Database.provisionPulseSchema`; deployed databases
   still need the forward migrations listed in [Pulse schema](../Reference/Pulse/schema.md).
3. Mount secret files for JWT signing and service credentials.
4. Set a stable `--lease-owner` for each logical runtime instance.
5. Configure concurrency:
   - `--max-concurrent-tasks`
   - `--max-frontier-concurrency`
   - repeated `--task-type-max-concurrent TYPE=N`
6. Expose the health endpoint.
7. Connect logs, metrics, and traces according to the platform runtime environment.
8. Decide how task definitions and compiled circuits enter the database.
9. Define retention for task definitions, runs, graph state, stage logs, and events.

Rule of thumb: `--max-concurrent-tasks` caps the whole worker, `--max-frontier-concurrency` caps one
run's active frontier, and `--task-type-max-concurrent` is a repeatable per-task-type override.

## Runtime Shape

```text
consumer binary
  imports Cortex.Pulse
  provides task registry
  reads PulseConfig
  starts runPulse

Postgres
  stores task definitions, runs, graph state, checkpoints, signals, and events

host API
  owns side effects and product policy
```

## Operational Notes

- Keep `lease-owner` stable across restarts of the same logical worker so startup recovery can
  reclaim owned runs.
- Use distinct lease owners for independent workers.
- Treat a lease-owner mismatch as a hard ownership conflict; Pulse will not renew another worker's
  run.
- Keep host actions idempotent where Pulse may retry or resume work.
- Treat the database as the durable source of runtime truth.
- Keep schema deployment and application rollout in the same release plan.

## Related

- [Running durable Pulse](08-running-durable-pulse.md)
- [Operating Pulse](10-operating-pulse.md)
- [Pulse schema](../Reference/Pulse/schema.md)
- [Host actions](../Reference/Pulse/host-actions.md)
