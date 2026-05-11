import Cortex.Wire.AdmissionArtifact.Check
import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck

/-!
## Overview

Executable core checks for decoded Wire admission artifacts.

This module is a measurement slice for the Lean-owned validator strategy. It
does not decide the full `ValidatorReady` predicate. Instead, it groups a
representative core: schema version, summary invariants, local select-row
validity, component-row uniqueness, primitive row validity, and executable
primitive stack replay.

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
  Check.nodupMapCheck entries AdmissionBoundaryPort.key &&
    Check.nodupMapCheck exits AdmissionBoundaryPort.key

/-- Successful frontier-linearity checking proves `NodeFrontiersLinear`. -/
theorem nodeFrontiersLinearCheck_sound
    {entries exits : List AdmissionBoundaryPort}
    (hCheck : nodeFrontiersLinearCheck entries exits = true) :
    NodeFrontiersLinear entries exits := by
  unfold nodeFrontiersLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.nodupMapCheck_sound hCheck.left
    , Check.nodupMapCheck_sound hCheck.right
    ⟩

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
  Check.nodupCheck leftNodeIds &&
    Check.nodupCheck rightNodeIds &&
      Check.nodupCheck leftBindings &&
        Check.nodupCheck rightBindings

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
    ⟨ Check.nodupCheck_sound hLeftNodes
    , Check.nodupCheck_sound hRightNodes
    , Check.nodupCheck_sound hLeftBindings
    , Check.nodupCheck_sound hRightBindings
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
  Check.nodupMapCheck matchedPairs AdmissionConnection.fromKey &&
    Check.nodupMapCheck matchedPairs AdmissionConnection.toKey

/-- Successful connect-pair linearity checking proves `ConnectPairsLinear`. -/
theorem connectPairsLinearCheck_sound
    {matchedPairs : List AdmissionConnection}
    (hCheck : connectPairsLinearCheck matchedPairs = true) :
    ConnectPairsLinear matchedPairs := by
  unfold connectPairsLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.nodupMapCheck_sound hCheck.left
    , Check.nodupMapCheck_sound hCheck.right
    ⟩

/-- Serialized primitive connect frontiers are duplicate-free per side. -/
def connectFrontiersLinearCheck
    (leftExits rightEntries : List AdmissionBoundaryPort) :
    Bool :=
  Check.nodupMapCheck leftExits AdmissionBoundaryPort.key &&
    Check.nodupMapCheck rightEntries AdmissionBoundaryPort.key

/-- Successful connect-frontier linearity checking proves `ConnectFrontiersLinear`. -/
theorem connectFrontiersLinearCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    (hCheck : connectFrontiersLinearCheck leftExits rightEntries = true) :
    ConnectFrontiersLinear leftExits rightEntries := by
  unfold connectFrontiersLinearCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.nodupMapCheck_sound hCheck.left
    , Check.nodupMapCheck_sound hCheck.right
    ⟩

/-- Matched and residual connect rows partition the serialized frontiers. -/
def connectFrontierPartitionCheck
    (leftExits rightEntries : List AdmissionBoundaryPort)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    Bool :=
  Check.permCheck
      ((matchedPairs.map AdmissionConnection.fromKey) ++
        (unmatchedLeftExits.map AdmissionBoundaryPort.key))
      (leftExits.map AdmissionBoundaryPort.key) &&
    Check.permCheck
      ((matchedPairs.map AdmissionConnection.toKey) ++
        (unmatchedRightEntries.map AdmissionBoundaryPort.key))
      (rightEntries.map AdmissionBoundaryPort.key)

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
  exact
    ⟨ Check.permCheck_sound hCheck.left
    , Check.permCheck_sound hCheck.right
    ⟩

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
  Check.allPairsWhenCheck
    leftExits rightEntries
    AdmissionBoundaryPort.CompatibleWith
    (exactMatchedPairCheck matchedPairs)

/-- Successful compatibility matching proves `ConnectMatchesAllCompatible`. -/
theorem connectMatchesAllCompatibleCheck_sound
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    (hCheck :
      connectMatchesAllCompatibleCheck leftExits rightEntries matchedPairs =
        true) :
    ConnectMatchesAllCompatible leftExits rightEntries matchedPairs := by
  unfold connectMatchesAllCompatibleCheck at hCheck
  exact
    Check.allPairsWhenCheck_sound hCheck
      (fun leftExit _ rightEntry _ hExact =>
        exactMatchedPairCheck_sound hExact)

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
  Check.nodupCheck artifact.nodes &&
    Check.nodupCheck artifact.bindingRefs &&
      Check.nodupMapCheck artifact.entries AdmissionBoundaryPort.key &&
        Check.nodupMapCheck artifact.exits AdmissionBoundaryPort.key &&
          Check.nodupCheck artifact.connections

