import Cortex.Wire.AdmissionArtifact.Primitive

/-!
## Overview

Phantom-adapter artifact rows for decoded Wire admission artifacts.

This page models the persisted shape of generated `*` adapters: record and
bounded-indexed product rows, gather/scatter direction, multi/singular
boundaries, and the two primitive bulk-contraction ledgers.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Phantom Adapter Artifacts -/

/-- Product shape serialized for a phantom adapter. -/
inductive ProductShapeArtifact where
  | record (contract : ContractId) (fields : List (FieldLabel × ContractId))
  | indexed (elementContract : ContractId) (count : Nat)
  deriving Repr

namespace ProductShapeArtifact

/-- Number of immediate product leaves named by the serialized shape. -/
def arity : ProductShapeArtifact → Nat
  | .record _ fields => fields.length
  | .indexed _ count => count

/-- Aggregate contract named by the singular side of the serialized product. -/
def contract : ProductShapeArtifact → ContractId
  | .record contract _ => contract
  | .indexed element count => ContractId.boundedIndexed element count

/-- Record-shaped products serialize deterministic field rows and must not repeat field labels. -/
def FieldLabelsUnique : ProductShapeArtifact → Prop
  | .record _ fields => (fields.map Prod.fst).Nodup
  | .indexed _ _ => True

/-- Product-shape contract rows carry valid field labels and contract identifiers. -/
def RowsValid : ProductShapeArtifact → Prop
  | .record contract fields =>
      contract.Valid ∧
        ∀ field, field ∈ fields → field.fst.Valid ∧ field.snd.Valid
  | .indexed elementContract _count => elementContract.Valid

/-- Indexed product elements are not another serialized `[T; N]`.

The executable grammar accepts an identifier in the element position of
`[T; N]`. This artifact predicate mirrors the nested-product part of that
boundary by rejecting rows whose element text already starts with the
indexed-product delimiter. Full source-identifier grammar remains outside the
non-empty nominal-name approximation used by this proof layer. -/
def IndexedElementNominal : ProductShapeArtifact → Prop
  | .record _ _ => True
  | .indexed elementContract _count => elementContract.name.startsWith "[" = false

/-- A serialized multi-side frontier has the field/contract shape claimed by the product row.

Record rows are compared by permutation because Haskell emits deterministic map order while the
source-facing contract is field-label exactness, not source-order preservation. -/
def BoundariesMatch : ProductShapeArtifact → List AdmissionBoundaryPort → Prop
  | .record _ fields, multi =>
      (multi.filterMap AdmissionBoundaryPort.recordField).Perm fields
  | .indexed elementContract _count, multi =>
      ∀ boundary, boundary ∈ multi → boundary.contract = elementContract

/-- Row-level validator obligation for serialized product shapes. -/
structure Valid (shape : ProductShapeArtifact) : Prop where
  fieldLabelsUnique : shape.FieldLabelsUnique
  rowsValid : shape.RowsValid
  indexedElementNominal : shape.IndexedElementNominal

@[simp]
theorem arity_record (contract : ContractId) (fields : List (FieldLabel × ContractId)) :
    (ProductShapeArtifact.record contract fields).arity = fields.length :=
  rfl

@[simp]
theorem arity_indexed (elementContract : ContractId) (count : Nat) :
    (ProductShapeArtifact.indexed elementContract count).arity = count :=
  rfl

@[simp]
theorem contract_record (contract : ContractId) (fields : List (FieldLabel × ContractId)) :
    (ProductShapeArtifact.record contract fields).contract = contract :=
  rfl

@[simp]
theorem contract_indexed (elementContract : ContractId) (count : Nat) :
    (ProductShapeArtifact.indexed elementContract count).contract =
      ContractId.boundedIndexed elementContract count :=
  rfl

/-- Valid record-shaped products expose duplicate-free field labels. -/
theorem valid_record_fieldsUnique
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hValid : (ProductShapeArtifact.record contract fields).Valid) :
    (fields.map Prod.fst).Nodup :=
  hValid.fieldLabelsUnique

/-- Valid record-shaped products expose validity for the aggregate contract row. -/
theorem valid_record_contractValid
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hValid : (ProductShapeArtifact.record contract fields).Valid) :
    contract.Valid :=
  hValid.rowsValid.left

/-- Valid record-shaped products expose validity for every field row. -/
theorem valid_record_fieldValid
    {contract : ContractId}
    {fields : List (FieldLabel × ContractId)}
    (hValid : (ProductShapeArtifact.record contract fields).Valid)
    {field : FieldLabel × ContractId}
    (hField : field ∈ fields) :
    field.fst.Valid ∧ field.snd.Valid :=
  hValid.rowsValid.right field hField

