import Cortex.Wire.Select

/-!
## Overview

Proof-facing model of ADR 0032 and ADR 0035 boundary-resource accounting.

## Context

The rewrite admission stack already proves graph safety, registry-boundary
preservation, and budget consumption for constructed planner steps. ADR 0032
and ADR 0035 add a more local vocabulary: a rewrite consumes a per-anchor
rewrite slot, and different rewrite forms use the anchor boundary in different
ways.

This module attaches that vocabulary to the existing proof objects. It does
not add a runtime rewrite constructor and it does not model full port-level
linear/affine/graded accounting. It records the proof-side resource law for
the current constructors, ties constructed steps to budgeted resource use, and
projects boundary preservation from constructed planner steps.

## Theorem Split

The page proves that `expandNode`, `appendAfter`, and `SelectActualize` have
distinct resource laws; that a constructed planner step spends one budgeted
rewrite slot; and that substitution and append-continuation boundary
preservation are distinct specializations of the existing constructed-step
contract preservation witness.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Boundary Resource Vocabulary -/

/-- Conceptual boundary law realized by a Wire operation. -/
inductive BoundaryLaw : Type where
  /-- Replacement-style expansion consumes the anchor boundary and substitutes a graph for it. -/
  | contractPreservingSubstitution
  /-- Append continuation retains the anchor boundary and sequences new work after it. -/
  | appendContinuation
  /-- Conditional actualization collapses a selected latent branch behind its owner. -/
  | conditionalBranchActualization
  deriving DecidableEq, Repr

/-- How an operation treats the anchor boundary obligation. -/
inductive AnchorBoundaryUse : Type where
  /-- The operation consumes or transforms the anchor boundary. -/
  | consumed
  /-- The operation leaves the anchor boundary in place. -/
  | retained
  /-- The operation consumes a guarded branch-local obligation. -/
  | guardedAffine
  deriving DecidableEq, Repr

/-- Per-epoch rewrite slot at one anchor.

This is a structure rather than a type alias so later ADR 0032 resource
dimensions can extend the slot without changing downstream theorem shapes. -/
structure RewriteSlot (node : Type) where
  /-- Anchor whose rewrite slot is spent. -/
  anchor : node
  deriving DecidableEq, Repr

/-- Resource-use witness declared by one rewrite-like operation. -/
structure BoundaryResourceUse (node : Type) where
  /-- Conceptual boundary law realized by the operation. -/
  law : BoundaryLaw
  /-- Per-anchor slot spent by the operation. -/
  slot : RewriteSlot node
  /-- How the anchor boundary itself is used. -/
  anchorBoundary : AnchorBoundaryUse
  deriving DecidableEq, Repr

/-- Boundary-resource use paired with the structural budget cost charged for it. -/
structure BudgetedBoundaryResourceUse (node : Type) where
  /-- Boundary law, slot, and anchor-boundary use. -/
  use : BoundaryResourceUse node
  /-- Graded structural rewrite budget consumed by this resource use. -/
  cost : RewriteCost
  deriving DecidableEq, Repr

/-! ## Graph Rewrite Resource Use -/

namespace GraphRewrite

variable {node : Type}

/-- Boundary law realized by a runtime-shaped `GraphRewrite`. -/
def boundaryLaw : GraphRewrite node → BoundaryLaw
  | GraphRewrite.expandNode _anchor _mode _spec =>
      BoundaryLaw.contractPreservingSubstitution
  | GraphRewrite.appendAfter _anchor _spec =>
      BoundaryLaw.appendContinuation

/-- Anchor-boundary use declared by a runtime-shaped `GraphRewrite`.

`retainNodeAsEnvelope` keeps node identity in the topology, but as an expansion
form it still transforms the anchor boundary. Only `appendAfter` retains the
anchor boundary unchanged. -/
def anchorBoundaryUse : GraphRewrite node → AnchorBoundaryUse
  | GraphRewrite.expandNode _anchor _mode _spec =>
      AnchorBoundaryUse.consumed
  | GraphRewrite.appendAfter _anchor _spec =>
      AnchorBoundaryUse.retained

/-- Rewrite slot spent by a runtime-shaped rewrite. -/
def rewriteSlot (rewrite : GraphRewrite node) : RewriteSlot node :=
  { anchor := rewrite.anchor }