/-- Successful summary-key checking proves `SummaryKeysUnique`. -/
theorem summaryKeysUniqueCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryKeysUniqueCheck = true) :
    artifact.SummaryKeysUnique := by
  unfold summaryKeysUniqueCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨⟨hNodes, hBindings⟩, hEntries⟩, hExits⟩, hConnections⟩
  exact
    { nodesUnique := Check.nodupCheck_sound hNodes
    , bindingRefsUnique := Check.nodupCheck_sound hBindings
    , entriesUnique := Check.nodupMapCheck_sound hEntries
    , exitsUnique := Check.nodupMapCheck_sound hExits
    , connectionsUnique := Check.nodupCheck_sound hConnections
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

/-- Executable checker for boundary rows being closed over a node summary. -/
def boundaryPortClosedCheck
    (nodes : List NodeId)
    (port : AdmissionBoundaryPort) :
    Bool :=
  Check.memCheck port.node nodes &&
    match port.exclusiveGroup with
    | none => true
    | some (owner, _index) => Check.memCheck owner nodes

/-- Successful boundary-row closure checking proves `AdmissionBoundaryPort.ClosedOver`. -/
theorem boundaryPortClosedCheck_sound
    {nodes : List NodeId}
    {port : AdmissionBoundaryPort}
    (hCheck : boundaryPortClosedCheck nodes port = true) :
    port.ClosedOver nodes := by
  unfold boundaryPortClosedCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  constructor
  · exact Check.memCheck_sound hCheck.left
  · cases hGroup : port.exclusiveGroup with
    | none =>
        trivial
    | some group =>
        cases group with
        | mk owner index =>
            have hOwnerCheck : Check.memCheck owner nodes = true := by
              simpa [hGroup] using hCheck.right
            exact Check.memCheck_sound hOwnerCheck

/-- Executable checker for boundary lists being closed over a node summary. -/
def boundaryPortsClosedCheck
    (nodes : List NodeId)
    (ports : List AdmissionBoundaryPort) :
    Bool :=
  Check.allBool ports (boundaryPortClosedCheck nodes)

/-- Successful boundary-closure checking proves `BoundaryPortsClosed`. -/
theorem boundaryPortsClosedCheck_sound
    {nodes : List NodeId}
    {ports : List AdmissionBoundaryPort}
    (hCheck : boundaryPortsClosedCheck nodes ports = true) :
    BoundaryPortsClosed nodes ports :=
  Check.allBool_sound hCheck
    (fun _port _ hPortCheck => boundaryPortClosedCheck_sound hPortCheck)

/-- Executable checker for raw connection endpoints being closed over a node summary. -/
def rawConnectionsClosedCheck
    (nodes : List NodeId)
    (connections : List AdmissionRawConnection) :
    Bool :=
  Check.allDecide connections fun connection =>
    connection.fromEndpoint.node ∈ nodes ∧ connection.toEndpoint.node ∈ nodes

/-- Successful raw-connection closure checking proves endpoint-node closure. -/
theorem rawConnectionsClosedCheck_sound
    {nodes : List NodeId}
    {connections : List AdmissionRawConnection}
    (hCheck : rawConnectionsClosedCheck nodes connections = true) :
    ∀ connection, connection ∈ connections →
      connection.fromEndpoint.node ∈ nodes ∧ connection.toEndpoint.node ∈ nodes :=
  Check.allDecide_sound hCheck

/-- Executable checker for top-level summary closure over serialized nodes. -/
def summaryDomainClosedCheck (artifact : WireAdmissionArtifact) : Bool :=
  boundaryPortsClosedCheck artifact.nodes artifact.entries &&
    boundaryPortsClosedCheck artifact.nodes artifact.exits &&
      rawConnectionsClosedCheck artifact.nodes artifact.connections

/-- Successful summary-domain checking proves `SummaryDomainClosed`. -/
theorem summaryDomainClosedCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryDomainClosedCheck = true) :
    artifact.SummaryDomainClosed := by
  unfold summaryDomainClosedCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hEntries, hExits⟩, hConnections⟩
  exact
    { entriesClosed := boundaryPortsClosedCheck_sound hEntries
    , exitsClosed := boundaryPortsClosedCheck_sound hExits
    , connectionsClosed := rawConnectionsClosedCheck_sound hConnections
    }

/-- Executable checker that summary identities match primitive identity rows. -/
def summaryIdentitiesMatchPrimitiveCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.permCheck artifact.nodes
      (PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps) &&
    Check.permCheck artifact.bindingRefs
      (PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps)

/-- Successful identity matching proves `SummaryIdentitiesMatchPrimitive`. -/
theorem summaryIdentitiesMatchPrimitiveCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryIdentitiesMatchPrimitiveCheck = true) :
    artifact.SummaryIdentitiesMatchPrimitive := by
  unfold summaryIdentitiesMatchPrimitiveCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.permCheck_sound hCheck.left
    , Check.permCheck_sound hCheck.right
    ⟩

/-- Executable checker that summary frontiers are backed by primitive residual frontiers. -/
def summaryFrontiersBackedByPrimitiveCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  (Check.allDecide artifact.entries fun entry =>
    entry.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
      entry.key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps) &&
  (Check.allDecide artifact.exits fun exit =>
    exit.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
      exit.key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps)

/-- Successful frontier-backing checking proves `SummaryFrontiersBackedByPrimitive`. -/
theorem summaryFrontiersBackedByPrimitiveCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryFrontiersBackedByPrimitiveCheck = true) :
    artifact.SummaryFrontiersBackedByPrimitive := by
  unfold summaryFrontiersBackedByPrimitiveCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.allDecide_sound hCheck.left
    , Check.allDecide_sound hCheck.right
    ⟩

