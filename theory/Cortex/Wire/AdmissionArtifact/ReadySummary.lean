import Cortex.Wire.AdmissionArtifact.ReadyPhantomBridge

/-!
## Overview

Validator-ready top-level summary and residual-frontier accessors.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes unique top-level node rows. -/
theorem validatorReady_nodesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.nodes.Nodup :=
  hReady.summaryKeysUnique.nodesUnique

/-- Validator readiness exposes unique top-level binding-reference rows. -/
theorem validatorReady_bindingRefsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.bindingRefs.Nodup :=
  hReady.summaryKeysUnique.bindingRefsUnique

/-- Validator readiness exposes unique top-level entry boundary rows. -/
theorem validatorReady_entriesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.entries.map AdmissionBoundaryPort.key).Nodup :=
  hReady.summaryKeysUnique.entriesUnique

/-- Validator readiness exposes unique top-level exit boundary rows. -/
theorem validatorReady_exitsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (artifact.exits.map AdmissionBoundaryPort.key).Nodup :=
  hReady.summaryKeysUnique.exitsUnique

/-- Validator readiness exposes unique top-level connection rows. -/
theorem validatorReady_connectionsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.connections.Nodup :=
  hReady.summaryKeysUnique.connectionsUnique

/-- Validator readiness forces primitive node identity rows to be duplicate-free. -/
theorem validatorReady_primitiveNodeRowsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps).Nodup :=
  (validatorReady_summaryIdentitiesMatchPrimitive hReady).left.nodup_iff.mp
    (validatorReady_nodesUnique hReady)

/-- Validator readiness forces primitive binding-ref rows to be duplicate-free. -/
theorem validatorReady_primitiveBindingRowsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps).Nodup :=
  (validatorReady_summaryIdentitiesMatchPrimitive hReady).right.nodup_iff.mp
    (validatorReady_bindingRefsUnique hReady)

/-- Validator readiness forces primitive projected raw connections to be duplicate-free. -/
theorem validatorReady_primitiveRawConnectionsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    (PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps).Nodup :=
  (validatorReady_rawConnectionsMatchPrimitive hReady).nodup_iff.mp
    (validatorReady_connectionsUnique hReady)

/-- Validator readiness forces primitive matched contractions to have unique raw projections. -/
theorem validatorReady_primitiveMatchedConnectionRawProjectionsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ((PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps).map
        AdmissionRawConnection.ofAdmissionConnection).Nodup := by
  rw [← PrimitiveGraphStep.rawConnectionsList_eq_map_matchedConnectionsList]
  exact validatorReady_primitiveRawConnectionsUnique hReady

/-- Validator-ready primitive matched contractions are injective under raw endpoint projection.

The top-level Haskell raw-edge ledger intentionally drops boundary metadata.
Validator readiness still rules out two primitive matched contractions projecting
to the same compiled raw edge.
-/
theorem validatorReady_primitiveMatchedConnection_rawProjection_injective
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {left right : AdmissionConnection}
    (hLeft :
      left ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps)
    (hRight :
      right ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps)
    (hProjection :
      AdmissionRawConnection.ofAdmissionConnection left =
        AdmissionRawConnection.ofAdmissionConnection right) :
    left = right :=
  List.inj_on_of_nodup_map
    (validatorReady_primitiveMatchedConnectionRawProjectionsUnique hReady)
    hLeft
    hRight
    hProjection

/-- Validator-ready primitive node frontier rows are unique by node identity.

This is the Lean-facing counterpart of the Haskell `primitiveNodeFrontiers`
lookup being accepted only when exactly one primitive node row exists for a
target node.
-/
theorem validatorReady_primitiveNode_frontiers_unique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {node : NodeId}
    {entries₁ exits₁ entries₂ exits₂ : List AdmissionBoundaryPort}
    (hLeft :
      PrimitiveGraphStep.node node entries₁ exits₁ ∈ artifact.primitiveSteps)
    (hRight :
      PrimitiveGraphStep.node node entries₂ exits₂ ∈ artifact.primitiveSteps) :
    entries₁ = entries₂ ∧ exits₁ = exits₂ :=
  PrimitiveGraphStep.node_frontiers_eq_of_nodeRowsList_nodup
    (validatorReady_primitiveNodeRowsUnique hReady) hLeft hRight

