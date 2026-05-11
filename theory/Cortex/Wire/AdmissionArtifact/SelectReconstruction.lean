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

The reconstruction record exposes one shared `(conditionEntries, conditionExits)`
primitive node row at the top level so that all per-arm and per-variant bridge
facts witness the same primitive backing for the condition node.

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

/-- Body-shape evidence for one source select arm against its chosen variant
and the shared condition-bridge exits. -/
inductive SelectArmBodyShapeReconstruction
    (selectAdmission : SelectAdmissionArtifact)
    (arm : SelectArmAdmissionArtifact)
    (conditionExits : List AdmissionBoundaryPort)
    (variant : SelectVariantArtifact) : Prop where
  | emptyBody
      (bodyNodesEmpty : arm.bodyNodes = [])
      (bodyEntriesEmpty : arm.bodyEntries = [])
      (bodyExitsEmpty : arm.bodyExits = [])
      (conditionOutputShapesIdentity :
        SelectConditionBridgeOutputShapes selectAdmission conditionExits =
          [variant.port.identityOutputShape]) :
        SelectArmBodyShapeReconstruction
          selectAdmission arm conditionExits variant
  | nonEmptyBody
      (bodyEntriesMatch :
        arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
          [variant.port.compatibilityShape])
      (bodyExitsPerm :
        (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
          (SelectConditionBridgeOutputShapes selectAdmission conditionExits)) :
        SelectArmBodyShapeReconstruction
          selectAdmission arm conditionExits variant

/-- Condition-bridge variant evidence for one source select arm, indexed by
the shared condition-node exits and the resolved variant. -/
structure SelectArmBridgeReconstruction
    (selectAdmission : SelectAdmissionArtifact)
    (arm : SelectArmAdmissionArtifact)
    (conditionExits : List AdmissionBoundaryPort)
    (variant : SelectVariantArtifact) : Prop where
  variantMem : variant ∈ selectAdmission.variants
  variantKey : variant.key = arm.canonicalKey
  bodyShape :
    SelectArmBodyShapeReconstruction selectAdmission arm conditionExits variant

/-- Primitive replay evidence for one selected variant's bridge entry, indexed
by the shared condition-node entries and the chosen entry. -/
structure SelectVariantBridgeReconstruction
    (artifact : WireAdmissionArtifact)
    (variant : SelectVariantArtifact)
    (conditionEntries : List AdmissionBoundaryPort)
    (entry : AdmissionBoundaryPort) : Prop where
  entryMem : entry ∈ conditionEntries
  compatible : variant.port.CompatibleWith entry
  replayed :
    { fromPort := variant.port, toPort := entry } ∈
      PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps
  entryConsumed :
    entry.key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps

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

/-- Artifact-boundary reconstruction evidence for one select-admission row,
indexed by a shared condition-node primitive row.

Sharing `conditionEntries` / `conditionExits` at this layer rules out the
formal countermodel where `armBridge` and `variantBridge` could pick different
primitive node rows for the same `selectAdmission.conditionNode`. -/
structure SelectAdmissionReconstructionRecord
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact)
    (conditionEntries conditionExits : List AdmissionBoundaryPort) : Prop where
  valid : selectAdmission.Valid
  ownerMatchesCondition : selectAdmission.owner = selectAdmission.conditionNode
  armsAtLeastTwo : 2 ≤ selectAdmission.arms.length
  latentKeyCoverage :
    ((selectAdmission.toLatentSelectAdmission valid).entries.map Prod.fst).Perm
      (selectAdmission.toLatentSelectAdmission valid).shape.armKeys
  primitiveConditionNode :
    PrimitiveGraphStep.node selectAdmission.conditionNode
        conditionEntries conditionExits ∈
      artifact.primitiveSteps
  conditionInputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ conditionEntries.map AdmissionBoundaryPort.key →
        PrimitiveInputKeyAccounted artifact key
  conditionOutputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ conditionExits.map AdmissionBoundaryPort.key →
        PrimitiveOutputKeyAccounted artifact key
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
        ∃ variant,
          SelectArmBridgeReconstruction
            selectAdmission arm conditionExits variant
  variantBridge :
    ∀ {variant : SelectVariantArtifact},
      variant ∈ selectAdmission.variants →
        ∃ entry,
          SelectVariantBridgeReconstruction
            artifact variant conditionEntries entry

