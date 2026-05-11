import Cortex.Wire.AdmissionArtifact.ReadyGenerated
import Cortex.Wire.AdmissionArtifact.ReadyPhantom
import Cortex.Wire.AdmissionArtifact.ReadySelect
import Cortex.Wire.AdmissionArtifact.ReadySelectBridge
import Cortex.Wire.AdmissionArtifact.ReadySummary

/-!
## Overview

Proof-facing soundness cutline for decoded Wire admission artifacts.

`ValidatorReady` is intentionally shaped like a checker contract: one field per
JSON-level predicate that the Haskell-side artifact validator can decide.
`Sound` is the theorem-facing contract: it groups those checker facts by the
Wire obligations they support and exposes only consequences that downstream
correspondence proofs should be allowed to cite.

This module is the boundary for the current PR. It does not prove that the
Haskell compiler constructs artifacts for every accepted Wire program. It proves
the narrower, explicit cutline: once an artifact satisfies `ValidatorReady`, the
primitive replay, generated-form, select, and phantom-adapter evidence needed by
the Lean replay layer is available under one named proposition.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Primitive replay soundness available from a validator-ready artifact.

The fields tie the top-level node/frontier/edge summary to primitive replay
rows and expose the only full-frontier matching fact downstream proofs should
use: every compatible pair listed by a primitive `connect` row is replayed and
consumed by the primitive trace stack.
-/
structure PrimitiveSound (artifact : WireAdmissionArtifact) : Prop where
  primitiveTraceStackValid : artifact.PrimitiveTraceStackValid
  primitiveStepsValid : artifact.PrimitiveStepsValid
  summaryKeysUnique : artifact.SummaryKeysUnique
  summaryRowsValid : artifact.SummaryRowsValid
  summaryDomainClosed : artifact.SummaryDomainClosed
  summaryIdentitiesMatchPrimitive : artifact.SummaryIdentitiesMatchPrimitive
  summaryFrontiersBackedByPrimitive : artifact.SummaryFrontiersBackedByPrimitive
  summaryFrontiersMatchPrimitive : artifact.SummaryFrontiersMatchPrimitive
  rawConnectionsMatchPrimitive : artifact.RawConnectionsMatchPrimitive
  componentDomainsClosed : artifact.ComponentDomainsClosed
  componentRowsUnique : artifact.ComponentRowsUnique
  componentFrontiersBackedByPrimitive : artifact.ComponentFrontiersBackedByPrimitive
  overlayLedgersPrefixAvailable : artifact.PrimitiveOverlayLedgersPrefixAvailable
  connectFrontiersBackedByNodes : artifact.PrimitiveConnectFrontiersBackedByNodes
  connectFrontiersPrefixAvailable : artifact.PrimitiveConnectFrontiersPrefixAvailable
  summaryConnectionReplayed :
    ∀ {connection : AdmissionRawConnection},
      connection ∈ artifact.connections →
        ∃ pair, pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
          AdmissionRawConnection.ofAdmissionConnection pair = connection
  matchedConnectionInSummary :
    ∀ {pair : AdmissionConnection},
      pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps →
        AdmissionRawConnection.ofAdmissionConnection pair ∈ artifact.connections
  compatiblePairReplayed :
    ∀ {leftExits rightEntries : List AdmissionBoundaryPort}
      {matchedPairs : List AdmissionConnection}
      {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort},
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
          artifact.primitiveSteps →
        ∀ {leftExit rightEntry : AdmissionBoundaryPort},
          leftExit ∈ leftExits →
            rightEntry ∈ rightEntries →
              leftExit.CompatibleWith rightEntry →
                ∃ pair,
                  pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
                    pair.fromPort = leftExit ∧ pair.toPort = rightEntry
  compatiblePairConsumed :
    ∀ {leftExits rightEntries : List AdmissionBoundaryPort}
      {matchedPairs : List AdmissionConnection}
      {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort},
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
          artifact.primitiveSteps →
        ∀ {leftExit rightEntry : AdmissionBoundaryPort},
          leftExit ∈ leftExits →
            rightEntry ∈ rightEntries →
              leftExit.CompatibleWith rightEntry →
                leftExit.key ∈
                    PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps ∧
                  rightEntry.key ∈
                    PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps

/-- Generated-form soundness available from a validator-ready artifact.

