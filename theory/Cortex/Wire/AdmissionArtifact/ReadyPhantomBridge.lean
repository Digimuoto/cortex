import Cortex.Wire.AdmissionArtifact.ReadySelectBridge

/-!
## Overview

Validator-ready phantom bridge accessors backed by primitive replay.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes primitive backing for phantom adapter bridge frontiers. -/
theorem validatorReady_phantomBridgeFrontiersBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PhantomBridgeFrontiersBackedByPrimitive :=
  hReady.phantomBridgeFrontiersBackedByPrimitive

/-- Validator-ready gather artifacts expose primitive backing for the singular entry. -/
theorem validatorReady_phantomAdapter_gather_singularEntryBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather) :
    phantom.singular.key ∈
      PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps := by
  have hComponents := validatorReady_componentFrontiersBackedByPrimitive hReady
  have hPhantomBacked := hComponents.phantomAdapters phantom hPhantom
  rw [hDirection] at hPhantomBacked
  exact hPhantomBacked.left

/-- Validator-ready gather artifacts expose primitive backing for each multi-side exit. -/
theorem validatorReady_phantomAdapter_gather_multiExitBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather)
    {multi : AdmissionBoundaryPort}
    (hMulti : multi ∈ phantom.multi) :
    multi.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps := by
  have hComponents := validatorReady_componentFrontiersBackedByPrimitive hReady
  have hPhantomBacked := hComponents.phantomAdapters phantom hPhantom
  rw [hDirection] at hPhantomBacked
  exact hPhantomBacked.right multi hMulti

/-- Validator-ready scatter artifacts expose primitive backing for the singular exit. -/
theorem validatorReady_phantomAdapter_scatter_singularExitBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter) :
    phantom.singular.key ∈
      PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps := by
  have hComponents := validatorReady_componentFrontiersBackedByPrimitive hReady
  have hPhantomBacked := hComponents.phantomAdapters phantom hPhantom
  rw [hDirection] at hPhantomBacked
  exact hPhantomBacked.left

/-- Validator-ready scatter artifacts expose primitive backing for each multi-side entry. -/
theorem validatorReady_phantomAdapter_scatter_multiEntryBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter)
    {multi : AdmissionBoundaryPort}
    (hMulti : multi ∈ phantom.multi) :
    multi.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps := by
  have hComponents := validatorReady_componentFrontiersBackedByPrimitive hReady
  have hPhantomBacked := hComponents.phantomAdapters phantom hPhantom
  rw [hDirection] at hPhantomBacked
  exact hPhantomBacked.right multi hMulti

/-- Validator-ready phantom artifacts expose primitive backing for left-bulk phantom targets. -/
theorem validatorReady_phantomBridge_leftBulkTargetBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.toPort.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps :=
  (validatorReady_phantomBridgeFrontiersBackedByPrimitive
    hReady phantom hPhantom).left pair hPair

/-- Validator-ready phantom artifacts expose primitive backing for right-bulk phantom sources. -/
theorem validatorReady_phantomBridge_rightBulkSourceBacked
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.fromPort.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps :=
  (validatorReady_phantomBridgeFrontiersBackedByPrimitive
    hReady phantom hPhantom).right pair hPair

/-- Validator readiness exposes exact phantom bridge primitive frontier matching. -/
theorem validatorReady_phantomBridgeFrontiersMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PhantomBridgeFrontiersMatchPrimitive :=
  hReady.phantomBridgeFrontiersMatchPrimitive

/-- Validator readiness exposes replay backing for phantom-adapter bulk contraction rows. -/
theorem validatorReady_phantomBridgeBulkConnectionsReplayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PhantomBridgeBulkConnectionsReplayed :=
  hReady.phantomBridgeBulkConnectionsReplayed

/-- A validator-ready phantom adapter has a matching primitive phantom-node frontier row. -/
theorem validatorReady_phantomBridge_frontiersMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    ∃ entries exits,
      PrimitiveGraphStep.node phantom.node entries exits ∈ artifact.primitiveSteps ∧
        phantom.leftBulkTargetKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
        phantom.rightBulkSourceKeys.Perm (exits.map AdmissionBoundaryPort.key) :=
  validatorReady_phantomBridgeFrontiersMatchPrimitive hReady phantom hPhantom

/-- Validator-ready phantom adapters are backed by primitive node identity rows. -/
theorem validatorReady_phantomAdapter_node_mem_primitiveRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.node ∈ PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps := by
  obtain ⟨_entries, _exits, hNode, _hInputs, _hOutputs⟩ :=
    validatorReady_phantomBridge_frontiersMatchPrimitive hReady hPhantom
  exact PrimitiveGraphStep.nodeRowsList_mem_of_node_mem hNode

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