/-- Valid indexed products expose validity of the element contract row. -/
theorem valid_indexed_elementValid
    {element : ContractId}
    {count : Nat}
    (hValid : (ProductShapeArtifact.indexed element count).Valid) :
    element.Valid :=
  hValid.rowsValid

/-- Valid indexed products expose that their element is not another `[T; N]`. -/
theorem valid_indexed_elementNominal
    {element : ContractId}
    {count : Nat}
    (hValid : (ProductShapeArtifact.indexed element count).Valid) :
    element.name.startsWith "[" = false :=
  hValid.indexedElementNominal

/-- Valid product shapes expose validity of the serialized aggregate contract. -/
theorem valid_contractValid
    {shape : ProductShapeArtifact}
    (hValid : shape.Valid) :
    shape.contract.Valid := by
  cases shape with
  | record contract fields =>
      exact ProductShapeArtifact.valid_record_contractValid hValid
  | indexed element count =>
      simp [ProductShapeArtifact.contract, ContractId.Valid, NominalNameValid,
        ContractId.boundedIndexed]

end ProductShapeArtifact

/-- Direction serialized for a phantom adapter artifact. -/
inductive PhantomAdapterDirection where
  | gather
  | scatter
  deriving Repr

/-- Phantom-adapter artifact row emitted for one generated `*` adapter. -/
structure PhantomAdapterArtifact where
  direction : PhantomAdapterDirection
  node : NodeId
  productShape : ProductShapeArtifact
  singular : AdmissionBoundaryPort
  multi : List AdmissionBoundaryPort
  leftBulk : List AdmissionConnection
  rightBulk : List AdmissionConnection
  deriving Repr

namespace PhantomAdapterArtifact

/-- Nodes on the serialized multi-side boundary. -/
def multiNodes (artifact : PhantomAdapterArtifact) : List NodeId :=
  artifact.multi.map AdmissionBoundaryPort.node

/-- Source nodes of the left bulk contraction ledger. -/
def leftBulkSources (artifact : PhantomAdapterArtifact) : List NodeId :=
  artifact.leftBulk.map AdmissionConnection.fromNode