The contract keeps generated families tied to primitive node rows and to their
source `make`/`makeEach` item rows. This is the handoff needed before proving
that executable kind substitution builds the same Lean witnesses.
-/
structure GeneratedSound (artifact : WireAdmissionArtifact) : Prop where
  generatedFormsValid : artifact.GeneratedFormsValid
  generatedFormsReferenced : artifact.GeneratedFormsReferenced
  generatedChildFrontiersMatchPrimitive :
    artifact.GeneratedChildFrontiersMatchPrimitive
  sourceMakeItemsAcceptItems :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        LinearPortGraph.MakeEach.acceptItems generated.binding
          generated.sourceMakeItems =
            Except.ok generated.sourceMakeItems
  usedChildSourceMakeItem :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        ∀ {child : GeneratedChildArtifact},
          child ∈ generated.usedChildren →
            ∃ item, item ∈ generated.sourceMakeItems ∧
              item.label = child.label ∧
                ∃ source, source ∈ generated.sourceChildren ∧
                  source.node = child.node ∧
                    source.label = child.label ∧
                      item = source.toMakeItem
  usedChildUniqueSourceMakeItem :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        ∀ {child : GeneratedChildArtifact},
          child ∈ generated.usedChildren →
            ∃ item, item ∈ generated.sourceMakeItems ∧
              item.label = child.label ∧
                ∀ other, other ∈ generated.sourceMakeItems →
                  other.label = child.label → other = item
  makeUsedChildSourceValueEmpty :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        generated.kind = GeneratedFormKind.make →
          ∀ {child : GeneratedChildArtifact},
            child ∈ generated.usedChildren →
              ∃ item, item ∈ generated.sourceMakeItems ∧
                item.label = child.label ∧ item.value = none
  makeSourceLabelsCanonical :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        generated.kind = GeneratedFormKind.make →
          generated.sourceMakeItems.map LinearPortGraph.MakeItem.label =
            (List.range generated.sourceChildren.length).map (fun index =>
              ⟨toString index⟩)
  makeSourceValuesEmpty :
    ∀ {generated : GeneratedFormArtifact},
      generated ∈ artifact.generatedForms →
        generated.kind = GeneratedFormKind.make →
          ∀ {item : LinearPortGraph.MakeItem},
            item ∈ generated.sourceMakeItems → item.value = none

/-- Select-admission soundness available from a validator-ready artifact.

Select rows are tied to primitive bridge frontiers, source arm rows, and latent
body freshness/disjointness. This is deliberately still source-side: lower
planner evidence for each latent body remains a caller-provided obligation.
-/
structure SelectSound (artifact : WireAdmissionArtifact) : Prop where
  selectsValid : artifact.SelectsValid
  selectBridgeFrontiersBackedByPrimitive :
    artifact.SelectBridgeFrontiersBackedByPrimitive
  selectBridgeEntriesConsumed : artifact.SelectBridgeEntriesConsumed
  selectArmBodyBoundariesMatchCondition :
    artifact.SelectArmBodyBoundariesMatchCondition
  selectArmBodyNodesFreshFromSummary :
    artifact.SelectArmBodyNodesFreshFromSummary
  selectArmBodyNodesPairwiseDisjoint :
    artifact.SelectArmBodyNodesPairwiseDisjoint
  armsAtLeastTwo :
    ∀ {selectAdmission : SelectAdmissionArtifact},
      selectAdmission ∈ artifact.selects → 2 ≤ selectAdmission.arms.length
  variantBridgeEntryConsumed :
    ∀ {selectAdmission : SelectAdmissionArtifact},
      selectAdmission ∈ artifact.selects →
        ∀ {variant : SelectVariantArtifact},
          variant ∈ selectAdmission.variants →
            ∃ entries exits entry,
              PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
                artifact.primitiveSteps ∧
                entry ∈ entries ∧
                  variant.port.CompatibleWith entry ∧
                    { fromPort := variant.port, toPort := entry } ∈
                      PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
                      entry.key ∈
                        PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps
  latentEntrySourceArm :
    ∀ {selectAdmission : SelectAdmissionArtifact}
      (_hSelect : selectAdmission ∈ artifact.selects)
      (hValid : selectAdmission.Valid)
      {entry : SelectArmKey × SelectArmAdmissionArtifact},
      entry ∈ (selectAdmission.toLatentSelectAdmission hValid).entries →
        ∃ arm, arm ∈ selectAdmission.arms ∧
          entry = (arm.canonicalSelectArmKey, arm)
  latentEntryBodyNodeFresh :
    ∀ {selectAdmission : SelectAdmissionArtifact}
      (_hSelect : selectAdmission ∈ artifact.selects)
      (hValid : selectAdmission.Valid)
      {entry : SelectArmKey × SelectArmAdmissionArtifact},
      entry ∈ (selectAdmission.toLatentSelectAdmission hValid).entries →
        ∀ {node : NodeId},
          node ∈ entry.snd.bodyNodes → node ∉ artifact.nodes
  latentEntriesBodyNodesDisjoint :
    ∀ {selectAdmission : SelectAdmissionArtifact}
      (_hSelect : selectAdmission ∈ artifact.selects)
      (hValid : selectAdmission.Valid)
      {leftEntry rightEntry : SelectArmKey × SelectArmAdmissionArtifact},
      leftEntry ∈ (selectAdmission.toLatentSelectAdmission hValid).entries →
        rightEntry ∈ (selectAdmission.toLatentSelectAdmission hValid).entries →
          leftEntry.fst ≠ rightEntry.fst →
            ∀ {node : NodeId},
              node ∈ leftEntry.snd.bodyNodes → node ∉ rightEntry.snd.bodyNodes

