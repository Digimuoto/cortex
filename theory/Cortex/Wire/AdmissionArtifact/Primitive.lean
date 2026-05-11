import Cortex.Wire.AdmissionArtifact.Boundary

/-!
## Overview

Primitive graph-step rows for decoded Wire admission artifacts.

The declarations here mirror the Haskell primitive admission trace: empty,
node, binding-reference, overlay, and connect rows plus their local validator
obligations and row-level projection lemmas.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Primitive Graph Steps -/

/-- Primitive graph-admission step recorded by Haskell lowering. -/
inductive PrimitiveGraphStep where
  | empty
  | node
      (node : NodeId)
      (entries exits : List AdmissionBoundaryPort)
  | bindingRef (binding : BindingName)
  | overlay
      (leftNodes rightNodes : List NodeId)
      (leftBindings rightBindings : List BindingName)
  | connect
      (leftExits rightEntries : List AdmissionBoundaryPort)
      (matchedPairs : List AdmissionConnection)
      (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort)
  deriving Repr

namespace PrimitiveGraphStep

/-- Primitive node boundary rows are owned by the node row that serializes them. -/
def NodeFrontiersOwned
    (node : NodeId)
    (entries exits : List AdmissionBoundaryPort) :
    Prop :=
  (∀ entry, entry ∈ entries → entry.node = node) ∧
    (∀ exit, exit ∈ exits → exit.node = node)

/-- Primitive node frontier rows do not duplicate boundary identities. -/
def NodeFrontiersLinear
    (entries exits : List AdmissionBoundaryPort) :
    Prop :=
  (entries.map AdmissionBoundaryPort.key).Nodup ∧
    (exits.map AdmissionBoundaryPort.key).Nodup

/-- Primitive overlay side ledgers are duplicate-free before they are merged. -/
def OverlayLedgersUnique
    (leftNodes rightNodes : List NodeId)
    (leftBindings rightBindings : List BindingName) :
    Prop :=
  leftNodes.Nodup ∧ rightNodes.Nodup ∧ leftBindings.Nodup ∧ rightBindings.Nodup

/-- Primitive overlay rows must keep left/right node and binding ledgers disjoint. -/
def OverlayLedgersDisjoint
    (leftNodes rightNodes : List NodeId)
    (leftBindings rightBindings : List BindingName) :
    Prop :=
  (∀ node, node ∈ leftNodes → node ∈ rightNodes → False) ∧
    (∀ binding, binding ∈ leftBindings → binding ∈ rightBindings → False)

/-- Matched primitive connect rows cannot reuse an output endpoint or input endpoint. -/
def ConnectPairsLinear (matchedPairs : List AdmissionConnection) : Prop :=
  (matchedPairs.map AdmissionConnection.fromKey).Nodup ∧
    (matchedPairs.map AdmissionConnection.toKey).Nodup

/-- Serialized primitive connect frontiers do not contain duplicate endpoint keys. -/
def ConnectFrontiersLinear
    (leftExits rightEntries : List AdmissionBoundaryPort) :
    Prop :=
  (leftExits.map AdmissionBoundaryPort.key).Nodup ∧
    (rightEntries.map AdmissionBoundaryPort.key).Nodup

/-- Matched and unmatched primitive connect rows partition the serialized frontiers exactly. -/
def ConnectFrontierPartition
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Prop :=
  ((matchedPairs.map AdmissionConnection.fromKey) ++
      (unmatchedLeftExits.map AdmissionBoundaryPort.key)).Perm
    (leftExits.map AdmissionBoundaryPort.key) ∧
  ((matchedPairs.map AdmissionConnection.toKey) ++
      (unmatchedRightEntries.map AdmissionBoundaryPort.key)).Perm
    (rightEntries.map AdmissionBoundaryPort.key)

/-- Every compatible left/right frontier pair is present in the matched-pair ledger. -/
def ConnectMatchesAllCompatible
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection) :
    Prop :=
  ∀ leftExit, leftExit ∈ leftExits →
    ∀ rightEntry, rightEntry ∈ rightEntries →
      leftExit.CompatibleWith rightEntry →
        ∃ pair, pair ∈ matchedPairs ∧
          pair.fromPort = leftExit ∧ pair.toPort = rightEntry

/-- Primitive connect rows carry structurally valid frontiers and contraction rows. -/
def ConnectRowsValid
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Prop :=
  BoundaryPortsValid leftExits ∧
    BoundaryPortsValid rightEntries ∧
    ConnectionsValid matchedPairs ∧
    BoundaryPortsValid unmatchedLeftExits ∧
    BoundaryPortsValid unmatchedRightEntries

