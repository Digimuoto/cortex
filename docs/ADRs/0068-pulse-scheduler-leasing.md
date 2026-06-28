---
title: "ADR 0068 - Pulse Scheduler: Lease Recovery, Fair Claiming and Backpressure Visibility"
description:
  "Specifies the scheduler discipline ADR 0003 left open: round-robin claiming under per-task-type
  caps, lease-renewal race resolution, expired-run recovery, and a backpressure surface on the
  health endpoint."
sidebar:
  label: "0068. Scheduler leasing"
  order: 68
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/service-api.md
  - docs/Reference/Pulse/events.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0008-pulse-operator-visibility-surfaces.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
---

# ADR 0068 - Pulse Scheduler: Lease Recovery, Fair Claiming and Backpressure Visibility

## Status

Proposed. The mechanisms described here are implemented in `Cortex.Pulse.Scheduler` and exercised by
`test/Cortex/Pulse/SchedulerSpec.hs`. This ADR records the contract those mechanisms must satisfy
and the obligations that follow; the configurable-threshold and requeue-age follow-ups remain open.

## Context

[ADR 0003](0003-pulse-service-and-host-action-boundary.md) decides that Pulse owns "task
definitions, runs, checkpoints, scheduling, leases, signals, and lifecycle transitions," but it
specifies **no scheduling algorithm**. A single durable poll loop must therefore make four entangled
decisions that 0003 leaves open, and every one of them has a failure mode if left implicit:

- **Which runnable run to claim next.** A naive "oldest first" loop lets one high-volume task type
  monopolize every worker slot while other due types starve. Fairness across task types is not free;
  it has to be a property of the ordering and of how slots are filled within one tick.
- **Concurrency bounds.** A global worker cap (`pulseMaxConcurrentTasks`) is not enough when one
  task type is resource-heavy. Operators need a per-task-type cap so a single type cannot consume
  all slots even when it is the only work pending.
- **Lease lifecycle under races.** A run executes under a lease (`runs.lease_owner`,
  `runs.lease_expires_at`). The owning executor renews mid-flight; a recovery sweep may declare the
  same lease expired; the run may finish in the window between a failed renewal and the cancellation
  it triggers. Without an explicit race resolution, a run can be double-executed, or a completed run
  can be reported failed.
- **Backpressure visibility.** When the pool is saturated and runnable work keeps aging in the
  queue, nothing in the runtime previously surfaced that condition. Saturation is invisible until a
  human notices latency.

These four are not independent features bolted onto separate components — they are the observable
behavior of one scheduler loop, and they interact: per-type caps shape claiming, claiming saturates
the pool, saturation is the backpressure signal, and recovery returns abandoned leases to the
claimable pool. The substrate needs one decision that pins down the whole discipline so the loop has
a single mental model rather than four ad hoc guards.

## Decision

Adopt a single scheduler discipline for the Pulse poll loop (`runSchedulerLoop`). It is the
algorithm ADR 0003 deferred; it has four coupled rules.

1. **Round-robin claiming under per-type caps.** Each fill cycle claims runs into free slots,
   recomputing the excluded-type set after every launch (`computeExcludedTypes`) so a per-task-type
   cap (`pulseTaskTypeLimits`) is enforced _within_ a single tick, not just across ticks. The type
   claimed most recently is deprioritized — ordered last in the claim queries
   (`claimNextPendingRun`, `getNextDueTask`) and persisted in `lastClaimedTypeVar` across poll ticks
   so fairness holds even when only one slot frees per tick. The global cap is the pool's
   `availableSlots`; the per-type caps are an additional filter on top.

2. **Skip-locked, CAS-based claim.** Operator-triggered pending runs are claimed first
   (`claimNextPendingRun`, `FOR UPDATE OF r SKIP LOCKED LIMIT 1`), then due scheduled tasks
   (`getNextDueTask` then `claimAndCreateRun`, which uses `INSERT ... ON CONFLICT DO NOTHING` plus a
   conditional `scheduler_claimed` flag flip). Two scheduler incarnations therefore never claim the
   same row. The `run.claimed` event is written **inside the claim transaction**, atomically with
   the claim, carrying `queue_seconds` for first claims.