/-- Validator-ready generated child frontiers match any primitive row for that child node.

The primitive node-row uniqueness theorem removes the arbitrary existential
choice made by `GeneratedChildFrontiersMatchPrimitive`.
-/
theorem validatorReady_generatedChild_frontiersMatchPrimitiveRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ generated.usedChildren)
    {entries exits : List AdmissionBoundaryPort}
    (hNode : PrimitiveGraphStep.node child.node entries exits ∈
      artifact.primitiveSteps) :
    child.inputKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
      child.outputKeys.Perm (exits.map AdmissionBoundaryPort.key) := by
  obtain ⟨_primitiveEntries, _primitiveExits, hPrimitiveNode, hInputs, hOutputs⟩ :=
    validatorReady_generatedChild_frontiersMatchPrimitive hReady hGenerated hChild
  obtain ⟨hEntries, hExits⟩ :=
    validatorReady_primitiveNode_frontiers_unique hReady hPrimitiveNode hNode
  exact ⟨by simpa [hEntries] using hInputs, by simpa [hExits] using hOutputs⟩

/-- Validator-ready select bridge facts hold for any primitive row for the condition node. -/
theorem validatorReady_selectBridge_variantFrontiersBackedByPrimitiveRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants)
    {entries exits : List AdmissionBoundaryPort}
    (hNode :
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps) :
    SelectBridgeEntryUnique variant entries ∧
      SelectBridgeInternalExitUnique selectAdmission.conditionNode variant exits := by
  obtain ⟨_primitiveEntries, _primitiveExits, hPrimitiveNode, hEntry, hExit⟩ :=
    validatorReady_selectBridge_variantFrontiersBackedByPrimitive
      hReady hSelect hVariant
  obtain ⟨hEntries, hExits⟩ :=
    validatorReady_primitiveNode_frontiers_unique hReady hPrimitiveNode hNode
  exact ⟨by simpa [hEntries] using hEntry, by simpa [hExits] using hExit⟩

