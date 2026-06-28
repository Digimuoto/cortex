---
title: "ADR 0066 — Pulse Graph-State-Driven Resume and Recovery Preconditions"
description:
  "Resume replays admitted rewrites up to the persisted watermark, re-authorizes witnessed replay,
  and validates a persisted recovery-precondition algebra (mirroring Recovery.lean) before
  classifying the recovered frontier — so resume is a typed total function of persisted state, not a
  best-effort restart."
sidebar:
  label: "0066. Resume & recovery preconditions"
  order: 66
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/proof-status.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0066 — Pulse Graph-State-Driven Resume and Recovery Preconditions

## Status

Proposed. The resume/recovery path is implemented in the durable executor
(`Cortex.Pulse.Executor.Resume`, `Cortex.Pulse.GraphRuntime`); this ADR records the decision and its
proof correspondence to `theory/Cortex/Pulse/Recovery.lean`. Implementation status is tracked as the
`pulse.resume_recovery` row in [`feature-status.md`](../Reference/feature-status.md), not in this
ADR's status field.

## Context

[ADR 0004](./0004-graph-native-pulse-execution.md) decided that "suspension, resume, and recovery
operate over graph state, not stage counters." It did not say what a _validly resumable_ persisted
graph state is, nor how the runtime reconstructs the materialized topology a crashed run was last
executing against.

Two adjacent decisions bound the problem but do not cover it:

- [ADR 0011](./0011-compatibility-barriers-and-fresh-run-recovery.md) governs **version-drift
  compatibility barriers** — an incompatible checkpoint fails explicitly rather than resuming
  silently, and operator recovery across drift is a fresh run. The runtime's
  `graph_state_runtime_version_mismatch` barrier is exactly one instance of that decision. But 0011
  governs the _version_ predicate only; it says nothing about the _shape_ of persisted state that is
  resumable under a matching version, nor about rewrite-lineage replay.
- [ADR 0058](./0058-pulse-atomic-suspend-settlement.md) governs the atomic suspend transition that a
  recovered waiting run must re-enter, but it assumes the run has already been validated and
  classified for resume.

Meanwhile the proof track carries a recovery model. `theory/Cortex/Pulse/Recovery.lean` defines
`recoveredState G state = propagateFailure G (resetRunningToPending state)` and proves
`persistence_safety`: recovery yields a `wellFormedGraphState` **conditional on** four persisted
preconditions packaged as `PersistedRecoveryPreconditions` — topology-domain, output-ownership,
output-completeness, and causal-history closure. The proof is honest that those preconditions are
_trusted or validated_ at the boundary, not guaranteed by the kernel. Nothing in the runtime tied a
resume gate to that precondition shape, so the proof's hypotheses were an unenforced contract.

Resume also has to reconstruct topology. A rewrite-capable run mutates its own graph during
execution; the persisted graph state records an `applied_rewrite_id` watermark, and the durable
rewrite lineage (`pulse.graph_rewrites`) records every admitted step. Resume must replay that
lineage to rebuild the topology the run was last executing, and it must not let a mislabeled lineage
row reconstruct topology the live admission gate would have rejected.

## Decision

Graph-state-driven resume is a **typed total function of persisted state** with a fixed pipeline,
and recovery is gated by an executable **recovery-precondition algebra** that mirrors
`Recovery.lean`'s `PersistedRecoveryPreconditions`. `resumeFromPersistedState` runs, in order:

1. **Reconstruct topology from the watermark.** Read `pulse.graph_rewrites`; split the lineage at
   the persisted `pgssAppliedRewriteId` watermark into materialized rows (`rewriteId <= watermark`)
   and pending rows (post-watermark). Replay materialized rows to rebuild the topology;
   re-materialize pending rows.
2. **Re-authorize witnessed replay; re-admit gassed replay.** A witnessed self-append step
   (`AdmissionWitnessed`) replays gas-neutral but is re-run through the same authorization gate
   (`authorizeWitnessedReplayWithControl`) as the live path, so a mislabeled or invalid
   pre-watermark row cannot reconstruct unauthorized topology on resume. A gassed step
   (`AdmissionGassed`) is re-admitted against the reconstructed remaining budget.
3. **Enforce the version barrier (ADR 0011).** If the persisted runtime version is present and does
   not equal `spCheckpointRuntimeVersion`, fail with `graph_state_runtime_version_mismatch`. This is
   the 0011 barrier; resume never reads stale state under a mismatched version.