3. **Run-scoped lease renewal with explicit race resolution.** `withLeaseRenewal` renews a run's
   lease every half the lease duration (jitter capped so renewal-plus-jitter stays below the lease,
   and disabled entirely for leases under 10s). `renewRunLease` returns whether the renewing
   `UPDATE` still matched a `running` row owned by this executor. The three outcomes are resolved
   explicitly: renewed → continue; renewal-returned-false → poll the in-flight action and **accept a
   completed outcome** if it already finished (`pulse.lease.completed_before_renewal`), otherwise
   treat the lease as lost, cancel, and after cancellation **still accept** an outcome that landed
   in the cancellation window (`pulse.lease.race`); DB-failed renewal → fail closed and cancel. A
   lease genuinely lost marks the run `failed` retryable.

4. **Two-path recovery plus a backpressure surface.** Recovery is split by ownership.
   `reclaimOwnedRuns` (startup) refreshes leases for runs still owned by _this_ lease owner so the
   executor resumes from its checkpoint. `recoverExpiredRuns` marks runs whose lease has expired
   under a _different_ owner `failed` with `error_type = 'stale_run_recovery'` and finalizes their
   schedule; it runs once at startup and then on a fixed ~30s cadence independent of the poll
   interval. Every poll tick reads one `readBackpressureSnapshot` (pending count, oldest
   never-started pending age, waiting count) into the health state, and warns on a fixed cadence
   (`pulse.scheduler.backpressure.starved`) when the pool is saturated while pending work ages past
   the threshold.

## Mental Model

> One poll loop owns the whole discipline. Each tick: reap finished runs, run recovery on its own
> cadence, fill free slots fairly under per-type caps, read one backpressure snapshot, and update
> the health surface. A run executes under a lease it renews itself; the lease is the unit of
> recovery, and losing it is resolved against the in-flight outcome rather than assumed fatal.

## Boundary Rules

- **Fairness is recomputed per launch, not per tick.** `computeExcludedTypes` runs again after every
  launch inside `fillAvailableSlots`, so a type reaching its cap mid-cycle is excluded for the rest
  of that same cycle. Round-robin deprioritization persists across ticks via `lastClaimedTypeVar`;
  it is not reset each poll.
- **The claim event is part of the claim transaction.** `run.claimed` (with `queue_seconds` for
  first claims) is emitted by `claimNextPendingRun`'s SQL, not by application code after the claim,
  so queue timing cannot diverge from the claim itself. A requeued (resumed-after-waiting) run
  records `requeued: true` and omits `queue_seconds` — its requeue instant is not recoverable
  without a `pending_since` column.
- **Lease loss is resolved against the outcome, never assumed.** Both the renewal-false path and the
  post-cancel path poll the in-flight action and accept a completed `RunOutcome` if one exists. A
  run is only marked failed for lease loss when no outcome is available. This is what prevents a
  double-execution or a false failure across the renewal/recovery boundary.
- **Owned-reclaim and foreign-recovery are different operations.** Reclaim refreshes leases for
  resume (`lease_owner = $1`); recovery fails out abandoned runs
  (`lease_owner IS DISTINCT FROM $2`). They never overlap on the same run, because the `lease_owner`
  predicate partitions them.
- **Recovery is a run-terminal protocol writer.** Because `recoverExpiredRuns` marks runs terminal
  and wakes their run-terminal waiters in the same transaction, it first takes the
  transaction-scoped advisory lock mandated by [ADR 0058](0058-pulse-atomic-suspend-settlement.md)
  before any run row is touched, so a recovered run awaited by another concurrently terminalizing
  run cannot reopen the mutual row-lock cycle that ADR closes.
- **Backpressure age covers only never-started pending runs.** `readBackpressureSnapshot` measures
  the oldest pending age over rows with `started_at IS NULL`, so a woken waiter that re-enters
  `pending` does not report its full lifetime as queue age and trip a false starvation warning.

## Alternatives considered

