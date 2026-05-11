import Cortex.Wire.AdmissionArtifact.ReadySummary

/-!
## Overview

Validator-ready component row and primitive-connect accessors.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes generated-form row validity. -/
theorem validatorReady_generatedForm_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.Valid :=
  hReady.generatedFormsValid generated hGenerated

/-- Validator readiness exposes generated-form used-child domain closure. -/
theorem validatorReady_generatedForm_domainClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    GeneratedFormArtifact.DomainClosed artifact.nodes generated :=
  hReady.componentDomainsClosed.generatedFormsClosed generated hGenerated

/-- Validator-ready used generated child nodes belong to the top-level node summary. -/
theorem validatorReady_generated_childNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node ∈ artifact.nodes :=
  (validatorReady_generatedForm_domainClosed hReady hGenerated child hChild).nodeClosed

/-- Validator-ready used generated child nodes appear in the generated-role ledger. -/
theorem validatorReady_generated_childNode_mem_generatedUsedChildNodes
    {artifact : WireAdmissionArtifact}
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node ∈ artifact.generatedUsedChildNodes := by
  simp [generatedUsedChildNodes]
  exact ⟨generated, hGenerated, child, hChild, rfl⟩

/-- Validator-ready used generated child nodes appear in the component-role ledger. -/
theorem validatorReady_generated_childNode_mem_componentRoleNodes
    {artifact : WireAdmissionArtifact}
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node ∈ artifact.componentRoleNodes := by
  simp [componentRoleNodes, generatedUsedChildNodes]
  exact Or.inl ⟨generated, hGenerated, child, hChild, rfl⟩

/-- Validator readiness exposes primitive graph-step row validity. -/
theorem validatorReady_primitiveStep_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {primitiveStep : PrimitiveGraphStep}
    (hPrimitiveStep : primitiveStep ∈ artifact.primitiveSteps) :
    primitiveStep.Valid :=
  hReady.primitiveStepsValid primitiveStep hPrimitiveStep

/-- Validator readiness exposes primitive graph-step domain closure. -/
theorem validatorReady_primitiveStep_domainClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {primitiveStep : PrimitiveGraphStep}
    (hPrimitiveStep : primitiveStep ∈ artifact.primitiveSteps) :
    PrimitiveGraphStep.DomainClosed artifact.nodes artifact.bindingRefs primitiveStep :=
  hReady.componentDomainsClosed.primitiveStepsClosed primitiveStep hPrimitiveStep

/-- Validator-ready primitive connect rows expose frontier membership for each matched pair. -/
theorem validatorReady_primitiveConnect_pair_mem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {pair : AdmissionConnection}
    (hPair : pair ∈ matchedPairs) :
    pair.fromPort ∈ leftExits ∧ pair.toPort ∈ rightEntries :=
  PrimitiveGraphStep.valid_connect_pair_mem
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)
    hPair

/-- Validator-ready primitive connect rows expose left-frontier membership for unmatched exits. -/
theorem validatorReady_primitiveConnect_unmatchedLeft_mem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ unmatchedLeftExits) :
    boundary ∈ leftExits :=
  (validatorReady_primitiveStep_valid
    hReady hPrimitiveStep).unmatchedLeftDrawnFromFrontier boundary hBoundary

/-- Validator-ready primitive connect rows expose right-frontier membership for
unmatched entries. -/
theorem validatorReady_primitiveConnect_unmatchedRight_mem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ unmatchedRightEntries) :
    boundary ∈ rightEntries :=
  (validatorReady_primitiveStep_valid
    hReady hPrimitiveStep).unmatchedRightDrawnFromFrontier boundary hBoundary

/-- Validator-ready primitive connect rows do not reuse matched endpoints. -/
theorem validatorReady_primitiveConnect_pairsLinear
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    PrimitiveGraphStep.ConnectPairsLinear matchedPairs :=
  PrimitiveGraphStep.valid_connect_pairsLinear
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)

/-- Validator-ready primitive connect rows do not reuse matched output endpoint keys. -/
theorem validatorReady_primitiveConnect_matchedFromKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    (matchedPairs.map AdmissionConnection.fromKey).Nodup :=
  (validatorReady_primitiveConnect_pairsLinear hReady hPrimitiveStep).left

/-- Validator-ready primitive connect rows do not reuse matched input endpoint keys. -/
theorem validatorReady_primitiveConnect_matchedToKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    (matchedPairs.map AdmissionConnection.toKey).Nodup :=
  (validatorReady_primitiveConnect_pairsLinear hReady hPrimitiveStep).right

/-- Validator-ready primitive connect rows expose duplicate-free serialized frontiers. -/
theorem validatorReady_primitiveConnect_frontiersLinear
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    PrimitiveGraphStep.ConnectFrontiersLinear leftExits rightEntries :=
  PrimitiveGraphStep.valid_connect_frontiersLinear
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)

