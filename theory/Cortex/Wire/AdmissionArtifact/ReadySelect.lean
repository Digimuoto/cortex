import Cortex.Wire.AdmissionArtifact.ReadyPhantom

/-!
## Overview

Validator-ready select admission accessors.

This page exposes component-domain, branch-shape, resolution, and latent body consequences for
select admission rows in a validator-ready artifact.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes select row validity. -/
theorem validatorReady_select_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.Valid :=
  hReady.selectsValid selectAdmission hSelect

/-- Validator readiness exposes select-artifact domain closure. -/
theorem validatorReady_select_domainClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    SelectAdmissionArtifact.DomainClosed artifact.nodes selectAdmission :=
  hReady.componentDomainsClosed.selectsClosed selectAdmission hSelect

/-- Validator-ready select condition nodes belong to the top-level node summary. -/
theorem validatorReady_select_conditionNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.conditionNode ∈ artifact.nodes :=
  (validatorReady_select_domainClosed hReady hSelect).conditionNodeClosed

/-- Validator-ready select condition nodes appear in the component-role ledger. -/
theorem validatorReady_select_conditionNode_mem_componentRoleNodes
    {artifact : WireAdmissionArtifact}
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.conditionNode ∈ artifact.componentRoleNodes := by
  simp [componentRoleNodes]
  exact Or.inr (Or.inr ⟨selectAdmission, hSelect, rfl⟩)

/-- Validator-ready select condition nodes appear in the select-condition role ledger. -/
theorem validatorReady_select_conditionNode_mem_selectConditionNodes
    {artifact : WireAdmissionArtifact}
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.conditionNode ∈
      artifact.selects.map SelectAdmissionArtifact.conditionNode :=
  List.mem_map.mpr ⟨selectAdmission, hSelect, rfl⟩

/-- Validator-ready generated child and phantom adapter component nodes cannot collide. -/
theorem validatorReady_generated_childNode_ne_phantomAdapter_node
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    child.node ≠ phantom.node := by
  have hDisjoint :=
    validatorReady_generatedChildNodes_disjoint_phantomAdapterNodes hReady
  have hGeneratedNode :=
    validatorReady_generated_childNode_mem_generatedUsedChildNodes hGenerated hChild
  have hPhantomNode :=
    validatorReady_phantomAdapter_node_mem_phantomAdapterNodes hPhantom
  intro hEq
  rw [← hEq] at hPhantomNode
  exact hDisjoint hGeneratedNode hPhantomNode

/-- Validator-ready generated child and select condition component nodes cannot collide. -/
theorem validatorReady_generated_childNode_ne_select_conditionNode
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    child.node ≠ selectAdmission.conditionNode := by
  have hDisjoint :=
    validatorReady_generatedChildNodes_disjoint_selectConditionNodes hReady
  have hGeneratedNode :=
    validatorReady_generated_childNode_mem_generatedUsedChildNodes hGenerated hChild
  have hSelectNode :=
    validatorReady_select_conditionNode_mem_selectConditionNodes hSelect
  intro hEq
  rw [← hEq] at hSelectNode
  exact hDisjoint hGeneratedNode hSelectNode

/-- Validator-ready phantom adapter and select condition component nodes cannot collide. -/
theorem validatorReady_phantomAdapter_node_ne_select_conditionNode
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    phantom.node ≠ selectAdmission.conditionNode := by
  have hDisjoint :=
    validatorReady_phantomAdapterNodes_disjoint_selectConditionNodes hReady
  have hPhantomNode :=
    validatorReady_phantomAdapter_node_mem_phantomAdapterNodes hPhantom
  have hSelectNode :=
    validatorReady_select_conditionNode_mem_selectConditionNodes hSelect
  intro hEq
  rw [← hEq] at hSelectNode
  exact hDisjoint hPhantomNode hSelectNode

/-- Validator-ready latent select body nodes cannot reuse generated child component nodes. -/
theorem validatorReady_select_armBodyNode_ne_generated_childNode
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {bodyNode : NodeId}
    (hBodyNode : bodyNode ∈ arm.bodyNodes)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    bodyNode ≠ child.node := by
  have hFresh :=
    validatorReady_select_armBodyNodeFresh hReady hSelect hArm hBodyNode
  have hClosed :=
    validatorReady_generated_childNodeClosed hReady hGenerated hChild
  intro hEq
  rw [hEq] at hFresh
  exact hFresh hClosed

