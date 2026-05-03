import Cortex.Wire.PulseSafety

/-!
## Overview

Recovery-facing proof surface for selected Wire branches.

## Context

`Cortex.Wire.Select` proves that a selected latent branch lowers to the
ordinary retained-owner `appendAfter` rewrite. `Cortex.Wire.PulseSafety`
proves that constructed admitted rewrites preserve the combined Wire/Pulse
safe-run envelope once runtime materialization supplies the next Pulse state.

This module connects those two surfaces to the durable recovery story. A
selected branch recovery record is not a new graph operator. It records the
already-selected `SelectActualize` witness together with the constructed
planning step for its lowered append rewrite. A separate provenance predicate
connects a recovered record to the persisted admission it claims to replay.
Recovery does not re-run selector logic and it does not materialize unselected
alternatives.

## Theorem Split

The page proves:

* a recovered record replays the same append rewrite as the persisted admission
  it is proven to come from;
* equal selected-arm choices produce equal lowered append rewrites;
* unselected branch nodes remain outside the replayed selected raw fragment;
* selected-branch recovery feeds the existing safe-run preservation theorem.
-/

namespace Cortex.Wire

open Cortex.Graph
open Cortex.Pulse

/-! ## Durable Selected-Branch Records -/

section SelectedBranchRecovery

variable {node arm : Type}
variable [DecidableEq node]

/-- Proof-side record for replaying one selected latent branch.

The record carries the selected arm and the constructed planner step for the
lowered append rewrite. It intentionally does not contain selector code: after
admission, recovery is replaying a selected rewrite, not re-evaluating the
selector. Durable provenance is represented separately by
`SelectedBranchRecoveryRecord.Provenance`. -/
structure SelectedBranchRecoveryRecord
    (family : LatentBranchFamily node arm)
    (policy : RuntimeNamespacePolicy node)
    (contractOk : Graph node → Prop)
    (context : PlanningContext node)
    (budget : RewriteBudget) : Type where
  /-- Selected branch chosen before recovery replay. -/
  actualize : SelectActualize family
  /-- Runtime inserted-depth witness used by constructed planning. -/
  insertedDepth : Nat
  /-- Remaining budget after admitting the selected rewrite. -/
  remaining : RewriteBudget
  /-- Constructed planner step for the lowered selected append rewrite. -/
  step :
    ConstructedPlanningStep
      policy
      contractOk
      context
      budget
      actualize.toGraphRewrite
      insertedDepth
      remaining

/-- Proof-side shape of a persisted selected-branch admission row.

This mirrors the durable lineage data that runtime correspondence must recover:
the selected arm, inserted-depth witness, remaining budget, and constructed
planner step for the selected append rewrite. The runtime proof obligation is
to decode durable rewrite lineage into this shape and then into a recovery
record. -/
structure PersistedSelectedBranchAdmission
    (family : LatentBranchFamily node arm)
    (policy : RuntimeNamespacePolicy node)
    (contractOk : Graph node → Prop)
    (context : PlanningContext node)
    (budget : RewriteBudget) : Type where
  /-- Selected branch persisted at admission time. -/
  actualize : SelectActualize family
  /-- Persisted inserted-depth witness used by constructed planning. -/
  insertedDepth : Nat
  /-- Persisted remaining budget after admitting the selected rewrite. -/
  remaining : RewriteBudget
  /-- Persisted constructed planner step for the selected append rewrite. -/
  step :
    ConstructedPlanningStep
      policy
      contractOk
      context
      budget
      actualize.toGraphRewrite
      insertedDepth
      remaining

namespace SelectedBranchRecoveryRecord

variable {family : LatentBranchFamily node arm}
variable {policy : RuntimeNamespacePolicy node}
variable {contractOk : Graph node → Prop}
variable {context : PlanningContext node}
variable {budget : RewriteBudget}

/-- The graph rewrite replayed from a selected-branch recovery record. -/
def replayedRewrite
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    GraphRewrite node :=
  record.actualize.toGraphRewrite

/-- The selected raw fragment replayed by the recovery record before runtime namespacing. -/
def replayedSelectedFragment
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    SubgraphSpec node :=
  record.actualize.selectedFragment

/-- Raw nodes in the selected fragment replayed by the recovery record. -/
def replayedSelectedNodes
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    Finset node :=
  record.actualize.selectedFragmentNodes

