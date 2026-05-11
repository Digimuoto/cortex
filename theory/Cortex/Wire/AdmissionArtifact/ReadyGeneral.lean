import Cortex.Wire.AdmissionArtifact.ValidatorCore

/-!
## Overview

Validator-ready core replay and component-ledger accessors.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes current-schema equality. -/
theorem validatorReady_schemaCurrent
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SchemaCurrent :=
  hReady.schemaCurrent

/-- Validator readiness exposes top-level summary-key uniqueness. -/
theorem validatorReady_summaryKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryKeysUnique :=
  hReady.summaryKeysUnique

/-- Validator readiness exposes top-level summary-row validity. -/
theorem validatorReady_summaryRowsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryRowsValid :=
  hReady.summaryRowsValid

/-- Validator readiness exposes top-level summary-domain closure. -/
theorem validatorReady_summaryDomainClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryDomainClosed :=
  hReady.summaryDomainClosed

/-- Validator readiness exposes raw connection summary coverage by primitive connect rows. -/
theorem validatorReady_rawConnectionsMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.RawConnectionsMatchPrimitive :=
  hReady.rawConnectionsMatchPrimitive

/-- Validator readiness exposes exact primitive backing for node and binding summaries. -/
theorem validatorReady_summaryIdentitiesMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryIdentitiesMatchPrimitive :=
  hReady.summaryIdentitiesMatchPrimitive

/-- Validator readiness exposes primitive backing for top-level entry/exit summaries. -/
theorem validatorReady_summaryFrontiersBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryFrontiersBackedByPrimitive :=
  hReady.summaryFrontiersBackedByPrimitive

/-- Validator readiness exposes exact primitive residual-frontier coverage. -/
theorem validatorReady_summaryFrontiersMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SummaryFrontiersMatchPrimitive :=
  hReady.summaryFrontiersMatchPrimitive

/-- Validator readiness exposes structured trace-row domain closure. -/
theorem validatorReady_componentDomainsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.ComponentDomainsClosed :=
  hReady.componentDomainsClosed

/-- Validator readiness exposes uniqueness for generated/phantom/select component rows. -/
theorem validatorReady_componentRowsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.ComponentRowsUnique :=
  hReady.componentRowsUnique

/-- Validator readiness exposes unique generated-family binding rows. -/
theorem validatorReady_generatedFormBindingsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.generatedForms.map GeneratedFormArtifact.binding).Nodup :=
  (validatorReady_componentRowsUnique hReady).generatedFormBindingsUnique

/-- Validator readiness exposes unique phantom-adapter node rows. -/
theorem validatorReady_phantomAdapterNodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.phantomAdapters.map PhantomAdapterArtifact.node).Nodup :=
  (validatorReady_componentRowsUnique hReady).phantomAdapterNodesUnique

/-- Validator readiness exposes unique select condition-node rows. -/
theorem validatorReady_selectConditionNodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.selects.map SelectAdmissionArtifact.conditionNode).Nodup :=
  (validatorReady_componentRowsUnique hReady).selectConditionNodesUnique

/-- Validator readiness exposes global component-role node uniqueness. -/
theorem validatorReady_componentRoleNodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.componentRoleNodes.Nodup :=
  (validatorReady_componentRowsUnique hReady).componentRoleNodesUnique

/-- Validator readiness exposes duplicate-free generated child component nodes. -/
theorem validatorReady_generatedUsedChildNodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.generatedUsedChildNodes.Nodup := by
  have hUnique := validatorReady_componentRoleNodesUnique hReady
  have hGeneratedPhantomUnique :
      (artifact.generatedUsedChildNodes ++
        artifact.phantomAdapters.map PhantomAdapterArtifact.node).Nodup := by
    simpa [componentRoleNodes] using List.Nodup.of_append_left hUnique
  exact List.Nodup.of_append_left hGeneratedPhantomUnique

/-- Validator readiness exposes disjoint generated-child and phantom-adapter node ledgers. -/
theorem validatorReady_generatedChildNodes_disjoint_phantomAdapterNodes
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.generatedUsedChildNodes.Disjoint
      (artifact.phantomAdapters.map PhantomAdapterArtifact.node) := by
  have hUnique := validatorReady_componentRoleNodesUnique hReady
  have hGeneratedPhantomUnique :
      (artifact.generatedUsedChildNodes ++
        artifact.phantomAdapters.map PhantomAdapterArtifact.node).Nodup := by
    simpa [componentRoleNodes] using List.Nodup.of_append_left hUnique
  exact List.Nodup.disjoint hGeneratedPhantomUnique

/-- Validator readiness exposes disjoint generated-child and select-condition node ledgers. -/
theorem validatorReady_generatedChildNodes_disjoint_selectConditionNodes
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.generatedUsedChildNodes.Disjoint
      (artifact.selects.map SelectAdmissionArtifact.conditionNode) := by
  have hUnique := validatorReady_componentRoleNodesUnique hReady
  have hDisjoint :
      (artifact.generatedUsedChildNodes ++
        artifact.phantomAdapters.map PhantomAdapterArtifact.node).Disjoint
        (artifact.selects.map SelectAdmissionArtifact.conditionNode) := by
    simpa [componentRoleNodes] using List.Nodup.disjoint hUnique
  intro node hGenerated hSelect
  exact hDisjoint (List.mem_append_left _ hGenerated) hSelect

