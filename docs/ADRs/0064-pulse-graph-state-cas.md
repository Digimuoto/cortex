---
title: "ADR 0064 — Pulse Graph-State Optimistic Concurrency and Single-Writer Ownership"
description:
  "Every durable graph-state write is an optimistic compare-and-swap on the run's single graph_state
  row keyed by its updated_at revision; a lost race drains the stale executor to OutcomeShutdown
  without overwriting newer state."
sidebar:
  label: "0064. Graph-state CAS"
  order: 64
status: accepted
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/schema.md
  - docs/Reference/Pulse/events.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0064 — Pulse Graph-State Optimistic Concurrency and Single-Writer Ownership

## Status

Accepted. The graph-state persistence hardening suite covers direct, sequential, concurrent,
suspend-settlement, and stale-owner CAS behavior. The hosted-Circuit integration additionally proves
that an uncommitted initial engine checkpoint starts no effect and that hosted checkpoint
acknowledgement crosses the same CAS seam before successor work is unlocked.

## Context

Pulse executes graph topology directly and persists a single mutable snapshot per run in
`pulse.graph_state` for durable resume (ADR 0004 decided graph-native execution but deferred the
persistence-concurrency detail). One row holds the latest `node_statuses`, `node_outputs`, rewrite
lineage, and `updated_at` for the run; `run_id` is its primary key, so there is exactly one such row
per run.

A run is meant to be advanced by one executor at a time. Ownership is a lease (`pulse.runs`
`lease_owner` / `lease_expires_at`), and recovery resumes a run whose lease expired. But a lease is
a soft boundary: a lease can expire while its original holder is still mid-wave (a stalled process,
a slow database round-trip, a clock skew), so recovery can resume the same `run_id` while the
original executor is still alive and still about to write. Two executors then transiently believe
they own the same run. Without a durability backstop the slower writer would clobber the faster
writer's newer graph state, corrupting the snapshot that resume reads back — exactly the
silent-overwrite hazard ADR 0011 rules out for checkpoints, but at the graph-state layer.

Holding a row lock across stage execution is the obvious fix and the wrong one: stages run arbitrary
work, so a pessimistic lock would be held for the wave's full duration and a crashed holder would
strand it behind a lock timeout. The runtime instead needs a write-time check that is
single-statement and that lets the loser _detect_ it lost rather than block.

## Decision

Make every durable graph-state write an optimistic compare-and-swap on the run's `graph_state` row,
keyed on its `updated_at` value as the revision token, and resolve a lost race by draining the stale
executor — never by overwriting.

- **`updated_at` is the revision token.** It is wrapped in the `GraphStateRevision` newtype so a
  revision is type-distinct from an ordinary timestamp at call sites (`GraphStateRevision.hs`).
- **CAS write.** `Q.writeGraphState` (`Query.hs`) takes an expected revision. The first write per
  run carries no expected revision and is insert-only (`ON CONFLICT (run_id) DO NOTHING`); a later
  write `UPDATE`s the row only `WHERE gs.updated_at = input.expected_revision`. The statement
  returns the new `updated_at` as `GraphStateWriteApplied`, or — when no row matched —
  `GraphStateWriteStale`.
- **Strictly increasing revisions.** `nextGraphStateRevision` (`Executor/Persistence.hs`) forces
  each replacement `updated_at` to be at least one microsecond greater than the previous revision
  (`graphStateRevisionStep = 0.000001`, PostgreSQL `timestamptz` precision), so a coarse-precision
  or briefly-backward clock cannot rewrite the same token and leave a stale owner eligible.
