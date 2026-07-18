import Cortex.Pulse.Validity

/-!
## Overview

Classification is the final pure phase of the fixed-topology Pulse
kernel: accumulated facts are closed under failure propagation and then
classified into a lifecycle decision. This module models the structural
decision surface while keeping runtime diagnostics and payload details
abstract.

## Context

The Haskell runtime classifies by first applying `propagateFailure`, then
checking for failed nodes, a nonempty executable frontier, completed
settlement, suspension, and finally stuck diagnostics. Lean keeps that
precedence for topology-valid states and states the theorem-level surface
against `wellFormedGraphState`, where the stuck branch is impossible.

## Theorem Split

The page defines classification predicates, the closed-state classifier,
the closure-wrapping classifier, branch equations, and the
well-formed-state exhaustiveness theorem.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Classification Surface -/

/-- `RunOutcome` is the structural terminal outcome visible to the proof. -/
inductive RunOutcome : Type where
  | completed : RunOutcome
  | failed : RunOutcome
  deriving Repr, DecidableEq

/-- `StepResult` is the pure classification result for a graph state.

The runtime `StuckDiagnostic` payload is intentionally erased: the Lean
classification theorem only needs to prove that the stuck constructor is
unreachable for well-formed structural states. -/
inductive StepResult (ν : Type u) (payload : Type v) :
    Type (max (u + 1) (v + 1)) where
  | progressing : GraphState ν payload → Finset ν → StepResult ν payload
  | settled : GraphState ν payload → RunOutcome → StepResult ν payload
  | suspended : GraphState ν payload → StepResult ν payload
  | stuck : GraphState ν payload → StepResult ν payload

