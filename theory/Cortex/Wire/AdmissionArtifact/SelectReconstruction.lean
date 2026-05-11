import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction

/-!
## Overview

Select-admission reconstruction from validator-sound admission artifacts.

The select artifact rows already project to the generic
`SelectAdmission.LatentSelectAdmission` carrier. This module names the
artifact-boundary reconstruction theorem that downstream correspondence proofs
should consume:

- every select row carries the projected latent admission and key coverage;
- latent entries come from decoded source arm rows;
- label-first and unique-contract-fallback resolution facts are preserved;
- latent body nodes are fresh from the top-level summary and pairwise disjoint;
- arm body boundary rows match the condition bridge; and
- selected-variant bridge entries are consumed by primitive replay.

This is still source-side admission. Replaying a chosen latent body into durable
selected-branch recovery remains a separate proof surface.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-! ## Select Reconstruction Contract -/

/-- Resolution evidence for one persisted source select arm. -/
inductive SelectArmResolutionReconstruction
    (selectAdmission : SelectAdmissionArtifact)
    (arm : SelectArmAdmissionArtifact) : Prop where
  | byLabel
      (mode_eq : arm.mode = SelectResolutionMode.resolvedByLabel)
      (sourceKey_eq : arm.sourceKey = arm.canonicalKey)
      (variant :
        ∃ variant, variant ∈ selectAdmission.variants ∧
          variant.key = arm.canonicalKey ∧
          variant.port.label = AdmissionPortLabel.label arm.sourceKey) :
        SelectArmResolutionReconstruction selectAdmission arm
  | byContract
      (mode_eq : arm.mode = SelectResolutionMode.resolvedByContract)
      (noLabelShadow :
        ∀ variant, variant ∈ selectAdmission.variants →
          variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey)
      (contractFallbackUnique :
        ∀ variant, variant ∈ selectAdmission.variants →
          (variant.port.contract.name = arm.sourceKey.name ↔
            variant.key = arm.canonicalKey)) :
        SelectArmResolutionReconstruction selectAdmission arm

