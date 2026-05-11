import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction

/-!
## Overview

Phantom-adapter reconstruction from validator-sound admission artifacts.

The phantom artifact rows record the generated adapter node, product shape,
source-visible multi/singular endpoints, and the two primitive bulk ledgers
emitted for `*`. They do not serialize the left and right operand graphs or the
Lean `BulkContract` traces required by `PhantomAdapterWitness`.

This module therefore reconstructs the strongest honest artifact-boundary
witness:

- the generated phantom node is backed by a primitive node row;
- that primitive row builds an open source-linear phantom-node object;
- left/right phantom bulk ledgers are replayed by primitive matched
  connections;
- record and bounded-indexed product-shape facts are available in case form;
- source-visible multi/singular endpoints are covered by direction-specific
  replay facts; and
- phantom-node frontier keys are accounted for by primitive replay.

The later full-graph reconstruction step must add the operand graphs and
certified `BulkContract` traces before constructing `PhantomAdapterWitness`.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace AdmissionBoundaryPort

/-! ## Boundary-Row Source Instances -/

/-- Direction-erased port signature projected from an artifact boundary row. -/
def sourcePortSignature (boundary : AdmissionBoundaryPort) : PortSignature :=
  { label := boundary.port
    contract := boundary.contract }

/-- Output-direction source instance projected from an artifact boundary row. -/
def sourceOutputInstance
    (boundary : AdmissionBoundaryPort) :
    SourcePortInstance NodeId OutputPortSignature :=
  { node := boundary.node
    port := { signature := boundary.sourcePortSignature } }

/-- Input-direction source instance projected from an artifact boundary row. -/
def sourceInputInstance
    (boundary : AdmissionBoundaryPort) :
    SourcePortInstance NodeId InputPortSignature :=
  { node := boundary.node
    port := { signature := boundary.sourcePortSignature } }

/-- Open source-linear object for one primitive node row. -/
def openBoundaryNodeObject
    (node : NodeId)
    (entries exits : List AdmissionBoundaryPort)
    (hEntryNodes : ∀ entry, entry ∈ entries → entry.node = node)
    (hExitNodes : ∀ exit, exit ∈ exits → exit.node = node) :
    LinearPortGraph.LinearPortObject NodeId OutputPortSignature InputPortSignature :=
  LinearPortGraph.LinearPortObject.nodePorts
    ({node} : Finset NodeId)
    ((exits.map AdmissionBoundaryPort.sourceOutputInstance).toFinset)
    ((entries.map AdmissionBoundaryPort.sourceInputInstance).toFinset)
    (by
      intro output hOutput
      simp only [List.mem_toFinset] at hOutput
      rcases List.mem_map.mp hOutput with ⟨exit, hExit, hEq⟩
      subst hEq
      exact Finset.mem_singleton.mpr (hExitNodes exit hExit))
    (by
      intro input hInput
      simp only [List.mem_toFinset] at hInput
      rcases List.mem_map.mp hInput with ⟨entry, hEntry, hEq⟩
      subst hEq
      exact Finset.mem_singleton.mpr (hEntryNodes entry hEntry))

end AdmissionBoundaryPort

namespace WireAdmissionArtifact

/-! ## Phantom Reconstruction Contract -/