/-- Boundary-resource use declared by a runtime-shaped rewrite. -/
def resourceUse (rewrite : GraphRewrite node) : BoundaryResourceUse node :=
  { law := rewrite.boundaryLaw
    slot := rewrite.rewriteSlot
    anchorBoundary := rewrite.anchorBoundaryUse }

/-- Expansion rewrites declare contract-preserving substitution resource use. -/
@[simp]
theorem expandNode_resourceUse
    (anchor : node)
    (mode : ExpansionMode)
    (spec : SubgraphSpec node) :
    (GraphRewrite.expandNode anchor mode spec).resourceUse =
      { law := BoundaryLaw.contractPreservingSubstitution
        slot := { anchor := anchor }
        anchorBoundary := AnchorBoundaryUse.consumed } :=
  rfl

/-- Append rewrites declare append-continuation resource use. -/
@[simp]
theorem appendAfter_resourceUse
    (anchor : node)
    (spec : SubgraphSpec node) :
    (GraphRewrite.appendAfter anchor spec).resourceUse =
      { law := BoundaryLaw.appendContinuation
        slot := { anchor := anchor }
        anchorBoundary := AnchorBoundaryUse.retained } :=
  rfl

/-- Expansion rewrites realize contract-preserving substitution. -/
@[simp]
theorem expandNode_boundaryLaw
    (anchor : node)
    (mode : ExpansionMode)
    (spec : SubgraphSpec node) :
    (GraphRewrite.expandNode anchor mode spec).boundaryLaw =
      BoundaryLaw.contractPreservingSubstitution :=
  rfl

/-- Append rewrites realize append continuation. -/
@[simp]
theorem appendAfter_boundaryLaw
    (anchor : node)
    (spec : SubgraphSpec node) :
    (GraphRewrite.appendAfter anchor spec).boundaryLaw =
      BoundaryLaw.appendContinuation :=
  rfl

/-- Substitution-style expansion consumes the anchor boundary. -/
@[simp]
theorem substitution_consumes_anchor_boundary
    (anchor : node)
    (mode : ExpansionMode)
    (spec : SubgraphSpec node) :
    (GraphRewrite.expandNode anchor mode spec).anchorBoundaryUse =
      AnchorBoundaryUse.consumed :=
  rfl

/-- Retained-envelope expansion still consumes or transforms the anchor boundary. -/
@[simp]
theorem retainEnvelope_consumes_anchor_boundary
    (anchor : node)
    (spec : SubgraphSpec node) :
    (GraphRewrite.expandNode anchor ExpansionMode.retainNodeAsEnvelope spec).anchorBoundaryUse =
      AnchorBoundaryUse.consumed :=
  rfl

/-- Append continuation retains the anchor boundary. -/
@[simp]
theorem appendContinuation_retains_anchor_boundary
    (anchor : node)
    (spec : SubgraphSpec node) :
    (GraphRewrite.appendAfter anchor spec).anchorBoundaryUse =
      AnchorBoundaryUse.retained :=
  rfl

end GraphRewrite

/-! ## Rewrite Slot Uniqueness -/

/-- A planning epoch spends each rewrite slot at most once. -/
def RewriteSlotsUnique {node : Type} (uses : List (BoundaryResourceUse node)) : Prop :=
  (uses.map (fun use => use.slot)).Nodup

/-- Elimination form for `RewriteSlotsUnique`: two uses in the same epoch cannot share a slot. -/
theorem rewriteSlot_spent_at_most_once
    {node : Type}
    {uses : List (BoundaryResourceUse node)}
    (hUnique : RewriteSlotsUnique uses)
    {left right : BoundaryResourceUse node}
    (hLeft : left ∈ uses)
    (hRight : right ∈ uses)
    (hSlot : left.slot = right.slot) :
    left = right := by
  induction uses generalizing left right with
  | nil =>
      cases hLeft
  | cons head tail ih =>
      simp only [RewriteSlotsUnique, List.map_cons, List.nodup_cons] at hUnique
      rcases hUnique with ⟨hHeadFresh, hTailUnique⟩
      simp only [List.mem_cons] at hLeft hRight
      rcases hLeft with hLeftHead | hLeftTail
      · rcases hRight with hRightHead | hRightTail
        · rw [hLeftHead, hRightHead]
        · rw [hLeftHead] at hSlot
          have hRightSlot : right.slot ∈ tail.map (fun use => use.slot) :=
            List.mem_map_of_mem (f := fun use : BoundaryResourceUse node => use.slot)
              hRightTail
          rw [← hSlot] at hRightSlot
          exact False.elim (hHeadFresh hRightSlot)
      · rcases hRight with hRightHead | hRightTail
        · rw [hRightHead] at hSlot
          have hLeftSlot : left.slot ∈ tail.map (fun use => use.slot) :=
            List.mem_map_of_mem (f := fun use : BoundaryResourceUse node => use.slot)
              hLeftTail
          rw [hSlot] at hLeftSlot
          exact False.elim (hHeadFresh hLeftSlot)
        · exact ih hTailUnique hLeftTail hRightTail hSlot

