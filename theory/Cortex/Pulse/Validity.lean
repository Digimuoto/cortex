import Cortex.Pulse.Closure

/-!
## Overview

The Paper 1 recovery claim depends on a named validity predicate rather
than a prose bundle of assumptions. This module collects the parts of
that predicate that are already mechanized in the fixed-topology kernel.

## Context

Validity is intentionally small at this stage. Domain exactness is carried
by the finite DAG node set, payload semantics remain abstract, and this
page packages the structural invariants that recovery can prove today.

## Theorem Split

The page first records frontier exactness for both proof-level and
runtime-frontier readiness, then combines topology-domain, output,
running, closure, causal-history, and frontier obligations into
`wellFormedGraphState`.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Frontier Exactness -/

/-- `frontierExact G state` says the finite frontier is exact for `Ready`. -/
def frontierExact
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ node : ν, node ∈ readyNodes G state ↔ node ∈ G.nodes ∧ Ready G state node

/-- `directFrontierExact G state` says the runtime frontier is exact for `DirectReady`. -/
def directFrontierExact
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ node : ν,
    node ∈ directReadyNodes G state ↔ node ∈ G.nodes ∧ DirectReady G state node

/-- `frontierExact_readyNodes` proves `readyNodes` is definitionally exact for `Ready`. -/
theorem frontierExact_readyNodes
    (G : DAG ν)
    (state : GraphState ν payload) :
    frontierExact G state := by
  intro node
  exact mem_readyNodes G state node

/-- `directFrontierExact_directReadyNodes` proves runtime frontier exactness. -/
theorem directFrontierExact_directReadyNodes
    (G : DAG ν)
    (state : GraphState ν payload) :
    directFrontierExact G state := by
  intro node
  exact mem_directReadyNodes G state node

/-- `directReady_sound` proves executable-direct readiness implies proof readiness. -/
theorem directReady_sound
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    ∀ node : ν, DirectReady G state node → Ready G state node := by
  intro node hDirect
  exact directReady_ready_of_causalHistoryClosed G state hCausal hDirect

/-- `ready_directReady_of_failureClosureComplete` proves proof readiness is executable. -/
theorem ready_directReady_of_failureClosureComplete
    (G : DAG ν)
    (state : GraphState ν payload)
    (hClosure : failureClosureComplete G state) :
    ∀ node : ν, Ready G state node → DirectReady G state node := by
  intro node hReady
  constructor
  · exact hReady.1
  · intro predecessor hEdge
    have hReach : G.reaches predecessor node := G.reaches_of_edge hEdge
    have hTerminal : NodeStatus.terminal (state.status predecessor) :=
      hReady.2 predecessor hReach
    have hNotFailed : state.status predecessor ≠ NodeStatus.failed := by
      intro hFailed
      have hNodeFailed : state.status node = NodeStatus.failed :=
        hClosure
          predecessor
          node
          hFailed
          hReach
          (by simp [hReady.1, NodeStatus.propagatable])
      rw [hReady.1] at hNodeFailed
      cases hNodeFailed
    exact NodeStatus.terminal_unblocks_of_not_failed hTerminal hNotFailed

/-- `ready_iff_directReady_of_closed_causal` bridges proof and runtime readiness. -/
theorem ready_iff_directReady_of_closed_causal
    (G : DAG ν)
    (state : GraphState ν payload)
    (hClosure : failureClosureComplete G state)
    (hCausal : CausalHistoryClosed G state)
    (node : ν) :
    Ready G state node ↔ DirectReady G state node := by
  constructor
  · exact ready_directReady_of_failureClosureComplete G state hClosure node
  · exact directReady_sound G state hCausal node

/-- `readyNodes_eq_directReadyNodes` connects the proof frontier to the runtime frontier. -/
theorem readyNodes_eq_directReadyNodes
    (G : DAG ν)
    (state : GraphState ν payload)
    (hClosure : failureClosureComplete G state)
    (hCausal : CausalHistoryClosed G state) :
    readyNodes G state = directReadyNodes G state := by
  classical
  ext node
  constructor
  · intro hNode
    rcases (mem_readyNodes G state node).mp hNode with ⟨hMem, hReady⟩
    exact
      (mem_directReadyNodes G state node).mpr
        ⟨hMem, (ready_iff_directReady_of_closed_causal G state hClosure hCausal node).mp hReady⟩
  · intro hNode
    rcases (mem_directReadyNodes G state node).mp hNode with ⟨hMem, hDirect⟩
    exact
      (mem_readyNodes G state node).mpr
        ⟨hMem, (ready_iff_directReady_of_closed_causal G state hClosure hCausal node).mpr hDirect⟩

/-! ## Recovered-State Validity -/

/-- `wellFormedGraphState G state` is validity for normalized recovered graph states. -/
def wellFormedGraphState
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  GraphState.topologyDomain G state ∧
    GraphState.outputsRespectStatuses state ∧
      GraphState.noRunningNodes state ∧
        failureClosureComplete G state ∧
          CausalHistoryClosed G state ∧
            frontierExact G state ∧ directFrontierExact G state

end Cortex.Pulse
