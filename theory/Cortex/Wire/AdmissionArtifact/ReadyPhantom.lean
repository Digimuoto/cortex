import Cortex.Wire.AdmissionArtifact.ReadyPrimitive

/-!
## Overview

Validator-ready phantom adapter accessors.

This page exposes product, boundary, bulk-replay, indexed-product, and record-product consequences
for phantom adapter rows in a validator-ready artifact.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Validator readiness exposes phantom-adapter row validity. -/
theorem validatorReady_phantomAdapter_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.Valid :=
  hReady.phantomAdaptersValid phantom hPhantom

/-- Validator readiness exposes phantom-adapter domain closure. -/
theorem validatorReady_phantomAdapter_domainClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    PhantomAdapterArtifact.DomainClosed artifact.nodes phantom :=
  hReady.componentDomainsClosed.phantomAdaptersClosed phantom hPhantom

/-- Validator-ready phantom adapter nodes belong to the top-level node summary. -/
theorem validatorReady_phantomAdapter_nodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.node ∈ artifact.nodes :=
  (validatorReady_phantomAdapter_domainClosed hReady hPhantom).nodeClosed

/-- Validator-ready phantom singular endpoints belong to the top-level node summary. -/
theorem validatorReady_phantomAdapter_singularNodeClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.singular.node ∈ artifact.nodes :=
  (validatorReady_phantomAdapter_domainClosed hReady hPhantom).singularNodeClosed

/-- Validator-ready phantom multi-side endpoints are closed over the node summary. -/
theorem validatorReady_phantomAdapter_multiBoundaryClosed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    AdmissionBoundaryPort.ClosedOver artifact.nodes boundary :=
  (validatorReady_phantomAdapter_domainClosed hReady hPhantom).multiClosed
    boundary hBoundary

/-- Validator-ready phantom left-bulk rows are closed over the node summary. -/
theorem validatorReady_phantomAdapter_leftBulk_closed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    AdmissionBoundaryPort.ClosedOver artifact.nodes pair.fromPort ∧
      AdmissionBoundaryPort.ClosedOver artifact.nodes pair.toPort :=
  (validatorReady_phantomAdapter_domainClosed hReady hPhantom).leftBulkClosed
    pair hPair

/-- Validator-ready phantom right-bulk rows are closed over the node summary. -/
theorem validatorReady_phantomAdapter_rightBulk_closed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    AdmissionBoundaryPort.ClosedOver artifact.nodes pair.fromPort ∧
      AdmissionBoundaryPort.ClosedOver artifact.nodes pair.toPort :=
  (validatorReady_phantomAdapter_domainClosed hReady hPhantom).rightBulkClosed
    pair hPair

/-- Validator-ready phantom adapter nodes appear in the component-role ledger. -/
theorem validatorReady_phantomAdapter_node_mem_componentRoleNodes
    {artifact : WireAdmissionArtifact}
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.node ∈ artifact.componentRoleNodes := by
  simp [componentRoleNodes]
  exact Or.inr (Or.inl ⟨phantom, hPhantom, rfl⟩)

/-- Validator-ready phantom adapter nodes appear in the phantom-role ledger. -/
theorem validatorReady_phantomAdapter_node_mem_phantomAdapterNodes
    {artifact : WireAdmissionArtifact}
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.node ∈ artifact.phantomAdapters.map PhantomAdapterArtifact.node :=
  List.mem_map.mpr ⟨phantom, hPhantom, rfl⟩

/-- Validator-ready phantom-adapter rows expose product arity matching. -/
theorem validatorReady_phantomAdapter_productArityMatches
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.ProductArityMatches :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).productArityMatches

/-- Validator-ready phantom-adapter rows expose product-shape/multi-frontier matching. -/
theorem validatorReady_phantomAdapter_productShapeMatchesMulti
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.ProductShapeMatchesMulti :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).productShapeMatchesMulti

/-- Validator-ready phantom-adapter rows expose singular/product contract matching. -/
theorem validatorReady_phantomAdapter_productContractMatchesSingular
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.ProductContractMatchesSingular :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).productContractMatchesSingular

/-- Validator-ready phantom-adapter rows expose product-shape validity. -/
theorem validatorReady_phantomAdapter_productShape_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.productShape.Valid :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).productShapeValid

