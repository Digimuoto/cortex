---
title: Integrating From Haskell
description: Compile Wire with strict registries and choose a managed or service Pulse runtime.
sidebar:
  label: 07. Haskell integration
  order: 7
---

# Integrating From Haskell

A Haskell consumer usually uses Cortex in two places:

1. Compile Wire source with strict contract and executor registries.
2. Run the compiled circuit through managed Pulse or a consumer-bound Pulse service.

## Compile Wire Strictly

Use `Cortex.Wire` to compile source text or parsed files:

```haskell
import Data.Text (Text)

import Cortex.Wire

compileWorkflow
  :: WireExecutorRegistry
  -> WireContractRegistry
  -> Text
  -> Either WireError CompiledCircuit
compileWorkflow executorRegistry contractRegistry =
  compileWireTextWithEnv (strictWireCompileEnv executorRegistry contractRegistry)
```

The important production choice is the `WireCompileEnv`. It is where the host decides which
contracts and executor names are valid. `emptyWireCompileEnv` is useful for loose examples; a
consumer should normally use strict registries.

## Choose The Runtime Shape

| Shape               | API surface                                                    | Use it when...                                                                                                    |
| ------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Local CLI           | `wire run`                                                     | You are testing standard local examples outside the consumer app.                                                 |
| Managed durable run | `runCompiledCircuitManaged` and `resumeCompiledCircuitManaged` | The consumer wants durable run/resume without a scheduler service loop.                                           |
| Durable service     | `Cortex.Pulse.runPulse`                                        | Operators need a long-lived worker with scheduler polling, registry-owned task execution, and service visibility. |

The managed facade creates a scheduler-inert task definition and one durable run, returns the run
id, renews the lease while it executes, and lets the caller resume by run id after a crash. The
caller still owns schema provisioning, pool reuse choices, binder compatibility, and retention of
durable rows.

Use the `...ManagedOn` variants when the consumer already owns a PostgreSQL pool and wants to
amortize pool setup across runs. Use the non-`On` variants when the consumer wants Cortex to open a
pool from `PulseConfig` for one call. Both paths run the same stage plan and return
`Either CircuitRunError (UUID, RunOutcome)` for fresh runs; resume variants take the prior run id.

Managed resume claims the run before executing it. A pending run or a running run with an expired
lease can be resumed by the caller. A live running run is rejected to avoid split-brain execution,
waiting and other non-claimable non-terminal runs are reported as not resumable, and terminal runs
return their stored outcome without re-driving the plan.

The main error classes are:

- `CircuitRunLoweringError` — the compiled circuit cannot lower to a runnable Pulse stage plan.
- `CircuitRunUnsupportedLatentConditions` — the managed entrypoint cannot run unresolved latent
  conditions.
- `CircuitRunPoolError` / `CircuitRunSchemaMissing` — pool setup or schema validation failed before
  execution.
- `CircuitRunSetupError` / `CircuitRunTaskClaimConflict` — task definition, task load, or run-claim
  setup failed.
- `CircuitRunResumeRejected` — the target run exists but is not currently resumable by this caller.
- `CircuitRunExecutionError` — execution raised an exception after setup.

## Provision The Schema

For a new consumer-owned database, call `Cortex.Pulse.Database.provisionPulseSchema` before managed
or service execution. It creates the current schema when `pulse` is absent and validates required
current objects when the schema already exists.

For an already-deployed database, apply forward migrations from `migrations/` before rolling out
code that depends on new schema shape. `provisionPulseSchema` validates; it is not a general
migration runner.

Ephemeral test databases should use the same provisioning path. That keeps local tests aligned with
fresh downstream setup instead of relying on hand-written table fragments.

## Boundary Rule

Cortex should stay provider-neutral. Put model clients, product tools, document renderers, and
domain policy in the consumer library. Register only the executor authority Cortex needs to compile
and run the graph.

## Related

- [Execution modes](02-execution-modes.md)
- [Running durable Pulse](08-running-durable-pulse.md)
- [Pulse schema](../Reference/Pulse/schema.md)
- [Pulse signals](../Reference/Pulse/signals.md)
- [Consumers](../Consumers/)