/-- Validator-ready select arm body facts hold for any primitive row for the condition node. -/
theorem validatorReady_select_armBodyBoundariesMatchConditionRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {arm : SelectArmAdmissionArtifact}
    (hArm : arm ∈ selectAdmission.arms)
    {entries exits : List AdmissionBoundaryPort}
    (hNode :
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps) :
    ∃ variant, variant ∈ selectAdmission.variants ∧
      variant.key = arm.canonicalKey ∧
        (((arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
            SelectConditionBridgeOutputShapes selectAdmission exits =
              [variant.port.identityOutputShape]) ∨
          (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
              [variant.port.compatibilityShape] ∧
            (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
              (SelectConditionBridgeOutputShapes selectAdmission exits))) := by
  obtain ⟨_primitiveEntries, primitiveExits, hPrimitiveNode, hVariant⟩ :=
    validatorReady_select_armBodyBoundariesMatchCondition hReady hSelect hArm
  obtain ⟨_hEntries, hExits⟩ :=
    validatorReady_primitiveNode_frontiers_unique hReady hPrimitiveNode hNode
  obtain ⟨variant, hVariantMem, hVariantKey, hBody⟩ := hVariant
  exact ⟨variant, hVariantMem, hVariantKey, by simpa [hExits] using hBody⟩

/-- Validator-ready phantom bridge frontiers match any primitive row for the adapter node.

This turns Haskell's exact-one primitive-node lookup into a reusable Lean-side
transport theorem for phantom witness construction.
-/
theorem validatorReady_phantomBridge_frontiersMatchPrimitiveRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {entries exits : List AdmissionBoundaryPort}
    (hNode : PrimitiveGraphStep.node phantom.node entries exits ∈
      artifact.primitiveSteps) :
    phantom.leftBulkTargetKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
      phantom.rightBulkSourceKeys.Perm (exits.map AdmissionBoundaryPort.key) := by
  obtain ⟨_primitiveEntries, _primitiveExits, hPrimitiveNode, hInputs, hOutputs⟩ :=
    validatorReady_phantomBridge_frontiersMatchPrimitive hReady hPhantom
  obtain ⟨hEntries, hExits⟩ :=
    validatorReady_primitiveNode_frontiers_unique hReady hPrimitiveNode hNode
  exact ⟨by simpa [hEntries] using hInputs, by simpa [hExits] using hOutputs⟩

/-- Validator-ready node summaries are exactly the primitive node identity rows. -/
theorem validatorReady_summary_node_mem_primitiveRows_iff
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {node : NodeId} :
    node ∈ artifact.nodes ↔
      node ∈ PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps :=
  (validatorReady_summaryIdentitiesMatchPrimitive hReady).left.mem_iff

/-- Validator-ready summary nodes are backed by primitive node identity rows. -/
theorem validatorReady_summary_node_in_primitiveRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {node : NodeId}
    (hNode : node ∈ artifact.nodes) :
    node ∈ PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps :=
  (validatorReady_summary_node_mem_primitiveRows_iff hReady).mp hNode

/-- Validator-ready primitive node identity rows appear in the top-level node summary. -/
theorem validatorReady_primitiveNodeRow_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {node : NodeId}
    (hNode : node ∈ PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps) :
    node ∈ artifact.nodes :=
  (validatorReady_summary_node_mem_primitiveRows_iff hReady).mpr hNode

/-- Validator-ready binding summaries are exactly the primitive binding-reference rows. -/
theorem validatorReady_summary_binding_mem_primitiveRows_iff
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {binding : BindingName} :
    binding ∈ artifact.bindingRefs ↔
      binding ∈ PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps :=
  (validatorReady_summaryIdentitiesMatchPrimitive hReady).right.mem_iff

/-- Validator-ready summary binding refs are backed by primitive binding rows. -/
theorem validatorReady_summary_binding_in_primitiveRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {binding : BindingName}
    (hBinding : binding ∈ artifact.bindingRefs) :
    binding ∈ PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps :=
  (validatorReady_summary_binding_mem_primitiveRows_iff hReady).mp hBinding

/-- Empty validator-ready generated-form rows are anchored by a primitive binding row. -/
theorem validatorReady_emptyGeneratedForm_bindingRow
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {generated : GeneratedFormArtifact}
    (hGenerated : generated ∈ artifact.generatedForms)
    (hEmpty : generated.usedChildren = []) :
    generated.binding ∈ PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps :=
  validatorReady_summary_binding_in_primitiveRows hReady
    (validatorReady_emptyGeneratedForm_bindingRef hReady hGenerated hEmpty)

/-- Validator-ready primitive binding rows appear in the top-level binding summary. -/
theorem validatorReady_primitiveBindingRow_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {binding : BindingName}
    (hBinding : binding ∈ PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps) :
    binding ∈ artifact.bindingRefs :=
  (validatorReady_summary_binding_mem_primitiveRows_iff hReady).mpr hBinding

/-- Validator-ready raw connection summaries are exactly primitive connect projections. -/
theorem validatorReady_summary_connection_mem_primitiveRawConnections_iff
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {connection : AdmissionRawConnection} :
    connection ∈ artifact.connections ↔
      connection ∈ PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps :=
  (validatorReady_rawConnectionsMatchPrimitive hReady).mem_iff

/-- Validator-ready summary raw connections are backed by primitive connect projections. -/
theorem validatorReady_summary_connection_in_primitiveRawConnections
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {connection : AdmissionRawConnection}
    (hConnection : connection ∈ artifact.connections) :
    connection ∈ PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps :=
  (validatorReady_summary_connection_mem_primitiveRawConnections_iff hReady).mp
    hConnection

/-- Validator-ready primitive raw connection projections appear in the top-level summary. -/
theorem validatorReady_primitiveRawConnection_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {connection : AdmissionRawConnection}
    (hConnection :
      connection ∈ PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps) :
    connection ∈ artifact.connections :=
  (validatorReady_summary_connection_mem_primitiveRawConnections_iff hReady).mpr
    hConnection

/-- Validator-ready summary raw connections are replayed by primitive matched contractions. -/
theorem validatorReady_summary_connection_replayedByPrimitiveMatch
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {connection : AdmissionRawConnection}
    (hConnection : connection ∈ artifact.connections) :
    ∃ pair, pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps ∧
      AdmissionRawConnection.ofAdmissionConnection pair = connection := by
  have hPrimitive :
      connection ∈ PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps :=
    validatorReady_summary_connection_in_primitiveRawConnections hReady hConnection
  rw [PrimitiveGraphStep.rawConnectionsList_eq_map_matchedConnectionsList] at hPrimitive
  obtain ⟨pair, hPair, hPairProjection⟩ := List.mem_map.mp hPrimitive
  exact ⟨pair, hPair, hPairProjection⟩

/-- Validator-ready primitive matched contractions appear in the top-level raw edge summary. -/
theorem validatorReady_primitiveMatchedConnection_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {pair : AdmissionConnection}
    (hPair : pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps) :
    AdmissionRawConnection.ofAdmissionConnection pair ∈ artifact.connections :=
  validatorReady_primitiveRawConnection_in_summary hReady <| by
    rw [PrimitiveGraphStep.rawConnectionsList_eq_map_matchedConnectionsList]
    exact List.mem_map.mpr ⟨pair, hPair, rfl⟩

/-- Validator readiness exposes valid top-level node rows. -/
theorem validatorReady_summary_nodesValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ∀ node, node ∈ artifact.nodes → node.Valid :=
  hReady.summaryRowsValid.nodesValid

/-- Validator readiness exposes valid top-level binding-reference rows. -/
theorem validatorReady_summary_bindingRefsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ∀ binding, binding ∈ artifact.bindingRefs → binding.Valid :=
  hReady.summaryRowsValid.bindingRefsValid

/-- Validator readiness exposes valid top-level entry boundary rows. -/
theorem validatorReady_summary_entriesValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    BoundaryPortsValid artifact.entries :=
  hReady.summaryRowsValid.entriesValid

/-- Validator readiness exposes valid top-level exit boundary rows. -/
theorem validatorReady_summary_exitsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    BoundaryPortsValid artifact.exits :=
  hReady.summaryRowsValid.exitsValid

/-- Validator readiness exposes that every top-level entry boundary is closed over summary nodes. -/
theorem validatorReady_summary_entriesClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    BoundaryPortsClosed artifact.nodes artifact.entries :=
  hReady.summaryDomainClosed.entriesClosed

/-- Validator readiness exposes that every top-level exit boundary is closed over summary nodes. -/
theorem validatorReady_summary_exitsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    BoundaryPortsClosed artifact.nodes artifact.exits :=
  hReady.summaryDomainClosed.exitsClosed

/-- Validator-ready top-level entry boundaries belong to summary nodes. -/
theorem validatorReady_summary_entryNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {entry : AdmissionBoundaryPort}
    (hEntry : entry ∈ artifact.entries) :
    entry.node ∈ artifact.nodes :=
  (validatorReady_summary_entriesClosed hReady entry hEntry).left

/-- Validator-ready top-level exit boundaries belong to summary nodes. -/
theorem validatorReady_summary_exitNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ artifact.exits) :
    exit.node ∈ artifact.nodes :=
  (validatorReady_summary_exitsClosed hReady exit hExit).left

/-- Validator-ready top-level entries are backed by primitive node frontier rows. -/
theorem validatorReady_summary_entryBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {entry : AdmissionBoundaryPort}
    (hEntry : entry ∈ artifact.entries) :
    entry.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
      entry.key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps :=
  (validatorReady_summaryFrontiersBackedByPrimitive hReady).left entry hEntry

/-- Validator-ready top-level exits are backed by primitive node frontier rows. -/
theorem validatorReady_summary_exitBackedByPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ artifact.exits) :
    exit.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
      exit.key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps :=
  (validatorReady_summaryFrontiersBackedByPrimitive hReady).right exit hExit