/-- Validator readiness exposes disjoint phantom-adapter and select-condition node ledgers. -/
theorem validatorReady_phantomAdapterNodes_disjoint_selectConditionNodes
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.phantomAdapters.map PhantomAdapterArtifact.node).Disjoint
      (artifact.selects.map SelectAdmissionArtifact.conditionNode) := by
  have hUnique := validatorReady_componentRoleNodesUnique hReady
  have hDisjoint :
      (artifact.generatedUsedChildNodes ++
        artifact.phantomAdapters.map PhantomAdapterArtifact.node).Disjoint
        (artifact.selects.map SelectAdmissionArtifact.conditionNode) := by
    simpa [componentRoleNodes] using List.Nodup.disjoint hUnique
  intro node hPhantom hSelect
  exact hDisjoint (List.mem_append_right _ hPhantom) hSelect

/-- Validator readiness exposes the anchor condition for empty generated-family rows. -/
theorem validatorReady_generatedFormsReferenced
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.GeneratedFormsReferenced :=
  hReady.generatedFormsReferenced

/-- Validator-ready generated-form rows are anchored by used children or an empty binding ref. -/
theorem validatorReady_generatedForm_referenced
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms) :
    generated.usedChildren ≠ [] ∨
      (generated.sourceChildren = [] ∧ generated.binding ∈ artifact.bindingRefs) :=
  validatorReady_generatedFormsReferenced hReady generated hGenerated

/-- Empty validator-ready generated-form rows have no source children. -/
theorem validatorReady_emptyGeneratedForm_sourceChildren_empty
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hEmpty : generated.usedChildren = []) :
    generated.sourceChildren = [] := by
  cases validatorReady_generatedForm_referenced hReady hGenerated with
  | inl hUsed =>
      exact False.elim (hUsed hEmpty)
  | inr hAnchor =>
      exact hAnchor.left

/-- Empty validator-ready generated-form rows are anchored by a primitive binding ref. -/
theorem validatorReady_emptyGeneratedForm_bindingRef
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hEmpty : generated.usedChildren = []) :
    generated.binding ∈ artifact.bindingRefs := by
  cases validatorReady_generatedForm_referenced hReady hGenerated with
  | inl hUsed =>
      exact False.elim (hUsed hEmpty)
  | inr hAnchor =>
      exact hAnchor.right

/-- Validator readiness exposes primitive backing for component-local frontier rows. -/
theorem validatorReady_componentFrontiersBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.ComponentFrontiersBackedByPrimitive :=
  hReady.componentFrontiersBackedByPrimitive

/-- Validator readiness exposes exact generated-child primitive frontier matching. -/
theorem validatorReady_generatedChildFrontiersMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.GeneratedChildFrontiersMatchPrimitive :=
  hReady.generatedChildFrontiersMatchPrimitive

/-- Validator readiness exposes primitive graph-step stack replay validity. -/
theorem validatorReady_primitiveTraceStackValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PrimitiveTraceStackValid :=
  hReady.primitiveTraceStackValid

/-- Validator readiness exposes a primitive replay final frame matching the summary. -/
theorem validatorReady_primitiveTrace_replaysToSummary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ∃ finalFrame,
      PrimitiveTraceReplays artifact.SelectInternalTraceExit
        artifact.primitiveSteps [] [finalFrame] ∧
        finalFrame.MatchesSummary artifact :=
  validatorReady_primitiveTraceStackValid hReady

/-- A validator-ready generated child has a matching primitive node frontier row. -/
theorem validatorReady_generatedChild_frontiersMatchPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    ∃ entries exits,
      PrimitiveGraphStep.node child.node entries exits ∈ artifact.primitiveSteps ∧
        child.inputKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
        child.outputKeys.Perm (exits.map AdmissionBoundaryPort.key) :=
  validatorReady_generatedChildFrontiersMatchPrimitive
    hReady generated hGenerated child hChild

/-- Validator-ready generated children are backed by primitive node identity rows. -/
theorem validatorReady_generatedChild_node_mem_primitiveRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren) :
    child.node ∈ PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps := by
  obtain ⟨_entries, _exits, hNode, _hInputs, _hOutputs⟩ :=
    validatorReady_generatedChild_frontiersMatchPrimitive hReady hGenerated hChild
  exact PrimitiveGraphStep.nodeRowsList_mem_of_node_mem hNode

/-- Validator readiness exposes primitive overlay prefix-availability. -/
theorem validatorReady_primitiveOverlayLedgersPrefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PrimitiveOverlayLedgersPrefixAvailable :=
  hReady.primitiveOverlayLedgersPrefixAvailable

