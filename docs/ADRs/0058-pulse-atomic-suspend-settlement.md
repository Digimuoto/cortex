---
title: "ADR 0058 - Pulse Atomic Suspend Settlement"
description:
  "Collapses the run-terminal suspend transition into one settlement transaction so the wait row,
  the graph state, and the run park commit together, retiring the post-park recheck."
sidebar:
  label: "0058. Atomic suspend settlement"
  order: 58
status: proposed
date: 2026-06-15
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/signals.md
  - docs/Reference/Pulse/schema.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - "GitHub #263"
  - "GitHub #264"
  - "GitHub #267"
---

# ADR 0058 - Pulse Atomic Suspend Settlement

## Status

Proposed. The design is validated by the model-checked spec `formal/RunTerminalSignal.tla` (atomic
settlement is lost-wakeup-free; the split protocol reproduces the bug). This ADR records the runtime
contract and the implementation obligations; the refactor itself is tracked on #267 (the testability
and design groundwork landed via #263).

## Context

A parent run suspends on a child run's `run-terminal:<uuid>` signal. Today the suspend transition is
**split across non-atomic steps**:

1. the frontier registers the wait row inline when a node returns `StageSuspended`
   (`Executor/Frontier.hs`, its own transaction, `SELECT … FOR SHARE` on the awaited run);
2. the wave's graph state (`NodeWaiting`) is persisted separately (`Executor/Persistence.hs`);
3. the run is parked (`runs.status = 'waiting'`) in a third transaction (`Executor/Outcome.hs`);
4. a post-park recheck re-reads delivered signals and self-wakes to patch the window between
   (1)/(3).

Every run-terminal bug fixed to date (PR #263: lost wakeup at registration, delivery racing the
park, missing terminal writers, swallowed lookup error; then a timeout-omission and a wake-on-error)
has been an **additive guard on a new interleaving** of this split. The protocol is correct only if
all four sites share one mental model — the signature of a transition surface that is too large.

## Decision

Collapse the suspend transition into **one settlement transaction**. `runs.status = 'waiting'` stays
as denormalized scheduler state (per `schema.md`); it is **not** derived from signal rows. The
transaction, given the wave's final graph state, commits **together**:

1. the graph state (with `NodeWaiting` for parked nodes, and `NodeCompleted` for any node whose wait
   resolves at registration);
2. the `pulse.signals` wait rows;
3. `runs.status = 'waiting'` — iff any node remains waiting after resolution.

Because the wait row and the `waiting` transition commit atomically, **no window exists between
registration and park**, so the post-park recheck (and its wake-on-error) is retired.

`SELECT … FOR SHARE` on each awaited run row is **retained inside this transaction** — atomicity
removes the internal (multi-transaction) window, but the share lock is what serializes settlement
against the terminal writer's delivery transaction. A transaction-scoped advisory lock taken first
by every run-terminal protocol operation (see _Boundary Rules_) prevents mutually-awaiting terminal
writers from deadlocking. All three mechanisms are required.

## Mental Model

> Suspending is one transaction. The frontier proposes `NodeWaiting`; settlement decides — per node,
> under a share lock — resolve-now-or-park, and commits graph state + wait rows + run status as a
> unit. Delivery remains the single "mark delivered + wake waiting run" transaction.

## Boundary Rules

- **One writer of the suspend transition.** Registration moves out of the frontier; the frontier
  only marks `NodeWaiting` provisionally. Settlement is the sole place that writes wait rows and
  parks.
- **One protocol critical section (deadlock-avoidance).** Concurrent _settlements_ alone cannot
  deadlock — `FOR SHARE` on awaited rows is a _shared_ lock (compatible across settlements), and a
  settlement's only exclusive writes are its own per-run rows. But terminal _writers_ and delivery
  take **exclusive** locks: each terminal writer `UPDATE`s its own `pulse.runs` row and then wakes
  (`UPDATE`s) its waiters' run rows. Two mutually-awaiting runs reaching terminal status
  concurrently (`complete(A)` holds A exclusive and wants to wake B; `complete(B)` holds B exclusive
  and wants to wake A) form an exclusive→exclusive row-lock cycle that no FOR-SHARE reasoning
  prevents. So every run-terminal protocol entry that touches run rows — the four terminal status
  writers, expired-lease recovery, run-terminal settlement planning, and `deliverRunTerminalSignals`
  — first takes a single transaction-scoped advisory lock (`pg_advisory_xact_lock`, one global key).
  Acquiring one common lock before any run row is touched collapses the protocol into a single
  critical section, so no cycle can form regardless of which runs await which. The awaited-row
  `FOR SHARE` is retained inside that section for lost-wakeup serialization (it still blocks a
  terminal writer between "observed non-terminal" and "pending wait committed"); the advisory lock,
  not lock ordering, is the deadlock-avoidance mechanism. The lock is transaction-scoped, so
  commit/rollback releases it with the same atomicity as the signal rows.