/-- Top-level raw connections projected from this primitive trace row. -/
def rawConnections : PrimitiveGraphStep → List AdmissionRawConnection
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries _exits => []
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      matchedPairs.map AdmissionRawConnection.ofAdmissionConnection

/-- Boundary contractions serialized by this primitive trace row. -/
def matchedConnections : PrimitiveGraphStep → List AdmissionConnection
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries _exits => []
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      matchedPairs

/-- Top-level node summary rows projected from this primitive trace row. -/
def nodeRows : PrimitiveGraphStep → List NodeId
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node nodeId _entries _exits => [nodeId]
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries => []

/-- Top-level binding-ref summary rows projected from this primitive trace row. -/
def bindingRows : PrimitiveGraphStep → List BindingName
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries _exits => []
  | PrimitiveGraphStep.bindingRef binding => [binding]
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries => []

/-- Primitive node entry boundary keys projected from this trace row. -/
def nodeEntryKeys : PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node entries _exits =>
      entries.map AdmissionBoundaryPort.key
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries => []

/-- Primitive node exit boundary keys projected from this trace row. -/
def nodeExitKeys : PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries exits =>
      exits.map AdmissionBoundaryPort.key
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries => []

/-- Input boundary keys consumed by primitive connect rows. -/
def consumedEntryKeys : PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries _exits => []
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      matchedPairs.map AdmissionConnection.toKey

/-- Output boundary keys consumed by primitive connect rows. -/
def consumedExitKeys : PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | PrimitiveGraphStep.empty => []
  | PrimitiveGraphStep.node _node _entries _exits => []
  | PrimitiveGraphStep.bindingRef _binding => []
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings => []
  | PrimitiveGraphStep.connect _leftExits _rightEntries matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      matchedPairs.map AdmissionConnection.fromKey

/-- Top-level raw connections projected from a list of primitive trace rows. -/
def rawConnectionsList : List PrimitiveGraphStep → List AdmissionRawConnection
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.rawConnections ++ rawConnectionsList primitiveSteps

/-- Boundary contractions projected from a list of primitive trace rows. -/
def matchedConnectionsList : List PrimitiveGraphStep → List AdmissionConnection
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.matchedConnections ++ matchedConnectionsList primitiveSteps

/-- Primitive raw connections are exactly the raw projection of matched contractions. -/
theorem rawConnectionsList_eq_map_matchedConnectionsList
    (primitiveSteps : List PrimitiveGraphStep) :
    rawConnectionsList primitiveSteps =
      (matchedConnectionsList primitiveSteps).map
        AdmissionRawConnection.ofAdmissionConnection := by
  induction primitiveSteps with
  | nil =>
      rfl
  | cons primitiveStep primitiveSteps ih =>
      cases primitiveStep with
      | empty =>
          simp [rawConnectionsList, matchedConnectionsList, rawConnections,
            matchedConnections, ih]
      | node node entries exits =>
          simp [rawConnectionsList, matchedConnectionsList, rawConnections,
            matchedConnections, ih]
      | bindingRef binding =>
          simp [rawConnectionsList, matchedConnectionsList, rawConnections,
            matchedConnections, ih]
      | overlay leftNodes rightNodes leftBindings rightBindings =>
          simp [rawConnectionsList, matchedConnectionsList, rawConnections,
            matchedConnections, ih]
      | connect leftExits rightEntries matchedPairs unmatchedLeftExits
          unmatchedRightEntries =>
          simp [rawConnectionsList, matchedConnectionsList, rawConnections,
            matchedConnections, ih, List.map_append]

/-- Top-level node summary rows projected from a list of primitive trace rows. -/
def nodeRowsList : List PrimitiveGraphStep → List NodeId
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.nodeRows ++ nodeRowsList primitiveSteps

/-- Top-level binding-ref summary rows projected from a list of primitive trace rows. -/
def bindingRowsList : List PrimitiveGraphStep → List BindingName
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.bindingRows ++ bindingRowsList primitiveSteps

/-- Primitive node rows contribute their node identity to the primitive node-row ledger. -/
theorem nodeRowsList_mem_of_node_mem
    {primitiveSteps : List PrimitiveGraphStep}
    {node : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hStep : PrimitiveGraphStep.node node entries exits ∈ primitiveSteps) :
    node ∈ nodeRowsList primitiveSteps := by
  induction primitiveSteps with
  | nil =>
      cases hStep
  | cons primitiveStep primitiveSteps ih =>
      simp [nodeRowsList] at hStep ⊢
      cases hStep with
      | inl hHead =>
          cases hHead
          exact Or.inl (by simp [nodeRows])
      | inr hTail =>
          exact Or.inr (ih hTail)