/-- Primitive entry keys that remain source-visible after primitive connection replay. -/
def residualPrimitiveEntryKeys (artifact : WireAdmissionArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  (PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps).filter fun key =>
    decide (key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps)

/-- Boolean check that one exit row witnesses a select-internal key. -/
def selectInternalExitRowKeyCheck
    (selectAdmission : SelectAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId)
    (exit : AdmissionBoundaryPort) :
    Bool :=
  decide (exit.key = key) &&
    match exit.exclusiveGroup with
    | none => false
    | some (owner, _index) =>
        decide (owner = selectAdmission.conditionNode) &&
          selectAdmission.variants.any fun variant =>
            decide (variant.port.CompatibleWith exit)

/-- Successful row-level select-internal checking returns the matched exit and variant facts. -/
theorem selectInternalExitRowKeyCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    {key : NodeId × FieldLabel × ContractId}
    {exit : AdmissionBoundaryPort}
    (hCheck : selectInternalExitRowKeyCheck selectAdmission key exit = true) :
    exit.key = key ∧
      (∃ index, exit.exclusiveGroup = some (selectAdmission.conditionNode, index)) ∧
        ∃ variant, variant ∈ selectAdmission.variants ∧
          variant.port.CompatibleWith exit := by
  unfold selectInternalExitRowKeyCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  have hKey : exit.key = key := of_decide_eq_true hCheck.left
  cases hGroup : exit.exclusiveGroup with
  | none =>
      simp [hGroup] at hCheck
  | some group =>
      cases group with
      | mk owner index =>
          have hTail :
              (decide (owner = selectAdmission.conditionNode) &&
                selectAdmission.variants.any
                  (fun variant => decide (variant.port.CompatibleWith exit))) = true := by
            simpa [hGroup] using hCheck.right
          rw [Bool.and_eq_true] at hTail
          have hOwner : owner = selectAdmission.conditionNode :=
            of_decide_eq_true hTail.left
          rcases List.any_eq_true.mp hTail.right with
            ⟨variant, hVariant, hCompatibleBool⟩
          have hCompatible : variant.port.CompatibleWith exit :=
            of_decide_eq_true hCompatibleBool
          exact
            ⟨ hKey
            , ⟨index, by simp [hOwner]⟩
            , variant
            , hVariant
            , hCompatible
            ⟩

/-- Row-level select-internal key witnesses are accepted by the boolean checker. -/
theorem selectInternalExitRowKeyCheck_complete
    {selectAdmission : SelectAdmissionArtifact}
    {key : NodeId × FieldLabel × ContractId}
    {exit : AdmissionBoundaryPort}
    (hKey : exit.key = key)
    (hGroup :
      ∃ index, exit.exclusiveGroup = some (selectAdmission.conditionNode, index))
    (hVariant :
      ∃ variant, variant ∈ selectAdmission.variants ∧
        variant.port.CompatibleWith exit) :
    selectInternalExitRowKeyCheck selectAdmission key exit = true := by
  obtain ⟨index, hGroupEq⟩ := hGroup
  obtain ⟨variant, hVariant, hCompatible⟩ := hVariant
  unfold selectInternalExitRowKeyCheck
  rw [Bool.and_eq_true]
  constructor
  · exact decide_eq_true hKey
  · rw [hGroupEq]
    rw [Bool.and_eq_true]
    constructor
    · simp
    · exact List.any_eq_true.mpr
        ⟨variant, hVariant, decide_eq_true hCompatible⟩

/-- Boolean check that a primitive node row witnesses a select-internal key. -/
def selectInternalNodeKeyCheck
    (selectAdmission : SelectAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.node node _entries exits =>
      decide (node = selectAdmission.conditionNode) &&
        exits.any fun exit =>
          selectInternalExitRowKeyCheck selectAdmission key exit
  | PrimitiveGraphStep.empty => false
  | PrimitiveGraphStep.bindingRef _binding => false
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      false
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      false

/-- Successful primitive-node key checking returns the primitive row and exit witness. -/
theorem selectInternalNodeKeyCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    {key : NodeId × FieldLabel × ContractId}
    {primitiveStep : PrimitiveGraphStep}
    (hCheck : selectInternalNodeKeyCheck selectAdmission key primitiveStep = true) :
    ∃ entries exits,
      primitiveStep = PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∧
        ∃ exit, exit ∈ exits ∧
          exit.key = key ∧
            (∃ index,
              exit.exclusiveGroup = some (selectAdmission.conditionNode, index)) ∧
              ∃ variant, variant ∈ selectAdmission.variants ∧
                variant.port.CompatibleWith exit := by
  cases primitiveStep with
  | empty =>
      simp [selectInternalNodeKeyCheck] at hCheck
  | bindingRef binding =>
      simp [selectInternalNodeKeyCheck] at hCheck
  | overlay leftNodes rightNodes leftBindings rightBindings =>
      simp [selectInternalNodeKeyCheck] at hCheck
  | connect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      simp [selectInternalNodeKeyCheck] at hCheck
  | node node entries exits =>
      unfold selectInternalNodeKeyCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      have hNode : node = selectAdmission.conditionNode :=
        of_decide_eq_true hCheck.left
      rcases List.any_eq_true.mp hCheck.right with
        ⟨exit, hExit, hExitCheck⟩
      rcases selectInternalExitRowKeyCheck_sound hExitCheck with
        ⟨hKey, hGroup, hVariant⟩
      exact
        ⟨ entries
        , exits
        , by simp [hNode]
        , exit
        , hExit
        , hKey
        , hGroup
        , hVariant
        ⟩

/-- Primitive-node key witnesses are accepted by the boolean checker. -/
theorem selectInternalNodeKeyCheck_complete
    {selectAdmission : SelectAdmissionArtifact}
    {key : NodeId × FieldLabel × ContractId}
    {entries exits : List AdmissionBoundaryPort}
    (hExit :
      ∃ exit, exit ∈ exits ∧
        exit.key = key ∧
          (∃ index,
            exit.exclusiveGroup = some (selectAdmission.conditionNode, index)) ∧
            ∃ variant, variant ∈ selectAdmission.variants ∧
              variant.port.CompatibleWith exit) :
    selectInternalNodeKeyCheck selectAdmission key
      (PrimitiveGraphStep.node selectAdmission.conditionNode entries exits) = true := by
  obtain ⟨exit, hExitMem, hKey, hGroup, hVariant⟩ := hExit
  unfold selectInternalNodeKeyCheck
  rw [Bool.and_eq_true]
  constructor
  · simp
  · exact List.any_eq_true.mpr
      ⟨ exit
      , hExitMem
      , selectInternalExitRowKeyCheck_complete hKey hGroup hVariant
      ⟩

/-- Boolean form of key-level select-internal exit detection. -/
def selectInternalExitKeyCheck
    (artifact : WireAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId) :
    Bool :=
  artifact.selects.any fun selectAdmission =>
    artifact.primitiveSteps.any fun primitiveStep =>
      selectInternalNodeKeyCheck selectAdmission key primitiveStep

/-- The key-level select-internal checker is exact for `SelectInternalExitKey`. -/
theorem selectInternalExitKeyCheck_eq_true_iff
    {artifact : WireAdmissionArtifact}
    {key : NodeId × FieldLabel × ContractId} :
    artifact.selectInternalExitKeyCheck key = true ↔
      artifact.SelectInternalExitKey key := by
  unfold selectInternalExitKeyCheck SelectInternalExitKey
  constructor
  · intro hCheck
    rcases List.any_eq_true.mp hCheck with
      ⟨selectAdmission, hSelect, hPrimitiveCheck⟩
    rcases List.any_eq_true.mp hPrimitiveCheck with
      ⟨primitiveStep, hPrimitive, hNodeCheck⟩
    rcases selectInternalNodeKeyCheck_sound hNodeCheck with
      ⟨entries, exits, hStep, exit, hExit, hKey, hGroup, variant,
        hVariant, hCompatible⟩
    subst primitiveStep
    exact
      ⟨ selectAdmission
      , hSelect
      , entries
      , exits
      , hPrimitive
      , exit
      , hExit
      , hKey
      , hGroup
      , variant
      , hVariant
      , hCompatible
      ⟩
  · rintro
      ⟨ selectAdmission, hSelect, entries, exits, hPrimitive, exit, hExit,
        hKey, hGroup, variant, hVariant, hCompatible ⟩
    exact
      List.any_eq_true.mpr
        ⟨ selectAdmission
        , hSelect
        , List.any_eq_true.mpr
          ⟨ PrimitiveGraphStep.node selectAdmission.conditionNode entries exits
          , hPrimitive
          , selectInternalNodeKeyCheck_complete
            ⟨ exit
            , hExit
            , hKey
            , hGroup
            , variant
            , hVariant
            , hCompatible
            ⟩
          ⟩
        ⟩

/-- Primitive exit keys that remain source-visible after replay and select erasure. -/
def residualPrimitiveExitKeys (artifact : WireAdmissionArtifact) :
    List (NodeId × FieldLabel × ContractId) :=
  (PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps).filter fun key =>
    decide (key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps) &&
      !(artifact.selectInternalExitKeyCheck key)

/-- Executable checker that summary frontiers exactly match residual primitive frontiers. -/
def summaryFrontiersMatchPrimitiveCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.sameMembersCheck
      (artifact.entries.map AdmissionBoundaryPort.key)
      artifact.residualPrimitiveEntryKeys &&
    Check.sameMembersCheck
      (artifact.exits.map AdmissionBoundaryPort.key)
      artifact.residualPrimitiveExitKeys

/-- Successful frontier-exactness checking proves `SummaryFrontiersMatchPrimitive`. -/
theorem summaryFrontiersMatchPrimitiveCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.summaryFrontiersMatchPrimitiveCheck = true) :
    artifact.SummaryFrontiersMatchPrimitive := by
  unfold summaryFrontiersMatchPrimitiveCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  have hEntriesMembers := Check.sameMembersCheck_sound hCheck.left
  have hExitsMembers := Check.sameMembersCheck_sound hCheck.right
  constructor
  · intro key
    constructor
    · intro hSummary
      have hResidual : key ∈ artifact.residualPrimitiveEntryKeys :=
        (hEntriesMembers key).mp hSummary
      unfold residualPrimitiveEntryKeys at hResidual
      rw [List.mem_filter] at hResidual
      exact ⟨hResidual.left, of_decide_eq_true hResidual.right⟩
    · intro hPrimitive
      have hResidual : key ∈ artifact.residualPrimitiveEntryKeys := by
        unfold residualPrimitiveEntryKeys
        rw [List.mem_filter]
        exact ⟨hPrimitive.left, by simpa using decide_eq_true hPrimitive.right⟩
      exact (hEntriesMembers key).mpr hResidual
  · intro key
    constructor
    · intro hSummary
      have hResidual : key ∈ artifact.residualPrimitiveExitKeys :=
        (hExitsMembers key).mp hSummary
      unfold residualPrimitiveExitKeys at hResidual
      rw [List.mem_filter] at hResidual
      rw [Bool.and_eq_true] at hResidual
      have hNotConsumed :
          key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps :=
        of_decide_eq_true hResidual.right.left
      have hNotInternal : ¬ artifact.SelectInternalExitKey key := by
        intro hInternal
        have hInternalCheck : artifact.selectInternalExitKeyCheck key = true :=
          selectInternalExitKeyCheck_eq_true_iff.mpr hInternal
        rw [hInternalCheck] at hResidual
        simp at hResidual
      exact ⟨hResidual.left, hNotConsumed, hNotInternal⟩
    · intro hPrimitive
      have hResidual : key ∈ artifact.residualPrimitiveExitKeys := by
        unfold residualPrimitiveExitKeys
        rw [List.mem_filter]
        refine ⟨hPrimitive.left, ?_⟩
        rw [Bool.and_eq_true]
        constructor
        · exact decide_eq_true hPrimitive.right.left
        · cases hInternalCheck : artifact.selectInternalExitKeyCheck key with
          | false =>
              rfl
          | true =>
              have hInternal : artifact.SelectInternalExitKey key :=
                selectInternalExitKeyCheck_eq_true_iff.mp hInternalCheck
              exact False.elim (hPrimitive.right.right hInternal)
      exact (hExitsMembers key).mpr hResidual

/-- Executable checker that top-level raw connections match primitive connect projections. -/
def rawConnectionsMatchPrimitiveCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.permCheck artifact.connections
    (PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps)

/-- Successful raw-connection matching proves `RawConnectionsMatchPrimitive`. -/
theorem rawConnectionsMatchPrimitiveCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.rawConnectionsMatchPrimitiveCheck = true) :
    artifact.RawConnectionsMatchPrimitive :=
  Check.permCheck_sound hCheck