/-- The replayed rewrite is the retained-owner append rewrite for the selected fragment. -/
theorem replayedRewrite_eq_appendAfter
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    record.replayedRewrite =
      GraphRewrite.appendAfter family.owner record.replayedSelectedFragment :=
  rfl

/-- The recovery record exposes admissibility of its constructed proof-carrying step rewrite. -/
theorem step_toRewrite_admissible
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    admissible record.step.toRewrite context.topology budget :=
  ConstructedPlanningStep.toAdmissible record.step

/-- Provenance relation between a persisted selected-branch admission and a recovered record.

The runtime correspondence layer must justify this relation from durable rewrite
lineage. Lean then consumes it as the formal link that the recovered record is
replaying the same selected admission, rather than merely naming a fresh
selected branch. -/
structure Provenance
    (persisted recovered :
      SelectedBranchRecoveryRecord family policy contractOk context budget) :
    Prop where
  /-- Recovery preserves the persisted selected arm. -/
  selected_eq : recovered.actualize.selected = persisted.actualize.selected
  /-- Recovery replays the persisted raw selected append rewrite. -/
  replayedRewrite_eq : recovered.replayedRewrite = persisted.replayedRewrite
  /-- Recovery uses the same constructed rewrite delta. -/
  delta_eq : recovered.step.delta = persisted.step.delta
  /-- Recovery carries the same remaining budget as the persisted admission. -/
  remaining_eq : recovered.remaining = persisted.remaining

namespace Provenance

/-- Provenance exposes equality of the raw replayed rewrite. -/
theorem replayedRewrite_eq_of_provenance
    {persisted recovered :
      SelectedBranchRecoveryRecord family policy contractOk context budget}
    (hProvenance : Provenance persisted recovered) :
    recovered.replayedRewrite = persisted.replayedRewrite :=
  hProvenance.replayedRewrite_eq

/-- Provenance exposes equality of the constructed rewrite delta. -/
theorem delta_eq_of_provenance
    {persisted recovered :
      SelectedBranchRecoveryRecord family policy contractOk context budget}
    (hProvenance : Provenance persisted recovered) :
    recovered.step.delta = persisted.step.delta :=
  hProvenance.delta_eq

/-- Provenance exposes equality of the remaining budget. -/
theorem remaining_eq_of_provenance
    {persisted recovered :
      SelectedBranchRecoveryRecord family policy contractOk context budget}
    (hProvenance : Provenance persisted recovered) :
    recovered.remaining = persisted.remaining :=
  hProvenance.remaining_eq

end Provenance

end SelectedBranchRecoveryRecord

namespace PersistedSelectedBranchAdmission

variable {family : LatentBranchFamily node arm}
variable {policy : RuntimeNamespacePolicy node}
variable {contractOk : Graph node → Prop}
variable {context : PlanningContext node}
variable {budget : RewriteBudget}

/-- Interpret a persisted selected-branch admission row as a recovery record. -/
def toRecoveryRecord
    (persisted :
      PersistedSelectedBranchAdmission family policy contractOk context budget) :
    SelectedBranchRecoveryRecord family policy contractOk context budget :=
  { actualize := persisted.actualize
    insertedDepth := persisted.insertedDepth
    remaining := persisted.remaining
    step := persisted.step }

/-- Loading exactly the persisted admission row produces recovery provenance.

The executable correspondence target is the equality premise: Haskell recovery
must show that decoding durable rewrite lineage yields this recovery record. -/
theorem provenance_of_recovered_eq
    (persisted :
      PersistedSelectedBranchAdmission family policy contractOk context budget)
    (recovered :
      SelectedBranchRecoveryRecord family policy contractOk context budget)
    (hRecovered : recovered = persisted.toRecoveryRecord) :
    SelectedBranchRecoveryRecord.Provenance persisted.toRecoveryRecord recovered := by
  cases hRecovered
  exact
    { selected_eq := rfl
      replayedRewrite_eq := rfl
      delta_eq := rfl
      remaining_eq := rfl }

end PersistedSelectedBranchAdmission

/-- Equal selected arms replay equal lowered append rewrites.

