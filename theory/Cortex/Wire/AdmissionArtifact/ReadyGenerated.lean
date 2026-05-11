import Cortex.Wire.AdmissionArtifact.ReadyPrimitive

/-!
## Overview

Validator-ready generated-form accessors.

This page exposes source-child, used-child, `make`, `makeEach`, and static-record consequences for
generated form rows in a validator-ready artifact.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator-ready generated rows expose exact used-child backing. -/
theorem validatorReady_generated_usedChild_backed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.key ∈ generated.sourceChildKeys :=
  (validatorReady_generatedForm_valid hReady hGenerated).usedChildrenFromSource child hChild

/-- Validator-ready generated rows recover the source row for every surviving child. -/
theorem validatorReady_generated_usedChild_sourceChild
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ source, source ∈ generated.sourceChildren ∧
      source.node = child.node ∧ source.label = child.label := by
  have hBacked :=
    validatorReady_generated_usedChild_backed hReady hGenerated hChild
  rcases List.mem_map.mp hBacked with ⟨source, hSource, hKey⟩
  have hNode : source.node = child.node := Prod.mk.inj hKey |>.left
  have hLabel : source.label = child.label := Prod.mk.inj hKey |>.right
  exact ⟨source, hSource, hNode, hLabel⟩

/-- Validator-ready generated rows recover a unique source row for every surviving child.

This is the source-row provenance handoff needed by future executable
`makeEach` correspondence: once the used generated child is known, the
serialized source row, including any static payload, is unique. -/
theorem validatorReady_generated_usedChild_uniqueSourceChild
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ source, source ∈ generated.sourceChildren ∧
      source.node = child.node ∧
        source.label = child.label ∧
          ∀ other, other ∈ generated.sourceChildren →
            other.node = child.node →
              other.label = child.label →
                other = source := by
  obtain ⟨source, hSource, hNode, hLabel⟩ :=
    validatorReady_generated_usedChild_sourceChild hReady hGenerated hChild
  have hSourceKeysUnique :=
    (validatorReady_generatedForm_valid hReady hGenerated).childKeysUnique.left
  have hUnique :
      ∀ other, other ∈ generated.sourceChildren →
        other.node = child.node →
          other.label = child.label →
            other = source := by
    intro other hOther hOtherNode hOtherLabel
    have hKeyEq : other.key = source.key := by
      unfold GeneratedChildSourceArtifact.key
      exact Prod.ext (hOtherNode.trans hNode.symm) (hOtherLabel.trans hLabel.symm)
    exact
      List.inj_on_of_nodup_map hSourceKeysUnique hOther hSource hKeyEq
  exact ⟨source, hSource, hNode, hLabel, hUnique⟩

/-- Validator-ready generated children recover their projected source `MakeItem`.

This connects the lowered child row that survived graph pruning back to the
exact source item list consumed by the Lean `makeEach` checker, including any
static payload carried by the decoded source row. -/
theorem validatorReady_generated_usedChild_sourceMakeItem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ item, item ∈ generated.sourceMakeItems ∧
      item.label = child.label ∧
        ∃ source, source ∈ generated.sourceChildren ∧
          source.node = child.node ∧
            source.label = child.label ∧
              item = source.toMakeItem := by
  obtain ⟨source, hSource, hNode, hLabel⟩ :=
    validatorReady_generated_usedChild_sourceChild hReady hGenerated hChild
  refine
    ⟨ source.toMakeItem
    , ?_
    , ?_
    , ⟨source, hSource, hNode, hLabel, rfl⟩
    ⟩
  · unfold GeneratedFormArtifact.sourceMakeItems
    exact List.mem_map.mpr ⟨source, hSource, rfl⟩
  · simp [GeneratedChildSourceArtifact.toMakeItem, hLabel]

/-- Validator-ready `make` children recover source items with no static payload. -/
theorem validatorReady_generated_make_usedChild_sourceMakeItem_value_empty
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hKind : generated.kind = GeneratedFormKind.make)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ item, item ∈ generated.sourceMakeItems ∧
      item.label = child.label ∧ item.value = none := by
  obtain ⟨source, hSource, _hNode, hLabel⟩ :=
    validatorReady_generated_usedChild_sourceChild hReady hGenerated hChild
  have hShape :=
    (validatorReady_generatedForm_valid hReady hGenerated).kindShapeMatches
  unfold GeneratedFormArtifact.KindShapeMatches at hShape
  rw [hKind] at hShape
  have hValueEmpty := hShape.right source hSource
  refine
    ⟨ source.toMakeItem
    , ?_
    , ?_
    , ?_
    ⟩
  · unfold GeneratedFormArtifact.sourceMakeItems
    exact List.mem_map.mpr ⟨source, hSource, rfl⟩
  · simp [GeneratedChildSourceArtifact.toMakeItem, hLabel]
  · simp [GeneratedChildSourceArtifact.toMakeItem, hValueEmpty]