/-- Validator-ready phantom-adapter rows expose validity of the aggregate product contract. -/
theorem validatorReady_phantomAdapter_product_contractValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.productShape.contract.Valid :=
  ProductShapeArtifact.valid_contractValid
    (validatorReady_phantomAdapter_productShape_valid hReady hPhantom)

/-- Validator-ready phantom-adapter rows expose multi-side endpoint uniqueness. -/
theorem validatorReady_phantomAdapter_multiEndpointKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.MultiEndpointKeysUnique :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).multiEndpointKeysUnique

/-- Validator-ready phantom-adapter rows expose direction-aware bulk endpoint matching. -/
theorem validatorReady_phantomAdapter_bulkEndpointsMatch
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.BulkEndpointsMatch :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).bulkEndpointsMatch

/-- Validator-ready phantom-adapter rows expose exact bulk endpoint partitioning. -/
theorem validatorReady_phantomAdapter_bulkEndpointPartition
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.BulkEndpointPartition :=
  (validatorReady_phantomAdapter_valid hReady hPhantom).bulkEndpointPartition

/-- Validator-ready phantom-adapter rows expose indexed multi-side compatibility-key uniqueness. -/
theorem validatorReady_phantomAdapter_indexedMultiCompatibilityKeysUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.IndexedMultiCompatibilityKeysUnique :=
  (validatorReady_phantomAdapter_valid
    hReady hPhantom).indexedMultiCompatibilityKeysUnique

/-- Validator-ready gather artifacts expose the left-bulk multi-to-phantom endpoint shape. -/
theorem validatorReady_phantomAdapter_gather_leftBulkEndpoints
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.fromPort ∈ phantom.multi ∧ pair.toPort.node = phantom.node := by
  have hMatch := validatorReady_phantomAdapter_bulkEndpointsMatch hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointsMatch at hMatch
  rw [hDirection] at hMatch
  exact hMatch.left pair hPair

/-- Validator-ready gather artifacts expose the right-bulk phantom-to-singular endpoint shape. -/
theorem validatorReady_phantomAdapter_gather_rightBulkEndpoints
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.fromPort.node = phantom.node ∧ pair.toPort = phantom.singular := by
  have hMatch := validatorReady_phantomAdapter_bulkEndpointsMatch hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointsMatch at hMatch
  rw [hDirection] at hMatch
  exact hMatch.right pair hPair

/-- Validator-ready scatter artifacts expose the left-bulk singular-to-phantom endpoint shape. -/
theorem validatorReady_phantomAdapter_scatter_leftBulkEndpoints
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.fromPort = phantom.singular ∧ pair.toPort.node = phantom.node := by
  have hMatch := validatorReady_phantomAdapter_bulkEndpointsMatch hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointsMatch at hMatch
  rw [hDirection] at hMatch
  exact hMatch.left pair hPair

/-- Validator-ready scatter artifacts expose the right-bulk phantom-to-multi endpoint shape. -/
theorem validatorReady_phantomAdapter_scatter_rightBulkEndpoints
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.fromPort.node = phantom.node ∧ pair.toPort ∈ phantom.multi := by
  have hMatch := validatorReady_phantomAdapter_bulkEndpointsMatch hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointsMatch at hMatch
  rw [hDirection] at hMatch
  exact hMatch.right pair hPair

/-- Validator-ready gather artifacts expose exact left-bulk coverage of multi-side keys. -/
theorem validatorReady_phantomAdapter_gather_leftBulkSourceKeys_perm_multi
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather) :
    phantom.leftBulkSourceKeys.Perm
      (phantom.multi.map AdmissionBoundaryPort.key) := by
  have hPartition := validatorReady_phantomAdapter_bulkEndpointPartition hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  exact hPartition.left

/-- Validator-ready gather artifacts expose exact right-bulk coverage of the singular key. -/
theorem validatorReady_phantomAdapter_gather_rightBulkTargetKeys_perm_singular
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather) :
    phantom.rightBulkTargetKeys.Perm [phantom.singular.key] := by
  have hPartition := validatorReady_phantomAdapter_bulkEndpointPartition hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  exact hPartition.right

/-- Validator-ready scatter artifacts expose exact left-bulk coverage of the singular key. -/
theorem validatorReady_phantomAdapter_scatter_leftBulkSourceKeys_perm_singular
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter) :
    phantom.leftBulkSourceKeys.Perm [phantom.singular.key] := by
  have hPartition := validatorReady_phantomAdapter_bulkEndpointPartition hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  exact hPartition.left