/-- Source endpoint keys of the left bulk contraction ledger. -/
def leftBulkSourceKeys
    (artifact : PhantomAdapterArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  artifact.leftBulk.map AdmissionConnection.fromKey

/-- Target nodes of the left bulk contraction ledger. -/
def leftBulkTargets (artifact : PhantomAdapterArtifact) : List NodeId :=
  artifact.leftBulk.map AdmissionConnection.toNode

/-- Target endpoint keys of the left bulk contraction ledger. -/
def leftBulkTargetKeys
    (artifact : PhantomAdapterArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  artifact.leftBulk.map AdmissionConnection.toKey

/-- Source nodes of the right bulk contraction ledger. -/
def rightBulkSources (artifact : PhantomAdapterArtifact) : List NodeId :=
  artifact.rightBulk.map AdmissionConnection.fromNode

/-- Source endpoint keys of the right bulk contraction ledger. -/
def rightBulkSourceKeys
    (artifact : PhantomAdapterArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  artifact.rightBulk.map AdmissionConnection.fromKey

/-- Target nodes of the right bulk contraction ledger. -/
def rightBulkTargets (artifact : PhantomAdapterArtifact) : List NodeId :=
  artifact.rightBulk.map AdmissionConnection.toNode

/-- Target endpoint keys of the right bulk contraction ledger. -/
def rightBulkTargetKeys
    (artifact : PhantomAdapterArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  artifact.rightBulk.map AdmissionConnection.toKey

/-- The serialized multi-side boundary has the product arity stated by the shape row.

This is a validator obligation, not a proof term embedded in the artifact. -/
def ProductArityMatches (artifact : PhantomAdapterArtifact) : Prop :=
  artifact.multi.length = artifact.productShape.arity

/-- The serialized multi-side boundary has the field/contract shape stated by the product row. -/
def ProductShapeMatchesMulti (artifact : PhantomAdapterArtifact) : Prop :=
  artifact.productShape.BoundariesMatch artifact.multi

/-- The singular endpoint names the aggregate contract stated by the product row. -/
def ProductContractMatchesSingular (artifact : PhantomAdapterArtifact) : Prop :=
  artifact.singular.contract = artifact.productShape.contract

/-- Serialized multi-side endpoints are unique by source boundary identity. -/
def MultiEndpointKeysUnique (artifact : PhantomAdapterArtifact) : Prop :=
  (artifact.multi.map AdmissionBoundaryPort.key).Nodup

/-- Indexed multi-side endpoints are unique by the compatibility key `=>` consumes.

Primitive replay also rejects ambiguous duplicate `(label, contract)` rows, but
the phantom row names the obligation directly so witness consumers do not need
to recover indexed endpoint uniqueness from a later connect trace. -/
def IndexedMultiCompatibilityKeysUnique (artifact : PhantomAdapterArtifact) : Prop :=
  match artifact.productShape with
  | ProductShapeArtifact.record _ _ => True
  | ProductShapeArtifact.indexed _ _ =>
      (artifact.multi.map AdmissionBoundaryPort.compatibilityShape).Nodup

/-- Serialized bulk contractions match the declared phantom direction.

The artifact does not serialize the generated phantom node's full frontier, so
this row-level check pins only the source/sink sides that are present in the
row: gather consumes multi-side inputs and produces the singular endpoint;
scatter consumes the singular endpoint and produces multi-side outputs. -/
def BulkEndpointsMatch (artifact : PhantomAdapterArtifact) : Prop :=
  match artifact.direction with
  | .gather =>
      (∀ pair, pair ∈ artifact.leftBulk →
          pair.fromPort ∈ artifact.multi ∧ pair.toPort.node = artifact.node) ∧
      (∀ pair, pair ∈ artifact.rightBulk →
          pair.fromPort.node = artifact.node ∧ pair.toPort = artifact.singular)
  | .scatter =>
      (∀ pair, pair ∈ artifact.leftBulk →
          pair.fromPort = artifact.singular ∧ pair.toPort.node = artifact.node) ∧
      (∀ pair, pair ∈ artifact.rightBulk →
          pair.fromPort.node = artifact.node ∧ pair.toPort ∈ artifact.multi)

/-- Serialized bulk contractions cover the source-visible multi/singular endpoints exactly. -/
def BulkEndpointPartition (artifact : PhantomAdapterArtifact) : Prop :=
  match artifact.direction with
  | .gather =>
      artifact.leftBulkSourceKeys.Perm
        (artifact.multi.map AdmissionBoundaryPort.key) ∧
      artifact.rightBulkTargetKeys.Perm [artifact.singular.key]
  | .scatter =>
      artifact.leftBulkSourceKeys.Perm [artifact.singular.key] ∧
      artifact.rightBulkTargetKeys.Perm
        (artifact.multi.map AdmissionBoundaryPort.key)

/-- Phantom-adapter rows carry valid node, boundary, and bulk connection identities. -/
structure RowsValid (artifact : PhantomAdapterArtifact) : Prop where
  nodeValid : artifact.node.Valid
  singularValid : artifact.singular.Valid
  multiValid : BoundaryPortsValid artifact.multi
  leftBulkValid : ConnectionsValid artifact.leftBulk
  rightBulkValid : ConnectionsValid artifact.rightBulk

/-- Phantom-adapter rows mention only nodes in the top-level summary. -/
structure DomainClosed (nodes : List NodeId) (artifact : PhantomAdapterArtifact) : Prop where
  nodeClosed : artifact.node ∈ nodes
  singularNodeClosed : artifact.singular.node ∈ nodes
  multiClosed : BoundaryPortsClosed nodes artifact.multi
  leftBulkClosed : ConnectionsClosed nodes artifact.leftBulk
  rightBulkClosed : ConnectionsClosed nodes artifact.rightBulk

/-- Row-level validator obligation for a phantom-adapter artifact. -/
structure Valid (artifact : PhantomAdapterArtifact) : Prop where
  productShapeValid : artifact.productShape.Valid
  productArityMatches : artifact.ProductArityMatches
  productShapeMatchesMulti : artifact.ProductShapeMatchesMulti
  productContractMatchesSingular : artifact.ProductContractMatchesSingular
  multiEndpointKeysUnique : artifact.MultiEndpointKeysUnique
  bulkEndpointsMatch : artifact.BulkEndpointsMatch
  bulkEndpointPartition : artifact.BulkEndpointPartition
  indexedMultiCompatibilityKeysUnique : artifact.IndexedMultiCompatibilityKeysUnique
  rowsValid : artifact.RowsValid

end PhantomAdapterArtifact

end AdmissionArtifact
end Cortex.Wire