/-! ## Select Row Checks -/

/-- Executable checker for one select variant row. -/
def selectVariantValidCheck (variant : SelectVariantArtifact) : Bool :=
  decide variant.key.Valid &&
    decide variant.port.Valid &&
      decide (variant.key = variant.port.selectKey)

/-- Successful select-variant checking proves `SelectVariantArtifact.Valid`. -/
theorem selectVariantValidCheck_sound
    {variant : SelectVariantArtifact}
    (hCheck : selectVariantValidCheck variant = true) :
    variant.Valid := by
  unfold selectVariantValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hKey, hPort⟩, hCanonical⟩
  exact
    { keyValid := of_decide_eq_true hKey
    , portValid := of_decide_eq_true hPort
    , keyCanonical := by
        unfold SelectVariantArtifact.KeyCanonical
        exact of_decide_eq_true hCanonical
    }

/-- Executable checker for one select arm row. -/
def selectArmValidCheck (arm : SelectArmAdmissionArtifact) : Bool :=
  decide arm.sourceKey.Valid &&
    decide arm.canonicalKey.Valid &&
      boundaryPortsClosedCheck arm.bodyNodes arm.bodyEntries &&
        boundaryPortsClosedCheck arm.bodyNodes arm.bodyExits &&
          Check.nodupCheck arm.bodyNodes &&
            Check.nodupCheck arm.bodyEntryKeys &&
              Check.nodupCheck arm.bodyExitKeys &&
                Check.allDecide arm.bodyNodes NodeId.Valid &&
                  AdmissionArtifactCheck.boundaryPortsValidCheck arm.bodyEntries &&
                    AdmissionArtifactCheck.boundaryPortsValidCheck arm.bodyExits

