---
title: "ADR 0067 - Pulse Per-Stage Retry, Backoff and Replay-Safety Policy"
description:
  "Per-stage failure handling is declared as serialized policy data on each StageDefinition - a
  StageRetryPolicy with exponentially-capped backoff and a replay-safety classification - and
  resolved by pure functions that a thin executor interprets."
sidebar:
  label: "0067. Stage retry & replay policy"
  order: 67
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/types.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
  - "GitHub #304"
---

# ADR 0067 - Pulse Per-Stage Retry, Backoff and Replay-Safety Policy

## Status

Proposed. The mechanism is already implemented and DB-tested in `Cortex.Pulse`; this ADR records the
contract that today lives only as prose in [chapter 06](../Architecture/06-pulse-runtime.md) and the
`Cortex.Pulse.Plan` type shapes. No prior ADR governs the policy shape: ADR 0011 governs checkpoint
compatibility barriers and fresh-run recovery (a different recovery axis), and ADR 0004 governs the
graph-native execution model the policy rides on, but neither fixes the per-stage retry/replay
surface. Implementation status is tracked separately in
[`feature-status.md`](../Reference/feature-status.md), not in this field.

## Context

A durable stage can fail for transient reasons (a flaky external call, a timeout) or have already
produced an un-undoable side effect before a crash. The runtime needs two distinct, per-stage
answers:

1. **On failure, should the stage be re-run, and how is the next attempt paced?** A blanket
   run-level retry is wrong: stages differ in how many attempts are sane, in how long to back off,
   and in whether exhaustion should fail the whole run or skip a non-essential stage.
2. **On resume, is it safe to re-execute a stage whose effects may have already landed?** A stage
   that writes to an external ledger must not be silently replayed; a pure transform can be replayed
   freely.

These two questions share one structural requirement: the answer must travel with the stage across
the durable boundary (it is persisted in the stage plan / graph state and read back on resume), and
it must be a value, not executor branching. If the decision were hardcoded in the executor, every
new failure or replay behavior would re-open the same interpreter; if it were free-form effectful
code, it could not be serialized into a stage definition or audited.

Today the shapes exist (`StageRetryPolicy`, `StageReplaySafety`, `ReplayPolicy` in
`Cortex.Pulse.Plan`) and the executor honors them, but the only written governance is two short
subsections of chapter 06. The contract — what the fields mean, what the backoff cap is, which
failures are non-retryable, and how replay-safety is enforced against prior stage-log entries — has
no ADR.

## Decision

Per-stage failure handling and replay-safety are **declarative policy values attached to each
`StageDefinition`**, resolved by **pure functions** that a thin effectful executor interprets. The
executor never decides retry or replay behavior on its own; it reads the policy off the stage and
applies the pure resolution.

The policy surface (in `Cortex.Pulse.Plan`):

- `sdRetryPolicy :: Maybe StageRetryPolicy` — absent means a single attempt, then fail the run. A
  `StageRetryPolicy` carries `srpPredicateName` (the durable identity of the retryability logic),
  `srpMaxAttempts`, `srpBackoff`, the in-memory `srpRetryable :: StageFailure -> Bool` predicate,
  and `srpExhaustion`.
- `srpBackoff :: StageRetryBackoff` is either `FixedBackoffMicros` or `ExponentialBackoffMicros`.
  Both are **capped at 300 seconds** (`maxRetryDelayMicros = 300_000_000`); the exponential schedule
  is `base * 2^(attempt-1)` with the exponent clamped to 30 to avoid `Int` overflow before the cap
  applies.
- `srpExhaustion :: StageRetryExhaustion` is `ExhaustionFailsRun` or `ExhaustionSkipsStage`: when a
  retryable failure exhausts the attempt budget, the run fails or the stage is skipped accordingly.
- `sdReplaySafety :: StageReplaySafety` is `SafeToReplay` or `Irreversible`. A `SafeToReplay` stage
  is never gated on resume. An `Irreversible` stage is governed by a `ReplayPolicy`
  (`sdReplayPolicyOverride` if set, else the plan-level `spReplayPolicy`): `ReplayPolicyWarn`,
  `ReplayPolicyBlockResume`, or `ReplayPolicyRequireOperatorOverride`.

The retry decision is the pure function
`resolveStageFailure :: StageDefinition -> Int -> StageFailure -> StageFailureResolution`, returning
`RetryStageAfter delayMicros`, `SkipStageAfterExhaustion summary`, or `FailRunAfterExhaustion spec`.
The replay decision is `enforceGraphReplayPolicy`, run once at the start of resume over the
recovered frontier: for each `Irreversible` node with a prior stage-log entry it applies the
effective `ReplayPolicy`. The executor (`handleRetry`, `handleSkip`, `handleTerminalFailure`,
`applyReplayPolicy`) is the thin interpreter of these values.

