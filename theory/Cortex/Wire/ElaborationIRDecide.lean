import Cortex.Wire.ElaborationIR

/-!
## Overview

Decidable instances for the elaboration-IR validity wrappers, so accepted
declarations and module shells can be constructed in generated fixtures with
`by decide` proof fields. The leaf validity predicates already carry
instances in `ElaborationIR`; this module covers the def-level
quantifications over lists and finsets and the output-shape admissibility
inductive, each by `inferInstanceAs` against the unfolded form or an explicit
decision through `decidable_of_iff`.
-/

namespace Cortex.Wire
namespace ElaborationIR

/-- Finset-quantified port validity is decidable pointwise. -/
instance (ports : Finset PortSignature) : Decidable (PortSignaturesValid ports) :=
  inferInstanceAs (Decidable (∀ port ∈ ports, port.Valid))

/-- List-quantified port validity is decidable pointwise. -/
instance (ports : List PortSignature) : Decidable (PortSignatureListValid ports) :=
  inferInstanceAs (Decidable (∀ port ∈ ports, port.Valid))

/-- Source-order label uniqueness is decidable as list `Nodup`. -/
instance (ports : List PortSignature) : Decidable (PortLabelListUnique ports) :=
  inferInstanceAs (Decidable (ports.map PortSignature.label).Nodup)

/-- Finset label injectivity is decidable as a bounded double quantification. -/
instance (ports : Finset PortSignature) : Decidable (PortLabelsUnique ports) :=
  decidable_of_iff
    (∀ left ∈ ports, ∀ right ∈ ports, left.label = right.label → left = right)
    ⟨ fun h left right hLeft hRight hEq => h left hLeft right hRight hEq
    , fun h left hLeft right hRight hEq => h hLeft hRight hEq
    ⟩

/-- Record-field local validity is decidable componentwise. -/
instance (field : RecordFieldDecl) : Decidable field.Valid :=
  inferInstanceAs (Decidable (field.field.Valid ∧ field.contract.Valid))

/-- Record-field validity over a list is decidable pointwise. -/
instance (fields : List RecordFieldDecl) : Decidable (RecordFieldListValid fields) :=
  inferInstanceAs (Decidable (∀ field ∈ fields, field.Valid))

/-- Record-field label uniqueness is decidable as list `Nodup`. -/
instance (fields : List RecordFieldDecl) : Decidable (RecordFieldLabelsUnique fields) :=
  inferInstanceAs (Decidable (fields.map RecordFieldDecl.field).Nodup)

namespace OutputShape

/-- Local admissibility decides by cases on the authored shape. -/
instance (shape : OutputShape) : Decidable shape.LocallyAdmissible :=
  match shape with
  | .single port =>
      decidable_of_iff port.Valid
        ⟨LocallyAdmissible.single, fun h => by cases h with | single hValid => exact hValid⟩
  | .sumGroup arms =>
      decidable_of_iff
        (2 ≤ arms.length ∧
          (∀ arm ∈ arms, arm.Valid) ∧
            (arms.map OutputArmDecl.armKey).Nodup ∧
              (arms.map fun arm => arm.port.label).Nodup)
        ⟨ fun h => LocallyAdmissible.sumGroup h.1 h.2.1 h.2.2.1 h.2.2.2
        , fun h => by
            cases h with
            | sumGroup hLength hValid hKeys hLabels => exact ⟨hLength, hValid, hKeys, hLabels⟩
        ⟩

end OutputShape

/-- Shape-list admissibility is decidable pointwise. -/
instance (shapes : List OutputShape) : Decidable (OutputShapeListAdmissible shapes) :=
  inferInstanceAs (Decidable (∀ shape ∈ shapes, shape.LocallyAdmissible))

end ElaborationIR
end Cortex.Wire