/-- Artifact-boundary reconstruction evidence for one select-admission row. -/
def SelectAdmissionReconstruction
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact) : Prop :=
  ∃ conditionEntries conditionExits,
    SelectAdmissionReconstructionRecord
      artifact selectAdmission conditionEntries conditionExits

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

/-- Validator soundness reconstructs select-admission artifact-boundary witnesses
indexed by a single shared condition-node primitive row.

Primitive node-row uniqueness (`Sound.primitiveNode_frontiers_unique`) collapses
the per-variant existential in `variantBridgeEntryConsumed` onto the same
`(conditionEntries, conditionExits)` chosen by
`selectArmBodyBoundariesMatchCondition`. -/
theorem Sound.toSelectReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound) :
    artifact.SelectReconstruction := by
  intro selectAdmission hSelect
  obtain ⟨conditionEntries, conditionExits, hPrimitiveNode, hArms⟩ :=
    hSound.select.selectArmBodyBoundariesMatchCondition
      selectAdmission hSelect
  have hValid := hSound.select.selectsValid selectAdmission hSelect
  have hAccounted :
      artifact.PrimitiveFrontierKeysAccounted :=
    primitiveFrontierKeysAccounted
      hSound.primitive.summaryFrontiersMatchPrimitive
  refine ⟨conditionEntries, conditionExits, ?_⟩
  refine
    { valid := hValid
      ownerMatchesCondition := hValid.ownerMatchesCondition
      armsAtLeastTwo := hSound.select.armsAtLeastTwo hSelect
      latentKeyCoverage :=
        (selectAdmission.toLatentSelectAdmission hValid).entries_keys_perm
      primitiveConditionNode := hPrimitiveNode
      conditionInputKeysAccounted := ?inputs
      conditionOutputKeysAccounted := ?outputs
      latentEntries := ?latent
      armResolution := ?resolution
      armBridge := ?bridge
      variantBridge := ?variantBridge }
  case inputs =>
    intro key hKey
    exact
      hAccounted.inputs
        (PrimitiveGraphStep.nodeEntryKeysList_mem_of_node_mem
          hPrimitiveNode hKey)
  case outputs =>
    intro key hKey
    exact
      hAccounted.outputs
        (PrimitiveGraphStep.nodeExitKeysList_mem_of_node_mem
          hPrimitiveNode hKey)
  case latent =>
    intro entry hEntry
    exact hSound.selectLatentEntryReconstruction hSelect hValid hEntry
  case resolution =>
    intro arm hArm
    exact hSound.selectArmResolutionReconstruction hSelect hArm
  case bridge =>
    intro arm hArm
    obtain ⟨variant, hVariantMem, hVariantKey, hBodyShape⟩ := hArms arm hArm
    refine
      ⟨ variant
      , { variantMem := hVariantMem
          variantKey := hVariantKey
          bodyShape := ?_ }⟩
    cases hBodyShape with
    | inl hEmpty =>
        obtain ⟨⟨hBodyNodes, hBodyEntries, hBodyExits⟩, hOutputShapes⟩ :=
          hEmpty
        exact
          SelectArmBodyShapeReconstruction.emptyBody
            hBodyNodes hBodyEntries hBodyExits hOutputShapes
    | inr hNonEmpty =>
        exact
          SelectArmBodyShapeReconstruction.nonEmptyBody
            hNonEmpty.left hNonEmpty.right
  case variantBridge =>
    intro variant hVariant
    obtain
      ⟨variantEntries, _variantExits, variantEntry,
        hVariantPrimitiveNode, hVariantEntryMem, hVariantCompat,
        hVariantReplayed, hVariantConsumed⟩ :=
      hSound.select.variantBridgeEntryConsumed hSelect hVariant
    obtain ⟨hEntriesEq, _hExitsEq⟩ :=
      hSound.primitiveNode_frontiers_unique
        hVariantPrimitiveNode hPrimitiveNode
    subst hEntriesEq
    exact
      ⟨ variantEntry
      , { entryMem := hVariantEntryMem
          compatible := hVariantCompat
          replayed := hVariantReplayed
          entryConsumed := hVariantConsumed }⟩

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