/-- `pendingNodes G state` is the topology-scoped pending-node set. -/
def pendingNodes (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : Finset ν :=
  G.nodes.filter fun node => state.status node = NodeStatus.pending

/-- `hasFailedNodes G state` checks for a failed node in the topology. -/
def hasFailedNodes
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∃ node : ν, node ∈ G.nodes ∧ state.status node = NodeStatus.failed

/-- `hasFailedNodesDecidable` decides topology-scoped failure by a finite scan. -/
def hasFailedNodesDecidable (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : Decidable (hasFailedNodes G state) := by
  unfold hasFailedNodes
  infer_instance

/-- `allSettled G state` says every topology node is terminal. -/
def allSettled
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ node : ν, node ∈ G.nodes → NodeStatus.terminal (state.status node)

/-- `allSettledDecidable` decides topology settlement by a finite scan. -/
def allSettledDecidable (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : Decidable (allSettled G state) := by
  unfold allSettled
  infer_instance

/-- `hasWaitingNodes G state` checks for topology-scoped waiting nodes.

Runtime correspondence for this predicate is intended under
`GraphState.topologyDomain`, where off-topology statuses are normalized to
`pending`. -/
def hasWaitingNodes
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∃ node : ν, node ∈ G.nodes ∧ state.status node = NodeStatus.waiting

/-- `hasWaitingNodesDecidable` decides topology-scoped waiting by a finite scan. -/
def hasWaitingNodesDecidable (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : Decidable (hasWaitingNodes G state) := by
  unfold hasWaitingNodes
  infer_instance

/-- `hasAmbientWaitingNodes state` models a raw status-map scan for waiting statuses. -/
def hasAmbientWaitingNodes
    (state : GraphState ν payload) : Prop :=
  ∃ node : ν, state.status node = NodeStatus.waiting

/-- Topology-domain validity bridges topology-scoped and ambient waiting checks. -/
theorem hasWaitingNodes_iff_hasAmbientWaitingNodes_of_topologyDomain
    (G : DAG ν)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state) :
    hasWaitingNodes G state ↔ hasAmbientWaitingNodes state := by
  constructor
  · intro hWaiting
    rcases hWaiting with ⟨node, _hNode, hStatus⟩
    exact ⟨node, hStatus⟩
  · intro hWaiting
    rcases hWaiting with ⟨node, hStatus⟩
    by_cases hNode : node ∈ G.nodes
    · exact ⟨node, hNode, hStatus⟩
    · have hPending : state.status node = NodeStatus.pending :=
        (hDomain node hNode).1
      rw [hPending] at hStatus
      cases hStatus

/-! ## Classifier -/

/-- `classifyClosedGraphState G state` classifies a topology-valid failure-closed state. -/
def classifyClosedGraphState (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : StepResult ν payload := by
  letI : Decidable (hasFailedNodes G state) := hasFailedNodesDecidable G state
  letI : Decidable (allSettled G state) := allSettledDecidable G state
  letI : Decidable (hasWaitingNodes G state) := hasWaitingNodesDecidable G state
  exact
    if hasFailedNodes G state then
      StepResult.settled state RunOutcome.failed
    else if (directReadyNodes G state).Nonempty then
      StepResult.progressing state (directReadyNodes G state)
    else if allSettled G state then
      StepResult.settled state RunOutcome.completed
    else if hasWaitingNodes G state then
      StepResult.suspended state
    else
      StepResult.stuck state

/-- `classifyGraphState G state` is the topology-scoped classifier after failure closure. -/
def classifyGraphState
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload) : StepResult ν payload :=
  classifyClosedGraphState G (propagateFailure G state)

/-! ## Branch Equations -/

/-- Failed nodes take classification precedence over all other branches. -/
theorem classifyClosedGraphState_failed
    (G : DAG ν)
    [DecidableEq ν]
    (state : GraphState ν payload)
    (hFailed : hasFailedNodes G state) :
    classifyClosedGraphState G state = StepResult.settled state RunOutcome.failed := by
  classical
  simp [classifyClosedGraphState, hFailed]

/-- A nonempty frontier progresses when no failed node is present. -/
theorem classifyClosedGraphState_progressing
    (G : DAG ν)
    [DecidableEq ν]
    (state : GraphState ν payload)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hFrontier : (directReadyNodes G state).Nonempty) :
    classifyClosedGraphState G state =
      StepResult.progressing state (directReadyNodes G state) := by
  classical
  simp [classifyClosedGraphState, hNoFailed, hFrontier]

/-- Settled completion applies after failed and frontier branches are absent. -/
theorem classifyClosedGraphState_settled_completed
    (G : DAG ν)
    [DecidableEq ν]
    (state : GraphState ν payload)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNoFrontier : ¬ (directReadyNodes G state).Nonempty)
    (hSettled : allSettled G state) :
    classifyClosedGraphState G state =
      StepResult.settled state RunOutcome.completed := by
  classical
  simp [classifyClosedGraphState, hNoFailed, hNoFrontier, hSettled]

/-- Suspension applies when no earlier branch fires and a topology node is waiting. -/
theorem classifyClosedGraphState_suspended
    (G : DAG ν)
    [DecidableEq ν]
    (state : GraphState ν payload)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNoFrontier : ¬ (directReadyNodes G state).Nonempty)
    (hNotSettled : ¬ allSettled G state)
    (hWaiting : hasWaitingNodes G state) :
    classifyClosedGraphState G state = StepResult.suspended state := by
  classical
  simp [classifyClosedGraphState, hNoFailed, hNoFrontier, hNotSettled, hWaiting]

/-- The stuck branch records the structural complement of the earlier branches. -/
theorem classifyClosedGraphState_stuck
    (G : DAG ν)
    [DecidableEq ν]
    (state : GraphState ν payload)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNoFrontier : ¬ (directReadyNodes G state).Nonempty)
    (hNotSettled : ¬ allSettled G state)
    (hNoWaiting : ¬ hasWaitingNodes G state) :
    classifyClosedGraphState G state = StepResult.stuck state := by
  classical
  simp [classifyClosedGraphState, hNoFailed, hNoFrontier, hNotSettled, hNoWaiting]

/-! ## Well-Formed Classification -/

/-- `ClassificationNormalized state` is the minimal volatile-state bundle for classification.

The minimal-pending-node argument only needs running and interrupted
statuses to be absent; topology, output, closure, and frontier-bridge
facts enter later correspondence theorems. -/
structure ClassificationNormalized
    (state : GraphState ν payload) : Prop where
  /-- No node is still in the active runtime state. -/
  noRunningNodes : GraphState.noRunningNodes state
  /-- No node still carries an interrupted runtime marker. -/
  noInterruptedNodes : GraphState.noInterruptedNodes state

/-- Well-formed graph states are classification-normalized. -/
theorem classificationNormalized_of_wellFormed
    (G : DAG ν)
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state) :
    ClassificationNormalized state :=
  { noRunningNodes := hWellFormed.noRunningNodes
    noInterruptedNodes := hWellFormed.noInterruptedNodes }