/-- Validator-ready primitive connect rows expose duplicate-free left exit frontiers. -/
theorem validatorReady_primitiveConnect_leftExitKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    (leftExits.map AdmissionBoundaryPort.key).Nodup :=
  (validatorReady_primitiveConnect_frontiersLinear hReady hPrimitiveStep).left

/-- Validator-ready primitive connect rows expose duplicate-free right entry frontiers. -/
theorem validatorReady_primitiveConnect_rightEntryKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    (rightEntries.map AdmissionBoundaryPort.key).Nodup :=
  (validatorReady_primitiveConnect_frontiersLinear hReady hPrimitiveStep).right

/-- Validator-ready primitive connect rows match every compatible left/right frontier pair. -/
theorem validatorReady_primitiveConnect_matchesAllCompatible
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    PrimitiveGraphStep.ConnectMatchesAllCompatible leftExits rightEntries matchedPairs :=
  PrimitiveGraphStep.valid_connect_matchesAllCompatible
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)

/-- Validator-ready primitive connect rows expose exact matched/unmatched frontier partitioning. -/
theorem validatorReady_primitiveConnect_frontierPartition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    PrimitiveGraphStep.ConnectFrontierPartition
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries :=
  PrimitiveGraphStep.valid_connect_frontierPartition
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)

/-- Validator-ready primitive connect rows exactly partition left exit frontier keys. -/
theorem validatorReady_primitiveConnect_leftFrontierPartition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    ((matchedPairs.map AdmissionConnection.fromKey) ++
        (unmatchedLeftExits.map AdmissionBoundaryPort.key)).Perm
      (leftExits.map AdmissionBoundaryPort.key) :=
  (validatorReady_primitiveConnect_frontierPartition hReady hPrimitiveStep).left

/-- Validator-ready primitive connect rows exactly partition right entry frontier keys. -/
theorem validatorReady_primitiveConnect_rightFrontierPartition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    ((matchedPairs.map AdmissionConnection.toKey) ++
        (unmatchedRightEntries.map AdmissionBoundaryPort.key)).Perm
      (rightEntries.map AdmissionBoundaryPort.key) :=
  (validatorReady_primitiveConnect_frontierPartition hReady hPrimitiveStep).right

/-- Validator-ready primitive connect rows expose structural endpoint validity. -/
theorem validatorReady_primitiveConnect_rowsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    PrimitiveGraphStep.ConnectRowsValid
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries :=
  PrimitiveGraphStep.valid_connect_rowsValid
    (validatorReady_primitiveStep_valid hReady hPrimitiveStep)

/-- Validator-ready primitive connect rows expose compatibility for each matched boundary pair. -/
theorem validatorReady_primitiveConnect_pairBoundaryCompatible
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {pair : AdmissionConnection}
    (hPair : pair ∈ matchedPairs) :
    pair.BoundaryCompatible :=
  let hRows := validatorReady_primitiveConnect_rowsValid hReady hPrimitiveStep
  connectionsValid_boundaryCompatible hRows.right.right.left hPair

/-- Validator-ready primitive connect rows replay every compatible frontier pair exactly. -/
theorem validatorReady_primitiveConnect_compatiblePair_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {leftExit rightEntry : AdmissionBoundaryPort}
    (hLeftExit : leftExit ∈ leftExits)
    (hRightEntry : rightEntry ∈ rightEntries)
    (hCompatible : leftExit.CompatibleWith rightEntry) :
    ∃ pair, pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
      pair.fromPort = leftExit ∧ pair.toPort = rightEntry := by
  have hAllCompatible :=
    validatorReady_primitiveConnect_matchesAllCompatible hReady hPrimitiveStep
  obtain ⟨pair, hPair, hFrom, hTo⟩ :=
    hAllCompatible leftExit hLeftExit rightEntry hRightEntry hCompatible
  exact
    ⟨ pair
    , PrimitiveGraphStep.matchedConnectionsList_mem_of_connect_mem hPrimitiveStep hPair
    , hFrom
    , hTo
    ⟩

/-- Validator-ready primitive connect rows consume every compatible frontier pair. -/
theorem validatorReady_primitiveConnect_compatiblePair_consumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps)
    {leftExit rightEntry : AdmissionBoundaryPort}
    (hLeftExit : leftExit ∈ leftExits)
    (hRightEntry : rightEntry ∈ rightEntries)
    (hCompatible : leftExit.CompatibleWith rightEntry) :
    leftExit.key ∈ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps ∧
      rightEntry.key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps := by
  obtain ⟨pair, hMatched, hFrom, hTo⟩ :=
    validatorReady_primitiveConnect_compatiblePair_replayed
      hReady hPrimitiveStep hLeftExit hRightEntry hCompatible
  constructor
  · simpa [AdmissionConnection.fromKey, hFrom] using
      PrimitiveGraphStep.matchedConnectionsList_fromKey_mem_consumedExitKeysList
        hMatched
  · simpa [AdmissionConnection.toKey, hTo] using
      PrimitiveGraphStep.matchedConnectionsList_toKey_mem_consumedEntryKeysList
        hMatched

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
