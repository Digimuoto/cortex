import Cortex.Pulse.State

/-!
## Overview

The Paper 1 fixed-topology kernel computes a frontier from an extensional
state over a finite DAG. A ready node is pending and has every strict
ancestor terminal. This reachability-level readiness is the proof-facing
normal form; the executable runtime computes from direct predecessors,
and later refinement lemmas can relate the two under reachable-state
invariants.

The key result in this module is real, not axiomatized: all nodes in the
frontier are ready, and any two distinct frontier nodes are incomparable
by DAG reachability.

## Context

The executable frontier is derived from direct predecessors. This proof
module keeps both direct-predecessor readiness and strict-reachability
readiness visible, so later validity theorems can bridge the executable
frontier to the proof-facing antichain argument.

## Theorem Split

The page defines readiness, constructs the finite frontier, proves the
frontier membership theorem, and then derives the antichain result.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Readiness Predicate -/

/-- `Ready G state node` means a topology node is pending and every strict ancestor is terminal. -/
def Ready (G : DAG ν) (state : GraphState ν payload) (node : ν) : Prop :=
  node ∈ G.nodes ∧
    state.status node = NodeStatus.pending ∧
      ∀ predecessor : ν,
        G.reaches predecessor node → NodeStatus.terminal (state.status predecessor)

/-- `DirectReady G state node` mirrors the executable direct-predecessor frontier check. -/
def DirectReady (G : DAG ν) (state : GraphState ν payload) (node : ν) : Prop :=
  node ∈ G.nodes ∧
    state.status node = NodeStatus.pending ∧
      ∀ predecessor : ν,
        G.predecessor predecessor node →
          NodeStatus.unblocksSuccessors (state.status predecessor)

/-- `CausalHistoryClosed G state` says unblocking nodes carry closed ancestor history. -/
def CausalHistoryClosed (G : DAG ν) (state : GraphState ν payload) : Prop :=
  ∀ node : ν,
    NodeStatus.unblocksSuccessors (state.status node) →
      ∀ predecessor : ν,
        G.reaches predecessor node → NodeStatus.terminal (state.status predecessor)

/-- `directReady_ready_of_causalHistoryClosed` bridges executable and proof frontiers. -/
theorem directReady_ready_of_causalHistoryClosed
    (G : DAG ν)
    (state : GraphState ν payload)
    {node : ν}
    (hCausal : CausalHistoryClosed G state)
    (hDirect : DirectReady G state node) :
    Ready G state node := by
  constructor
  · exact hDirect.1
  constructor
  · exact hDirect.2.1
  · intro predecessor hReach
    rcases EdgePath.last_step hReach with hEdge | ⟨direct, hPrefix, hEdge⟩
    · exact NodeStatus.unblocks_terminal (hDirect.2.2 predecessor hEdge)
    · exact hCausal direct (hDirect.2.2 direct hEdge) predecessor hPrefix

/-- `ready_iff_on_nodes` bounds proof readiness to the finite topology domain. -/
theorem ready_iff_on_nodes
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) :
    Ready G state node ↔
      node ∈ G.nodes ∧
        state.status node = NodeStatus.pending ∧
          ∀ predecessor ∈ G.nodes,
            G.reaches predecessor node → NodeStatus.terminal (state.status predecessor) := by
  constructor
  · intro hReady
    exact ⟨hReady.1, hReady.2.1, fun predecessor _hNode => hReady.2.2 predecessor⟩
  · intro hReady
    refine ⟨hReady.1, hReady.2.1, ?_⟩
    intro predecessor hReach
    exact hReady.2.2 predecessor (G.reaches_source_mem hReach) hReach

/-- `directReady_iff_on_nodes` bounds direct readiness to the finite topology domain. -/
theorem directReady_iff_on_nodes
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) :
    DirectReady G state node ↔
      node ∈ G.nodes ∧
        state.status node = NodeStatus.pending ∧
          ∀ predecessor ∈ G.nodes,
            G.predecessor predecessor node →
              NodeStatus.unblocksSuccessors (state.status predecessor) := by
  constructor
  · intro hReady
    exact ⟨hReady.1, hReady.2.1, fun predecessor _hNode => hReady.2.2 predecessor⟩
  · intro hReady
    refine ⟨hReady.1, hReady.2.1, ?_⟩
    intro predecessor hEdge
    exact hReady.2.2 predecessor (G.edge_source_mem hEdge) hEdge

