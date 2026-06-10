import Cortex.Wire.GraphElaboration
import Mathlib.Data.Finset.Sort
import Mathlib.Data.Prod.Lex
import Mathlib.Data.String.Basic
import Mathlib.Order.RelClasses

/-!
## Overview

Executable admission kernel for the primitive graph-expression subset: an
`elaborate` function that computes the certified graph for `empty`, `node`,
`binding`, `overlay`, and `connect`, together with its `Admits` derivation.

`GraphElaboration.Admits` is relational: callers supply `Disjoint` witnesses
and a `BoundaryMatchTrace` whose `determined` field pins the contracted pairs
to exactly the ADR 0047-compatible frontier pairs. This module supplies the
executable side: a decidable disjointness check, a boundary matcher that
computes the compatible pairs and rejects non-functional matchings (the
fan-in/fan-out/ambiguity rejections of the Haskell compiler), a certified
bulk-contraction builder, and the certifying elaborator that returns the
admitted graph bundled with its derivation. Soundness is by construction:
`(elaborate mod expr).ok` carries `Admits mod expr graph` as data, so there
is no separate trust step between the executable path and the relation.

Derived forms (`star`, `select`, `make`, `makeEach`) return a named
`unsupportedForm` error in this slice; their certified shapes have their own
acceptance functions and join the kernel when binding admission unfolds
right-hand sides.
-/

namespace Cortex.Wire
namespace ElaborationIR

open Cortex.Wire.LinearPortGraph

/-- Rejection reasons of the executable primitive kernel. The constructors
mirror the Haskell compiler's rejection surface for the primitive subset. -/
inductive ElabError where
  /-- `node` reference without an accepted declaration. -/
  | unknownNode (target : NodeId)
  /-- Graph-binding reference without an accepted binding. -/
  | unknownBinding (target : BindingName)
  /-- Overlay operands share a node, port instance, or binding reference. -/
  | overlayConflict
  /-- Connect operands share a node, port instance, or binding reference. -/
  | connectConflict
  /-- Boundary matching is not one-to-one on the compatible pairs. -/
  | ambiguousConnect
  /-- Derived forms are not part of the primitive kernel slice. -/
  | unsupportedForm
  deriving Repr

namespace CertifiedGraph

variable {mod : AdmittedModuleShell}

/-! ## Decidable Disjointness -/

/-- Executable disjointness for two certified graphs: empty intersections at
every level the `Disjoint` certificate quantifies over. -/
def disjointCheck (lhs rhs : CertifiedGraph mod) : Bool :=
  decide (lhs.object.graph.nodes ∩ rhs.object.graph.nodes = ∅) &&
    decide (lhs.object.graph.outputs ∩ rhs.object.graph.outputs = ∅) &&
      decide (lhs.object.graph.inputs ∩ rhs.object.graph.inputs = ∅) &&
        decide (lhs.usedRefs ∩ rhs.usedRefs = ∅)

/-- Membership refutation from an empty intersection. -/
theorem not_mem_both_of_inter_empty
    {α : Type} [DecidableEq α] {left right : Finset α}
    (hEmpty : left ∩ right = ∅) :
    ∀ a, a ∈ left → a ∈ right → False := by
  intro a hLeft hRight
  have hMem : a ∈ left ∩ right := Finset.mem_inter.mpr ⟨hLeft, hRight⟩
  rw [hEmpty] at hMem
  exact absurd hMem (Finset.notMem_empty a)

/-- The executable disjointness check certifies `Disjoint`. -/
theorem disjoint_of_disjointCheck
    {lhs rhs : CertifiedGraph mod}
    (hCheck : disjointCheck lhs rhs = true) :
    Disjoint lhs rhs := by
  have hParts := hCheck
  simp only [disjointCheck, Bool.and_eq_true, decide_eq_true_eq] at hParts
  obtain ⟨⟨⟨hNodes, hOutputs⟩, hInputs⟩, hRefs⟩ := hParts
  exact
    { domain :=
        ⟨ not_mem_both_of_inter_empty hNodes
        , not_mem_both_of_inter_empty hOutputs
        , not_mem_both_of_inter_empty hInputs
        ⟩
    , refs := not_mem_both_of_inter_empty hRefs
    }

/-! ## Executable Boundary Matching

The matcher sorts the compatible pair set into a canonical list, which needs a
linear order on port instances. The orders below are lexicographic lifts of
the underlying source names; they are scoped to this namespace because they
exist for sorting only and carry no semantic content.
-/