/-- Validator-ready generated rows expose source-label backing for used children. -/
theorem validatorReady_generated_usedChild_label_mem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.label ∈ generated.sourceLabels :=
  GeneratedFormArtifact.usedChildrenFromSource_label_mem
    (validatorReady_generatedForm_valid hReady hGenerated).usedChildrenFromSource
    hChild

/-- Validator-ready generated rows expose source/used child-key uniqueness. -/
theorem validatorReady_generated_childKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.ChildKeysUnique :=
  (validatorReady_generatedForm_valid hReady hGenerated).childKeysUnique

/-- Validator-ready generated rows expose binding/label ownership for child node identities. -/
theorem validatorReady_generated_childrenOwnedByBinding
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.ChildrenOwnedByBinding :=
  (validatorReady_generatedForm_valid hReady hGenerated).childrenOwnedByBinding

/-- Validator-ready generated rows expose structural validity of source static payloads. -/
theorem validatorReady_generated_sourceValuesValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.SourceValuesValid :=
  (validatorReady_generatedForm_valid hReady hGenerated).sourceValuesValid

/-- Validator-ready generated source rows project to valid Lean `makeEach` items. -/
theorem validatorReady_generated_sourceMakeItems_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    LinearPortGraph.MakeItem.ItemsValid generated.sourceMakeItems := by
  have hRows : generated.RowsValid :=
    (validatorReady_generatedForm_valid hReady hGenerated).rowsValid
  exact
    GeneratedFormArtifact.sourceMakeItems_valid fun child hChild =>
      (hRows.sourceChildrenValid child hChild).labelValid

/-- Validator-ready generated source rows project to duplicate-free Lean `makeEach` item labels. -/
theorem validatorReady_generated_sourceMakeItems_labelsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    LinearPortGraph.MakeItem.LabelsUnique generated.sourceMakeItems :=
  GeneratedFormArtifact.sourceMakeItems_labelsUnique
    (validatorReady_generated_childrenOwnedByBinding hReady hGenerated)
    (validatorReady_generated_childKeysUnique hReady hGenerated)

/-- Validator-ready used children recover a unique projected source `MakeItem`. -/
theorem validatorReady_generated_usedChild_uniqueSourceMakeItem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ item, item ∈ generated.sourceMakeItems ∧
      item.label = child.label ∧
        ∀ other, other ∈ generated.sourceMakeItems →
          other.label = child.label → other = item := by
  obtain ⟨item, hItem, hItemLabel, _source⟩ :=
    validatorReady_generated_usedChild_sourceMakeItem hReady hGenerated hChild
  have hLabelsUnique :=
    validatorReady_generated_sourceMakeItems_labelsUnique hReady hGenerated
  have hUnique :
      ∀ other, other ∈ generated.sourceMakeItems →
        other.label = child.label → other = item := by
    intro other hOther hOtherLabel
    exact
      List.inj_on_of_nodup_map
        hLabelsUnique
        hOther
        hItem
        (hOtherLabel.trans hItemLabel.symm)
  exact ⟨item, hItem, hItemLabel, hUnique⟩

/-- Validator-ready generated source rows pass the generated-form `makeEach` item checker. -/
theorem validatorReady_generated_sourceMakeItems_acceptItems_ok
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    LinearPortGraph.MakeEach.acceptItems generated.binding generated.sourceMakeItems =
      Except.ok generated.sourceMakeItems :=
  LinearPortGraph.MakeEach.acceptItems_ok_eq_self
    generated.binding
    generated.sourceMakeItems
    (validatorReady_generated_sourceMakeItems_valid hReady hGenerated)
    (validatorReady_generated_sourceMakeItems_labelsUnique hReady hGenerated)

/-- Validator-ready generated rows expose generated-form kind payload-shape matching. -/
theorem validatorReady_generated_kindShapeMatches
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.KindShapeMatches :=
  (validatorReady_generatedForm_valid hReady hGenerated).kindShapeMatches

/-- Validator-ready `make` rows expose count-derived source labels. -/
theorem validatorReady_generated_makeSourceLabelsCanonical
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hKind : generated.kind = GeneratedFormKind.make) :
    generated.MakeSourceLabelsCanonical := by
  have hShape := validatorReady_generated_kindShapeMatches hReady hGenerated
  unfold GeneratedFormArtifact.KindShapeMatches at hShape
  rw [hKind] at hShape
  exact hShape.left

