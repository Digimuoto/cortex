import Cortex.Pulse.Recovery
import Cortex.Wire.Pure
import Cortex.Wire.Select

/-!
## Overview

Track 3 bridge from Wire rewrite certificates into the Pulse fixed-topology
safety kernel.

## Context

Wire proofs reason about source planning contexts, registry boundaries, rewrite
budgets, and constructed deltas. Pulse proofs reason about `GraphState` over a
fixed `DAG`. Runtime materialization is the boundary between those tracks: an
accepted Wire topology must be viewed as the Pulse DAG that execution and
recovery use.

This module intentionally does not construct that DAG. The graph-to-DAG
construction belongs to the graph/Pulse bridge track. Instead,
`WireTopologyDAGBridge` names the witness Track 3 needs: the Pulse DAG has the
same finite node set and direct-edge relation as the current Wire topology.
`SafeWireRunState` then bundles the Wire and Pulse invariants that must move
together across execution, recovery, and admitted rewrites.

## Theorem Split

The page proves preservation surfaces:

* recovery establishes the bundled safe state from persisted recovery
  preconditions;
* recovery preserves the bundled safe state for the same topology;
* admissible frontier facts, followed by recovery normalization, preserve it;
* successful CorePure output evaluation can feed that execution surface as a
  Pulse success fact while retaining output-port and value-contract evidence;
* a constructed admitted rewrite preserves it when runtime materialization
  supplies the next Pulse DAG/state witness; and
* `SelectActualize` is the selected-arm specialization of the same admitted
  rewrite theorem.

External worker results remain abstract `NodeResult`s. Replay determinism is
therefore modulo the same fixed result set, using the existing Pulse
permutation theorem.
-/

namespace Cortex.Wire

open Cortex.Graph
open Cortex.Pulse

/-! ## Wire Topology to Pulse DAG Bridge -/

section TopologyBridge

variable {node : Type}
variable [DecidableEq node]

/-- `WireTopologyDAGBridge topology G` relates a Wire topology to the Pulse DAG used to execute it.

The bridge is explicit because Track 3 consumes, but does not construct, the graph-to-DAG witness.
Track 1 is responsible for deriving this record from relation endpoint closure and acyclicity. -/
structure WireTopologyDAGBridge
    (topology : Graph node)
    (G : DAG node) :
    Prop where
  /-- Pulse executes exactly the vertices denoted by the Wire topology. -/
  nodes_eq : G.nodes = (denote topology).vertices
  /-- Pulse direct edges are exactly the denoted Wire edges. -/
  edge_iff : ∀ source target, G.edge source target = true ↔
    (source, target) ∈ (denote topology).edges

namespace WireTopologyDAGBridge

/-- The bridge exposes equality of the finite execution domain. -/
theorem nodes_eq_topology
    {topology : Graph node}
    {G : DAG node}
    (hBridge : WireTopologyDAGBridge topology G) :
    G.nodes = (denote topology).vertices :=
  hBridge.nodes_eq

/-- The bridge exposes direct-edge agreement from Pulse to Wire. -/
theorem pulse_edge_mem_topology
    {topology : Graph node}
    {G : DAG node}
    (hBridge : WireTopologyDAGBridge topology G)
    {source target : node}
    (hEdge : G.edge source target = true) :
    (source, target) ∈ (denote topology).edges :=
  (hBridge.edge_iff source target).mp hEdge

/-- The bridge exposes direct-edge agreement from Wire to Pulse. -/
theorem topology_edge_pulse_edge
    {topology : Graph node}
    {G : DAG node}
    (hBridge : WireTopologyDAGBridge topology G)
    {source target : node}
    (hEdge : (source, target) ∈ (denote topology).edges) :
    G.edge source target = true :=
  (hBridge.edge_iff source target).mpr hEdge

end WireTopologyDAGBridge

end TopologyBridge

/-! ## Safe Wire/Pulse Run State -/

section SafeRunState

