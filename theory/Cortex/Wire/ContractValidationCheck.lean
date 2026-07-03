import Cortex.Wire.ContractValidation

/-!
## Overview

Executable checker for the Wire contract-schema validator dialect (ADR 0085),
with soundness and completeness against the Prop-level `SchemaAccepts`.

`schemaAcceptsCheck` mirrors the Haskell validator's per-node checks in the
same source order (enum, type, string bounds, number bounds, object checks,
array checks); `schemaAcceptsCheck_iff` proves it decides `SchemaAccepts`
exactly, and the derived `Decidable` instance lets emitted fixtures discharge
both acceptance and rejection theorems by `native_decide`.

## Context

The pattern is the house triad from
`Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck`: a Prop-level predicate, a
Bool-level executable check, and a `_sound` bridging theorem — here
strengthened to an `_iff` since the checker is total and each clause is
decidable, so completeness is free from the same induction.
-/

namespace Cortex.Wire
namespace ContractValidation

/-- Executable `enum` clause. -/
def enumCheck (enum? : Option (List Json)) (payload : Json) : Bool :=
  match enum? with
  | none => true
  | some allowed => decide (payload ∈ allowed)

theorem enumCheck_iff (enum? : Option (List Json)) (payload : Json) :
    enumCheck enum? payload = true ↔ EnumAccepts enum? payload := by
  cases enum? <;> simp [enumCheck, EnumAccepts]

/-- Executable `type` clause. -/
def typeCheck (types : List String) (payload : Json) : Bool :=
  types.isEmpty || types.any fun typeName => Json.typeNameAdmits typeName payload

theorem typeCheck_iff (types : List String) (payload : Json) :
    typeCheck types payload = true ↔ TypeAccepts types payload := by
  simp [typeCheck, TypeAccepts, List.isEmpty_iff]

/-- Executable string length bounds. -/
def stringBoundsCheck (minLength? maxLength? : Option Int) (payload : Json) : Bool :=
  match payload with
  | .str s =>
      (match minLength? with
        | some bound => decide (bound ≤ (s.length : Int))
        | none => true)
        && (match maxLength? with
            | some bound => decide ((s.length : Int) ≤ bound)
            | none => true)
  | .null => true
  | .bool _ => true
  | .num _ => true
  | .arr _ => true
  | .obj _ => true

theorem stringBoundsCheck_iff (minLength? maxLength? : Option Int) (payload : Json) :
    stringBoundsCheck minLength? maxLength? payload = true
      ↔ StringBoundsAccept minLength? maxLength? payload := by
  cases payload <;> cases minLength? <;> cases maxLength? <;>
    simp [stringBoundsCheck, StringBoundsAccept]

/-- Executable numeric bounds. -/
def numberBoundsCheck (minimum? maximum? : Option Rat) (payload : Json) : Bool :=
  match payload with
  | .num q =>
      (match minimum? with
        | some bound => decide (bound ≤ q)
        | none => true)
        && (match maximum? with
            | some bound => decide (q ≤ bound)
            | none => true)
  | .null => true
  | .bool _ => true
  | .str _ => true
  | .arr _ => true
  | .obj _ => true

theorem numberBoundsCheck_iff (minimum? maximum? : Option Rat) (payload : Json) :
    numberBoundsCheck minimum? maximum? payload = true
      ↔ NumberBoundsAccept minimum? maximum? payload := by
  cases payload <;> cases minimum? <;> cases maximum? <;>
    simp [numberBoundsCheck, NumberBoundsAccept]

/-- Executable `required` clause. -/
def requiredCheck (required : List String) (fields : List (String × Json)) : Bool :=
  required.all fun key => (lookupKey fields key).isSome

theorem requiredCheck_iff (required : List String) (fields : List (String × Json)) :
    requiredCheck required fields = true ↔ RequiredPresent required fields := by
  simp [requiredCheck, RequiredPresent]

