import Cortex.Wire.AdmissionArtifact.Sound

/-!
## Overview

Primitive graph reconstruction from a validator-sound admission artifact.

The decoded admission artifact is lower-level than `GraphElaboration.CertifiedGraph`:
it carries primitive boundary rows and a replay stack, not accepted node declarations
inside an `AdmittedModuleShell`. This module therefore names the strongest honest
primitive reconstruction target at the artifact boundary.

A `PrimitiveGraphReconstruction` says:

- primitive rows replay to one final frame;
- the final frame is exactly the top-level serialized summary, up to permutation;
- source-visible frontier rows are duplicate-free;
- every primitive node-frontier key is accounted for as exposed, consumed, or
  select-internal; and
- top-level raw connections are exactly the raw projection of replayed primitive
  contractions.

The later `CertifiedGraph` reconstruction step must add the accepted-node/module
evidence that is intentionally absent from the serialized artifact rows.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

namespace PrimitiveTraceFrame

/-! ## Frame-Level Linearity Facts -/

/-- Duplicate-free primitive replay rows after summary matching.

This is the artifact-level frontier-linearity fact: source-visible entry and
exit endpoints have unique boundary keys, and the raw connection summary has no
duplicate serialized connection rows. It is deliberately phrased over the
primitive replay frame rather than over `LinearPortObject`, because artifact rows
do not carry accepted node declarations. -/
structure SourceVisibleRowsUnique (frame : PrimitiveTraceFrame) : Prop where
  nodesUnique : frame.nodes.Nodup
  bindingRefsUnique : frame.bindingRefs.Nodup
  entriesUnique : (frame.entries.map AdmissionBoundaryPort.key).Nodup
  exitsUnique : (frame.exits.map AdmissionBoundaryPort.key).Nodup
  connectionsUnique : frame.connections.Nodup

/-- A summary-matching frame inherits the artifact's duplicate-free summary rows. -/
theorem sourceVisibleRowsUnique_of_matchesSummary
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact)
    (hUnique : artifact.SummaryKeysUnique) :
    frame.SourceVisibleRowsUnique where
  nodesUnique := by
    exact
      (matchesSummary_nodes_perm hMatch).nodup_iff.mpr
        hUnique.nodesUnique
  bindingRefsUnique := by
    exact
      (matchesSummary_bindingRefs_perm hMatch).nodup_iff.mpr
        hUnique.bindingRefsUnique
  entriesUnique := by
    have hPerm :
        (frame.entries.map AdmissionBoundaryPort.key).Perm
          (artifact.entries.map AdmissionBoundaryPort.key) :=
      (matchesSummary_entries_perm hMatch).map AdmissionBoundaryPort.key
    exact hPerm.nodup_iff.mpr hUnique.entriesUnique
  exitsUnique := by
    have hPerm :
        (frame.exits.map AdmissionBoundaryPort.key).Perm
          (artifact.exits.map AdmissionBoundaryPort.key) :=
      (matchesSummary_exits_perm hMatch).map AdmissionBoundaryPort.key
    exact hPerm.nodup_iff.mpr hUnique.exitsUnique
  connectionsUnique := by
    exact
      (matchesSummary_connections_perm hMatch).nodup_iff.mpr
        hUnique.connectionsUnique

end PrimitiveTraceFrame

/-! ## Primitive Frontier Accounting -/

/-- A primitive input key is accounted for either as a source-visible entry or
as an input consumed by a primitive contraction. -/
inductive PrimitiveInputKeyAccounted
    (artifact : WireAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId) : Prop where
  | exposed :
      key ∈ artifact.entries.map AdmissionBoundaryPort.key →
        PrimitiveInputKeyAccounted artifact key
  | consumed :
      key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps →
        PrimitiveInputKeyAccounted artifact key

/-- A primitive output key is accounted for as a source-visible exit, as an
output consumed by a primitive contraction, or as a select-condition internal
choice exit hidden from the source-visible summary. -/
inductive PrimitiveOutputKeyAccounted
    (artifact : WireAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId) : Prop where
  | exposed :
      key ∈ artifact.exits.map AdmissionBoundaryPort.key →
        PrimitiveOutputKeyAccounted artifact key
  | consumed :
      key ∈ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps →
        PrimitiveOutputKeyAccounted artifact key
  | selectInternal :
      artifact.SelectInternalExitKey key →
        PrimitiveOutputKeyAccounted artifact key

/-- Every primitive node frontier key has a linear accounting classification. -/
structure PrimitiveFrontierKeysAccounted
    (artifact : WireAdmissionArtifact) : Prop where
  inputs :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps →
        PrimitiveInputKeyAccounted artifact key
  outputs :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps →
        PrimitiveOutputKeyAccounted artifact key

