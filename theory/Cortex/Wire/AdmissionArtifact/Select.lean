import Cortex.Wire.AdmissionArtifact.Boundary
import Cortex.Wire.SelectAdmission

/-!
## Overview

Select admission artifact rows for decoded Wire admission artifacts.

This page models persisted `select(...)` rows: base variants, source-arm
resolution modes, latent body summaries, and projection into the generic
`LatentSelectAdmission` carrier.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Select Artifacts -/

/-- Haskell select arm resolution mode. Labels are tried before contract fallback. -/
inductive SelectResolutionMode where
  | resolvedByLabel
  | resolvedByContract
  deriving Repr

/-- Interpret an artifact field label as a source select-arm key. -/
def selectArmKeyOfFieldLabel (label : FieldLabel) : SelectArmKey :=
  ⟨label.name⟩

/-- Valid artifact field labels remain valid when used as select-arm keys. -/
theorem selectArmKeyOfFieldLabel_valid
    {label : FieldLabel}
    (hValid : label.Valid) :
    (selectArmKeyOfFieldLabel label).Valid :=
  hValid

/-- One variant exposed by the selected base node. -/
structure SelectVariantArtifact where
  key : FieldLabel
  port : AdmissionBoundaryPort
  deriving Repr

namespace SelectVariantArtifact

/-- The persisted variant key is the label-first key derived from the boundary row. -/
def KeyCanonical (variant : SelectVariantArtifact) : Prop :=
  variant.key = variant.port.selectKey

/-- Variant key as the generic select-admission carrier expects it. -/
def selectArmKey (variant : SelectVariantArtifact) : SelectArmKey :=
  selectArmKeyOfFieldLabel variant.key

/-- Variant row projected into a selectable output-shape arm port. -/
def armPort (variant : SelectVariantArtifact) : SelectArmKey × PortSignature :=
  (variant.selectArmKey, { label := variant.key, contract := variant.port.contract })

/-- Select variant rows carry a valid arm key, boundary port, and canonicalized key. -/
structure Valid (variant : SelectVariantArtifact) : Prop where
  keyValid : variant.key.Valid
  portValid : variant.port.Valid
  keyCanonical : variant.KeyCanonical

/-- Valid select variants expose canonicalized label-first keys. -/
theorem valid_keyCanonical
    {variant : SelectVariantArtifact}
    (hValid : variant.Valid) :
    variant.KeyCanonical :=
  hValid.keyCanonical

/-- Valid select variants project to valid selectable output-shape arm keys. -/
theorem valid_selectArmKey
    {variant : SelectVariantArtifact}
    (hValid : variant.Valid) :
    variant.selectArmKey.Valid :=
  selectArmKeyOfFieldLabel_valid hValid.keyValid

/-- Valid select variants project to valid selectable output-shape port signatures. -/
theorem valid_armPort_signature
    {variant : SelectVariantArtifact}
    (hValid : variant.Valid) :
    variant.armPort.snd.Valid :=
  ⟨hValid.keyValid, AdmissionBoundaryPort.valid_contractValid hValid.portValid⟩

end SelectVariantArtifact

/-- One source arm admitted against a canonical variant. -/
structure SelectArmAdmissionArtifact where
  sourceIndex : Nat
  sourceKey : FieldLabel
  canonicalKey : FieldLabel
  mode : SelectResolutionMode
  bodyNodes : List NodeId
  bodyEntries : List AdmissionBoundaryPort
  bodyExits : List AdmissionBoundaryPort
  deriving Repr

namespace SelectArmAdmissionArtifact

