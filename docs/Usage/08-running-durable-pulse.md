---
title: Running Durable Pulse
description: Start the Postgres-backed Pulse path and understand the runtime inputs.
sidebar:
  label: 08. Durable Pulse
  order: 8
---

# Running Durable Pulse

Pulse is the durable runtime for compiled circuits. It stores task definitions, runs, graph state,
stage state, events, checkpoints, signals, and recovery metadata in Postgres.

This page is the durable, Postgres-backed path. To run a small `.wire` program once with no
persistence, resume, or signals, use [First local Wire run](03-first-local-wire-run.md) instead.

## Runtime Inputs

A Pulse process needs:

| Input               | CLI or source                                                            | Purpose                                                      |
| ------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------ |
| Postgres connection | `--db-host`, `--db-port`, `--db-user`, `--db-name`, `--db-password-file` | Stores durable runtime state.                                |
| Lease owner         | `--lease-owner`                                                          | Identifies the logical Pulse instance that owns active work. |
| JWT signing secret  | `--jwt-secret-file`                                                      | Mints runner tokens for host calls.                          |
| Service credential  | `--service-credential-file`                                              | Authenticates internal Pulse-to-host actions.                |
| Task registry       | Haskell value passed to `runPulse`                                       | Maps task kinds to Haskell executors.                        |
| Host API URL        | `--api-url`                                                              | Endpoint Pulse calls for host-owned side effects.            |
| Workflow directory  | `--workflow-dir`                                                         | Optional directory of hot-loadable compiled workflows.       |

The stock `cortex-pulse` binary supplies an empty task registry. Use it to inspect runtime
configuration and health wiring; use a consumer-bound binary for real task execution.

## Provisioning And Migration

Fresh deployments should provision the `pulse` schema through
`Cortex.Pulse.Database.provisionPulseSchema`. That call creates the schema from the checked-in
`data/pulse-schema.sql` dump when absent and validates the current shape when present.

Existing deployments must apply forward, idempotent files from `migrations/` before deploying code
that depends on the new shape. Pulse does not ship an in-process migration runner; operators or
deployment tooling own migration execution.

## Managed Runs Versus Service Runs

The durable service loop claims scheduled task definitions and runs them with lease renewal,
recovery, and backpressure visibility. Haskell consumers that do not want a scheduler service can
use the managed compiled-circuit facade instead. The managed facade creates one scheduler-inert task
definition and run, executes it under lease renewal, and exposes resume-by-run-id for crash
recovery.

Both modes use the same Pulse tables, graph-state CAS discipline, signal protocol, and event
catalog. The difference is ownership of scheduling: the service owns polling and task discovery; the
managed facade is caller-driven.

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

For useful task execution, replace this shell with a binary that calls `Cortex.Pulse.runPulse` with
a non-empty registry.

## What Pulse Records

A durable run leaves behind:

- current graph state
- stage attempts
- checkpoint envelopes
- run events
- signal waits and deliveries
- final outcome

Use [Pulse schema](../Reference/Pulse/schema.md), [events](../Reference/Pulse/events.md), and
[signals](../Reference/Pulse/signals.md) for exact storage and event semantics.

## Operational Boundaries

- Only Pulse writes run status, graph state, signal rows, stage attempts, and events in the `pulse`
  schema.
- Durable graph-state writes cross the CAS-protected graph-state write seam.
- Run-terminal signal delivery and terminal status writers use the governed run-terminal protocol
  writer set.
- Reserved signal families such as `run-terminal:` and `external-call:` are runtime-owned and are
  not delivered through the public signal endpoint.

## Related

- [Execution modes](02-execution-modes.md)
- [Deploying Pulse](09-deploying-pulse.md)
- [Operating Pulse](10-operating-pulse.md)
- [Pulse reference](../Reference/Pulse/)
