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
and packages them into `persistence_safety` under the persisted-domain and
remaining abstract payload/output assumptions.
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

/-! ## Structural Safety -/

/-- `persistence_safety` packages structural recovery safety.

Structural recovery safety is parameterized by the persisted topology-domain
invariant and the payload/output invariant.

The remaining assumption is exactly the part this abstract kernel cannot
derive without payload semantics: outputs must still be attached only to
statuses that may carry outputs after recovery normalization. -/
theorem persistence_safety
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state)
    (hOutputs : GraphState.outputsRespectStatuses (recoveredState G state)) :
    wellFormedGraphState G (recoveredState G state) := by
  exact
    ⟨ recovered_topologyDomain G state hDomain
    , hOutputs
    , recovered_noRunning G state
    , recovered_failureClosureComplete G state
    , recovered_frontierExact G state
    ⟩

end Cortex.Pulse
