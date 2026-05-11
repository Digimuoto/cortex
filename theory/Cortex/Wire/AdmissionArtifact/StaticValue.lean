import Cortex.Wire.AdmissionArtifact.Boundary

/-!
## Overview

Static value rows for decoded Wire admission artifacts.

This page names the Lean-shaped static-value subset emitted for generated
`makeEach` rows and proves that conversion into `ElaborationIR.StaticValue`
preserves record labels and duplicate-field obligations.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Static Values -/

/-- Static value subset shared by Haskell `makeEach` artifacts and Lean `StaticValue`.

This deliberately omits general CorePure expressions: `makeEach` payloads that
feed a `Value` kind parameter must be strings, booleans, natural numbers, lists,
or records with field values in the same recursive subset before they can be
decoded into this carrier. Record keys are flat field labels; nested field paths
are rejected before artifact emission.
-/
inductive AdmissionStaticValue where
  | string (value : String)
  | bool (value : Bool)
  | nat (value : Nat)
  | list (values : List AdmissionStaticValue)
  | record (fields : List (FieldLabel × AdmissionStaticValue))
  deriving Repr

namespace AdmissionStaticValue

mutual

/-- Forget the serialized artifact wrapper into the existing elaboration IR value carrier. -/
def toStaticValue : AdmissionStaticValue → StaticValue
  | .string value => StaticValue.string value
  | .bool value => StaticValue.bool value
  | .nat value => StaticValue.nat value
  | .list values => StaticValue.list (toStaticValueList values)
  | .record fields => StaticValue.record (toStaticValueFields fields)

def toStaticValueList : List AdmissionStaticValue → List StaticValue
  | [] => []
  | value :: values => value.toStaticValue :: toStaticValueList values

def toStaticValueFields :
    List (FieldLabel × AdmissionStaticValue) → List (FieldLabel × StaticValue)
  | [] => []
  | (label, value) :: fields => (label, value.toStaticValue) :: toStaticValueFields fields

end

mutual

/-- Recursive validator obligation for serialized static values.

Record-shaped values keep source field order but must not repeat a field label,
because later `makeEach` witness construction projects fields by name. -/
def Valid : AdmissionStaticValue → Prop
  | .string _ => True
  | .bool _ => True
  | .nat _ => True
  | .list values => ValuesValid values
  | .record fields => (fields.map Prod.fst).Nodup ∧ FieldsValid fields

def ValuesValid : List AdmissionStaticValue → Prop
  | [] => True
  | value :: values => value.Valid ∧ ValuesValid values

def FieldsValid : List (FieldLabel × AdmissionStaticValue) → Prop
  | [] => True
  | (label, value) :: fields => label.Valid ∧ value.Valid ∧ FieldsValid fields

end

@[simp]
theorem toStaticValue_string (value : String) :
    (AdmissionStaticValue.string value).toStaticValue = StaticValue.string value :=
  rfl

@[simp]
theorem toStaticValue_bool (value : Bool) :
    (AdmissionStaticValue.bool value).toStaticValue = StaticValue.bool value :=
  rfl

@[simp]
theorem toStaticValue_nat (value : Nat) :
    (AdmissionStaticValue.nat value).toStaticValue = StaticValue.nat value :=
  rfl

@[simp]
theorem toStaticValue_list (values : List AdmissionStaticValue) :
    (AdmissionStaticValue.list values).toStaticValue =
      StaticValue.list (AdmissionStaticValue.toStaticValueList values) :=
  rfl

@[simp]
theorem toStaticValue_record (fields : List (FieldLabel × AdmissionStaticValue)) :
    (AdmissionStaticValue.record fields).toStaticValue =
      StaticValue.record (AdmissionStaticValue.toStaticValueFields fields) :=
  rfl

@[simp]
theorem toStaticValueList_eq_map (values : List AdmissionStaticValue) :
    AdmissionStaticValue.toStaticValueList values =
      values.map AdmissionStaticValue.toStaticValue := by
  induction values with
  | nil => rfl
  | cons value values ih =>
      simp [AdmissionStaticValue.toStaticValueList, ih]

@[simp]
theorem toStaticValueFields_eq_map (fields : List (FieldLabel × AdmissionStaticValue)) :
    AdmissionStaticValue.toStaticValueFields fields =
      fields.map fun field => (field.fst, field.snd.toStaticValue) := by
  induction fields with
  | nil => rfl
  | cons field fields ih =>
      cases field
      simp [AdmissionStaticValue.toStaticValueFields, ih]

/-- Forgetting serialized static values preserves record field labels. -/
theorem toStaticValueFields_labels
    (fields : List (FieldLabel × AdmissionStaticValue)) :
    (AdmissionStaticValue.toStaticValueFields fields).map Prod.fst =
      fields.map Prod.fst := by
  simp [AdmissionStaticValue.toStaticValueFields_eq_map, List.map_map]

/-- Valid serialized records expose duplicate-free field labels. -/
theorem valid_record_fieldsUnique
    {fields : List (FieldLabel × AdmissionStaticValue)}
    (hValid : (AdmissionStaticValue.record fields).Valid) :
    (fields.map Prod.fst).Nodup :=
  hValid.left

/-- Valid serialized records remain duplicate-free after conversion to `StaticValue` fields. -/
theorem valid_record_toStaticValueFields_labelsUnique
    {fields : List (FieldLabel × AdmissionStaticValue)}
    (hValid : (AdmissionStaticValue.record fields).Valid) :
    ((AdmissionStaticValue.toStaticValueFields fields).map Prod.fst).Nodup := by
  rw [AdmissionStaticValue.toStaticValueFields_labels]
  exact AdmissionStaticValue.valid_record_fieldsUnique hValid

end AdmissionStaticValue

end AdmissionArtifact
end Cortex.Wire