/-- A singleton resource-use epoch spends its slot at most once. -/
theorem singleton_rewriteSlotsUnique
    {node : Type}
    (use : BoundaryResourceUse node) :
    RewriteSlotsUnique [use] := by
  simp [RewriteSlotsUnique]

/-! ## Boundary Preservation from Constructed Steps -/

section BoundaryPreservation

variable {node : Type}
variable [DecidableEq node]
variable {policy : RuntimeNamespacePolicy node}
variable {contractOk : Graph node → Prop}
variable {context : PlanningContext node}
variable {budget remaining : RewriteBudget}
variable {rawRewrite : GraphRewrite node}
variable {insertedDepth : Nat}

/-- Boundary-resource use charged by a constructed planner step. -/
noncomputable def ConstructedPlanningStep.boundaryResourceUse
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    BudgetedBoundaryResourceUse node :=
  { use := rawRewrite.resourceUse
    cost := step.toRewrite.cost }

/-- A constructed planner step's resource cost is the cost of its induced proof-carrying rewrite. -/
theorem ConstructedPlanningStep.boundaryResourceCost_eq_toRewrite_cost
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    step.boundaryResourceUse.cost = step.toRewrite.cost :=
  rfl

/-- A constructed planner step spends the anchor rewrite slot of its raw rewrite. -/
theorem ConstructedPlanningStep.boundaryResourceSlot_eq_rawRewrite
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    step.boundaryResourceUse.use.slot = rawRewrite.rewriteSlot :=
  rfl

/-- A constructed planner step's budgeted resource use fits the incoming budget. -/
theorem ConstructedPlanningStep.boundaryResourceCost_fits_budget
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    step.boundaryResourceUse.cost.fitsIn budget := by
  exact step.toAdmissible.1

/-- A constructed planner step consumes positive rewrite-operation budget. -/
theorem ConstructedPlanningStep.boundaryResource_rewriteOps_positive
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    0 < step.boundaryResourceUse.cost.rewriteOps := by
  exact step.toRewrite.rewriteOps_positive

/-- One constructed planner step is a one-slot epoch and therefore cannot double-spend its slot. -/
theorem ConstructedPlanningStep.rewriteSlotsUnique
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    RewriteSlotsUnique [step.boundaryResourceUse.use] :=
  singleton_rewriteSlotsUnique step.boundaryResourceUse.use

/-! ## Chain-Level Rewrite Slot Uniqueness -/

namespace ConstructedPlanningChain

variable {context finalContext : PlanningContext node}
variable {finalBudget : RewriteBudget}
variable {steps : Nat}

/-- A rewrite slot appears in a constructed planning chain. -/
inductive ContainsRewriteSlot
    (slot : RewriteSlot node) :
    {context finalContext : PlanningContext node} →
      {budget finalBudget : RewriteBudget} →
        {steps : Nat} →
          ConstructedPlanningChain
            policy
            contractOk
            context
            budget
            finalContext
            finalBudget
            steps →
            Prop where
  | head
      {context finalContext : PlanningContext node}
      {budget remaining finalBudget : RewriteBudget}
      {rawRewrite : GraphRewrite node}
      {insertedDepth steps : Nat}
      (planningStep :
        ConstructedPlanningStep
          policy
          contractOk
          context
          budget
          rawRewrite
          insertedDepth
          remaining)
      (tail :
        ConstructedPlanningChain
          policy
          contractOk
          planningStep.nextContext
          remaining
          finalContext
          finalBudget
          steps)
      (hSlot : planningStep.boundaryResourceUse.use.slot = slot) :
      ContainsRewriteSlot slot (ConstructedPlanningChain.step planningStep tail)
  | tail
      {context finalContext : PlanningContext node}
      {budget remaining finalBudget : RewriteBudget}
      {rawRewrite : GraphRewrite node}
      {insertedDepth steps : Nat}
      {planningStep :
        ConstructedPlanningStep
          policy
          contractOk
          context
          budget
          rawRewrite
          insertedDepth
          remaining}
      {tail :
        ConstructedPlanningChain
          policy
          contractOk
          planningStep.nextContext
          remaining
          finalContext
          finalBudget
          steps}
      (hTail : ContainsRewriteSlot slot tail) :
      ContainsRewriteSlot slot (ConstructedPlanningChain.step planningStep tail)

