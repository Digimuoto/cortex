/-
# Pulse Kernel — Frontier Safety

The Paper 1 fixed-topology kernel computes a frontier from an extensional
state over a finite DAG. A ready node is pending and has every strict
ancestor terminal. This reachability-level readiness is the proof-facing
normal form; the executable runtime computes from direct predecessors,
and later refinement lemmas can relate the two under reachable-state
invariants.

The key result in this module is real, not axiomatized: all nodes in the
frontier are ready, and any two distinct frontier nodes are incomparable
by DAG reachability.
-/

import Cortex.Pulse.State

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-- A node is ready when it is pending and every strict ancestor is terminal. -/
def Ready (G : DAG ν) (state : GraphState ν payload) (node : ν) : Prop :=
  state.status node = NodeStatus.pending ∧
    ∀ predecessor : ν,
      G.reaches predecessor node → NodeStatus.terminal (state.status predecessor)

/-- Frontier nodes for a finite topology. -/
noncomputable def readyNodes
    (G : DAG ν)
    (state : GraphState ν payload) : Finset ν := by
  classical
  exact G.nodes.filter (Ready G state)

/-- Membership in `readyNodes` is exactly the readiness predicate. -/
theorem mem_readyNodes
    (G : DAG ν)
    (state : GraphState ν payload)
    (node : ν) :
    node ∈ readyNodes G state ↔ node ∈ G.nodes ∧ Ready G state node := by
  classical
  simp [readyNodes]

/-- The frontier contains only ready nodes. -/
theorem frontier_only_ready
    (G : DAG ν)
    (state : GraphState ν payload) :
    ∀ node ∈ readyNodes G state, Ready G state node := by
  intro node hNode
  exact ((mem_readyNodes G state node).mp hNode).2

/-- Distinct frontier members are mutually unreachable. -/
def PairwiseReachabilityIncomparable (G : DAG ν) (nodes : Finset ν) : Prop :=
  ∀ a ∈ nodes, ∀ b ∈ nodes, a ≠ b → ¬ G.reaches a b ∧ ¬ G.reaches b a

/-- Two ready nodes cannot be ordered by strict reachability. -/
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

/-- The frontier of a fixed DAG is an antichain under reachability. -/
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