/-- Primitive-backed open phantom-node object reconstructed for one adapter row. -/
structure PhantomBridgeObjectReconstruction
    (artifact : WireAdmissionArtifact)
    (phantom : PhantomAdapterArtifact)
    (entries exits : List AdmissionBoundaryPort) : Prop where
  primitiveNode :
    PrimitiveGraphStep.node phantom.node entries exits ∈ artifact.primitiveSteps
  entriesOwned : ∀ entry, entry ∈ entries → entry.node = phantom.node
  exitsOwned : ∀ exit, exit ∈ exits → exit.node = phantom.node
  /-- No two entries share a boundary key. Load-bearing against silent collapse
  in `openBoundaryNodeObject`'s `.toFinset` dedup, which projects on the
  `(node, port, contract)` key only (see `AdmissionBoundaryPort.key`). -/
  entriesUnique : (entries.map AdmissionBoundaryPort.key).Nodup
  /-- No two exits share a boundary key. Same role as `entriesUnique`. -/
  exitsUnique : (exits.map AdmissionBoundaryPort.key).Nodup
  leftBulkTargetsMatchPrimitive :
    phantom.leftBulkTargetKeys.Perm (entries.map AdmissionBoundaryPort.key)
  rightBulkSourcesMatchPrimitive :
    phantom.rightBulkSourceKeys.Perm (exits.map AdmissionBoundaryPort.key)
  /-- The open phantom-node object is source-linear. The proof is the smart
  constructor's built-in `openNodePorts_portLinear` invariant; it does not
  depend on artifact-specific data. The no-silent-collapse fields downstream
  consumers should read are `entriesUnique` / `exitsUnique`. -/
  openObjectLinear :
    (AdmissionBoundaryPort.openBoundaryNodeObject
      phantom.node entries exits entriesOwned exitsOwned).graph.PortLinear
  inputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ entries.map AdmissionBoundaryPort.key →
        PrimitiveInputKeyAccounted artifact key
  outputKeysAccounted :
    ∀ {key : NodeId × FieldLabel × ContractId},
      key ∈ exits.map AdmissionBoundaryPort.key →
        PrimitiveOutputKeyAccounted artifact key

/-- Product-shape reconstruction for a phantom artifact row. -/
inductive PhantomProductReconstruction
    (artifact : WireAdmissionArtifact)
    (phantom : PhantomAdapterArtifact) : Prop where
  | record
      {contract : ContractId}
      {fields : List (FieldLabel × ContractId)}
      (shape_eq : phantom.productShape =
        ProductShapeArtifact.record contract fields)
      (contractValid : contract.Valid)
      (fieldRowsValid :
        ∀ field, field ∈ fields → field.fst.Valid ∧ field.snd.Valid)
      (fieldsUnique : (fields.map Prod.fst).Nodup)
      (multiLengthEq : phantom.multi.length = fields.length)
      (multiFieldsPerm :
        (phantom.multi.filterMap AdmissionBoundaryPort.recordField).Perm fields)
      (singularContractEq : phantom.singular.contract = contract) :
        PhantomProductReconstruction artifact phantom
  | indexed
      {element : ContractId}
      {count : Nat}
      (shape_eq : phantom.productShape =
        ProductShapeArtifact.indexed element count)
      (elementValid : element.Valid)
      (elementNominal : element.name.startsWith "[" = false)
      (multiLengthEq : phantom.multi.length = count)
      (multiContractEq :
        ∀ boundary, boundary ∈ phantom.multi → boundary.contract = element)
      (multiCompatibilityKeysUnique :
        (phantom.multi.map AdmissionBoundaryPort.compatibilityShape).Nodup)
      (singularContractEq :
        phantom.singular.contract = ContractId.boundedIndexed element count) :
        PhantomProductReconstruction artifact phantom

