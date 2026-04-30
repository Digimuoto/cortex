import Cortex.Wire.Planner.Chain

/-!
## Overview

Proof-side certificates for Wire `select(...)` actualization.

## Context

ADR 0037 classifies `select(...)` as latent structural control, not as a new
Mokhov graph constructor and not as a new runtime `GraphRewrite` form. A
compiled select contains a closed family of latent branch fragments. Runtime
selection chooses one arm and materializes it through the existing retained
owner append realization.

This module names that proof surface. `LatentBranchFamily` records the owner
and latent fragments together with the compile-time validity and disjointness
promises that make those fragments a closed family for this lowering surface.
Each fragment is already the compiler-qualified latent fragment: any
author-facing arm-local names have been placed into branch namespaces before
the disjointness invariant is stated. `SelectActualize` records the chosen arm.
Its lowering is definitionally `GraphRewrite.appendAfter`, so all admission,
budget, and chain proofs continue to flow through the existing rewrite
machinery.

This module does not model selector-key resolution, common downstream boundary
typing, durable single-use selection, or recovery replay. Those are later
runtime and correspondence obligations. The scope here is selected-arm lowering
into existing append-after rewrite admission.

## Theorem Split

The page proves that selected-arm actualization lowers to `appendAfter`, retains
the owner anchor, exposes only the selected raw fragment to the rewrite
admission surface, reuses constructed-step admissibility, consumes the
constructed selected-arm delta cost, and keeps unselected branch fragments
outside the selected raw fragment through the family disjointness invariant.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Latent Branch Families -/

section LatentBranchFamily

/-- `LatentBranchFamily` is the proof-side shape of a compiled `select(...)`.

The family is not itself live topology. Its fragments are candidates; a
`SelectActualize` witness chooses one arm and lowers that arm to an ordinary
append-after rewrite at the owner. -/
structure LatentBranchFamily (node arm : Type) [DecidableEq node] where
  /-- Owner node whose selected output actualizes one latent continuation. -/
  owner : node
  /-- Closed set of arms accepted by the compiled select. -/
  arms : Finset arm
  /-- Compiler-qualified latent fragment attached to each arm.

  Local author names have already been placed into the branch namespace;
  pairwise disjointness is stated over these qualified fragment nodes. -/
  fragment : arm → SubgraphSpec node
  /-- Every declared branch fragment satisfies the normal inserted-subgraph checks. -/
  fragmentsValid : ∀ branch, branch ∈ arms → (fragment branch).Valid
  /-- Declared compiler-qualified branch fragments do not share nodes. -/
  fragmentsPairwiseDisjoint :
    ∀ left right,
      left ∈ arms →
        right ∈ arms →
          left ≠ right →
            ∀ nodeId,
              nodeId ∈ (denote (fragment left).topology).vertices →
                nodeId ∈ (denote (fragment right).topology).vertices →
                  False

namespace LatentBranchFamily

variable {node arm : Type}
variable [DecidableEq node]

/-- Nodes that belong to one latent branch fragment. -/
def fragmentNodes
    (family : LatentBranchFamily node arm)
    (branch : arm) :
    Finset node :=
  (denote (family.fragment branch).topology).vertices

/-- Branch fragments are node-disjoint in one direction. -/
def BranchNodeDisjoint
    (family : LatentBranchFamily node arm)
    (left right : arm) :
    Prop :=
  ∀ nodeId,
    nodeId ∈ family.fragmentNodes left →
      nodeId ∈ family.fragmentNodes right →
        False

/-- Every pair of distinct declared branch fragments is node-disjoint. -/
def BranchFragmentsPairwiseDisjoint
    (family : LatentBranchFamily node arm) :
    Prop :=
  ∀ left right,
    left ∈ family.arms →
      right ∈ family.arms →
        left ≠ right →
          family.BranchNodeDisjoint left right

/-- Family construction exposes per-arm inserted-subgraph validity. -/
theorem fragment_valid
    (family : LatentBranchFamily node arm)
    {branch : arm}
    (hBranch : branch ∈ family.arms) :
    (family.fragment branch).Valid :=
  family.fragmentsValid branch hBranch

