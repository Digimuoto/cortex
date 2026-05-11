import Mathlib.Data.List.Perm.Basic

/-!
## Overview

Reusable boolean checker combinators for decoded Wire admission artifacts.

Each helper is intentionally small: a checker returns `Bool`, and its paired
soundness theorem converts `check = true` into the proof-facing predicate. These
are Lean-side soundness combinators, not standalone proofs that the Haskell
validator uses the same algorithm. Artifact-specific modules keep the semantic
predicates and any Haskell-correspondence obligations.
-/

namespace Cortex.Wire
namespace AdmissionArtifact
namespace Check

/-! ## Decidable Propositions -/

/-- Boolean form of a decidable proposition. -/
def propCheck (predicate : Prop) [Decidable predicate] : Bool :=
  decide predicate

/-- Successful proposition checking returns the proposition. -/
theorem propCheck_sound
    {predicate : Prop}
    [Decidable predicate]
    (hCheck : propCheck predicate = true) :
    predicate :=
  of_decide_eq_true hCheck

/-! ## List Quantifiers -/

/-- Boolean universal quantification over a decoded finite row list. -/
def allDecide {α : Type}
    (items : List α)
    (predicate : α → Prop)
    [DecidablePred predicate] :
    Bool :=
  items.all fun item => decide (predicate item)

/-- A successful finite boolean universal check supplies the corresponding predicate. -/
theorem allDecide_sound
    {α : Type}
    {items : List α}
    {predicate : α → Prop}
    [DecidablePred predicate]
    (hCheck : allDecide items predicate = true) :
    ∀ item, item ∈ items → predicate item := by
  intro item hItem
  have hItemCheck :
      decide (predicate item) = true :=
    (List.all_eq_true.mp hCheck) item hItem
  exact of_decide_eq_true hItemCheck

/-- Boolean universal quantification for row checkers that already return `Bool`. -/
def allBool {α : Type} (items : List α) (check : α → Bool) : Bool :=
  items.all check

/-- A successful finite boolean universal check transports through local soundness. -/
theorem allBool_sound
    {α : Type}
    {items : List α}
    {check : α → Bool}
    {predicate : α → Prop}
    (hCheck : allBool items check = true)
    (hSound :
      ∀ item, item ∈ items → check item = true → predicate item) :
    ∀ item, item ∈ items → predicate item := by
  intro item hItem
  exact hSound item hItem ((List.all_eq_true.mp hCheck) item hItem)

/-- Boolean existential search over a decoded finite row list. -/
def anyDecide {α : Type}
    (items : List α)
    (predicate : α → Prop)
    [DecidablePred predicate] :
    Bool :=
  items.any fun item => decide (predicate item)

/-- A successful finite boolean existential check supplies a matching row. -/
theorem anyDecide_sound
    {α : Type}
    {items : List α}
    {predicate : α → Prop}
    [DecidablePred predicate]
    (hCheck : anyDecide items predicate = true) :
    ∃ item, item ∈ items ∧ predicate item := by
  rcases List.any_eq_true.mp hCheck with ⟨item, hItem, hPredicate⟩
  exact ⟨item, hItem, of_decide_eq_true hPredicate⟩

/-! ## Standard Row Properties -/

/-- Boolean duplicate-freedom check for a decoded list. -/
def nodupCheck {α : Type} [DecidableEq α] (items : List α) : Bool :=
  propCheck items.Nodup

/-- Successful duplicate-freedom checking proves `List.Nodup`. -/
theorem nodupCheck_sound
    {α : Type}
    [DecidableEq α]
    {items : List α}
    (hCheck : nodupCheck items = true) :
    items.Nodup :=
  propCheck_sound hCheck

/-- Boolean duplicate-freedom check for a projected key list. -/
def nodupMapCheck {α β : Type}
    [DecidableEq β]
    (items : List α)
    (key : α → β) :
    Bool :=
  nodupCheck (items.map key)