/-- Direction-specific replay evidence for the source-visible `*` endpoints. -/
inductive PhantomDirectionReconstruction
    (artifact : WireAdmissionArtifact)
    (phantom : PhantomAdapterArtifact) : Prop where
  | gather
      (direction_eq : phantom.direction = PhantomAdapterDirection.gather)
      (leftBulkSourcesPermMulti :
        phantom.leftBulkSourceKeys.Perm
          (phantom.multi.map AdmissionBoundaryPort.key))
      (rightBulkTargetsPermSingular :
        phantom.rightBulkTargetKeys.Perm [phantom.singular.key])
      (multiEndpointsReplayed :
        ∀ {boundary : AdmissionBoundaryPort},
          boundary ∈ phantom.multi →
            ∃ pair, pair ∈ phantom.leftBulk ∧
              pair.fromKey = boundary.key ∧
                pair ∈ PrimitiveGraphStep.matchedConnectionsList
                  artifact.primitiveSteps)
      (singularEndpointReplayed :
        ∃ pair, pair ∈ phantom.rightBulk ∧
          pair.toKey = phantom.singular.key ∧
            pair ∈ PrimitiveGraphStep.matchedConnectionsList
              artifact.primitiveSteps) :
        PhantomDirectionReconstruction artifact phantom
  | scatter
      (direction_eq : phantom.direction = PhantomAdapterDirection.scatter)
      (leftBulkSourcesPermSingular :
        phantom.leftBulkSourceKeys.Perm [phantom.singular.key])
      (rightBulkTargetsPermMulti :
        phantom.rightBulkTargetKeys.Perm
          (phantom.multi.map AdmissionBoundaryPort.key))
      (singularEndpointReplayed :
        ∃ pair, pair ∈ phantom.leftBulk ∧
          pair.fromKey = phantom.singular.key ∧
            pair ∈ PrimitiveGraphStep.matchedConnectionsList
              artifact.primitiveSteps)
      (multiEndpointsReplayed :
        ∀ {boundary : AdmissionBoundaryPort},
          boundary ∈ phantom.multi →
            ∃ pair, pair ∈ phantom.rightBulk ∧
              pair.toKey = boundary.key ∧
                pair ∈ PrimitiveGraphStep.matchedConnectionsList
                  artifact.primitiveSteps) :
        PhantomDirectionReconstruction artifact phantom

/-- Artifact-boundary reconstruction evidence for one phantom adapter row
indexed by a shared primitive bridge witness.

The `bridgeEntries` / `bridgeExits` parameters name the single primitive node
row that backs the adapter node. Sharing them at this layer pins the bridge
frontier witness to one concrete primitive row, removing the ambiguity that
would otherwise arise from `bridge` carrying its own existential `(entries,
exits)`. The bulk-replay fields don't quantify over any primitive frontier
row — they only assert membership in `matchedConnectionsList`, so they're
unaffected by this parameterization. -/
structure PhantomAdapterReconstructionRecord
    (artifact : WireAdmissionArtifact)
    (phantom : PhantomAdapterArtifact)
    (bridgeEntries bridgeExits : List AdmissionBoundaryPort) : Prop where
  valid : phantom.Valid
  bridge :
    PhantomBridgeObjectReconstruction artifact phantom bridgeEntries bridgeExits
  product : PhantomProductReconstruction artifact phantom
  direction : PhantomDirectionReconstruction artifact phantom
  leftBulkReplayed :
    ∀ {pair : AdmissionConnection},
      pair ∈ phantom.leftBulk →
        pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps
  rightBulkReplayed :
    ∀ {pair : AdmissionConnection},
      pair ∈ phantom.rightBulk →
        pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps

/-- Artifact-boundary reconstruction evidence for one phantom adapter row. -/
def PhantomAdapterReconstruction
    (artifact : WireAdmissionArtifact)
    (phantom : PhantomAdapterArtifact) : Prop :=
  ∃ bridgeEntries bridgeExits,
    PhantomAdapterReconstructionRecord artifact phantom bridgeEntries bridgeExits

/-- Artifact-boundary phantom reconstruction for every phantom adapter row. -/
def PhantomReconstruction (artifact : WireAdmissionArtifact) : Prop :=
  ∀ phantom, phantom ∈ artifact.phantomAdapters →
    PhantomAdapterReconstruction artifact phantom

/-! ## Reconstruction Theorems -/

