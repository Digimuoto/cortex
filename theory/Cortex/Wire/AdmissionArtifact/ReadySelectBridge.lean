import Cortex.Wire.AdmissionArtifact.ReadyGeneral

/-!
## Overview

Validator-ready select bridge accessors backed by primitive replay.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes primitive backing for select condition bridge frontiers. -/
theorem validatorReady_selectBridgeFrontiersBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectBridgeFrontiersBackedByPrimitive :=
  hReady.selectBridgeFrontiersBackedByPrimitive

/-- Validator readiness exposes that select bridge entries are replay-consumed. -/
theorem validatorReady_selectBridgeEntriesConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectBridgeEntriesConsumed :=
  hReady.selectBridgeEntriesConsumed

/-- Validator-ready select rows expose their primitive condition-node frontier row. -/
theorem validatorReady_selectBridge_conditionNodePrimitiveRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps := by
  obtain ⟨entries, exits, hNode, _hVariants⟩ :=
    validatorReady_selectBridgeFrontiersBackedByPrimitive
      hReady selectAdmission hSelect
  exact ⟨entries, exits, hNode⟩

/-- Validator-ready select condition nodes are backed by primitive node identity rows. -/
theorem validatorReady_select_conditionNode_mem_primitiveRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.conditionNode ∈
      PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps := by
  obtain ⟨_entries, _exits, hNode⟩ :=
    validatorReady_selectBridge_conditionNodePrimitiveRow hReady hSelect
  exact PrimitiveGraphStep.nodeRowsList_mem_of_node_mem hNode

/-- Validator-ready select variants have unique primitive bridge entry and choice-exit rows. -/
theorem validatorReady_selectBridge_variantFrontiersBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        SelectBridgeEntryUnique variant entries ∧
          SelectBridgeInternalExitUnique selectAdmission.conditionNode variant exits := by
  obtain ⟨entries, exits, hNode, hVariants⟩ :=
    validatorReady_selectBridgeFrontiersBackedByPrimitive
      hReady selectAdmission hSelect
  exact ⟨entries, exits, hNode, hVariants variant hVariant⟩

/-- Validator-ready select variants have a consumed condition-node bridge entry. -/
theorem validatorReady_select_variant_bridgeEntryConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    ∃ entries exits entry,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        entry ∈ entries ∧
          variant.port.CompatibleWith entry ∧
            { fromPort := variant.port, toPort := entry } ∈
              PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
              entry.key ∈
                PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps := by
  obtain ⟨entries, exits, hNode, hEntryUnique, _hExitUnique⟩ :=
    validatorReady_selectBridge_variantFrontiersBackedByPrimitive
      hReady hSelect hVariant
  obtain ⟨entry, hEntry, hCompatible⟩ :=
    selectBridgeEntryUnique_entry hEntryUnique
  have hMatched :=
    validatorReady_selectBridgeEntriesConsumed
      hReady selectAdmission hSelect entries exits hNode
        variant hVariant entry hEntry hCompatible
  have hConsumed :
      entry.key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps := by
    simpa [AdmissionConnection.toKey] using
      PrimitiveGraphStep.matchedConnectionsList_toKey_mem_consumedEntryKeysList
        hMatched
  exact
    ⟨ entries
    , exits
    , entry
    , hNode
    , hEntry
    , hCompatible
    , hMatched
    , hConsumed
    ⟩

/-- Validator readiness exposes select arm body boundary compatibility. -/
theorem validatorReady_selectArmBodyBoundariesMatchCondition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectArmBodyBoundariesMatchCondition :=
  hReady.selectArmBodyBoundariesMatchCondition

