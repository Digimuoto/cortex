import Cortex.Graph.Safety
import Cortex.Wire.Registry
import Mathlib.Data.Nat.Basic

/-!
## Overview

Sketches the soundness obligation for runtime graph rewriting:

> Every accepted rewrite is a *type-preserving transformation* on the
> circuit. If a rewrite would introduce a cycle, exceed the budget, or
> violate a contract boundary, it is rejected.

The Haskell side (`src/Cortex/Pulse/Rewrite.hs`,
`src/Cortex/Wire/Proposal.hs`) implements an admission predicate. This
file mechanizes the proof-carrying shape expected of admitted rewrites:
an accepted rewrite must carry evidence that it preserves graph
acyclicity, preserves the contract-boundary predicate supplied by the
caller, and consumes positive rewrite-operation budget inside the same
five-dimensional budget shape used by the runtime.

## Context

This module names real predicates for rewrite admission without pretending
the dynamic rewrite story is already fully connected to the Haskell
implementation. The current proof surface now includes both local
admission projections and chain-level preservation/termination facts.

## Theorem Split

The page defines graph-level paths, the abstract rewrite certificate,
the five-dimensional rewrite budget, the admission predicate, theorem
projections from the certificate, and rewrite chains bounded by remaining
rewrite-operation budget.

## Roadmap

1. Connect `Rewrite` certificates to the Haskell admission path.
2. Connect registry-boundary witnesses to the Haskell compiler and registry.
3. Model the remaining `planGraphRewrite` checks: anchor existence,
   entry/exit non-emptiness, orphan-freedom, and runtime policy.
4. Connect the graph path predicate to the runtime topology integrity
   witness from ADR 0009.

## References

- ADR 0009 — rewrite provenance and topology integrity.
- ADR 0010 — closed authority and the three-layer stack.
- `docs/architecture/07-rewrites-and-materialization.md`.
- `docs/publications/paper-3-graph-substitution-semantics/manuscript.md`.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Rewrite Model -/

/-- `GraphPath g a b` is non-empty reachability in the denotation of a graph. -/
inductive GraphPath {α : Type} [DecidableEq α] (g : Graph α) : α → α → Prop where
  | direct {a b : α} : (a, b) ∈ (denote g).edges → GraphPath g a b
  | trans {a b c : α} : GraphPath g a b → GraphPath g b c → GraphPath g a c

/-- `Acyclic g` rules out non-empty paths from a vertex back to itself. -/
def Acyclic {α : Type} [DecidableEq α] (g : Graph α) : Prop :=
  ∀ node : α, ¬ GraphPath g node node

/-- `graphPath_of_graphSafetyPath` bridges the canonical graph path into Wire paths. -/
theorem graphPath_of_graphSafetyPath
    {α : Type}
    [DecidableEq α]
    {g : Graph α}
    {source target : α}
    (hPath : Cortex.Graph.GraphPath g source target) :
    GraphPath g source target := by
  change Cortex.Graph.Relation.Path (denote g) source target at hPath
  induction hPath with
  | direct hEdge =>
      exact GraphPath.direct hEdge
  | trans _ _ ihLeft ihRight =>
      exact GraphPath.trans ihLeft ihRight

/-- `graphSafetyPath_of_graphPath` bridges Wire paths into the canonical graph path. -/
theorem graphSafetyPath_of_graphPath
    {α : Type}
    [DecidableEq α]
    {g : Graph α}
    {source target : α}
    (hPath : GraphPath g source target) :
    Cortex.Graph.GraphPath g source target := by
  induction hPath with
  | direct hEdge =>
      exact Cortex.Graph.Relation.Path.direct hEdge
  | trans _ _ ihLeft ihRight =>
      exact Cortex.Graph.Relation.Path.trans ihLeft ihRight