4. **Reconcile, then resolve delivered signals.** `reconcileGraphState` restores the map invariants
   the precondition validator depends on; `resolveDeliveredSignals` completes ordinary/run-terminal
   waits delivered while the run was parked, but deliberately leaves a reserved `external-call:`
   wake `NodeWaiting` (`isExternalCallSignal`) so suspend settlement re-arms it rather than
   completing it from the wake payload (ADR 0059).
5. **Validate recovery preconditions, then classify.** `recoverPersistedGraphState` validates the
   precondition algebra; on failure it returns the offending `RecoveryPreconditionError` set and
   resume fails with `graph_state_recovery_preconditions_failed`. On success it normalizes
   (`resetRunningToPending`) and classifies (`classifyGraphState`, which applies `propagateFailure`)
   into a `StepResult` — `Progressing` / `Settled` / `Suspended` / `Stuck`.

The recovery-precondition algebra (`recoveryPreconditionErrors`) is the runtime mirror of the four
Lean precondition fields:

| Persisted precondition (`Recovery.lean`) | Runtime error variant(s) (`RecoveryPreconditionError`)                                    |
| ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| `topologyDomain`                         | `RecoveryStatusOutsideTopology`, `RecoveryStatusMissing`, `RecoveryOutputOutsideTopology` |
| `outputsRespectStatuses`                 | `RecoveryOutputNotAllowed`                                                                |
| `outputsCompleteForStatuses`             | `RecoveryRequiredOutputMissing`                                                           |
| `causalHistoryClosed`                    | `RecoveryCausalHistoryOpen`                                                               |

The runtime is intentionally **stricter** than the proof: Lean's status/output functions are total,
so it has no "missing status" case, whereas the Haskell map representation requires every topology
node to carry an explicit persisted status entry (`RecoveryStatusMissing`). Reconciliation and
rewrite materialization restore those map invariants before the validator runs.

Every resume failure is **typed and non-silent**: each failure path emits an observability event,
calls `failRun` with a typed error string plus operator-facing message, and returns `OutcomeFailed`.
Resume never best-effort continues past a failed precondition.

## Mental Model

> Resume is **replay → re-authorize → reconcile → validate → classify**, all over persisted state.
> The watermark is the replay boundary; witnessed replay is re-checked, not trusted; the
> recovery-precondition algebra is the executable form of `Recovery.lean`'s hypotheses; and
> classification (which applies failure closure) is the only thing that decides the recovered
> frontier or terminal outcome. A precondition that does not hold is a typed run failure, not a
> guess.

## Boundary Rules

- **The watermark is the replay boundary.** `pgssAppliedRewriteId` partitions durable rewrite
  lineage into already-materialized topology and pending topology. Resume rebuilds topology by
  replaying the materialized prefix; it does not snapshot topology separately from its lineage.
- **Witnessed replay is re-authorized.** A pre-watermark `AdmissionWitnessed` row is replayed
  through the live authorization gate, not trusted because it is persisted. Gassed replay re-admits
  against the reconstructed budget. Replay therefore cannot reconstruct topology the admission
  contract would reject.
- **Preconditions are validated before classification.** `recoverPersistedGraphState` rejects
  off-topology status/output keys, missing status entries, outputs on non-payload statuses, missing
  required outputs, and successor-unblocking nodes with non-terminal strict ancestors — the four
  precondition classes of `PersistedRecoveryPreconditions` plus the stricter total-map check. Only a
  validated state is normalized and classified.
- **Normalization mirrors the proof split.** `normalizeForResume` performs `resetRunningToPending`
  only; `classifyGraphState` applies `propagateFailure`. Their composition is the runtime
  counterpart of Lean's `recoveredState`. The split is deliberate so recovery and live
  classification share one failure-closure path.
- **A recovered waiting run re-enters settlement (ADR 0058).** When classification yields
  `Suspended`, recovery routes through `settleSuspend`, which is idempotent for a run whose wait
  rows already exist; it does not bare-park. For a reserved `external-call:` wake, settlement
  re-arms the node to `NodePending` (`resumeFromWaiting`) and consumes the delivered row in the same
  transaction, so the bound `StageAction` re-runs and re-fetches the provider result —
  re-arm-on-wake, not completion-from-payload (ADR 0059). `Settled`/`Stuck`/`Progressing` route to
  their normal handlers.
- **Version drift is the 0011 barrier, not a recovery error.** A runtime-version mismatch fails as
  `graph_state_runtime_version_mismatch` before any precondition validation; it is
  operator-recovered by a fresh run under 0011, not by patching persisted state.

