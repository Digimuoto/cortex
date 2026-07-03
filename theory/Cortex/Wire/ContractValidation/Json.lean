/-!
## Overview

JSON payload model for the Wire contract-schema validator dialect (ADR 0085).

The Haskell enforcement pass (`Cortex.Wire.ContractValidation`) validates
Aeson values; this inductive is its Lean image. Numbers are core `Rat`, the
exact image of Haskell `Scientific` under `toRational`: `Rat` is always
normalized, so structural equality coincides with numeric equality (needed by
`enum`), decidable `≤`/`<` mirror the `Scientific` `Ord`, and `Rat.isInt` is
exactly `Scientific.isInteger`.

## Context

Objects are association lists under a canonical-form invariant: the fixture
emitter renders object fields with strictly ascending, duplicate-free keys, so
structural equality coincides with Aeson's order-insensitive `KeyMap`
equality on every emitted value. The invariant is stated as `Json.Canonical`
(executable form `Json.canonicalCheck`) and pinned by a `#guard` on every
payload in the emitted fixture modules; the validator theorems do not require
it as a hypothesis.
String length: Lean `String.length` counts Unicode scalar values, identical to
`Data.Text.length`, so the `minLength`/`maxLength` semantics transfer without
a caveat. Equality is hand-written (`Json.beq` with `Json.beq_iff_eq`) because
the `DecidableEq` deriving handler does not support nested inductives.
-/

namespace Cortex.Wire
namespace ContractValidation

/-- JSON payload value, the Lean image of an Aeson value. -/
inductive Json : Type where
  | null : Json
  | bool (b : Bool) : Json
  | num (q : Rat) : Json
  | str (s : String) : Json
  | arr (elems : List Json) : Json
  | obj (fields : List (String × Json)) : Json

/-- First-match key lookup on an association list (object fields, schema
properties). Under the canonical duplicate-free invariant, first-match agrees
with Aeson `KeyMap.lookup`. -/
def lookupKey : List (String × α) → String → Option α
  | [], _ => none
  | (name, value) :: rest, key => if name = key then some value else lookupKey rest key

/-- Adjacent keys strictly ascend on an association list. Strict ascent
implies duplicate-free keys, and on values satisfying it structural list
equality coincides with Aeson's order-insensitive `KeyMap` equality. -/
def KeysAscending : List (String × α) → Prop
  | [] => True
  | [_] => True
  | a :: b :: rest => a.1 < b.1 ∧ KeysAscending (b :: rest)

/-- Executable form of `KeysAscending`. -/
def keysAscendingCheck : List (String × α) → Bool
  | [] => true
  | [_] => true
  | a :: b :: rest => decide (a.1 < b.1) && keysAscendingCheck (b :: rest)

theorem keysAscendingCheck_iff (entries : List (String × α)) :
    keysAscendingCheck entries = true ↔ KeysAscending entries := by
  induction entries with
  | nil => simp [keysAscendingCheck, KeysAscending]
  | cons a rest ih =>
    cases rest with
    | nil => simp [keysAscendingCheck, KeysAscending]
    | cons b tail =>
      simp [keysAscendingCheck, KeysAscending, Bool.and_eq_true] at ih ⊢
      simp [ih]

/-- A lookup hit witnesses membership of the association pair. -/
theorem lookupKey_some_mem {entries : List (String × α)} {key : String} {value : α}
    (hLookup : lookupKey entries key = some value) : (key, value) ∈ entries := by
  induction entries with
  | nil => simp [lookupKey] at hLookup
  | cons head tail ih =>
    obtain ⟨name, entry⟩ := head
    by_cases hEq : name = key
    · subst hEq
      simp [lookupKey] at hLookup
      simp [hLookup]
    · simp [lookupKey, hEq] at hLookup
      exact List.mem_cons_of_mem _ (ih hLookup)

namespace Json

mutual
  /-- Structural equality on payloads. -/
  def beq : Json → Json → Bool
    | .null, .null => true
    | .bool a, .bool b => a == b
    | .num a, .num b => a == b
    | .str a, .str b => a == b
    | .arr as, .arr bs => beqList as bs
    | .obj as, .obj bs => beqFields as bs
    | _, _ => false

  /-- Elementwise structural equality on payload lists. -/
  def beqList : List Json → List Json → Bool
    | [], [] => true
    | a :: as, b :: bs => beq a b && beqList as bs
    | _, _ => false

  /-- Pairwise structural equality on object field lists. -/
  def beqFields : List (String × Json) → List (String × Json) → Bool
    | [], [] => true
    | (keyA, valueA) :: as, (keyB, valueB) :: bs =>
        keyA == keyB && beq valueA valueB && beqFields as bs
    | _, _ => false
