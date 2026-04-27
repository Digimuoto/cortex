/-
# Pulse Kernel — Recovery Normalization

Recovery first resets volatile execution state and then reapplies failure
closure. The theorem statements here are intentionally structural: they
prove the normalized-state pieces that do not depend on payload-specific
business semantics.
-/

import Cortex.Pulse.Fact
import Cortex.Pulse.Validity

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-- Crash-recovery normalization for the fixed-topology kernel. -/
noncomputable def recoveredState
    (G : DAG ν)
    (state : GraphState ν payload) : GraphState ν payload :=
  propagateFailure G (GraphState.resetRunningToPending state)

/-- Recovery normalization removes running nodes. -/
theorem recovered_noRunning
    (G : DAG ν)
    (state : GraphState ν payload) :
    GraphState.noRunningNodes (recoveredState G state) := by
  exact
    propagateFailure_preserves_noRunning
      G
      (GraphState.resetRunningToPending state)
      (GraphState.resetRunning_no_running state)

/-- Recovery normalization produces a failure-closed state. -/
theorem recovered_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) :
    failureClosureComplete G (recoveredState G state) := by
  exact propagateFailure_failureClosureComplete G (GraphState.resetRunningToPending state)

/-- Recovery normalization has an exact frontier for `Ready`. -/
theorem recovered_frontierExact
    (G : DAG ν)
    (state : GraphState ν payload) :
    frontierExact G (recoveredState G state) := by
  exact frontierExact_readyNodes G (recoveredState G state)

/-- Structural recovery safety, parameterized by the payload invariant.

The remaining assumption is exactly the part this abstract kernel cannot
derive without payload semantics: outputs must still be attached only to
statuses that may carry outputs after recovery normalization. -/
theorem persistence_safety
    (G : DAG ν)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsRespectStatuses (recoveredState G state)) :
    wellFormedGraphState G (recoveredState G state) := by
  exact
    ⟨ hOutputs
    , recovered_noRunning G state
    , recovered_failureClosureComplete G state
    , recovered_frontierExact G state
    ⟩

end Cortex.Pulse