/-- Validator-ready primitive overlay rows draw node and binding ledgers from their trace prefix. -/
theorem validatorReady_primitiveOverlay_prefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {tracePrefix suffix : List PrimitiveGraphStep}
    {leftNodes rightNodes : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hTrace :
      artifact.primitiveSteps =
        tracePrefix ++
          [PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings] ++
          suffix) :
    (∀ node, node ∈ leftNodes ++ rightNodes →
      node ∈ PrimitiveGraphStep.nodeRowsList tracePrefix) ∧
    (∀ binding, binding ∈ leftBindings ++ rightBindings →
      binding ∈ PrimitiveGraphStep.bindingRowsList tracePrefix) :=
  validatorReady_primitiveOverlayLedgersPrefixAvailable
    hReady tracePrefix suffix leftNodes rightNodes leftBindings rightBindings hTrace

/-- Validator-ready primitive overlay rows have a replay prefix that already contains their
ledgers. -/
theorem validatorReady_primitiveOverlay_mem_prefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftNodes rightNodes : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hPrimitiveStep :
      PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings ∈
        artifact.primitiveSteps) :
    ∃ tracePrefix suffix,
      artifact.primitiveSteps =
        tracePrefix ++
          [PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings] ++
          suffix ∧
        (∀ node, node ∈ leftNodes ++ rightNodes →
          node ∈ PrimitiveGraphStep.nodeRowsList tracePrefix) ∧
        (∀ binding, binding ∈ leftBindings ++ rightBindings →
          binding ∈ PrimitiveGraphStep.bindingRowsList tracePrefix) := by
  obtain ⟨tracePrefix, suffix, hTrace⟩ :=
    exists_append_singleton_of_mem hPrimitiveStep
  refine ⟨tracePrefix, suffix, hTrace, ?_⟩
  exact validatorReady_primitiveOverlay_prefixAvailable hReady hTrace

/-- Validator readiness exposes primitive backing for primitive connect frontier rows. -/
theorem validatorReady_primitiveConnectFrontiersBackedByNodes
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PrimitiveConnectFrontiersBackedByNodes :=
  hReady.primitiveConnectFrontiersBackedByNodes

/-- Validator readiness exposes primitive connect prefix-availability. -/
theorem validatorReady_primitiveConnectFrontiersPrefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PrimitiveConnectFrontiersPrefixAvailable :=
  hReady.primitiveConnectFrontiersPrefixAvailable

/-- Validator-ready primitive connect rows draw frontiers from their trace prefix. -/
theorem validatorReady_primitiveConnect_prefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {tracePrefix suffix : List PrimitiveGraphStep}
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hTrace :
      artifact.primitiveSteps =
        tracePrefix ++
          [PrimitiveGraphStep.connect
            leftExits rightEntries matchedPairs unmatchedLeftExits
            unmatchedRightEntries] ++
          suffix) :
    (∀ leftExit, leftExit ∈ leftExits →
      leftExit.key ∈ PrimitiveGraphStep.nodeExitKeysList tracePrefix ∧
        leftExit.key ∉ PrimitiveGraphStep.consumedExitKeysList tracePrefix) ∧
    (∀ rightEntry, rightEntry ∈ rightEntries →
      rightEntry.key ∈ PrimitiveGraphStep.nodeEntryKeysList tracePrefix ∧
        rightEntry.key ∉ PrimitiveGraphStep.consumedEntryKeysList tracePrefix) :=
  validatorReady_primitiveConnectFrontiersPrefixAvailable
    hReady tracePrefix suffix leftExits rightEntries matchedPairs
      unmatchedLeftExits unmatchedRightEntries hTrace

/-- Validator-ready primitive connect rows have a replay prefix where their frontiers are live. -/
theorem validatorReady_primitiveConnect_mem_prefixAvailable
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hPrimitiveStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        artifact.primitiveSteps) :
    ∃ tracePrefix suffix,
      artifact.primitiveSteps =
        tracePrefix ++
          [PrimitiveGraphStep.connect
            leftExits rightEntries matchedPairs unmatchedLeftExits
            unmatchedRightEntries] ++
          suffix ∧
        (∀ leftExit, leftExit ∈ leftExits →
          leftExit.key ∈ PrimitiveGraphStep.nodeExitKeysList tracePrefix ∧
            leftExit.key ∉ PrimitiveGraphStep.consumedExitKeysList tracePrefix) ∧
        (∀ rightEntry, rightEntry ∈ rightEntries →
          rightEntry.key ∈ PrimitiveGraphStep.nodeEntryKeysList tracePrefix ∧
            rightEntry.key ∉ PrimitiveGraphStep.consumedEntryKeysList tracePrefix) := by
  obtain ⟨tracePrefix, suffix, hTrace⟩ :=
    exists_append_singleton_of_mem hPrimitiveStep
  refine ⟨tracePrefix, suffix, hTrace, ?_⟩
  exact validatorReady_primitiveConnect_prefixAvailable hReady hTrace

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