/-- Serialized body-entry endpoint identities for this select arm. -/
def bodyEntryKeys (arm : SelectArmAdmissionArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  arm.bodyEntries.map AdmissionBoundaryPort.key

/-- Serialized body-exit endpoint identities for this select arm. -/
def bodyExitKeys (arm : SelectArmAdmissionArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  arm.bodyExits.map AdmissionBoundaryPort.key

/-- Canonical arm key as the generic select-admission carrier expects it. -/
def canonicalSelectArmKey (arm : SelectArmAdmissionArtifact) : SelectArmKey :=
  selectArmKeyOfFieldLabel arm.canonicalKey

/-- Body boundary rows belong to nodes serialized in the arm body. -/
def BodyBoundariesClosed (arm : SelectArmAdmissionArtifact) : Prop :=
  BoundaryPortsClosed arm.bodyNodes arm.bodyEntries ∧
    BoundaryPortsClosed arm.bodyNodes arm.bodyExits

/-- Select arm body rows are duplicate-free by serialized identity. -/
def BodyRowsUnique (arm : SelectArmAdmissionArtifact) : Prop :=
  arm.bodyNodes.Nodup ∧ arm.bodyEntryKeys.Nodup ∧ arm.bodyExitKeys.Nodup

/-- Select arm rows carry valid keys, body nodes, and boundary summaries. -/
structure Valid (arm : SelectArmAdmissionArtifact) : Prop where
  sourceKeyValid : arm.sourceKey.Valid
  canonicalKeyValid : arm.canonicalKey.Valid
  bodyBoundariesClosed : arm.BodyBoundariesClosed
  bodyRowsUnique : arm.BodyRowsUnique
  bodyNodesValid : ∀ node, node ∈ arm.bodyNodes → node.Valid
  bodyEntriesValid : BoundaryPortsValid arm.bodyEntries
  bodyExitsValid : BoundaryPortsValid arm.bodyExits

end SelectArmAdmissionArtifact

/-- Source `select(...)` admission artifact emitted for one condition node. -/
structure SelectAdmissionArtifact where
  owner : NodeId
  variants : List SelectVariantArtifact
  arms : List SelectArmAdmissionArtifact
  conditionNode : NodeId
  deriving Repr

namespace SelectAdmissionArtifact

/-- Canonical variant keys exposed by the selected base node. -/
def variantKeys (artifact : SelectAdmissionArtifact) : List FieldLabel :=
  artifact.variants.map SelectVariantArtifact.key

/-- Canonical variant keys as generic select-admission arm keys. -/
def variantSelectArmKeys (artifact : SelectAdmissionArtifact) : List SelectArmKey :=
  artifact.variants.map SelectVariantArtifact.selectArmKey

/-- Variant rows projected into a selectable output shape. -/
def variantArmPorts (artifact : SelectAdmissionArtifact) :
    List (SelectArmKey × PortSignature) :=
  artifact.variants.map SelectVariantArtifact.armPort

/-- Canonical variant keys covered by source arms after label/contract fallback resolution. -/
def armCanonicalKeys (artifact : SelectAdmissionArtifact) : List FieldLabel :=
  artifact.arms.map SelectArmAdmissionArtifact.canonicalKey

/-- Canonical arm keys as generic select-admission arm keys. -/
def armCanonicalSelectArmKeys (artifact : SelectAdmissionArtifact) :
    List SelectArmKey :=
  artifact.arms.map SelectArmAdmissionArtifact.canonicalSelectArmKey

/-- Source-arm indexes persisted by the compiler artifact. -/
def armSourceIndexes (artifact : SelectAdmissionArtifact) : List Nat :=
  artifact.arms.map SelectArmAdmissionArtifact.sourceIndex

/-- Variant keys exposed by the selected base node are unique. -/
def VariantKeysUnique (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.variantKeys.Nodup

/-- Select admission artifacts describe real exclusive output groups, not singleton outputs. -/
def VariantsAtLeastTwo (artifact : SelectAdmissionArtifact) : Prop :=
  2 ≤ artifact.variants.length

/-- Select variant ports all come from one source exclusive output group.

The compiler obtains these variants only after `resolveExclusiveBoundary`
accepts one non-empty exclusive frontier. The decoded artifact mirrors that
source obligation directly instead of relying on downstream bridge rows. -/
def VariantsShareExclusiveGroup (artifact : SelectAdmissionArtifact) : Prop :=
  ∃ owner index,
    ∀ variant, variant ∈ artifact.variants →
      variant.port.exclusiveGroup = some (owner, index)

/-- Canonical arm keys are unique after label/contract fallback resolution. -/
def ArmCanonicalKeysUnique (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.armCanonicalKeys.Nodup

/-- Source-arm indexes are unique in the serialized artifact. -/
def ArmSourceIndexesUnique (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.armSourceIndexes.Nodup

/-- Source-arm indexes preserve executable source-order enumeration. -/
def ArmSourceIndexesCanonical (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.armSourceIndexes = List.range artifact.arms.length

/-- The condition node that owns the latent branch family is the artifact owner. -/
def OwnerMatchesCondition (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.owner = artifact.conditionNode

/-- Source arms cover exactly the base variants, order-insensitively.

This mirrors `LatentSelectAdmission.entries_keys_perm` in `SelectAdmission`. -/
def KeysCovered (artifact : SelectAdmissionArtifact) : Prop :=
  artifact.armCanonicalKeys.Perm artifact.variantKeys

/-- Select admission rows carry valid owner/condition identifiers and child rows. -/
structure RowsValid (artifact : SelectAdmissionArtifact) : Prop where
  ownerValid : artifact.owner.Valid
  conditionNodeValid : artifact.conditionNode.Valid
  variantsValid : ∀ variant, variant ∈ artifact.variants → variant.Valid
  armsValid : ∀ arm, arm ∈ artifact.arms → arm.Valid

/-- Select admission owner, condition, and base variants are closed over the top-level node summary.

Arm body nodes are not checked here because they describe latent branch fragments:
they need not be present in the already-compiled top-level node summary until
runtime selected-branch replay materializes them. -/
structure DomainClosed (nodes : List NodeId) (artifact : SelectAdmissionArtifact) : Prop where
  ownerClosed : artifact.owner ∈ nodes
  conditionNodeClosed : artifact.conditionNode ∈ nodes
  variantPortsClosed : ∀ variant, variant ∈ artifact.variants → variant.port.node ∈ nodes

/-- A serialized select arm's resolution mode matches the variant rows it was resolved against.

Label resolution must target a variant whose serialized label is the source key.
Contract fallback must be unshadowed by any label of the same spelling and must
identify exactly one variant contract. This mirrors executable Wire's
label-first, unique-contract-fallback rule. -/
def ArmResolutionSound (artifact : SelectAdmissionArtifact) : Prop :=
  ∀ arm, arm ∈ artifact.arms →
    match arm.mode with
    | .resolvedByLabel =>
        arm.sourceKey = arm.canonicalKey ∧
          ∃ variant, variant ∈ artifact.variants ∧
            variant.key = arm.canonicalKey ∧
            variant.port.label = AdmissionPortLabel.label arm.sourceKey
    | .resolvedByContract =>
        (∀ variant, variant ∈ artifact.variants →
          variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) ∧
          (∀ variant, variant ∈ artifact.variants →
            (variant.port.contract.name = arm.sourceKey.name ↔
              variant.key = arm.canonicalKey))

/-- Row-level validator obligations for a select-admission artifact. -/
structure Valid (artifact : SelectAdmissionArtifact) : Prop where
  ownerMatchesCondition : artifact.OwnerMatchesCondition
  keysCovered : artifact.KeysCovered
  variantKeysUnique : artifact.VariantKeysUnique
  variantsAtLeastTwo : artifact.VariantsAtLeastTwo
  variantsShareExclusiveGroup : artifact.VariantsShareExclusiveGroup
  armCanonicalKeysUnique : artifact.ArmCanonicalKeysUnique
  armSourceIndexesUnique : artifact.ArmSourceIndexesUnique
  armSourceIndexesCanonical : artifact.ArmSourceIndexesCanonical
  rowsValid : artifact.RowsValid
  armResolutionSound : artifact.ArmResolutionSound

/-- Key coverage forces the number of admitted arms to match the number of base variants. -/
theorem keysCovered_length_eq
    {artifact : SelectAdmissionArtifact}
    (hCovered : artifact.KeysCovered) :
    artifact.arms.length = artifact.variants.length := by
  simpa [KeysCovered, armCanonicalKeys, variantKeys] using hCovered.length_eq

/-- Field-label key coverage transports to the generic select-admission key carrier. -/
theorem keysCovered_selectArmKeys_perm
    {artifact : SelectAdmissionArtifact}
    (hCovered : artifact.KeysCovered) :
    artifact.armCanonicalSelectArmKeys.Perm artifact.variantSelectArmKeys := by
  have hMapped :=
    hCovered.map selectArmKeyOfFieldLabel
  simpa
    [ KeysCovered
    , armCanonicalKeys
    , variantKeys
    , armCanonicalSelectArmKeys
    , variantSelectArmKeys
    , List.map_map
    , Function.comp_def
    ] using hMapped

/-- Valid select artifacts project to the generic source-select output-shape carrier. -/
def toSelectableOutputShape
    (artifact : SelectAdmissionArtifact)
    (hValid : artifact.Valid) :
    SelectAdmission.SelectableOutputShape where
  armPorts := artifact.variantArmPorts
  armsAtLeastTwo := by
    simpa [variantArmPorts] using hValid.variantsAtLeastTwo
  armKeysUnique := by
    have hKeys :
        artifact.variantSelectArmKeys.Nodup := by
      have hMapped :
          (artifact.variantKeys.map selectArmKeyOfFieldLabel).Nodup := by
        exact
          hValid.variantKeysUnique.map
            (by
              intro left right hEq
              cases left
              cases right
              cases hEq
              rfl)
      simpa
        [ variantSelectArmKeys
        , variantKeys
        , SelectVariantArtifact.selectArmKey
        , List.map_map
        , Function.comp_def
        ] using hMapped
    simpa
      [variantArmPorts, variantSelectArmKeys, SelectVariantArtifact.armPort]
      using hKeys
  portLabelsUnique := by
    simpa
      [ variantArmPorts
      , variantKeys
      , SelectVariantArtifact.armPort
      , List.map_map
      , Function.comp_def
      ] using hValid.variantKeysUnique
  armKeysValid := by
    intro entry hEntry
    rcases List.mem_map.mp hEntry with ⟨variant, hVariant, hEq⟩
    subst hEq
    exact
      SelectVariantArtifact.valid_selectArmKey
        (hValid.rowsValid.variantsValid variant hVariant)
  armPortsValid := by
    intro entry hEntry
    rcases List.mem_map.mp hEntry with ⟨variant, hVariant, hEq⟩
    subst hEq
    exact
      SelectVariantArtifact.valid_armPort_signature
        (hValid.rowsValid.variantsValid variant hVariant)

/-- Valid select artifacts project to the generic latent-select key carrier.

The latent body is still the decoded artifact arm row, not a `SubgraphSpec`.
This is the first artifact-to-admission bridge: it proves that persisted arm
rows have the same key coverage shape as `SelectAdmission.LatentSelectAdmission`.
-/
def toLatentSelectAdmission
    (artifact : SelectAdmissionArtifact)
    (hValid : artifact.Valid) :
    SelectAdmission.LatentSelectAdmission SelectArmAdmissionArtifact where
  shape := artifact.toSelectableOutputShape hValid
  entries := artifact.arms.map fun arm => (arm.canonicalSelectArmKey, arm)
  entries_keys_perm := by
    have hPerm := keysCovered_selectArmKeys_perm hValid.keysCovered
    simpa
      [ toSelectableOutputShape
      , SelectAdmission.SelectableOutputShape.armKeys
      , armCanonicalSelectArmKeys
      , variantSelectArmKeys
      , variantArmPorts
      , SelectVariantArtifact.armPort
      , List.map_map
      , Function.comp_def
      ] using hPerm

/-- Entries in the artifact-projected latent admission are exactly decoded source arm rows. -/
theorem toLatentSelectAdmission_entry_sourceArm
    {artifact : SelectAdmissionArtifact}
    {hValid : artifact.Valid}
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry : entry ∈ (artifact.toLatentSelectAdmission hValid).entries) :
    ∃ arm, arm ∈ artifact.arms ∧ entry = (arm.canonicalSelectArmKey, arm) := by
  change
    entry ∈ artifact.arms.map (fun arm => (arm.canonicalSelectArmKey, arm))
      at hEntry
  rcases List.mem_map.mp hEntry with ⟨arm, hArm, hEq⟩
  exact ⟨arm, hArm, hEq.symm⟩

/-- Latent entry keys are the canonical keys of their decoded source arm rows. -/
theorem toLatentSelectAdmission_entry_key_eq_bodyCanonical
    {artifact : SelectAdmissionArtifact}
    {hValid : artifact.Valid}
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry : entry ∈ (artifact.toLatentSelectAdmission hValid).entries) :
    entry.fst = entry.snd.canonicalSelectArmKey := by
  obtain ⟨arm, _hArm, hEq⟩ :=
    toLatentSelectAdmission_entry_sourceArm hEntry
  cases hEq
  rfl

/-- Every decoded source arm appears in the artifact-projected latent admission. -/
theorem toLatentSelectAdmission_sourceArm_entry
    {artifact : SelectAdmissionArtifact}
    {hValid : artifact.Valid}
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ artifact.arms) :
    (arm.canonicalSelectArmKey, arm) ∈
      (artifact.toLatentSelectAdmission hValid).entries := by
  change
    (arm.canonicalSelectArmKey, arm) ∈
      artifact.arms.map (fun arm => (arm.canonicalSelectArmKey, arm))
  exact List.mem_map.mpr ⟨arm, hArm, rfl⟩

/-- Latent bodies produced from valid artifacts retain source-arm row validity. -/
theorem toLatentSelectAdmission_entry_body_valid
    {artifact : SelectAdmissionArtifact}
    {hValid : artifact.Valid}
    {entry : SelectArmKey × SelectArmAdmissionArtifact}
    (hEntry : entry ∈ (artifact.toLatentSelectAdmission hValid).entries) :
    entry.snd.Valid := by
  obtain ⟨arm, hArm, hEq⟩ :=
    toLatentSelectAdmission_entry_sourceArm hEntry
  cases hEq
  exact hValid.rowsValid.armsValid arm hArm

end SelectAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