/-- `readyDecidable` decides proof readiness from a finite scan and a reachability decider. -/
def readyDecidable (G : DAG ν) [DecidableEq ν] [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (node : ν) : Decidable (Ready G state node) := by
  rw [ready_iff_on_nodes]
  infer_instance

/-- `directReadyDecidable` decides runtime readiness from direct boolean edges. -/
def directReadyDecidable (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload)
    (node : ν) : Decidable (DirectReady G state node) := by
  rw [directReady_iff_on_nodes]
  infer_instance

/-! ## Finite Frontier -/

/-- `readyNodes G state` is the finite frontier for a topology and state. -/
def readyNodes (G : DAG ν) [DecidableEq ν] [DecidableRel G.reaches]
    (state : GraphState ν payload) : Finset ν := by
  letI : DecidablePred (Ready G state) := readyDecidable G state
  exact G.nodes.filter (Ready G state)

/-- `directReadyNodes G state` mirrors the runtime direct-predecessor frontier. -/
def directReadyNodes (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload) : Finset ν := by
  letI : DecidablePred (DirectReady G state) := directReadyDecidable G state
  exact G.nodes.filter (DirectReady G state)

/-- `mem_readyNodes` states that frontier membership is exactly readiness. -/
theorem mem_readyNodes (G : DAG ν) [DecidableEq ν] [DecidableRel G.reaches]
    (state : GraphState ν payload)
    (node : ν) :
    node ∈ readyNodes G state ↔ node ∈ G.nodes ∧ Ready G state node := by
  classical
  simp [readyNodes]

/-- `mem_directReadyNodes` states runtime frontier membership exactly. -/
theorem mem_directReadyNodes (G : DAG ν) [DecidableEq ν]
    (state : GraphState ν payload)
    (node : ν) :
    node ∈ directReadyNodes G state ↔ node ∈ G.nodes ∧ DirectReady G state node := by
  classical
  simp [directReadyNodes]

/-- `frontier_only_ready` states that every frontier node is ready. -/
theorem frontier_only_ready (G : DAG ν) [DecidableEq ν] [DecidableRel G.reaches]
    (state : GraphState ν payload) :
    ∀ node ∈ readyNodes G state, Ready G state node := by
  intro node hNode
  exact ((mem_readyNodes G state node).mp hNode).2

/-! ## Antichain Theorem -/

/-- `PairwiseReachabilityIncomparable G nodes` means frontier members are mutually unreachable. -/
def PairwiseReachabilityIncomparable (G : DAG ν) (nodes : Finset ν) : Prop :=
  ∀ a ∈ nodes, ∀ b ∈ nodes, a ≠ b → ¬ G.reaches a b ∧ ¬ G.reaches b a

/-- `ready_not_reaches_ready` rules out strict reachability between ready nodes. -/
theorem ready_not_reaches_ready
    (G : DAG ν)
    (state : GraphState ν payload)
    {a b : ν}
    (hA : Ready G state a)
    (hB : Ready G state b) :
    ¬ G.reaches a b := by
  intro hReach
  have hTerminal : NodeStatus.terminal NodeStatus.pending := by
    simpa [hA.2.1] using hB.2.2 a hReach
  exact NodeStatus.pending_not_terminal hTerminal

/-- `frontier_antichain` proves the fixed-DAG frontier is a reachability antichain. -/
theorem frontier_antichain (G : DAG ν) [DecidableEq ν] [DecidableRel G.reaches]
    (state : GraphState ν payload) :
    PairwiseReachabilityIncomparable G (readyNodes G state) := by
  intro a hA b hB _hDistinct
  have hReadyA : Ready G state a := ((mem_readyNodes G state a).mp hA).2
  have hReadyB : Ready G state b := ((mem_readyNodes G state b).mp hB).2
  exact
    ⟨ ready_not_reaches_ready G state hReadyA hReadyB
    , ready_not_reaches_ready G state hReadyB hReadyA
    ⟩

end Cortex.Pulse