/-- Nonterminal topology nodes are pending under normalized, nonfailed, nonwaiting validity. -/
theorem status_eq_pending_of_not_terminal
    (G : DAG ν)
    (state : GraphState ν payload)
    (hNormalized : ClassificationNormalized state)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNoWaiting : ¬ hasWaitingNodes G state)
    {node : ν}
    (hNode : node ∈ G.nodes)
    (hNotTerminal : ¬ NodeStatus.terminal (state.status node)) :
    state.status node = NodeStatus.pending := by
  cases hStatus : state.status node
  · rfl
  · exact False.elim (hNormalized.noRunningNodes node hStatus)
  · exact False.elim (hNotTerminal (by simp [hStatus, NodeStatus.terminal]))
  · exact False.elim (hNoFailed ⟨node, hNode, hStatus⟩)
  · exact False.elim (hNotTerminal (by simp [hStatus, NodeStatus.terminal]))
  · exact False.elim (hNormalized.noInterruptedNodes node hStatus)
  · exact False.elim (hNoWaiting ⟨node, hNode, hStatus⟩)
  · exact False.elim (hNotTerminal (by simp [hStatus, NodeStatus.terminal]))

/-- A normalized nonfailed, nonsettled, nonwaiting state has a proof frontier. -/
theorem readyNodes_nonempty_of_normalized
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hNormalized : ClassificationNormalized state)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNotSettled : ¬ allSettled G state)
    (hNoWaiting : ¬ hasWaitingNodes G state) :
    (readyNodes G state).Nonempty := by
  classical
  have hExistsNonterminal :
      ∃ node : ν, node ∈ G.nodes ∧ ¬ NodeStatus.terminal (state.status node) := by
    by_contra hNone
    apply hNotSettled
    intro node hNode
    by_contra hNotTerminal
    exact hNone ⟨node, hNode, hNotTerminal⟩
  rcases hExistsNonterminal with ⟨seed, hSeedMem, hSeedNotTerminal⟩
  have hSeedPending : state.status seed = NodeStatus.pending :=
    status_eq_pending_of_not_terminal
      G
      state
      hNormalized
      hNoFailed
      hNoWaiting
      hSeedMem
      hSeedNotTerminal
  have hPendingNonempty : (pendingNodes G state).Nonempty := by
    exact ⟨seed, by simp [pendingNodes, hSeedMem, hSeedPending]⟩
  rcases G.exists_reaches_minimal (pendingNodes G state) hPendingNonempty with
    ⟨node, hNodePending, hMinimal⟩
  have hPendingInfo :
      node ∈ G.nodes ∧ state.status node = NodeStatus.pending := by
    simpa [pendingNodes] using hNodePending
  have hReady : Ready G state node := by
    constructor
    · exact hPendingInfo.1
    constructor
    · exact hPendingInfo.2
    · intro predecessor hReach
      by_contra hPredecessorNotTerminal
      have hPredecessorMem : predecessor ∈ G.nodes :=
        G.reaches_source_mem hReach
      have hPredecessorPendingStatus :
          state.status predecessor = NodeStatus.pending :=
        status_eq_pending_of_not_terminal
          G
          state
          hNormalized
          hNoFailed
          hNoWaiting
          hPredecessorMem
          hPredecessorNotTerminal
      have hPredecessorPending : predecessor ∈ pendingNodes G state := by
        simp [pendingNodes, hPredecessorMem, hPredecessorPendingStatus]
      exact hMinimal predecessor hPredecessorPending hReach
  exact ⟨node, (mem_readyNodes G state node).mpr ⟨hPendingInfo.1, hReady⟩⟩

/-- A well-formed nonfailed, nonsettled, nonwaiting state has a runtime frontier. -/
theorem directReadyNodes_nonempty_of_wellFormed
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state)
    (hNoFailed : ¬ hasFailedNodes G state)
    (hNotSettled : ¬ allSettled G state)
    (hNoWaiting : ¬ hasWaitingNodes G state) :
    (directReadyNodes G state).Nonempty := by
  rw [← hWellFormed.readyNodes_eq_directReadyNodes G state]
  exact
    readyNodes_nonempty_of_normalized
      G
      state
      (classificationNormalized_of_wellFormed G state hWellFormed)
      hNoFailed
      hNotSettled
      hNoWaiting

