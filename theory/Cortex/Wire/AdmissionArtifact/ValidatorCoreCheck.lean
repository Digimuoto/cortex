import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck

/-!
## Overview

Executable core checks for decoded Wire admission artifacts.

This module is a measurement slice for the Lean-owned validator strategy. It
does not decide the full `ValidatorReady` predicate. Instead, it groups a
representative core: schema version, summary uniqueness, summary row validity,
component-row uniqueness, primitive row validity, and executable primitive
stack replay.

Each checker has a theorem of the form `check = true → predicate`, so this file
tests whether replacing mirrored Haskell validator clauses with Lean-owned
executable checks scales locally.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Decidable Validity Leaves -/

namespace AdmissionPortLabel

instance validDecidable (label : AdmissionPortLabel) : Decidable label.Valid := by
  cases label with
  | noLabel =>
      exact isTrue trivial
  | label portLabel =>
      unfold Valid
      infer_instance

end AdmissionPortLabel

namespace AdmissionBoundaryPort

instance validDecidable (boundary : AdmissionBoundaryPort) : Decidable boundary.Valid := by
  cases boundary with
  | mk node port contract label exclusiveGroup =>
      cases label with
      | noLabel =>
          cases exclusiveGroup with
          | none =>
              unfold Valid AdmissionPortLabel.Valid
              infer_instance
          | some group =>
              cases group
              unfold Valid AdmissionPortLabel.Valid
              infer_instance
      | label label =>
          cases exclusiveGroup with
          | none =>
              unfold Valid AdmissionPortLabel.Valid
              infer_instance
          | some group =>
              cases group
              unfold Valid AdmissionPortLabel.Valid
              infer_instance

end AdmissionBoundaryPort

namespace AdmissionConnection

instance validDecidable (connection : AdmissionConnection) : Decidable connection.Valid := by
  unfold Valid BoundaryCompatible AdmissionBoundaryPort.CompatibleWith
  infer_instance

end AdmissionConnection

namespace AdmissionEndpointRef

instance validDecidable (endpoint : AdmissionEndpointRef) : Decidable endpoint.Valid := by
  cases endpoint with
  | mk node port =>
      cases port with
      | none =>
          unfold Valid
          infer_instance
      | some port =>
          unfold Valid
          infer_instance

end AdmissionEndpointRef

namespace AdmissionRawConnection

instance validDecidable (connection : AdmissionRawConnection) :
    Decidable connection.Valid := by
  unfold Valid
  infer_instance

end AdmissionRawConnection

/-! ## List Helpers -/

namespace Check

/-- Boolean universal quantification over a decoded finite row list. -/
def allDecide {α : Type}
    (items : List α)
    (predicate : α → Prop)
    [DecidablePred predicate] :
    Bool :=
  items.all fun item => decide (predicate item)

/-- A successful finite boolean universal check supplies the corresponding predicate. -/
theorem allDecide_sound
    {α : Type}
    {items : List α}
    {predicate : α → Prop}
    [DecidablePred predicate]
    (hCheck : allDecide items predicate = true) :
    ∀ item, item ∈ items → predicate item := by
  intro item hItem
  have hItemCheck :
      decide (predicate item) = true :=
    (List.all_eq_true.mp hCheck) item hItem
  exact of_decide_eq_true hItemCheck

/-- Boolean existential search over a decoded finite row list. -/
def anyDecide {α : Type}
    (items : List α)
    (predicate : α → Prop)
    [DecidablePred predicate] :
    Bool :=
  items.any fun item => decide (predicate item)

/-- A successful finite boolean existential check supplies a matching row. -/
theorem anyDecide_sound
    {α : Type}
    {items : List α}
    {predicate : α → Prop}
    [DecidablePred predicate]
    (hCheck : anyDecide items predicate = true) :
    ∃ item, item ∈ items ∧ predicate item := by
  rcases List.any_eq_true.mp hCheck with ⟨item, hItem, hPredicate⟩
  exact ⟨item, hItem, of_decide_eq_true hPredicate⟩

end Check

/-! ## Boundary Checks -/

namespace AdmissionArtifactCheck

/-- Every boundary port in a decoded list is structurally valid. -/
def boundaryPortsValidCheck (ports : List AdmissionBoundaryPort) : Bool :=
  Check.allDecide ports AdmissionBoundaryPort.Valid