/-- Phantom-adapter soundness available from a validator-ready artifact.

The contract covers the adapter row itself, primitive backing for the adapter
node/frontiers, bulk replay, and the product-shape facts needed for bounded
indexed and record product adapters.
-/
structure PhantomSound (artifact : WireAdmissionArtifact) : Prop where
  phantomAdaptersValid : artifact.PhantomAdaptersValid
  phantomBridgeFrontiersBackedByPrimitive :
    artifact.PhantomBridgeFrontiersBackedByPrimitive
  phantomBridgeFrontiersMatchPrimitive : artifact.PhantomBridgeFrontiersMatchPrimitive
  phantomBridgeBulkConnectionsReplayed :
    artifact.PhantomBridgeBulkConnectionsReplayed
  indexedMultiLengthEq :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {element : ContractId} {count : Nat},
          phantom.productShape = ProductShapeArtifact.indexed element count →
            phantom.multi.length = count
  indexedMultiContractEq :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {element : ContractId} {count : Nat},
          phantom.productShape = ProductShapeArtifact.indexed element count →
            ∀ {boundary : AdmissionBoundaryPort},
              boundary ∈ phantom.multi → boundary.contract = element
  indexedElementValid :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {element : ContractId} {count : Nat},
          phantom.productShape = ProductShapeArtifact.indexed element count →
            element.Valid
  indexedElementNominal :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {element : ContractId} {count : Nat},
          phantom.productShape = ProductShapeArtifact.indexed element count →
            element.name.startsWith "[" = false
  indexedSingularContractEq :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {element : ContractId} {count : Nat},
          phantom.productShape = ProductShapeArtifact.indexed element count →
            phantom.singular.contract = ContractId.boundedIndexed element count
  gatherMultiEndpointReplayed :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        phantom.direction = PhantomAdapterDirection.gather →
          ∀ {boundary : AdmissionBoundaryPort},
            boundary ∈ phantom.multi →
              ∃ pair, pair ∈ phantom.leftBulk ∧
                pair.fromKey = boundary.key ∧
                  pair ∈ PrimitiveGraphStep.matchedConnectionsList
                    artifact.primitiveSteps
  scatterMultiEndpointReplayed :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        phantom.direction = PhantomAdapterDirection.scatter →
          ∀ {boundary : AdmissionBoundaryPort},
            boundary ∈ phantom.multi →
              ∃ pair, pair ∈ phantom.rightBulk ∧
                pair.toKey = boundary.key ∧
                  pair ∈ PrimitiveGraphStep.matchedConnectionsList
                    artifact.primitiveSteps
  recordFieldsUnique :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {contract : ContractId} {fields : List (FieldLabel × ContractId)},
          phantom.productShape = ProductShapeArtifact.record contract fields →
            (fields.map Prod.fst).Nodup
  recordMultiFieldsPerm :
    ∀ {phantom : PhantomAdapterArtifact},
      phantom ∈ artifact.phantomAdapters →
        ∀ {contract : ContractId} {fields : List (FieldLabel × ContractId)},
          phantom.productShape = ProductShapeArtifact.record contract fields →
            (phantom.multi.filterMap AdmissionBoundaryPort.recordField).Perm fields

/-- Proof-facing contract for a decoded Wire admission artifact.

This is the current correspondence target. A Haskell-emitted artifact is useful
to Lean exactly when the executable validator establishes `ValidatorReady`; this
theorem-level record then exposes the primitive, generated, select, and phantom
facts needed for replay without citing checker implementation details.
-/
structure Sound (artifact : WireAdmissionArtifact) : Prop where
  schemaCurrent : artifact.SchemaCurrent
  primitive : artifact.PrimitiveSound
  generated : artifact.GeneratedSound
  select : artifact.SelectSound
  phantom : artifact.PhantomSound