/-- Validator-ready `make` rows carry no per-child static value payload. -/
theorem validatorReady_generated_makeSourceValuesEmpty
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hKind : generated.kind = GeneratedFormKind.make) :
    generated.MakeSourceValuesEmpty := by
  have hShape := validatorReady_generated_kindShapeMatches hReady hGenerated
  unfold GeneratedFormArtifact.KindShapeMatches at hShape
  rw [hKind] at hShape
  exact hShape.right

/-- Validator-ready `make` source rows project to the canonical generated label sequence. -/
theorem validatorReady_generated_make_sourceMakeItems_labelsCanonical
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hKind : generated.kind = GeneratedFormKind.make) :
    generated.sourceMakeItems.map LinearPortGraph.MakeItem.label =
      (List.range generated.sourceChildren.length).map (fun index => ⟨toString index⟩) := by
  rw [GeneratedFormArtifact.sourceMakeItems_labels]
  exact validatorReady_generated_makeSourceLabelsCanonical hReady hGenerated hKind

/-- Validator-ready `make` source rows project to value-free generated items. -/
theorem validatorReady_generated_make_sourceMakeItems_valuesEmpty
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hKind : generated.kind = GeneratedFormKind.make)
    {item : LinearPortGraph.MakeItem}
    (hItem : item ∈ generated.sourceMakeItems) :
    item.value = none := by
  unfold GeneratedFormArtifact.sourceMakeItems at hItem
  rcases List.mem_map.mp hItem with ⟨child, hChild, hItemEq⟩
  rw [← hItemEq]
  simp [GeneratedChildSourceArtifact.toMakeItem,
    validatorReady_generated_makeSourceValuesEmpty hReady hGenerated hKind child hChild]

/-- Validator-ready generated rows expose structural row validity. -/
theorem validatorReady_generated_rowsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.RowsValid :=
  (validatorReady_generatedForm_valid hReady hGenerated).rowsValid

/-- Validator-ready generated rows expose valid kind identifiers. -/
theorem validatorReady_generated_kindNameValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.kindName.Valid :=
  (validatorReady_generated_rowsValid hReady hGenerated).kindNameValid

/-- Validator-ready generated rows expose valid binding identifiers. -/
theorem validatorReady_generated_bindingValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.binding.Valid :=
  (validatorReady_generated_rowsValid hReady hGenerated).bindingValid

/-- Validator-ready generated source rows expose row validity directly. -/
theorem validatorReady_generated_sourceChild_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren) :
    source.Valid :=
  (validatorReady_generated_rowsValid hReady hGenerated).sourceChildrenValid source hSource

/-- Validator-ready generated source rows expose valid node identifiers. -/
theorem validatorReady_generated_sourceChild_nodeValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren) :
    source.node.Valid :=
  (validatorReady_generated_sourceChild_valid hReady hGenerated hSource).nodeValid

/-- Validator-ready generated source rows expose valid child labels. -/
theorem validatorReady_generated_sourceChild_labelValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren) :
    source.label.Valid :=
  (validatorReady_generated_sourceChild_valid hReady hGenerated hSource).labelValid

/-- Validator-ready generated source rows expose optional static payload validity. -/
theorem validatorReady_generated_sourceChild_staticValueValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren) :
    source.StaticValueValid :=
  (validatorReady_generated_sourceChild_valid hReady hGenerated hSource).staticValueValid

/-- Validator-ready generated static record payloads have duplicate-free field labels. -/
theorem validatorReady_generated_sourceChild_staticRecordFieldsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren)
    {fields : List (FieldLabel × AdmissionStaticValue)}
    (hValue : source.value = some (AdmissionStaticValue.record fields)) :
    (fields.map Prod.fst).Nodup := by
  have hStaticValueValid :
      source.StaticValueValid :=
    validatorReady_generated_sourceChild_staticValueValid hReady hGenerated hSource
  unfold GeneratedChildSourceArtifact.StaticValueValid at hStaticValueValid
  rw [hValue] at hStaticValueValid
  exact AdmissionStaticValue.valid_record_fieldsUnique hStaticValueValid

/-- Validator-ready generated static record payloads remain duplicate-free after conversion. -/
theorem validatorReady_generated_sourceChild_staticRecordFieldsUnique_toStaticValue
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren)
    {fields : List (FieldLabel × AdmissionStaticValue)}
    (hValue : source.value = some (AdmissionStaticValue.record fields)) :
    ((AdmissionStaticValue.toStaticValueFields fields).map Prod.fst).Nodup := by
  have hStaticValueValid :
      source.StaticValueValid :=
    validatorReady_generated_sourceChild_staticValueValid hReady hGenerated hSource
  unfold GeneratedChildSourceArtifact.StaticValueValid at hStaticValueValid
  rw [hValue] at hStaticValueValid
  exact AdmissionStaticValue.valid_record_toStaticValueFields_labelsUnique hStaticValueValid