/-- The head of a constructed chain spends its own rewrite slot. -/
theorem containsRewriteSlot_head
    {context finalContext : PlanningContext node}
    {budget remaining finalBudget : RewriteBudget}
    {rawRewrite : GraphRewrite node}
    {insertedDepth steps : Nat}
    (planningStep :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining)
    (tail :
      ConstructedPlanningChain
        policy
        contractOk
        planningStep.nextContext
        remaining
        finalContext
        finalBudget
        steps) :
    ContainsRewriteSlot
      planningStep.boundaryResourceUse.use.slot
      (ConstructedPlanningChain.step planningStep tail) :=
  ContainsRewriteSlot.head planningStep tail rfl

/-- A slot is fresh for every resource use already present in a tail chain. -/
def SlotFresh
    (slot : RewriteSlot node)
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps) :
    Prop :=
  ¬ ContainsRewriteSlot slot chain

/-- Refined constructed planning epochs whose anchors are fresh at every step. -/
inductive SlotUnique :
    {context finalContext : PlanningContext node} →
      {budget finalBudget : RewriteBudget} →
        {steps : Nat} →
          ConstructedPlanningChain
            policy
            contractOk
            context
            budget
            finalContext
            finalBudget
            steps →
            Prop where
  | done
      {context : PlanningContext node}
      {budget : RewriteBudget} :
      SlotUnique
        (ConstructedPlanningChain.done
          (policy := policy)
          (contractOk := contractOk)
          (context := context)
          (budget := budget))
  | step
      {context finalContext : PlanningContext node}
      {budget remaining finalBudget : RewriteBudget}
      {rawRewrite : GraphRewrite node}
      {insertedDepth steps : Nat}
      {planningStep :
        ConstructedPlanningStep
          policy
          contractOk
          context
          budget
          rawRewrite
          insertedDepth
          remaining}
      {tail :
        ConstructedPlanningChain
          policy
          contractOk
          planningStep.nextContext
          remaining
          finalContext
          finalBudget
          steps}
      (hTail : SlotUnique tail)
      (hFresh : SlotFresh planningStep.boundaryResourceUse.use.slot tail) :
      SlotUnique (ConstructedPlanningChain.step planningStep tail)

/-- The empty constructed chain is slot-unique. -/
theorem slotUnique_done
    {context : PlanningContext node}
    {budget : RewriteBudget} :
    SlotUnique
      (ConstructedPlanningChain.done
        (policy := policy)
        (contractOk := contractOk)
        (context := context)
        (budget := budget)) :=
  SlotUnique.done

/-- The empty constructed chain has no spent rewrite slots. -/
theorem not_containsRewriteSlot_done
    {context : PlanningContext node}
    {budget : RewriteBudget}
    {slot : RewriteSlot node} :
    ¬
      ContainsRewriteSlot
        slot
        (ConstructedPlanningChain.done
          (policy := policy)
          (contractOk := contractOk)
          (context := context)
          (budget := budget)) := by
  intro hSlot
  cases hSlot

/-- Adding a fresh-slot head to a slot-unique tail builds a slot-unique epoch. -/
theorem slotUnique_step
    {context finalContext : PlanningContext node}
    {budget remaining finalBudget : RewriteBudget}
    {rawRewrite : GraphRewrite node}
    {insertedDepth steps : Nat}
    {planningStep :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining}
    {tail :
      ConstructedPlanningChain
        policy
        contractOk
        planningStep.nextContext
        remaining
        finalContext
        finalBudget
        steps}
    (hTail : SlotUnique tail)
    (hFresh : SlotFresh planningStep.boundaryResourceUse.use.slot tail) :
    SlotUnique (ConstructedPlanningChain.step planningStep tail) :=
  SlotUnique.step hTail hFresh