/-- Successful boundary-port validity checking proves the relational list predicate. -/
theorem boundaryPortsValidCheck_sound
    {ports : List AdmissionBoundaryPort}
    (hCheck : boundaryPortsValidCheck ports = true) :
    BoundaryPortsValid ports :=
  Check.allDecide_sound hCheck

/-- Every boundary contraction in a decoded list is structurally valid. -/
def connectionsValidCheck (connections : List AdmissionConnection) : Bool :=
  Check.allDecide connections AdmissionConnection.Valid

/-- Successful connection-row validity checking proves the relational list predicate. -/
theorem connectionsValidCheck_sound
    {connections : List AdmissionConnection}
    (hCheck : connectionsValidCheck connections = true) :
    ConnectionsValid connections :=
  Check.allDecide_sound hCheck

end AdmissionArtifactCheck

/-! ## Primitive Row Checks -/

namespace PrimitiveGraphStep

/-- Primitive node frontiers are owned by the node row that serializes them. -/
def nodeFrontiersOwnedCheck
    (nodeId : NodeId)
    (entries exits : List AdmissionBoundaryPort) :
    Bool :=
  Check.allDecide entries (fun entry => entry.node = nodeId) &&
    Check.allDecide exits (fun exit => exit.node = nodeId)

/-- Successful ownership checking proves `NodeFrontiersOwned`. -/
theorem nodeFrontiersOwnedCheck_sound
    {nodeId : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hCheck : nodeFrontiersOwnedCheck nodeId entries exits = true) :
    NodeFrontiersOwned nodeId entries exits := by
  unfold nodeFrontiersOwnedCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.allDecide_sound hCheck.left
    , Check.allDecide_sound hCheck.right
    ⟩

/-- Primitive node frontier keys are duplicate-free per direction. -/
def nodeFrontiersLinearCheck
    (entries exits : List AdmissionBoundaryPort) :
    Bool :=
  decide ((entries.map AdmissionBoundaryPort.key).Nodup) &&
    decide ((exits.map AdmissionBoundaryPort.key).Nodup)

/-- Successful frontier-linearity checking proves `NodeFrontiersLinear`. -/
theorem nodeFrontiersLinearCheck_sound
    {entries exits : List AdmissionBoundaryPort}
    (hCheck : nodeFrontiersLinearCheck entries exits = true) :
    NodeFrontiersLinear entries exits := by
  unfold nodeFrontiersLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, of_decide_eq_true hCheck.right⟩

/-- Executable checker for primitive node-row validity. -/
def nodeValidCheck
    (nodeId : NodeId)
    (entries exits : List AdmissionBoundaryPort) :
    Bool :=
  decide nodeId.Valid &&
    AdmissionArtifactCheck.boundaryPortsValidCheck entries &&
      AdmissionArtifactCheck.boundaryPortsValidCheck exits &&
        nodeFrontiersOwnedCheck nodeId entries exits &&
          nodeFrontiersLinearCheck entries exits

/-- Successful primitive node-row checking proves `NodeValid`. -/
theorem nodeValidCheck_sound
    {nodeId : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hCheck : nodeValidCheck nodeId entries exits = true) :
    NodeValid nodeId entries exits := by
  unfold nodeValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨⟨hNode, hEntries⟩, hExits⟩, hOwned⟩, hLinear⟩
  exact
    { nodeValid := of_decide_eq_true hNode
    , entriesValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hEntries
    , exitsValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hExits
    , frontiersOwned := nodeFrontiersOwnedCheck_sound hOwned
    , frontiersLinear := nodeFrontiersLinearCheck_sound hLinear
    }

/-- Primitive overlay side ledgers are duplicate-free before merge. -/
def overlayLedgersUniqueCheck
    (leftNodeIds rightNodeIds : List NodeId)
    (leftBindings rightBindings : List BindingName) :
    Bool :=
  decide leftNodeIds.Nodup &&
    decide rightNodeIds.Nodup &&
      decide leftBindings.Nodup &&
        decide rightBindings.Nodup

/-- Successful overlay-uniqueness checking proves `OverlayLedgersUnique`. -/
theorem overlayLedgersUniqueCheck_sound
    {leftNodeIds rightNodeIds : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hCheck :
      overlayLedgersUniqueCheck
        leftNodeIds rightNodeIds leftBindings rightBindings = true) :
    OverlayLedgersUnique leftNodeIds rightNodeIds leftBindings rightBindings := by
  unfold overlayLedgersUniqueCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hLeftNodes, hRightNodes⟩, hLeftBindings⟩, hRightBindings⟩
  exact
    ⟨ of_decide_eq_true hLeftNodes
    , of_decide_eq_true hRightNodes
    , of_decide_eq_true hLeftBindings
    , of_decide_eq_true hRightBindings
    ⟩