/-- Validator-ready generated used rows expose row validity directly. -/
theorem validatorReady_generated_usedChild_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.Valid :=
  (validatorReady_generated_rowsValid hReady hGenerated).usedChildrenValid child hChild

/-- Validator-ready generated used rows expose valid node identifiers. -/
theorem validatorReady_generated_usedChild_nodeValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node.Valid :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).nodeValid

/-- Validator-ready generated used rows expose valid child labels. -/
theorem validatorReady_generated_usedChild_labelValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.label.Valid :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).labelValid

/-- Validator-ready generated source rows follow the binding/label node-name policy. -/
theorem validatorReady_generated_sourceChild_ownedByBinding
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {source : GeneratedChildSourceArtifact}
    (hSource : source ∈ generated.sourceChildren) :
    source.node = GeneratedFormArtifact.childNodeFor generated.binding source.label :=
  (validatorReady_generated_childrenOwnedByBinding hReady hGenerated).left source hSource

/-- Validator-ready generated used rows follow the binding/label node-name policy. -/
theorem validatorReady_generated_usedChild_ownedByBinding
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node = GeneratedFormArtifact.childNodeFor generated.binding child.label :=
  (validatorReady_generated_childrenOwnedByBinding hReady hGenerated).right child hChild

/-- Validator-ready generated used rows own every serialized frontier endpoint. -/
theorem validatorReady_generated_usedChild_frontiersOwnedByChild
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.FrontiersOwnedByChild :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).frontiersOwnedByChild

/-- Validator-ready generated used rows expose ownership of each output frontier endpoint. -/
theorem validatorReady_generated_usedChild_outputOwnedByChild
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {output : AdmissionBoundaryPort}
    (hOutput : output ∈ child.outputs) :
    output.node = child.node :=
  (validatorReady_generated_usedChild_frontiersOwnedByChild
    hReady hGenerated hChild).left output hOutput

/-- Validator-ready generated used rows expose ownership of each input frontier endpoint. -/
theorem validatorReady_generated_usedChild_inputOwnedByChild
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {input : AdmissionBoundaryPort}
    (hInput : input ∈ child.inputs) :
    input.node = child.node :=
  (validatorReady_generated_usedChild_frontiersOwnedByChild
    hReady hGenerated hChild).right input hInput

/-- Validator-ready generated used rows have duplicate-free output frontier keys. -/
theorem validatorReady_generated_usedChild_outputKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.outputKeys.Nodup :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).frontierKeysUnique.left

/-- Validator-ready generated used rows have duplicate-free input frontier keys. -/
theorem validatorReady_generated_usedChild_inputKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.inputKeys.Nodup :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).frontierKeysUnique.right

/-- Validator-ready generated used rows expose valid output frontier rows. -/
theorem validatorReady_generated_usedChild_outputsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    BoundaryPortsValid child.outputs :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).outputsValid

/-- Validator-ready generated used rows expose valid input frontier rows. -/
theorem validatorReady_generated_usedChild_inputsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    BoundaryPortsValid child.inputs :=
  (validatorReady_generated_usedChild_valid hReady hGenerated hChild).inputsValid

/-- Validator-ready generated used rows expose validity of each output frontier endpoint. -/
theorem validatorReady_generated_usedChild_outputValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {output : AdmissionBoundaryPort}
    (hOutput : output ∈ child.outputs) :
    output.Valid :=
  validatorReady_generated_usedChild_outputsValid
    hReady hGenerated hChild output hOutput

/-- Validator-ready generated used rows expose validity of each input frontier endpoint. -/
theorem validatorReady_generated_usedChild_inputValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {input : AdmissionBoundaryPort}
    (hInput : input ∈ child.inputs) :
    input.Valid :=
  validatorReady_generated_usedChild_inputsValid
    hReady hGenerated hChild input hInput

/-- Validator-ready generated used rows close output frontier endpoints over the node summary. -/
theorem validatorReady_generated_usedChild_outputsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    BoundaryPortsClosed artifact.nodes child.outputs :=
  (validatorReady_generatedForm_domainClosed hReady hGenerated child hChild).outputsClosed

/-- Validator-ready generated used rows close input frontier endpoints over the node summary. -/
theorem validatorReady_generated_usedChild_inputsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    BoundaryPortsClosed artifact.nodes child.inputs :=
  (validatorReady_generatedForm_domainClosed hReady hGenerated child hChild).inputsClosed

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