/-- Duplicate-free primitive node ledgers make node frontier rows unique. -/
theorem node_frontiers_eq_of_nodeRowsList_nodup
    {primitiveSteps : List PrimitiveGraphStep}
    (hUnique : (nodeRowsList primitiveSteps).Nodup)
    {node : NodeId}
    {entries₁ exits₁ entries₂ exits₂ : List AdmissionBoundaryPort}
    (hLeft : PrimitiveGraphStep.node node entries₁ exits₁ ∈ primitiveSteps)
    (hRight : PrimitiveGraphStep.node node entries₂ exits₂ ∈ primitiveSteps) :
    entries₁ = entries₂ ∧ exits₁ = exits₂ := by
  induction primitiveSteps with
  | nil =>
      cases hLeft
  | cons primitiveStep primitiveSteps ih =>
      simp at hLeft hRight
      cases hLeft with
      | inl hLeftHead =>
          cases hLeftHead
          cases hRight with
          | inl hRightHead =>
              cases hRightHead
              exact ⟨rfl, rfl⟩
          | inr hRightTail =>
              have hRightNode :=
                nodeRowsList_mem_of_node_mem hRightTail
              have hNoTail : node ∉ nodeRowsList primitiveSteps := by
                have hUniqueHead := hUnique
                simp [nodeRowsList, nodeRows] at hUniqueHead
                exact hUniqueHead.left
              exact False.elim (hNoTail hRightNode)
      | inr hLeftTail =>
          cases hRight with
          | inl hRightHead =>
              cases hRightHead
              have hLeftNode :=
                nodeRowsList_mem_of_node_mem hLeftTail
              have hNoTail : node ∉ nodeRowsList primitiveSteps := by
                have hUniqueHead := hUnique
                simp [nodeRowsList, nodeRows] at hUniqueHead
                exact hUniqueHead.left
              exact False.elim (hNoTail hLeftNode)
          | inr hRightTail =>
              cases primitiveStep <;> simp [nodeRowsList, nodeRows] at hUnique
              · exact ih hUnique hLeftTail hRightTail
              · exact ih hUnique.right hLeftTail hRightTail
              · exact ih hUnique hLeftTail hRightTail
              · exact ih hUnique hLeftTail hRightTail
              · exact ih hUnique hLeftTail hRightTail

/-- Primitive node entry boundary keys projected from a list of trace rows. -/
def nodeEntryKeysList :
    List PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.nodeEntryKeys ++ nodeEntryKeysList primitiveSteps

/-- Primitive node exit boundary keys projected from a list of trace rows. -/
def nodeExitKeysList :
    List PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.nodeExitKeys ++ nodeExitKeysList primitiveSteps

/-- Input boundary keys consumed by a list of primitive connect rows. -/
def consumedEntryKeysList :
    List PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.consumedEntryKeys ++ consumedEntryKeysList primitiveSteps

/-- Output boundary keys consumed by a list of primitive connect rows. -/
def consumedExitKeysList :
    List PrimitiveGraphStep → List (NodeId × FieldLabel × ContractId)
  | [] => []
  | primitiveStep :: primitiveSteps =>
      primitiveStep.consumedExitKeys ++ consumedExitKeysList primitiveSteps

/-- Matched connection rows contribute their target keys to consumed entry keys. -/
theorem matchedConnectionsList_toKey_mem_consumedEntryKeysList
    {connection : AdmissionConnection}
    {primitiveSteps : List PrimitiveGraphStep}
    (hConnection :
      connection ∈ matchedConnectionsList primitiveSteps) :
    connection.toKey ∈ consumedEntryKeysList primitiveSteps := by
  induction primitiveSteps with
  | nil =>
      cases hConnection
  | cons primitiveStep primitiveSteps ih =>
      cases primitiveStep with
      | empty =>
          exact ih hConnection
      | node node entries exits =>
          exact ih hConnection
      | bindingRef binding =>
          exact ih hConnection
      | overlay leftNodes rightNodes leftBindings rightBindings =>
          exact ih hConnection
      | connect leftExits rightEntries matchedPairs unmatchedLeftExits
          unmatchedRightEntries =>
          simp [matchedConnectionsList, matchedConnections, consumedEntryKeysList,
            consumedEntryKeys] at hConnection ⊢
          cases hConnection with
          | inl hPair =>
              exact Or.inl ⟨connection, hPair, rfl⟩
          | inr hRest =>
              exact Or.inr (ih hRest)