## Mental Model

> Each stage carries its own answer to "what happens when I fail?" and "is it safe to run me again?"
> as data. A pure function reads the data and the failure and returns one of three verdicts; the
> executor only executes the verdict. Replay safety is checked once, at the resume seam, not on
> every attempt.

## Boundary Rules

- **Policy is data, decision is pure, execution is thin.** `resolveStageFailure` and the policy
  branch of `enforceGraphReplayPolicy`/`applyReplayPolicy` contain the entire decision. The executor
  paths perform only effects (write the attempt log, sleep, fail/skip the run). New retry or replay
  behavior extends the pure resolver, not the interpreter.
- **At-least-one attempt.** `srpMaxAttempts` is read as `max 1 srpMaxAttempts`; a misconfigured
  non-positive count cannot suppress the stage entirely.
- **Retryable AND under budget to retry.** `resolveStageFailure` retries only when
  `srpRetryable failure` holds **and** `attempt < maxAttempts`. A non-retryable failure goes
  straight to `FailRunAfterExhaustion` regardless of remaining budget; budget exhaustion of a
  retryable failure routes by `srpExhaustion`.
- **Backoff is capped, monotonic, overflow-safe.** `retryDelayMicros` clamps negative inputs to 0
  and never exceeds 300 s; the exponential exponent is clamped to 30 so the `2^n` term cannot
  overflow before the cap.
- **Cancellation and shutdown win between attempts.** `handleRetry` waits through `srpBackoff` via
  `awaitDelayOrShutdown`, which returns early when the shutdown flag flips, and a cancellation
  re-check runs before the next attempt — a parked retry never blocks a graceful stop for the full
  delay.
- **Replay-safety is enforced only where it matters.** `enforceGraphReplayPolicy` skips
  `SafeToReplay` nodes and `Irreversible` nodes with no prior stage-log history; it acts only on an
  `Irreversible` node that has already run. `ReplayPolicyWarn` emits an observability event and
  continues; `ReplayPolicyBlockResume` and `ReplayPolicyRequireOperatorOverride` fail the run
  non-retryably with distinct error types (`replay_blocked`,
  `replay_blocked_operator_override_required`).
- **The retryability predicate is named, not serialized.** The serialized `StageRetryPolicy`
  persists `srpPredicateName`, `srpMaxAttempts`, `srpBackoff`, and `srpExhaustion`. The
  `srpRetryable` function is **not** serialized — `FromJSON` reconstructs it as `const True`, so a
  policy rehydrated purely from JSON treats every failure as retryable. `srpPredicateName` is the
  durable identity of the retryability logic that the host re-binds; reusing one name for different
  semantics across compatible runtime versions is invalid.
- **External-call frontiers are out of scope.** A durable external-call stage (ADR 0059) is lowered
  `SafeToReplay` with no `sdRetryPolicy` (`Lowering/ExternalCallStage.hs`), so it carries no retry
  pacing (a failure is not retried) and, while it still passes through the resume replay check, it
  is skipped inside `enforceGraphReplayPolicy` as `SafeToReplay` — irreversible-replay gating never
  fires for it. Its non-terminality and re-entry are governed instead by 0059's idempotent durable
  attempt record (submit / park / resume) and by 0053's executor-level replay class and await
  strategy. This ADR governs the per-stage policy for stages that opt in.

## Alternatives considered

- **Run-level retry only.** A single retry policy on the run rather than per stage. Rejected: it
  cannot express that one stage's external write is `Irreversible` while a sibling transform is
  freely replayable, nor that exhaustion should skip a non-essential stage without failing the run.
- **Executor-branched failure handling.** Keep retry/replay as `if`/`case` logic inside the executor
  loop. Rejected: it is exactly the additive-guard trap ADR 0058 calls out for the suspend path —
  every new behavior re-opens the interpreter, and the decision cannot be serialized into a stage
  definition or audited from the plan.
- **Serialize the retryability predicate itself (closures/code).** Persist the
  `StageFailure -> Bool` function, not just its name. Rejected: arbitrary predicates are not durably
  serializable or versionable; a stable `srpPredicateName` plus host re-binding keeps the durable
  record auditable and the decision logic pure.
- **Derive replay-safety from checkpoint compatibility (ADR 0011).** Reuse the compatibility-barrier
  machinery to gate replay. Rejected: compatibility barriers answer "is this checkpoint still valid
  for this code?", an orthogonal question to "did this stage already cause an un-undoable effect?".
  Both can apply to the same resume; collapsing them would hide one behind the other.