/-- Validator-ready latent select body nodes cannot reuse phantom-adapter component nodes. -/
theorem validatorReady_select_armBodyNode_ne_phantomAdapter_node
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {bodyNode : NodeId}
    (hBodyNode : bodyNode ∈ arm.bodyNodes)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    bodyNode ≠ phantom.node := by
  have hFresh :=
    validatorReady_select_armBodyNodeFresh hReady hSelect hArm hBodyNode
  have hClosed :=
    validatorReady_phantomAdapter_nodeClosed hReady hPhantom
  intro hEq
  rw [hEq] at hFresh
  exact hFresh hClosed

/-- Validator-ready latent select body nodes cannot reuse select condition component nodes. -/
theorem validatorReady_select_armBodyNode_ne_select_conditionNode
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {bodyNode : NodeId}
    (hBodyNode : bodyNode ∈ arm.bodyNodes)
    {otherSelect : SelectAdmissionArtifact}
    (hOtherSelect : otherSelect ∈ artifact.selects) :
    bodyNode ≠ otherSelect.conditionNode := by
  have hFresh :=
    validatorReady_select_armBodyNodeFresh hReady hSelect hArm hBodyNode
  have hClosed :=
    validatorReady_select_conditionNodeClosed hReady hOtherSelect
  intro hEq
  rw [hEq] at hFresh
  exact hFresh hClosed

/-- Validator-ready select variant ports belong to the top-level node summary. -/
theorem validatorReady_select_variantNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.port.node ∈ artifact.nodes :=
  (validatorReady_select_domainClosed hReady hSelect).variantPortsClosed variant hVariant

/-- Validator-ready select rows expose owner/condition equality. -/
theorem validatorReady_select_ownerMatchesCondition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.OwnerMatchesCondition :=
  (validatorReady_select_valid hReady hSelect).ownerMatchesCondition

/-- Validator-ready select rows expose permutation-level key coverage. -/
theorem validatorReady_select_keysCovered
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.KeysCovered :=
  (validatorReady_select_valid hReady hSelect).keysCovered

/-- Validator-ready select rows expose unique base variant keys. -/
theorem validatorReady_select_variantKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.VariantKeysUnique :=
  (validatorReady_select_valid hReady hSelect).variantKeysUnique

/-- Validator-ready select rows expose the exclusive-sum arity floor. -/
theorem validatorReady_select_variantsAtLeastTwo
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.VariantsAtLeastTwo :=
  (validatorReady_select_valid hReady hSelect).variantsAtLeastTwo

/-- Validator-ready select rows expose the source exclusive group shared by every base variant. -/
theorem validatorReady_select_variantsShareExclusiveGroup
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.VariantsShareExclusiveGroup :=
  (validatorReady_select_valid hReady hSelect).variantsShareExclusiveGroup

/-- Shared select variant groups force all variant rows to come from one source node. -/
theorem validatorReady_select_variants_sameSourceNode
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {left right : SelectVariantArtifact}
    (hLeft : left ∈ selectAdmission.variants)
    (hRight : right ∈ selectAdmission.variants) :
    left.port.node = right.port.node := by
  obtain ⟨owner, index, hGroup⟩ :=
    validatorReady_select_variantsShareExclusiveGroup hReady hSelect
  have hRows : selectAdmission.RowsValid :=
    (validatorReady_select_valid hReady hSelect).rowsValid
  have hLeftValid : left.Valid :=
    hRows.variantsValid left hLeft
  have hRightValid : right.Valid :=
    hRows.variantsValid right hRight
  have hLeftLocal :
      left.port.ExclusiveGroupOwnerLocal :=
    AdmissionBoundaryPort.valid_exclusiveGroupOwnerLocal hLeftValid.portValid
  have hRightLocal :
      right.port.ExclusiveGroupOwnerLocal :=
    AdmissionBoundaryPort.valid_exclusiveGroupOwnerLocal hRightValid.portValid
  unfold AdmissionBoundaryPort.ExclusiveGroupOwnerLocal at hLeftLocal hRightLocal
  rw [hGroup left hLeft] at hLeftLocal
  rw [hGroup right hRight] at hRightLocal
  exact hLeftLocal.symm.trans hRightLocal