/-- Exact residual-frontier coverage classifies every primitive input key. -/
theorem primitiveInputKey_accounted
    {artifact : WireAdmissionArtifact}
    (hFrontiers : artifact.SummaryFrontiersMatchPrimitive)
    {key : NodeId × FieldLabel × ContractId}
    (hPrimitiveKey :
      key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps) :
    PrimitiveInputKeyAccounted artifact key := by
  by_cases hConsumed :
      key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps
  · exact PrimitiveInputKeyAccounted.consumed hConsumed
  · exact
      PrimitiveInputKeyAccounted.exposed
        ((hFrontiers.left key).mpr ⟨hPrimitiveKey, hConsumed⟩)

/-- Exact residual-frontier coverage classifies every primitive output key. -/
theorem primitiveOutputKey_accounted
    {artifact : WireAdmissionArtifact}
    (hFrontiers : artifact.SummaryFrontiersMatchPrimitive)
    {key : NodeId × FieldLabel × ContractId}
    (hPrimitiveKey :
      key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps) :
    PrimitiveOutputKeyAccounted artifact key := by
  by_cases hConsumed :
      key ∈ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps
  · exact PrimitiveOutputKeyAccounted.consumed hConsumed
  · by_cases hInternal : artifact.SelectInternalExitKey key
    · exact PrimitiveOutputKeyAccounted.selectInternal hInternal
    · exact
        PrimitiveOutputKeyAccounted.exposed
          ((hFrontiers.right key).mpr
            ⟨hPrimitiveKey, hConsumed, hInternal⟩)

/-- Exact residual-frontier coverage gives the primitive frontier accounting
needed by reconstruction. -/
theorem primitiveFrontierKeysAccounted
    {artifact : WireAdmissionArtifact}
    (hFrontiers : artifact.SummaryFrontiersMatchPrimitive) :
    artifact.PrimitiveFrontierKeysAccounted where
  inputs hPrimitiveKey :=
    primitiveInputKey_accounted hFrontiers hPrimitiveKey
  outputs hPrimitiveKey :=
    primitiveOutputKey_accounted hFrontiers hPrimitiveKey

/-! ## Reconstruction Contract -/

/-- Primitive graph evidence reconstructed for one final replay frame.

This is the current artifact-boundary target, not the final
`GraphElaboration.CertifiedGraph` target. The latter additionally needs
accepted-node declarations and module binding expansion that are not serialized
in primitive artifact rows. -/
structure PrimitiveGraphReconstructionFrame
    (artifact : WireAdmissionArtifact)
    (finalFrame : PrimitiveTraceFrame) : Prop where
  replay :
    PrimitiveTraceReplays artifact.SelectInternalTraceExit
      artifact.primitiveSteps [] [finalFrame]
  matchesSummary : finalFrame.MatchesSummary artifact
  sourceVisibleRowsUnique : finalFrame.SourceVisibleRowsUnique
  frontierKeysAccounted : artifact.PrimitiveFrontierKeysAccounted
  rawConnectionsMatchPrimitive : artifact.RawConnectionsMatchPrimitive

/-- Primitive graph evidence reconstructed from a sound admission artifact. -/
def PrimitiveGraphReconstruction
    (artifact : WireAdmissionArtifact) : Prop :=
  ∃ finalFrame, PrimitiveGraphReconstructionFrame artifact finalFrame

/-- Primitive soundness reconstructs the artifact-level primitive graph witness. -/
theorem PrimitiveSound.toPrimitiveGraphReconstruction
    {artifact : WireAdmissionArtifact}
    (hPrimitive : artifact.PrimitiveSound) :
    artifact.PrimitiveGraphReconstruction := by
  obtain ⟨finalFrame, hReplay, hMatch⟩ :=
    hPrimitive.primitiveTraceStackValid
  exact
    ⟨ finalFrame
    , { replay := hReplay
        matchesSummary := hMatch
        sourceVisibleRowsUnique :=
          PrimitiveTraceFrame.sourceVisibleRowsUnique_of_matchesSummary
            hMatch hPrimitive.summaryKeysUnique
        frontierKeysAccounted :=
          primitiveFrontierKeysAccounted hPrimitive.summaryFrontiersMatchPrimitive
        rawConnectionsMatchPrimitive :=
          hPrimitive.rawConnectionsMatchPrimitive }
    ⟩

/-- Validator soundness reconstructs the artifact-level primitive graph witness. -/
theorem Sound.toPrimitiveGraphReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound) :
    artifact.PrimitiveGraphReconstruction :=
  hSound.primitive.toPrimitiveGraphReconstruction

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