- **Lost race ⇒ drain, not fail.** `persistGraphState` maps `GraphStateWriteStale` to
  `GraphStatePersistStaleWrite`, and `handleGraphStatePersistError` turns that into
  `OutcomeShutdown` after recording the warn event
  [`run.graph_state_stale_write`](../Reference/Pulse/events.md#run-lifecycle) ("lost the ownership
  race; stopping this executor without overwriting newer state"). This is explicitly distinct from a
  write that errors at the database (`GraphStatePersistDbError`), which records
  [`run.graph_state_persist_failed`](../Reference/Pulse/events.md#run-lifecycle) and _fails_ the run
  (`OutcomeFailed`, retryable).

The run is therefore a logically single-writer durable object, enforced optimistically rather than
by a lock: at most one executor's wave write wins a given revision, and an overlapping stale owner
stops harmlessly instead of corrupting the winner's state.

## Mental Model

> The `graph_state` row is owned by whoever last advanced its revision. Each write stakes the
> revision it read and wins only if no one has moved it since. The loser yields the run — it stops
> without a terminal write — rather than clobbering the winner.

The named mutation boundary is the **durable graph-state write seam**. Runtime code may construct
new graph state in memory, but durable mutation of `pulse.graph_state` must cross this seam so the
CAS token, stale-write behavior, event emission, and suspend-settlement ordering remain uniform.

## Boundary Rules

- **One row, one revision per run.** `run_id` is the `graph_state` primary key; `updated_at` is both
  the durable snapshot timestamp and the CAS token. There is no separate revision column.
- **CAS on every wave write.** All durable graph-state writes route through the durable graph-state
  write seam (`persistGraphState` / `requireGraphStatePersist` / `requireGraphStatePersistVar` /
  `settleSuspend`) rather than raw `writeGraphState`: the frontier's running-mark and per-node
  result writes (`Executor/Frontier.hs`), the loop's post-rewrite write (`Executor/Loop.hs`), and
  resume's rehydration write (`Executor/Resume.hs`). Each carries the expected revision it last
  read, so no path can bypass the check.
- **Hosted engine checkpoints use the same seam.** The Pulse runtime host maps every engine
  checkpoint into `PersistedGraphState` and calls `requireGraphStatePersistVar`; it sends
  `checkpoint_committed` only after that CAS succeeds. A stale owner, persistence error, or lost
  lease terminates the child and workers without advancing from an uncommitted snapshot.
- **CAS-first inside the suspend transaction.** The run-terminal suspend settlement (ADR 0058) does
  read/lock-only signal-wait planning first, then runs its `writeGraphState` as the **first durable
  mutation** in the transaction; a `GraphStateWriteStale` there becomes
  `SuspendSettlementTxStaleWrite` → `OutcomeShutdown`, aborting before any wait-row commit or park,
  so a lost CAS never leaves orphan wait rows or parks on stale state. The same settlement now also
  re-arms reserved `external-call:` waits (ADR 0059); the CAS is still the first durable write
  there, so a stale write aborts before any wait-row commit, delivered-signal consume, or re-arm on
  that path too.
- **Lost race drains; it does not fail.** A stale CAS yields `OutcomeShutdown` and writes no
  terminal run status — the losing executor exits and the winner's run record and graph state stay
  authoritative. A genuine database error is the failing path, and the two are never conflated.

## Alternatives considered

- **Pessimistic row lock (`SELECT … FOR UPDATE` on `graph_state`).** Rejected: the lock would be
  held across arbitrary stage execution for the whole wave, and a crashed or lease-lost holder would
  strand the run behind a lock timeout. CAS is single-statement, holds nothing across stage work,
  and lets the loser detect loss after the fact.
- **A separate monotonic integer revision column.** Rejected: the row already maintains `updated_at`
  for durable resume and inspection, and it is already monotone under `nextGraphStateRevision`. A
  second counter is redundant durable state with no added guarantee.
- **Last-writer-wins (no expected-revision check).** Rejected: a stale lease-recovery executor would
  silently overwrite the winner's newer graph state, reintroducing exactly the corrupt-resume hazard
  ADR 0011 forbids for checkpoints.

## Consequences

### Positive

- Two executors that transiently both own a run cannot corrupt durable state: at most one write per
  revision wins, and the loser stops cleanly with an audit event.
- No lock is held across stage execution; each write is a single-statement conditional `UPDATE`.
- The CAS reuses `updated_at`, so resume/inspection and concurrency control share one column instead
  of carrying a redundant revision counter.

### Negative

- The token is a wall-clock value. Strict monotonicity depends entirely on the one-microsecond
  stepping in `nextGraphStateRevision`; that step is the sole defense against a coarse-precision or
  backward-drifting clock writing a duplicate token.
- A lost race discards the loser's in-flight wave work rather than merging it; correctness rests on
  the winner's state being the authoritative continuation.
- The drain is observable only through the `run.graph_state_stale_write` warn event, so ownership
  contention is invisible unless operators read the run event stream.

### Obligations

- Every new graph-state write path must go through the persistence seam carrying an expected
  revision; no caller may issue a raw `writeGraphState` without it, or the CAS is bypassed.
- Reviews of new durable execution paths must treat raw `writeGraphState` as an implementation
  detail of the seam, not as a general mutation API.
- `settleSuspend` must keep its graph-state CAS write first in the transaction (ADR 0058) so a stale
  result aborts before wait rows or a park are written.
- `nextGraphStateRevision` must remain strictly increasing; any change to the revision source must
  preserve the one-microsecond floor.
- Tests (against `just test-db`): a write with a stale expected revision returns
  `GraphStateWriteStale` and leaves the winner's state intact; a stale owner resolves to
  `OutcomeShutdown` and emits the warn event without overwriting newer state.

## Traceability

- Feature keys: `pulse.graph_state_cas`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/schema.md`
- Implementation: `src/Cortex/Pulse/GraphStateRevision.hs`, `src/Cortex/Pulse/Query.hs`
  (`writeGraphState`), `src/Cortex/Pulse/Executor/Persistence.hs` (`persistGraphState`,
  `nextGraphStateRevision`, `handleGraphStatePersistError`, `settleSuspend`)
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs` (`graph-state persistence hardening` and hosted Circuit
  backend), `checks.cortex-wire-hosted-pulse`
- Theory/proof: none

## Related

- [ADR 0004 — Graph-Native Pulse Execution](./0004-graph-native-pulse-execution.md) — establishes
  the durable graph snapshot this CAS guards.
- [ADR 0011 — Compatibility Barriers and Fresh-Run Recovery](./0011-compatibility-barriers-and-fresh-run-recovery.md)
  — the no-silent-overwrite stance at the checkpoint layer that this enforces at the graph-state
  layer.
- [ADR 0058 — Pulse Atomic Suspend Settlement](./0058-pulse-atomic-suspend-settlement.md) — relies
  on this CAS as its CAS-first rule inside the suspend transaction.
- [ADR 0059 — Durable External-Call Frontiers on Pulse](./0059-durable-external-call-frontiers-on-pulse.md)
  — its external-call wake re-arm flows through the same CAS-first suspend settlement, so this CAS
  guards the external-call re-arm path as well.
- [Architecture 06 — Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Pulse Schema Reference](../Reference/Pulse/schema.md) — `graph_state` and the `updated_at`
  revision token.
- [Pulse Events Reference](../Reference/Pulse/events.md) — `run.graph_state_stale_write`.