/-- Validator-ready entry keys are exactly residual primitive entry frontier keys. -/
theorem validatorReady_summary_entryKey_iff_residualPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId} :
    key ∈ artifact.entries.map AdmissionBoundaryPort.key ↔
      key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
        key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps :=
  (validatorReady_summaryFrontiersMatchPrimitive hReady).left key

/-- Validator-ready exit keys are exactly residual primitive exit frontier keys. -/
theorem validatorReady_summary_exitKey_iff_residualPrimitive
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId} :
    key ∈ artifact.exits.map AdmissionBoundaryPort.key ↔
      key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
        key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps ∧
          ¬ artifact.SelectInternalExitKey key :=
  (validatorReady_summaryFrontiersMatchPrimitive hReady).right key

/-- Unconsumed primitive entry frontier keys appear in the top-level entry summary. -/
theorem validatorReady_residualPrimitiveEntry_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId}
    (hKey : key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
      key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps) :
    key ∈ artifact.entries.map AdmissionBoundaryPort.key :=
  (validatorReady_summary_entryKey_iff_residualPrimitive hReady).mpr hKey

/-- Consumed primitive entry frontier keys are absent from the top-level entry summary. -/
theorem validatorReady_consumedPrimitiveEntry_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId}
    (hConsumed :
      key ∈ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps) :
    key ∉ artifact.entries.map AdmissionBoundaryPort.key := by
  intro hSummary
  exact
    ((validatorReady_summary_entryKey_iff_residualPrimitive hReady).mp
      hSummary).right hConsumed

