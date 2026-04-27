/-
# Pulse Kernel — Failure Closure

Failure closure propagates failed status through the fixed topology while
leaving terminal successes and skipped/rewritten nodes intact. This is
the structural part of the runtime's `propagateFailure`: it says nothing
about failure payloads, retry policy, or operator-facing diagnostics.
-/

import Cortex.Pulse.Frontier

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-- A node has a strict failed ancestor in the current state. -/
def hasFailedAncestor
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) : Prop :=
  ∃ failedNode : ν,
    state.status failedNode = NodeStatus.failed ∧ G.reaches failedNode node

/-- A state is failure-closed when propagatable descendants of failed nodes
are already marked failed. -/
def failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ failedNode node : ν,
    state.status failedNode = NodeStatus.failed →
      G.reaches failedNode node →
        NodeStatus.propagatable (state.status node) →
          state.status node = NodeStatus.failed

/-- Status update performed by failure closure at a single node. -/
noncomputable def propagateStatus
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) : NodeStatus := by
  classical
  exact
    if NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node then
      NodeStatus.failed
    else
      state.status node

/-- Propagate failure to all pending or waiting descendants of failed nodes. -/
noncomputable def propagateFailure
    (G : DAG ν)
    (state : GraphState ν payload) : GraphState ν payload where
  status := fun node => propagateStatus G state node
  output := state.output

/-- Existing failed nodes remain failed after propagation. -/
theorem propagateFailure_preserves_failed
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hFailed : state.status node = NodeStatus.failed) :
    (propagateFailure G state).status node = NodeStatus.failed := by
  classical
  simp [propagateFailure, propagateStatus, hFailed, NodeStatus.propagatable]

/-- Propagation marks propagatable descendants of failed nodes as failed. -/
theorem propagateFailure_marks_failed_descendant
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hPropagatable : NodeStatus.propagatable (state.status node))
    (hAncestor : hasFailedAncestor G state node) :
    (propagateFailure G state).status node = NodeStatus.failed := by
  classical
  simp [propagateFailure, propagateStatus, hPropagatable, hAncestor]

/-- If propagation leaves a node propagatable, it was propagatable before. -/
theorem propagatable_of_propagate
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hPropagatable :
      NodeStatus.propagatable ((propagateFailure G state).status node)) :
    NodeStatus.propagatable (state.status node) := by
  classical
  by_cases hClosed :
    NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
  · exact hClosed.1
  · simpa [propagateFailure, propagateStatus, hClosed] using hPropagatable

/-- Every failed node after propagation either was failed already or had an
original failed ancestor. -/
theorem failed_after_propagate
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hFailed : (propagateFailure G state).status node = NodeStatus.failed) :
    state.status node = NodeStatus.failed ∨ hasFailedAncestor G state node := by
  classical
  by_cases hClosed :
    NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
  · exact Or.inr hClosed.2
  · have hOriginal : state.status node = NodeStatus.failed := by
      simpa [propagateFailure, propagateStatus, hClosed] using hFailed
    exact Or.inl hOriginal

/-- A failed node produced by propagation still traces back to an original
failed ancestor for every descendant it reaches. -/
theorem hasFailedAncestor_of_failed_after_reaches
    (G : DAG ν)
    (state : GraphState ν payload)
    {failedNode node : ν}
    (hFailed : (propagateFailure G state).status failedNode = NodeStatus.failed)
    (hReach : G.reaches failedNode node) :
    hasFailedAncestor G state node := by
  rcases failed_after_propagate G state hFailed with hOriginalFailed | hAncestor
  · exact ⟨failedNode, hOriginalFailed, hReach⟩
  · rcases hAncestor with ⟨root, hRootFailed, hRootReach⟩
    exact ⟨root, hRootFailed, G.reaches_trans hRootReach hReach⟩

/-- Failure propagation is extensive over the failed-node set. -/
theorem propagateFailure_extensive
    (G : DAG ν)
    (state : GraphState ν payload) :
    ∀ node : ν,
      state.status node = NodeStatus.failed →
        (propagateFailure G state).status node = NodeStatus.failed := by
  intro node hFailed
  exact propagateFailure_preserves_failed G state hFailed

/-- Failure propagation produces a failure-closed state. -/
theorem propagateFailure_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) :
    failureClosureComplete G (propagateFailure G state) := by
  intro failedNode node hFailed hReach hPropagatable
  have hAncestor : hasFailedAncestor G state node :=
    hasFailedAncestor_of_failed_after_reaches G state hFailed hReach
  have hOriginalPropagatable : NodeStatus.propagatable (state.status node) :=
    propagatable_of_propagate G state hPropagatable
  exact propagateFailure_marks_failed_descendant G state hOriginalPropagatable hAncestor

/-- Failure propagation preserves the absence of running nodes. -/
theorem propagateFailure_preserves_noRunning
    (G : DAG ν)
    (state : GraphState ν payload)
    (hNoRunning : GraphState.noRunningNodes state) :
    GraphState.noRunningNodes (propagateFailure G state) := by
  classical
  intro node
  by_cases hClosed :
    NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
  · intro hRunning
    simp [propagateFailure, propagateStatus, hClosed] at hRunning
  · simpa [propagateFailure, propagateStatus, hClosed] using hNoRunning node

/-- A failure-closed state is a fixed point of failure propagation. -/
theorem propagateFailure_of_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload)
    (hComplete : failureClosureComplete G state) :
    propagateFailure G state = state := by
  classical
  ext node
  · by_cases hClosed :
      NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
    · rcases hClosed.2 with ⟨failedNode, hFailed, hReach⟩
      have hNodeFailed : state.status node = NodeStatus.failed :=
        hComplete failedNode node hFailed hReach hClosed.1
      simp [propagateFailure, propagateStatus, hClosed, hNodeFailed]
    · simp [propagateFailure, propagateStatus, hClosed]
  · simp [propagateFailure]

/-- Failure propagation is idempotent. -/
theorem propagateFailure_idempotent
    (G : DAG ν)
    (state : GraphState ν payload) :
    propagateFailure G (propagateFailure G state) = propagateFailure G state := by
  exact
    propagateFailure_of_failureClosureComplete
      G
      (propagateFailure G state)
      (propagateFailure_failureClosureComplete G state)

end Cortex.Pulse