end

/-- Elementwise equality on payload lists is list equality, given pointwise
faithfulness of `beq` on the left elements. -/
theorem beqList_iff_of {as bs : List Json}
    (hElem : ∀ a ∈ as, ∀ b, beq a b = true ↔ a = b) :
    beqList as bs = true ↔ as = bs := by
  induction as generalizing bs with
  | nil => cases bs <;> simp [beqList]
  | cons a as ih =>
    cases bs with
    | nil => simp [beqList]
    | cons b bs =>
      have hHead := hElem a (List.mem_cons_self ..) b
      have hTail := ih (bs := bs) (fun x hx => hElem x (List.mem_cons_of_mem _ hx))
      simp [beqList, Bool.and_eq_true, hHead, hTail]

/-- Pairwise equality on field lists is list equality, given pointwise
faithfulness of `beq` on the left values. -/
theorem beqFields_iff_of {as bs : List (String × Json)}
    (hElem : ∀ pair ∈ as, ∀ b, beq pair.2 b = true ↔ pair.2 = b) :
    beqFields as bs = true ↔ as = bs := by
  induction as generalizing bs with
  | nil => cases bs <;> simp [beqFields]
  | cons a as ih =>
    obtain ⟨keyA, valueA⟩ := a
    cases bs with
    | nil => simp [beqFields]
    | cons b bs =>
      obtain ⟨keyB, valueB⟩ := b
      have hHead := hElem (keyA, valueA) (List.mem_cons_self ..) valueB
      have hTail := ih (bs := bs) (fun x hx => hElem x (List.mem_cons_of_mem _ hx))
      simp [beqFields, Bool.and_eq_true, hHead, hTail, and_assoc]

/-- `beq` decides propositional equality. -/
theorem beq_iff_eq (a b : Json) : beq a b = true ↔ a = b := by
  have aux : ∀ fuel (a b : Json), sizeOf a ≤ fuel → (beq a b = true ↔ a = b) := by
    intro fuel
    induction fuel with
    | zero =>
      intro a b hFuel
      cases a <;> simp +arith at hFuel
    | succ n ih =>
      intro a b hFuel
      cases a <;> cases b <;> simp_all only [beq] <;> try simp
      case succ.arr.arr as bs =>
        refine beqList_iff_of fun x hx c => ih x c ?_
        have := List.sizeOf_lt_of_mem hx
        simp +arith at hFuel
        omega
      case succ.obj.obj as bs =>
        refine beqFields_iff_of fun pair hPair c => ih pair.2 c ?_
        have hPairSize := List.sizeOf_lt_of_mem hPair
        have hValueSize : sizeOf pair.2 ≤ sizeOf pair := by
          obtain ⟨key, value⟩ := pair
          simp +arith
        simp +arith at hFuel
        omega
  exact aux (sizeOf a) a b (Nat.le_refl _)

instance : DecidableEq Json := fun a b => decidable_of_iff _ (beq_iff_eq a b)

/-- Canonical form: every object's field keys strictly ascend (hence are
duplicate-free), recursively through arrays and object values. The fixture
emitter renders every payload in canonical form; on canonical values Lean's
structural equality is Aeson's `KeyMap` equality and `lookupKey` agrees with
`KeyMap.lookup`. -/
def Canonical : Json → Prop
  | .null => True
  | .bool _ => True
  | .num _ => True
  | .str _ => True
  | .arr elems => ∀ element ∈ elems, Canonical element
  | .obj fields => KeysAscending fields ∧ ∀ field ∈ fields, Canonical field.2
termination_by payload => sizeOf payload
decreasing_by
  · have hElem := List.sizeOf_lt_of_mem ‹element ∈ elems›
    simp only [Json.arr.sizeOf_spec]
    omega
  · have hField := List.sizeOf_lt_of_mem ‹field ∈ fields›
    have hValue : sizeOf field.2 ≤ sizeOf field := by
      obtain ⟨key, value⟩ := field
      simp +arith
    simp only [Json.obj.sizeOf_spec]
    omega