- **Leave the algorithm implicit (status quo of ADR 0003).** Rejected: 0003 names scheduling as
  Pulse-owned but writes no contract, so fairness, per-type caps, and lease-race resolution lived as
  uncommented loop details with no canon to hold them to. The behavior is load-bearing enough to
  deserve a decision.
- **Global concurrency cap only, no per-type caps.** Rejected: a single resource-heavy task type can
  then consume every worker slot whenever it has the most pending work, starving all other types.
  Per-type caps plus round-robin deprioritization are what bound that.
- **Treat a failed lease renewal as an unconditional run failure.** Rejected: the run frequently
  finishes in the window between a renewal miss and the cancellation it triggers; failing it
  unconditionally would discard a completed outcome and re-run already-done work. The discipline
  polls the action and accepts a real outcome first.
- **Derive backpressure from external observability instead of the runtime.** Rejected on the same
  grounds as [ADR 0008](0008-pulse-operator-visibility-surfaces.md): operators need a queryable
  runtime surface (the health endpoint and run events), not only an external log stream, and
  saturation is a first-class scheduler fact.

## Consequences

### Positive

- Fairness across task types is a stated property with per-launch enforcement, not an emergent loop
  detail; one task type cannot monopolize the pool.
- The lease-renewal/recovery race has one written resolution, so completed runs are never reported
  failed at the boundary and abandoned runs are recovered without double-execution.
- Saturation is visible: per-type active counts, pending count, oldest pending age, and waiting
  count are on the health surface, with a rate-limited starvation warning.

### Negative

- The scheduler loop is more complex than a bare claim-and-run: it carries round-robin state across
  ticks, recomputes exclusions per launch, runs recovery on a separate cadence, and reads a
  backpressure snapshot every tick (one extra query per poll).
- The starvation threshold and re-warn cadence are currently fixed constants in the loop, not yet
  operator-configurable.

### Obligations

- Keep round-robin claiming fair: recompute `computeExcludedTypes` after each launch and persist the
  last-claimed type across ticks; per-type caps come from `pulseTaskTypeLimits`.
- Keep the claim atomic and skip-locked, and keep the `run.claimed` event (with `queue_seconds` for
  first claims) inside the claim transaction.
- Keep `withLeaseRenewal` resolving the three renewal outcomes explicitly, accepting a completed
  outcome over a lease-loss failure in both the renewal-false and post-cancel windows.
- Keep owned-reclaim (resume) and foreign-recovery (fail) partitioned by `lease_owner`, run recovery
  on its fixed cadence, and have `recoverExpiredRuns` take the ADR 0058 advisory lock before
  touching run rows.
- Keep the backpressure snapshot feeding the health surface every tick, measuring pending age over
  never-started runs only, and keep the starvation warning rate-limited.
- Follow-up: add a `pending_since` column so requeued-run queue age and `queue_seconds` are
  recoverable, and make the starvation threshold/cadence configurable.

## Traceability

- Feature keys: `pulse.scheduler_leasing`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/service-api.md`
- Implementation: `src/Cortex/Pulse/Scheduler.hs`, `src/Cortex/Pulse/Query.hs`,
  `src/Cortex/Pulse/Health.hs`, `src/Cortex/Pulse.hs`
- Tests: `test/Cortex/Pulse/SchedulerSpec.hs`
- Theory/proof: none

## Related

- [0003 - Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md) —
  asserts Pulse owns scheduling and leases but specifies no algorithm; this ADR fills that gap.
- [0008 - Pulse Operator Visibility Surfaces](0008-pulse-operator-visibility-surfaces.md) — the
  backpressure surface is a scheduler-decision visibility surface in that contract.
- [0058 - Pulse Atomic Suspend Settlement](0058-pulse-atomic-suspend-settlement.md) — expired-run
  recovery is a run-terminal protocol writer and takes the advisory lock that ADR mandates.
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Pulse Service API Reference](../Reference/Pulse/service-api.md)
- [Pulse Events Reference](../Reference/Pulse/events.md) </content> </invoke>

## Tracking

- #259 — configurable scheduler thresholds and requeue-age accounting.