/-- Executable `additionalProperties` clause. -/
def additionalCheck
    (properties : List (String × SchemaNode))
    (additionalProperties? : Option Bool)
    (fields : List (String × Json)) : Bool :=
  match additionalProperties? with
  | some false => fields.all fun field => (lookupKey properties field.1).isSome
  | some true => true
  | none => true

theorem additionalCheck_iff
    (properties : List (String × SchemaNode))
    (additionalProperties? : Option Bool)
    (fields : List (String × Json)) :
    additionalCheck properties additionalProperties? fields = true
      ↔ AdditionalAllowed properties additionalProperties? fields := by
  cases additionalProperties? with
  | none => simp [additionalCheck, AdditionalAllowed]
  | some flag => cases flag <;> simp [additionalCheck, AdditionalAllowed]

/-- Executable acceptance check, mirroring the Haskell validator's per-node
check order. Recursion is on the schema, never the payload. -/
def schemaAcceptsCheck : SchemaNode → Json → Bool
  | .mk types enum? required properties additionalProperties? items?
      minLength? maxLength? minimum? maximum?, payload =>
    enumCheck enum? payload
      && typeCheck types payload
      && stringBoundsCheck minLength? maxLength? payload
      && numberBoundsCheck minimum? maximum? payload
      && (match payload with
          | .obj fields =>
              requiredCheck required fields
                && properties.attach.all
                    (fun pair =>
                      match lookupKey fields pair.1.1 with
                      | some value => schemaAcceptsCheck pair.1.2 value
                      | none => true)
                && additionalCheck properties additionalProperties? fields
          | .null => true
          | .bool _ => true
          | .num _ => true
          | .str _ => true
          | .arr _ => true)
      && (match items?, payload with
          | some itemSchema, .arr elems =>
              elems.all fun element => schemaAcceptsCheck itemSchema element
          | _, _ => true)
termination_by schema _ => sizeOf schema
decreasing_by
  · have hPairSize := List.sizeOf_lt_of_mem pair.2
    have hValueSize : sizeOf pair.1.2 ≤ sizeOf pair.1 := by
      obtain ⟨⟨key, subSchema⟩, hMem⟩ := pair
      simp +arith
    simp only [SchemaNode.mk.sizeOf_spec]
    omega
  · simp only [SchemaNode.mk.sizeOf_spec, Option.some.sizeOf_spec]
    omega

