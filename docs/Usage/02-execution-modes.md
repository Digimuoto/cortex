---
title: Execution Modes
description: Choose between local Wire execution, the managed Pulse facade, and durable Pulse.
sidebar:
  label: 02. Execution modes
  order: 2
---

# Execution Modes

Cortex has one authoring path and several execution profiles. The same `.wire` source compiles into
a circuit; the mode you choose decides where that circuit runs and whether any state survives the
process.

## Mode Matrix

| Mode                  | Entry point                                                        | Postgres | Durable state | Use it for                                                                             |
| --------------------- | ------------------------------------------------------------------ | -------- | ------------- | -------------------------------------------------------------------------------------- |
| Local `wire run`      | `nix run .#wire -- run FILE`                                       | No       | No            | First runs, smoke examples, local exploration.                                         |
| Managed Pulse facade  | `runCompiledCircuitManaged` from Haskell                           | Yes      | Yes           | Consumer libraries that want durable run/resume without running the scheduler service. |
| Durable Pulse service | `Cortex.Pulse.runPulse` or `cortex-pulse` with a consumer registry | Yes      | Yes           | Long-lived service runs, operators, signals, leases, recovery, and service visibility. |

`wire run` is shipped today as a local, in-process runner for CorePure nodes and standard `std.io`
effect leaves. It implements the first CLI surface described by
[ADR 0043](../ADRs/0043-pulse-in-memory-runner.md), while that ADR remains proposed for the broader
in-memory Pulse runner contract. It does not write checkpoints, expose resumable run state, wait on
durable signals, or take leases.

Durable Pulse is the Postgres-backed runtime profile. It records task definitions, run state, graph
state, stage attempts, events, signal waits, and final outcomes. Use it when a run must be
inspected, resumed, coordinated across workers, or operated after the process that started it exits.

## Decision Points

| If you need...                                                                   | Use...                                          |
| -------------------------------------------------------------------------------- | ----------------------------------------------- |
| A first runnable example without services                                        | Local `wire run`.                               |
| A local example that prints, reads stdin, runs a command, or reads/writes a file | Local `wire run` with standard `std.io` leaves. |
| Configured consumer executors, provider credentials, or product policy           | A consumer runtime.                             |
| Persistence, resume, signals, leases, retries, events, or operator-visible state | Durable Pulse.                                  |
| Haskell embedding without a scheduler process                                    | The managed Pulse facade.                       |
| A standalone service loop with a task registry                                   | `Cortex.Pulse.runPulse` in a consumer binary.   |

## Boundaries

Local `wire run` recognizes the standard IO executors listed in
[Executors and alphabet](../Reference/Wire/executors-and-alphabet.md). It rejects configured
executors and generated durable-only nodes instead of pretending to run them.

The stock `cortex-pulse` binary is useful for checking runtime wiring, health behavior, and CLI
configuration, but it has an empty task registry. A useful durable deployment normally links Cortex
from a consumer repo and passes a populated registry to `Cortex.Pulse.runPulse`.

## Related

- [First local Wire run](03-first-local-wire-run.md)
- [Running durable Pulse](08-running-durable-pulse.md)
- [Integrating from Haskell](07-integrating-from-haskell.md)
- [Pulse reference](../Reference/Pulse/)