/-- Family construction exposes pairwise branch-fragment disjointness. -/
theorem fragments_pairwise_disjoint
    (family : LatentBranchFamily node arm) :
    family.BranchFragmentsPairwiseDisjoint := by
  intro left right hLeft hRight hDifferent nodeId hLeftNode hRightNode
  exact
    family.fragmentsPairwiseDisjoint
      left
      right
      hLeft
      hRight
      hDifferent
      nodeId
      hLeftNode
      hRightNode

end LatentBranchFamily

/-! ## Select Actualization -/

variable {node arm : Type}
variable [DecidableEq node]

/-- `SelectActualize family` is the proof-side witness for the selected arm.

The witness only carries the selected arm and proof that the arm belongs to the
closed compiled family. It does not model durable single-use consumption and it
does not grant a general graph-rewrite capability. -/
structure SelectActualize (family : LatentBranchFamily node arm) where
  /-- The arm chosen by the selector output. -/
  selected : arm
  /-- The selected arm is one of the compiled latent alternatives. -/
  selected_mem : selected ∈ family.arms

namespace SelectActualize

variable {family : LatentBranchFamily node arm}

/-- Fragment selected by an actualization witness. -/
def selectedFragment (actualize : SelectActualize family) :
    SubgraphSpec node :=
  family.fragment actualize.selected

/-- Raw compiler-qualified nodes in the selected fragment before runtime planner namespacing. -/
def selectedFragmentNodes
    (actualize : SelectActualize family) :
    Finset node :=
  family.fragmentNodes actualize.selected

/-- Lower selected-arm actualization to the current retained-owner append rewrite. -/
def toGraphRewrite (actualize : SelectActualize family) :
    GraphRewrite node :=
  GraphRewrite.appendAfter family.owner actualize.selectedFragment

/-- A selected arm lowers to `appendAfter` at the family owner. -/
theorem selectActualize_lowers_to_appendAfter
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite =
      GraphRewrite.appendAfter family.owner actualize.selectedFragment :=
  rfl

/-- The lowered rewrite anchor is the select owner. -/
theorem selectActualize_anchor_eq
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite.anchor = family.owner :=
  rfl

/-- Select actualization is the retained-owner rewrite form. -/
theorem selectActualize_anchorDisposition_retained
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite.anchorDisposition = RewriteAnchorDisposition.retained :=
  rfl

/-- The lowered rewrite exposes the selected fragment as its inserted subgraph. -/
theorem selectActualize_spec_eq_selectedFragment
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite.spec = actualize.selectedFragment :=
  rfl

/-- The selected arm belongs to the closed latent branch family. -/
theorem selectActualize_selected_mem
    (actualize : SelectActualize family) :
    actualize.selected ∈ family.arms :=
  actualize.selected_mem

/-- The selected fragment satisfies the inserted-subgraph checks carried by the family. -/
theorem selectActualize_selectedFragment_valid
    (actualize : SelectActualize family) :
    actualize.selectedFragment.Valid :=
  family.fragment_valid actualize.selected_mem

/-- Raw nodes exposed by the selected arm are exactly the selected fragment nodes. -/
theorem selectActualize_selectedFragmentNodes_eq
    (actualize : SelectActualize family) :
    actualize.selectedFragmentNodes =
      (denote actualize.selectedFragment.topology).vertices :=
  rfl

/-- Unselected branch nodes are not in the selected raw fragment for a certified family.

This is a selected-fragment theorem, not a theorem about the entire final
topology. Other nodes may already exist in the owner context; the claim here is
only that the actualization witness exposes the selected raw branch fragment to
rewrite admission before runtime planner namespacing. -/
theorem selectActualize_unselected_not_in_selectedFragment
    (actualize : SelectActualize family)
    {unselected : arm}
    (hUnselectedMem : unselected ∈ family.arms)
    (hDifferent : unselected ≠ actualize.selected)
    {nodeId : node}
    (hNode : nodeId ∈ family.fragmentNodes unselected) :
    nodeId ∉ actualize.selectedFragmentNodes := by
  intro hSelectedNode
  exact
    family.fragments_pairwise_disjoint
      unselected
      actualize.selected
      hUnselectedMem
      actualize.selected_mem
      hDifferent
      nodeId
      hNode
      hSelectedNode