/-- Name-lexicographic order on node identifiers, for canonical sorting. -/
scoped instance : LinearOrder NodeId :=
  LinearOrder.lift' NodeId.name fun a b h => by
    cases a
    cases b
    simpa using h

/-- Name-lexicographic order on field labels, for canonical sorting. -/
scoped instance : LinearOrder FieldLabel :=
  LinearOrder.lift' FieldLabel.name fun a b h => by
    cases a
    cases b
    simpa using h

/-- Name-lexicographic order on contract identifiers, for canonical sorting. -/
scoped instance : LinearOrder ContractId :=
  LinearOrder.lift' ContractId.name fun a b h => by
    cases a
    cases b
    simpa using h

/-- Lexicographic order on port signatures, for canonical sorting. -/
scoped instance : LinearOrder PortSignature :=
  LinearOrder.lift' (fun s => toLex (s.label, s.contract)) fun a b h => by
    cases a
    cases b
    simpa [Prod.ext_iff] using toLex.injective h

/-- Signature order on output-direction wrappers, for canonical sorting. -/
scoped instance : LinearOrder OutputPortSignature :=
  LinearOrder.lift' OutputPortSignature.signature fun a b h => by
    cases a
    cases b
    simpa using h

/-- Signature order on input-direction wrappers, for canonical sorting. -/
scoped instance : LinearOrder InputPortSignature :=
  LinearOrder.lift' InputPortSignature.signature fun a b h => by
    cases a
    cases b
    simpa using h

/-- Injective lexicographic key for matched boundary pairs. `Prod` already
carries the componentwise (non-total) order, so the matcher sorts by an
explicit relation through this key instead of overloading `≤`. -/
def pairKey
    (pair :
      SourcePortInstance NodeId OutputPortSignature ×
        SourcePortInstance NodeId InputPortSignature) :
    (NodeId ×ₗ OutputPortSignature) ×ₗ (NodeId ×ₗ InputPortSignature) :=
  toLex (toLex (pair.1.node, pair.1.port), toLex (pair.2.node, pair.2.port))

theorem pairKey_injective : Function.Injective pairKey := by
  intro a b h
  obtain ⟨⟨aNode, aPort⟩, ⟨aInNode, aInPort⟩⟩ := a
  obtain ⟨⟨bNode, bPort⟩, ⟨bInNode, bInPort⟩⟩ := b
  have hOuter := toLex.injective h
  rw [Prod.ext_iff] at hOuter
  have hLeft := toLex.injective hOuter.1
  have hRight := toLex.injective hOuter.2
  simp_all [Prod.ext_iff]

/-- Canonical sorting relation for matched boundary pairs. -/
def pairLe
    (left right :
      SourcePortInstance NodeId OutputPortSignature ×
        SourcePortInstance NodeId InputPortSignature) :
    Prop :=
  pairKey left ≤ pairKey right

/-- The sorting relation is decidable through its key. -/
instance : DecidableRel pairLe :=
  fun left right => inferInstanceAs (Decidable (pairKey left ≤ pairKey right))

/-- The sorting relation is transitive through its key. -/
instance : IsTrans _ pairLe :=
  ⟨fun _ _ _ hLeft hRight => le_trans hLeft hRight⟩

/-- The sorting relation is antisymmetric because the key is injective. -/
instance : Std.Antisymm pairLe :=
  ⟨fun _ _ hLeft hRight => pairKey_injective (le_antisymm hLeft hRight)⟩

/-- The sorting relation is total through its key. -/
instance : Std.Total pairLe :=
  ⟨fun left right => le_total (pairKey left) (pairKey right)⟩

/-- All ADR 0047-compatible frontier pairs of a prospective `lhs => rhs`:
exposed left outputs against exposed right inputs with equal source port
signatures, in canonical sorted order. -/
def compatiblePairs (lhs rhs : CertifiedGraph mod) :
    List
      (SourcePortInstance NodeId OutputPortSignature ×
        SourcePortInstance NodeId InputPortSignature) :=
  ((lhs.object.graph.exposedOutputs ×ˢ rhs.object.graph.exposedInputs).filter
      (fun pair => pair.1.port.signature = pair.2.port.signature)).sort pairLe

