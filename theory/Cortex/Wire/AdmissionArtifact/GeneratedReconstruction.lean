import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction

/-!
## Overview

Generated-form reconstruction from validator-sound admission artifacts.

The generated artifact rows record source `make`/`makeEach` children, surviving
lowered children, and primitive frontier rows for those surviving children. They
do not carry the accepted kind declaration or the executable kind-substitution
result, so this module does not claim to reconstruct
`KindInstantiatedFrontiers` or `MakeWitness` directly.

Instead, `GeneratedReconstruction` is the artifact-boundary witness:

- source `MakeItem` rows pass the Lean `makeEach` item checker;
- every surviving generated child has a unique source row and projected
  `MakeItem`;
- every surviving child frontier exactly matches a primitive node row;
- every surviving child frontier key is accounted for by primitive replay; and
- `make` rows expose canonical count labels and value-free items, while all
  source rows preserve decoded static payloads through `toStaticValue`.

The later accepted-kind reconstruction step must add the accepted kind and
substitution evidence needed to build `KindInstantiatedFrontiers`.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-! ## Generated Reconstruction Contract -/

/-- Evidence for one surviving generated child row.

The data arguments are parameters so the public reconstruction predicate can
remain `Prop` while still naming the source row, projected `MakeItem`, and
primitive frontier row that witness the child. -/
structure GeneratedUsedChildReconstructionEvidence
    (artifact : WireAdmissionArtifact)
    (generated : GeneratedFormArtifact)
    (child : GeneratedChildArtifact)
    (item : LinearPortGraph.MakeItem)
    (source : GeneratedChildSourceArtifact)
    (entries exits : List AdmissionBoundaryPort) : Prop where
  itemMem : item ∈ generated.sourceMakeItems
  itemLabel : item.label = child.label
  itemUnique :
    ∀ other, other ∈ generated.sourceMakeItems →
      other.label = child.label → other = item
  sourceMem : source ∈ generated.sourceChildren
  sourceNode : source.node = child.node
  sourceLabel : source.label = child.label
  /-- The source row backing the child is unique among `sourceChildren`.

  Derived from `GeneratedFormArtifact.Valid.childKeysUnique`'s
  `sourceChildKeys.Nodup` plus the `(node, label)` matching above. Exposed at
  the reconstruction boundary so downstream proofs don't have to re-derive it
  from the underlying validity contract. -/
  sourceUnique :
    ∀ other, other ∈ generated.sourceChildren →
      other.node = child.node → other.label = child.label → other = source
  itemFromSource : item = source.toMakeItem
  primitiveNode :
    PrimitiveGraphStep.node child.node entries exits ∈ artifact.primitiveSteps
  inputKeysMatchPrimitive :
    child.inputKeys.Perm (entries.map AdmissionBoundaryPort.key)
  outputKeysMatchPrimitive :
    child.outputKeys.Perm (exits.map AdmissionBoundaryPort.key)
  inputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ child.inputKeys → PrimitiveInputKeyAccounted artifact key
  outputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ child.outputKeys → PrimitiveOutputKeyAccounted artifact key

/-- Artifact-boundary reconstruction evidence for one surviving generated child. -/
def GeneratedUsedChildReconstruction
    (artifact : WireAdmissionArtifact)
    (generated : GeneratedFormArtifact)
    (child : GeneratedChildArtifact) : Prop :=
  ∃ item source entries exits,
    GeneratedUsedChildReconstructionEvidence
      artifact generated child item source entries exits

/-- Artifact-boundary reconstruction evidence for one generated-form row. -/
structure GeneratedFormReconstruction
    (artifact : WireAdmissionArtifact)
    (generated : GeneratedFormArtifact) : Prop where
  sourceItemsAccepted :
    LinearPortGraph.MakeEach.acceptItems generated.binding
      generated.sourceMakeItems =
        Except.ok generated.sourceMakeItems
  usedChildren :
    ∀ child, child ∈ generated.usedChildren →
      GeneratedUsedChildReconstruction artifact generated child
  sourceValuesProjected :
    generated.sourceMakeItems.map LinearPortGraph.MakeItem.value =
      generated.sourceChildren.map
        (fun child => child.value.map AdmissionStaticValue.toStaticValue)
  makePayload :
    generated.kind = GeneratedFormKind.make →
      generated.sourceMakeItems.map LinearPortGraph.MakeItem.label =
          (List.range generated.sourceChildren.length).map (fun index =>
            ⟨toString index⟩) ∧
        ∀ {item : LinearPortGraph.MakeItem},
          item ∈ generated.sourceMakeItems → item.value = none