/-- Runtime planner admission sees the selected fragment after ordinary rewrite namespacing. -/
theorem selectActualize_runtimeRewrite_spec_eq
    (actualize : SelectActualize family)
    (policy : RuntimeNamespacePolicy node) :
    (runtimePlannerRewrite policy actualize.toGraphRewrite).spec =
      namespaceSubgraphSpec (policy.namespaceNode family.owner) actualize.selectedFragment :=
  rfl

/-- Constructed planner steps for select actualization reuse ordinary rewrite admission. -/
theorem selectActualize_admissible_of_constructedStep
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget remaining : RewriteBudget}
    {insertedDepth : Nat}
    {actualize : SelectActualize family}
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        actualize.toGraphRewrite
        insertedDepth
        remaining) :
    admissible step.toRewrite context.topology budget :=
  ConstructedPlanningStep.toAdmissible step

/-- Budget admission consumes the cost of the constructed selected-arm delta. -/
theorem selectActualize_consumes_selected_cost
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {budget remaining : RewriteBudget}
    {insertedDepth : Nat}
    {actualize : SelectActualize family}
    (hAdmitted :
      AdmittedRewriteDelta
        budget
        (constructedPlannedRewriteDelta
          policy
          context
          actualize.toGraphRewrite
          insertedDepth)
        remaining) :
    remaining =
      budget.consume
        (constructedPlannedRewriteDelta
          policy
          context
          actualize.toGraphRewrite
          insertedDepth).cost :=
  hAdmitted.remaining_eq

/-- A constructed select step exposes consumption of its selected-arm rewrite cost. -/
theorem selectActualize_step_remaining_eq_consume
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget remaining : RewriteBudget}
    {insertedDepth : Nat}
    {actualize : SelectActualize family}
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        actualize.toGraphRewrite
        insertedDepth
        remaining) :
    remaining = budget.consume step.toRewrite.cost :=
  ConstructedPlanningStep.remaining_eq_consume step

/-- The constructed admission checks contain the namespaced selected inserted subgraph. -/
theorem selectActualize_namespaced_selected_subgraph_contained
    {policy : RuntimeNamespacePolicy node}
    {contractOk : Graph node → Prop}
    {context : PlanningContext node}
    {budget remaining : RewriteBudget}
    {insertedDepth : Nat}
    {actualize : SelectActualize family}
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        actualize.toGraphRewrite
        insertedDepth
        remaining) :
    SubgraphContainedInFinal
      (runtimePlannerRewrite policy actualize.toGraphRewrite)
      step.delta := by
  simpa only [ConstructedPlanningStep.delta] using
    (runtimePlannerConstruction_planGraphRewriteChecks
      (constructedPlannedRewriteDelta_runtimePlannerConstruction
        step.inputs.toValidation)).subgraphContained

end SelectActualize

end LatentBranchFamily

namespace SelectActualize

/-! ## Registry Boundary Integration -/

section RegistryBoundary

variable {executor config contract authority arm : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

/-- Select actualization inherits constructed-delta registry-boundary preservation.

This theorem is still proof-side: runtime code must produce the ordinary
constructed-delta admission witness for the selected append realization. -/
theorem selectActualize_preserves_registryBoundary
    (registry : ExecutorRegistry executor config contract authority)
    {policy :
      RuntimeNamespacePolicy (StagedExecutorNode executor config authority)}
    {context :
      PlanningContext (StagedExecutorNode executor config authority)}
    {family :
      LatentBranchFamily (StagedExecutorNode executor config authority) arm}
    {actualize : SelectActualize family}
    {insertedDepth : Nat}
    (hBoundary : registryBoundary registry context.topology)
    (hDelta :
      RegistryBoundaryDeltaAdmitted
        registry
        (constructedPlannedRewriteDelta
          policy
          context
          actualize.toGraphRewrite
          insertedDepth)) :
    registryBoundary
      registry
      (constructedPlannedRewriteDelta
        policy
        context
        actualize.toGraphRewrite
        insertedDepth).topology :=
  constructedPlannedRewriteDelta_preserves_registryBoundary
    registry
    hBoundary
    hDelta

end RegistryBoundary

end SelectActualize

end Cortex.Wire