variable {executor config contract authority payload : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

abbrev WireNode executor config authority :=
  StagedExecutorNode executor config authority

/-- `MaterializedPulseState context G state` is the runtime materialization witness consumed by
Track 3.

For a fixed planning context, it says the runtime has supplied the Pulse DAG corresponding to the
Wire topology and that the persisted graph state is well formed over that DAG. It does not, by
itself, state how this materialized state relates to a previous graph state across a rewrite. -/
structure MaterializedPulseState
    (context : PlanningContext (WireNode executor config authority))
    (G : DAG (WireNode executor config authority))
    (state : GraphState (WireNode executor config authority) payload) :
    Prop where
  /-- Current Wire topology and Pulse DAG agree extensionally. -/
  dagBridge : WireTopologyDAGBridge context.topology G
  /-- Persisted Pulse state is well formed over the materialized DAG. -/
  pulseWellFormed : wellFormedGraphState G state

/-- `SafeWireRunState` is the Track 3 safety envelope.

It bundles the current Wire planning-context validity, registry authority boundary, monotone budget
bound, and Pulse well-formed graph state over the DAG induced by the current Wire topology. -/
structure SafeWireRunState
    (registry : ExecutorRegistry executor config contract authority)
    (initialBudget remainingBudget : RewriteBudget)
    (context : PlanningContext (WireNode executor config authority))
    (G : DAG (WireNode executor config authority))
    (state : GraphState (WireNode executor config authority) payload) :
    Prop where
  /-- Current materialized Wire topology and definition domain are valid. -/
  sourceValid : SourcePlanningContextValid context
  /-- Current topology stays within the executor registry boundary. -/
  registryBoundary : _root_.Cortex.Wire.registryBoundary registry context.topology
  /-- Current Pulse DAG denotes the current Wire topology. -/
  dagBridge : WireTopologyDAGBridge context.topology G
  /-- Current remaining budget has not exceeded the run's initial budget. -/
  budgetWithinInitial : remainingBudget.le initialBudget
  /-- Current Pulse graph state is structurally well formed. -/
  pulseWellFormed : wellFormedGraphState G state

namespace SafeWireRunState

variable {registry : ExecutorRegistry executor config contract authority}
variable {initialBudget remainingBudget : RewriteBudget}
variable {context : PlanningContext (WireNode executor config authority)}
variable {G : DAG (WireNode executor config authority)}
variable {state : GraphState (WireNode executor config authority) payload}

/-- Safe run states expose the materialized Pulse-state witness used by rewrite transitions. -/
theorem materializedPulseState
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state) :
    MaterializedPulseState context G state :=
  { dagBridge := hSafe.dagBridge
    pulseWellFormed := hSafe.pulseWellFormed }

/-- Recovery establishes the Wire/Pulse safety envelope from persisted recovery preconditions.

This is the crash-recovery entry point: the input state may still contain volatile `running` or
`interrupted` statuses. Pulse recovery normalizes those states and proves `wellFormedGraphState`
from the weaker persisted preconditions. -/
theorem wirePulseRecoveryStep_establishes_safeRunState
    (hSourceValid : SourcePlanningContextValid context)
    (hBoundary : _root_.Cortex.Wire.registryBoundary registry context.topology)
    (hBridge : WireTopologyDAGBridge context.topology G)
    (hBudget : remainingBudget.le initialBudget)
    (hPersisted : persistedRecoveryPreconditions G state) :
    SafeWireRunState
      registry
      initialBudget
      remainingBudget
      context
      G
      (recoveredState G state) :=
  { sourceValid := hSourceValid
    registryBoundary := hBoundary
    dagBridge := hBridge
    budgetWithinInitial := hBudget
    pulseWellFormed := persistence_safety G state hPersisted }

