import Cortex.Pulse.Frontier
import Mathlib.Data.List.Pairwise
import Mathlib.Data.List.Perm.Basic

/-!
## Overview

Frontier workers produce node-local facts. The fixed-topology kernel only
needs the node key, the resulting status, and an optional output; payload
and failure detail contents remain abstract.

## Context

The runtime applies a wave of frontier results by folding node-local
updates into a graph state. The theorem-level fact this page needs is
that two results for distinct nodes commute because they update disjoint
keys.

## Theorem Split

The page defines abstract worker outcomes, packages them as durable node
results, and proves the disjoint-key commutativity lemma used by later
frontier-fold proofs. Arbitrary node facts are not assumed safe: the
`Admissible` predicate records the frontier precondition needed by
preservation theorems.
-/

namespace Cortex.Pulse

/-! ## Worker Outcomes -/

/-- `NodeOutcome payload` is the abstract worker outcome for a single node. -/
inductive NodeOutcome (payload : Type v) : Type v where
  | succeeded : payload → NodeOutcome payload
  | skipped : NodeOutcome payload
  | suspended : NodeOutcome payload
  | failed : NodeOutcome payload
  | timedOut : NodeOutcome payload
  | cancelled : NodeOutcome payload
  | shutdown : NodeOutcome payload
  | runCancelled : NodeOutcome payload
  | rewritten : payload → NodeOutcome payload
  deriving Repr

namespace NodeOutcome

variable {payload : Type v}

/-- `NodeOutcome.status outcome` is the status contributed by an outcome. -/
def status : NodeOutcome payload → NodeStatus
  | succeeded _ => NodeStatus.completed
  | skipped => NodeStatus.skipped
  | suspended => NodeStatus.waiting
  | failed => NodeStatus.failed
  | timedOut => NodeStatus.failed
  | cancelled => NodeStatus.interrupted
  | shutdown => NodeStatus.interrupted
  | runCancelled => NodeStatus.interrupted
  | rewritten _ => NodeStatus.rewritten

/-- `NodeOutcome.output outcome` is the optional output contributed by an outcome. -/
def output : NodeOutcome payload → Option payload
  | succeeded value => some value
  | rewritten value => some value
  | skipped => none
  | suspended => none
  | failed => none
  | timedOut => none
  | cancelled => none
  | shutdown => none
  | runCancelled => none

/-- `output_respects_status` says emitted outputs match statuses that own payloads. -/
theorem output_respects_status
    (outcome : NodeOutcome payload)
    (value : payload)
    (hOutput : output outcome = some value) :
    NodeStatus.mayHaveOutput (status outcome) := by
  cases outcome <;> simp [output, status, NodeStatus.mayHaveOutput] at hOutput ⊢

/-- `status_ne_running` says durable worker outcomes never write `running`. -/
theorem status_ne_running
    (outcome : NodeOutcome payload) :
    status outcome ≠ NodeStatus.running := by
  cases outcome <;> simp [status]

end NodeOutcome

/-! ## Durable Node Facts -/

/-- `NodeResult ν payload` is the durable fact emitted for one node. -/
structure NodeResult (ν : Type u) (payload : Type v) where
  /-- `node` is the state key updated by this fact. -/
  node : ν
  /-- `outcome` is the abstract result for the node. -/
  outcome : NodeOutcome payload

namespace NodeResult

variable {ν : Type u} {payload : Type v}

/-- `InTopology G result` says a durable node fact targets a topology node. -/
def InTopology (G : DAG ν) (result : NodeResult ν payload) : Prop :=
  result.node ∈ G.nodes

/-- `Admissible G state result` says a node fact came from the executable frontier. -/
def Admissible
    (G : DAG ν)
    (state : GraphState ν payload)
    (result : NodeResult ν payload) : Prop :=
  InTopology G result ∧ DirectReady G state result.node

/-- `admissible_inTopology` extracts the topology target precondition. -/
theorem admissible_inTopology
    {G : DAG ν}
    {state : GraphState ν payload}
    {result : NodeResult ν payload}
    (hResult : Admissible G state result) :
    InTopology G result :=
  hResult.1

/-- `admissible_directReady` extracts the executable-frontier precondition. -/
theorem admissible_directReady
    {G : DAG ν}
    {state : GraphState ν payload}
    {result : NodeResult ν payload}
    (hResult : Admissible G state result) :
    DirectReady G state result.node :=
  hResult.2

