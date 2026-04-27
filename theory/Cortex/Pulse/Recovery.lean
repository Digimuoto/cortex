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
and packages them into `persistence_safety` under explicit persisted
topology, output, and causal-history preconditions.
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

/-- `recovered_frontierBridge` proves recovery aligns proof and runtime frontiers. -/
theorem recovered_frontierBridge
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    frontierBridge G (recoveredState G state) := by
  exact
    frontierBridge_of_closed_causal
      G
      (recoveredState G state)
      (recovered_failureClosureComplete G state)
      (recovered_causalHistoryClosed G state hCausal)

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

/-- `persistedRecoveryPreconditions G state` is what recovery must trust or validate. -/
def persistedRecoveryPreconditions
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  GraphState.topologyDomain G state ∧
    GraphState.outputsRespectStatuses state ∧ CausalHistoryClosed G state

/-- `persistence_safety` packages structural recovery safety.

Structural recovery safety is conditional on persisted topology-domain,
payload/output, and causal-history preconditions. Recovery then preserves
those preconditions while establishing no-running, failure-closure, and
the proof/runtime frontier bridge. -/
theorem persistence_safety
    (G : DAG ν)
    (state : GraphState ν payload)
    (hPersisted : persistedRecoveryPreconditions G state) :
    wellFormedGraphState G (recoveredState G state) := by
  rcases hPersisted with ⟨hDomain, hOutputs, hCausal⟩
  exact
    ⟨ recovered_topologyDomain G state hDomain
    , recovered_outputsRespectStatuses G state hOutputs
    , recovered_noRunning G state
    , recovered_failureClosureComplete G state
    , recovered_causalHistoryClosed G state hCausal
    , recovered_frontierBridge G state hCausal
    ⟩

/-- `frontierFacts_recovered_wellFormedGraphState` safely re-closes admissible fact folds. -/
theorem frontierFacts_recovered_wellFormedGraphState [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    (results : List (NodeResult ν payload))
    (hWellFormed : wellFormedGraphState G state)
    (hResults : NodeResult.AllAdmissibleFold G state results) :
    wellFormedGraphState G (propagateFailure G (NodeResult.applyNodeFacts results state)) := by
  rcases hWellFormed with
    ⟨hDomain, hOutputs, hNoRunning, _hClosure, hCausal, _hBridge⟩
  have hAccumulatedDomain :
      GraphState.topologyDomain G (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_topologyDomain G results state hDomain hResults
  have hAccumulatedOutputs :
      GraphState.outputsRespectStatuses (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_outputsRespectStatuses G results state hOutputs hResults
  have hAccumulatedNoRunning :
      GraphState.noRunningNodes (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_noRunning G results state hNoRunning hResults
  have hAccumulatedCausal :
      CausalHistoryClosed G (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_causalHistoryClosed G results state hCausal hResults
  have hFinalClosure :
      failureClosureComplete G
        (propagateFailure G (NodeResult.applyNodeFacts results state)) :=
    propagateFailure_failureClosureComplete G (NodeResult.applyNodeFacts results state)
  have hFinalCausal :
      CausalHistoryClosed G
        (propagateFailure G (NodeResult.applyNodeFacts results state)) :=
    propagateFailure_preserves_causalHistoryClosed
      G
      (NodeResult.applyNodeFacts results state)
      hAccumulatedCausal
  exact
    ⟨ propagateFailure_preserves_topologyDomain
        G
        (NodeResult.applyNodeFacts results state)
        hAccumulatedDomain
    , propagateFailure_preserves_outputsRespectStatuses
        G
        (NodeResult.applyNodeFacts results state)
        hAccumulatedOutputs
    , propagateFailure_preserves_noRunning
        G
        (NodeResult.applyNodeFacts results state)
        hAccumulatedNoRunning
    , hFinalClosure
    , hFinalCausal
    , frontierBridge_of_closed_causal
        G
        (propagateFailure G (NodeResult.applyNodeFacts results state))
        hFinalClosure
        hFinalCausal
    ⟩

end Cortex.Pulse