/-- Well-formed closed states classify into one of the non-stuck branches. -/
theorem classifyClosedGraphState_exhaustive_of_wellFormed
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state) :
    (hasFailedNodes G state ∧
        classifyClosedGraphState G state = StepResult.settled state RunOutcome.failed) ∨
      (¬ hasFailedNodes G state ∧
        (directReadyNodes G state).Nonempty ∧
          classifyClosedGraphState G state =
            StepResult.progressing state (directReadyNodes G state)) ∨
        (¬ hasFailedNodes G state ∧
          ¬ (directReadyNodes G state).Nonempty ∧
            allSettled G state ∧
              classifyClosedGraphState G state =
                StepResult.settled state RunOutcome.completed) ∨
          (¬ hasFailedNodes G state ∧
            ¬ (directReadyNodes G state).Nonempty ∧
              ¬ allSettled G state ∧
                hasWaitingNodes G state ∧
                  classifyClosedGraphState G state = StepResult.suspended state) := by
  classical
  by_cases hFailed : hasFailedNodes G state
  · exact Or.inl ⟨hFailed, classifyClosedGraphState_failed G state hFailed⟩
  · right
    by_cases hFrontier : (directReadyNodes G state).Nonempty
    · exact Or.inl
        ⟨hFailed, hFrontier, classifyClosedGraphState_progressing G state hFailed hFrontier⟩
    · right
      by_cases hSettled : allSettled G state
      · exact Or.inl
          ⟨ hFailed
          , hFrontier
          , hSettled
          , classifyClosedGraphState_settled_completed G state hFailed hFrontier hSettled
          ⟩
      · right
        by_cases hWaiting : hasWaitingNodes G state
        · exact
            ⟨ hFailed
            , hFrontier
            , hSettled
            , hWaiting
            , classifyClosedGraphState_suspended G state hFailed hFrontier hSettled hWaiting
            ⟩
        · have hFrontierNonempty :
              (directReadyNodes G state).Nonempty :=
            directReadyNodes_nonempty_of_wellFormed
              G
              state
              hWellFormed
              hFailed
              hSettled
              hWaiting
          exact False.elim (hFrontier hFrontierNonempty)

/-- Well-formed closed states cannot classify as stuck. -/
theorem classifyClosedGraphState_not_stuck_of_wellFormed
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state)
    (stuckState : GraphState ν payload) :
    classifyClosedGraphState G state ≠ StepResult.stuck stuckState := by
  classical
  by_cases hFailed : hasFailedNodes G state
  · intro hClass
    simp [classifyClosedGraphState, hFailed] at hClass
  · by_cases hFrontier : (directReadyNodes G state).Nonempty
    · intro hClass
      simp [classifyClosedGraphState, hFailed, hFrontier] at hClass
    · by_cases hSettled : allSettled G state
      · intro hClass
        simp [classifyClosedGraphState, hFailed, hFrontier, hSettled] at hClass
      · by_cases hWaiting : hasWaitingNodes G state
        · intro hClass
          simp
            [ classifyClosedGraphState
            , hFailed
            , hFrontier
            , hSettled
            , hWaiting
            ] at hClass
        · have hFrontierNonempty :
              (directReadyNodes G state).Nonempty :=
            directReadyNodes_nonempty_of_wellFormed
              G
              state
              hWellFormed
              hFailed
              hSettled
              hWaiting
          exact False.elim (hFrontier hFrontierNonempty)

/-- On well-formed states, runtime-style classification is already closed-state classification. -/
theorem classifyGraphState_eq_closed_of_wellFormed
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state) :
    classifyGraphState G state = classifyClosedGraphState G state := by
  unfold classifyGraphState
  rw [propagateFailure_of_failureClosureComplete G state hWellFormed.failureClosureComplete]

/-- Well-formed graph states cannot classify as stuck after the runtime closure step. -/
theorem classifyGraphState_not_stuck_of_wellFormed
    (G : DAG ν)
    [DecidableEq ν]
    [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (hWellFormed : wellFormedGraphState G state)
    (stuckState : GraphState ν payload) :
    classifyGraphState G state ≠ StepResult.stuck stuckState := by
  rw [classifyGraphState_eq_closed_of_wellFormed G state hWellFormed]
  exact classifyClosedGraphState_not_stuck_of_wellFormed G state hWellFormed stuckState

end Cortex.Pulse