/-- Validator-ready select rows expose unique canonical arm keys. -/
theorem validatorReady_select_armCanonicalKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.ArmCanonicalKeysUnique :=
  (validatorReady_select_valid hReady hSelect).armCanonicalKeysUnique

/-- Validator-ready select rows expose unique source-arm indexes. -/
theorem validatorReady_select_armSourceIndexesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.ArmSourceIndexesUnique :=
  (validatorReady_select_valid hReady hSelect).armSourceIndexesUnique

/-- Validator-ready select rows expose source-order arm indexes. -/
theorem validatorReady_select_armSourceIndexesCanonical
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.ArmSourceIndexesCanonical :=
  (validatorReady_select_valid hReady hSelect).armSourceIndexesCanonical

/-- Validator-ready select rows expose structural row validity. -/
theorem validatorReady_select_rowsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.RowsValid :=
  (validatorReady_select_valid hReady hSelect).rowsValid

/-- Validator-ready select rows expose owner-node identifier validity. -/
theorem validatorReady_select_ownerValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.owner.Valid :=
  (validatorReady_select_rowsValid hReady hSelect).ownerValid

/-- Validator-ready select rows expose condition-node identifier validity. -/
theorem validatorReady_select_conditionNodeValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.conditionNode.Valid :=
  (validatorReady_select_rowsValid hReady hSelect).conditionNodeValid

/-- Validator-ready select rows expose structural validity of each base variant row. -/
theorem validatorReady_select_variant_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.Valid :=
  (validatorReady_select_rowsValid hReady hSelect).variantsValid
    variant hVariant

/-- Validator-ready select variants expose valid canonical keys. -/
theorem validatorReady_select_variant_keyValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.key.Valid :=
  (validatorReady_select_variant_valid hReady hSelect hVariant).keyValid

/-- Validator-ready select variants expose valid boundary ports. -/
theorem validatorReady_select_variant_portValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.port.Valid :=
  (validatorReady_select_variant_valid hReady hSelect hVariant).portValid

/-- Validator-ready select rows expose structural validity of each serialized arm row. -/
theorem validatorReady_select_arm_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.Valid :=
  (validatorReady_select_rowsValid hReady hSelect).armsValid arm hArm

/-- Validator-ready select arms expose valid source keys. -/
theorem validatorReady_select_arm_sourceKeyValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.sourceKey.Valid :=
  (validatorReady_select_arm_valid hReady hSelect hArm).sourceKeyValid

/-- Validator-ready select arms expose valid canonical keys. -/
theorem validatorReady_select_arm_canonicalKeyValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.canonicalKey.Valid :=
  (validatorReady_select_arm_valid hReady hSelect hArm).canonicalKeyValid

/-- Validator-ready select arm rows expose body-boundary closure over the latent body nodes. -/
theorem validatorReady_select_arm_bodyBoundariesClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.BodyBoundariesClosed :=
  (validatorReady_select_arm_valid hReady hSelect hArm).bodyBoundariesClosed

/-- Validator-ready select arm body entries are closed over the latent body nodes. -/
theorem validatorReady_select_arm_bodyEntriesClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    BoundaryPortsClosed arm.bodyNodes arm.bodyEntries :=
  (validatorReady_select_arm_bodyBoundariesClosed hReady hSelect hArm).left

/-- Validator-ready select arm body exits are closed over the latent body nodes. -/
theorem validatorReady_select_arm_bodyExitsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    BoundaryPortsClosed arm.bodyNodes arm.bodyExits :=
  (validatorReady_select_arm_bodyBoundariesClosed hReady hSelect hArm).right

/-- Validator-ready select arm rows expose duplicate-free latent body rows. -/
theorem validatorReady_select_arm_bodyRowsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.BodyRowsUnique :=
  (validatorReady_select_arm_valid hReady hSelect hArm).bodyRowsUnique

/-- Validator-ready select arm body nodes are duplicate-free. -/
theorem validatorReady_select_arm_bodyNodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.bodyNodes.Nodup :=
  (validatorReady_select_arm_bodyRowsUnique hReady hSelect hArm).left

