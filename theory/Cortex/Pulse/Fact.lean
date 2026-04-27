import Cortex.Pulse.State

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
frontier-fold proofs.
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

end NodeResult

end Cortex.Pulse
