import Cortex.Pulse.Frontier

/-!
## Overview

Failure closure propagates failed status through the fixed topology while
leaving terminal successes and skipped/rewritten nodes intact. This is
the structural part of the runtime's `propagateFailure`: it says nothing
about failure payloads, retry policy, or operator-facing diagnostics.

## Context

The closure operator is the main Paper 1 recovery law: once a node fails,
every still-propagatable descendant must fail too. The model keeps the
operator extensional and proves the closure/fixed-point facts needed by
recovery.

## Theorem Split

The page defines failed ancestors, defines the closure operator, proves
that one pass is failure-complete, and finishes with idempotence.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Failed-Ancestor Model -/

/-- `hasFailedAncestor G state node` means the node has a strict failed ancestor. -/
def hasFailedAncestor
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) : Prop :=
  ∃ failedNode : ν,
    state.status failedNode = NodeStatus.failed ∧ G.reaches failedNode node

/-- `failureClosureComplete G state` means failure is closed over propagatable descendants.

A state is failure-closed when propagatable descendants of failed nodes
are already marked failed. -/
def failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ failedNode node : ν,
    state.status failedNode = NodeStatus.failed →
      G.reaches failedNode node →
        NodeStatus.propagatable (state.status node) →
          state.status node = NodeStatus.failed

/-! ## Closure Operator -/

/-- `propagateStatus G state node` is the single-node failure-closure status update. -/
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

/-- `propagateFailure G state` propagates failure to pending or waiting descendants. -/
noncomputable def propagateFailure
    (G : DAG ν)
    (state : GraphState ν payload) : GraphState ν payload where
  status := fun node => propagateStatus G state node
  output := state.output

/-! ## Closure Facts -/

/-- `propagateFailure_preserves_failed` shows existing failed nodes stay failed. -/
theorem propagateFailure_preserves_failed
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hFailed : state.status node = NodeStatus.failed) :
    (propagateFailure G state).status node = NodeStatus.failed := by
  classical
  simp [propagateFailure, propagateStatus, hFailed, NodeStatus.propagatable]

/-- `propagateFailure_marks_failed_descendant` marks propagatable failed descendants. -/
theorem propagateFailure_marks_failed_descendant
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hPropagatable : NodeStatus.propagatable (state.status node))
    (hAncestor : hasFailedAncestor G state node) :
    (propagateFailure G state).status node = NodeStatus.failed := by
  classical
  simp [propagateFailure, propagateStatus, hPropagatable, hAncestor]

/-- `propagatable_of_propagate` recovers original propagatability after propagation. -/
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

/-- `failed_after_propagate_origin` identifies why a node is failed after propagation.

Every failed node after propagation either was failed already or had an
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

/-- `failed_after_propagate_has_original_failed_ancestor` traces propagated failures.

A failed node produced by propagation still traces back to an original
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

/-- `propagateFailure_extensive` proves propagation is extensive over failed nodes. -/
theorem propagateFailure_extensive
    (G : DAG ν)
    (state : GraphState ν payload) :
    ∀ node : ν,
      state.status node = NodeStatus.failed →
        (propagateFailure G state).status node = NodeStatus.failed := by
  intro node hFailed
  exact propagateFailure_preserves_failed G state hFailed

/-- `propagateFailure_failureClosureComplete` proves propagation reaches closure. -/
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

/-! ## Normalization Preservation -/

/-- `propagateFailure_preserves_noRunning` preserves the absence of running nodes. -/
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

/-- `propagateFailure_preserves_topologyDomain` preserves off-topology absence. -/
theorem propagateFailure_preserves_topologyDomain
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state) :
    GraphState.topologyDomain G (propagateFailure G state) := by
  classical
  intro node hNotMem
  rcases hDomain node hNotMem with ⟨hStatus, hOutput⟩
  have hNoAncestor : ¬ hasFailedAncestor G state node := by
    intro hAncestor
    rcases hAncestor with ⟨_failedNode, _hFailed, hReach⟩
    exact hNotMem (G.reaches_target_mem hReach)
  constructor
  · simp [propagateFailure, propagateStatus, hStatus, hNoAncestor]
  · simpa [propagateFailure] using hOutput

/-- `propagateFailure_preserves_outputsRespectStatuses` preserves output ownership. -/
theorem propagateFailure_preserves_outputsRespectStatuses
    (G : DAG ν)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsRespectStatuses state) :
    GraphState.outputsRespectStatuses (propagateFailure G state) := by
  classical
  intro node value hOutput
  by_cases hClosed :
    NodeStatus.propagatable (state.status node) ∧ hasFailedAncestor G state node
  · have hMayHaveOutput : NodeStatus.mayHaveOutput (state.status node) :=
      hOutputs node value hOutput
    cases hStatus : state.status node <;>
      simp
        [ NodeStatus.propagatable
        , NodeStatus.mayHaveOutput
        , hClosed
        , hStatus
        ] at hClosed hMayHaveOutput ⊢
  · simpa [propagateFailure, propagateStatus, hClosed] using hOutputs node value hOutput

/-! ## Idempotence -/

/-- `propagateFailure_of_failureClosureComplete` makes failure-closed states fixed points. -/
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

/-- `propagateFailure_idempotent` proves failure propagation is idempotent. -/
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
