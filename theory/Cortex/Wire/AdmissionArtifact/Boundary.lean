import Cortex.Wire.ElaborationIR

/-!
## Overview

Shared boundary rows for decoded Wire admission artifacts.

This page contains schema-version constants, serialized boundary endpoints,
raw connection rows, and list-level closure/validity predicates used by the
primitive, generated, phantom, select, and validator artifact modules.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Schema Version -/

/-- Schema version emitted by the current Haskell admission artifact encoder. -/
def currentSchemaVersion : Nat := 3

/-! ## Shared Boundary Rows -/

/-- Optional label attached to a serialized boundary port. -/
inductive AdmissionPortLabel where
  | noLabel
  | label (label : FieldLabel)
  deriving DecidableEq, Repr

namespace AdmissionPortLabel

/-- Optional serialized labels are valid when every present label is non-empty. -/
def Valid : AdmissionPortLabel → Prop
  | .noLabel => True
  | .label portLabel => portLabel.Valid

end AdmissionPortLabel

/-- Boundary-port row emitted by the compiler artifact. -/
structure AdmissionBoundaryPort where
  node : NodeId
  port : FieldLabel
  contract : ContractId
  label : AdmissionPortLabel
  exclusiveGroup : Option (NodeId × Nat)
  deriving DecidableEq, Repr

namespace AdmissionBoundaryPort

/-- Identity key for a serialized boundary endpoint. -/
def key (boundary : AdmissionBoundaryPort) : NodeId × FieldLabel × ContractId :=
  (boundary.node, boundary.port, boundary.contract)

/-- Compatibility shape for a boundary endpoint, ignoring local node and port names. -/
def compatibilityShape (boundary : AdmissionBoundaryPort) : AdmissionPortLabel × ContractId :=
  (boundary.label, boundary.contract)

/-- Source-visible output shape, preserving the local exclusive-group index when present. -/
def outputShape (boundary : AdmissionBoundaryPort) :
    AdmissionPortLabel × ContractId × Option Nat :=
  (boundary.label, boundary.contract, boundary.exclusiveGroup.map Prod.snd)

/-- Output shape produced by an identity select arm for a selected variant. -/
def identityOutputShape (boundary : AdmissionBoundaryPort) :
    AdmissionPortLabel × ContractId × Option Nat :=
  (boundary.label, boundary.contract, none)

/-- Two boundary endpoints are compatible when Wire `=>` may contract them. -/
def CompatibleWith (fromPort toPort : AdmissionBoundaryPort) : Prop :=
  fromPort.label = toPort.label ∧ fromPort.contract = toPort.contract

/-- Boundary compatibility is decidable because serialized labels and contracts are decidable. -/
instance instDecidableCompatibleWith
    (fromPort toPort : AdmissionBoundaryPort) :
    Decidable (fromPort.CompatibleWith toPort) := by
  unfold CompatibleWith
  infer_instance

/-- Serialized boundary endpoints must carry valid node, port, contract, and label identities. -/
def Valid (boundary : AdmissionBoundaryPort) : Prop :=
  boundary.node.Valid ∧
    boundary.port.Valid ∧
    boundary.contract.Valid ∧
    boundary.label.Valid ∧
    match boundary.exclusiveGroup with
    | none => True
    | some (owner, _index) => owner = boundary.node ∧ owner.Valid

/-- Serialized exclusive-group owner rows are node-local. -/
def ExclusiveGroupOwnerLocal (boundary : AdmissionBoundaryPort) : Prop :=
  match boundary.exclusiveGroup with
  | none => True
  | some (owner, _index) => owner = boundary.node

/-- Valid boundary rows expose node-local exclusive-group owners. -/
theorem valid_exclusiveGroupOwnerLocal
    {boundary : AdmissionBoundaryPort}
    (hValid : boundary.Valid) :
    boundary.ExclusiveGroupOwnerLocal := by
  cases hGroup : boundary.exclusiveGroup with
  | none =>
      simp [ExclusiveGroupOwnerLocal, hGroup]
  | some group =>
      have hOwner := hValid.right.right.right.right
      rw [hGroup] at hOwner
      simpa [ExclusiveGroupOwnerLocal, hGroup] using hOwner.left