/-- Artifact-boundary generated-form reconstruction for every generated row. -/
def GeneratedReconstruction (artifact : WireAdmissionArtifact) : Prop :=
  ∀ generated, generated ∈ artifact.generatedForms →
    GeneratedFormReconstruction artifact generated

/-- Generated and primitive soundness reconstruct one surviving generated child row. -/
theorem Sound.generatedUsedChildReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    GeneratedUsedChildReconstruction artifact generated child := by
  obtain ⟨item, hItemMem, hItemLabel, hSource⟩ :=
    hSound.generated.usedChildSourceMakeItem hGenerated hChild
  obtain
    ⟨uniqueItem, hUniqueItemMem, hUniqueItemLabel, hUniqueItem⟩ :=
      hSound.generated.usedChildUniqueSourceMakeItem hGenerated hChild
  have hItemEqUnique : item = uniqueItem :=
    hUniqueItem item hItemMem hItemLabel
  have hItemUnique :
      ∀ other, other ∈ generated.sourceMakeItems →
        other.label = child.label → other = item := by
    intro other hOtherMem hOtherLabel
    exact (hUniqueItem other hOtherMem hOtherLabel).trans hItemEqUnique.symm
  obtain
    ⟨source, hSourceMem, hSourceNode, hSourceLabel, hItemFromSource⟩ :=
      hSource
  obtain ⟨entries, exits, hPrimitiveNode, hInputKeys, hOutputKeys⟩ :=
    hSound.generated.generatedChildFrontiersMatchPrimitive
      generated hGenerated child hChild
  have hFrontierAccounted :
      artifact.PrimitiveFrontierKeysAccounted :=
    primitiveFrontierKeysAccounted
      hSound.primitive.summaryFrontiersMatchPrimitive
  refine
    ⟨ item
    , source
    , entries
    , exits
    , ?_
    ⟩
  have hSourceChildKeysUnique :
      generated.sourceChildKeys.Nodup :=
    (hSound.generated.generatedFormsValid generated hGenerated).childKeysUnique.left
  have hSourceUnique :
      ∀ other, other ∈ generated.sourceChildren →
        other.node = child.node → other.label = child.label → other = source := by
    intro other hOther hOtherNode hOtherLabel
    have hKeyEq : other.key = source.key := by
      unfold GeneratedChildSourceArtifact.key
      rw [hOtherNode, hOtherLabel, ← hSourceNode, ← hSourceLabel]
    exact List.inj_on_of_nodup_map hSourceChildKeysUnique hOther hSourceMem hKeyEq
  exact
    { itemMem := hItemMem
      itemLabel := hItemLabel
      itemUnique := hItemUnique
      sourceMem := hSourceMem
      sourceNode := hSourceNode
      sourceLabel := hSourceLabel
      sourceUnique := hSourceUnique
      itemFromSource := hItemFromSource
      primitiveNode := hPrimitiveNode
      inputKeysMatchPrimitive := hInputKeys
      outputKeysMatchPrimitive := hOutputKeys
      inputKeysAccounted := by
        intro key hKey
        have hPrimitiveKey :
            key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps :=
          PrimitiveGraphStep.nodeEntryKeysList_mem_of_node_mem
            hPrimitiveNode
            (hInputKeys.mem_iff.mp hKey)
        exact hFrontierAccounted.inputs hPrimitiveKey
      outputKeysAccounted := by
        intro key hKey
        have hPrimitiveKey :
            key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps :=
          PrimitiveGraphStep.nodeExitKeysList_mem_of_node_mem
            hPrimitiveNode
            (hOutputKeys.mem_iff.mp hKey)
        exact hFrontierAccounted.outputs hPrimitiveKey }

/-- Validator soundness reconstructs generated-form artifact-boundary witnesses. -/
theorem Sound.toGeneratedReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound) :
    artifact.GeneratedReconstruction := by
  intro generated hGenerated
  exact
    { sourceItemsAccepted :=
        hSound.generated.sourceMakeItemsAcceptItems hGenerated
      usedChildren := by
        intro child hChild
        exact hSound.generatedUsedChildReconstruction hGenerated hChild
      sourceValuesProjected :=
        GeneratedFormArtifact.sourceMakeItems_values generated
      makePayload := by
        intro hKind
        exact
          ⟨ hSound.generated.makeSourceLabelsCanonical hGenerated hKind
          , fun hItem =>
              hSound.generated.makeSourceValuesEmpty hGenerated hKind hItem
          ⟩ }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