## Consequences

### Positive

- Retry and replay behavior travel with the stage as serialized data; the plan is the audit record
  for how each stage fails and whether it may be replayed.
- The decision is a small set of pure functions, so it is unit-testable without a database
  (`retryDelayMicros` backoff-cap tests) and the executor stays a thin interpreter.
- The backoff cap and overflow clamp make exponential schedules safe to configure aggressively
  without risking unbounded sleeps or `Int` overflow.
- Replay-safety is a first-class, per-stage classification, so an `Irreversible` stage's resume
  behavior is explicit and operator-controllable rather than implicit.

### Negative

- Two related-but-distinct mechanisms (retry resolution and replay enforcement) share one feature
  key and one ADR; a reader must hold both faces of the per-stage policy surface in mind.
- The retryability predicate's behavior depends on host re-binding by `srpPredicateName`; a policy
  rehydrated from JSON alone defaults to retry-on-any-failure (`const True`), so the name contract
  is load-bearing and unenforced by the type system.
- Replay enforcement reads the full stage-log detail set per `Irreversible` node on resume; a plan
  dense with irreversible stages pays that read cost at the resume seam.

### Obligations

- Keep [`docs/Reference/Pulse/types.md`](../Reference/Pulse/types.md#5-retry-policy) and chapter
  06's Retry/Replay-safety subsections in step with `Cortex.Pulse.Plan`: the field set, the 300 s
  cap, the exhaustion semantics, and the timeout-precedence rule (per-stage `sdTimeoutSeconds` over
  the task-level timeout).
- Preserve `srpPredicateName` stability: never reuse a name for different retry semantics across
  compatible runtime versions, and re-bind the predicate host-side rather than relying on the JSON
  default.
- Keep the decision logic pure: extend `resolveStageFailure` / `applyReplayPolicy`, not the executor
  interpreters, when adding behavior.
- Maintain the DB-backed regression coverage in `test/Cortex/Pulse/ExecutorSpec.hs`: backoff cap,
  retry-then-succeed, skip-on-exhaustion, shutdown/cancellation during backoff, and the four replay
  outcomes (warn-continues, block_resume, operator-override, `SafeToReplay`-ignores).

## Traceability

- Feature keys: `pulse.stage_retry_policy`
- Public surface: `Cortex.Pulse`, [`docs/Reference/Pulse/types.md`](../Reference/Pulse/types.md)
- Implementation: `src/Cortex/Pulse/Plan.hs` (`StageRetryPolicy`, `StageRetryBackoff`,
  `StageRetryExhaustion`, `StageReplaySafety`, `ReplayPolicy`, `sdRetryPolicy`,
  `sdReplayPolicyOverride`), `src/Cortex/Pulse/Executor/Attempt.hs` (`resolveStageFailure`,
  `handleRetry`, `awaitDelayOrShutdown`, `effectiveStageTimeoutSeconds`),
  `src/Cortex/Pulse/Executor/Persistence.hs` (`retryDelayMicros`, `maxRetryDelayMicros`),
  `src/Cortex/Pulse/Executor/ReplayPolicy.hs` (`enforceGraphReplayPolicy`, `applyReplayPolicy`)
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [0004 - Graph-Native Pulse Execution](0004-graph-native-pulse-execution.md) — the execution model
  the per-stage policy rides on.
- [0011 - Compatibility Barriers and Fresh-Run Recovery](0011-compatibility-barriers-and-fresh-run-recovery.md)
  — the orthogonal checkpoint-compatibility recovery axis.
- [0058 - Pulse Atomic Suspend Settlement](0058-pulse-atomic-suspend-settlement.md) — the same
  pure-decision / thin-interpreter discipline applied to the suspend transition.
- [0053 - Executor Catalog Manifests and Pulse Runtime Bindings](0053-executor-catalog-manifests-and-pulse-bindings.md)
  — declares the executor-level replay class and await strategy in the runtime policy digest at
  binding time; this ADR's per-stage `StageReplaySafety` / `StageRetryPolicy` is their runtime-plan
  realization.
- [0059 - Durable External-Call Frontiers on Pulse](0059-durable-external-call-frontiers-on-pulse.md)
  — external-call frontier stages opt out of this per-stage policy (`SafeToReplay`, no
  `sdRetryPolicy`) and handle provider non-terminality and re-entry through their idempotent durable
  attempt record instead.
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md) — Retry and Replay-safety
  subsections.
- [Pulse Types Reference](../Reference/Pulse/types.md) — the normative type shapes.
- GitHub #304