/-- `graphPath_iff_graphSafetyPath` equates Wire and canonical graph paths. -/
theorem graphPath_iff_graphSafetyPath
    {α : Type}
    [DecidableEq α]
    (g : Graph α)
    (source target : α) :
    GraphPath g source target ↔ Cortex.Graph.GraphPath g source target :=
  ⟨graphSafetyPath_of_graphPath, graphPath_of_graphSafetyPath⟩

/-- `acyclic_iff_graphSafetyAcyclic` equates Wire and canonical graph acyclicity. -/
theorem acyclic_iff_graphSafetyAcyclic
    {α : Type}
    [DecidableEq α]
    (g : Graph α) :
    Acyclic g ↔ Cortex.Graph.GraphAcyclic g := by
  constructor
  · intro hAcyclic node hPath
    exact hAcyclic node (graphPath_of_graphSafetyPath hPath)
  · intro hAcyclic node hPath
    exact hAcyclic node (graphSafetyPath_of_graphPath hPath)

/-- `RewriteCost` mirrors the runtime's structural rewrite-cost dimensions. -/
structure RewriteCost where
  /-- Number of nodes added by the admitted rewrite. -/
  addedNodes : Nat
  /-- Number of edges added by the admitted rewrite. -/
  addedEdges : Nat
  /-- Depth added below the rewrite anchor. -/
  addedDepth : Nat
  /-- Peak frontier-width delta introduced by the rewrite. -/
  frontierDelta : Nat
  /-- Number of admitted rewrite operations consumed by this rewrite. -/
  rewriteOps : Nat
  deriving DecidableEq, Repr

/-- `RewriteBudget` mirrors the runtime's remaining structural rewrite budget. -/
structure RewriteBudget where
  /-- Remaining node additions. -/
  addedNodes : Nat
  /-- Remaining edge additions. -/
  addedEdges : Nat
  /-- Remaining depth below anchors. -/
  addedDepth : Nat
  /-- Remaining peak frontier-width delta. -/
  frontierDelta : Nat
  /-- Remaining admitted rewrite operations. -/
  rewriteOps : Nat
  deriving DecidableEq, Repr

namespace RewriteCost

/-- `fitsIn cost budget` means every structural cost dimension fits the remaining budget. -/
def fitsIn (cost : RewriteCost) (budget : RewriteBudget) : Prop :=
  cost.addedNodes ≤ budget.addedNodes ∧
    cost.addedEdges ≤ budget.addedEdges ∧
      cost.addedDepth ≤ budget.addedDepth ∧
        cost.frontierDelta ≤ budget.frontierDelta ∧
          cost.rewriteOps ≤ budget.rewriteOps

end RewriteCost

namespace RewriteBudget

/-- `le left right` is fieldwise comparison for remaining rewrite budgets. -/
def le (left right : RewriteBudget) : Prop :=
  left.addedNodes ≤ right.addedNodes ∧
    left.addedEdges ≤ right.addedEdges ∧
      left.addedDepth ≤ right.addedDepth ∧
        left.frontierDelta ≤ right.frontierDelta ∧
          left.rewriteOps ≤ right.rewriteOps

/-- `consume budget cost` mirrors runtime subtraction after a cost fits the budget. -/
def consume (budget : RewriteBudget) (cost : RewriteCost) : RewriteBudget :=
  { addedNodes := budget.addedNodes - cost.addedNodes
    addedEdges := budget.addedEdges - cost.addedEdges
    addedDepth := budget.addedDepth - cost.addedDepth
    frontierDelta := budget.frontierDelta - cost.frontierDelta
    rewriteOps := budget.rewriteOps - cost.rewriteOps }

/-- `consume_le` records that budget consumption never replenishes any dimension. -/
theorem consume_le (budget : RewriteBudget) (cost : RewriteCost) :
    (consume budget cost).le budget := by
  constructor
  · exact Nat.sub_le _ _
  · constructor
    · exact Nat.sub_le _ _
    · constructor
      · exact Nat.sub_le _ _
      · constructor
        · exact Nat.sub_le _ _
        · exact Nat.sub_le _ _