/-- Validator readiness supplies the primitive replay soundness contract. -/
theorem validatorReady_primitiveSound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PrimitiveSound where
  primitiveTraceStackValid := hReady.primitiveTraceStackValid
  primitiveStepsValid := hReady.primitiveStepsValid
  summaryKeysUnique := hReady.summaryKeysUnique
  summaryRowsValid := hReady.summaryRowsValid
  summaryDomainClosed := hReady.summaryDomainClosed
  summaryIdentitiesMatchPrimitive := hReady.summaryIdentitiesMatchPrimitive
  summaryFrontiersBackedByPrimitive := hReady.summaryFrontiersBackedByPrimitive
  summaryFrontiersMatchPrimitive := hReady.summaryFrontiersMatchPrimitive
  rawConnectionsMatchPrimitive := hReady.rawConnectionsMatchPrimitive
  componentDomainsClosed := hReady.componentDomainsClosed
  componentRowsUnique := hReady.componentRowsUnique
  componentFrontiersBackedByPrimitive := hReady.componentFrontiersBackedByPrimitive
  overlayLedgersPrefixAvailable := hReady.primitiveOverlayLedgersPrefixAvailable
  connectFrontiersBackedByNodes := hReady.primitiveConnectFrontiersBackedByNodes
  connectFrontiersPrefixAvailable := hReady.primitiveConnectFrontiersPrefixAvailable
  summaryConnectionReplayed := fun hConnection =>
    validatorReady_summary_connection_replayedByPrimitiveMatch hReady hConnection
  matchedConnectionInSummary := fun hPair =>
    validatorReady_primitiveMatchedConnection_in_summary hReady hPair
  compatiblePairReplayed :=
    fun {_leftExits} {_rightEntries} {_matchedPairs}
      {_unmatchedLeftExits} {_unmatchedRightEntries}
      hStep {_leftExit} {_rightEntry} hLeft hRight hCompatible =>
    validatorReady_primitiveConnect_compatiblePair_replayed
      hReady hStep hLeft hRight hCompatible
  compatiblePairConsumed :=
    fun {_leftExits} {_rightEntries} {_matchedPairs}
      {_unmatchedLeftExits} {_unmatchedRightEntries}
      hStep {_leftExit} {_rightEntry} hLeft hRight hCompatible =>
    validatorReady_primitiveConnect_compatiblePair_consumed
      hReady hStep hLeft hRight hCompatible

/-- Validator readiness supplies the generated-form soundness contract. -/
theorem validatorReady_generatedSound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.GeneratedSound where
  generatedFormsValid := hReady.generatedFormsValid
  generatedFormsReferenced := hReady.generatedFormsReferenced
  generatedChildFrontiersMatchPrimitive :=
    hReady.generatedChildFrontiersMatchPrimitive
  sourceMakeItemsAcceptItems := fun {_generated} hGenerated =>
    validatorReady_generated_sourceMakeItems_acceptItems_ok hReady hGenerated
  usedChildSourceMakeItem := fun {_generated} hGenerated {_child} hChild =>
    validatorReady_generated_usedChild_sourceMakeItem hReady hGenerated hChild
  usedChildUniqueSourceMakeItem := fun {_generated} hGenerated {_child} hChild =>
    validatorReady_generated_usedChild_uniqueSourceMakeItem hReady hGenerated hChild
  makeUsedChildSourceValueEmpty :=
    fun {_generated} hGenerated hKind {_child} hChild =>
    validatorReady_generated_make_usedChild_sourceMakeItem_value_empty
      hReady hGenerated hKind hChild
  makeSourceLabelsCanonical := fun {_generated} hGenerated hKind =>
    validatorReady_generated_make_sourceMakeItems_labelsCanonical
      hReady hGenerated hKind
  makeSourceValuesEmpty := fun {_generated} hGenerated hKind {_item} hItem =>
    validatorReady_generated_make_sourceMakeItems_valuesEmpty hReady hGenerated hKind hItem