/-- Valid boundary rows expose valid endpoint contract identifiers. -/
theorem valid_contractValid
    {boundary : AdmissionBoundaryPort}
    (hValid : boundary.Valid) :
    boundary.contract.Valid :=
  hValid.right.right.left

/-- Boundary rows are closed over a node summary when both their endpoint node and
optional exclusive-group owner are present. -/
def ClosedOver (nodes : List NodeId) (boundary : AdmissionBoundaryPort) : Prop :=
  boundary.node ∈ nodes ∧
    match boundary.exclusiveGroup with
    | none => True
    | some (owner, _index) => owner ∈ nodes

/-- Label-first select key exposed by a serialized boundary endpoint. -/
def selectKey (boundary : AdmissionBoundaryPort) : FieldLabel :=
  match boundary.label with
  | .noLabel => ⟨boundary.contract.name⟩
  | .label label => label

end AdmissionBoundaryPort

/-- Serialized source-level connection between two boundary ports. -/
structure AdmissionConnection where
  fromPort : AdmissionBoundaryPort
  toPort : AdmissionBoundaryPort
  deriving DecidableEq, Repr

namespace AdmissionConnection

/-- Source node of a serialized boundary contraction. -/
def fromNode (connection : AdmissionConnection) : NodeId :=
  connection.fromPort.node

/-- Target node of a serialized boundary contraction. -/
def toNode (connection : AdmissionConnection) : NodeId :=
  connection.toPort.node

/-- Source endpoint key of a serialized boundary contraction. -/
def fromKey (connection : AdmissionConnection) : NodeId × FieldLabel × ContractId :=
  connection.fromPort.key

/-- Target endpoint key of a serialized boundary contraction. -/
def toKey (connection : AdmissionConnection) : NodeId × FieldLabel × ContractId :=
  connection.toPort.key

/-- Boundary contractions connect endpoints with the same source-visible label and contract. -/
def BoundaryCompatible (connection : AdmissionConnection) : Prop :=
  connection.fromPort.CompatibleWith connection.toPort

/-- Serialized connections are valid when both endpoint rows are valid and compatible. -/
def Valid (connection : AdmissionConnection) : Prop :=
  connection.fromPort.Valid ∧ connection.toPort.Valid ∧ connection.BoundaryCompatible

/-- Valid serialized connections expose source-visible boundary compatibility. -/
theorem valid_boundaryCompatible
    {connection : AdmissionConnection}
    (hValid : connection.Valid) :
    connection.BoundaryCompatible :=
  hValid.right.right

end AdmissionConnection

/-- Record-field view of a labeled boundary endpoint, if it carries a field label. -/
def AdmissionBoundaryPort.recordField
    (boundary : AdmissionBoundaryPort) :
    Option (FieldLabel × ContractId) :=
  match boundary.label with
  | .noLabel => none
  | .label label => some (label, boundary.contract)

theorem filterMap_length_le
    {α β : Type}
    (f : α → Option β)
    (items : List α) :
    (items.filterMap f).length ≤ items.length := by
  induction items with
  | nil =>
      simp
  | cons item rest ih =>
      cases hItem : f item with
      | none =>
          simp [List.filterMap_cons_none, hItem, Nat.le_trans ih (Nat.le_succ rest.length)]
      | some value =>
          simp [List.filterMap_cons_some, hItem, Nat.succ_le_succ ih]

theorem exists_some_of_filterMap_length_eq
    {α β : Type}
    {f : α → Option β}
    {items : List α}
    (hLength : (items.filterMap f).length = items.length)
    {item : α}
    (hItem : item ∈ items) :
    ∃ value, f item = some value := by
  induction items with
  | nil =>
      cases hItem
  | cons head tail ih =>
      cases hHead : f head with
      | none =>
          have hLe := filterMap_length_le f tail
          have hBad : (tail.filterMap f).length = Nat.succ tail.length := by
            simpa [List.filterMap_cons_none, hHead] using hLength
          have hImpossible : Nat.succ tail.length ≤ tail.length := by
            rw [← hBad]
            exact hLe
          exact False.elim (Nat.not_succ_le_self tail.length hImpossible)
      | some value =>
          rw [List.mem_cons] at hItem
          rcases hItem with hEq | hTail
          · subst item
            exact ⟨value, hHead⟩
          · have hTailLength : (tail.filterMap f).length = tail.length := by
              apply Nat.succ.inj
              simpa [List.filterMap_cons_some, hHead] using hLength
            exact ih hTailLength hTail