/-- The computed pair list is exactly the `CompatiblePair` relation. -/
theorem mem_compatiblePairs
    {lhs rhs : CertifiedGraph mod}
    {output : SourcePortInstance NodeId OutputPortSignature}
    {input : SourcePortInstance NodeId InputPortSignature} :
    (output, input) ∈ compatiblePairs lhs rhs ↔ CompatiblePair lhs rhs output input := by
  unfold compatiblePairs
  rw [Finset.mem_sort, Finset.mem_filter, Finset.mem_product]
  simp [CompatiblePair, and_assoc]

/-! ## Certified Bulk-Contraction Construction -/

/-- Build a certified contraction trace for a list of pairwise-distinct
exposed pairs, bundled with the exact-pair-set characterization. The output-
and input-side `Nodup` premises are exactly the one-to-one matching
discipline: contracting the head pair erases only its own endpoints, so every
later pair stays exposed. -/
def buildBulkContract
    (graph : LinearPortGraph NodeId OutputPortSignature InputPortSignature)
    (pairs :
      List
        (SourcePortInstance NodeId OutputPortSignature ×
          SourcePortInstance NodeId InputPortSignature))
    (hOutputs : ∀ pair ∈ pairs, pair.1 ∈ graph.exposedOutputs)
    (hInputs : ∀ pair ∈ pairs, pair.2 ∈ graph.exposedInputs)
    (hOutputsNodup : (pairs.map Prod.fst).Nodup)
    (hInputsNodup : (pairs.map Prod.snd).Nodup) :
    (finish : LinearPortGraph NodeId OutputPortSignature InputPortSignature) ×'
      (bulk : BulkContract graph finish) ×'
        ∀ output input,
          BulkContractContainsPair bulk output input ↔ (output, input) ∈ pairs :=
  match pairs, hOutputs, hInputs, hOutputsNodup, hInputsNodup with
  | [], _, _, _, _ =>
      ⟨ graph
      , BulkContract.done graph
      , fun output input => by simp [BulkContractContainsPair]
      ⟩
  | (output, input) :: rest, hOutputs, hInputs, hOutputsNodup, hInputsNodup =>
      let hOutputExposed : output ∈ graph.exposedOutputs :=
        hOutputs (output, input) (List.mem_cons_self ..)
      let hInputExposed : input ∈ graph.exposedInputs :=
        hInputs (output, input) (List.mem_cons_self ..)
      let tail :=
        buildBulkContract (graph.contract output input hOutputExposed hInputExposed) rest
          (fun pair hPair =>
            Finset.mem_erase.mpr
              ⟨ fun hEq =>
                  (List.nodup_cons.mp hOutputsNodup).1
                    (by
                      have hMem := List.mem_map_of_mem (f := Prod.fst) hPair
                      rwa [hEq] at hMem)
              , hOutputs pair (List.mem_cons_of_mem _ hPair)
              ⟩)
          (fun pair hPair =>
            Finset.mem_erase.mpr
              ⟨ fun hEq =>
                  (List.nodup_cons.mp hInputsNodup).1
                    (by
                      have hMem := List.mem_map_of_mem (f := Prod.snd) hPair
                      rwa [hEq] at hMem)
              , hInputs pair (List.mem_cons_of_mem _ hPair)
              ⟩)
          (List.nodup_cons.mp hOutputsNodup).2
          (List.nodup_cons.mp hInputsNodup).2
      ⟨ tail.1
      , BulkContract.step graph output input hOutputExposed hInputExposed tail.2.1
      , fun candidateOutput candidateInput => by
          show
            (candidateOutput = output ∧ candidateInput = input) ∨
                BulkContractContainsPair tail.2.1 candidateOutput candidateInput ↔
              (candidateOutput, candidateInput) ∈ (output, input) :: rest
          rw [tail.2.2 candidateOutput candidateInput]
          simp [Prod.ext_iff]
      ⟩

/-! ## Connect Matching -/