This is a functional-congruence fact about the selected-arm lowering, not a
claim that selector execution is deterministic. Durable recovery determinism is
stated separately using `SelectedBranchRecoveryRecord.Provenance`. -/
theorem replayedRewrite_eq_of_selected_eq
    {family : LatentBranchFamily node arm}
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget : RewriteBudget}
    (left right :
      SelectedBranchRecoveryRecord family policy contractOk context budget)
    (hSelected : left.actualize.selected = right.actualize.selected) :
    left.replayedRewrite = right.replayedRewrite := by
  cases left with
  | mk leftActualize _leftDepth _leftRemaining _leftStep =>
      cases right with
      | mk rightActualize _rightDepth _rightRemaining _rightStep =>
          cases leftActualize with
          | mk leftSelected _leftMem =>
              cases rightActualize with
              | mk rightSelected _rightMem =>
                  simp only
                    [ SelectedBranchRecoveryRecord.replayedRewrite
                    , SelectActualize.toGraphRewrite
                    , SelectActualize.selectedFragment
                    ] at hSelected ⊢
                  cases hSelected
                  rfl

/-- Two recovered records with the same persisted provenance replay the same admission data.

The non-trivial recovery obligation is the provenance witness: it is the runtime
correspondence fact that both records were loaded from the same persisted
selected-branch admission. Once that witness is supplied, replay is
deterministic for the raw selected append rewrite, constructed delta, and
remaining budget. -/
theorem selectedBranch_recovery_deterministic
    {family : LatentBranchFamily node arm}
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget : RewriteBudget}
    (persisted left right :
      SelectedBranchRecoveryRecord family policy contractOk context budget)
    (hLeft : SelectedBranchRecoveryRecord.Provenance persisted left)
    (hRight : SelectedBranchRecoveryRecord.Provenance persisted right) :
    left.replayedRewrite = right.replayedRewrite ∧
      left.step.delta = right.step.delta ∧
        left.remaining = right.remaining :=
  ⟨ hLeft.replayedRewrite_eq.trans hRight.replayedRewrite_eq.symm
  , ⟨ hLeft.delta_eq.trans hRight.delta_eq.symm
    , hLeft.remaining_eq.trans hRight.remaining_eq.symm
    ⟩
  ⟩

/-- Recovery does not replay nodes from an unselected branch raw fragment. -/
theorem selectedBranch_unselected_not_replayed
    {family : LatentBranchFamily node arm}
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget : RewriteBudget}
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget)
    {unselected : arm}
    (hUnselectedMem : unselected ∈ family.arms)
    (hDifferent : unselected ≠ record.actualize.selected)
    {nodeId : node}
    (hNode : nodeId ∈ family.fragmentNodes unselected) :
    nodeId ∉ record.replayedSelectedNodes :=
  SelectActualize.selectActualize_unselected_not_in_selectedFragment
    record.actualize
    hUnselectedMem
    hDifferent
    hNode

/-- Namespaced unselected branch nodes are absent from the constructed delta topology.