theorem exists_append_singleton_of_mem
    {α : Type}
    {item : α}
    {items : List α}
    (hItem : item ∈ items) :
    ∃ before after, items = before ++ [item] ++ after := by
  induction items with
  | nil =>
      cases hItem
  | cons head tail ih =>
      rw [List.mem_cons] at hItem
      cases hItem with
      | inl hHead =>
          subst item
          exact ⟨[], tail, by simp⟩
      | inr hTail =>
          obtain ⟨before, after, hTailEq⟩ := ih hTail
          exact ⟨head :: before, after, by simp [hTailEq]⟩

/-- Every boundary row in a list is structurally valid. -/
def BoundaryPortsValid (ports : List AdmissionBoundaryPort) : Prop :=
  ∀ port, port ∈ ports → port.Valid

/-- Every serialized connection row in a list is structurally valid. -/
def ConnectionsValid (connections : List AdmissionConnection) : Prop :=
  ∀ connection, connection ∈ connections → connection.Valid

/-- Valid serialized connection lists expose compatibility for every connection row. -/
theorem connectionsValid_boundaryCompatible
    {connections : List AdmissionConnection}
    (hValid : ConnectionsValid connections)
    {connection : AdmissionConnection}
    (hConnection : connection ∈ connections) :
    connection.BoundaryCompatible :=
  AdmissionConnection.valid_boundaryCompatible (hValid connection hConnection)

/-- Every serialized boundary row and its optional exclusive-group owner belong to
the node summary. -/
def BoundaryPortsClosed (nodes : List NodeId) (ports : List AdmissionBoundaryPort) : Prop :=
  ∀ port, port ∈ ports → port.ClosedOver nodes

/-- Every serialized connection row endpoint is closed over the given node summary. -/
def ConnectionsClosed (nodes : List NodeId) (connections : List AdmissionConnection) : Prop :=
  ∀ connection, connection ∈ connections →
    connection.fromPort.ClosedOver nodes ∧ connection.toPort.ClosedOver nodes

/-- Raw compiled endpoint reference emitted in the top-level connection ledger. -/
structure AdmissionEndpointRef where
  node : NodeId
  port : Option FieldLabel
  deriving DecidableEq, Repr

namespace AdmissionEndpointRef

/-- Raw connection endpoints must carry a valid node and any present port name. -/
def Valid (endpoint : AdmissionEndpointRef) : Prop :=
  endpoint.node.Valid ∧
    match endpoint.port with
    | none => True
    | some port => port.Valid

/-- Boundary-row projection used by Haskell's top-level raw connection ledger. -/
def ofBoundary (boundary : AdmissionBoundaryPort) : AdmissionEndpointRef :=
  { node := boundary.node, port := some boundary.port }

end AdmissionEndpointRef

/-- Raw compiled connection emitted by the top-level artifact summary. -/
structure AdmissionRawConnection where
  fromEndpoint : AdmissionEndpointRef
  toEndpoint : AdmissionEndpointRef
  deriving DecidableEq, Repr

namespace AdmissionRawConnection

/-- Boundary-contraction projection used by Haskell's top-level raw connection ledger. -/
def ofAdmissionConnection (connection : AdmissionConnection) : AdmissionRawConnection :=
  { fromEndpoint := AdmissionEndpointRef.ofBoundary connection.fromPort
  , toEndpoint := AdmissionEndpointRef.ofBoundary connection.toPort
  }

/-- Raw summary connections are valid when both endpoint refs are valid. -/
def Valid (connection : AdmissionRawConnection) : Prop :=
  connection.fromEndpoint.Valid ∧ connection.toEndpoint.Valid

end AdmissionRawConnection

end AdmissionArtifact
end Cortex.Wire
