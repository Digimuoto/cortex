---
title: "ADR 0065 - Pulse Concurrent Frontier Execution and Cooperative Cancellation"
description:
  "The durable Pulse executor runs the ready frontier through a semaphore-bounded async worker pool;
  the first terminal node outcome cooperatively cancels in-flight siblings, every worker reifies its
  exception into a node result, and completed facts persist incrementally via the graph-state CAS."
sidebar:
  label: "0065. Frontier concurrency"
  order: 65
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/events.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0043-pulse-in-memory-runner.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0065 - Pulse Concurrent Frontier Execution and Cooperative Cancellation

## Status

Proposed. The concurrent frontier is implemented in `Executor/Frontier.hs` and selected by
`Executor/Loop.hs`, and is exercised by the `concurrent frontier execution`,
`concurrent frontier stress tests`, and `frontier regression tests` suites in `ExecutorSpec.hs`.
This ADR records the contract that code already follows; it does not propose a new mechanism.

## Context

ADR 0004 made graph topology the runtime model and named "frontier concurrency" as a natural
consequence — fan-out and joins are first-class, and ready work is the set of nodes whose
predecessors are satisfied. But 0004 records only the _semantics_ (partial-order scheduling over
frontiers of ready nodes); it does not record _how_ a wave of ready nodes actually executes. ADR
0043 deliberately leaves its in-memory runner sequential ("the runner may execute sequentially in
v1"). ADR 0058 governs a different seam — the atomic suspend-settlement transaction — and explicitly
moved registration _out_ of the frontier. So the durable executor's concurrent-frontier contract is
unrecorded canon: how many nodes run at once, how the wave is bounded, what happens to siblings when
one node reaches a terminal outcome, how a worker exception becomes a graph fact, and how completed
nodes reach durable state before the wave drains.

That contract is load-bearing because each open question has a wrong answer that corrupts the graph:

- An unbounded wave spawns one connection-holding worker per ready node, removing all backpressure
  against the database pool and the host.
- An async exception that escapes its worker leaves the failing node stranded in `NodeRunning`,
  which `classifyGraphState` then reads as "still progressing," so the run neither fails nor
  settles.
- If the first failing node does not stop its siblings, the run spends semaphore tokens and DB
  writes driving doomed work to completion.
- If completed nodes are not persisted until the whole wave finishes, a crash mid-wave loses every
  finished-but-unpersisted result.

The code already answers all four through a semaphore-bounded async pool, two run-scoped
cancellation flags, exception reification, and incremental persistence. This ADR fixes that answer
as the contract so future runtime features extend one seam.

## Decision

The durable Pulse executor runs the ready frontier **concurrently through a bounded pool of async
workers — one worker per ready node — and cancels the rest of the wave cooperatively on the first
terminal node outcome.**

`Executor/Loop.hs` dispatches to `runFrontierConcurrent` only when `seMaxFrontierConcurrency > 1`
**and** the ready frontier has more than one node; otherwise `runFrontierSequential` runs. Both
share one `NodeResult`/graph-state model, so the sequential path is the degenerate case (consistent
with 0004 keeping linear execution as the degenerate path), not a second engine.

`runFrontierConcurrent` snapshots each ready node's inputs from graph state **before** any worker
starts, marks the pending nodes `NodeRunning` (persisted via the graph-state CAS), then spawns one
`Async` worker per node. A single `QSem` of capacity `max 1 seMaxFrontierConcurrency` gates worker
entry, so at most the configured number of nodes execute at once. A worker:

1. takes a semaphore token (`bracket_ (waitQSem sem) (signalQSem sem)`);
2. if the start gate is already closed, returns `OutcomeNodeCancelled` without running;
3. otherwise runs its stage against its immutable input snapshot and returns a `NodeResult` —
   **never an exception**: the worker body runs under `mask`/`try`, and any caught exception is
   mapped to a node result (`workerExceptionResult`).

The first node outcome that is terminal — failed, timed out, shutdown, or run-cancelled — sets two
run-scoped `TVar Bool` flags: the **start gate** (queued workers that have not yet started observe
it on acquiring the semaphore and return `OutcomeNodeCancelled`) and the **cancel-running** flag (a
monitor async blocks on it and then `cancel`s every in-flight worker). Sibling cancellation lands in
graph state as `NodeInterrupted InterruptedSiblingCancelled`. A node that merely **suspends** or
**succeeds** does not trigger cancellation.

As each worker completes, the collector folds its `NodeResult` into the shared graph state
(`applyNodeFact`) and persists incrementally through the graph-state CAS (`persistGraphState`) —
governed separately as `pulse.graph_state_cas` — so finished nodes are durable before the wave
drains. After the wave drains, `classifyFrontierOutcome` decides the run outcome.

## Mental Model

> One frontier wave is a bounded pool of async workers, one per ready node. Each worker takes a
> semaphore token, runs its stage against an immutable input snapshot, and returns a `NodeResult` —
> never an exception. The first terminal result closes the start gate (so queued workers never
> start) and signals a monitor to cancel the in-flight siblings. Completed facts fold into shared
> graph state and persist (CAS) as they arrive; classifying the drained wave decides the run
> outcome.

## Boundary Rules

- **Bounded by `pulseMaxFrontierConcurrency`.** The cap is `max 1 seMaxFrontierConcurrency`; one
  `QSem cap` gates worker entry. `Executor/Loop.hs` selects the concurrent path only when the cap is
  `> 1` and the ready frontier has more than one node. The sequential frontier handles every other
  case with the same result model.
- **Workers are isolated from shared state.** Each worker receives a pre-computed immutable input
  map snapshotted from graph state before any worker starts, and never reads the live graph-state
  `TVar`. Its durable writes are its own stage audit log, signal registration, and stage result — no
  worker writes another node's fact.
- **Exceptions become node results, never escapes.** The worker body runs under
  `mask $ \restore -> (try . restore) (...)` so the `try` is installed before cancellation can land.
  A caught exception maps via `workerExceptionResult`: a cancellation exception (`ThreadKilled`,
  `UserInterrupt`, `AsyncCancelled` — `isWorkerCancellation`) becomes `OutcomeNodeCancelled`; any
  other exception becomes `OutcomeNodeFailed` with error type `worker_exception` (retryable). A
  residual escape is caught again by `waitAnyCatch` in the collector and reified there (recording a
  `stage.worker_exception_reified` run event, or `stage.worker_exception_unattributed` if no handle
  matches), so the wave never leaves a node in `NodeRunning`.
- **First terminal outcome cancels siblings cooperatively.** `markTerminalOutcome` flips both the
  start-gate and cancel-running flags for `OutcomeNodeFailed`, `OutcomeNodeTimedOut`,
  `OutcomeNodeShutdown`, and `OutcomeNodeRunCancelled`. Closing the start gate stops not-yet-started
  queued workers; the monitor async cancels in-flight workers. Cancellation is **cooperative**: a
  worker inside a blocking stage action is interrupted only at the next safe point, not preempted
  mid-transaction. `OutcomeSuspendedOn`, `OutcomeSucceeded`, `OutcomeSkipped`, and
  `OutcomeNodeCancelled` itself do not trigger cancellation.
- **Pre-attempt gate before any worker spawns.** `withPreAttemptGuards "frontier"` runs once before
  spawning. If it returns `StageTerminal` (e.g. cancellation requested, or shutdown), the wave marks
  every pending node `OutcomeNodeCancelled`, persists that, and returns the terminal outcome with no
  worker launched.
- **Incremental CAS persistence; a persist failure ends the wave.** Each completed `NodeResult` is
  folded into graph state and persisted via the graph-state CAS as it arrives. If a persist fails,
  the collector records the error, closes both flags (cancelling the remainder of the wave), and the
  run fails through `handleGraphStatePersistError` — it does not continue on stale state.
- **Outcome selection after drain.** `classifyFrontierOutcome` prefers, in order: the first
  run-terminal node outcome (timeout / shutdown / run-cancelled, via `runTerminal`); then a
  topology-classified `Settled OutcomeFailed`; then admitted rewrites (ordered by id); otherwise the
  `classifyGraphState` verdict (`Progressing` → re-loop, `Suspended` → `OutcomeSuspended`, `Stuck` →
  re-loop). A bare `OutcomeNodeFailed` is **not** itself run-terminal — it cancels siblings, but the
  run fails only when classification settles failure over the topology.

## Alternatives considered

- **Sequential-only frontier (the 0043 in-memory runner's choice).** Rejected for the durable
  executor: independent fan-out nodes would serialize, paying the sum of node latencies on topology
  that 0004 makes first-class as parallel. The sequential path is retained only as the degenerate
  single-node / cap-1 case so there is one result model, not two engines.
- **Propagate worker exceptions to the run loop.** Rejected: an escaped async exception leaves the
  failing node `NodeRunning`, which classification reads as "still progressing," so the run hangs
  between failed and settled. Reifying every worker exit into a `NodeResult` keeps graph state total
  and replayable; the collector's `waitAnyCatch` reification is the backstop.
- **Let all siblings finish after the first terminal outcome.** Rejected: once a node has reached a
  run-terminal outcome the run will end, so spending semaphore tokens and DB writes on doomed
  siblings is waste. Cooperative cancellation reclaims them while staying safe — workers are cut at
  a safe point, never preempted mid-transaction.
- **Unbounded concurrency (spawn every ready node freely).** Rejected: it removes backpressure
  against the connection pool and the host. The `QSem` keeps a wide fan-out within the configured
  `pulseMaxFrontierConcurrency` budget while still overlapping work.

## Consequences

### Positive

- Independent frontier nodes execute in parallel within a configured bound, so a fan-out wave costs
  roughly the slowest node, not the sum of its nodes.
- The graph never strands a node in `NodeRunning`: every worker exit — success, failure, suspend,
  cancel, or escaped exception — ends in a recorded `NodeResult` and a persisted fact.
- Doomed waves stop early: the first terminal outcome closes the start gate and cancels in-flight
  siblings instead of running them to waste.
- One execution model. Concurrent and sequential frontiers share `NodeResult`, `applyNodeFact`, and
  `classifyGraphState`, so resume and recovery reason over the same graph state regardless of which
  path ran.

### Negative

- Concurrency is cooperative, not preemptive: a worker deep in a blocking stage action is cancelled
  only at its next safe point, so a terminal sibling does not instantly free a stuck worker.
- A wide wave holds several database connections at once (up to the cap), raising pool pressure
  relative to sequential execution.
- Outcome selection has multiple precedence tiers (run-terminal node outcome → settled failure →
  rewrites → classification); the ordering is load-bearing and must stay in step with
  `classifyGraphState`.
- Which sibling's terminal outcome is observed first is timing-dependent; the run end is stable
  across interleavings only because all run-terminal outcomes of a wave drive the same outcome.

### Obligations

- Keep every worker exit reified as a `NodeResult`; never let an async exception escape
  `spawnNodeWorker` un-reified. The collector's `waitAnyCatch` reification stays as the backstop and
  must keep recording `stage.worker_exception_reified`.
- Keep the cancellation flags exhaustive: any new terminal node-outcome class must be added to
  `markTerminalOutcome`, or it will neither stop queued workers nor cancel siblings.
- Persist each completed fact via the graph-state CAS before the wave drains; on a persist failure,
  close the wave and fail the run rather than continuing on stale state.
- Keep the concurrent and sequential frontiers behaviourally equivalent on the single-node / cap-1
  case; the `seMaxFrontierConcurrency > 1 && length readyNodeIds > 1` dispatch in `Executor/Loop.hs`
  is the only switch between them.
- Emit `EvtFrontierStart` / `EvtFrontierComplete` (`pulse.executor.frontier.concurrent.start` /
  `…complete`) so operators can see wave size, cap, duration, and whether the wave was terminal.
- Tests (`test/Cortex/Pulse/ExecutorSpec.hs`, against `just test-db`): a concurrent diamond runs its
  siblings in parallel; the first failure cancels in-flight siblings; the semaphore cap is
  respected; queued workers are blocked after a terminal sibling finishes; suspension on one node
  does not cancel concurrent siblings; the pre-check cancels before spawning any worker; completed
  nodes are persisted before the frontier drains.

## Traceability

- Feature keys: `pulse.frontier_concurrency`
- Public surface: `Cortex.Pulse`, `docs/Architecture/06-pulse-runtime.md`
- Implementation: `src/Cortex/Pulse/Executor/Frontier.hs`, `src/Cortex/Pulse/Executor/Loop.hs`,
  `src/Cortex/Pulse/Executor/Types.hs`
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`
- Theory/proof: none

## Related

- [ADR 0004 - Graph-Native Pulse Execution](0004-graph-native-pulse-execution.md) — names frontier
  concurrency as a consequence of graph-native scheduling; this ADR records its execution contract.
- [ADR 0043 - Pulse In-Memory Runner](0043-pulse-in-memory-runner.md) — the local runner that stays
  sequential; this contract is durable-executor-only.
- [ADR 0058 - Pulse Atomic Suspend Settlement](0058-pulse-atomic-suspend-settlement.md) — the
  suspend seam the frontier feeds (`OutcomeSuspendedOn` → settlement), held outside the frontier.
- [ADR 0059 - Durable External-Call Frontiers on Pulse](0059-durable-external-call-frontiers-on-pulse.md)
  — the external-call specialization of that suspend seam: an `external-call:` `OutcomeSuspendedOn`
  parks on a reserved wake and re-arms (`NodePending`) via settlement instead of completing. To this
  concurrency contract it is just another non-cancelling suspend; the frontier never inspects the
  signal family.
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md) — the "Concurrent
  execution" narrative.
- [Pulse Events Reference](../Reference/Pulse/events.md)
- [Cortex Feature Status](../Reference/feature-status.md) — the `pulse.frontier_concurrency` row.
