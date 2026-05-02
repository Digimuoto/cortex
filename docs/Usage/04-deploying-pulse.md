---
title: Deploying Pulse
description: First-pass deployment checklist for a consumer-bound Pulse runtime.
sidebar:
  label: 04. Deploying Pulse
  order: 4
---

# Deploying Pulse

Production Pulse deployments are consumer-bound. Cortex supplies the runtime library and substrate
shell; your application supplies the registry, secrets, host API, and operational policy.

## Deployment Checklist

1. Build a consumer binary that imports Cortex and passes a populated task registry to
   `Cortex.Pulse.runPulse`.
2. Provision Postgres and apply the Cortex schema expected by the running version. See
   [Pulse schema](../Reference/Pulse/schema.md).
3. Mount secret files for JWT signing and service credentials.
4. Set a stable `--lease-owner` for each logical runtime instance.
5. Configure concurrency:
   - `--max-concurrent-tasks`
   - `--max-frontier-concurrency`
   - repeated `--task-type-max-concurrent TYPE=N`
6. Expose the health endpoint.
7. Connect observability according to the platform runtime environment.
8. Decide how task definitions and compiled circuits enter the database.

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
  stores task definitions, runs, checkpoints, signals, and events

host API
  owns side effects and product policy
```

## Operational Notes

- Keep `lease-owner` stable across restarts of the same logical worker so startup recovery can
  reclaim owned runs.
- Use distinct lease owners for independent workers.
- Keep host actions idempotent where Pulse may retry or resume work.
- Treat the database as the durable source of runtime truth.

The detailed runtime contract lives in [Pulse reference](../Reference/Pulse/).