/-- Validator-ready scatter artifacts expose exact right-bulk coverage of multi-side keys. -/
theorem validatorReady_phantomAdapter_scatter_rightBulkTargetKeys_perm_multi
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter) :
    phantom.rightBulkTargetKeys.Perm
      (phantom.multi.map AdmissionBoundaryPort.key) := by
  have hPartition := validatorReady_phantomAdapter_bulkEndpointPartition hReady hPhantom
  unfold PhantomAdapterArtifact.BulkEndpointPartition at hPartition
  rw [hDirection] at hPartition
  exact hPartition.right

/-- Validator-ready phantom-adapter rows expose structural row validity. -/
theorem validatorReady_phantomAdapter_rowsValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.RowsValid :=
  (validatorReady_phantomAdapter_valid
    hReady hPhantom).rowsValid

/-- Validator-ready phantom adapter nodes carry valid node identifiers. -/
theorem validatorReady_phantomAdapter_nodeValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.node.Valid :=
  (validatorReady_phantomAdapter_rowsValid hReady hPhantom).nodeValid

/-- Validator-ready phantom singular endpoints are structurally valid. -/
theorem validatorReady_phantomAdapter_singularValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.singular.Valid :=
  (validatorReady_phantomAdapter_rowsValid hReady hPhantom).singularValid

/-- Validator-ready phantom multi-side endpoints are structurally valid. -/
theorem validatorReady_phantomAdapter_multiBoundaryValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    boundary.Valid :=
  (validatorReady_phantomAdapter_rowsValid hReady hPhantom).multiValid
    boundary hBoundary

/-- Validator-ready phantom left-bulk rows are structurally valid. -/
theorem validatorReady_phantomAdapter_leftBulk_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.Valid :=
  (validatorReady_phantomAdapter_rowsValid hReady hPhantom).leftBulkValid
    pair hPair

/-- Validator-ready phantom right-bulk rows are structurally valid. -/
theorem validatorReady_phantomAdapter_rightBulk_valid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.Valid :=
  (validatorReady_phantomAdapter_rowsValid hReady hPhantom).rightBulkValid
    pair hPair

/-- Validator-ready phantom-adapter rows expose compatibility for each left bulk row. -/
theorem validatorReady_phantomAdapter_leftBulk_boundaryCompatible
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.BoundaryCompatible :=
  let hRows := validatorReady_phantomAdapter_rowsValid hReady hPhantom
  connectionsValid_boundaryCompatible hRows.leftBulkValid hPair

/-- Validator-ready phantom-adapter rows expose compatibility for each right bulk row. -/
theorem validatorReady_phantomAdapter_rightBulk_boundaryCompatible
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.BoundaryCompatible :=
  let hRows := validatorReady_phantomAdapter_rowsValid hReady hPhantom
  connectionsValid_boundaryCompatible hRows.rightBulkValid hPair

/-- Validator-ready phantom left-bulk rows are replayed by primitive connect rows. -/
theorem validatorReady_phantomAdapter_leftBulk_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps :=
  (validatorReady_phantomBridgeBulkConnectionsReplayed
    hReady phantom hPhantom).left pair hPair

/-- Validator-ready phantom right-bulk rows are replayed by primitive connect rows. -/
theorem validatorReady_phantomAdapter_rightBulk_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps :=
  (validatorReady_phantomBridgeBulkConnectionsReplayed
    hReady phantom hPhantom).right pair hPair

/-- Validator-ready phantom left-bulk source exits are consumed by primitive replay. -/
theorem validatorReady_phantomAdapter_leftBulk_sourceConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.fromKey ∈
      PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps :=
  PrimitiveGraphStep.matchedConnectionsList_fromKey_mem_consumedExitKeysList
    (validatorReady_phantomAdapter_leftBulk_replayed hReady hPhantom hPair)

/-- Validator-ready phantom left-bulk target entries are consumed by primitive replay. -/
theorem validatorReady_phantomAdapter_leftBulk_targetConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.leftBulk) :
    pair.toKey ∈
      PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps :=
  PrimitiveGraphStep.matchedConnectionsList_toKey_mem_consumedEntryKeysList
    (validatorReady_phantomAdapter_leftBulk_replayed hReady hPhantom hPair)