/-- `le_trans` composes fieldwise budget comparison. -/
theorem le_trans
    {left middle right : RewriteBudget}
    (hLeft : left.le middle)
    (hRight : middle.le right) :
    left.le right := by
  rcases hLeft with ⟨hLeftNodes, hLeftEdges, hLeftDepth, hLeftFrontier, hLeftOps⟩
  rcases hRight with ⟨hRightNodes, hRightEdges, hRightDepth, hRightFrontier, hRightOps⟩
  exact
    ⟨ _root_.le_trans hLeftNodes hRightNodes
    , _root_.le_trans hLeftEdges hRightEdges
    , _root_.le_trans hLeftDepth hRightDepth
    , _root_.le_trans hLeftFrontier hRightFrontier
    , _root_.le_trans hLeftOps hRightOps
    ⟩

/-- `le_refl` is reflexivity for fieldwise budget comparison. -/
theorem le_refl (budget : RewriteBudget) : budget.le budget :=
  ⟨le_rfl, le_rfl, le_rfl, le_rfl, le_rfl⟩

end RewriteBudget

/-- `Rewrite α` is an option-valued graph transformer. The full Haskell shape
carries provenance and concrete contract metadata; this proof shape keeps
the transformation, a structural budget cost, and the preservation evidence
that an admitted rewrite must supply. The rewrite-operation dimension is
strictly positive so chain length is bounded by `rewriteOps`. -/
structure Rewrite (α : Type) [DecidableEq α] (contractOk : Graph α → Prop) where
  /-- `apply` is the transformation. `none` means "this rewrite does not apply
      to this graph". -/
  apply : Graph α → Option (Graph α)
  /-- `cost` is the fixed structural budget cost of admitting this rewrite. -/
  cost : RewriteCost
  /-- `rewriteOps_positive` ensures every accepted rewrite consumes operation budget. -/
  rewriteOps_positive : 0 < cost.rewriteOps
  /-- `preserves_acyclic` is the graph-safety certificate for this rewrite. -/
  preserves_acyclic :
    ∀ {g g' : Graph α}, apply g = some g' → Acyclic g → Acyclic g'
  /-- `preserves_contracts` is the caller-supplied boundary-safety certificate. -/
  preserves_contracts :
    ∀ {g g' : Graph α}, apply g = some g' → contractOk g → contractOk g'

/-! ## Admission Predicate -/

section RewriteProofs

variable {α : Type}
variable [DecidableEq α]
variable {contractOk : Graph α → Prop}

/-- `applicable r g` says the rewrite produces a candidate graph. -/
def applicable
    (r : Rewrite α contractOk)
    (g : Graph α) : Prop :=
  ∃ g' : Graph α, r.apply g = some g'

/-- `admissible r g budget` says a rewrite fits the remaining budget and applies.

The acyclicity and contract-boundary obligations live in the `Rewrite`
certificate, so an admissible rewrite cannot be constructed without them. -/
def admissible
    (r : Rewrite α contractOk)
    (g : Graph α)
    (budget : RewriteBudget) : Prop :=
  r.cost.fitsIn budget ∧ applicable r g

/-! ## Soundness Obligations -/

/-- `admissible_preserves_acyclic` projects the acyclicity certificate.

If `g` is acyclic and `r` is admissible at `g`, then `r.apply g`
(when defined) is acyclic. -/
theorem admissible_preserves_acyclic
    (r : Rewrite α contractOk)
    {g g' : Graph α}
    {budget : RewriteBudget}
    (_hAdmissible : admissible r g budget)
    (hApply : r.apply g = some g')
    (hAcyclic : Acyclic g) :
    Acyclic g' :=
  r.preserves_acyclic hApply hAcyclic

/-- `admissible_preserves_contracts` projects the contract-boundary certificate.

Admissible rewrites preserve the contract registry's boundary invariants:
every port still references a registered contract, and every cross-fragment
edge is still typed-compatible. The concrete predicate is supplied as
`contractOk` until the registry mechanization lands. -/
theorem admissible_preserves_contracts
    (r : Rewrite α contractOk)
    {g g' : Graph α}
    {budget : RewriteBudget}
    (_hAdmissible : admissible r g budget)
    (hApply : r.apply g = some g')
    (hContracts : contractOk g) :
    contractOk g' :=
  r.preserves_contracts hApply hContracts

/-- `admissible_rewriteOps_bounds` extracts the local operation-budget facts.

A chain-length proof uses this local fact to show every admitted step consumes at least one
rewrite operation and never exceeds the current operation budget. -/
theorem admissible_rewriteOps_bounds
    (r : Rewrite α contractOk)
    (g : Graph α)
    (budget : RewriteBudget)
    (hAdmissible : admissible r g budget) :
    0 < r.cost.rewriteOps ∧ r.cost.rewriteOps ≤ budget.rewriteOps :=
  ⟨r.rewriteOps_positive, hAdmissible.1.2.2.2.2⟩

end RewriteProofs

/-! ## Registry Boundary Instantiation -/

section RegistryBoundary

variable {executor config contract authority : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

/-- `admissible_preserves_registryBoundary` instantiates `contractOk` with the Wire registry
boundary model.

An admitted rewrite over staged executor nodes cannot leave the closed executor alphabet unless its
rewrite certificate also proves the registry boundary for the produced graph. -/
theorem admissible_preserves_registryBoundary
    (registry : ExecutorRegistry executor config contract authority)
    (r :
      Rewrite
        (StagedExecutorNode executor config authority)
        (registryBoundary registry))
    {g g' : Graph (StagedExecutorNode executor config authority)}
    {budget : RewriteBudget}
    (hAdmissible : admissible r g budget)
    (hApply : r.apply g = some g')
    (hBoundary : registryBoundary registry g) :
    registryBoundary registry g' :=
  admissible_preserves_contracts r hAdmissible hApply hBoundary

end RegistryBoundary

/-! ## Rewrite Chains -/

section RewriteChains

variable {α : Type}
variable [DecidableEq α]
variable {contractOk : Graph α → Prop}

/-- `RewriteChain g budget gFinal finalBudget steps` is a finite sequence of admitted rewrites.

Each step applies one rewrite, subtracts its structural cost from the remaining budget, and
continues from the produced graph. The `steps` index makes the operation-budget termination bound
explicit. The index order is: current graph, current budget, final graph, final budget, steps. -/
inductive RewriteChain
    (contractOk : Graph α → Prop) :
    Graph α → RewriteBudget → Graph α → RewriteBudget → Nat → Prop where
  | done {g : Graph α} {budget : RewriteBudget} :
      RewriteChain contractOk g budget g budget 0
  | step
      {g g' gFinal : Graph α}
      {budget budgetAfter finalBudget : RewriteBudget}
      {steps : Nat}
      (r : Rewrite α contractOk)
      (hAdmissible : admissible r g budget)
      (hApply : r.apply g = some g')
      (hBudgetAfter : budgetAfter = budget.consume r.cost)
      (tail : RewriteChain contractOk g' budgetAfter gFinal finalBudget steps) :
      RewriteChain contractOk g budget gFinal finalBudget (Nat.succ steps)

private theorem rewrite_step_budget_bound
    {steps : Nat}
    {budget budgetAfter : RewriteBudget}
    {rewriteCost : RewriteCost}
    (hSteps : steps ≤ budgetAfter.rewriteOps)
    (hBudgetAfter : budgetAfter = budget.consume rewriteCost)
    (hOpsPositive : 0 < rewriteCost.rewriteOps)
    (hOpsBound : rewriteCost.rewriteOps ≤ budget.rewriteOps) :
    Nat.succ steps ≤ budget.rewriteOps := by
  have hOneLeCost : 1 ≤ rewriteCost.rewriteOps := Nat.succ_le_of_lt hOpsPositive
  have hStepBound : Nat.succ steps ≤ budgetAfter.rewriteOps + 1 := by
    simpa [Nat.succ_eq_add_one] using Nat.succ_le_succ hSteps
  have hBudgetAfterBound : budgetAfter.rewriteOps + 1 ≤ budget.rewriteOps := by
    rw [hBudgetAfter, RewriteBudget.consume]
    calc
      budget.rewriteOps - rewriteCost.rewriteOps + 1 ≤
          budget.rewriteOps - rewriteCost.rewriteOps + rewriteCost.rewriteOps :=
        Nat.add_le_add_left hOneLeCost _
      _ = budget.rewriteOps := Nat.sub_add_cancel hOpsBound
  exact _root_.le_trans hStepBound hBudgetAfterBound

/-- `rewriteChain_steps_le_rewriteOps` bounds chain length by operation budget. -/
theorem rewriteChain_steps_le_rewriteOps
    {g gFinal : Graph α}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (hChain : RewriteChain contractOk g budget gFinal finalBudget steps) :
    steps ≤ budget.rewriteOps := by
  induction hChain with
  | done =>
      exact Nat.zero_le _
  | step r hAdmissible _hApply hBudgetAfter _tail ih =>
      exact
        rewrite_step_budget_bound
          ih
          hBudgetAfter
          r.rewriteOps_positive
          hAdmissible.1.2.2.2.2

/-- `rewriteChain_finalBudget_le_initial` records that rewrite chains never replenish budget. -/
theorem rewriteChain_finalBudget_le_initial
    {g gFinal : Graph α}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (hChain : RewriteChain contractOk g budget gFinal finalBudget steps) :
    finalBudget.le budget := by
  induction hChain with
  | done =>
      exact RewriteBudget.le_refl _
  | step r _hAdmissible _hApply hBudgetAfter _tail ih =>
      rw [hBudgetAfter] at ih
      exact RewriteBudget.le_trans ih (RewriteBudget.consume_le _ r.cost)

/-- `rewriteChain_preserves_acyclic` lifts acyclicity preservation to rewrite chains. -/
theorem rewriteChain_preserves_acyclic
    {g gFinal : Graph α}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (hChain : RewriteChain contractOk g budget gFinal finalBudget steps)
    (hAcyclic : Acyclic g) :
    Acyclic gFinal := by
  induction hChain with
  | done =>
      exact hAcyclic
  | step r hAdmissible hApply _hBudgetAfter _tail ih =>
      exact ih (admissible_preserves_acyclic r hAdmissible hApply hAcyclic)

/-- `rewriteChain_preserves_contracts` lifts contract preservation to rewrite chains. -/
theorem rewriteChain_preserves_contracts
    {g gFinal : Graph α}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (hChain : RewriteChain contractOk g budget gFinal finalBudget steps)
    (hContracts : contractOk g) :
    contractOk gFinal := by
  induction hChain with
  | done =>
      exact hContracts
  | step r hAdmissible hApply _hBudgetAfter _tail ih =>
      exact ih (admissible_preserves_contracts r hAdmissible hApply hContracts)

end RewriteChains

/-- `rewriteChain_preserves_registryBoundary` lifts registry-boundary preservation to chains. -/
theorem rewriteChain_preserves_registryBoundary
    {executor config contract authority : Type}
    [DecidableEq contract]
    [DecidableEq (StagedExecutorNode executor config authority)]
    (registry : ExecutorRegistry executor config contract authority)
    {g gFinal : Graph (StagedExecutorNode executor config authority)}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (hChain :
      RewriteChain
        (registryBoundary registry)
        g
        budget
        gFinal
        finalBudget
        steps)
    (hBoundary : registryBoundary registry g) :
    registryBoundary registry gFinal :=
  rewriteChain_preserves_contracts hChain hBoundary

end Cortex.Wire