/-- Successful select-arm checking proves `SelectArmAdmissionArtifact.Valid`. -/
theorem selectArmValidCheck_sound
    {arm : SelectArmAdmissionArtifact}
    (hCheck : selectArmValidCheck arm = true) :
    arm.Valid := by
  unfold selectArmValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨⟨⟨⟨⟨hSourceKey, hCanonicalKey⟩, hBodyEntriesClosed⟩,
      hBodyExitsClosed⟩, hBodyNodesUnique⟩, hBodyEntriesUnique⟩, hBodyExitsUnique⟩,
      hBodyNodesValid⟩, hBodyEntriesValid⟩, hBodyExitsValid⟩
  exact
    { sourceKeyValid := of_decide_eq_true hSourceKey
    , canonicalKeyValid := of_decide_eq_true hCanonicalKey
    , bodyBoundariesClosed :=
        ⟨ boundaryPortsClosedCheck_sound hBodyEntriesClosed
        , boundaryPortsClosedCheck_sound hBodyExitsClosed
        ⟩
    , bodyRowsUnique :=
        ⟨ Check.nodupCheck_sound hBodyNodesUnique
        , Check.nodupCheck_sound hBodyEntriesUnique
        , Check.nodupCheck_sound hBodyExitsUnique
        ⟩
    , bodyNodesValid := Check.allDecide_sound hBodyNodesValid
    , bodyEntriesValid :=
        AdmissionArtifactCheck.boundaryPortsValidCheck_sound hBodyEntriesValid
    , bodyExitsValid :=
        AdmissionArtifactCheck.boundaryPortsValidCheck_sound hBodyExitsValid
    }