/-- Phantom soundness reconstructs the source-linear open object for the adapter node. -/
theorem Sound.phantomBridgeObjectReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    ∃ entries exits,
      PhantomBridgeObjectReconstruction artifact phantom entries exits := by
  obtain ⟨entries, exits, hPrimitiveNode, hEntries, hExits⟩ :=
    hSound.phantom.phantomBridgeFrontiersMatchPrimitive phantom hPhantom
  have hPrimitiveValid :
      (PrimitiveGraphStep.node phantom.node entries exits).Valid :=
    hSound.primitive.primitiveStepsValid
      (PrimitiveGraphStep.node phantom.node entries exits)
      hPrimitiveNode
  have hOwned := hPrimitiveValid.frontiersOwned
  have hFrontierLinear := hPrimitiveValid.frontiersLinear
  have hAccounted :
      artifact.PrimitiveFrontierKeysAccounted :=
    primitiveFrontierKeysAccounted
      hSound.primitive.summaryFrontiersMatchPrimitive
  refine
    ⟨ entries
    , exits
    , { primitiveNode := hPrimitiveNode
        entriesOwned := hOwned.left
        exitsOwned := hOwned.right
        entriesUnique := hFrontierLinear.left
        exitsUnique := hFrontierLinear.right
        leftBulkTargetsMatchPrimitive := hEntries
        rightBulkSourcesMatchPrimitive := hExits
        openObjectLinear :=
          (AdmissionBoundaryPort.openBoundaryNodeObject
            phantom.node entries exits hOwned.left hOwned.right).linear
        inputKeysAccounted := by
          intro key hKey
          have hPrimitiveKey :
              key ∈ PrimitiveGraphStep.nodeEntryKeysList
                artifact.primitiveSteps :=
            PrimitiveGraphStep.nodeEntryKeysList_mem_of_node_mem
              hPrimitiveNode hKey
          exact hAccounted.inputs hPrimitiveKey
        outputKeysAccounted := by
          intro key hKey
          have hPrimitiveKey :
              key ∈ PrimitiveGraphStep.nodeExitKeysList
                artifact.primitiveSteps :=
            PrimitiveGraphStep.nodeExitKeysList_mem_of_node_mem
              hPrimitiveNode hKey
          exact hAccounted.outputs hPrimitiveKey }
    ⟩

/-- Phantom soundness reconstructs product-shape evidence for one adapter row. -/
theorem Sound.phantomProductReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    PhantomProductReconstruction artifact phantom := by
  have hValid := hSound.phantom.phantomAdaptersValid phantom hPhantom
  cases hShape : phantom.productShape with
  | record contract fields =>
      have hProductValid := hValid.productShapeValid
      have hArity := hValid.productArityMatches
      have hSingular := hValid.productContractMatchesSingular
      unfold PhantomAdapterArtifact.ProductArityMatches at hArity
      unfold PhantomAdapterArtifact.ProductContractMatchesSingular at hSingular
      rw [hShape] at hProductValid hArity hSingular
      exact
        PhantomProductReconstruction.record
          hShape
          (ProductShapeArtifact.valid_record_contractValid hProductValid)
          (fun field hField =>
            ProductShapeArtifact.valid_record_fieldValid hProductValid hField)
          (hSound.phantom.recordFieldsUnique hPhantom hShape)
          (by simpa [ProductShapeArtifact.arity] using hArity)
          (hSound.phantom.recordMultiFieldsPerm hPhantom hShape)
          (by simpa [ProductShapeArtifact.contract] using hSingular)
  | indexed element count =>
      have hProductValid := hValid.productShapeValid
      have hCompatibility := hValid.indexedMultiCompatibilityKeysUnique
      unfold PhantomAdapterArtifact.IndexedMultiCompatibilityKeysUnique
        at hCompatibility
      rw [hShape] at hProductValid hCompatibility
      exact
        PhantomProductReconstruction.indexed
          hShape
          (hSound.phantom.indexedElementValid hPhantom hShape)
          (hSound.phantom.indexedElementNominal hPhantom hShape)
          (hSound.phantom.indexedMultiLengthEq hPhantom hShape)
          (fun boundary hBoundary =>
            hSound.phantom.indexedMultiContractEq
              hPhantom hShape hBoundary)
          hCompatibility
          (hSound.phantom.indexedSingularContractEq hPhantom hShape)