/-- Recovery preserves the Wire/Pulse safety envelope for an already safe materialized topology. -/
theorem wirePulseRecoveryStep_preserves_safeRunState
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state) :
    SafeWireRunState
      registry
      initialBudget
      remainingBudget
      context
      G
      (recoveredState G state) :=
  { sourceValid := hSafe.sourceValid
    registryBoundary := hSafe.registryBoundary
    dagBridge := hSafe.dagBridge
    budgetWithinInitial := hSafe.budgetWithinInitial
    pulseWellFormed :=
      persistence_safety
        G
        state
        { topologyDomain := hSafe.pulseWellFormed.topologyDomain
          outputsRespectStatuses := hSafe.pulseWellFormed.outputsRespectStatuses
          outputsCompleteForStatuses := hSafe.pulseWellFormed.outputsCompleteForStatuses
          causalHistoryClosed := hSafe.pulseWellFormed.causalHistoryClosed } }

/-- Admissible frontier facts, followed by recovery, preserve the Wire/Pulse safety envelope. -/
theorem wirePulseExecutionStep_preserves_safeRunState
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state)
    (results : List (NodeResult (WireNode executor config authority) payload))
    (hResults : NodeResult.AllAdmissibleFold G state results) :
    SafeWireRunState
      registry
      initialBudget
      remainingBudget
      context
      G
      (recoveredState G (NodeResult.applyNodeFacts results state)) :=
  { sourceValid := hSafe.sourceValid
    registryBoundary := hSafe.registryBoundary
    dagBridge := hSafe.dagBridge
    budgetWithinInitial := hSafe.budgetWithinInitial
    pulseWellFormed :=
      frontierFacts_recovered_wellFormedGraphState
        G
        state
        results
        hSafe.pulseWellFormed
        hResults }

/-- Replaying the same externally produced frontier facts in a different order gives the same
recovered state, provided facts target distinct nodes.

This is intentionally a no-retry theorem. Same-node retries or supersession need a separate runtime
policy before a deterministic theorem can state which fact wins. -/
theorem wirePulseExecutionFacts_replay_deterministic
    {left right : List (NodeResult (WireNode executor config authority) payload)}
    (hPerm : left.Perm right)
    (hDistinct : left.Pairwise (fun first second => first.node ≠ second.node))
    (state : GraphState (WireNode executor config authority) payload) :
    recoveredState G (NodeResult.applyNodeFacts left state) =
      recoveredState G (NodeResult.applyNodeFacts right state) := by
  rw [NodeResult.applyNodeFacts_perm_invariant hPerm hDistinct state]

/-! ## CorePure Execution Facts -/

/-- Successful admitted CorePure output evaluation can feed the Wire/Pulse execution envelope.

The theorem is intentionally still conditional on `NodeResult.Admissible`: CorePure evaluation
produces the payload, while the Pulse frontier check says the fact may be applied to this graph
state. The first conjunct keeps the CorePure output-port and value-contract evidence attached to
the emitted success payload. The theorem does not prove that `node` is the compiled Wire node for
`pureNode`; that identity binding is a caller-supplied compiler/runtime correspondence
obligation. -/
theorem corePureExecutionStep_preserves_safeRunState
    {ctx : CorePure.StaticContext}
    {env : CorePure.Env}
    {pureNode : CorePure.PureNode}
    {lookup : CorePure.Name → Option CorePure.Value}
    {contracts : CorePure.OutputValueContracts}
    {node : WireNode executor config authority}
    {pureState :
      GraphState (WireNode executor config authority) (CorePure.Name → Option CorePure.Value)}
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G pureState)
    (hNode : CorePure.PureNodeAdmitted ctx pureNode)
    (hEval : pureNode.evalOutputs env = Except.ok lookup)
    (hContracts :
      ∀ outerEnv localEnv,
        CorePure.evalBindings env pureNode.bindings = Except.ok outerEnv →
          CorePure.evalWhereEnv outerEnv pureNode.whereExpr = Except.ok localEnv →
            CorePure.OutputExpressionsSatisfyContracts
              (CorePure.outputValueContractOk contracts)
              localEnv
              pureNode.outputs)
    (hAdmissible :
      NodeResult.Admissible
        G
        pureState
        { node := node
          outcome := NodeOutcome.succeeded lookup }) :
    (∀ name value,
        lookup name = some value →
          name ∈ pureNode.outputPorts ∧ CorePure.outputValueContractOk contracts name value) ∧
      SafeWireRunState
        registry
        initialBudget
        remainingBudget
        context
        G
        (recoveredState
          G
          (NodeResult.applyNodeFacts
            [ { node := node
                outcome := NodeOutcome.succeeded lookup } ]
            pureState)) := by
  constructor
  · exact
      CorePure.pureNode_evalOutputs_values_satisfy_valueContracts
        hNode
        hEval
        hContracts
  · refine
      wirePulseExecutionStep_preserves_safeRunState
        hSafe
        [ { node := node
            outcome := NodeOutcome.succeeded lookup } ]
        ?_
    exact ⟨hAdmissible, trivial⟩

