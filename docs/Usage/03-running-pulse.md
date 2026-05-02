---
title: Running Pulse
description:
  Runtime inputs, database expectations, and what the stock Pulse shell can and cannot run.
sidebar:
  label: 03. Running Pulse
  order: 3
---

# Running Pulse

Pulse is the durable runtime for compiled circuits. It stores task definitions, runs, stage state,
events, checkpoints, signals, and recovery metadata in Postgres.

## Runtime Inputs

A Pulse process needs:

| Input                       | CLI or source                                                            | Purpose                                                                |
| --------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| Postgres connection         | `--db-host`, `--db-port`, `--db-user`, `--db-name`, `--db-password-file` | Stores task definitions, runs, checkpoints, signals, and event logs.   |
| Lease owner                 | `--lease-owner`                                                          | Identifies the logical Pulse instance that owns active work.           |
| JWT signing secret          | `--jwt-secret-file`                                                      | Mints runner tokens for host calls.                                    |
| Service credential          | `--service-credential-file`                                              | Authenticates internal Pulse-to-host actions.                          |
| Task registry               | Haskell value passed to `runPulse`                                       | Maps task kinds to Haskell executors.                                  |
| Host API URL                | `--api-url`                                                              | Endpoint Pulse calls when a task runner needs host-owned side effects. |
| Hot-loadable workflow input | `--workflow-dir`                                                         | Optional directory containing hot-loadable `.cr` workflows.            |

The stock `cortex-pulse` binary supplies an empty task registry. Use it to inspect runtime
configuration and health wiring; use a consumer-bound binary for real task execution.

## Start The Shell

The executable requires a JWT secret file. Database password and service credential files are
optional at the CLI level, but real deployments should provide them through files or equivalent
secret mounts.

```bash
printf 'dev-jwt-secret' > /tmp/cortex-jwt-secret

nix run .#cortex-pulse -- \
  --db-host localhost \
  --db-port 5432 \
  --db-user cortex \
  --db-name cortex \
  --jwt-secret-file /tmp/cortex-jwt-secret \
  --health-port 9090
```

For a useful run, replace this shell with a binary that calls `Cortex.Pulse.runPulse` with a
non-empty registry.

## What Pulse Records

Pulse is intentionally observable. A run leaves behind:

- current graph state
- stage attempts
- checkpoint envelopes
- run events
- signal waits and deliveries
- final outcome

Use [Pulse schema](../Reference/Pulse/schema.md), [events](../Reference/Pulse/events.md), and
[signals](../Reference/Pulse/signals.md) for exact storage and event semantics.
