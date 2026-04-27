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
module works at strict-reachability level so frontier antichain reasoning
is local to the DAG laws; a later refinement can connect direct
predecessors to this stronger readiness predicate.

## Theorem Split

The page defines readiness, constructs the finite frontier, proves the
frontier membership theorem, and then derives the antichain result.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Readiness Predicate -/

/-- `Ready G state node` means the node is pending and every strict ancestor is terminal. -/
def Ready (G : DAG ν) (state : GraphState ν payload) (node : ν) : Prop :=
  state.status node = NodeStatus.pending ∧
    ∀ predecessor : ν,
      G.reaches predecessor node → NodeStatus.terminal (state.status predecessor)

/-! ## Finite Frontier -/

/-- `readyNodes G state` is the finite frontier for a topology and state. -/
noncomputable def readyNodes
    (G : DAG ν)
    (state : GraphState ν payload) : Finset ν := by
  classical
  exact G.nodes.filter (Ready G state)

/-- `mem_readyNodes` states that frontier membership is exactly readiness. -/
theorem mem_readyNodes
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) :
    node ∈ readyNodes G state ↔ node ∈ G.nodes ∧ Ready G state node := by
  classical
  simp [readyNodes]

/-- `frontier_only_ready` states that every frontier node is ready. -/
theorem frontier_only_ready
    (G : DAG ν)
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
    simpa [hA.1] using hB.2 a hReach
  exact NodeStatus.pending_not_terminal hTerminal

/-- `frontier_antichain` proves the fixed-DAG frontier is a reachability antichain. -/
theorem frontier_antichain
    (G : DAG ν)
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