/-- Validator-ready select arm body entry rows are duplicate-free by endpoint key. -/
theorem validatorReady_select_arm_bodyEntryKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.bodyEntryKeys.Nodup :=
  (validatorReady_select_arm_bodyRowsUnique hReady hSelect hArm).right.left

/-- Validator-ready select arm body exit rows are duplicate-free by endpoint key. -/
theorem validatorReady_select_arm_bodyExitKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.bodyExitKeys.Nodup :=
  (validatorReady_select_arm_bodyRowsUnique hReady hSelect hArm).right.right

/-- Validator-ready select arm body nodes carry valid node identifiers. -/
theorem validatorReady_select_arm_bodyNodeValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {node : NodeId}
    (hNode : node ∈ arm.bodyNodes) :
    node.Valid :=
  (validatorReady_select_arm_valid hReady hSelect hArm).bodyNodesValid
    node hNode

/-- Validator-ready select arms expose valid latent body entry rows. -/
theorem validatorReady_select_arm_bodyEntriesValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    BoundaryPortsValid arm.bodyEntries :=
  (validatorReady_select_arm_valid hReady hSelect hArm).bodyEntriesValid

/-- Validator-ready select arms expose valid latent body exit rows. -/
theorem validatorReady_select_arm_bodyExitsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    BoundaryPortsValid arm.bodyExits :=
  (validatorReady_select_arm_valid hReady hSelect hArm).bodyExitsValid

/-- Validator-ready select arms expose validity of each latent body entry row. -/
theorem validatorReady_select_arm_bodyEntryValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {entry : AdmissionBoundaryPort}
    (hEntry : entry ∈ arm.bodyEntries) :
    entry.Valid :=
  validatorReady_select_arm_bodyEntriesValid hReady hSelect hArm entry hEntry

/-- Validator-ready select arms expose validity of each latent body exit row. -/
theorem validatorReady_select_arm_bodyExitValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ arm.bodyExits) :
    exit.Valid :=
  validatorReady_select_arm_bodyExitsValid hReady hSelect hArm exit hExit

/-- Validator-ready select rows expose canonicalized label-first keys for base variants. -/
theorem validatorReady_select_variant_keyCanonical
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.KeyCanonical :=
  let hRows := validatorReady_select_rowsValid hReady hSelect
  SelectVariantArtifact.valid_keyCanonical (hRows.variantsValid variant hVariant)

/-- Validator-ready select rows expose label-first resolution-mode soundness. -/
theorem validatorReady_select_armResolutionSound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.ArmResolutionSound :=
  (validatorReady_select_valid hReady hSelect).armResolutionSound

/-- Validator-ready select arms expose their label-first resolution evidence. -/
theorem validatorReady_select_armResolution
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    match arm.mode with
    | SelectResolutionMode.resolvedByLabel =>
        arm.sourceKey = arm.canonicalKey ∧
          ∃ variant, variant ∈ selectAdmission.variants ∧
            variant.key = arm.canonicalKey ∧
            variant.port.label = AdmissionPortLabel.label arm.sourceKey
    | SelectResolutionMode.resolvedByContract =>
        (∀ variant, variant ∈ selectAdmission.variants →
          variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) ∧
          (∀ variant, variant ∈ selectAdmission.variants →
            (variant.port.contract.name = arm.sourceKey.name ↔
              variant.key = arm.canonicalKey)) :=
  validatorReady_select_armResolutionSound hReady hSelect arm hArm

/-- Validator-ready label-resolved select arms expose their resolved variant directly. -/
theorem validatorReady_select_labelResolved_variant
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    (hMode : arm.mode = SelectResolutionMode.resolvedByLabel) :
    arm.sourceKey = arm.canonicalKey ∧
      ∃ variant, variant ∈ selectAdmission.variants ∧
        variant.key = arm.canonicalKey ∧
        variant.port.label = AdmissionPortLabel.label arm.sourceKey := by
  have hResolution :=
    validatorReady_select_armResolution hReady hSelect hArm
  rw [hMode] at hResolution
  exact hResolution

/-- Validator-ready label-resolved arms identify a unique labeled variant.