/-- Executable checker that all variant ports share one exclusive output group. -/
def selectVariantsShareExclusiveGroupCheck :
    List SelectVariantArtifact → Bool
  | [] => false
  | variant :: variants =>
      match variant.port.exclusiveGroup with
      | none => false
      | some group =>
          Check.allDecide variants fun other =>
            other.port.exclusiveGroup = some group

/-- Successful exclusive-group checking proves `VariantsShareExclusiveGroup`. -/
theorem selectVariantsShareExclusiveGroupCheck_sound
    {variants : List SelectVariantArtifact}
    (hCheck : selectVariantsShareExclusiveGroupCheck variants = true) :
    ∃ owner index,
      ∀ variant, variant ∈ variants →
        variant.port.exclusiveGroup = some (owner, index) := by
  cases variants with
  | nil =>
      simp [selectVariantsShareExclusiveGroupCheck] at hCheck
  | cons variant variants =>
      cases hGroup : variant.port.exclusiveGroup with
      | none =>
          simp [selectVariantsShareExclusiveGroupCheck, hGroup] at hCheck
      | some group =>
          cases group with
          | mk owner index =>
              have hTail :
                  Check.allDecide variants
                    (fun other =>
                      other.port.exclusiveGroup = some (owner, index)) = true := by
                simpa [selectVariantsShareExclusiveGroupCheck, hGroup] using hCheck
              refine ⟨owner, index, ?_⟩
              intro candidate hCandidate
              simp at hCandidate
              rcases hCandidate with hHead | hTailMem
              ·
                  cases hHead
                  exact hGroup
              ·
                  exact Check.allDecide_sound hTail candidate hTailMem

/-- Executable checker for one select arm's persisted resolution mode. -/
def selectArmResolutionSoundCheck
    (variants : List SelectVariantArtifact)
    (arm : SelectArmAdmissionArtifact) :
    Bool :=
  match arm.mode with
  | SelectResolutionMode.resolvedByLabel =>
      decide (arm.sourceKey = arm.canonicalKey) &&
        Check.anyDecide variants (fun variant =>
          variant.key = arm.canonicalKey ∧
            variant.port.label = AdmissionPortLabel.label arm.sourceKey)
  | SelectResolutionMode.resolvedByContract =>
      Check.allDecide variants (fun variant =>
          variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) &&
        Check.allDecide variants (fun variant =>
          (variant.port.contract.name = arm.sourceKey.name ↔
            variant.key = arm.canonicalKey))

/-- Successful resolution-mode checking proves the relational resolution contract. -/
theorem selectArmResolutionSoundCheck_sound
    {variants : List SelectVariantArtifact}
    {arm : SelectArmAdmissionArtifact}
    (hCheck : selectArmResolutionSoundCheck variants arm = true) :
    match arm.mode with
    | SelectResolutionMode.resolvedByLabel =>
        arm.sourceKey = arm.canonicalKey ∧
          ∃ variant, variant ∈ variants ∧
            variant.key = arm.canonicalKey ∧
            variant.port.label = AdmissionPortLabel.label arm.sourceKey
    | SelectResolutionMode.resolvedByContract =>
        (∀ variant, variant ∈ variants →
          variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) ∧
          (∀ variant, variant ∈ variants →
            (variant.port.contract.name = arm.sourceKey.name ↔
              variant.key = arm.canonicalKey)) := by
  cases hMode : arm.mode with
  | resolvedByLabel =>
      unfold selectArmResolutionSoundCheck at hCheck
      rw [hMode] at hCheck
      rw [Bool.and_eq_true] at hCheck
      have hResult :
          arm.sourceKey = arm.canonicalKey ∧
            ∃ variant, variant ∈ variants ∧
              variant.key = arm.canonicalKey ∧
                variant.port.label = AdmissionPortLabel.label arm.sourceKey :=
        ⟨of_decide_eq_true hCheck.left, Check.anyDecide_sound hCheck.right⟩
      simpa [hMode] using hResult
  | resolvedByContract =>
      unfold selectArmResolutionSoundCheck at hCheck
      rw [hMode] at hCheck
      rw [Bool.and_eq_true] at hCheck
      have hResult :
          (∀ variant, variant ∈ variants →
            variant.port.label ≠ AdmissionPortLabel.label arm.sourceKey) ∧
            (∀ variant, variant ∈ variants →
              (variant.port.contract.name = arm.sourceKey.name ↔
                variant.key = arm.canonicalKey)) :=
        ⟨Check.allDecide_sound hCheck.left, Check.allDecide_sound hCheck.right⟩
      simpa [hMode] using hResult