/-- Validator-ready phantom right-bulk source exits are consumed by primitive replay. -/
theorem validatorReady_phantomAdapter_rightBulk_sourceConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.fromKey ∈
      PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps :=
  PrimitiveGraphStep.matchedConnectionsList_fromKey_mem_consumedExitKeysList
    (validatorReady_phantomAdapter_rightBulk_replayed hReady hPhantom hPair)

/-- Validator-ready phantom right-bulk target entries are consumed by primitive replay. -/
theorem validatorReady_phantomAdapter_rightBulk_targetConsumed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {pair : AdmissionConnection}
    (hPair : pair ∈ phantom.rightBulk) :
    pair.toKey ∈
      PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps :=
  PrimitiveGraphStep.matchedConnectionsList_toKey_mem_consumedEntryKeysList
    (validatorReady_phantomAdapter_rightBulk_replayed hReady hPhantom hPair)

/-- Validator-ready gather adapters consume every multi-side endpoint through a replayed row. -/
theorem validatorReady_phantomAdapter_gather_multiEndpoint_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    ∃ pair,
      pair ∈ phantom.leftBulk ∧
        pair.fromKey = boundary.key ∧
          pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps := by
  have hPerm :=
    validatorReady_phantomAdapter_gather_leftBulkSourceKeys_perm_multi
      hReady hPhantom hDirection
  have hKeyMem :
      boundary.key ∈ phantom.leftBulkSourceKeys := by
    exact hPerm.mem_iff.mpr (List.mem_map.mpr ⟨boundary, hBoundary, rfl⟩)
  unfold PhantomAdapterArtifact.leftBulkSourceKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , validatorReady_phantomAdapter_leftBulk_replayed hReady hPhantom hPair
    ⟩

/-- Validator-ready gather adapters consume the singular endpoint through a replayed row. -/
theorem validatorReady_phantomAdapter_gather_singularEndpoint_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.gather) :
    ∃ pair,
      pair ∈ phantom.rightBulk ∧
        pair.toKey = phantom.singular.key ∧
          pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps := by
  have hPerm :=
    validatorReady_phantomAdapter_gather_rightBulkTargetKeys_perm_singular
      hReady hPhantom hDirection
  have hKeyMem :
      phantom.singular.key ∈ phantom.rightBulkTargetKeys := by
    exact hPerm.mem_iff.mpr (by simp)
  unfold PhantomAdapterArtifact.rightBulkTargetKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , validatorReady_phantomAdapter_rightBulk_replayed hReady hPhantom hPair
    ⟩

/-- Validator-ready scatter adapters consume the singular endpoint through a replayed row. -/
theorem validatorReady_phantomAdapter_scatter_singularEndpoint_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter) :
    ∃ pair,
      pair ∈ phantom.leftBulk ∧
        pair.fromKey = phantom.singular.key ∧
          pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps := by
  have hPerm :=
    validatorReady_phantomAdapter_scatter_leftBulkSourceKeys_perm_singular
      hReady hPhantom hDirection
  have hKeyMem :
      phantom.singular.key ∈ phantom.leftBulkSourceKeys := by
    exact hPerm.mem_iff.mpr (by simp)
  unfold PhantomAdapterArtifact.leftBulkSourceKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , validatorReady_phantomAdapter_leftBulk_replayed hReady hPhantom hPair
    ⟩

/-- Validator-ready scatter adapters consume every multi-side endpoint through a replayed row. -/
theorem validatorReady_phantomAdapter_scatter_multiEndpoint_replayed
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    (hDirection : phantom.direction = PhantomAdapterDirection.scatter)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    ∃ pair,
      pair ∈ phantom.rightBulk ∧
        pair.toKey = boundary.key ∧
          pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps := by
  have hPerm :=
    validatorReady_phantomAdapter_scatter_rightBulkTargetKeys_perm_multi
      hReady hPhantom hDirection
  have hKeyMem :
      boundary.key ∈ phantom.rightBulkTargetKeys := by
    exact hPerm.mem_iff.mpr (List.mem_map.mpr ⟨boundary, hBoundary, rfl⟩)
  unfold PhantomAdapterArtifact.rightBulkTargetKeys at hKeyMem
  rcases List.mem_map.mp hKeyMem with ⟨pair, hPair, hKey⟩
  exact
    ⟨ pair
    , hPair
    , hKey
    , validatorReady_phantomAdapter_rightBulk_replayed hReady hPhantom hPair
    ⟩