This theorem needs a freshness premise for the unselected branch namespace:
fragment disjointness rules out collisions with the selected inserted subgraph,
while freshness rules out the same namespaced node already being present in the
pre-rewrite context. -/
theorem selectedBranch_unselected_not_in_delta_topology
    {family : LatentBranchFamily node arm}
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget : RewriteBudget}
    (record :
      SelectedBranchRecoveryRecord family policy contractOk context budget)
    {unselected : arm}
    (hUnselectedMem : unselected ∈ family.arms)
    (hDifferent : unselected ≠ record.actualize.selected)
    (hFresh :
      ∀ {nodeId},
        nodeId ∈ family.fragmentNodes unselected →
          policy.namespaceNode family.owner nodeId ∉ (denote context.topology).vertices)
    {nodeId : node}
    (hNode : nodeId ∈ family.fragmentNodes unselected) :
    policy.namespaceNode family.owner nodeId ∉
      (denote record.step.delta.topology).vertices := by
  intro hFinal
  have hRuntimeSpecValid :
      (runtimePlannerRewrite policy record.actualize.toGraphRewrite).spec.Valid := by
    simp only [runtimePlannerRewrite, namespaceGraphRewrite_spec]
    exact
      namespaceSubgraphSpec_preserves_valid
        (policy.namespaceNode_injective record.actualize.toGraphRewrite.anchor)
        record.step.inputs.rawSubgraphValid
  have hAnchor :
      family.owner ∈ (denote context.topology).vertices := by
    simpa only [SelectActualize.toGraphRewrite, GraphRewrite.anchor] using
      record.step.inputs.anchorInTopology
  have hFinalRelation :
      policy.namespaceNode family.owner nodeId ∈
        (plannedFinalRelation
          context.topology
          (runtimePlannerRewrite policy record.actualize.toGraphRewrite)).vertices := by
    simpa only
      [ ConstructedPlanningStep.delta
      , constructedPlannedRewriteDelta
      , constructedFinalRelation
      , denote_constructedFinalTopology
      ] using hFinal
  have hVerticesEq :
      (plannedFinalRelation
        context.topology
        (runtimePlannerRewrite policy record.actualize.toGraphRewrite)).vertices =
        (denote context.topology).vertices ∪
          (denote
            (runtimePlannerRewrite policy
              record.actualize.toGraphRewrite).spec.topology).vertices := by
    simpa only
      [ SelectActualize.toGraphRewrite
      , runtimePlannerRewrite
      , namespaceGraphRewrite
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      ] using
        (plannedFinalRelation_vertices_append
          (context := context.topology)
          (anchor := family.owner)
          (spec := namespaceSubgraphSpec (policy.namespaceNode family.owner)
            record.actualize.selectedFragment)
          hAnchor
          hRuntimeSpecValid.entryNodesInside
          hRuntimeSpecValid.exitNodesInside)
  have hUnion :
      policy.namespaceNode family.owner nodeId ∈
        (denote context.topology).vertices ∪
          (denote
            (runtimePlannerRewrite policy
              record.actualize.toGraphRewrite).spec.topology).vertices := by
    simpa only [hVerticesEq] using hFinalRelation
  rcases Finset.mem_union.mp hUnion with hOld | hInserted
  · exact hFresh hNode hOld
  · simp only
      [ SelectActualize.toGraphRewrite
      , runtimePlannerRewrite
      , namespaceGraphRewrite
      , GraphRewrite.spec
      , namespaceSubgraphSpec
      , denote_mapGraph
      , mapRelation
      , Finset.mem_image
      ] at hInserted
    rcases hInserted with ⟨selectedNode, hSelectedNode, hNamespacedEq⟩
    have hSelectedEq :
        selectedNode = nodeId := by
      apply policy.namespaceNode_injective family.owner
      simpa only using hNamespacedEq
    have hSelectedRaw :
        nodeId ∈ record.replayedSelectedNodes := by
      rw [← hSelectedEq]
      simpa only
        [ SelectedBranchRecoveryRecord.replayedSelectedNodes
        , SelectActualize.selectedFragmentNodes
        , LatentBranchFamily.fragmentNodes
        , SelectActualize.selectedFragment
        ] using hSelectedNode
    exact
      (selectedBranch_unselected_not_replayed
        record
        hUnselectedMem
        hDifferent
        hNode)
        hSelectedRaw

end SelectedBranchRecovery

/-! ## Safe-Run Forwarding for Recovery Records -/

section SafeRunState

variable {executor config contract authority payload : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]
variable {registry : ExecutorRegistry executor config contract authority}
variable {initialBudget remainingBudget : RewriteBudget}
variable {context : PlanningContext (WireNode executor config authority)}
variable {G : DAG (WireNode executor config authority)}
variable {state : GraphState (WireNode executor config authority) payload}
variable {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
variable {arm : Type}
variable {family : LatentBranchFamily (WireNode executor config authority) arm}
variable {nextG : DAG (WireNode executor config authority)}
variable {nextState : GraphState (WireNode executor config authority) payload}

/-- A selected-branch recovery record forwards to admitted-rewrite safe-run preservation.

The theorem consumes the same materialization witness as ordinary admitted
rewrites. Its contribution is connecting the durable selected-branch recovery
record to the existing `SelectActualize` safe-run theorem; recovery-specific
durable provenance is modeled by `SelectedBranchRecoveryRecord.Provenance`. -/
theorem selectedBranch_recovery_preserves_safeRunState
    (hSafe :
      SafeWireRunState registry initialBudget remainingBudget context G state)
    (record :
      SelectedBranchRecoveryRecord
        family
        policy
        (_root_.Cortex.Wire.registryBoundary registry)
        context
        remainingBudget)
    (hDelta : RegistryBoundaryDeltaAdmitted registry record.step.delta)
    (hMaterialized : MaterializedPulseState record.step.nextContext nextG nextState) :
    SafeWireRunState
      registry
      initialBudget
      record.remaining
      record.step.nextContext
      nextG
      nextState :=
  SafeWireRunState.selectActualize_preserves_safeRunState
    hSafe
    record.step
    hDelta
    hMaterialized

end SafeRunState

end Cortex.Wire