/-- Primitive overlay side ledgers are disjoint before merge. -/
def overlayLedgersDisjointCheck
    (leftNodeIds rightNodeIds : List NodeId)
    (leftBindings rightBindings : List BindingName) :
    Bool :=
  Check.allDecide leftNodeIds (fun node => node ∉ rightNodeIds) &&
    Check.allDecide leftBindings (fun binding => binding ∉ rightBindings)

/-- Successful overlay-disjointness checking proves `OverlayLedgersDisjoint`. -/
theorem overlayLedgersDisjointCheck_sound
    {leftNodeIds rightNodeIds : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hCheck :
      overlayLedgersDisjointCheck
        leftNodeIds rightNodeIds leftBindings rightBindings = true) :
    OverlayLedgersDisjoint leftNodeIds rightNodeIds leftBindings rightBindings := by
  unfold overlayLedgersDisjointCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  constructor
  · intro node hLeft hRight
    exact (Check.allDecide_sound hCheck.left node hLeft) hRight
  · intro binding hLeft hRight
    exact (Check.allDecide_sound hCheck.right binding hLeft) hRight

/-- Executable checker for primitive overlay-row validity. -/
def overlayValidCheck
    (leftNodeIds rightNodeIds : List NodeId)
    (leftBindings rightBindings : List BindingName) :
    Bool :=
  Check.allDecide leftNodeIds NodeId.Valid &&
    Check.allDecide rightNodeIds NodeId.Valid &&
      Check.allDecide leftBindings BindingName.Valid &&
        Check.allDecide rightBindings BindingName.Valid &&
          overlayLedgersUniqueCheck
            leftNodeIds rightNodeIds leftBindings rightBindings &&
            overlayLedgersDisjointCheck
              leftNodeIds rightNodeIds leftBindings rightBindings

/-- Successful primitive overlay-row checking proves `OverlayValid`. -/
theorem overlayValidCheck_sound
    {leftNodeIds rightNodeIds : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hCheck :
      overlayValidCheck
        leftNodeIds rightNodeIds leftBindings rightBindings = true) :
    OverlayValid leftNodeIds rightNodeIds leftBindings rightBindings := by
  unfold overlayValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨hLeftNodes, hRightNodes⟩, hLeftBindings⟩, hRightBindings⟩,
      hUnique⟩, hDisjoint⟩
  exact
    { leftNodesValid := Check.allDecide_sound hLeftNodes
    , rightNodesValid := Check.allDecide_sound hRightNodes
    , leftBindingsValid := Check.allDecide_sound hLeftBindings
    , rightBindingsValid := Check.allDecide_sound hRightBindings
    , ledgersUnique := overlayLedgersUniqueCheck_sound hUnique
    , ledgersDisjoint := overlayLedgersDisjointCheck_sound hDisjoint
    }

/-- Matched primitive connect pairs do not reuse outputs or inputs. -/
def connectPairsLinearCheck (matchedPairs : List AdmissionConnection) : Bool :=
  decide ((matchedPairs.map AdmissionConnection.fromKey).Nodup) &&
    decide ((matchedPairs.map AdmissionConnection.toKey).Nodup)

/-- Successful connect-pair linearity checking proves `ConnectPairsLinear`. -/
theorem connectPairsLinearCheck_sound
    {matchedPairs : List AdmissionConnection}
    (hCheck : connectPairsLinearCheck matchedPairs = true) :
    ConnectPairsLinear matchedPairs := by
  unfold connectPairsLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, of_decide_eq_true hCheck.right⟩

/-- Serialized primitive connect frontiers are duplicate-free per side. -/
def connectFrontiersLinearCheck
    (leftExits rightEntries : List AdmissionBoundaryPort) :
    Bool :=
  decide ((leftExits.map AdmissionBoundaryPort.key).Nodup) &&
    decide ((rightEntries.map AdmissionBoundaryPort.key).Nodup)

/-- Successful connect-frontier linearity checking proves `ConnectFrontiersLinear`. -/
theorem connectFrontiersLinearCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    (hCheck : connectFrontiersLinearCheck leftExits rightEntries = true) :
    ConnectFrontiersLinear leftExits rightEntries := by
  unfold connectFrontiersLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, of_decide_eq_true hCheck.right⟩