/-- Validator-ready indexed phantom artifacts expose the serialized product count. -/
theorem validatorReady_phantomAdapter_indexed_multi_length_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count) :
    phantom.multi.length = count := by
  have hArity := validatorReady_phantomAdapter_productArityMatches hReady hPhantom
  unfold PhantomAdapterArtifact.ProductArityMatches at hArity
  rw [hShape] at hArity
  simpa [ProductShapeArtifact.arity] using hArity

/-- Validator-ready indexed phantom artifacts expose uniform multi-side element contracts. -/
theorem validatorReady_phantomAdapter_indexed_multi_contract_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    boundary.contract = element := by
  have hMatch := validatorReady_phantomAdapter_productShapeMatchesMulti hReady hPhantom
  unfold PhantomAdapterArtifact.ProductShapeMatchesMulti at hMatch
  rw [hShape] at hMatch
  exact hMatch boundary hBoundary

/-- Validator-ready indexed phantom artifacts expose valid element contracts. -/
theorem validatorReady_phantomAdapter_indexed_elementValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count) :
    element.Valid := by
  have hValid := validatorReady_phantomAdapter_productShape_valid hReady hPhantom
  rw [hShape] at hValid
  exact ProductShapeArtifact.valid_indexed_elementValid hValid

/-- Validator-ready indexed phantom artifacts reject nested indexed product elements. -/
theorem validatorReady_phantomAdapter_indexed_elementNominal
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count) :
    element.name.startsWith "[" = false := by
  have hValid := validatorReady_phantomAdapter_productShape_valid hReady hPhantom
  rw [hShape] at hValid
  exact ProductShapeArtifact.valid_indexed_elementNominal hValid

/-- Validator-ready indexed phantom artifacts expose duplicate-free multi compatibility keys. -/
theorem validatorReady_phantomAdapter_indexed_multiCompatibilityShapesUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count) :
    (phantom.multi.map AdmissionBoundaryPort.compatibilityShape).Nodup := by
  have hUnique :=
    validatorReady_phantomAdapter_indexedMultiCompatibilityKeysUnique hReady hPhantom
  unfold PhantomAdapterArtifact.IndexedMultiCompatibilityKeysUnique at hUnique
  rw [hShape] at hUnique
  exact hUnique

/-- Validator-ready phantom artifacts expose the singular endpoint's aggregate product contract. -/
theorem validatorReady_phantomAdapter_singular_contract_eq_product
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters) :
    phantom.singular.contract = phantom.productShape.contract :=
  validatorReady_phantomAdapter_productContractMatchesSingular hReady hPhantom

/-- Validator-ready indexed phantom artifacts expose the singular `[T; N]` contract. -/
theorem validatorReady_phantomAdapter_indexed_singular_contract_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {element : ContractId}
    {count : Nat}
    (hShape : phantom.productShape = ProductShapeArtifact.indexed element count) :
    phantom.singular.contract = ContractId.boundedIndexed element count := by
  have hContract :=
    validatorReady_phantomAdapter_singular_contract_eq_product hReady hPhantom
  rw [hShape] at hContract
  simpa [ProductShapeArtifact.contract] using hContract

/-- Validator-ready record phantom artifacts expose duplicate-free record field labels. -/
theorem validatorReady_phantomAdapter_record_fieldsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    (fields.map Prod.fst).Nodup := by
  have hValid := validatorReady_phantomAdapter_productShape_valid hReady hPhantom
  rw [hShape] at hValid
  exact ProductShapeArtifact.valid_record_fieldsUnique hValid

/-- Validator-ready record phantom artifacts expose validity of the aggregate contract row. -/
theorem validatorReady_phantomAdapter_record_contractValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    contract.Valid := by
  have hValid := validatorReady_phantomAdapter_productShape_valid hReady hPhantom
  rw [hShape] at hValid
  exact ProductShapeArtifact.valid_record_contractValid hValid

/-- Validator-ready record phantom artifacts expose the singular aggregate record contract. -/
theorem validatorReady_phantomAdapter_record_singular_contract_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    phantom.singular.contract = contract := by
  have hContract :=
    validatorReady_phantomAdapter_singular_contract_eq_product hReady hPhantom
  rw [hShape] at hContract
  simpa [ProductShapeArtifact.contract] using hContract

