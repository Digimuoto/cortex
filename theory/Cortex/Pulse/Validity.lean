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

The page first records frontier exactness, then combines topology-domain,
output, running, closure, causal-history, and frontier obligations into
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

/-- `frontierExact_readyNodes` proves `readyNodes` is definitionally exact for `Ready`. -/
theorem frontierExact_readyNodes
    (G : DAG ν)
    (state : GraphState ν payload) :
    frontierExact G state := by
  intro node
  exact mem_readyNodes G state node

/-- `directReady_sound` proves executable-direct readiness implies proof readiness. -/
theorem directReady_sound
    (G : DAG ν)
    (state : GraphState ν payload)
    (hCausal : CausalHistoryClosed G state) :
    ∀ node : ν, DirectReady G state node → Ready G state node := by
  intro node hDirect
  exact directReady_ready_of_causalHistoryClosed G state hCausal hDirect

/-! ## Recovered-State Validity -/

/-- `wellFormedGraphState G state` is validity for normalized recovered graph states. -/
def wellFormedGraphState
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  GraphState.topologyDomain G state ∧
    GraphState.outputsRespectStatuses state ∧
      GraphState.noRunningNodes state ∧
        failureClosureComplete G state ∧
          CausalHistoryClosed G state ∧ frontierExact G state

end Cortex.Pulse