/-- Matched and residual connect rows partition the serialized frontiers. -/
def connectFrontierPartitionCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Bool :=
  decide
      (((matchedPairs.map AdmissionConnection.fromKey) ++
          (unmatchedLeftExits.map AdmissionBoundaryPort.key)).Perm
        (leftExits.map AdmissionBoundaryPort.key)) &&
    decide
      (((matchedPairs.map AdmissionConnection.toKey) ++
          (unmatchedRightEntries.map AdmissionBoundaryPort.key)).Perm
        (rightEntries.map AdmissionBoundaryPort.key))

/-- Successful partition checking proves `ConnectFrontierPartition`. -/
theorem connectFrontierPartitionCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hCheck :
      connectFrontierPartitionCheck
        leftExits rightEntries matchedPairs
          unmatchedLeftExits unmatchedRightEntries = true) :
    ConnectFrontierPartition
      leftExits rightEntries matchedPairs
        unmatchedLeftExits unmatchedRightEntries := by
  unfold connectFrontierPartitionCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, of_decide_eq_true hCheck.right⟩

/-- Matched pairs are drawn from the frontiers serialized in the same connect row. -/
def connectPairsDrawnFromFrontiersCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection) :
    Bool :=
  Check.allDecide matchedPairs fun pair =>
    pair.fromPort ∈ leftExits ∧ pair.toPort ∈ rightEntries

/-- Successful pair-frontier checking proves the matched-pair inclusion fact. -/
theorem connectPairsDrawnFromFrontiersCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    (hCheck :
      connectPairsDrawnFromFrontiersCheck leftExits rightEntries matchedPairs =
        true) :
    ∀ pair, pair ∈ matchedPairs →
      pair.fromPort ∈ leftExits ∧ pair.toPort ∈ rightEntries :=
  Check.allDecide_sound hCheck

/-- Residual left exits are drawn from the serialized left frontier. -/
def unmatchedLeftDrawnFromFrontierCheck
    (leftExits unmatchedLeftExits : List AdmissionBoundaryPort) :
    Bool :=
  Check.allDecide unmatchedLeftExits fun boundary => boundary ∈ leftExits

/-- Successful residual-left checking proves the inclusion fact. -/
theorem unmatchedLeftDrawnFromFrontierCheck_sound
    {leftExits unmatchedLeftExits : List AdmissionBoundaryPort}
    (hCheck :
      unmatchedLeftDrawnFromFrontierCheck leftExits unmatchedLeftExits = true) :
    ∀ boundary, boundary ∈ unmatchedLeftExits → boundary ∈ leftExits :=
  Check.allDecide_sound hCheck

/-- Residual right entries are drawn from the serialized right frontier. -/
def unmatchedRightDrawnFromFrontierCheck
    (rightEntries unmatchedRightEntries : List AdmissionBoundaryPort) :
    Bool :=
  Check.allDecide unmatchedRightEntries fun boundary => boundary ∈ rightEntries

/-- Successful residual-right checking proves the inclusion fact. -/
theorem unmatchedRightDrawnFromFrontierCheck_sound
    {rightEntries unmatchedRightEntries : List AdmissionBoundaryPort}
    (hCheck :
      unmatchedRightDrawnFromFrontierCheck rightEntries unmatchedRightEntries =
        true) :
    ∀ boundary, boundary ∈ unmatchedRightEntries → boundary ∈ rightEntries :=
  Check.allDecide_sound hCheck

/-- Search a matched-pair ledger for a concrete compatible frontier pair. -/
def exactMatchedPairCheck
    (matchedPairs : List AdmissionConnection)
    (leftExit rightEntry : AdmissionBoundaryPort) :
    Bool :=
  Check.anyDecide matchedPairs fun pair =>
    pair.fromPort = leftExit ∧ pair.toPort = rightEntry

/-- Successful exact-pair search returns the matching connection row. -/
theorem exactMatchedPairCheck_sound
    {matchedPairs : List AdmissionConnection}
    {leftExit rightEntry : AdmissionBoundaryPort}
    (hCheck : exactMatchedPairCheck matchedPairs leftExit rightEntry = true) :
    ∃ pair, pair ∈ matchedPairs ∧
      pair.fromPort = leftExit ∧ pair.toPort = rightEntry := by
  unfold exactMatchedPairCheck at hCheck
  rcases Check.anyDecide_sound hCheck with ⟨pair, hPair, hExact⟩
  exact ⟨pair, hPair, hExact⟩