The executable resolver takes the label branch before contract fallback. Once a
label branch is serialized, variant-key uniqueness plus canonical variant keys
make the labeled target unique. -/
theorem validatorReady_select_labelResolved_uniqueVariant
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    (hMode : arm.mode = SelectResolutionMode.resolvedByLabel) :
    arm.sourceKey = arm.canonicalKey ∧
      ∃ variant, variant ∈ selectAdmission.variants ∧
        variant.key = arm.canonicalKey ∧
          variant.port.label = AdmissionPortLabel.label arm.sourceKey ∧
          ∀ other, other ∈ selectAdmission.variants →
            other.port.label = AdmissionPortLabel.label arm.sourceKey →
              other = variant := by
  obtain ⟨hSourceKey, variant, hVariant, hVariantKey, hVariantLabel⟩ :=
    validatorReady_select_labelResolved_variant hReady hSelect hArm hMode
  have hKeysUnique :=
    validatorReady_select_variantKeysUnique hReady hSelect
  have hUnique :
      ∀ other, other ∈ selectAdmission.variants →
        other.port.label = AdmissionPortLabel.label arm.sourceKey →
          other = variant := by
    intro other hOther hOtherLabel
    have hOtherCanonical :=
      validatorReady_select_variant_keyCanonical hReady hSelect hOther
    have hOtherKeySource : other.key = arm.sourceKey := by
      unfold SelectVariantArtifact.KeyCanonical at hOtherCanonical
      simpa [AdmissionBoundaryPort.selectKey, hOtherLabel] using hOtherCanonical
    have hOtherKey : other.key = arm.canonicalKey :=
      hOtherKeySource.trans hSourceKey
    exact
      List.inj_on_of_nodup_map hKeysUnique
        hOther
        hVariant
        (hOtherKey.trans hVariantKey.symm)
  exact
    ⟨ hSourceKey
    , ⟨ variant, hVariant, hVariantKey, hVariantLabel, hUnique ⟩
    ⟩

/-- Validator-ready select arm keys are covered by base variants. -/
theorem validatorReady_select_armCanonicalKey_mem_variantKeys
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    arm.canonicalKey ∈ selectAdmission.variantKeys := by
  have hCovered := validatorReady_select_keysCovered hReady hSelect
  have hArmKey : arm.canonicalKey ∈ selectAdmission.armCanonicalKeys := by
    exact List.mem_map.mpr ⟨arm, hArm, rfl⟩
  exact hCovered.mem_iff.mp hArmKey

/-- Validator-ready contract-fallback arms identify a unique unshadowed variant.

The executable resolver tries labels first and then admits a contract-name
fallback only when exactly one base variant has that contract. -/
theorem validatorReady_select_contractResolved_uniqueVariant
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    (hMode : arm.mode = SelectResolutionMode.resolvedByContract) :
    (∀ variant, variant ∈ selectAdmission.variants →
      variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) ∧
      ∃ variant, variant ∈ selectAdmission.variants ∧
        variant.key = arm.canonicalKey ∧
          variant.port.contract.name = arm.sourceKey.name ∧
          ∀ other, other ∈ selectAdmission.variants →
            other.port.contract.name = arm.sourceKey.name → other = variant := by
  have hResolution :=
    validatorReady_select_armResolution hReady hSelect hArm
  rw [hMode] at hResolution
  rcases hResolution with ⟨hNoLabel, hContractIff⟩
  have hKeyMem :=
    validatorReady_select_armCanonicalKey_mem_variantKeys hReady hSelect hArm
  rcases List.mem_map.mp hKeyMem with ⟨variant, hVariant, hVariantKey⟩
  have hContract :
      variant.port.contract.name = arm.sourceKey.name :=
    (hContractIff variant hVariant).mpr hVariantKey
  have hKeysUnique :=
    validatorReady_select_variantKeysUnique hReady hSelect
  have hUnique :
      ∀ other, other ∈ selectAdmission.variants →
        other.port.contract.name = arm.sourceKey.name → other = variant := by
    intro other hOther hOtherContract
    have hOtherKey :
        other.key = arm.canonicalKey :=
      (hContractIff other hOther).mp hOtherContract
    exact
      List.inj_on_of_nodup_map hKeysUnique
        hOther
        hVariant
        (hOtherKey.trans hVariantKey.symm)
  exact
    ⟨ hNoLabel
    , ⟨ variant, hVariant, hVariantKey, hContract, hUnique ⟩
    ⟩