/-- Validator-ready select bridge entries are absent from source-visible entries. -/
theorem validatorReady_select_variant_bridgeEntry_not_summary
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
            entry.key ∉ artifact.entries.map AdmissionBoundaryPort.key := by
  obtain ⟨entries, exits, entry, hNode, hEntry, hCompatible, hMatchedAndConsumed⟩ :=
    validatorReady_select_variant_bridgeEntryConsumed hReady hSelect hVariant
  exact
    ⟨ entries
    , exits
    , entry
    , hNode
    , hEntry
    , hCompatible
    , validatorReady_consumedPrimitiveEntry_not_summary hReady
        hMatchedAndConsumed.right
    ⟩

/-- Source-visible unconsumed primitive exit frontier keys appear in the top-level exit summary. -/
theorem validatorReady_residualPrimitiveExit_in_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId}
    (hKey : key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
      key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps ∧
        ¬ artifact.SelectInternalExitKey key) :
    key ∈ artifact.exits.map AdmissionBoundaryPort.key :=
  (validatorReady_summary_exitKey_iff_residualPrimitive hReady).mpr hKey

/-- Consumed primitive exit frontier keys are absent from the top-level exit summary. -/
theorem validatorReady_consumedPrimitiveExit_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId}
    (hConsumed :
      key ∈ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps) :
    key ∉ artifact.exits.map AdmissionBoundaryPort.key := by
  intro hSummary
  exact
    ((validatorReady_summary_exitKey_iff_residualPrimitive hReady).mp
      hSummary).right.left hConsumed

/-- Select-internal primitive exit keys are absent from the source-visible exit summary. -/
theorem validatorReady_selectInternalExitKey_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {key : NodeId × FieldLabel × ContractId}
    (hInternal : artifact.SelectInternalExitKey key) :
    key ∉ artifact.exits.map AdmissionBoundaryPort.key := by
  intro hSummary
  exact
    ((validatorReady_summary_exitKey_iff_residualPrimitive hReady).mp
      hSummary).right.right hInternal

/-- Internal choice exits from select condition-node rows are absent from top-level exits. -/
theorem validatorReady_selectInternalChoiceExit_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entries exits : List AdmissionBoundaryPort}
    (hNode :
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ exits)
    (hChoice : SelectInternalChoiceExit selectAdmission exit = true) :
    exit.key ∉ artifact.exits.map AdmissionBoundaryPort.key :=
  validatorReady_selectInternalExitKey_not_summary hReady
    (selectInternalChoiceExit_key hSelect hNode hExit hChoice)

/-- Replay-hidden select exits from primitive node rows are absent from top-level exits. -/
theorem validatorReady_selectInternalTraceExit_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {node : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hNode : PrimitiveGraphStep.node node entries exits ∈ artifact.primitiveSteps)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ exits)
    (hHidden : artifact.SelectInternalTraceExit exit) :
    exit.key ∉ artifact.exits.map AdmissionBoundaryPort.key :=
  validatorReady_selectInternalExitKey_not_summary hReady
    (selectInternalTraceExit_key_of_valid_node
      (hReady.primitiveStepsValid (PrimitiveGraphStep.node node entries exits) hNode)
      hNode hExit hHidden)