/-- Every compatible frontier pair is recorded in the matched-pair ledger. -/
def connectMatchesAllCompatibleCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection) :
    Bool :=
  leftExits.all fun leftExit =>
    rightEntries.all fun rightEntry =>
      if leftExit.CompatibleWith rightEntry then
        exactMatchedPairCheck matchedPairs leftExit rightEntry
      else
        true

/-- Successful compatibility matching proves `ConnectMatchesAllCompatible`. -/
theorem connectMatchesAllCompatibleCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    (hCheck :
      connectMatchesAllCompatibleCheck leftExits rightEntries matchedPairs =
        true) :
    ConnectMatchesAllCompatible leftExits rightEntries matchedPairs := by
  intro leftExit hLeftExit rightEntry hRightEntry hCompatible
  unfold connectMatchesAllCompatibleCheck at hCheck
  have hLeftCheck :=
    (List.all_eq_true.mp hCheck) leftExit hLeftExit
  have hRightCheck :=
    (List.all_eq_true.mp hLeftCheck) rightEntry hRightEntry
  by_cases hCompatibleCheck : leftExit.CompatibleWith rightEntry
  · simp [hCompatibleCheck] at hRightCheck
    exact exactMatchedPairCheck_sound hRightCheck
  · exact False.elim (hCompatibleCheck hCompatible)

/-- Boundary rows inside a primitive connect row are structurally valid. -/
def connectRowsValidCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Bool :=
  AdmissionArtifactCheck.boundaryPortsValidCheck leftExits &&
    AdmissionArtifactCheck.boundaryPortsValidCheck rightEntries &&
      AdmissionArtifactCheck.connectionsValidCheck matchedPairs &&
        AdmissionArtifactCheck.boundaryPortsValidCheck unmatchedLeftExits &&
          AdmissionArtifactCheck.boundaryPortsValidCheck unmatchedRightEntries

/-- Successful connect-row boundary checking proves `ConnectRowsValid`. -/
theorem connectRowsValidCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hCheck :
      connectRowsValidCheck
        leftExits rightEntries matchedPairs
          unmatchedLeftExits unmatchedRightEntries = true) :
    ConnectRowsValid
      leftExits rightEntries matchedPairs
        unmatchedLeftExits unmatchedRightEntries := by
  unfold connectRowsValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨⟨hLeftExits, hRightEntries⟩, hPairs⟩,
    hUnmatchedLeft⟩, hUnmatchedRight⟩
  exact
    ⟨ AdmissionArtifactCheck.boundaryPortsValidCheck_sound hLeftExits
    , AdmissionArtifactCheck.boundaryPortsValidCheck_sound hRightEntries
    , AdmissionArtifactCheck.connectionsValidCheck_sound hPairs
    , AdmissionArtifactCheck.boundaryPortsValidCheck_sound hUnmatchedLeft
    , AdmissionArtifactCheck.boundaryPortsValidCheck_sound hUnmatchedRight
    ⟩

/-- Executable checker for primitive connect-row validity. -/
def connectValidCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Bool :=
  connectPairsDrawnFromFrontiersCheck leftExits rightEntries matchedPairs &&
    unmatchedLeftDrawnFromFrontierCheck leftExits unmatchedLeftExits &&
      unmatchedRightDrawnFromFrontierCheck rightEntries unmatchedRightEntries &&
        connectPairsLinearCheck matchedPairs &&
          connectFrontiersLinearCheck leftExits rightEntries &&
            connectMatchesAllCompatibleCheck leftExits rightEntries matchedPairs &&
              connectFrontierPartitionCheck
                leftExits rightEntries matchedPairs
                  unmatchedLeftExits unmatchedRightEntries &&
                connectRowsValidCheck
                  leftExits rightEntries matchedPairs
                    unmatchedLeftExits unmatchedRightEntries