/-- Validator-ready select variant keys are covered by source arms. -/
theorem validatorReady_select_variantKey_mem_armCanonicalKeys
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    variant.key ∈ selectAdmission.armCanonicalKeys := by
  have hCovered := validatorReady_select_keysCovered hReady hSelect
  have hVariantKey : variant.key ∈ selectAdmission.variantKeys := by
    exact List.mem_map.mpr ⟨variant, hVariant, rfl⟩
  exact hCovered.mem_iff.mpr hVariantKey

/-- Validator readiness exposes select key-cardinality for every select row. -/
theorem validatorReady_select_arms_length_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    selectAdmission.arms.length = selectAdmission.variants.length :=
  SelectAdmissionArtifact.keysCovered_length_eq
    (validatorReady_select_keysCovered hReady hSelect)

/-- Validator readiness exposes that a select row carries at least two admitted arms. -/
theorem validatorReady_select_armsAtLeastTwo
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects) :
    2 ≤ selectAdmission.arms.length := by
  rw [validatorReady_select_arms_length_eq hReady hSelect]
  exact validatorReady_select_variantsAtLeastTwo hReady hSelect

/-- Validator-ready select latent entries come from decoded source arm rows. -/
theorem validatorReady_select_latentEntry_sourceArm
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry :
      entry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries) :
    ∃ arm, arm ∈ selectAdmission.arms ∧
      entry = (arm.canonicalSelectArmKey, arm) :=
  SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm hEntry

/-- Validator-ready latent entry keys match their decoded source arm canonical keys. -/
theorem validatorReady_select_latentEntry_key_eq_bodyCanonical
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry :
      entry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries) :
    entry.fst = entry.snd.canonicalSelectArmKey :=
  SelectAdmissionArtifact.toLatentSelectAdmission_entry_key_eq_bodyCanonical hEntry

/-- Validator-ready select latent body rows retain their row-level validity. -/
theorem validatorReady_select_latentEntry_body_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry :
      entry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries) :
    entry.snd.Valid :=
  SelectAdmissionArtifact.toLatentSelectAdmission_entry_body_valid hEntry

/-- Validator-ready latent select body nodes are fresh from the top-level summary. -/
theorem validatorReady_select_latentEntry_bodyNodeFresh
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry :
      entry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries)
    {node : NodeId}
    (hNode : node ∈ entry.snd.bodyNodes) :
    node ∉ artifact.nodes := by
  obtain ⟨arm, hArm, hEq⟩ :=
    validatorReady_select_latentEntry_sourceArm hReady hSelect hEntry
  cases hEq
  exact validatorReady_select_armBodyNodeFresh hReady hSelect hArm hNode

/-- Validator-ready latent select entries with distinct keys have disjoint body node domains. -/
theorem validatorReady_select_latentEntries_bodyNodesDisjoint
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {leftEntry rightEntry : SelectArmKey × SelectArmAdmissionArtifact}
    (hLeftEntry :
      leftEntry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries)
    (hRightEntry :
      rightEntry ∈
        (selectAdmission.toLatentSelectAdmission
          (validatorReady_select_valid hReady hSelect)).entries)
    (hKeys : leftEntry.fst ≠ rightEntry.fst)
    {node : NodeId}
    (hNode : node ∈ leftEntry.snd.bodyNodes) :
    node ∉ rightEntry.snd.bodyNodes := by
  obtain ⟨leftArm, hLeftArm, hLeftEq⟩ :=
    validatorReady_select_latentEntry_sourceArm hReady hSelect hLeftEntry
  obtain ⟨rightArm, hRightArm, hRightEq⟩ :=
    validatorReady_select_latentEntry_sourceArm hReady hSelect hRightEntry
  cases hLeftEq
  cases hRightEq
  have hCanonicalKeys : leftArm.canonicalKey ≠ rightArm.canonicalKey := by
    intro hCanonicalEq
    apply hKeys
    unfold SelectArmAdmissionArtifact.canonicalSelectArmKey selectArmKeyOfFieldLabel
    rw [hCanonicalEq]
  exact
    validatorReady_select_armBodyNodesDisjoint
      hReady hSelect hLeftArm hRightArm hCanonicalKeys hNode

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