/-- Executable checker for select-admission row-local facts. -/
def selectAdmissionRowsValidCheck
    (selectAdmission : SelectAdmissionArtifact) :
    Bool :=
  decide selectAdmission.owner.Valid &&
    decide selectAdmission.conditionNode.Valid &&
      Check.allBool selectAdmission.variants selectVariantValidCheck &&
        Check.allBool selectAdmission.arms selectArmValidCheck

/-- Successful row-local checking proves `SelectAdmissionArtifact.RowsValid`. -/
theorem selectAdmissionRowsValidCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    (hCheck : selectAdmissionRowsValidCheck selectAdmission = true) :
    selectAdmission.RowsValid := by
  unfold selectAdmissionRowsValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hOwner, hCondition⟩, hVariants⟩, hArms⟩
  exact
    { ownerValid := of_decide_eq_true hOwner
    , conditionNodeValid := of_decide_eq_true hCondition
    , variantsValid :=
        Check.allBool_sound hVariants
          (fun _variant _ hVariant =>
            selectVariantValidCheck_sound hVariant)
    , armsValid :=
        Check.allBool_sound hArms
          (fun _arm _ hArm =>
            selectArmValidCheck_sound hArm)
    }

/-- Executable checker for one select-admission artifact. -/
def selectAdmissionValidCheck
    (selectAdmission : SelectAdmissionArtifact) :
    Bool :=
  decide (selectAdmission.owner = selectAdmission.conditionNode) &&
    Check.permCheck selectAdmission.armCanonicalKeys
      selectAdmission.variantKeys &&
      Check.nodupCheck selectAdmission.variantKeys &&
        decide (2 ≤ selectAdmission.variants.length) &&
          selectVariantsShareExclusiveGroupCheck selectAdmission.variants &&
            Check.nodupCheck selectAdmission.armCanonicalKeys &&
              Check.nodupCheck selectAdmission.armSourceIndexes &&
                decide
                  (selectAdmission.armSourceIndexes =
                    List.range selectAdmission.arms.length) &&
                  selectAdmissionRowsValidCheck selectAdmission &&
                    Check.allBool selectAdmission.arms
                      (selectArmResolutionSoundCheck selectAdmission.variants)

/-- Successful select-admission checking proves `SelectAdmissionArtifact.Valid`. -/
theorem selectAdmissionValidCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    (hCheck : selectAdmissionValidCheck selectAdmission = true) :
    selectAdmission.Valid := by
  unfold selectAdmissionValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨⟨⟨⟨⟨hOwner, hCovered⟩, hVariantKeys⟩, hAtLeastTwo⟩,
      hExclusiveGroup⟩, hArmKeys⟩, hArmIndexes⟩, hArmIndexesCanonical⟩,
      hRows⟩, hResolution⟩
  exact
    { ownerMatchesCondition := by
        unfold SelectAdmissionArtifact.OwnerMatchesCondition
        exact of_decide_eq_true hOwner
    , keysCovered := Check.permCheck_sound hCovered
    , variantKeysUnique := Check.nodupCheck_sound hVariantKeys
    , variantsAtLeastTwo := by
        unfold SelectAdmissionArtifact.VariantsAtLeastTwo
        exact of_decide_eq_true hAtLeastTwo
    , variantsShareExclusiveGroup :=
        selectVariantsShareExclusiveGroupCheck_sound hExclusiveGroup
    , armCanonicalKeysUnique := Check.nodupCheck_sound hArmKeys
    , armSourceIndexesUnique := Check.nodupCheck_sound hArmIndexes
    , armSourceIndexesCanonical := by
        unfold SelectAdmissionArtifact.ArmSourceIndexesCanonical
        exact of_decide_eq_true hArmIndexesCanonical
    , rowsValid := selectAdmissionRowsValidCheck_sound hRows
    , armResolutionSound :=
        Check.allBool_sound hResolution
          (fun _arm _ hArm =>
            selectArmResolutionSoundCheck_sound hArm)
    }

/-- Executable checker that all select-admission artifacts are locally valid. -/
def selectsValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.selects selectAdmissionValidCheck

/-- Successful select-list checking proves `SelectsValid`. -/
theorem selectsValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectsValidCheck = true) :
    artifact.SelectsValid :=
  Check.allBool_sound hCheck
    (fun _selectAdmission _ hSelect =>
      selectAdmissionValidCheck_sound hSelect)

/-- Executable checker for component-row identity uniqueness. -/
def componentRowsUniqueCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.nodupMapCheck artifact.generatedForms GeneratedFormArtifact.binding &&
    Check.nodupMapCheck artifact.phantomAdapters PhantomAdapterArtifact.node &&
      Check.nodupMapCheck artifact.selects SelectAdmissionArtifact.conditionNode &&
        Check.nodupCheck artifact.componentRoleNodes