/-- Successful primitive connect-row checking proves `ConnectValid`. -/
theorem connectValidCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hCheck :
      connectValidCheck
        leftExits rightEntries matchedPairs
          unmatchedLeftExits unmatchedRightEntries = true) :
    ConnectValid
      leftExits rightEntries matchedPairs
        unmatchedLeftExits unmatchedRightEntries := by
  unfold connectValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨⟨⟨hPairsDrawn, hUnmatchedLeft⟩, hUnmatchedRight⟩, hPairsLinear⟩,
      hFrontiersLinear⟩, hMatchesAll⟩, hPartition⟩, hRowsValid⟩
  exact
    { pairsDrawnFromFrontiers :=
        connectPairsDrawnFromFrontiersCheck_sound hPairsDrawn
    , unmatchedLeftDrawnFromFrontier :=
        unmatchedLeftDrawnFromFrontierCheck_sound hUnmatchedLeft
    , unmatchedRightDrawnFromFrontier :=
        unmatchedRightDrawnFromFrontierCheck_sound hUnmatchedRight
    , pairsLinear := connectPairsLinearCheck_sound hPairsLinear
    , frontiersLinear := connectFrontiersLinearCheck_sound hFrontiersLinear
    , matchesAllCompatible := connectMatchesAllCompatibleCheck_sound hMatchesAll
    , frontierPartition := connectFrontierPartitionCheck_sound hPartition
    , rowsValid := connectRowsValidCheck_sound hRowsValid
    }

/-- Executable checker for primitive graph-step row validity. -/
def validCheck : PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.node nodeId entries exits =>
      nodeValidCheck nodeId entries exits
  | PrimitiveGraphStep.bindingRef binding =>
      decide binding.Valid
  | PrimitiveGraphStep.overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      overlayValidCheck leftNodeIds rightNodeIds leftBindings rightBindings
  | PrimitiveGraphStep.connect
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      connectValidCheck
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries

/-- Successful primitive graph-step checking proves row-local `Valid`. -/
theorem validCheck_sound
    {primitiveStep : PrimitiveGraphStep}
    (hCheck : primitiveStep.validCheck = true) :
    primitiveStep.Valid := by
  cases primitiveStep with
  | empty =>
      exact trivial
  | node nodeId entries exits =>
      exact nodeValidCheck_sound hCheck
  | bindingRef binding =>
      show binding.Valid
      exact of_decide_eq_true hCheck
  | overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      exact overlayValidCheck_sound hCheck
  | connect leftExits rightEntries matchedPairs unmatchedLeftExits
      unmatchedRightEntries =>
      exact connectValidCheck_sound hCheck

end PrimitiveGraphStep

/-! ## Validator-Ready Core -/

namespace WireAdmissionArtifact

/-- Executable checker for top-level summary-key uniqueness. -/
def summaryKeysUniqueCheck (artifact : WireAdmissionArtifact) : Bool :=
  decide artifact.nodes.Nodup &&
    decide artifact.bindingRefs.Nodup &&
      decide ((artifact.entries.map AdmissionBoundaryPort.key).Nodup) &&
        decide ((artifact.exits.map AdmissionBoundaryPort.key).Nodup) &&
          decide artifact.connections.Nodup

/-- Successful summary-key checking proves `SummaryKeysUnique`. -/
theorem summaryKeysUniqueCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryKeysUniqueCheck = true) :
    artifact.SummaryKeysUnique := by
  unfold summaryKeysUniqueCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨⟨hNodes, hBindings⟩, hEntries⟩, hExits⟩, hConnections⟩
  exact
    { nodesUnique := of_decide_eq_true hNodes
    , bindingRefsUnique := of_decide_eq_true hBindings
    , entriesUnique := of_decide_eq_true hEntries
    , exitsUnique := of_decide_eq_true hExits
    , connectionsUnique := of_decide_eq_true hConnections
    }

/-- Executable checker for top-level summary row validity. -/
def summaryRowsValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allDecide artifact.nodes NodeId.Valid &&
    Check.allDecide artifact.bindingRefs BindingName.Valid &&
      AdmissionArtifactCheck.boundaryPortsValidCheck artifact.entries &&
        AdmissionArtifactCheck.boundaryPortsValidCheck artifact.exits &&
          Check.allDecide artifact.connections AdmissionRawConnection.Valid

/-- Successful summary-row checking proves `SummaryRowsValid`. -/
theorem summaryRowsValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryRowsValidCheck = true) :
    artifact.SummaryRowsValid := by
  unfold summaryRowsValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨⟨hNodes, hBindings⟩, hEntries⟩, hExits⟩, hConnections⟩
  exact
    { nodesValid := Check.allDecide_sound hNodes
    , bindingRefsValid := Check.allDecide_sound hBindings
    , entriesValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hEntries
    , exitsValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hExits
    , connectionsValid := Check.allDecide_sound hConnections
    }