/-- Matched connection rows contribute their source keys to consumed exit keys. -/
theorem matchedConnectionsList_fromKey_mem_consumedExitKeysList
    {connection : AdmissionConnection}
    {primitiveSteps : List PrimitiveGraphStep}
    (hConnection :
      connection ∈ matchedConnectionsList primitiveSteps) :
    connection.fromKey ∈ consumedExitKeysList primitiveSteps := by
  induction primitiveSteps with
  | nil =>
      cases hConnection
  | cons primitiveStep primitiveSteps ih =>
      cases primitiveStep with
      | empty =>
          exact ih hConnection
      | node node entries exits =>
          exact ih hConnection
      | bindingRef binding =>
          exact ih hConnection
      | overlay leftNodes rightNodes leftBindings rightBindings =>
          exact ih hConnection
      | connect leftExits rightEntries matchedPairs unmatchedLeftExits
          unmatchedRightEntries =>
          simp [matchedConnectionsList, matchedConnections, consumedExitKeysList,
            consumedExitKeys] at hConnection ⊢
          cases hConnection with
          | inl hPair =>
              exact Or.inl ⟨connection, hPair, rfl⟩
          | inr hRest =>
              exact Or.inr (ih hRest)

/-- Matched pairs from a primitive connect row appear in the global matched-pair ledger. -/
theorem matchedConnectionsList_mem_of_connect_mem
    {primitiveSteps : List PrimitiveGraphStep}
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    {pair : AdmissionConnection}
    (hStep :
      PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
        primitiveSteps)
    (hPair : pair ∈ matchedPairs) :
    pair ∈ matchedConnectionsList primitiveSteps := by
  induction primitiveSteps with
  | nil =>
      cases hStep
  | cons primitiveStep primitiveSteps ih =>
      cases primitiveStep with
      | empty =>
          simp [matchedConnectionsList, matchedConnections] at hStep ⊢
          exact ih hStep
      | node node entries exits =>
          simp [matchedConnectionsList, matchedConnections] at hStep ⊢
          exact ih hStep
      | bindingRef binding =>
          simp [matchedConnectionsList, matchedConnections] at hStep ⊢
          exact ih hStep
      | overlay leftNodes rightNodes leftBindings rightBindings =>
          simp [matchedConnectionsList, matchedConnections] at hStep ⊢
          exact ih hStep
      | connect leftExits' rightEntries' matchedPairs' unmatchedLeftExits'
          unmatchedRightEntries' =>
          simp [matchedConnectionsList, matchedConnections] at hStep ⊢
          cases hStep with
          | inl hHead =>
              rcases hHead with ⟨rfl, rfl, rfl, rfl, rfl⟩
              exact Or.inl hPair
          | inr hTail =>
              exact Or.inr (ih hTail)

/-- Validator obligations for a serialized primitive node row. -/
structure NodeValid
    (nodeId : NodeId)
    (entries exits : List AdmissionBoundaryPort) : Prop where
  nodeValid : nodeId.Valid
  entriesValid : BoundaryPortsValid entries
  exitsValid : BoundaryPortsValid exits
  frontiersOwned : NodeFrontiersOwned nodeId entries exits
  frontiersLinear : NodeFrontiersLinear entries exits

/-- Validator obligations for a serialized primitive overlay row. -/
structure OverlayValid
    (leftNodeIds rightNodeIds : List NodeId)
    (leftBindings rightBindings : List BindingName) : Prop where
  leftNodesValid : ∀ node, node ∈ leftNodeIds → node.Valid
  rightNodesValid : ∀ node, node ∈ rightNodeIds → node.Valid
  leftBindingsValid : ∀ binding, binding ∈ leftBindings → binding.Valid
  rightBindingsValid : ∀ binding, binding ∈ rightBindings → binding.Valid
  ledgersUnique : OverlayLedgersUnique leftNodeIds rightNodeIds leftBindings rightBindings
  ledgersDisjoint : OverlayLedgersDisjoint leftNodeIds rightNodeIds leftBindings rightBindings

/-- Validator obligations for a serialized primitive connect row. -/
structure ConnectValid
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) : Prop where
  pairsDrawnFromFrontiers :
    ∀ pair, pair ∈ matchedPairs → pair.fromPort ∈ leftExits ∧ pair.toPort ∈ rightEntries
  unmatchedLeftDrawnFromFrontier :
    ∀ boundary, boundary ∈ unmatchedLeftExits → boundary ∈ leftExits
  unmatchedRightDrawnFromFrontier :
    ∀ boundary, boundary ∈ unmatchedRightEntries → boundary ∈ rightEntries
  pairsLinear : ConnectPairsLinear matchedPairs
  frontiersLinear : ConnectFrontiersLinear leftExits rightEntries
  matchesAllCompatible : ConnectMatchesAllCompatible leftExits rightEntries matchedPairs
  frontierPartition :
    ConnectFrontierPartition
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries
  rowsValid :
    ConnectRowsValid
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries

/-- Row-level validator obligation for primitive graph steps.

The primitive artifact is still a trace row, not a `CertifiedGraph`. For
`connect`, the local check is that every matched pair and every unmatched
endpoint is drawn from the frontiers serialized in the same row, and that the
matched/unmatched rows partition each frontier exactly.
-/
def Valid : PrimitiveGraphStep → Prop
  | .empty => True
  | .node nodeId entries exits =>
      NodeValid nodeId entries exits
  | PrimitiveGraphStep.bindingRef binding => binding.Valid
  | PrimitiveGraphStep.overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      OverlayValid leftNodeIds rightNodeIds leftBindings rightBindings
  | PrimitiveGraphStep.connect
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      ConnectValid leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries

/-- Primitive graph-step rows mention only nodes and binding references in the top-level summary. -/
def DomainClosed
    (nodes : List NodeId)
    (bindingRefs : List BindingName) :
    PrimitiveGraphStep → Prop
  | .empty => True
  | .node nodeId entries exits =>
      nodeId ∈ nodes ∧
      BoundaryPortsClosed nodes entries ∧
      BoundaryPortsClosed nodes exits
  | PrimitiveGraphStep.bindingRef binding => binding ∈ bindingRefs
  | PrimitiveGraphStep.overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      (∀ node, node ∈ leftNodeIds → node ∈ nodes) ∧
      (∀ node, node ∈ rightNodeIds → node ∈ nodes) ∧
      (∀ binding, binding ∈ leftBindings → binding ∈ bindingRefs) ∧
      (∀ binding, binding ∈ rightBindings → binding ∈ bindingRefs)
  | PrimitiveGraphStep.connect
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      BoundaryPortsClosed nodes leftExits ∧
      BoundaryPortsClosed nodes rightEntries ∧
      ConnectionsClosed nodes matchedPairs ∧
      BoundaryPortsClosed nodes unmatchedLeftExits ∧
      BoundaryPortsClosed nodes unmatchedRightEntries

/-- Valid primitive overlay rows expose left/right ledger disjointness. -/
theorem valid_overlay_ledgersDisjoint
    {leftNodes rightNodes : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hValid :
      (PrimitiveGraphStep.overlay
        leftNodes rightNodes leftBindings rightBindings).Valid) :
    OverlayLedgersDisjoint leftNodes rightNodes leftBindings rightBindings :=
  hValid.ledgersDisjoint

/-- Valid primitive overlay rows expose duplicate-free side ledgers. -/
theorem valid_overlay_ledgersUnique
    {leftNodes rightNodes : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hValid :
      (PrimitiveGraphStep.overlay
        leftNodes rightNodes leftBindings rightBindings).Valid) :
    OverlayLedgersUnique leftNodes rightNodes leftBindings rightBindings :=
  hValid.ledgersUnique

/-- Valid primitive connect rows expose left/right frontier membership for each match. -/
theorem valid_connect_pair_mem
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid)
    {pair : AdmissionConnection}
    (hPair : pair ∈ matchedPairs) :
    pair.fromPort ∈ leftExits ∧ pair.toPort ∈ rightEntries :=
  hValid.pairsDrawnFromFrontiers pair hPair

/-- Valid primitive connect rows do not reuse matched output or input endpoints. -/
theorem valid_connect_pairsLinear
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid) :
    ConnectPairsLinear matchedPairs :=
  hValid.pairsLinear

/-- Valid primitive connect rows expose duplicate-free serialized frontiers. -/
theorem valid_connect_frontiersLinear
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid) :
    ConnectFrontiersLinear leftExits rightEntries :=
  hValid.frontiersLinear

/-- Valid primitive connect rows expose exact matched/unmatched frontier partitioning. -/
theorem valid_connect_frontierPartition
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid) :
    ConnectFrontierPartition
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries :=
  hValid.frontierPartition

/-- Valid primitive connect rows match every compatible left/right frontier pair. -/
theorem valid_connect_matchesAllCompatible
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid) :
    ConnectMatchesAllCompatible leftExits rightEntries matchedPairs :=
  hValid.matchesAllCompatible

/-- Valid primitive connect rows expose structural validity of serialized row endpoints. -/
theorem valid_connect_rowsValid
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hValid :
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries).Valid) :
    ConnectRowsValid
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries :=
  hValid.rowsValid

end PrimitiveGraphStep

end AdmissionArtifact
end Cortex.Wire