/-- Successful component-row checking proves `ComponentRowsUnique`. -/
theorem componentRowsUniqueCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.componentRowsUniqueCheck = true) :
    artifact.ComponentRowsUnique := by
  unfold componentRowsUniqueCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hGenerated, hPhantom⟩, hSelect⟩, hRoles⟩
  exact
    { generatedFormBindingsUnique := Check.nodupMapCheck_sound hGenerated
    , phantomAdapterNodesUnique := Check.nodupMapCheck_sound hPhantom
    , selectConditionNodesUnique := Check.nodupMapCheck_sound hSelect
    , componentRoleNodesUnique := Check.nodupCheck_sound hRoles
    }

/-- Executable checker for primitive graph-step row-local validity. -/
def primitiveStepsValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.primitiveSteps PrimitiveGraphStep.validCheck

/-- Successful primitive-step checking proves `PrimitiveStepsValid`. -/
theorem primitiveStepsValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveStepsValidCheck = true) :
    artifact.PrimitiveStepsValid := by
  exact
    Check.allBool_sound hCheck
      (fun primitiveStep _ hStepCheck =>
        PrimitiveGraphStep.validCheck_sound hStepCheck)

/-- Representative executable subset of `ValidatorReady`.

This is not a replacement for full validator readiness. It names the fields
covered by the current executable-checker strategy spike.
-/
structure ValidatorReadyCore (artifact : WireAdmissionArtifact) : Prop where
  schemaCurrent : artifact.SchemaCurrent
  summaryKeysUnique : artifact.SummaryKeysUnique
  summaryRowsValid : artifact.SummaryRowsValid
  summaryDomainClosed : artifact.SummaryDomainClosed
  summaryIdentitiesMatchPrimitive : artifact.SummaryIdentitiesMatchPrimitive
  summaryFrontiersBackedByPrimitive : artifact.SummaryFrontiersBackedByPrimitive
  summaryFrontiersMatchPrimitive : artifact.SummaryFrontiersMatchPrimitive
  rawConnectionsMatchPrimitive : artifact.RawConnectionsMatchPrimitive
  selectsValid : artifact.SelectsValid
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
  summaryDomainClosed := hReady.summaryDomainClosed
  summaryIdentitiesMatchPrimitive := hReady.summaryIdentitiesMatchPrimitive
  summaryFrontiersBackedByPrimitive := hReady.summaryFrontiersBackedByPrimitive
  summaryFrontiersMatchPrimitive := hReady.summaryFrontiersMatchPrimitive
  rawConnectionsMatchPrimitive := hReady.rawConnectionsMatchPrimitive
  selectsValid := hReady.selectsValid
  componentRowsUnique := hReady.componentRowsUnique
  primitiveStepsValid := hReady.primitiveStepsValid
  primitiveTraceStackValid := hReady.primitiveTraceStackValid

/-- Executable checker for the representative validator-ready core. -/
def validatorReadyCoreCheck (artifact : WireAdmissionArtifact) : Bool :=
  decide artifact.SchemaCurrent &&
    artifact.summaryKeysUniqueCheck &&
      artifact.summaryRowsValidCheck &&
        artifact.summaryDomainClosedCheck &&
          artifact.summaryIdentitiesMatchPrimitiveCheck &&
            artifact.summaryFrontiersBackedByPrimitiveCheck &&
              artifact.summaryFrontiersMatchPrimitiveCheck &&
                artifact.rawConnectionsMatchPrimitiveCheck &&
                  artifact.selectsValidCheck &&
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
    ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨hSchema, hSummaryKeys⟩, hSummaryRows⟩,
      hSummaryDomain⟩, hSummaryIdentities⟩, hSummaryBacked⟩, hSummaryFrontiers⟩,
      hRawConnections⟩, hSelects⟩, hComponentRows⟩, hPrimitiveSteps⟩, hPrimitiveTrace⟩
  exact
    { schemaCurrent := of_decide_eq_true hSchema
    , summaryKeysUnique := summaryKeysUniqueCheck_sound hSummaryKeys
    , summaryRowsValid := summaryRowsValidCheck_sound hSummaryRows
    , summaryDomainClosed := summaryDomainClosedCheck_sound hSummaryDomain
    , summaryIdentitiesMatchPrimitive :=
        summaryIdentitiesMatchPrimitiveCheck_sound hSummaryIdentities
    , summaryFrontiersBackedByPrimitive :=
        summaryFrontiersBackedByPrimitiveCheck_sound hSummaryBacked
    , summaryFrontiersMatchPrimitive :=
        summaryFrontiersMatchPrimitiveCheck_sound hSummaryFrontiers
    , rawConnectionsMatchPrimitive :=
        rawConnectionsMatchPrimitiveCheck_sound hRawConnections
    , selectsValid := selectsValidCheck_sound hSelects
    , componentRowsUnique := componentRowsUniqueCheck_sound hComponentRows
    , primitiveStepsValid := primitiveStepsValidCheck_sound hPrimitiveSteps
    , primitiveTraceStackValid := primitiveTraceStackValidCheck_sound hPrimitiveTrace
    }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