/-- Validator readiness supplies the select-admission soundness contract. -/
theorem validatorReady_selectSound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.SelectSound where
  selectsValid := hReady.selectsValid
  selectBridgeFrontiersBackedByPrimitive :=
    hReady.selectBridgeFrontiersBackedByPrimitive
  selectBridgeEntriesConsumed := hReady.selectBridgeEntriesConsumed
  selectArmBodyBoundariesMatchCondition :=
    hReady.selectArmBodyBoundariesMatchCondition
  selectArmBodyNodesFreshFromSummary := hReady.selectArmBodyNodesFreshFromSummary
  selectArmBodyNodesPairwiseDisjoint := hReady.selectArmBodyNodesPairwiseDisjoint
  armsAtLeastTwo := fun {_selectAdmission} hSelect =>
    validatorReady_select_armsAtLeastTwo hReady hSelect
  variantBridgeEntryConsumed :=
    fun {_selectAdmission} hSelect {_variant} hVariant =>
    validatorReady_select_variant_bridgeEntryConsumed hReady hSelect hVariant
  latentEntrySourceArm := fun {_selectAdmission} _hSelect _hValid {_entry} hEntry =>
    SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm hEntry
  latentEntryBodyNodeFresh :=
    fun {_selectAdmission} hSelect _hValid {_entry} hEntry {_node} hNode =>
    by
      obtain ⟨arm, hArm, hEq⟩ :=
        SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm hEntry
      cases hEq
      exact validatorReady_select_armBodyNodeFresh hReady hSelect hArm hNode
  latentEntriesBodyNodesDisjoint :=
    fun {_selectAdmission} hSelect _hValid {_leftEntry} {_rightEntry}
      hLeft hRight hKeys {_node} hNode =>
    by
      obtain ⟨leftArm, hLeftArm, hLeftEq⟩ :=
        SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm hLeft
      obtain ⟨rightArm, hRightArm, hRightEq⟩ :=
        SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm hRight
      cases hLeftEq
      cases hRightEq
      have hCanonicalKeys : leftArm.canonicalKey ≠ rightArm.canonicalKey := by
        intro hCanonicalEq
        apply hKeys
        unfold SelectArmAdmissionArtifact.canonicalSelectArmKey
          selectArmKeyOfFieldLabel
        rw [hCanonicalEq]
      exact
        validatorReady_select_armBodyNodesDisjoint
          hReady hSelect hLeftArm hRightArm hCanonicalKeys hNode

/-- Validator readiness supplies the phantom-adapter soundness contract. -/
theorem validatorReady_phantomSound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.PhantomSound where
  phantomAdaptersValid := hReady.phantomAdaptersValid
  phantomBridgeFrontiersBackedByPrimitive :=
    hReady.phantomBridgeFrontiersBackedByPrimitive
  phantomBridgeFrontiersMatchPrimitive := hReady.phantomBridgeFrontiersMatchPrimitive
  phantomBridgeBulkConnectionsReplayed :=
    hReady.phantomBridgeBulkConnectionsReplayed
  indexedMultiLengthEq := fun {_phantom} hPhantom {_element} {_count} hShape =>
    validatorReady_phantomAdapter_indexed_multi_length_eq hReady hPhantom hShape
  indexedMultiContractEq :=
    fun {_phantom} hPhantom {_element} {_count} hShape {_boundary} hBoundary =>
    validatorReady_phantomAdapter_indexed_multi_contract_eq
      hReady hPhantom hShape hBoundary
  indexedElementValid := fun {_phantom} hPhantom {_element} {_count} hShape =>
    validatorReady_phantomAdapter_indexed_elementValid hReady hPhantom hShape
  indexedElementNominal := fun {_phantom} hPhantom {_element} {_count} hShape =>
    validatorReady_phantomAdapter_indexed_elementNominal hReady hPhantom hShape
  indexedSingularContractEq := fun {_phantom} hPhantom {_element} {_count} hShape =>
    validatorReady_phantomAdapter_indexed_singular_contract_eq hReady hPhantom hShape
  gatherMultiEndpointReplayed :=
    fun {_phantom} hPhantom hDirection {_boundary} hBoundary =>
    validatorReady_phantomAdapter_gather_multiEndpoint_replayed
      hReady hPhantom hDirection hBoundary
  scatterMultiEndpointReplayed :=
    fun {_phantom} hPhantom hDirection {_boundary} hBoundary =>
    validatorReady_phantomAdapter_scatter_multiEndpoint_replayed
      hReady hPhantom hDirection hBoundary
  recordFieldsUnique := fun {_phantom} hPhantom {_contract} {_fields} hShape =>
    validatorReady_phantomAdapter_record_fieldsUnique hReady hPhantom hShape
  recordMultiFieldsPerm := fun {_phantom} hPhantom {_contract} {_fields} hShape =>
    validatorReady_phantomAdapter_record_multi_fields_perm hReady hPhantom hShape

/-- Validator readiness supplies the full theorem-facing artifact soundness contract. -/
theorem validatorReady_sound
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.Sound where
  schemaCurrent := hReady.schemaCurrent
  primitive := validatorReady_primitiveSound hReady
  generated := validatorReady_generatedSound hReady
  select := validatorReady_selectSound hReady
  phantom := validatorReady_phantomSound hReady

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