/-- Proof-relevant resource-use trace for a slot-unique constructed planning epoch. -/
inductive SlotUniqueTrace :
    {context finalContext : PlanningContext node} →
      {budget finalBudget : RewriteBudget} →
        {steps : Nat} →
          ConstructedPlanningChain
            policy
            contractOk
            context
            budget
            finalContext
            finalBudget
            steps →
            List (BoundaryResourceUse node) →
            Type where
  | done
      {context : PlanningContext node}
      {budget : RewriteBudget} :
      SlotUniqueTrace
        (ConstructedPlanningChain.done
          (policy := policy)
          (contractOk := contractOk)
          (context := context)
          (budget := budget))
        []
  | step
      {context finalContext : PlanningContext node}
      {budget remaining finalBudget : RewriteBudget}
      {rawRewrite : GraphRewrite node}
      {insertedDepth steps : Nat}
      {planningStep :
        ConstructedPlanningStep
          policy
          contractOk
          context
          budget
          rawRewrite
          insertedDepth
          remaining}
      {tail :
        ConstructedPlanningChain
          policy
          contractOk
          planningStep.nextContext
          remaining
          finalContext
          finalBudget
          steps}
      {tailUses : List (BoundaryResourceUse node)}
      (tailTrace : SlotUniqueTrace tail tailUses)
      (hChainFresh : SlotFresh planningStep.boundaryResourceUse.use.slot tail)
      (hUseFresh :
        planningStep.boundaryResourceUse.use.slot ∉
          tailUses.map (fun use => use.slot)) :
      SlotUniqueTrace
        (ConstructedPlanningChain.step planningStep tail)
        (planningStep.boundaryResourceUse.use :: tailUses)

namespace SlotUniqueTrace

/-- A proof-relevant slot-unique trace also discharges the erased slot-unique predicate. -/
theorem toSlotUnique
    {context finalContext : PlanningContext node}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    {chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps}
    {uses : List (BoundaryResourceUse node)}
    (trace : SlotUniqueTrace chain uses) :
    SlotUnique chain := by
  induction trace with
  | done =>
      exact SlotUnique.done
  | step _tailTrace hChainFresh _hUseFresh ih =>
      exact SlotUnique.step ih hChainFresh

/-- A proof-relevant slot-unique trace exposes the list-level no-double-spend witness. -/
theorem rewriteSlotsUnique
    {context finalContext : PlanningContext node}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    {chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps}
    {uses : List (BoundaryResourceUse node)}
    (trace : SlotUniqueTrace chain uses) :
    RewriteSlotsUnique uses := by
  induction trace with
  | done =>
      simp [RewriteSlotsUnique]
  | step _tailTrace _hChainFresh hUseFresh ih =>
      simp only [RewriteSlotsUnique, List.map_cons, List.nodup_cons]
      exact ⟨hUseFresh, ih⟩

/-- A proof-relevant slot-unique trace rules out duplicate slot spends in its epoch. -/
theorem slot_spent_at_most_once
    {context finalContext : PlanningContext node}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    {chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps}
    {uses : List (BoundaryResourceUse node)}
    (trace : SlotUniqueTrace chain uses)
    {left right : BoundaryResourceUse node}
    (hLeft : left ∈ uses)
    (hRight : right ∈ uses)
    (hSlot : left.slot = right.slot) :
    left = right :=
  rewriteSlot_spent_at_most_once trace.rewriteSlotsUnique hLeft hRight hSlot

end SlotUniqueTrace

end ConstructedPlanningChain

namespace BoundaryResource

/-- Constructed planner steps expose the generic boundary-preservation witness. -/
theorem boundaryPreserved
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining)
    {g : Graph node}
    (hGraphEq : denote g = denote context.topology)
    (hBoundary : contractOk g) :
    contractOk step.delta.topology :=
  step.contractPreserved g hGraphEq hBoundary

/-- Abstract witness that a substitution replacement exposes the consumed anchor boundary.

The concrete contract vocabulary is supplied by the caller; this predicate is
the proof-side hook ADR 0035 needs to distinguish replacement from append
continuation. -/
def SubstitutionExposesAnchorBoundary
    (exposes : node → SubgraphSpec node → Prop)
    (anchor : node)
    (spec : SubgraphSpec node) :
    Prop :=
  exposes anchor spec

