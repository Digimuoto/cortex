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
topology, output-ownership, output-completeness, and causal-history
preconditions.
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
    GraphState.noRunningNodes (recoveredState G state) :=
  propagateFailure_preserves_noRunning
    G
    (GraphState.resetRunningToPending state)
    (GraphState.resetRunning_no_running state)

/-- `recovered_noInterrupted` proves recovery normalization removes interrupted nodes. -/
theorem recovered_noInterrupted
    (G : DAG ν)
    (state : GraphState ν payload) :
    GraphState.noInterruptedNodes (recoveredState G state) :=
  propagateFailure_preserves_noInterrupted
    G
    (GraphState.resetRunningToPending state)
    (GraphState.resetRunning_no_interrupted state)

/-- `recovered_topologyDomain` preserves the persisted topology-domain invariant. -/
theorem recovered_topologyDomain
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state) :
    GraphState.topologyDomain G (recoveredState G state) :=
  propagateFailure_preserves_topologyDomain
    G
    (GraphState.resetRunningToPending state)
    (GraphState.resetRunning_preserves_topologyDomain G state hDomain)

/-- `recovered_failureClosureComplete` proves recovery normalization is failure-closed. -/
theorem recovered_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) :
    failureClosureComplete G (recoveredState G state) :=
  propagateFailure_failureClosureComplete G (GraphState.resetRunningToPending state)

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
    CausalHistoryClosed G (recoveredState G state) :=
  propagateFailure_preserves_causalHistoryClosed
    G
    (GraphState.resetRunningToPending state)
    (resetRunning_preserves_causalHistoryClosed G state hCausal)

/-- `recovered_frontierBridge` proves recovery aligns proof and runtime frontiers. -/
theorem recovered_frontierBridge
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    frontierBridge G (recoveredState G state) :=
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
    GraphState.outputsRespectStatuses (recoveredState G state) :=
  propagateFailure_preserves_outputsRespectStatuses
    G
    (GraphState.resetRunningToPending state)
    (GraphState.resetRunning_preserves_outputsRespectStatuses state hOutputs)

/-- `recovered_outputsCompleteForStatuses` preserves required outputs through recovery. -/
theorem recovered_outputsCompleteForStatuses
    (G : DAG ν)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsCompleteForStatuses state) :
    GraphState.outputsCompleteForStatuses (recoveredState G state) :=
  propagateFailure_preserves_outputsCompleteForStatuses
    G
    (GraphState.resetRunningToPending state)
    (GraphState.resetRunning_preserves_outputsCompleteForStatuses state hOutputs)

/-! ## Structural Safety -/

/-- `PersistedRecoveryPreconditions G state` is what recovery must trust or validate. -/
structure PersistedRecoveryPreconditions
    (G : DAG ν)
    (state : GraphState ν payload) : Prop where
  /-- Persisted state has no status/output entries outside the topology. -/
  topologyDomain : GraphState.topologyDomain G state
  /-- Persisted outputs are attached only to statuses that may own payloads. -/
  outputsRespectStatuses : GraphState.outputsRespectStatuses state
  /-- Persisted payload-owning statuses have their required outputs present. -/
  outputsCompleteForStatuses : GraphState.outputsCompleteForStatuses state
  /-- Persisted terminal/unblocking history is causally closed. -/
  causalHistoryClosed : CausalHistoryClosed G state

/-- `persistedRecoveryPreconditions G state` keeps the published predicate name stable. -/
abbrev persistedRecoveryPreconditions
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  PersistedRecoveryPreconditions G state

/-- `persistence_safety` packages structural recovery safety.

Structural recovery safety is conditional on persisted topology-domain,
payload/output, output-completeness, and causal-history preconditions.
Recovery then preserves those preconditions while establishing
no-running, no-interrupted, failure-closure, and the proof/runtime
frontier bridge. -/
theorem persistence_safety
    (G : DAG ν)
    (state : GraphState ν payload)
    (hPersisted : persistedRecoveryPreconditions G state) :
    wellFormedGraphState G (recoveredState G state) := by
  exact
    { topologyDomain := recovered_topologyDomain G state hPersisted.topologyDomain
      outputsRespectStatuses :=
        recovered_outputsRespectStatuses G state hPersisted.outputsRespectStatuses
      outputsCompleteForStatuses :=
        recovered_outputsCompleteForStatuses G state hPersisted.outputsCompleteForStatuses
      noRunningNodes := recovered_noRunning G state
      noInterruptedNodes := recovered_noInterrupted G state
      failureClosureComplete := recovered_failureClosureComplete G state
      causalHistoryClosed := recovered_causalHistoryClosed G state hPersisted.causalHistoryClosed
      frontierBridge := recovered_frontierBridge G state hPersisted.causalHistoryClosed }

/-- `frontierFacts_recovered_wellFormedGraphState` safely recovers admissible fact folds. -/
theorem frontierFacts_recovered_wellFormedGraphState [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    (results : List (NodeResult ν payload))
    (hWellFormed : wellFormedGraphState G state)
    (hResults : NodeResult.AllAdmissibleFold G state results) :
    wellFormedGraphState G (recoveredState G (NodeResult.applyNodeFacts results state)) := by
  have hAccumulatedDomain :
      GraphState.topologyDomain G (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_topologyDomain
      G
      results
      state
      hWellFormed.topologyDomain
      hResults
  have hAccumulatedOutputs :
      GraphState.outputsRespectStatuses (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_outputsRespectStatuses
      G
      results
      state
      hWellFormed.outputsRespectStatuses
      hResults
  have hAccumulatedOutputsComplete :
      GraphState.outputsCompleteForStatuses (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_outputsCompleteForStatuses
      G
      results
      state
      hWellFormed.outputsCompleteForStatuses
      hResults
  have hAccumulatedCausal :
      CausalHistoryClosed G (NodeResult.applyNodeFacts results state) :=
    NodeResult.applyNodeFacts_preserves_causalHistoryClosed
      G
      results
      state
      hWellFormed.causalHistoryClosed
      hResults
  have hPersisted :
      persistedRecoveryPreconditions G (NodeResult.applyNodeFacts results state) :=
    { topologyDomain := hAccumulatedDomain
      outputsRespectStatuses := hAccumulatedOutputs
      outputsCompleteForStatuses := hAccumulatedOutputsComplete
      causalHistoryClosed := hAccumulatedCausal }
  exact persistence_safety G (NodeResult.applyNodeFacts results state) hPersisted

end Cortex.Pulse