/-- Condition-bridge/body-boundary evidence for one select arm. -/
structure SelectArmBridgeReconstruction
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (arm : SelectArmAdmissionArtifact)
    (entries exits : List AdmissionBoundaryPort)
    (variant : SelectVariantArtifact) : Prop where
  primitiveConditionNode :
    PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
      artifact.primitiveSteps
  variantMem : variant ∈ selectAdmission.variants
  variantKey : variant.key = arm.canonicalKey
  bodyShape :
    (((arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
        SelectConditionBridgeOutputShapes selectAdmission exits =
          [variant.port.identityOutputShape]) ∨
      (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
          [variant.port.compatibilityShape] ∧
        (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
          (SelectConditionBridgeOutputShapes selectAdmission exits)))
  conditionInputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ entries.map AdmissionBoundaryPort.key →
        PrimitiveInputKeyAccounted artifact key
  conditionOutputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ exits.map AdmissionBoundaryPort.key →
        PrimitiveOutputKeyAccounted artifact key

/-- Artifact-boundary bridge evidence exists for one select arm. -/
def SelectArmBridge
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (arm : SelectArmAdmissionArtifact) : Prop :=
  ∃ entries exits variant,
    SelectArmBridgeReconstruction artifact selectAdmission arm entries exits variant

/-- Primitive replay evidence for one selected variant's bridge entry. -/
structure SelectVariantBridgeReconstruction
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (variant : SelectVariantArtifact)
    (entries exits : List AdmissionBoundaryPort)
    (entry : AdmissionBoundaryPort) : Prop where
  primitiveConditionNode :
    PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
      artifact.primitiveSteps
  entryMem : entry ∈ entries
  compatible : variant.port.CompatibleWith entry
  replayed :
    { fromPort := variant.port, toPort := entry } ∈
      PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps
  entryConsumed :
    entry.key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps

/-- Artifact-boundary variant bridge evidence exists for one base variant. -/
def SelectVariantBridge
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (variant : SelectVariantArtifact) : Prop :=
  ∃ entries exits entry,
    SelectVariantBridgeReconstruction
      artifact selectAdmission variant entries exits entry

/-- Reconstruction evidence for one projected latent select entry. -/
structure SelectLatentEntryReconstruction
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (hValid : selectAdmission.Valid)
    (entry : SelectArmKey × SelectArmAdmissionArtifact) : Prop where
  sourceArm :
    ∃ arm, arm ∈ selectAdmission.arms ∧
      entry = (arm.canonicalSelectArmKey, arm)
  bodyValid : entry.snd.Valid
  bodyNodeFresh :
    ∀ {node : NodeId}, node ∈ entry.snd.bodyNodes → node ∉ artifact.nodes
  bodyNodesDisjoint :
    ∀ {other : SelectArmKey × SelectArmAdmissionArtifact},
      other ∈ (selectAdmission.toLatentSelectAdmission hValid).entries →
        entry.fst ≠ other.fst →
          ∀ {node : NodeId},
            node ∈ entry.snd.bodyNodes → node ∉ other.snd.bodyNodes

/-- Artifact-boundary reconstruction evidence for one select-admission row. -/
structure SelectAdmissionReconstruction
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact) : Prop where
  valid : selectAdmission.Valid
  ownerMatchesCondition : selectAdmission.owner = selectAdmission.conditionNode
  armsAtLeastTwo : 2 ≤ selectAdmission.arms.length
  latentKeyCoverage :
    ((selectAdmission.toLatentSelectAdmission valid).entries.map Prod.fst).Perm
      (selectAdmission.toLatentSelectAdmission valid).shape.armKeys
  latentEntries :
    ∀ {entry : SelectArmKey × SelectArmAdmissionArtifact},
      entry ∈ (selectAdmission.toLatentSelectAdmission valid).entries →
        SelectLatentEntryReconstruction artifact selectAdmission valid entry
  armResolution :
    ∀ {arm : SelectArmAdmissionArtifact},
      arm ∈ selectAdmission.arms →
        SelectArmResolutionReconstruction selectAdmission arm
  armBridge :
    ∀ {arm : SelectArmAdmissionArtifact},
      arm ∈ selectAdmission.arms →
        SelectArmBridge artifact selectAdmission arm
  variantBridge :
    ∀ {variant : SelectVariantArtifact},
      variant ∈ selectAdmission.variants →
        SelectVariantBridge artifact selectAdmission variant

/-- Artifact-boundary select reconstruction for every select row. -/
def SelectReconstruction (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    SelectAdmissionReconstruction artifact selectAdmission

/-! ## Reconstruction Theorems -/

/-- Select soundness reconstructs source-arm resolution evidence for one arm. -/
theorem Sound.selectArmResolutionReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    SelectArmResolutionReconstruction selectAdmission arm := by
  have hValid := hSound.select.selectsValid selectAdmission hSelect
  have hResolution := hValid.armResolutionSound arm hArm
  cases hMode : arm.mode with
  | resolvedByLabel =>
      rw [hMode] at hResolution
      exact
        SelectArmResolutionReconstruction.byLabel
          hMode hResolution.left hResolution.right
  | resolvedByContract =>
      rw [hMode] at hResolution
      exact
        SelectArmResolutionReconstruction.byContract
          hMode hResolution.left hResolution.right

/-- Select soundness reconstructs condition-bridge evidence for one arm. -/
theorem Sound.selectArmBridge
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms) :
    SelectArmBridge artifact selectAdmission arm := by
  obtain ⟨entries, exits, hPrimitiveNode, hArms⟩ :=
    hSound.select.selectArmBodyBoundariesMatchCondition
      selectAdmission hSelect
  obtain ⟨variant, hVariant, hVariantKey, hBodyShape⟩ :=
    hArms arm hArm
  have hAccounted :
      artifact.PrimitiveFrontierKeysAccounted :=
    primitiveFrontierKeysAccounted
      hSound.primitive.summaryFrontiersMatchPrimitive
  refine ⟨entries, exits, variant, ?_⟩
  exact
    { primitiveConditionNode := hPrimitiveNode
      variantMem := hVariant
      variantKey := hVariantKey
      bodyShape := hBodyShape
      conditionInputKeysAccounted := by
        intro key hKey
        have hPrimitiveKey :
            key ∈ PrimitiveGraphStep.nodeEntryKeysList
              artifact.primitiveSteps :=
          PrimitiveGraphStep.nodeEntryKeysList_mem_of_node_mem
            hPrimitiveNode hKey
        exact hAccounted.inputs hPrimitiveKey
      conditionOutputKeysAccounted := by
        intro key hKey
        have hPrimitiveKey :
            key ∈ PrimitiveGraphStep.nodeExitKeysList
              artifact.primitiveSteps :=
          PrimitiveGraphStep.nodeExitKeysList_mem_of_node_mem
            hPrimitiveNode hKey
        exact hAccounted.outputs hPrimitiveKey }

/-- Select soundness reconstructs primitive bridge evidence for one base variant. -/
theorem Sound.selectVariantBridge
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    SelectVariantBridge artifact selectAdmission variant := by
  obtain ⟨entries, exits, entry, hPrimitiveNode, hEntry, hCompat,
    hReplayed, hConsumed⟩ :=
      hSound.select.variantBridgeEntryConsumed hSelect hVariant
  exact
    ⟨ entries
    , exits
    , entry
    , { primitiveConditionNode := hPrimitiveNode
        entryMem := hEntry
        compatible := hCompat
        replayed := hReplayed
        entryConsumed := hConsumed }
    ⟩

/-- Select soundness reconstructs provenance and freshness for one latent entry. -/
theorem Sound.selectLatentEntryReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    (hValid : selectAdmission.Valid)
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry :
      entry ∈ (selectAdmission.toLatentSelectAdmission hValid).entries) :
    SelectLatentEntryReconstruction artifact selectAdmission hValid entry := by
  exact
    { sourceArm :=
        hSound.select.latentEntrySourceArm hSelect hValid hEntry
      bodyValid :=
        SelectAdmissionArtifact.toLatentSelectAdmission_entry_body_valid
          hEntry
      bodyNodeFresh := by
        intro node hNode
        exact
          hSound.select.latentEntryBodyNodeFresh
            hSelect hValid hEntry hNode
      bodyNodesDisjoint := by
        intro other hOther hKeys node hNode
        exact
          hSound.select.latentEntriesBodyNodesDisjoint
            hSelect hValid hEntry hOther hKeys hNode }

/-- Validator soundness reconstructs select-admission artifact-boundary witnesses. -/
theorem Sound.toSelectReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound) :
    artifact.SelectReconstruction := by
  intro selectAdmission hSelect
  let hValid := hSound.select.selectsValid selectAdmission hSelect
  exact
    { valid := hValid
      ownerMatchesCondition := hValid.ownerMatchesCondition
      armsAtLeastTwo := hSound.select.armsAtLeastTwo hSelect
      latentKeyCoverage :=
        (selectAdmission.toLatentSelectAdmission hValid).entries_keys_perm
      latentEntries := by
        intro entry hEntry
        exact
          hSound.selectLatentEntryReconstruction
            hSelect hValid hEntry
      armResolution := by
        intro arm hArm
        exact hSound.selectArmResolutionReconstruction hSelect hArm
      armBridge := by
        intro arm hArm
        exact hSound.selectArmBridge hSelect hArm
      variantBridge := by
        intro variant hVariant
        exact hSound.selectVariantBridge hSelect hVariant }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