## Alternatives considered

- **Treat persisted graph state as already-valid and skip the precondition gate.** Rejected — it
  silently imports `Recovery.lean`'s hypotheses as assumptions. A corrupted or partially-written
  state (off-topology keys, an unblocking node with a non-terminal ancestor) would be classified
  into a frontier and re-executed against semantics the proof never covered.
- **Snapshot the materialized topology directly instead of replaying lineage from a watermark.**
  Rejected — it duplicates topology state that the durable rewrite lineage already determines, and
  it loses the re-authorization checkpoint: a snapshot cannot re-run admission, so a bad row becomes
  permanent topology. The watermark + lineage replay keeps one source of topology truth.
- **Trust witnessed pre-watermark rows as gas-neutral and authorized.** Rejected — "witnessed" is an
  admission _mode_, not a proof that the persisted row is well-formed; re-running the authorization
  gate is the only thing that stops a mislabeled lineage row from reconstructing unauthorized
  topology on resume.
- **Fold version drift into the recovery-precondition algebra.** Rejected — version compatibility is
  ADR 0011's separate decision with a distinct operator-recovery story (fresh run). Collapsing it
  into the precondition set would erase that boundary.

## Consequences

### Positive

- The hypotheses of `Recovery.lean`'s `persistence_safety` are enforced at the runtime boundary
  rather than assumed; an invalid persisted state is a typed, observable run failure.
- Resume is a deterministic function of persisted state: topology is reconstructed from durable
  lineage, and witnessed replay is re-authorized, so resume cannot manufacture topology the live
  gate would reject.
- The recovery path and the live classification path share one failure-closure step
  (`classifyGraphState` / `propagateFailure`), so there is a single recovered-frontier semantics.

### Negative

- The runtime precondition algebra is intentionally stricter than the proof (it adds the total-map
  `RecoveryStatusMissing` check), so the Haskell↔Lean correspondence is a deliberate mirror, not a
  mechanical extraction. The mapping must be maintained by hand when either side changes.
- Replaying the rewrite lineage on every resume re-runs admission/authorization work that the
  original execution already did; this is accepted as the cost of not trusting persisted topology.

### Obligations

- Keep `RecoveryPreconditionError`'s variants in correspondence with
  `PersistedRecoveryPreconditions`; a new Lean precondition field needs a runtime error class (or an
  explicit note that the runtime is stricter).
- Keep version-drift handling on the 0011 barrier (`graph_state_runtime_version_mismatch`), not in
  the recovery-precondition set.
- Keep witnessed pre-watermark replay routed through the live authorization gate; never
  short-circuit it because the row is persisted.
- Keep the `Suspended` recovery branch routed through `settleSuspend` (ADR 0058), not a bare park.
- Update [`proof-status.md`](../Reference/proof-status.md) (the "Pulse recovery envelope" row) if
  the Haskell correspondence surface for recovery changes.

## Traceability

- Feature keys: `pulse.resume_recovery`
- Public surface: `Cortex.Pulse`
- Implementation: `src/Cortex/Pulse/Executor/Resume.hs`, `src/Cortex/Pulse/GraphRuntime.hs`
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`
- Theory/proof: [Pulse recovery envelope row](../Reference/proof-status.md) (Lean
  `theory/Cortex/Pulse/Recovery.lean` — `persistence_safety`, `PersistedRecoveryPreconditions`)

## Related

- [ADR 0004 — Graph-Native Pulse Execution](./0004-graph-native-pulse-execution.md) — establishes
  that resume and recovery operate over graph state.
- [ADR 0011 — Compatibility Barriers and Fresh-Run Recovery](./0011-compatibility-barriers-and-fresh-run-recovery.md)
  — the version-drift barrier this ADR defers to, not duplicates.
- [ADR 0058 — Pulse Atomic Suspend Settlement](./0058-pulse-atomic-suspend-settlement.md) — the
  settlement a recovered waiting run re-enters.
- [ADR 0059 — Durable External-Call Frontiers on Pulse](./0059-durable-external-call-frontiers-on-pulse.md)
  — the reserved external-call wake whose re-arm-on-wake resolution a recovered waiting run drives
  through settlement.
- [Architecture 06 — Pulse Runtime](../Architecture/06-pulse-runtime.md#resume) — the resume
  narrative.
- [Cortex Proof Status](../Reference/proof-status.md) — the proof-status matrix the Theory cell
  links to.