/-- Phantom soundness reconstructs replay evidence for a gather singular endpoint. -/
theorem PhantomSound.gatherSingularEndpointReplayed
    {artifact : WireAdmissionArtifact}
    (hPhantomSound : artifact.PhantomSound)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather) :
    ∃ pair, pair ∈ phantom.rightBulk ∧
      pair.toKey = phantom.singular.key ∧
        pair ∈ PrimitiveGraphStep.matchedConnectionsList
          artifact.primitiveSteps := by
  have hValid := hPhantomSound.phantomAdaptersValid phantom hPhantom
  have hPartition := hValid.bulkEndpointPartition
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  have hKeyMem :
      phantom.singular.key ∈ phantom.rightBulkTargetKeys :=
    hPartition.right.mem_iff.mpr (by simp)
  unfold PhantomAdapterArtifact.rightBulkTargetKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , (hPhantomSound.phantomBridgeBulkConnectionsReplayed
        phantom hPhantom).right pair hPair
    ⟩

/-- Phantom soundness reconstructs replay evidence for a scatter singular endpoint. -/
theorem PhantomSound.scatterSingularEndpointReplayed
    {artifact : WireAdmissionArtifact}
    (hPhantomSound : artifact.PhantomSound)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter) :
    ∃ pair, pair ∈ phantom.leftBulk ∧
      pair.fromKey = phantom.singular.key ∧
        pair ∈ PrimitiveGraphStep.matchedConnectionsList
          artifact.primitiveSteps := by
  have hValid := hPhantomSound.phantomAdaptersValid phantom hPhantom
  have hPartition := hValid.bulkEndpointPartition
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  have hKeyMem :
      phantom.singular.key ∈ phantom.leftBulkSourceKeys :=
    hPartition.left.mem_iff.mpr (by simp)
  unfold PhantomAdapterArtifact.leftBulkSourceKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , (hPhantomSound.phantomBridgeBulkConnectionsReplayed
        phantom hPhantom).left pair hPair
    ⟩

/-- Phantom soundness reconstructs direction-specific endpoint replay evidence. -/
theorem Sound.phantomDirectionReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    PhantomDirectionReconstruction artifact phantom := by
  have hValid := hSound.phantom.phantomAdaptersValid phantom hPhantom
  have hPartition := hValid.bulkEndpointPartition
  cases hDirection : phantom.direction with
  | gather =>
      unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
      rw [hDirection] at hPartition
      exact
        PhantomDirectionReconstruction.gather
          hDirection
          hPartition.left
          hPartition.right
          (fun hBoundary =>
            hSound.phantom.gatherMultiEndpointReplayed
              hPhantom hDirection hBoundary)
          (hSound.phantom.gatherSingularEndpointReplayed
            hPhantom hDirection)
  | scatter =>
      unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
      rw [hDirection] at hPartition
      exact
        PhantomDirectionReconstruction.scatter
          hDirection
          hPartition.left
          hPartition.right
          (hSound.phantom.scatterSingularEndpointReplayed
            hPhantom hDirection)
          (fun hBoundary =>
            hSound.phantom.scatterMultiEndpointReplayed
              hPhantom hDirection hBoundary)

/-- Validator soundness reconstructs phantom-adapter artifact-boundary witnesses. -/
theorem Sound.toPhantomReconstruction
    {artifact : WireAdmissionArtifact}
    (hSound : artifact.Sound) :
    artifact.PhantomReconstruction := by
  intro phantom hPhantom
  obtain ⟨bridgeEntries, bridgeExits, hBridge⟩ :=
    hSound.phantomBridgeObjectReconstruction hPhantom
  refine ⟨bridgeEntries, bridgeExits, ?_⟩
  exact
    { valid := hSound.phantom.phantomAdaptersValid phantom hPhantom
      bridge := hBridge
      product := hSound.phantomProductReconstruction hPhantom
      direction := hSound.phantomDirectionReconstruction hPhantom
      leftBulkReplayed := by
        intro pair hPair
        exact
          (hSound.phantom.phantomBridgeBulkConnectionsReplayed
            phantom hPhantom).left pair hPair
      rightBulkReplayed := by
        intro pair hPair
        exact
          (hSound.phantom.phantomBridgeBulkConnectionsReplayed
            phantom hPhantom).right pair hPair }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