/-! ## Rewrite Materialization -/

/-- Constructed admitted rewrites preserve the Wire/Pulse safety envelope once materialized.

Runtime materialization supplies the next Pulse DAG and graph state. The theorem discharges the
Wire-side obligations: source validity advances through the constructed step, the registry boundary
is preserved by the delta-admission witness, and the remaining budget stays below the initial run
budget. Retained-node status/output continuity is deliberately not claimed here; it belongs in the
runtime materialization witness or a future continuity predicate layered on top of it. -/
theorem wirePulseAdmittedRewrite_preserves_safeRunState
    {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
    {rawRewrite : GraphRewrite (WireNode executor config authority)}
    {insertedDepth : Nat}
    {nextBudget : RewriteBudget}
    {nextG : DAG (WireNode executor config authority)}
    {nextState : GraphState (WireNode executor config authority) payload}
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state)
    (step :
      ConstructedPlanningStep
        policy
        (_root_.Cortex.Wire.registryBoundary registry)
        context
        remainingBudget
        rawRewrite
        insertedDepth
        nextBudget)
    (hDelta : RegistryBoundaryDeltaAdmitted registry step.delta)
    (hMaterialized : MaterializedPulseState step.nextContext nextG nextState) :
    SafeWireRunState
      registry
      initialBudget
      nextBudget
      step.nextContext
      nextG
      nextState :=
  { sourceValid := step.toNextSourceValid
    registryBoundary :=
      ConstructedPlanningStep.registryBoundaryPreserved
        registry
        step
        hSafe.registryBoundary
        hDelta
    dagBridge := hMaterialized.dagBridge
    budgetWithinInitial :=
      RewriteBudget.le_trans
        (admittedRewriteDelta_remaining_le_initial step.admitted)
        hSafe.budgetWithinInitial
    pulseWellFormed := hMaterialized.pulseWellFormed }

/-- Selected-arm actualization is the `SelectActualize` specialization of admitted rewrite safety.

The proof does not add a new rewrite constructor: it reuses the constructed-step theorem for
`actualize.toGraphRewrite`, which is definitionally the retained-owner `appendAfter` lowering. -/
theorem selectActualize_preserves_safeRunState
    {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
    {arm : Type}
    {family : LatentBranchFamily (WireNode executor config authority) arm}
    {actualize : SelectActualize family}
    {insertedDepth : Nat}
    {nextBudget : RewriteBudget}
    {nextG : DAG (WireNode executor config authority)}
    {nextState : GraphState (WireNode executor config authority) payload}
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state)
    (step :
      ConstructedPlanningStep
        policy
        (_root_.Cortex.Wire.registryBoundary registry)
        context
        remainingBudget
        actualize.toGraphRewrite
        insertedDepth
        nextBudget)
    (hDelta : RegistryBoundaryDeltaAdmitted registry step.delta)
    (hMaterialized : MaterializedPulseState step.nextContext nextG nextState) :
    SafeWireRunState
      registry
      initialBudget
      nextBudget
      step.nextContext
      nextG
      nextState :=
  wirePulseAdmittedRewrite_preserves_safeRunState
    hSafe
    step
    hDelta
    hMaterialized

end SafeWireRunState

end SafeRunState

end Cortex.Wire
