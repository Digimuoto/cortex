/-
# Pulse Kernel — Valid Recovered States

The Paper 1 recovery claim depends on a named validity predicate rather
than a prose bundle of assumptions. This module collects the parts of
that predicate that are already mechanized in the fixed-topology kernel.
-/

import Cortex.Pulse.Closure

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-- The finite frontier is exact for the readiness predicate. -/
def frontierExact
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  ∀ node : ν, node ∈ readyNodes G state ↔ node ∈ G.nodes ∧ Ready G state node

/-- `readyNodes` is definitionally exact for `Ready`. -/
theorem frontierExact_readyNodes
    (G : DAG ν)
    (state : GraphState ν payload) :
    frontierExact G state := by
  intro node
  exact mem_readyNodes G state node

/-- Validity predicate for normalized, closed recovered graph states. -/
def wellFormedGraphState
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  GraphState.outputsRespectStatuses state ∧
    GraphState.noRunningNodes state ∧
      failureClosureComplete G state ∧ frontierExact G state

end Cortex.Pulse