/-- Contract-preserving substitution preserves the caller boundary through constructed admission. -/
theorem substitution_preserves_boundary
    (exposes : node → SubgraphSpec node → Prop)
    (anchor : node)
    (mode : ExpansionMode)
    (spec : SubgraphSpec node)
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        (GraphRewrite.expandNode anchor mode spec)
        insertedDepth
        remaining)
    (hExposes : SubstitutionExposesAnchorBoundary exposes anchor spec)
    {g : Graph node}
    (hGraphEq : denote g = denote context.topology)
    (hBoundary : contractOk g) :
    (GraphRewrite.expandNode anchor mode spec).anchorBoundaryUse = AnchorBoundaryUse.consumed ∧
      SubstitutionExposesAnchorBoundary exposes anchor spec ∧
        contractOk step.delta.topology :=
  ⟨rfl, hExposes, boundaryPreserved step hGraphEq hBoundary⟩

/-- Append continuation preserves the caller boundary through constructed admission. -/
theorem appendContinuation_preserves_boundary
    (anchor : node)
    (spec : SubgraphSpec node)
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        (GraphRewrite.appendAfter anchor spec)
        insertedDepth
        remaining)
    {g : Graph node}
    (hGraphEq : denote g = denote context.topology)
    (hBoundary : contractOk g) :
    (GraphRewrite.appendAfter anchor spec).anchorBoundaryUse = AnchorBoundaryUse.retained ∧
      contractOk step.delta.topology :=
  ⟨rfl, boundaryPreserved step hGraphEq hBoundary⟩

end BoundaryResource

end BoundaryPreservation

/-! ## Select Actualization Resource Use -/

namespace LatentBranchFamily

variable {node arm : Type}
variable [DecidableEq node]

/-- Boundary-resource use declared by a latent branch family before append-after lowering. -/
def resourceUse (family : LatentBranchFamily node arm) :
    BoundaryResourceUse node :=
  { law := BoundaryLaw.conditionalBranchActualization
    slot := { anchor := family.owner }
    anchorBoundary := AnchorBoundaryUse.guardedAffine }

/-- Latent branch families use the conditional branch actualization law. -/
@[simp]
theorem resourceUse_law_eq_conditionalBranchActualization
    (family : LatentBranchFamily node arm) :
    family.resourceUse.law = BoundaryLaw.conditionalBranchActualization :=
  rfl

/-- Latent branch family actualization spends the owner rewrite slot. -/
@[simp]
theorem resourceUse_slot_eq_owner
    (family : LatentBranchFamily node arm) :
    family.resourceUse.slot = { anchor := family.owner } :=
  rfl

/-- Latent branch family actualization consumes a guarded branch-local obligation. -/
@[simp]
theorem resourceUse_anchorBoundary_eq_guardedAffine
    (family : LatentBranchFamily node arm) :
    family.resourceUse.anchorBoundary = AnchorBoundaryUse.guardedAffine :=
  rfl

end LatentBranchFamily

namespace SelectActualize

variable {node arm : Type}
variable [DecidableEq node]
variable {family : LatentBranchFamily node arm}

/-- The lowered selected-arm rewrite spends the owner's rewrite slot. -/
@[simp]
theorem selectActualize_toGraphRewrite_resourceUse_slot_eq_owner
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite.resourceUse.slot = { anchor := family.owner } :=
  rfl

/-- The lowered selected-arm rewrite uses the append-continuation law. -/
@[simp]
theorem selectActualize_toGraphRewrite_resourceUse_law_eq_appendContinuation
    (actualize : SelectActualize family) :
    actualize.toGraphRewrite.resourceUse.law = BoundaryLaw.appendContinuation :=
  rfl

/-- Select actualization and its lowered rewrite spend the same owner rewrite slot.

The boundary law intentionally differs across layers: the source-level
operation is conditional branch actualization, while runtime admission sees
the retained-owner append rewrite that materializes the selected fragment. -/
theorem selectActualize_resourceUse_slot_coherent_with_lowering
    (actualize : SelectActualize family) :
    family.resourceUse.slot = actualize.toGraphRewrite.resourceUse.slot :=
  rfl

end SelectActualize

end Cortex.Wire
