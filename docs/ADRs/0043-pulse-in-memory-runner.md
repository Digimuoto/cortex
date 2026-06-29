---
title: "ADR 0043 - Pulse In-Memory Runner"
description:
  "Defines a non-durable in-memory Pulse runner for local Wire execution, tests, demos, and early
  benchmarks, separate from the durable `cortex-pulse` service."
sidebar:
  label: "0043. Pulse in-memory runner"
  order: 43
status: proposed
date: 2026-05-02
superseded_by: null
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Pulse/types.md
  - docs/Reference/Pulse/events.md
  - docs/Reference/rewrites.md
  - docs/Usage/02-execution-modes.md
  - docs/Usage/08-running-durable-pulse.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0042-wire-standard-effect-executors.md
---

# ADR 0043 - Pulse In-Memory Runner

## Status

Proposed - this ADR defines a local runner mode. It does not change the durable Pulse service
contract.

## Context

Durable Pulse is the production service profile for Cortex. The production executor owns
persistence, checkpoints, leases, retries, resume, cancellation, observability, and durable rewrite
materialization.

That service boundary is necessary for long-lived workflows, but it is too heavy for every use case.
Local Wire authoring, tutorials, unit tests, benchmark baselines, and small demos need a runner that
can execute a compiled stage plan without Postgres or the observability stack.

Cortex already has reusable pieces below the durable loop:

- `StagePlan` and `StageDefinition` describe executable graph plans.
- `GraphRuntime` tracks ready nodes, node status, and completed outputs.
- Rewrite admission and materialization are factored as reusable logic.
- Memory can be disabled through a discard handle for stages that do not query it.

Those pieces make a local runner possible without inventing a second graph model. The risk is
semantic overclaim: an in-memory runner cannot honestly provide durable recovery guarantees.

## Decision

Cortex should provide an explicit in-memory Pulse runner for local execution.

The runner executes `StagePlan NodeId` values in one process and keeps graph state, outputs, and
remaining rewrite budget in memory. It is suitable for:

- `wire run` local execution;
- docs examples and tutorials;
- Postgres-free unit and integration tests;
- early benchmark baselines for pure/static Wire programs.

It is not the durable Pulse service and does not replace `cortex-pulse`.

The initial supported stage results are:

| Stage result         | In-memory behavior                                                                   |
| -------------------- | ------------------------------------------------------------------------------------ |
| `StageComplete`      | Mark the node completed and store its output.                                        |
| `StageRewrite`       | Admit and materialize the rewrite through the existing rewrite/materialization path. |
| `StageRejectRewrite` | Continue according to the local runner's explicit rejection policy.                  |
| `StageSuspend`       | Stop with a suspended outcome; do not persist a resumable signal wait.               |

The runner may execute sequentially in v1. Concurrency can be added later if it is useful for
benchmarks or parity tests, but v1 should optimize for deterministic behavior and simple
diagnostics.

The runner must report its mode clearly. A successful local run proves that the graph can execute
under the supplied bindings in this process. It does not prove that the same run has durable
checkpoints, lease recovery, signal resume, cancellation propagation, or service API visibility.

## Alternatives Considered

- **Require Postgres for every Wire run** - rejected because it blocks tutorials, smoke tests, and
  fast local examples.
- **Mock Pulse with a separate mini interpreter** - rejected because it would drift from
  `StagePlan`, `GraphRuntime`, and rewrite admission semantics. The local runner should reuse the
  substrate pieces below the durable loop.
- **Make `wire run` submit to `cortex-pulse`** - rejected for v1 because it requires registry
  binding, task-definition insertion, service lifecycle, credentials, and database setup before a
  user can run a first program.
- **Claim durable parity without persistence** - rejected because it would weaken the meaning of
  Pulse durability and confuse local execution with production execution.

## Consequences

### Positive

- Wire gets a Postgres-free run path.
- Pure/static Wire programs become benchmarkable through a small command.
- The reusable Pulse graph-runtime and rewrite materialization layers get more direct exercise.
- Docs can show a complete stdin -> pure -> stdout program without a downstream service.

### Negative

- Cortex has two execution modes that must be named carefully: local in-memory and durable service.
- Tests must avoid accidentally treating local execution as proof of durable replay behavior.
- Supporting rewrites locally still requires careful budget and materialization accounting.

### Obligations

- Make the local runner's result type distinguish completed, failed, and suspended runs.
- Do not expose local suspended runs as resumable durable state.
- Reuse existing `StagePlan`, `GraphRuntime`, and rewrite materialization code instead of defining a
  parallel graph engine.
- Document unsupported durable features: leases, checkpoint persistence, service API state,
  cross-process resume, durable signal waits, cancellation propagation, and observability events.
- Add an initial benchmark child issue after `wire run` can execute pure/static programs.

## Traceability

- Feature keys: `pulse.in_memory_runner`
- Public surface: the `wire run` command, `docs/Usage/02-execution-modes.md`,
  `docs/Usage/08-running-durable-pulse.md`, `docs/Reference/Pulse/types.md`
- Implementation: `app/wire/Main.hs` (the local in-process `wire run` smoke runner) reusing the
  substrate pieces below the durable loop — `src/Cortex/Pulse/GraphRuntime.hs` (graph state and
  ready frontiers) and `src/Cortex/Pulse/Plan.hs` (`StagePlan`)
- Tests: none
- Theory/proof: none

## Related

- [Chapter 01 - Overview](../Architecture/01-overview.md)
- [Chapter 06 - Pulse runtime](../Architecture/06-pulse-runtime.md)
- [Chapter 07 - Rewrites and materialization](../Architecture/07-rewrites-and-materialization.md)
- [Pulse types](../Reference/Pulse/types.md)
- [Pulse events](../Reference/Pulse/events.md)
- [Rewrites](../Reference/rewrites.md)
- [Execution modes](../Usage/02-execution-modes.md)
- [Running durable Pulse](../Usage/08-running-durable-pulse.md)
- [ADR 0003 - Pulse Service and Host Action Boundary](0003-pulse-service-and-host-action-boundary.md)
- [ADR 0004 - Graph-Native Pulse Execution](0004-graph-native-pulse-execution.md)
- [ADR 0035 - Wire Rewrite Algebra Forms](0035-wire-rewrite-algebra-forms.md)
- [ADR 0036 - Latent Branch Budget and Recovery Policy](0036-wire-latent-branch-budget-recovery.md)
- [ADR 0041 - Wire CLI Command Surface](0041-wire-cli-command-surface.md)
- [ADR 0042 - Wire Standard Effect Executors](0042-wire-standard-effect-executors.md)