/-- Executable checker for component-row identity uniqueness. -/
def componentRowsUniqueCheck (artifact : WireAdmissionArtifact) : Bool :=
  decide ((artifact.generatedForms.map GeneratedFormArtifact.binding).Nodup) &&
    decide ((artifact.phantomAdapters.map PhantomAdapterArtifact.node).Nodup) &&
      decide ((artifact.selects.map SelectAdmissionArtifact.conditionNode).Nodup) &&
        decide artifact.componentRoleNodes.Nodup

/-- Successful component-row checking proves `ComponentRowsUnique`. -/
theorem componentRowsUniqueCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.componentRowsUniqueCheck = true) :
    artifact.ComponentRowsUnique := by
  unfold componentRowsUniqueCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hGenerated, hPhantom⟩, hSelect⟩, hRoles⟩
  exact
    { generatedFormBindingsUnique := of_decide_eq_true hGenerated
    , phantomAdapterNodesUnique := of_decide_eq_true hPhantom
    , selectConditionNodesUnique := of_decide_eq_true hSelect
    , componentRoleNodesUnique := of_decide_eq_true hRoles
    }

/-- Executable checker for primitive graph-step row-local validity. -/
def primitiveStepsValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  artifact.primitiveSteps.all PrimitiveGraphStep.validCheck

/-- Successful primitive-step checking proves `PrimitiveStepsValid`. -/
theorem primitiveStepsValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveStepsValidCheck = true) :
    artifact.PrimitiveStepsValid := by
  intro primitiveStep hStep
  exact PrimitiveGraphStep.validCheck_sound ((List.all_eq_true.mp hCheck) _ hStep)

/-- Representative executable subset of `ValidatorReady`.

This is not a replacement for full validator readiness. It names the fields
covered by the current executable-checker strategy spike.
-/
structure ValidatorReadyCore (artifact : WireAdmissionArtifact) : Prop where
  schemaCurrent : artifact.SchemaCurrent
  summaryKeysUnique : artifact.SummaryKeysUnique
  summaryRowsValid : artifact.SummaryRowsValid
  componentRowsUnique : artifact.ComponentRowsUnique
  primitiveStepsValid : artifact.PrimitiveStepsValid
  primitiveTraceStackValid : artifact.PrimitiveTraceStackValid

/-- Full validator readiness implies the executable core contract. -/
theorem validatorReady_core
    {artifact : WireAdmissionArtifact}
    (hReady : artifact.ValidatorReady) :
    artifact.ValidatorReadyCore where
  schemaCurrent := hReady.schemaCurrent
  summaryKeysUnique := hReady.summaryKeysUnique
  summaryRowsValid := hReady.summaryRowsValid
  componentRowsUnique := hReady.componentRowsUnique
  primitiveStepsValid := hReady.primitiveStepsValid
  primitiveTraceStackValid := hReady.primitiveTraceStackValid

/-- Executable checker for the representative validator-ready core. -/
def validatorReadyCoreCheck (artifact : WireAdmissionArtifact) : Bool :=
  decide artifact.SchemaCurrent &&
    artifact.summaryKeysUniqueCheck &&
      artifact.summaryRowsValidCheck &&
        artifact.componentRowsUniqueCheck &&
          artifact.primitiveStepsValidCheck &&
            artifact.primitiveTraceStackValidCheck

/-- Successful core checking proves the representative validator-ready core. -/
theorem validatorReadyCoreCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.validatorReadyCoreCheck = true) :
    artifact.ValidatorReadyCore := by
  unfold validatorReadyCoreCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨hSchema, hSummaryKeys⟩, hSummaryRows⟩, hComponentRows⟩,
      hPrimitiveSteps⟩, hPrimitiveTrace⟩
  exact
    { schemaCurrent := of_decide_eq_true hSchema
    , summaryKeysUnique := summaryKeysUniqueCheck_sound hSummaryKeys
    , summaryRowsValid := summaryRowsValidCheck_sound hSummaryRows
    , componentRowsUnique := componentRowsUniqueCheck_sound hComponentRows
    , primitiveStepsValid := primitiveStepsValidCheck_sound hPrimitiveSteps
    , primitiveTraceStackValid := primitiveTraceStackValidCheck_sound hPrimitiveTrace
    }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