- **Rejected suspends repair graph state.** A suspend that settlement rejects (run-terminal target
  missing, run-terminal self-wait, or duplicate pending ownership) marks the offending `NodeWaiting`
  nodes `NodeFailed`, propagates failure through the topology, and persists that repaired graph
  state before failing the run — so a rejected run does not leave a node stranded in `NodeWaiting`.
- **Resolve-at-settlement.** A node whose awaited run is already terminal resolves in-transaction:
  its node is marked `NodeCompleted` with the terminal payload, not parked.
- **Re-run only on resolution.** If any node resolved, settlement does not park; it re-runs the plan
  with the resolved nodes already `NodeCompleted` so their successors unblock. If none resolved, it
  parks. (Re-running without first marking resolved nodes completed would loop forever, because the
  normal `runGraphPlan` path does not call `resolveDeliveredSignals` — that runs only on resume.)
- **Owner-checked idempotent registration.** Settlement may re-run (mixed resolve/park, or recovery
  of a `NodeWaiting` run whose wait rows already exist). Registration is idempotent only when the
  same node already owns the pending row for `(run_id, signal_name)`. A different node trying to
  reuse the same pending signal name is rejected before graph state is parked.
- **CAS-first.** The graph-state write uses optimistic CAS on its revision; it runs first in the
  transaction and a stale result aborts before any wait-row insert or park, so a lost CAS never
  leaves orphan rows or a park on stale state.

## Consequences

### Positive

- The lost-wakeup class is closed structurally rather than guarded; the post-park recheck and
  wake-on-error are deleted.
- One mental model, one writer, one transaction — new run-terminal features extend a single seam.

### Negative

- Settlement is more complex than a bare park: it mutates graph state (resolve→completed) and drives
  a re-run decision.
- Recovery of a `NodeWaiting` run must route through settlement (idempotent) rather than a bare
  park.
- The advisory lock serializes the entire run-terminal protocol globally: only one terminal write /
  run-terminal settlement / delivery proceeds at a time across the substrate. These operations are
  infrequent relative to ordinary stage execution, so the throughput cost is accepted in exchange
  for a single, obviously-correct deadlock argument.

### Obligations

- `settleSuspend` (one transaction): CAS graph-state write first; FOR-SHARE register-or-resolve per
  `NodeWaiting`; mark resolved nodes `NodeCompleted`; park iff waiters remain; return whether to
  re-run or report `OutcomeSuspended`.
- Make signal-wait registration owner-checked: same-node pending rows are idempotent, different-node
  pending rows are invalid, and duplicate ownership is never collapsed into `DO NOTHING`.
- Take the transaction-scoped run-terminal protocol advisory lock first in every operation that
  touches run rows under the protocol: the four terminal status writers, expired-lease recovery,
  run-terminal settlement planning, and `deliverRunTerminalSignals`.
- A rejected suspend repairs graph state (mark offending `NodeWaiting` nodes failed, propagate
  failure) and persists it before failing the run.
- Remove inline registration from `Executor/Frontier.hs` (`StageSuspended` → `OutcomeSuspendedOn`,
  no DB write).
- Route both suspend entry points in `Executor/Loop.hs` (fresh-suspend and the recovered `Suspended`
  branch) through settlement; implement re-run-if-resolved.
- Delete `shouldWakeAfterPark` + the wake-on-error path in `Executor/Outcome.hs`.
- Tests (against `just test-db`): all-resolve → re-run → complete; mixed resolve/park; CAS-stale →
  no orphan rows / no park; recovered-waiter settlement parks once. Update `signals.md`/`events.md`
  (`run.woken` is retired).
- Theory: this ADR's safety/liveness obligation is the one `formal/RunTerminalSignal.tla` checks;
  keep it in step with the implementation.

## Alternatives considered

- **Keep the recheck (status quo).** Rejected as the steady state: it is correct but is an additive
  guard that every new interleaving re-opens; the suite that would catch regressions was dormant
  (#264).
- **Derive `waiting` from signal rows (drop the denormalized status).** Rejected: it pushes a
  graph/signal join into scheduler claiming and erases a documented lifecycle state (`schema.md`).
- **Redundant registration (frontier + settlement).** Rejected: a delivery between the two can flip
  the row to `delivered`, and a second pending `INSERT` then duplicates it.

## Related

- [0003 - Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md)
- [0004 - Graph-Native Pulse Execution](0004-graph-native-pulse-execution.md)
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Pulse Signals Reference](../Reference/Pulse/signals.md)
- `formal/RunTerminalSignal.tla`