theorem schemaAcceptsCheck_iff_aux :
    ∀ (fuel : Nat) (schema : SchemaNode) (payload : Json), sizeOf schema ≤ fuel →
      (schemaAcceptsCheck schema payload = true ↔ SchemaAccepts schema payload) := by
  intro fuel
  induction fuel with
  | zero =>
    intro schema payload hFuel
    cases schema
    simp +arith at hFuel
  | succ n ih =>
    intro schema payload hFuel
    cases schema with
    | mk types enum? required properties additionalProperties? items?
        minLength? maxLength? minimum? maximum? =>
      have hPropSize : ∀ key subSchema, (key, subSchema) ∈ properties → sizeOf subSchema ≤ n := by
        intro key subSchema hMem
        have hPair := List.sizeOf_lt_of_mem hMem
        simp only [Prod.mk.sizeOf_spec] at hPair
        simp only [SchemaNode.mk.sizeOf_spec] at hFuel
        omega
      have hItemSize : ∀ itemSchema, items? = some itemSchema → sizeOf itemSchema ≤ n := by
        intro itemSchema hEq
        subst hEq
        simp only [SchemaNode.mk.sizeOf_spec, Option.some.sizeOf_spec] at hFuel
        omega
      unfold schemaAcceptsCheck SchemaAccepts
      simp only [Bool.and_eq_true, and_assoc]
      rw [enumCheck_iff, typeCheck_iff, stringBoundsCheck_iff, numberBoundsCheck_iff]
      refine and_congr .rfl (and_congr .rfl (and_congr .rfl (and_congr .rfl
        (and_congr ?_ ?_))))
      · -- object clause
        cases payload with
        | obj fields =>
          show (requiredCheck required fields
              && properties.attach.all
                  (fun pair =>
                    match lookupKey fields pair.1.1 with
                    | some value => schemaAcceptsCheck pair.1.2 value
                    | none => true)
              && additionalCheck properties additionalProperties? fields) = true ↔ _
          simp only [Bool.and_eq_true, and_assoc]
          rw [requiredCheck_iff, additionalCheck_iff]
          refine and_congr .rfl (and_congr ?_ .rfl)
          rw [List.all_eq_true]
          constructor
          · intro hAll key subSchema hMem value hLookup
            have hPair :
                (match lookupKey fields key with
                  | some value => schemaAcceptsCheck subSchema value
                  | none => true) = true :=
              hAll ⟨(key, subSchema), hMem⟩ (List.mem_attach _ _)
            rw [hLookup] at hPair
            exact (ih subSchema value (hPropSize key subSchema hMem)).mp hPair
          · intro hProp pair hPairMem
            obtain ⟨⟨key, subSchema⟩, hMem⟩ := pair
            show (match lookupKey fields key with
                | some value => schemaAcceptsCheck subSchema value
                | none => true) = true
            cases hLookup : lookupKey fields key with
            | none => rfl
            | some value =>
              exact (ih subSchema value (hPropSize key subSchema hMem)).mpr
                (hProp key subSchema hMem value hLookup)
        | null => simp
        | bool b => simp
        | num q => simp
        | str s => simp
        | arr elems => simp
      · -- items clause
        cases items? with
        | none => cases payload <;> simp
        | some itemSchema =>
          have hSize := hItemSize itemSchema rfl
          cases payload with
          | arr elems =>
            show (elems.all fun element => schemaAcceptsCheck itemSchema element) = true ↔ _
            rw [List.all_eq_true]
            exact ⟨fun hAll element hMem => (ih itemSchema element hSize).mp (hAll element hMem),
              fun hProp element hMem => (ih itemSchema element hSize).mpr (hProp element hMem)⟩
          | null => simp
          | bool b => simp
          | num q => simp
          | str s => simp
          | obj fields => simp

/-- The executable check decides acceptance exactly. -/
theorem schemaAcceptsCheck_iff (schema : SchemaNode) (payload : Json) :
    schemaAcceptsCheck schema payload = true ↔ SchemaAccepts schema payload :=
  schemaAcceptsCheck_iff_aux (sizeOf schema) schema payload (Nat.le_refl _)

/-- House-pattern soundness: a passing check yields acceptance. -/
theorem schemaAcceptsCheck_sound {schema : SchemaNode} {payload : Json}
    (hCheck : schemaAcceptsCheck schema payload = true) : SchemaAccepts schema payload :=
  (schemaAcceptsCheck_iff schema payload).mp hCheck

/-- Completeness: acceptance is always detected by the check. -/
theorem schemaAcceptsCheck_complete {schema : SchemaNode} {payload : Json}
    (hAccepts : SchemaAccepts schema payload) : schemaAcceptsCheck schema payload = true :=
  (schemaAcceptsCheck_iff schema payload).mpr hAccepts

instance (schema : SchemaNode) (payload : Json) : Decidable (SchemaAccepts schema payload) :=
  decidable_of_iff _ (schemaAcceptsCheck_iff schema payload)

/-- Executable missing-schema gate. -/
def schemaOptAcceptsCheck (schema? : Option SchemaNode) (payload : Json) : Bool :=
  match schema? with
  | none => true
  | some schema => schemaAcceptsCheck schema payload

theorem schemaOptAcceptsCheck_iff (schema? : Option SchemaNode) (payload : Json) :
    schemaOptAcceptsCheck schema? payload = true ↔ SchemaOptAccepts schema? payload := by
  cases schema? <;> simp [schemaOptAcceptsCheck, SchemaOptAccepts, schemaAcceptsCheck_iff]

instance (schema? : Option SchemaNode) (payload : Json) :
    Decidable (SchemaOptAccepts schema? payload) :=
  decidable_of_iff _ (schemaOptAcceptsCheck_iff schema? payload)

end ContractValidation
end Cortex.Wire