/-- Compute a certified boundary trace for `lhs => rhs`, or reject when the
compatible pairs are not one-to-one. Mirrors the Haskell compiler's per-key
singleton discipline: a repeated output (fan-out), repeated input (fan-in), or
any other non-functional matching is an `ambiguousConnect`. -/
def matchBoundary
    (lhs rhs : CertifiedGraph mod)
    (hDisjoint : Disjoint lhs rhs) :
    Except ElabError (BoundaryMatchTrace lhs rhs hDisjoint) :=
  let pairs := compatiblePairs lhs rhs
  if hFunctional :
      ((pairs.map Prod.fst).Nodup ∧ (pairs.map Prod.snd).Nodup : Prop) then
    let overlayGraph :=
      (LinearPortObject.overlay lhs.object rhs.object hDisjoint.domain).graph
    let hOutputs :
        ∀ pair ∈ pairs, pair.1 ∈ overlayGraph.exposedOutputs :=
      fun pair hPair =>
        Finset.mem_union_left _
          ((mem_compatiblePairs.mp (by simpa using hPair)).1)
    let hInputs :
        ∀ pair ∈ pairs, pair.2 ∈ overlayGraph.exposedInputs :=
      fun pair hPair =>
        Finset.mem_union_right _
          ((mem_compatiblePairs.mp (by simpa using hPair)).2.1)
    let built :=
      buildBulkContract overlayGraph pairs hOutputs hInputs
        hFunctional.1 hFunctional.2
    .ok
      { finish := built.1
      , bulk := built.2.1
      , determined := by
          intro output input
          rw [built.2.2 output input]
          exact mem_compatiblePairs
      }
  else
    .error ElabError.ambiguousConnect

/-! ## The Certifying Elaborator -/

/-- Executable primitive admission: compute the certified graph for the
primitive subset together with its `Admits` derivation. Soundness is carried
in the return type, so an `ok` result is its own proof of admission. -/
def elaborate (mod : AdmittedModuleShell) :
    (expr : GraphExpr) →
      Except ElabError { graph : CertifiedGraph mod // Admits mod expr graph }
  | GraphExpr.empty =>
      .ok ⟨CertifiedGraph.empty, Admits.empty mod⟩
  | GraphExpr.node target =>
      match hFind : mod.nodes.find? (fun decl => decl.node = target) with
      | some decl =>
          .ok
            ⟨ CertifiedGraph.nodeOf decl
            , Admits.node decl
                (List.mem_of_find?_eq_some hFind)
                (by
                  have hPred := List.find?_some hFind
                  simpa using hPred)
            ⟩
      | none => .error (ElabError.unknownNode target)
  | GraphExpr.binding target =>
      if hRef : target ∈ mod.graphs.map GraphBinding.name then
        .ok ⟨CertifiedGraph.bindingOf target, Admits.binding hRef⟩
      else
        .error (ElabError.unknownBinding target)
  | GraphExpr.overlay leftExpr rightExpr => do
      let ⟨leftGraph, hLeft⟩ ← elaborate mod leftExpr
      let ⟨rightGraph, hRight⟩ ← elaborate mod rightExpr
      if hCheck : disjointCheck leftGraph rightGraph then
        let hDisjoint := disjoint_of_disjointCheck hCheck
        .ok
          ⟨ CertifiedGraph.overlayOf leftGraph rightGraph hDisjoint
          , Admits.overlay hLeft hRight hDisjoint
          ⟩
      else
        .error ElabError.overlayConflict
  | GraphExpr.connect leftExpr rightExpr => do
      let ⟨leftGraph, hLeft⟩ ← elaborate mod leftExpr
      let ⟨rightGraph, hRight⟩ ← elaborate mod rightExpr
      if hCheck : disjointCheck leftGraph rightGraph then
        let hDisjoint := disjoint_of_disjointCheck hCheck
        let matched ← matchBoundary leftGraph rightGraph hDisjoint
        .ok
          ⟨ CertifiedGraph.connectOf leftGraph rightGraph hDisjoint matched
          , Admits.connect hLeft hRight hDisjoint matched
          ⟩
      else
        .error ElabError.connectConflict
  | GraphExpr.star _ _ => .error ElabError.unsupportedForm
  | GraphExpr.select _ _ => .error ElabError.unsupportedForm
  | GraphExpr.make _ _ _ => .error ElabError.unsupportedForm
  | GraphExpr.makeEach _ _ _ => .error ElabError.unsupportedForm

/-- Soundness of the executable kernel, stated as the conventional corollary
of the certifying return type: every successful elaboration is admitted. -/
theorem elaborate_sound
    {mod : AdmittedModuleShell}
    {expr : GraphExpr}
    {result : { graph : CertifiedGraph mod // Admits mod expr graph }}
    (_hOk : elaborate mod expr = .ok result) :
    Admits mod expr result.val :=
  result.property

end CertifiedGraph

end ElaborationIR
end Cortex.Wire