/-- Executable form of `Canonical`; emitted fixtures `#guard` it for every
payload. -/
def canonicalCheck : Json → Bool
  | .null => true
  | .bool _ => true
  | .num _ => true
  | .str _ => true
  | .arr elems => elems.attach.all fun element => canonicalCheck element.1
  | .obj fields =>
      keysAscendingCheck fields
        && fields.attach.all fun field => canonicalCheck field.1.2
termination_by payload => sizeOf payload
decreasing_by
  · have hElem := List.sizeOf_lt_of_mem element.2
    simp only [Json.arr.sizeOf_spec]
    omega
  · have hField := List.sizeOf_lt_of_mem field.2
    have hValue : sizeOf field.1.2 ≤ sizeOf field.1 := by
      obtain ⟨⟨key, value⟩, hMem⟩ := field
      simp +arith
    simp only [Json.obj.sizeOf_spec]
    omega

theorem canonicalCheck_iff (payload : Json) :
    canonicalCheck payload = true ↔ Canonical payload := by
  have aux : ∀ fuel (payload : Json), sizeOf payload ≤ fuel →
      (canonicalCheck payload = true ↔ Canonical payload) := by
    intro fuel
    induction fuel with
    | zero =>
      intro payload hFuel
      cases payload <;> simp +arith at hFuel
    | succ n ih =>
      intro payload hFuel
      cases payload with
      | null => simp [canonicalCheck, Canonical]
      | bool b => simp [canonicalCheck, Canonical]
      | num q => simp [canonicalCheck, Canonical]
      | str s => simp [canonicalCheck, Canonical]
      | arr elems =>
        have hElemSize : ∀ element, element ∈ elems → sizeOf element ≤ n := by
          intro element hMem
          have := List.sizeOf_lt_of_mem hMem
          simp only [Json.arr.sizeOf_spec] at hFuel
          omega
        unfold canonicalCheck Canonical
        rw [List.all_eq_true]
        constructor
        · intro hAll element hMem
          have hCheck : canonicalCheck element = true :=
            hAll ⟨element, hMem⟩ (List.mem_attach _ _)
          exact (ih element (hElemSize element hMem)).mp hCheck
        · intro hProp pair hPairMem
          exact (ih pair.1 (hElemSize pair.1 pair.2)).mpr (hProp pair.1 pair.2)
      | obj fields =>
        have hFieldSize : ∀ field, field ∈ fields → sizeOf (Prod.snd field) ≤ n := by
          intro field hMem
          have hField := List.sizeOf_lt_of_mem hMem
          have hValue : sizeOf field.2 ≤ sizeOf field := by
            obtain ⟨key, value⟩ := field
            simp +arith
          simp only [Json.obj.sizeOf_spec] at hFuel
          omega
        unfold canonicalCheck Canonical
        simp only [Bool.and_eq_true]
        rw [keysAscendingCheck_iff, List.all_eq_true]
        refine and_congr .rfl ?_
        constructor
        · intro hAll field hMem
          have hCheck : canonicalCheck field.2 = true :=
            hAll ⟨field, hMem⟩ (List.mem_attach _ _)
          exact (ih field.2 (hFieldSize field hMem)).mp hCheck
        · intro hProp pair hPairMem
          exact (ih pair.1.2 (hFieldSize pair.1 pair.2)).mpr (hProp pair.1 pair.2)
  exact aux (sizeOf payload) payload (Nat.le_refl _)

instance (payload : Json) : Decidable (Canonical payload) :=
  decidable_of_iff _ (canonicalCheck_iff payload)

/-- Whether a dialect `type` name admits a payload. `integer` admits exactly
whole-valued numbers (`2.0` is an integer, `2.5` is not — mirroring
`Scientific.isInteger`); names outside the seven-name vocabulary admit
nothing. -/
def typeNameAdmits (name : String) (payload : Json) : Bool :=
  match name, payload with
  | "object", .obj _ => true
  | "array", .arr _ => true
  | "string", .str _ => true
  | "number", .num _ => true
  | "integer", .num q => q.isInt
  | "boolean", .bool _ => true
  | "null", .null => true
  | _, _ => false

end Json

end ContractValidation
end Cortex.Wire