/-- Every validator-ready select variant has a hidden bridge-choice exit absent from the summary. -/
theorem validatorReady_select_variant_internalChoiceExit_not_summary
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    ∃ entries exits exit,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        exit ∈ exits ∧
          SelectInternalChoiceExit selectAdmission exit = true ∧
            exit.key ∉ artifact.exits.map AdmissionBoundaryPort.key := by
  obtain ⟨entries, exits, hNode, _hEntry, hInternalExit⟩ :=
    validatorReady_selectBridge_variantFrontiersBackedByPrimitive
      hReady hSelect hVariant
  obtain ⟨exit, hExit, _hCompatible, hChoice⟩ :=
    selectBridgeInternalExitUnique_choiceExit hVariant hInternalExit
  exact
    ⟨ entries
    , exits
    , exit
    , hNode
    , hExit
    , hChoice
    , validatorReady_selectInternalChoiceExit_not_summary
        hReady hSelect hNode hExit hChoice
    ⟩

/-- Every validator-ready select variant has condition-node bridge rows in primitive replay.

This is the Lean-side accessor for Haskell
`wireAdmissionSelectBridgeFrontiersBackedByPrimitive`: the compatible entry and
the internal branch-choice exit both come from the serialized primitive node row
for the select condition node.
-/
theorem validatorReady_select_variant_conditionBridgeRows
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {variant : SelectVariantArtifact}
    (hVariant : variant ∈ selectAdmission.variants) :
    ∃ entries exits entry exit,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        entry ∈ entries ∧
          exit ∈ exits ∧
            entry.node = selectAdmission.conditionNode ∧
              exit.node = selectAdmission.conditionNode ∧
                variant.port.CompatibleWith entry ∧
                  variant.port.CompatibleWith exit ∧
                    SelectInternalChoiceExit selectAdmission exit = true := by
  obtain ⟨entries, exits, hNode, hEntryUnique, hExitUnique⟩ :=
    validatorReady_selectBridge_variantFrontiersBackedByPrimitive
      hReady hSelect hVariant
  obtain ⟨entry, hEntry, hEntryCompatible⟩ :=
    selectBridgeEntryUnique_entry hEntryUnique
  obtain ⟨exit, hExit, hExitCompatible, hChoice⟩ :=
    selectBridgeInternalExitUnique_choiceExit hVariant hExitUnique
  have hStepValid :
      (PrimitiveGraphStep.node selectAdmission.conditionNode entries exits).Valid :=
    hReady.primitiveStepsValid
      (PrimitiveGraphStep.node selectAdmission.conditionNode entries exits) hNode
  have hOwned :
      PrimitiveGraphStep.NodeFrontiersOwned
        selectAdmission.conditionNode entries exits :=
    hStepValid.frontiersOwned
  exact
    ⟨ entries
    , exits
    , entry
    , exit
    , hNode
    , hEntry
    , hExit
    , hOwned.left entry hEntry
    , hOwned.right exit hExit
    , hEntryCompatible
    , hExitCompatible
    , hChoice
    ⟩

/-- Validator-ready top-level exits are never select-internal bridge-choice exits. -/
theorem validatorReady_summary_exit_not_selectInternal
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ artifact.exits) :
    ¬ artifact.SelectInternalExitKey exit.key := by
  have hKey : exit.key ∈ artifact.exits.map AdmissionBoundaryPort.key :=
    List.mem_map.mpr ⟨exit, hExit, rfl⟩
  exact
    ((validatorReady_summary_exitKey_iff_residualPrimitive hReady).mp
      hKey).right.right

/-- Validator readiness exposes valid top-level raw connection rows. -/
theorem validatorReady_summary_connectionsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ∀ connection, connection ∈ artifact.connections → connection.Valid :=
  hReady.summaryRowsValid.connectionsValid

/-- Validator readiness exposes that every raw connection endpoint belongs to a summary node. -/
theorem validatorReady_summary_connectionsClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    ∀ connection, connection ∈ artifact.connections →
      connection.fromEndpoint.node ∈ artifact.nodes ∧
        connection.toEndpoint.node ∈ artifact.nodes :=
  hReady.summaryDomainClosed.connectionsClosed

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