/-- `admissible_ready` turns an admissible runtime fact into proof-level readiness. -/
theorem admissible_ready
    (G : DAG ν)
    (state : GraphState ν payload)
    (result : NodeResult ν payload)
    (hCausal : CausalHistoryClosed G state)
    (hResult : Admissible G state result) :
    Ready G state result.node :=
  directReady_ready_of_causalHistoryClosed G state hCausal hResult.2

/-- `applyNodeFact result state` applies a node-local fact to the graph state. -/
def applyNodeFact [DecidableEq ν]
    (result : NodeResult ν payload)
    (state : GraphState ν payload) : GraphState ν payload where
  status := fun n =>
    if n = result.node then result.outcome.status else state.status n
  output := fun n =>
    if n = result.node then result.outcome.output else state.output n

/-! ## Invariant Preservation -/

/-- `applyNodeFact_preserves_topologyDomain` preserves off-topology absence. -/
theorem applyNodeFact_preserves_topologyDomain [DecidableEq ν]
    (G : DAG ν)
    (result : NodeResult ν payload)
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state)
    (hResult : InTopology G result) :
    GraphState.topologyDomain G (applyNodeFact result state) := by
  intro node hNotMem
  by_cases hNode : node = result.node
  · subst node
    exact False.elim (hNotMem hResult)
  · rcases hDomain node hNotMem with ⟨hStatus, hOutput⟩
    constructor
    · simp [applyNodeFact, hNode, hStatus]
    · simp [applyNodeFact, hNode, hOutput]

/-- `applyNodeFact_preserves_outputsRespectStatuses` preserves output ownership. -/
theorem applyNodeFact_preserves_outputsRespectStatuses [DecidableEq ν]
    (result : NodeResult ν payload)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsRespectStatuses state) :
    GraphState.outputsRespectStatuses (applyNodeFact result state) := by
  intro node value hOutput
  by_cases hNode : node = result.node
  · subst node
    simp [applyNodeFact] at hOutput ⊢
    exact NodeOutcome.output_respects_status result.outcome value hOutput
  · have hOriginalOutput : state.output node = some value := by
      simpa [applyNodeFact, hNode] using hOutput
    have hMayHaveOutput : NodeStatus.mayHaveOutput (state.status node) :=
      hOutputs node value hOriginalOutput
    simpa [applyNodeFact, hNode] using hMayHaveOutput

/-- `applyNodeFact_preserves_outputsCompleteForStatuses` preserves required outputs. -/
theorem applyNodeFact_preserves_outputsCompleteForStatuses [DecidableEq ν]
    (result : NodeResult ν payload)
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsCompleteForStatuses state) :
    GraphState.outputsCompleteForStatuses (applyNodeFact result state) := by
  intro node hRequiresOutput
  by_cases hNode : node = result.node
  · subst node
    cases hOutcome : result.outcome with
    | succeeded value =>
        exact ⟨value, by simp [applyNodeFact, NodeOutcome.output, hOutcome]⟩
    | skipped =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | suspended =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | failed =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | timedOut =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | cancelled =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | shutdown =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | runCancelled =>
        simp
          [ applyNodeFact
          , NodeOutcome.status
          , NodeStatus.requiresOutput
          , hOutcome
          ] at hRequiresOutput
    | rewritten value =>
        exact ⟨value, by simp [applyNodeFact, NodeOutcome.output, hOutcome]⟩
  · have hOriginalRequires : NodeStatus.requiresOutput (state.status node) := by
      simpa [applyNodeFact, hNode] using hRequiresOutput
    rcases hOutputs node hOriginalRequires with ⟨value, hOutput⟩
    exact ⟨value, by simpa [applyNodeFact, hNode] using hOutput⟩

/-- `applyNodeFact_preserves_noRunning` preserves the absence of running nodes. -/
theorem applyNodeFact_preserves_noRunning [DecidableEq ν]
    (result : NodeResult ν payload)
    (state : GraphState ν payload)
    (hNoRunning : GraphState.noRunningNodes state) :
    GraphState.noRunningNodes (applyNodeFact result state) := by
  intro node
  by_cases hNode : node = result.node
  · subst node
    simpa [applyNodeFact] using NodeOutcome.status_ne_running result.outcome
  · simpa [applyNodeFact, hNode] using hNoRunning node