/-- Validator-ready record phantom artifacts expose validity of every field row. -/
theorem validatorReady_phantomAdapter_record_fieldValid
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields)
    {field : FieldLabel × ContractId}
    (hField : field ∈ fields) :
    field.fst.Valid ∧ field.snd.Valid := by
  have hValid := validatorReady_phantomAdapter_productShape_valid hReady hPhantom
  rw [hShape] at hValid
  exact ProductShapeArtifact.valid_record_fieldValid hValid hField

/-- Validator-ready record phantom artifacts expose serialized record arity. -/
theorem validatorReady_phantomAdapter_record_multi_length_eq
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    phantom.multi.length = fields.length := by
  have hArity := validatorReady_phantomAdapter_productArityMatches hReady hPhantom
  unfold PhantomAdapterArtifact.ProductArityMatches at hArity
  rw [hShape] at hArity
  simpa [ProductShapeArtifact.arity] using hArity

/-- Validator-ready record phantom artifacts expose the multi-side record-field projection. -/
theorem validatorReady_phantomAdapter_record_multi_fields_perm
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    (phantom.multi.filterMap AdmissionBoundaryPort.recordField).Perm fields := by
  have hMatch := validatorReady_phantomAdapter_productShapeMatchesMulti hReady hPhantom
  unfold PhantomAdapterArtifact.ProductShapeMatchesMulti at hMatch
  rw [hShape] at hMatch
  simpa [ProductShapeArtifact.BoundariesMatch] using hMatch

/-- Validator-ready record phantom artifacts expose duplicate-free projected multi labels. -/
theorem validatorReady_phantomAdapter_record_multi_fieldLabelsUnique
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields) :
    ((phantom.multi.filterMap AdmissionBoundaryPort.recordField).map Prod.fst).Nodup := by
  have hFieldsUnique :=
    validatorReady_phantomAdapter_record_fieldsUnique hReady hPhantom hShape
  have hPerm :=
    validatorReady_phantomAdapter_record_multi_fields_perm hReady hPhantom hShape
  exact (hPerm.map Prod.fst).nodup_iff.mpr hFieldsUnique

/-- Validator-ready record phantom artifacts expose a field row for every multi endpoint. -/
theorem validatorReady_phantomAdapter_record_multi_boundary_field_mem
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    ∃ field,
      boundary.recordField = some field ∧ field ∈ fields := by
  have hLength :=
    validatorReady_phantomAdapter_record_multi_length_eq hReady hPhantom hShape
  have hPerm :=
    validatorReady_phantomAdapter_record_multi_fields_perm hReady hPhantom hShape
  have hProjectedLength :
      (phantom.multi.filterMap AdmissionBoundaryPort.recordField).length =
        phantom.multi.length := by
    rw [hPerm.length_eq, hLength]
  obtain ⟨field, hField⟩ :=
    exists_some_of_filterMap_length_eq hProjectedLength hBoundary
  have hProjected :
      field ∈ phantom.multi.filterMap AdmissionBoundaryPort.recordField :=
    List.mem_filterMap.mpr ⟨boundary, hBoundary, hField⟩
  exact ⟨field, hField, hPerm.mem_iff.mp hProjected⟩

/-- Validator-ready record phantom multi endpoints are labeled by declared record fields. -/
theorem validatorReady_phantomAdapter_record_multi_boundary_labeled
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady)
    {phantom : PhantomAdapterArtifact}
    (hPhantom : phantom ∈ artifact.phantomAdapters)
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hShape : phantom.productShape = ProductShapeArtifact.record contract fields)
    {boundary : AdmissionBoundaryPort}
    (hBoundary : boundary ∈ phantom.multi) :
    ∃ label,
      boundary.label = AdmissionPortLabel.label label ∧
        (label, boundary.contract) ∈ fields := by
  obtain ⟨field, hField, hFieldMem⟩ :=
    validatorReady_phantomAdapter_record_multi_boundary_field_mem
      hReady hPhantom hShape hBoundary
  cases hLabel : boundary.label with
  | noLabel =>
      simp [AdmissionBoundaryPort.recordField, hLabel] at hField
  | label label =>
      simp [AdmissionBoundaryPort.recordField, hLabel] at hField
      exact ⟨label, rfl, by simpa [hField] using hFieldMem⟩

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