/-- Validator-ready select arms consume their selected variant and produce the bridge shape. -/
theorem validatorReady_select_armBodyBoundariesMatchCondition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        ∃ variant, variant ∈ selectAdmission.variants ∧
          variant.key = arm.canonicalKey ∧
          (((arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
              SelectConditionBridgeOutputShapes selectAdmission exits =
                [variant.port.identityOutputShape]) ∨
            (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
                [variant.port.compatibilityShape] ∧
              (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
                (SelectConditionBridgeOutputShapes selectAdmission exits))) := by
  obtain ⟨entries, exits, hNode, hArms⟩ :=
    validatorReady_selectArmBodyBoundariesMatchCondition hReady selectAdmission hSelect
  exact ⟨entries, exits, hNode, hArms arm hArm⟩

/-- Validator-ready identity select arms expose the condition bridge identity shape. -/
theorem validatorReady_select_identityArm_bridgeShape
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    (hIdentity : arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) :
    ∃ entries exits variant,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        variant ∈ selectAdmission.variants ∧
          variant.key = arm.canonicalKey ∧
            SelectConditionBridgeOutputShapes selectAdmission exits =
              [variant.port.identityOutputShape] := by
  obtain ⟨entries, exits, hNode, variant, hVariant, hKey, hShape⟩ :=
    validatorReady_select_armBodyBoundariesMatchCondition hReady hSelect hArm
  rcases hShape with hIdentityShape | hBodyShape
  · exact
      ⟨ entries
      , exits
      , variant
      , hNode
      , hVariant
      , hKey
      , hIdentityShape.right
      ⟩
  · have hImpossible :
        ([] : List (AdmissionPortLabel × ContractId)) =
          [variant.port.compatibilityShape] := by
      simpa [hIdentity.right.left] using hBodyShape.left
    cases hImpossible

/-- Validator-ready non-identity select arms expose body-entry and bridge-output shapes. -/
theorem validatorReady_select_nonIdentityArm_bodyShapes
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    (hNotIdentity :
      ¬ (arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = [])) :
    ∃ entries exits variant,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        variant ∈ selectAdmission.variants ∧
          variant.key = arm.canonicalKey ∧
            arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
              [variant.port.compatibilityShape] ∧
              (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
                (SelectConditionBridgeOutputShapes selectAdmission exits) := by
  obtain ⟨entries, exits, hNode, variant, hVariant, hKey, hShape⟩ :=
    validatorReady_select_armBodyBoundariesMatchCondition hReady hSelect hArm
  rcases hShape with hIdentityShape | hBodyShape
  · exact False.elim (hNotIdentity hIdentityShape.left)
  · exact
      ⟨ entries
      , exits
      , variant
      , hNode
      , hVariant
      , hKey
      , hBodyShape.left
      , hBodyShape.right
      ⟩

/-- Validator readiness exposes disjoint latent select-arm body node domains. -/
theorem validatorReady_selectArmBodyNodesPairwiseDisjoint
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectArmBodyNodesPairwiseDisjoint :=
  hReady.selectArmBodyNodesPairwiseDisjoint

/-- Validator readiness exposes freshness of latent select-arm bodies. -/
theorem validatorReady_selectArmBodyNodesFreshFromSummary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectArmBodyNodesFreshFromSummary :=
  hReady.selectArmBodyNodesFreshFromSummary

/-- Validator-ready select arm body nodes are absent from the top-level node summary. -/
theorem validatorReady_select_armBodyNodeFresh
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {node : NodeId}
    (hNode : node ∈ arm.bodyNodes) :
    node ∉ artifact.nodes :=
  validatorReady_selectArmBodyNodesFreshFromSummary
    hReady selectAdmission hSelect arm hArm node hNode

/-- Validator-ready select arms with different canonical keys cannot share body nodes. -/
theorem validatorReady_select_armBodyNodesDisjoint
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {left right : SelectArmAdmissionArtifact}
    (hLeft : left ∈ selectAdmission.arms)
    (hRight : right ∈ selectAdmission.arms)
    (hKeys : left.canonicalKey ≠ right.canonicalKey)
    {node : NodeId}
    (hNode : node ∈ left.bodyNodes) :
    node ∉ right.bodyNodes :=
  validatorReady_selectArmBodyNodesPairwiseDisjoint
    hReady selectAdmission hSelect left hLeft right hRight hKeys node hNode

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