/-- `applyNodeFact_preserves_causalHistoryClosed` preserves causal history for admissible facts. -/
theorem applyNodeFact_preserves_causalHistoryClosed [DecidableEq ν]
    (G : DAG ν)
    (result : NodeResult ν payload)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state)
    (hResult : Admissible G state result) :
    CausalHistoryClosed G (applyNodeFact result state) := by
  classical
  have hReady : Ready G state result.node :=
    admissible_ready G state result hCausal hResult
  intro node hUnblocks predecessor hReach
  by_cases hNode : node = result.node
  · subst node
    by_cases hPred : predecessor = result.node
    · subst predecessor
      exact False.elim (G.not_reaches_self result.node hReach)
    · have hOriginalTerminal : NodeStatus.terminal (state.status predecessor) :=
        hReady.2.2 predecessor hReach
      simpa [applyNodeFact, hPred] using hOriginalTerminal
  · have hOriginalUnblocks : NodeStatus.unblocksSuccessors (state.status node) := by
      simpa [applyNodeFact, hNode] using hUnblocks
    by_cases hPred : predecessor = result.node
    · subst predecessor
      have hOriginalTerminal : NodeStatus.terminal (state.status result.node) :=
        hCausal node hOriginalUnblocks result.node hReach
      have hPendingTerminal : NodeStatus.terminal NodeStatus.pending := by
        simpa [hReady.2.1] using hOriginalTerminal
      exact False.elim (NodeStatus.pending_not_terminal hPendingTerminal)
    · have hOriginalTerminal : NodeStatus.terminal (state.status predecessor) :=
        hCausal node hOriginalUnblocks predecessor hReach
      simpa [applyNodeFact, hPred] using hOriginalTerminal

/-! ## Frontier-Fold Accumulation -/

/-- `applyNodeFacts results state` folds node-local facts in list order. -/
def applyNodeFacts [DecidableEq ν]
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload) : GraphState ν payload :=
  results.foldl (fun current result => applyNodeFact result current) state

/-- `AllAdmissibleFold G state results` requires each folded fact to be frontier-admissible. -/
def AllAdmissibleFold [DecidableEq ν]
    (G : DAG ν) : GraphState ν payload → List (NodeResult ν payload) → Prop
  | _state, [] => True
  | state, result :: rest =>
      Admissible G state result ∧
        AllAdmissibleFold G (applyNodeFact result state) rest

/-- `applyNodeFacts_preserves_topologyDomain` preserves off-topology absence. -/
theorem applyNodeFacts_preserves_topologyDomain [DecidableEq ν]
    (G : DAG ν)
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload)
    (hDomain : GraphState.topologyDomain G state)
    (hResults : AllAdmissibleFold G state results) :
    GraphState.topologyDomain G (applyNodeFacts results state) := by
  induction results generalizing state with
  | nil => simpa [applyNodeFacts] using hDomain
  | cons result rest ih =>
      rcases hResults with ⟨hResult, hRest⟩
      have hStep : GraphState.topologyDomain G (applyNodeFact result state) :=
        applyNodeFact_preserves_topologyDomain G result state hDomain hResult.1
      simpa [applyNodeFacts] using ih (applyNodeFact result state) hStep hRest

/-- `applyNodeFacts_preserves_outputsRespectStatuses` preserves output ownership. -/
theorem applyNodeFacts_preserves_outputsRespectStatuses [DecidableEq ν]
    (G : DAG ν)
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsRespectStatuses state)
    (hResults : AllAdmissibleFold G state results) :
    GraphState.outputsRespectStatuses (applyNodeFacts results state) := by
  induction results generalizing state with
  | nil => simpa [applyNodeFacts] using hOutputs
  | cons result rest ih =>
      rcases hResults with ⟨_hResult, hRest⟩
      have hStep :
          GraphState.outputsRespectStatuses (applyNodeFact result state) :=
        applyNodeFact_preserves_outputsRespectStatuses result state hOutputs
      simpa [applyNodeFacts] using ih (applyNodeFact result state) hStep hRest

/-- `applyNodeFacts_preserves_outputsCompleteForStatuses` preserves required outputs. -/
theorem applyNodeFacts_preserves_outputsCompleteForStatuses [DecidableEq ν]
    (G : DAG ν)
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload)
    (hOutputs : GraphState.outputsCompleteForStatuses state)
    (hResults : AllAdmissibleFold G state results) :
    GraphState.outputsCompleteForStatuses (applyNodeFacts results state) := by
  induction results generalizing state with
  | nil => simpa [applyNodeFacts] using hOutputs
  | cons result rest ih =>
      rcases hResults with ⟨_hResult, hRest⟩
      have hStep :
          GraphState.outputsCompleteForStatuses (applyNodeFact result state) :=
        applyNodeFact_preserves_outputsCompleteForStatuses result state hOutputs
      simpa [applyNodeFacts] using ih (applyNodeFact result state) hStep hRest

