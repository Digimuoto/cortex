import Cortex.Pulse.Fact
import Cortex.Pulse.Validity

/-!
## Overview

Recovery first resets volatile execution state and then reapplies failure
closure. The theorem statements here are intentionally structural: they
prove the normalized-state pieces that do not depend on payload-specific
business semantics.

## Context

The runtime persists prefixes of execution state. After a crash, in-flight
work is reset and failure is reclosed before classification. This page is
the Lean counterpart of that recovery normalization pipeline.

## Theorem Split

The page defines the recovered state, proves each structural invariant,
and packages them into `persistence_safety` under persisted topology,
output, and causal-history invariants.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Recovery Operator -/

/-- `recoveredState G state` is crash-recovery normalization for the fixed-topology kernel. -/
noncomputable def recoveredState
    (G : DAG ν)
    (state : GraphState ν payload) : GraphState ν payload :=
  propagateFailure G (GraphState.resetRunningToPending state)

/-! ## Normalization Theorems -/

/-- `recovered_noRunning` proves recovery normalization removes running nodes. -/
theorem recovered_noRunning
    (G : DAG ν)
    (state : GraphState ν payload) :
    GraphState.noRunningNodes (recoveredState G state) := by
  exact
    propagateFailure_preserves_noRunning
      G
      (GraphState.resetRunningToPending state)
      (GraphState.resetRunning_no_running state)

/-- `recovered_topologyDomain` preserves the persisted topology-domain invariant. -/
theorem recovered_topologyDomain
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state) :
    GraphState.topologyDomain G (recoveredState G state) := by
  exact
    propagateFailure_preserves_topologyDomain
      G
      (GraphState.resetRunningToPending state)
      (GraphState.resetRunning_preserves_topologyDomain G state hDomain)

/-- `recovered_failureClosureComplete` proves recovery normalization is failure-closed. -/
theorem recovered_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) :
    failureClosureComplete G (recoveredState G state) := by
  exact propagateFailure_failureClosureComplete G (GraphState.resetRunningToPending state)

/-- `recovered_frontierExact` proves recovery normalization has an exact frontier. -/
theorem recovered_frontierExact
    (G : DAG ν)
    (state : GraphState ν payload) :
    frontierExact G (recoveredState G state) := by
  exact frontierExact_readyNodes G (recoveredState G state)

/-- `resetRunning_preserves_causalHistoryClosed` preserves causal history closure. -/
theorem resetRunning_preserves_causalHistoryClosed
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    CausalHistoryClosed G (GraphState.resetRunningToPending state) := by
  intro node hUnblocks predecessor hReach
  have hResetUnblocks :
      NodeStatus.unblocksSuccessors (GraphState.resetStatus (state.status node)) := by
    simpa [GraphState.resetRunningToPending] using hUnblocks
  have hOriginalUnblocks : NodeStatus.unblocksSuccessors (state.status node) :=
    GraphState.resetStatus_reflects_unblocks hResetUnblocks
  have hOriginalTerminal : NodeStatus.terminal (state.status predecessor) :=
    hCausal node hOriginalUnblocks predecessor hReach
  simpa [GraphState.resetRunningToPending] using
    GraphState.resetStatus_preserves_terminal hOriginalTerminal

/-- `propagateFailure_preserves_causalHistoryClosed` preserves causal history closure. -/
theorem propagateFailure_preserves_causalHistoryClosed
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    CausalHistoryClosed G (propagateFailure G state) := by
  classical
  intro node hUnblocks predecessor hReach
  have hOriginalUnblocks : NodeStatus.unblocksSuccessors (state.status node) := by
    by_cases hClosed :
      NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
    · simp
        [ propagateFailure
        , propagateStatus
        , NodeStatus.unblocksSuccessors
        , hClosed
        ] at hUnblocks
    · simpa [propagateFailure, propagateStatus, hClosed] using hUnblocks
  have hOriginalTerminal : NodeStatus.terminal (state.status predecessor) :=
    hCausal node hOriginalUnblocks predecessor hReach
  by_cases hClosed :
    NodeStatus.propagatable (state.status predecessor) ∧ hasFailedAncestor G state predecessor
  · simp [propagateFailure, propagateStatus, NodeStatus.terminal, hClosed]
  · simpa [propagateFailure, propagateStatus, hClosed] using hOriginalTerminal

/-- `recovered_causalHistoryClosed` preserves causal history through recovery. -/
theorem recovered_causalHistoryClosed
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    CausalHistoryClosed G (recoveredState G state) := by
  exact
    propagateFailure_preserves_causalHistoryClosed
      G
      (GraphState.resetRunningToPending state)
      (resetRunning_preserves_causalHistoryClosed G state hCausal)

/-- `recovered_outputsRespectStatuses` preserves output ownership through recovery. -/
theorem recovered_outputsRespectStatuses
    (G : DAG ν)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsRespectStatuses state) :
    GraphState.outputsRespectStatuses (recoveredState G state) := by
  exact
    propagateFailure_preserves_outputsRespectStatuses
      G
      (GraphState.resetRunningToPending state)
      (GraphState.resetRunning_preserves_outputsRespectStatuses state hOutputs)

/-! ## Structural Safety -/

/-- `persistence_safety` packages structural recovery safety.

Structural recovery safety is parameterized by persisted topology-domain,
payload/output, and causal-history invariants. Recovery then preserves
those invariants while establishing no-running, failure-closure, and
frontier-exactness facts. -/
theorem persistence_safety
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state)
    (hOutputs : GraphState.outputsRespectStatuses state)
    (hCausal : CausalHistoryClosed G state) :
    wellFormedGraphState G (recoveredState G state) := by
  exact
    ⟨ recovered_topologyDomain G state hDomain
    , recovered_outputsRespectStatuses G state hOutputs
    , recovered_noRunning G state
    , recovered_failureClosureComplete G state
    , recovered_causalHistoryClosed G state hCausal
    , recovered_frontierExact G state
    ⟩

end Cortex.Pulse