/-- Successful projected duplicate-freedom checking proves `List.Nodup` for the keys. -/
theorem nodupMapCheck_sound
    {α β : Type}
    [DecidableEq β]
    {items : List α}
    {key : α → β}
    (hCheck : nodupMapCheck items key = true) :
    (items.map key).Nodup :=
  nodupCheck_sound hCheck

/-- Boolean permutation check for two decoded lists. -/
def permCheck {α : Type} [DecidableEq α] (left right : List α) : Bool :=
  propCheck (left.Perm right)

/-- Successful permutation checking proves `List.Perm`. -/
theorem permCheck_sound
    {α : Type}
    [DecidableEq α]
    {left right : List α}
    (hCheck : permCheck left right = true) :
    left.Perm right :=
  propCheck_sound hCheck

/-- Boolean membership check for a decoded finite list. -/
def memCheck {α : Type} [DecidableEq α] (item : α) (items : List α) : Bool :=
  propCheck (item ∈ items)

/-- Successful membership checking proves list membership. -/
theorem memCheck_sound
    {α : Type}
    [DecidableEq α]
    {item : α}
    {items : List α}
    (hCheck : memCheck item items = true) :
    item ∈ items :=
  propCheck_sound hCheck

/-- Boolean set-style equality for lists, ignoring multiplicity and order. -/
def sameMembersCheck {α : Type} [DecidableEq α] (left right : List α) : Bool :=
  allDecide left (fun item => item ∈ right) &&
    allDecide right (fun item => item ∈ left)

/-- Successful set-style equality checking proves membership equivalence. -/
theorem sameMembersCheck_sound
    {α : Type}
    [DecidableEq α]
    {left right : List α}
    (hCheck : sameMembersCheck left right = true) :
    ∀ item, item ∈ left ↔ item ∈ right := by
  unfold sameMembersCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  intro item
  constructor
  · intro hItem
    exact allDecide_sound hCheck.left item hItem
  · intro hItem
    exact allDecide_sound hCheck.right item hItem

/-! ## Gated Pair Checks -/

/-- Check all pairs that satisfy a decidable gate. Ungated pairs are ignored. -/
def allPairsWhenCheck
    {α β : Type}
    (left : List α)
    (right : List β)
    (condition : α → β → Prop)
    [DecidableRel condition]
    (check : α → β → Bool) :
    Bool :=
  left.all fun leftItem =>
    right.all fun rightItem =>
      if condition leftItem rightItem then
        check leftItem rightItem
      else
        true

/-- Successful gated-pair checking proves the target predicate for every gated pair. -/
theorem allPairsWhenCheck_sound
    {α β : Type}
    {left : List α}
    {right : List β}
    {condition : α → β → Prop}
    [DecidableRel condition]
    {check : α → β → Bool}
    {predicate : α → β → Prop}
    (hCheck : allPairsWhenCheck left right condition check = true)
    (hSound :
      ∀ leftItem, leftItem ∈ left →
        ∀ rightItem, rightItem ∈ right →
          check leftItem rightItem = true → predicate leftItem rightItem) :
    ∀ leftItem, leftItem ∈ left →
      ∀ rightItem, rightItem ∈ right →
        condition leftItem rightItem → predicate leftItem rightItem := by
  intro leftItem hLeft rightItem hRight hCondition
  unfold allPairsWhenCheck at hCheck
  have hLeftCheck :=
    (List.all_eq_true.mp hCheck) leftItem hLeft
  have hRightCheck :=
    (List.all_eq_true.mp hLeftCheck) rightItem hRight
  by_cases hConditionCheck : condition leftItem rightItem
  · simp [hConditionCheck] at hRightCheck
    exact hSound leftItem hLeft rightItem hRight hRightCheck
  · exact False.elim (hConditionCheck hCondition)

end Check
end AdmissionArtifact
end Cortex.Wire