/-- `applyNodeFacts_preserves_noRunning` preserves the absence of running nodes. -/
theorem applyNodeFacts_preserves_noRunning [DecidableEq ν]
    (G : DAG ν)
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload)
    (hNoRunning : GraphState.noRunningNodes state)
    (hResults : AllAdmissibleFold G state results) :
    GraphState.noRunningNodes (applyNodeFacts results state) := by
  induction results generalizing state with
  | nil => simpa [applyNodeFacts] using hNoRunning
  | cons result rest ih =>
      rcases hResults with ⟨_hResult, hRest⟩
      have hStep : GraphState.noRunningNodes (applyNodeFact result state) :=
        applyNodeFact_preserves_noRunning result state hNoRunning
      simpa [applyNodeFacts] using ih (applyNodeFact result state) hStep hRest

/-- `applyNodeFacts_preserves_causalHistoryClosed` preserves causal history. -/
theorem applyNodeFacts_preserves_causalHistoryClosed [DecidableEq ν]
    (G : DAG ν)
    (results : List (NodeResult ν payload))
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state)
    (hResults : AllAdmissibleFold G state results) :
    CausalHistoryClosed G (applyNodeFacts results state) := by
  induction results generalizing state with
  | nil => simpa [applyNodeFacts] using hCausal
  | cons result rest ih =>
      rcases hResults with ⟨hResult, hRest⟩
      have hStep : CausalHistoryClosed G (applyNodeFact result state) :=
        applyNodeFact_preserves_causalHistoryClosed G result state hCausal hResult
      simpa [applyNodeFacts] using ih (applyNodeFact result state) hStep hRest

/-! ## Disjoint-Key Accumulation -/

/-- `applyNodeFact_comm` proves facts for distinct nodes commute. -/
theorem applyNodeFact_comm [DecidableEq ν]
    (r1 r2 : NodeResult ν payload)
    (state : GraphState ν payload)
    (hDistinct : r1.node ≠ r2.node) :
    applyNodeFact r1 (applyNodeFact r2 state) =
      applyNodeFact r2 (applyNodeFact r1 state) := by
  have hDistinctSymm : r2.node ≠ r1.node := by
    intro hEq
    exact hDistinct hEq.symm
  ext n
  · by_cases h1 : n = r1.node
    · by_cases h2 : n = r2.node
      · exact False.elim (hDistinct (by rw [← h1, ← h2]))
      · simp [applyNodeFact, h1, hDistinct]
    · by_cases h2 : n = r2.node
      · simp [applyNodeFact, h2, hDistinctSymm]
      · simp [applyNodeFact, h1, h2]
  · by_cases h1 : n = r1.node
    · by_cases h2 : n = r2.node
      · exact False.elim (hDistinct (by rw [← h1, ← h2]))
      · simp [applyNodeFact, h1, hDistinct]
    · by_cases h2 : n = r2.node
      · simp [applyNodeFact, h2, hDistinctSymm]
      · simp [applyNodeFact, h1, h2]

/-- `applyNodeFacts_perm_invariant` lifts disjoint-key commutativity to fact folds. -/
theorem applyNodeFacts_perm_invariant [DecidableEq ν]
    {left right : List (NodeResult ν payload)}
    (hPerm : left.Perm right)
    (hDistinct : left.Pairwise (fun first second => first.node ≠ second.node))
    (state : GraphState ν payload) :
    applyNodeFacts left state = applyNodeFacts right state := by
  unfold applyNodeFacts
  refine hPerm.foldl_eq' ?_ state
  intro first hFirst second hSecond current
  by_cases hSame : first = second
  · subst second
    rfl
  · have hSymm :
        Symmetric (fun first second : NodeResult ν payload => first.node ≠ second.node) := by
      intro a b hDistinctNodes hEq
      exact hDistinctNodes hEq.symm
    have hDistinctNodes : first.node ≠ second.node :=
      List.Pairwise.forall hSymm hDistinct hFirst hSecond hSame
    exact (applyNodeFact_comm first second current hDistinctNodes).symm

end NodeResult

end Cortex.Pulse
