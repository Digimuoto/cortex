import Cortex.Wire.AdmissionArtifact.Check
import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck

/-!
## Overview

Executable core checks for decoded Wire admission artifacts.

This module is a measurement slice for the Lean-owned validator strategy. It
does not decide the full `ValidatorReady` predicate. Instead, it groups a
representative core: schema version, summary invariants, component-domain
closure, local generated/select/phantom row validity, component-row uniqueness,
primitive row validity, and executable primitive stack replay.

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

/-- Executable checker for a boundary contraction being closed over a node summary. -/
def connectionClosedCheck
    (nodes : List NodeId)
    (connection : AdmissionConnection) :
    Bool :=
  boundaryPortClosedCheck nodes connection.fromPort &&
    boundaryPortClosedCheck nodes connection.toPort

/-- Successful connection-closure checking proves both endpoints are closed. -/
theorem connectionClosedCheck_sound
    {nodes : List NodeId}
    {connection : AdmissionConnection}
    (hCheck : connectionClosedCheck nodes connection = true) :
    connection.fromPort.ClosedOver nodes ∧ connection.toPort.ClosedOver nodes := by
  unfold connectionClosedCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ boundaryPortClosedCheck_sound hCheck.left
    , boundaryPortClosedCheck_sound hCheck.right
    ⟩

/-- Executable checker for boundary contraction lists being closed over a node summary. -/
def connectionsClosedCheck
    (nodes : List NodeId)
    (connections : List AdmissionConnection) :
    Bool :=
  Check.allBool connections (connectionClosedCheck nodes)

/-- Successful connection-list closure checking proves `ConnectionsClosed`. -/
theorem connectionsClosedCheck_sound
    {nodes : List NodeId}
    {connections : List AdmissionConnection}
    (hCheck : connectionsClosedCheck nodes connections = true) :
    ConnectionsClosed nodes connections :=
  Check.allBool_sound hCheck
    (fun _connection _ hConnection =>
      connectionClosedCheck_sound hConnection)

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

/-- Executable checker for primitive trace rows being closed over artifact summaries. -/
def primitiveStepDomainClosedCheck
    (nodes : List NodeId)
    (bindingRefs : List BindingName) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.node nodeId entries exits =>
      Check.memCheck nodeId nodes &&
        boundaryPortsClosedCheck nodes entries &&
          boundaryPortsClosedCheck nodes exits
  | PrimitiveGraphStep.bindingRef binding =>
      Check.memCheck binding bindingRefs
  | PrimitiveGraphStep.overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      Check.allDecide leftNodeIds (fun node => node ∈ nodes) &&
        Check.allDecide rightNodeIds (fun node => node ∈ nodes) &&
          Check.allDecide leftBindings (fun binding => binding ∈ bindingRefs) &&
            Check.allDecide rightBindings (fun binding => binding ∈ bindingRefs)
  | PrimitiveGraphStep.connect
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      boundaryPortsClosedCheck nodes leftExits &&
        boundaryPortsClosedCheck nodes rightEntries &&
          connectionsClosedCheck nodes matchedPairs &&
            boundaryPortsClosedCheck nodes unmatchedLeftExits &&
              boundaryPortsClosedCheck nodes unmatchedRightEntries

/-- Successful primitive-domain checking proves `PrimitiveGraphStep.DomainClosed`. -/
theorem primitiveStepDomainClosedCheck_sound
    {nodes : List NodeId}
    {bindingRefs : List BindingName}
    {primitiveStep : PrimitiveGraphStep}
    (hCheck : primitiveStepDomainClosedCheck nodes bindingRefs primitiveStep = true) :
    PrimitiveGraphStep.DomainClosed nodes bindingRefs primitiveStep := by
  cases primitiveStep with
  | empty =>
      exact trivial
  | node nodeId entries exits =>
      unfold primitiveStepDomainClosedCheck at hCheck
      simp only [Bool.and_eq_true] at hCheck
      rcases hCheck with ⟨⟨hNode, hEntries⟩, hExits⟩
      exact
        ⟨ Check.memCheck_sound hNode
        , boundaryPortsClosedCheck_sound hEntries
        , boundaryPortsClosedCheck_sound hExits
        ⟩
  | bindingRef binding =>
      exact Check.memCheck_sound hCheck
  | overlay leftNodeIds rightNodeIds leftBindings rightBindings =>
      unfold primitiveStepDomainClosedCheck at hCheck
      simp only [Bool.and_eq_true] at hCheck
      rcases hCheck with ⟨⟨⟨hLeftNodes, hRightNodes⟩, hLeftBindings⟩, hRightBindings⟩
      exact
        ⟨ Check.allDecide_sound hLeftNodes
        , Check.allDecide_sound hRightNodes
        , Check.allDecide_sound hLeftBindings
        , Check.allDecide_sound hRightBindings
        ⟩
  | connect leftExits rightEntries matchedPairs unmatchedLeftExits
      unmatchedRightEntries =>
      unfold primitiveStepDomainClosedCheck at hCheck
      simp only [Bool.and_eq_true] at hCheck
      rcases hCheck with
        ⟨⟨⟨⟨hLeftExits, hRightEntries⟩, hMatchedPairs⟩, hUnmatchedLeft⟩,
          hUnmatchedRight⟩
      exact
        ⟨ boundaryPortsClosedCheck_sound hLeftExits
        , boundaryPortsClosedCheck_sound hRightEntries
        , connectionsClosedCheck_sound hMatchedPairs
        , boundaryPortsClosedCheck_sound hUnmatchedLeft
        , boundaryPortsClosedCheck_sound hUnmatchedRight
        ⟩

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

/-! ## Primitive Prefix Checks -/

/-- Replay-order scan for primitive predicates whose truth depends on the trace prefix. -/
def primitivePrefixScanCheck
    (rowCheck : List PrimitiveGraphStep → PrimitiveGraphStep → Bool)
    (priorSteps : List PrimitiveGraphStep) :
    List PrimitiveGraphStep → Bool
  | [] =>
      true
  | primitiveStep :: primitiveSteps =>
      rowCheck priorSteps primitiveStep &&
        primitivePrefixScanCheck rowCheck (priorSteps ++ [primitiveStep]) primitiveSteps

/-- A successful prefix scan proves the row predicate at every trace position. -/
theorem primitivePrefixScanCheck_at_step_sound
    {rowCheck : List PrimitiveGraphStep → PrimitiveGraphStep → Bool}
    {rowPredicate : List PrimitiveGraphStep → PrimitiveGraphStep → Prop}
    (rowSound :
      ∀ priorSteps primitiveStep,
        rowCheck priorSteps primitiveStep = true →
          rowPredicate priorSteps primitiveStep)
    {priorSteps primitiveSteps : List PrimitiveGraphStep}
    (hCheck :
      primitivePrefixScanCheck rowCheck priorSteps primitiveSteps = true) :
    ∀ tracePrefix suffix primitiveStep,
      primitiveSteps = tracePrefix ++ [primitiveStep] ++ suffix →
        rowPredicate (priorSteps ++ tracePrefix) primitiveStep := by
  induction primitiveSteps generalizing priorSteps with
  | nil =>
      intro tracePrefix suffix primitiveStep hEq
      cases tracePrefix with
      | nil =>
          simp at hEq
      | cons traceHead traceTail =>
          simp at hEq
  | cons head tail ih =>
      unfold primitivePrefixScanCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      intro tracePrefix suffix primitiveStep hEq
      cases tracePrefix with
      | nil =>
          simp at hEq
          rcases hEq with ⟨hHead, _hTail⟩
          subst primitiveStep
          simpa using rowSound priorSteps head hCheck.left
      | cons traceHead traceTail =>
          simp at hEq
          rcases hEq with ⟨hHead, hTail⟩
          subst traceHead
          have hTailEq :
              tail = traceTail ++ [primitiveStep] ++ suffix := by
            simpa using hTail
          have hTailPredicate :=
            ih hCheck.right traceTail suffix primitiveStep hTailEq
          simpa [List.append_assoc] using hTailPredicate

/-- Row predicate for overlay ledgers being backed by primitive identity rows in prior steps. -/
def primitiveOverlayLedgersPrefixAvailableAt
    (priorSteps : List PrimitiveGraphStep) :
    PrimitiveGraphStep → Prop
  | PrimitiveGraphStep.empty =>
      True
  | PrimitiveGraphStep.node _node _entries _exits =>
      True
  | PrimitiveGraphStep.bindingRef _binding =>
      True
  | PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings =>
      (∀ node, node ∈ leftNodes ++ rightNodes →
        node ∈ PrimitiveGraphStep.nodeRowsList priorSteps) ∧
      (∀ binding, binding ∈ leftBindings ++ rightBindings →
        binding ∈ PrimitiveGraphStep.bindingRowsList priorSteps)
  | PrimitiveGraphStep.connect
      _leftExits _rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      True

/-- Row checker for overlay ledgers being backed by primitive identity rows in prior steps. -/
def primitiveOverlayLedgersPrefixStepCheck
    (priorSteps : List PrimitiveGraphStep) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.node _node _entries _exits =>
      true
  | PrimitiveGraphStep.bindingRef _binding =>
      true
  | PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings =>
      let nodeRows := PrimitiveGraphStep.nodeRowsList priorSteps
      let bindingRows := PrimitiveGraphStep.bindingRowsList priorSteps
      Check.allDecide (leftNodes ++ rightNodes) (fun node => node ∈ nodeRows) &&
        Check.allDecide (leftBindings ++ rightBindings)
          (fun binding => binding ∈ bindingRows)
  | PrimitiveGraphStep.connect
      _leftExits _rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      true

/-- Successful row checking proves overlay ledger prefix availability at that row. -/
theorem primitiveOverlayLedgersPrefixStepCheck_sound
    (priorSteps : List PrimitiveGraphStep)
    (primitiveStep : PrimitiveGraphStep)
    (hCheck : primitiveOverlayLedgersPrefixStepCheck priorSteps primitiveStep = true) :
    primitiveOverlayLedgersPrefixAvailableAt priorSteps primitiveStep := by
  cases primitiveStep with
  | empty =>
      exact trivial
  | node _node _entries _exits =>
      exact trivial
  | bindingRef _binding =>
      exact trivial
  | overlay leftNodes rightNodes leftBindings rightBindings =>
      unfold primitiveOverlayLedgersPrefixStepCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ Check.allDecide_sound hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩
  | connect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      exact trivial

/-- Executable checker for primitive overlay ledger replay-order availability. -/
def primitiveOverlayLedgersPrefixAvailableCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  primitivePrefixScanCheck primitiveOverlayLedgersPrefixStepCheck []
    artifact.primitiveSteps

/-- Successful overlay-prefix checking proves `PrimitiveOverlayLedgersPrefixAvailable`. -/
theorem primitiveOverlayLedgersPrefixAvailableCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveOverlayLedgersPrefixAvailableCheck = true) :
    artifact.PrimitiveOverlayLedgersPrefixAvailable := by
  intro tracePrefix suffix leftNodes rightNodes leftBindings rightBindings hTrace
  have hAt :=
    primitivePrefixScanCheck_at_step_sound
      primitiveOverlayLedgersPrefixStepCheck_sound
      hCheck tracePrefix suffix
      (PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings)
      hTrace
  simpa [primitiveOverlayLedgersPrefixAvailableAt] using hAt

/-- Row predicate for connect frontiers being backed by primitive node rows. -/
def primitiveConnectFrontiersBackedByNodesAt
    (artifact : WireAdmissionArtifact) :
    PrimitiveGraphStep → Prop
  | PrimitiveGraphStep.empty =>
      True
  | PrimitiveGraphStep.node _node _entries _exits =>
      True
  | PrimitiveGraphStep.bindingRef _binding =>
      True
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      True
  | PrimitiveGraphStep.connect
      leftExits rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      (∀ leftExit, leftExit ∈ leftExits →
        leftExit.key ∈
          PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps) ∧
      (∀ rightEntry, rightEntry ∈ rightEntries →
        rightEntry.key ∈
          PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps)

/-- Row checker for connect frontiers being backed by primitive node rows. -/
def primitiveConnectFrontiersBackedByNodesStepCheck
    (artifact : WireAdmissionArtifact) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.node _node _entries _exits =>
      true
  | PrimitiveGraphStep.bindingRef _binding =>
      true
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      true
  | PrimitiveGraphStep.connect
      leftExits rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      let nodeExitKeys := PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps
      let nodeEntryKeys := PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps
      Check.allDecide leftExits (fun leftExit => leftExit.key ∈ nodeExitKeys) &&
        Check.allDecide rightEntries (fun rightEntry => rightEntry.key ∈ nodeEntryKeys)

/-- Successful row checking proves connect frontier backing at that row. -/
theorem primitiveConnectFrontiersBackedByNodesStepCheck_sound
    {artifact : WireAdmissionArtifact}
    {primitiveStep : PrimitiveGraphStep}
    (hCheck :
      primitiveConnectFrontiersBackedByNodesStepCheck artifact primitiveStep = true) :
    primitiveConnectFrontiersBackedByNodesAt artifact primitiveStep := by
  cases primitiveStep with
  | empty =>
      exact trivial
  | node _node _entries _exits =>
      exact trivial
  | bindingRef _binding =>
      exact trivial
  | overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      exact trivial
  | connect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      unfold primitiveConnectFrontiersBackedByNodesStepCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ Check.allDecide_sound hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩

/-- Executable checker for primitive connect frontier node-row backing. -/
def primitiveConnectFrontiersBackedByNodesCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.allBool artifact.primitiveSteps
    (primitiveConnectFrontiersBackedByNodesStepCheck artifact)

/-- Successful connect-backing checking proves `PrimitiveConnectFrontiersBackedByNodes`. -/
theorem primitiveConnectFrontiersBackedByNodesCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveConnectFrontiersBackedByNodesCheck = true) :
    artifact.PrimitiveConnectFrontiersBackedByNodes := by
  intro leftExits rightEntries matchedPairs unmatchedLeftExits
    unmatchedRightEntries hStep
  have hAt :=
    Check.allBool_sound hCheck
      (fun _primitiveStep _hMem hPrimitiveStep =>
        primitiveConnectFrontiersBackedByNodesStepCheck_sound hPrimitiveStep)
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits
        unmatchedRightEntries)
      hStep
  simpa [primitiveConnectFrontiersBackedByNodesAt] using hAt

/-- Row predicate for connect frontiers being available and unconsumed in prior steps. -/
def primitiveConnectFrontiersPrefixAvailableAt
    (priorSteps : List PrimitiveGraphStep) :
    PrimitiveGraphStep → Prop
  | PrimitiveGraphStep.empty =>
      True
  | PrimitiveGraphStep.node _node _entries _exits =>
      True
  | PrimitiveGraphStep.bindingRef _binding =>
      True
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      True
  | PrimitiveGraphStep.connect
      leftExits rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      (∀ leftExit, leftExit ∈ leftExits →
        leftExit.key ∈ PrimitiveGraphStep.nodeExitKeysList priorSteps ∧
          leftExit.key ∉ PrimitiveGraphStep.consumedExitKeysList priorSteps) ∧
      (∀ rightEntry, rightEntry ∈ rightEntries →
        rightEntry.key ∈ PrimitiveGraphStep.nodeEntryKeysList priorSteps ∧
          rightEntry.key ∉ PrimitiveGraphStep.consumedEntryKeysList priorSteps)

/-- Row checker for connect frontiers being available and unconsumed in prior steps. -/
def primitiveConnectFrontiersPrefixStepCheck
    (priorSteps : List PrimitiveGraphStep) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.node _node _entries _exits =>
      true
  | PrimitiveGraphStep.bindingRef _binding =>
      true
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      true
  | PrimitiveGraphStep.connect
      leftExits rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      let availableExits := PrimitiveGraphStep.nodeExitKeysList priorSteps
      let consumedExits := PrimitiveGraphStep.consumedExitKeysList priorSteps
      let availableEntries := PrimitiveGraphStep.nodeEntryKeysList priorSteps
      let consumedEntries := PrimitiveGraphStep.consumedEntryKeysList priorSteps
      Check.allDecide leftExits
          (fun leftExit =>
            leftExit.key ∈ availableExits ∧ leftExit.key ∉ consumedExits) &&
        Check.allDecide rightEntries
          (fun rightEntry =>
            rightEntry.key ∈ availableEntries ∧ rightEntry.key ∉ consumedEntries)

/-- Successful row checking proves connect frontier prefix availability at that row. -/
theorem primitiveConnectFrontiersPrefixStepCheck_sound
    (priorSteps : List PrimitiveGraphStep)
    (primitiveStep : PrimitiveGraphStep)
    (hCheck : primitiveConnectFrontiersPrefixStepCheck priorSteps primitiveStep = true) :
    primitiveConnectFrontiersPrefixAvailableAt priorSteps primitiveStep := by
  cases primitiveStep with
  | empty =>
      exact trivial
  | node _node _entries _exits =>
      exact trivial
  | bindingRef _binding =>
      exact trivial
  | overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      exact trivial
  | connect leftExits rightEntries _matchedPairs _unmatchedLeftExits
      _unmatchedRightEntries =>
      unfold primitiveConnectFrontiersPrefixStepCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ Check.allDecide_sound hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩

/-- Executable checker for primitive connect frontier replay-order availability. -/
def primitiveConnectFrontiersPrefixAvailableCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  primitivePrefixScanCheck primitiveConnectFrontiersPrefixStepCheck []
    artifact.primitiveSteps

/-- Successful connect-prefix checking proves `PrimitiveConnectFrontiersPrefixAvailable`. -/
theorem primitiveConnectFrontiersPrefixAvailableCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveConnectFrontiersPrefixAvailableCheck = true) :
    artifact.PrimitiveConnectFrontiersPrefixAvailable := by
  intro tracePrefix suffix leftExits rightEntries matchedPairs unmatchedLeftExits
    unmatchedRightEntries hTrace
  have hAt :=
    primitivePrefixScanCheck_at_step_sound
      primitiveConnectFrontiersPrefixStepCheck_sound
      hCheck tracePrefix suffix
      (PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits
        unmatchedRightEntries)
      hTrace
  simpa [primitiveConnectFrontiersPrefixAvailableAt] using hAt

/-! ## Generated-Form Row Checks -/

mutual

/-- Executable checker for serialized static values in generated-form source rows. -/
def staticValueValidCheck : AdmissionStaticValue → Bool
  | AdmissionStaticValue.string _value =>
      true
  | AdmissionStaticValue.bool _value =>
      true
  | AdmissionStaticValue.nat _value =>
      true
  | AdmissionStaticValue.list values =>
      staticValueValuesValidCheck values
  | AdmissionStaticValue.record fields =>
      Check.nodupMapCheck fields Prod.fst &&
        staticValueFieldsValidCheck fields

/-- Executable checker for serialized static-value lists. -/
def staticValueValuesValidCheck : List AdmissionStaticValue → Bool
  | [] =>
      true
  | value :: values =>
      staticValueValidCheck value &&
        staticValueValuesValidCheck values

/-- Executable checker for serialized static record fields. -/
def staticValueFieldsValidCheck :
    List (FieldLabel × AdmissionStaticValue) → Bool
  | [] =>
      true
  | field :: fields =>
      decide field.fst.Valid &&
        staticValueValidCheck field.snd &&
          staticValueFieldsValidCheck fields

end

mutual

/-- Successful static-value checking proves `AdmissionStaticValue.Valid`. -/
theorem staticValueValidCheck_sound
    {value : AdmissionStaticValue}
    (hCheck : staticValueValidCheck value = true) :
    value.Valid := by
  cases value with
  | string value =>
      exact trivial
  | bool value =>
      exact trivial
  | nat value =>
      exact trivial
  | list values =>
      exact staticValueValuesValidCheck_sound hCheck
  | record fields =>
      unfold staticValueValidCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ Check.nodupMapCheck_sound hCheck.left
        , staticValueFieldsValidCheck_sound hCheck.right
        ⟩

/-- Successful static-value-list checking proves `AdmissionStaticValue.ValuesValid`. -/
theorem staticValueValuesValidCheck_sound
    {values : List AdmissionStaticValue}
    (hCheck : staticValueValuesValidCheck values = true) :
    AdmissionStaticValue.ValuesValid values := by
  cases values with
  | nil =>
      exact trivial
  | cons value values =>
      unfold staticValueValuesValidCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ staticValueValidCheck_sound hCheck.left
        , staticValueValuesValidCheck_sound hCheck.right
        ⟩

/-- Successful static-field checking proves `AdmissionStaticValue.FieldsValid`. -/
theorem staticValueFieldsValidCheck_sound
    {fields : List (FieldLabel × AdmissionStaticValue)}
    (hCheck : staticValueFieldsValidCheck fields = true) :
    AdmissionStaticValue.FieldsValid fields := by
  cases fields with
  | nil =>
      exact trivial
  | cons field fields =>
      cases field with
      | mk label value =>
          unfold staticValueFieldsValidCheck at hCheck
          simp only [Bool.and_eq_true] at hCheck
          rcases hCheck with ⟨⟨hLabel, hValue⟩, hFields⟩
          exact
            ⟨ of_decide_eq_true hLabel
            , staticValueValidCheck_sound hValue
            , staticValueFieldsValidCheck_sound hFields
            ⟩

end

/-- Executable checker for optional static payloads on generated source children. -/
def generatedChildSourceStaticValueValidCheck
    (child : GeneratedChildSourceArtifact) :
    Bool :=
  match child.value with
  | none => true
  | some value => staticValueValidCheck value

/-- Successful optional-payload checking proves source-child static payload validity. -/
theorem generatedChildSourceStaticValueValidCheck_sound
    {child : GeneratedChildSourceArtifact}
    (hCheck : generatedChildSourceStaticValueValidCheck child = true) :
    child.StaticValueValid := by
  cases hValue : child.value with
  | none =>
      simp [GeneratedChildSourceArtifact.StaticValueValid, hValue]
  | some value =>
      have hValueCheck : staticValueValidCheck value = true := by
        simpa [generatedChildSourceStaticValueValidCheck, hValue] using hCheck
      simpa [GeneratedChildSourceArtifact.StaticValueValid, hValue] using
        staticValueValidCheck_sound hValueCheck

/-- Executable checker for source generated-child row validity. -/
def generatedChildSourceValidCheck
    (child : GeneratedChildSourceArtifact) :
    Bool :=
  decide child.node.Valid &&
    decide child.label.Valid &&
      generatedChildSourceStaticValueValidCheck child

/-- Successful source-child checking proves `GeneratedChildSourceArtifact.Valid`. -/
theorem generatedChildSourceValidCheck_sound
    {child : GeneratedChildSourceArtifact}
    (hCheck : generatedChildSourceValidCheck child = true) :
    child.Valid := by
  unfold generatedChildSourceValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hNode, hLabel⟩, hStatic⟩
  exact
    { nodeValid := of_decide_eq_true hNode
    , labelValid := of_decide_eq_true hLabel
    , staticValueValid := generatedChildSourceStaticValueValidCheck_sound hStatic
    }

/-- Executable checker that generated-child frontiers are owned by the child node. -/
def generatedChildFrontiersOwnedCheck
    (child : GeneratedChildArtifact) :
    Bool :=
  Check.allDecide child.outputs (fun output => output.node = child.node) &&
    Check.allDecide child.inputs (fun input => input.node = child.node)

/-- Successful generated-child frontier ownership proves `FrontiersOwnedByChild`. -/
theorem generatedChildFrontiersOwnedCheck_sound
    {child : GeneratedChildArtifact}
    (hCheck : generatedChildFrontiersOwnedCheck child = true) :
    child.FrontiersOwnedByChild := by
  unfold generatedChildFrontiersOwnedCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.allDecide_sound hCheck.left
    , Check.allDecide_sound hCheck.right
    ⟩

/-- Executable checker that generated-child frontier keys are unique per direction. -/
def generatedChildFrontierKeysUniqueCheck
    (child : GeneratedChildArtifact) :
    Bool :=
  Check.nodupMapCheck child.outputs AdmissionBoundaryPort.key &&
    Check.nodupMapCheck child.inputs AdmissionBoundaryPort.key

/-- Successful generated-child frontier uniqueness proves `FrontierKeysUnique`. -/
theorem generatedChildFrontierKeysUniqueCheck_sound
    {child : GeneratedChildArtifact}
    (hCheck : generatedChildFrontierKeysUniqueCheck child = true) :
    child.FrontierKeysUnique := by
  unfold generatedChildFrontierKeysUniqueCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.nodupMapCheck_sound hCheck.left
    , Check.nodupMapCheck_sound hCheck.right
    ⟩

/-- Executable checker for used generated-child row validity. -/
def generatedChildValidCheck
    (child : GeneratedChildArtifact) :
    Bool :=
  decide child.node.Valid &&
    decide child.label.Valid &&
      generatedChildFrontiersOwnedCheck child &&
        generatedChildFrontierKeysUniqueCheck child &&
          AdmissionArtifactCheck.boundaryPortsValidCheck child.outputs &&
            AdmissionArtifactCheck.boundaryPortsValidCheck child.inputs

/-- Successful used-child checking proves `GeneratedChildArtifact.Valid`. -/
theorem generatedChildValidCheck_sound
    {child : GeneratedChildArtifact}
    (hCheck : generatedChildValidCheck child = true) :
    child.Valid := by
  unfold generatedChildValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨hNode, hLabel⟩, hOwned⟩, hUnique⟩, hOutputs⟩, hInputs⟩
  exact
    { nodeValid := of_decide_eq_true hNode
    , labelValid := of_decide_eq_true hLabel
    , frontiersOwnedByChild := generatedChildFrontiersOwnedCheck_sound hOwned
    , frontierKeysUnique := generatedChildFrontierKeysUniqueCheck_sound hUnique
    , outputsValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hOutputs
    , inputsValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hInputs
    }

/-- Executable checker for used generated-child domain closure. -/
def generatedChildDomainClosedCheck
    (nodes : List NodeId)
    (child : GeneratedChildArtifact) :
    Bool :=
  Check.memCheck child.node nodes &&
    boundaryPortsClosedCheck nodes child.outputs &&
      boundaryPortsClosedCheck nodes child.inputs

/-- Successful used-child closure checking proves `GeneratedChildArtifact.DomainClosed`. -/
theorem generatedChildDomainClosedCheck_sound
    {nodes : List NodeId}
    {child : GeneratedChildArtifact}
    (hCheck : generatedChildDomainClosedCheck nodes child = true) :
    child.DomainClosed nodes := by
  unfold generatedChildDomainClosedCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hNode, hOutputs⟩, hInputs⟩
  exact
    { nodeClosed := Check.memCheck_sound hNode
    , outputsClosed := boundaryPortsClosedCheck_sound hOutputs
    , inputsClosed := boundaryPortsClosedCheck_sound hInputs
    }

/-- Executable checker that used generated children are backed by source rows. -/
def generatedUsedChildrenFromSourceCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  Check.allDecide artifact.usedChildren fun child =>
    child.key ∈ artifact.sourceChildKeys

/-- Successful source-backing checking proves `UsedChildrenFromSource`. -/
theorem generatedUsedChildrenFromSourceCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedUsedChildrenFromSourceCheck artifact = true) :
    artifact.UsedChildrenFromSource :=
  Check.allDecide_sound hCheck

/-- Executable checker that generated child names follow the binding/label policy. -/
def generatedChildrenOwnedByBindingCheck
    (artifact : GeneratedFormArtifact) :
  Bool :=
  Check.allDecide artifact.sourceChildren
      (fun child =>
        child.node = GeneratedFormArtifact.childNodeFor artifact.binding child.label) &&
    Check.allDecide artifact.usedChildren
      (fun child =>
        child.node = GeneratedFormArtifact.childNodeFor artifact.binding child.label)

/-- Successful generated-name checking proves `ChildrenOwnedByBinding`. -/
theorem generatedChildrenOwnedByBindingCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedChildrenOwnedByBindingCheck artifact = true) :
    artifact.ChildrenOwnedByBinding := by
  unfold generatedChildrenOwnedByBindingCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.allDecide_sound hCheck.left
    , Check.allDecide_sound hCheck.right
    ⟩

/-- Executable checker that source and used generated child keys are duplicate-free. -/
def generatedChildKeysUniqueCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  Check.nodupCheck artifact.sourceChildKeys &&
    Check.nodupCheck artifact.usedChildKeys

/-- Successful generated-key checking proves `ChildKeysUnique`. -/
theorem generatedChildKeysUniqueCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedChildKeysUniqueCheck artifact = true) :
    artifact.ChildKeysUnique := by
  unfold generatedChildKeysUniqueCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact
    ⟨ Check.nodupCheck_sound hCheck.left
    , Check.nodupCheck_sound hCheck.right
    ⟩

/-- Executable checker that every generated source payload is structurally valid. -/
def generatedSourceValuesValidCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  Check.allBool artifact.sourceChildren generatedChildSourceStaticValueValidCheck

/-- Successful generated source-payload checking proves `SourceValuesValid`. -/
theorem generatedSourceValuesValidCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedSourceValuesValidCheck artifact = true) :
    artifact.SourceValuesValid :=
  Check.allBool_sound hCheck
    (fun _child _ hChild =>
      generatedChildSourceStaticValueValidCheck_sound hChild)

/-- Executable checker that `make` source labels are canonical. -/
def makeSourceLabelsCanonicalCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  decide
    (artifact.sourceLabels =
      (List.range artifact.sourceChildren.length).map (fun index => ⟨toString index⟩))

/-- Successful canonical-label checking proves `MakeSourceLabelsCanonical`. -/
theorem makeSourceLabelsCanonicalCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : makeSourceLabelsCanonicalCheck artifact = true) :
    artifact.MakeSourceLabelsCanonical := by
  unfold GeneratedFormArtifact.MakeSourceLabelsCanonical
  exact of_decide_eq_true hCheck

/-- Executable checker that a source child carries no static payload. -/
def generatedSourceValueEmptyCheck
    (child : GeneratedChildSourceArtifact) :
    Bool :=
  match child.value with
  | none => true
  | some _value => false

/-- Successful empty-payload checking proves the child payload is absent. -/
theorem generatedSourceValueEmptyCheck_sound
    {child : GeneratedChildSourceArtifact}
    (hCheck : generatedSourceValueEmptyCheck child = true) :
    child.value = none := by
  cases hValue : child.value with
  | none =>
      rfl
  | some value =>
      simp [generatedSourceValueEmptyCheck, hValue] at hCheck

/-- Executable checker that all source children carry no static payload. -/
def makeSourceValuesEmptyCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  Check.allBool artifact.sourceChildren generatedSourceValueEmptyCheck

/-- Successful empty-payload-list checking proves `MakeSourceValuesEmpty`. -/
theorem makeSourceValuesEmptyCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : makeSourceValuesEmptyCheck artifact = true) :
    artifact.MakeSourceValuesEmpty :=
  Check.allBool_sound hCheck
    (fun _child _ hChild =>
      generatedSourceValueEmptyCheck_sound hChild)

/-- Executable checker that generated-form payload shape matches its source form. -/
def generatedKindShapeMatchesCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  match artifact.kind with
  | GeneratedFormKind.make =>
      makeSourceLabelsCanonicalCheck artifact &&
        makeSourceValuesEmptyCheck artifact
  | GeneratedFormKind.makeEach =>
      true

/-- Successful generated-kind-shape checking proves `KindShapeMatches`. -/
theorem generatedKindShapeMatchesCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedKindShapeMatchesCheck artifact = true) :
    artifact.KindShapeMatches := by
  cases hKind : artifact.kind with
  | make =>
      unfold generatedKindShapeMatchesCheck at hCheck
      rw [hKind] at hCheck
      rw [Bool.and_eq_true] at hCheck
      unfold GeneratedFormArtifact.KindShapeMatches
      rw [hKind]
      exact
        ⟨ makeSourceLabelsCanonicalCheck_sound hCheck.left
        , makeSourceValuesEmptyCheck_sound hCheck.right
        ⟩
  | makeEach =>
      unfold GeneratedFormArtifact.KindShapeMatches
      rw [hKind]
      exact trivial

/-- Executable checker for generated-form row-local facts. -/
def generatedFormRowsValidCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  decide artifact.kindName.Valid &&
    decide artifact.binding.Valid &&
      Check.allBool artifact.sourceChildren generatedChildSourceValidCheck &&
        Check.allBool artifact.usedChildren generatedChildValidCheck

/-- Successful generated-form row checking proves `GeneratedFormArtifact.RowsValid`. -/
theorem generatedFormRowsValidCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedFormRowsValidCheck artifact = true) :
    artifact.RowsValid := by
  unfold generatedFormRowsValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hKind, hBinding⟩, hSourceChildren⟩, hUsedChildren⟩
  exact
    { kindNameValid := of_decide_eq_true hKind
    , bindingValid := of_decide_eq_true hBinding
    , sourceChildrenValid :=
        Check.allBool_sound hSourceChildren
          (fun _child _ hChild => generatedChildSourceValidCheck_sound hChild)
    , usedChildrenValid :=
        Check.allBool_sound hUsedChildren
          (fun _child _ hChild => generatedChildValidCheck_sound hChild)
    }

/-- Executable checker for one generated-form artifact. -/
def generatedFormValidCheck
    (artifact : GeneratedFormArtifact) :
    Bool :=
  generatedUsedChildrenFromSourceCheck artifact &&
    generatedChildrenOwnedByBindingCheck artifact &&
      generatedChildKeysUniqueCheck artifact &&
        generatedSourceValuesValidCheck artifact &&
          generatedKindShapeMatchesCheck artifact &&
            generatedFormRowsValidCheck artifact

/-- Successful generated-form checking proves `GeneratedFormArtifact.Valid`. -/
theorem generatedFormValidCheck_sound
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedFormValidCheck artifact = true) :
    artifact.Valid := by
  unfold generatedFormValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨hSource, hOwned⟩, hUnique⟩, hValues⟩, hShape⟩, hRows⟩
  exact
    { usedChildrenFromSource := generatedUsedChildrenFromSourceCheck_sound hSource
    , childrenOwnedByBinding := generatedChildrenOwnedByBindingCheck_sound hOwned
    , childKeysUnique := generatedChildKeysUniqueCheck_sound hUnique
    , sourceValuesValid := generatedSourceValuesValidCheck_sound hValues
    , kindShapeMatches := generatedKindShapeMatchesCheck_sound hShape
    , rowsValid := generatedFormRowsValidCheck_sound hRows
    }

/-- Executable checker for generated-form domain closure over the top-level node summary. -/
def generatedFormDomainClosedCheck
    (nodes : List NodeId)
    (artifact : GeneratedFormArtifact) :
    Bool :=
  Check.allBool artifact.usedChildren (generatedChildDomainClosedCheck nodes)

/-- Successful generated-form closure checking proves `GeneratedFormArtifact.DomainClosed`. -/
theorem generatedFormDomainClosedCheck_sound
    {nodes : List NodeId}
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedFormDomainClosedCheck nodes artifact = true) :
    artifact.DomainClosed nodes :=
  Check.allBool_sound hCheck
    (fun _child _ hChild =>
      generatedChildDomainClosedCheck_sound hChild)

/-- Executable checker that a generated-form row is anchored by used children
or an empty binding. -/
def generatedFormReferencedCheck
    (bindingRefs : List BindingName)
    (artifact : GeneratedFormArtifact) :
    Bool :=
  match artifact.usedChildren with
  | _child :: _children => true
  | [] =>
      match artifact.sourceChildren with
      | [] => Check.memCheck artifact.binding bindingRefs
      | _source :: _sources => false

/-- Successful generated-form reference checking proves the row is replay-addressable. -/
theorem generatedFormReferencedCheck_sound
    {bindingRefs : List BindingName}
    {artifact : GeneratedFormArtifact}
    (hCheck : generatedFormReferencedCheck bindingRefs artifact = true) :
    artifact.usedChildren ≠ [] ∨
      (artifact.sourceChildren = [] ∧ artifact.binding ∈ bindingRefs) := by
  rcases artifact with ⟨kind, kindName, binding, sourceChildren, usedChildren⟩
  cases usedChildren with
  | nil =>
      cases sourceChildren with
      | nil =>
          have hBinding : Check.memCheck binding bindingRefs = true := by
            simpa [generatedFormReferencedCheck] using hCheck
          exact Or.inr ⟨rfl, Check.memCheck_sound hBinding⟩
      | cons source sources =>
          simp [generatedFormReferencedCheck] at hCheck
  | cons child children =>
      exact Or.inl (by intro hEmpty; cases hEmpty)

/-! ## Phantom Adapter Row Checks -/

/-- Executable checker for duplicate-free record field labels in product-shape rows. -/
def productShapeFieldLabelsUniqueCheck
    (shape : ProductShapeArtifact) :
    Bool :=
  match shape with
  | ProductShapeArtifact.record _contract fields =>
      Check.nodupMapCheck fields Prod.fst
  | ProductShapeArtifact.indexed _element _count =>
      true

/-- Successful product field-label checking proves `ProductShapeArtifact.FieldLabelsUnique`. -/
theorem productShapeFieldLabelsUniqueCheck_sound
    {shape : ProductShapeArtifact}
    (hCheck : productShapeFieldLabelsUniqueCheck shape = true) :
    shape.FieldLabelsUnique := by
  cases shape with
  | record contract fields =>
      exact Check.nodupMapCheck_sound hCheck
  | indexed element count =>
      exact trivial

/-- Executable checker for product-shape contract and field-row validity. -/
def productShapeRowsValidCheck
    (shape : ProductShapeArtifact) :
    Bool :=
  match shape with
  | ProductShapeArtifact.record contract fields =>
      decide contract.Valid &&
        Check.allDecide fields (fun field => field.fst.Valid ∧ field.snd.Valid)
  | ProductShapeArtifact.indexed element _count =>
      decide element.Valid

/-- Successful product row checking proves `ProductShapeArtifact.RowsValid`. -/
theorem productShapeRowsValidCheck_sound
    {shape : ProductShapeArtifact}
    (hCheck : productShapeRowsValidCheck shape = true) :
    shape.RowsValid := by
  cases shape with
  | record contract fields =>
      unfold productShapeRowsValidCheck at hCheck
      rw [Bool.and_eq_true] at hCheck
      exact
        ⟨ of_decide_eq_true hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩
  | indexed element count =>
      show element.Valid
      exact of_decide_eq_true hCheck

/-- Executable checker that indexed product elements are not serialized nested products. -/
def productShapeIndexedElementNominalCheck
    (shape : ProductShapeArtifact) :
    Bool :=
  match shape with
  | ProductShapeArtifact.record _contract _fields =>
      true
  | ProductShapeArtifact.indexed element _count =>
      decide (element.name.startsWith "[" = false)

/-- Successful nested-product rejection proves `ProductShapeArtifact.IndexedElementNominal`. -/
theorem productShapeIndexedElementNominalCheck_sound
    {shape : ProductShapeArtifact}
    (hCheck : productShapeIndexedElementNominalCheck shape = true) :
    shape.IndexedElementNominal := by
  cases shape with
  | record contract fields =>
      exact trivial
  | indexed element count =>
      show element.name.startsWith "[" = false
      exact of_decide_eq_true hCheck

/-- Executable checker for serialized product-shape validity. -/
def productShapeValidCheck
    (shape : ProductShapeArtifact) :
    Bool :=
  productShapeFieldLabelsUniqueCheck shape &&
    productShapeRowsValidCheck shape &&
      productShapeIndexedElementNominalCheck shape

/-- Successful product-shape checking proves `ProductShapeArtifact.Valid`. -/
theorem productShapeValidCheck_sound
    {shape : ProductShapeArtifact}
    (hCheck : productShapeValidCheck shape = true) :
    shape.Valid := by
  unfold productShapeValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hFields, hRows⟩, hNominal⟩
  exact
    { fieldLabelsUnique := productShapeFieldLabelsUniqueCheck_sound hFields
    , rowsValid := productShapeRowsValidCheck_sound hRows
    , indexedElementNominal := productShapeIndexedElementNominalCheck_sound hNominal
    }

/-- Executable checker that multi-side boundaries match the serialized product shape. -/
def productShapeBoundariesMatchCheck
    (shape : ProductShapeArtifact)
    (multi : List AdmissionBoundaryPort) :
    Bool :=
  match shape with
  | ProductShapeArtifact.record _contract fields =>
      Check.permCheck (multi.filterMap AdmissionBoundaryPort.recordField) fields
  | ProductShapeArtifact.indexed element _count =>
      Check.allDecide multi (fun boundary => boundary.contract = element)

/-- Successful multi-side boundary checking proves `ProductShapeArtifact.BoundariesMatch`. -/
theorem productShapeBoundariesMatchCheck_sound
    {shape : ProductShapeArtifact}
    {multi : List AdmissionBoundaryPort}
    (hCheck : productShapeBoundariesMatchCheck shape multi = true) :
    shape.BoundariesMatch multi := by
  cases shape with
  | record contract fields =>
      exact Check.permCheck_sound hCheck
  | indexed element count =>
      exact Check.allDecide_sound hCheck

/-- Executable checker that a phantom row's multi-side length matches its product arity. -/
def phantomProductArityMatchesCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  decide (artifact.multi.length = artifact.productShape.arity)

/-- Successful arity checking proves `ProductArityMatches`. -/
theorem phantomProductArityMatchesCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomProductArityMatchesCheck artifact = true) :
    artifact.ProductArityMatches := by
  unfold PhantomAdapterArtifact.ProductArityMatches
  exact of_decide_eq_true hCheck

/-- Executable checker that a phantom row's multi-side boundary matches its product shape. -/
def phantomProductShapeMatchesMultiCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  productShapeBoundariesMatchCheck artifact.productShape artifact.multi

/-- Successful multi-side shape checking proves `ProductShapeMatchesMulti`. -/
theorem phantomProductShapeMatchesMultiCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomProductShapeMatchesMultiCheck artifact = true) :
    artifact.ProductShapeMatchesMulti :=
  productShapeBoundariesMatchCheck_sound hCheck

/-- Executable checker that the singular endpoint uses the aggregate product contract. -/
def phantomProductContractMatchesSingularCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  decide (artifact.singular.contract = artifact.productShape.contract)

/-- Successful singular-contract checking proves `ProductContractMatchesSingular`. -/
theorem phantomProductContractMatchesSingularCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomProductContractMatchesSingularCheck artifact = true) :
    artifact.ProductContractMatchesSingular := by
  unfold PhantomAdapterArtifact.ProductContractMatchesSingular
  exact of_decide_eq_true hCheck

/-- Executable checker that source-visible multi-side endpoints are duplicate-free. -/
def phantomMultiEndpointKeysUniqueCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  Check.nodupMapCheck artifact.multi AdmissionBoundaryPort.key

/-- Successful multi-endpoint checking proves `MultiEndpointKeysUnique`. -/
theorem phantomMultiEndpointKeysUniqueCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomMultiEndpointKeysUniqueCheck artifact = true) :
    artifact.MultiEndpointKeysUnique :=
  Check.nodupMapCheck_sound hCheck

/-- Executable checker that bulk endpoints match the phantom adapter direction. -/
def phantomBulkEndpointsMatchCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  match artifact.direction with
  | PhantomAdapterDirection.gather =>
      Check.allDecide artifact.leftBulk (fun pair =>
          pair.fromPort ∈ artifact.multi ∧ pair.toPort.node = artifact.node) &&
        Check.allDecide artifact.rightBulk (fun pair =>
          pair.fromPort.node = artifact.node ∧ pair.toPort = artifact.singular)
  | PhantomAdapterDirection.scatter =>
      Check.allDecide artifact.leftBulk (fun pair =>
          pair.fromPort = artifact.singular ∧ pair.toPort.node = artifact.node) &&
        Check.allDecide artifact.rightBulk (fun pair =>
          pair.fromPort.node = artifact.node ∧ pair.toPort ∈ artifact.multi)

/-- Successful bulk-endpoint checking proves `BulkEndpointsMatch`. -/
theorem phantomBulkEndpointsMatchCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomBulkEndpointsMatchCheck artifact = true) :
    artifact.BulkEndpointsMatch := by
  cases hDirection : artifact.direction with
  | gather =>
      unfold phantomBulkEndpointsMatchCheck at hCheck
      rw [hDirection] at hCheck
      rw [Bool.and_eq_true] at hCheck
      unfold PhantomAdapterArtifact.BulkEndpointsMatch
      rw [hDirection]
      exact
        ⟨ Check.allDecide_sound hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩
  | scatter =>
      unfold phantomBulkEndpointsMatchCheck at hCheck
      rw [hDirection] at hCheck
      rw [Bool.and_eq_true] at hCheck
      unfold PhantomAdapterArtifact.BulkEndpointsMatch
      rw [hDirection]
      exact
        ⟨ Check.allDecide_sound hCheck.left
        , Check.allDecide_sound hCheck.right
        ⟩

/-- Executable checker that bulk ledgers cover the source-visible endpoints exactly. -/
def phantomBulkEndpointPartitionCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  match artifact.direction with
  | PhantomAdapterDirection.gather =>
      Check.permCheck artifact.leftBulkSourceKeys
          (artifact.multi.map AdmissionBoundaryPort.key) &&
        Check.permCheck artifact.rightBulkTargetKeys [artifact.singular.key]
  | PhantomAdapterDirection.scatter =>
      Check.permCheck artifact.leftBulkSourceKeys [artifact.singular.key] &&
        Check.permCheck artifact.rightBulkTargetKeys
          (artifact.multi.map AdmissionBoundaryPort.key)

/-- Successful bulk-partition checking proves `BulkEndpointPartition`. -/
theorem phantomBulkEndpointPartitionCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomBulkEndpointPartitionCheck artifact = true) :
    artifact.BulkEndpointPartition := by
  cases hDirection : artifact.direction with
  | gather =>
      unfold phantomBulkEndpointPartitionCheck at hCheck
      rw [hDirection] at hCheck
      rw [Bool.and_eq_true] at hCheck
      unfold PhantomAdapterArtifact.BulkEndpointPartition
      rw [hDirection]
      exact
        ⟨ Check.permCheck_sound hCheck.left
        , Check.permCheck_sound hCheck.right
        ⟩
  | scatter =>
      unfold phantomBulkEndpointPartitionCheck at hCheck
      rw [hDirection] at hCheck
      rw [Bool.and_eq_true] at hCheck
      unfold PhantomAdapterArtifact.BulkEndpointPartition
      rw [hDirection]
      exact
        ⟨ Check.permCheck_sound hCheck.left
        , Check.permCheck_sound hCheck.right
        ⟩

/-- Executable checker for indexed multi-side compatibility-key uniqueness. -/
def phantomIndexedMultiCompatibilityKeysUniqueCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  match artifact.productShape with
  | ProductShapeArtifact.record _contract _fields =>
      true
  | ProductShapeArtifact.indexed _element _count =>
      Check.nodupMapCheck artifact.multi AdmissionBoundaryPort.compatibilityShape

/-- Successful indexed compatibility-key checking proves the indexed uniqueness obligation. -/
theorem phantomIndexedMultiCompatibilityKeysUniqueCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomIndexedMultiCompatibilityKeysUniqueCheck artifact = true) :
    artifact.IndexedMultiCompatibilityKeysUnique := by
  cases hShape : artifact.productShape with
  | record contract fields =>
      unfold PhantomAdapterArtifact.IndexedMultiCompatibilityKeysUnique
      rw [hShape]
      exact trivial
  | indexed element count =>
      unfold phantomIndexedMultiCompatibilityKeysUniqueCheck at hCheck
      rw [hShape] at hCheck
      unfold PhantomAdapterArtifact.IndexedMultiCompatibilityKeysUnique
      rw [hShape]
      exact Check.nodupMapCheck_sound hCheck

/-- Executable checker for phantom-adapter row-local facts. -/
def phantomAdapterRowsValidCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  decide artifact.node.Valid &&
    decide artifact.singular.Valid &&
      AdmissionArtifactCheck.boundaryPortsValidCheck artifact.multi &&
        AdmissionArtifactCheck.connectionsValidCheck artifact.leftBulk &&
          AdmissionArtifactCheck.connectionsValidCheck artifact.rightBulk

/-- Successful phantom row-local checking proves `PhantomAdapterArtifact.RowsValid`. -/
theorem phantomAdapterRowsValidCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomAdapterRowsValidCheck artifact = true) :
    artifact.RowsValid := by
  unfold phantomAdapterRowsValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨hNode, hSingular⟩, hMulti⟩, hLeftBulk⟩, hRightBulk⟩
  exact
    { nodeValid := of_decide_eq_true hNode
    , singularValid := of_decide_eq_true hSingular
    , multiValid := AdmissionArtifactCheck.boundaryPortsValidCheck_sound hMulti
    , leftBulkValid := AdmissionArtifactCheck.connectionsValidCheck_sound hLeftBulk
    , rightBulkValid := AdmissionArtifactCheck.connectionsValidCheck_sound hRightBulk
    }

/-- Executable checker for one phantom-adapter artifact. -/
def phantomAdapterValidCheck
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  productShapeValidCheck artifact.productShape &&
    phantomProductArityMatchesCheck artifact &&
      phantomProductShapeMatchesMultiCheck artifact &&
        phantomProductContractMatchesSingularCheck artifact &&
          phantomMultiEndpointKeysUniqueCheck artifact &&
            phantomBulkEndpointsMatchCheck artifact &&
              phantomBulkEndpointPartitionCheck artifact &&
                phantomIndexedMultiCompatibilityKeysUniqueCheck artifact &&
                  phantomAdapterRowsValidCheck artifact

/-- Successful phantom-adapter checking proves `PhantomAdapterArtifact.Valid`. -/
theorem phantomAdapterValidCheck_sound
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomAdapterValidCheck artifact = true) :
    artifact.Valid := by
  unfold phantomAdapterValidCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨⟨⟨⟨hShape, hArity⟩, hMultiShape⟩, hSingularContract⟩,
      hMultiUnique⟩, hBulkMatch⟩, hBulkPartition⟩, hIndexedUnique⟩, hRows⟩
  exact
    { productShapeValid := productShapeValidCheck_sound hShape
    , productArityMatches := phantomProductArityMatchesCheck_sound hArity
    , productShapeMatchesMulti :=
        phantomProductShapeMatchesMultiCheck_sound hMultiShape
    , productContractMatchesSingular :=
        phantomProductContractMatchesSingularCheck_sound hSingularContract
    , multiEndpointKeysUnique := phantomMultiEndpointKeysUniqueCheck_sound hMultiUnique
    , bulkEndpointsMatch := phantomBulkEndpointsMatchCheck_sound hBulkMatch
    , bulkEndpointPartition := phantomBulkEndpointPartitionCheck_sound hBulkPartition
    , indexedMultiCompatibilityKeysUnique :=
        phantomIndexedMultiCompatibilityKeysUniqueCheck_sound hIndexedUnique
    , rowsValid := phantomAdapterRowsValidCheck_sound hRows
    }

/-- Executable checker for phantom-adapter domain closure over the top-level node summary. -/
def phantomAdapterDomainClosedCheck
    (nodes : List NodeId)
    (artifact : PhantomAdapterArtifact) :
    Bool :=
  Check.memCheck artifact.node nodes &&
    boundaryPortClosedCheck nodes artifact.singular &&
      boundaryPortsClosedCheck nodes artifact.multi &&
        connectionsClosedCheck nodes artifact.leftBulk &&
          connectionsClosedCheck nodes artifact.rightBulk

/-- Successful phantom-adapter closure checking proves `PhantomAdapterArtifact.DomainClosed`. -/
theorem phantomAdapterDomainClosedCheck_sound
    {nodes : List NodeId}
    {artifact : PhantomAdapterArtifact}
    (hCheck : phantomAdapterDomainClosedCheck nodes artifact = true) :
    artifact.DomainClosed nodes := by
  unfold phantomAdapterDomainClosedCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨hNode, hSingular⟩, hMulti⟩, hLeftBulk⟩, hRightBulk⟩
  exact
    { nodeClosed := Check.memCheck_sound hNode
    , singularNodeClosed := (boundaryPortClosedCheck_sound hSingular).left
    , multiClosed := boundaryPortsClosedCheck_sound hMulti
    , leftBulkClosed := connectionsClosedCheck_sound hLeftBulk
    , rightBulkClosed := connectionsClosedCheck_sound hRightBulk
    }

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

/-- Executable checker for select-admission domain closure over the top-level node summary. -/
def selectAdmissionDomainClosedCheck
    (nodes : List NodeId)
    (selectAdmission : SelectAdmissionArtifact) :
    Bool :=
  Check.memCheck selectAdmission.owner nodes &&
    Check.memCheck selectAdmission.conditionNode nodes &&
      Check.allDecide selectAdmission.variants fun variant =>
        variant.port.node ∈ nodes

/-- Successful select-domain checking proves `SelectAdmissionArtifact.DomainClosed`. -/
theorem selectAdmissionDomainClosedCheck_sound
    {nodes : List NodeId}
    {selectAdmission : SelectAdmissionArtifact}
    (hCheck : selectAdmissionDomainClosedCheck nodes selectAdmission = true) :
    selectAdmission.DomainClosed nodes := by
  unfold selectAdmissionDomainClosedCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨hOwner, hCondition⟩, hVariants⟩
  exact
    { ownerClosed := Check.memCheck_sound hOwner
    , conditionNodeClosed := Check.memCheck_sound hCondition
    , variantPortsClosed := Check.allDecide_sound hVariants
    }

/-- Boolean exclusive-group ownership check for select condition-node internal exits. -/
def selectExitOwnedByConditionCheck
    (conditionNode : NodeId)
    (exit : AdmissionBoundaryPort) :
    Bool :=
  match exit.exclusiveGroup with
  | none => false
  | some (owner, _index) => decide (owner = conditionNode)

/-- Successful condition-owner checking returns the serialized exclusive-group index. -/
theorem selectExitOwnedByConditionCheck_sound
    {conditionNode : NodeId}
    {exit : AdmissionBoundaryPort}
    (hCheck : selectExitOwnedByConditionCheck conditionNode exit = true) :
    ∃ index, exit.exclusiveGroup = some (conditionNode, index) := by
  unfold selectExitOwnedByConditionCheck at hCheck
  cases hGroup : exit.exclusiveGroup with
  | none =>
      simp [hGroup] at hCheck
  | some group =>
      cases group with
      | mk owner index =>
          have hOwner : owner = conditionNode := by
            have hOwnerCheck : decide (owner = conditionNode) = true := by
              simpa [selectExitOwnedByConditionCheck, hGroup] using hCheck
            exact of_decide_eq_true hOwnerCheck
          exact ⟨index, by simp [hOwner]⟩

/-- Serialized condition-owned exits are accepted by the boolean owner check. -/
theorem selectExitOwnedByConditionCheck_complete
    {conditionNode : NodeId}
    {exit : AdmissionBoundaryPort}
    (hGroup : ∃ index, exit.exclusiveGroup = some (conditionNode, index)) :
    selectExitOwnedByConditionCheck conditionNode exit = true := by
  obtain ⟨index, hGroupEq⟩ := hGroup
  unfold selectExitOwnedByConditionCheck
  rw [hGroupEq]
  simp

/-- Boolean check that a finite list contains exactly one row satisfying `matchCheck`. -/
def uniqueBoolCheck
    {α : Type}
    [DecidableEq α]
    (items : List α)
    (matchCheck : α → Bool) :
    Bool :=
  match items.find? matchCheck with
  | none => false
  | some selected =>
      Check.allDecide items fun item =>
        matchCheck item = true → item = selected

/-- `List.find?` over a boolean predicate returns an item from the scanned list. -/
theorem find?_bool_mem
    {α : Type}
    {items : List α}
    {matchCheck : α → Bool}
    {selected : α}
    (hFind : items.find? matchCheck = some selected) :
    selected ∈ items ∧ matchCheck selected = true := by
  induction items with
  | nil =>
      simp at hFind
  | cons head tail ih =>
      simp only [List.find?_cons] at hFind
      cases hHead : matchCheck head with
      | false =>
          rw [hHead] at hFind
          have hTail := ih hFind
          exact ⟨List.mem_cons_of_mem head hTail.left, hTail.right⟩
      | true =>
          rw [hHead] at hFind
          cases hFind
          exact ⟨List.mem_cons_self, hHead⟩

/-- Successful finite uniqueness checking returns the unique matched item. -/
theorem uniqueBoolCheck_sound
    {α : Type}
    [DecidableEq α]
    {items : List α}
    {matchCheck : α → Bool}
    (hCheck : uniqueBoolCheck items matchCheck = true) :
    ∃ selected, selected ∈ items ∧ matchCheck selected = true ∧
      ∀ item, item ∈ items → matchCheck item = true → item = selected := by
  unfold uniqueBoolCheck at hCheck
  cases hFind : items.find? matchCheck with
  | none =>
      rw [hFind] at hCheck
      simp at hCheck
  | some selected =>
      rw [hFind] at hCheck
      have hSelected := find?_bool_mem hFind
      exact
        ⟨ selected
        , hSelected.left
        , hSelected.right
        , Check.allDecide_sound hCheck
        ⟩

/-- Boolean predicate for a variant-compatible select bridge entry. -/
def selectBridgeEntryMatchCheck
    (variant : SelectVariantArtifact)
    (entry : AdmissionBoundaryPort) :
    Bool :=
  decide (variant.port.CompatibleWith entry)

/-- Executable checker for unique select bridge entries. -/
def selectBridgeEntryUniqueCheck
    (variant : SelectVariantArtifact)
    (entries : List AdmissionBoundaryPort) :
    Bool :=
  uniqueBoolCheck entries (selectBridgeEntryMatchCheck variant)

/-- Successful bridge-entry uniqueness checking proves `SelectBridgeEntryUnique`. -/
theorem selectBridgeEntryUniqueCheck_sound
    {variant : SelectVariantArtifact}
    {entries : List AdmissionBoundaryPort}
    (hCheck : selectBridgeEntryUniqueCheck variant entries = true) :
    SelectBridgeEntryUnique variant entries := by
  obtain ⟨entry, hEntry, hMatch, hUnique⟩ :=
    uniqueBoolCheck_sound hCheck
  have hCompatible : variant.port.CompatibleWith entry :=
    of_decide_eq_true hMatch
  exact
    ⟨ entry
    , hEntry
    , hCompatible
    , fun other hOther hOtherCompatible =>
        hUnique other hOther (decide_eq_true hOtherCompatible)
    ⟩

/-- Boolean predicate for a variant-compatible, condition-owned select bridge exit. -/
def selectBridgeInternalExitMatchCheck
    (conditionNode : NodeId)
    (variant : SelectVariantArtifact)
    (exit : AdmissionBoundaryPort) :
    Bool :=
  decide (variant.port.CompatibleWith exit) &&
    selectExitOwnedByConditionCheck conditionNode exit

/-- Executable checker for unique select internal branch-choice exits. -/
def selectBridgeInternalExitUniqueCheck
    (conditionNode : NodeId)
    (variant : SelectVariantArtifact)
    (exits : List AdmissionBoundaryPort) :
    Bool :=
  uniqueBoolCheck exits
    (selectBridgeInternalExitMatchCheck conditionNode variant)

/-- Successful internal-exit uniqueness checking proves `SelectBridgeInternalExitUnique`. -/
theorem selectBridgeInternalExitUniqueCheck_sound
    {conditionNode : NodeId}
    {variant : SelectVariantArtifact}
    {exits : List AdmissionBoundaryPort}
    (hCheck :
      selectBridgeInternalExitUniqueCheck conditionNode variant exits = true) :
    SelectBridgeInternalExitUnique conditionNode variant exits := by
  obtain ⟨exit, hExit, hMatch, hUnique⟩ :=
    uniqueBoolCheck_sound hCheck
  unfold selectBridgeInternalExitMatchCheck at hMatch
  rw [Bool.and_eq_true] at hMatch
  have hCompatible : variant.port.CompatibleWith exit :=
    of_decide_eq_true hMatch.left
  have hGroup := selectExitOwnedByConditionCheck_sound hMatch.right
  exact
    ⟨ exit
    , hExit
    , hCompatible
    , hGroup
    , fun other hOther hOtherCompatible hOtherGroup =>
        hUnique other hOther (by
          unfold selectBridgeInternalExitMatchCheck
          rw [Bool.and_eq_true]
          exact
            ⟨ decide_eq_true hOtherCompatible
            , selectExitOwnedByConditionCheck_complete hOtherGroup
            ⟩)
    ⟩

/-- Row checker for one select condition-node primitive frontier row. -/
def selectBridgeFrontiersPrimitiveStepCheck
    (selectAdmission : SelectAdmissionArtifact) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.node node _entries exits =>
      decide (node = selectAdmission.conditionNode) &&
        Check.allBool selectAdmission.variants fun variant =>
          selectBridgeEntryUniqueCheck variant _entries &&
            selectBridgeInternalExitUniqueCheck
              selectAdmission.conditionNode variant exits
  | PrimitiveGraphStep.empty =>
      false
  | PrimitiveGraphStep.bindingRef _binding =>
      false
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      false
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      false

/-- Executable checker for one select row's primitive bridge frontier backing. -/
def selectBridgeFrontiersBackedByPrimitiveRowCheck
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact) :
    Bool :=
  artifact.primitiveSteps.any
    (selectBridgeFrontiersPrimitiveStepCheck selectAdmission)

/-- Successful row checking proves primitive bridge frontier backing for one select row. -/
theorem selectBridgeFrontiersBackedByPrimitiveRowCheck_sound
    {artifact : WireAdmissionArtifact}
    {selectAdmission : SelectAdmissionArtifact}
    (hCheck :
      selectBridgeFrontiersBackedByPrimitiveRowCheck artifact selectAdmission = true) :
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        ∀ variant, variant ∈ selectAdmission.variants →
          SelectBridgeEntryUnique variant entries ∧
            SelectBridgeInternalExitUnique selectAdmission.conditionNode variant exits := by
  unfold selectBridgeFrontiersBackedByPrimitiveRowCheck at hCheck
  rcases List.any_eq_true.mp hCheck with
    ⟨primitiveStep, hPrimitiveStep, hPrimitiveCheck⟩
  cases primitiveStep with
  | empty =>
      simp [selectBridgeFrontiersPrimitiveStepCheck] at hPrimitiveCheck
  | bindingRef _binding =>
      simp [selectBridgeFrontiersPrimitiveStepCheck] at hPrimitiveCheck
  | overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      simp [selectBridgeFrontiersPrimitiveStepCheck] at hPrimitiveCheck
  | connect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries =>
      simp [selectBridgeFrontiersPrimitiveStepCheck] at hPrimitiveCheck
  | node primitiveNode entries exits =>
      unfold selectBridgeFrontiersPrimitiveStepCheck at hPrimitiveCheck
      rw [Bool.and_eq_true] at hPrimitiveCheck
      have hNode : primitiveNode = selectAdmission.conditionNode :=
        of_decide_eq_true hPrimitiveCheck.left
      refine ⟨entries, exits, ?_, ?_⟩
      · simpa [hNode] using hPrimitiveStep
      · intro variant hVariant
        have hVariantCheck :=
          Check.allBool_sound hPrimitiveCheck.right
            (fun checkedVariant _ hCheck =>
              show
                SelectBridgeEntryUnique checkedVariant entries ∧
                  SelectBridgeInternalExitUnique
                    selectAdmission.conditionNode checkedVariant exits
              by
                rw [Bool.and_eq_true] at hCheck
                exact
                  ⟨ selectBridgeEntryUniqueCheck_sound hCheck.left
                  , selectBridgeInternalExitUniqueCheck_sound hCheck.right
                  ⟩)
            variant hVariant
        exact hVariantCheck

/-- Executable checker for primitive backing of all select condition bridge frontiers. -/
def selectBridgeFrontiersBackedByPrimitiveCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.allBool artifact.selects
    (selectBridgeFrontiersBackedByPrimitiveRowCheck artifact)

/-- Successful select bridge-frontier checking proves `SelectBridgeFrontiersBackedByPrimitive`. -/
theorem selectBridgeFrontiersBackedByPrimitiveCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectBridgeFrontiersBackedByPrimitiveCheck = true) :
    artifact.SelectBridgeFrontiersBackedByPrimitive :=
  Check.allBool_sound hCheck
    (fun _selectAdmission _ hSelect =>
      selectBridgeFrontiersBackedByPrimitiveRowCheck_sound hSelect)

/-- Row checker for condition-node bridge entries being consumed by primitive replay. -/
def selectBridgeEntriesConsumedPrimitiveStepCheck
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.node node entries _exits =>
      if node = selectAdmission.conditionNode then
        let matchedConnections :=
          PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps
        Check.allBool selectAdmission.variants fun variant =>
          Check.allDecide entries fun entry =>
            variant.port.CompatibleWith entry →
              { fromPort := variant.port, toPort := entry } ∈ matchedConnections
      else
        true
  | PrimitiveGraphStep.empty =>
      true
  | PrimitiveGraphStep.bindingRef _binding =>
      true
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      true
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      true

/-- Executable checker for consumed select bridge entries. -/
def selectBridgeEntriesConsumedCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.selects fun selectAdmission =>
    Check.allBool artifact.primitiveSteps
      (selectBridgeEntriesConsumedPrimitiveStepCheck artifact selectAdmission)

/-- Successful select bridge-entry consumption checking proves `SelectBridgeEntriesConsumed`. -/
theorem selectBridgeEntriesConsumedCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectBridgeEntriesConsumedCheck = true) :
    artifact.SelectBridgeEntriesConsumed := by
  intro selectAdmission hSelect entries exits hNode variant hVariant entry hEntry
    hCompatible
  have hSelectCheck :=
    Check.allBool_sound hCheck
      (fun checkedSelect _ hCheckedSelect =>
        Check.allBool_sound hCheckedSelect
          (fun primitiveStep _ hPrimitiveStep =>
            show
              selectBridgeEntriesConsumedPrimitiveStepCheck
                artifact checkedSelect primitiveStep = true by
              exact hPrimitiveStep))
      selectAdmission hSelect
  have hStepCheck :=
    hSelectCheck
      (PrimitiveGraphStep.node selectAdmission.conditionNode entries exits) hNode
  unfold selectBridgeEntriesConsumedPrimitiveStepCheck at hStepCheck
  simp at hStepCheck
  have hVariantCheck :=
    Check.allBool_sound hStepCheck
      (fun checkedVariant _ hCheckedVariant =>
        Check.allDecide_sound hCheckedVariant)
      variant hVariant
  exact hVariantCheck entry hEntry hCompatible

/-- Executable checker for the select identity-arm bridge-output branch. -/
def selectArmIdentityBodyShapeCheck
    (selectAdmission : SelectAdmissionArtifact)
    (exits : List AdmissionBoundaryPort)
    (arm : SelectArmAdmissionArtifact)
    (variant : SelectVariantArtifact) :
    Bool :=
  decide (arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) &&
    decide
      (SelectConditionBridgeOutputShapes selectAdmission exits =
        [variant.port.identityOutputShape])

/-- Successful identity-arm shape checking proves the identity branch. -/
theorem selectArmIdentityBodyShapeCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    {exits : List AdmissionBoundaryPort}
    {arm : SelectArmAdmissionArtifact}
    {variant : SelectVariantArtifact}
    (hCheck :
      selectArmIdentityBodyShapeCheck selectAdmission exits arm variant = true) :
    (arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
      SelectConditionBridgeOutputShapes selectAdmission exits =
        [variant.port.identityOutputShape] := by
  unfold selectArmIdentityBodyShapeCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, of_decide_eq_true hCheck.right⟩

/-- Executable checker for the non-identity select-arm bridge-output branch. -/
def selectArmNonIdentityBodyShapeCheck
    (selectAdmission : SelectAdmissionArtifact)
    (exits : List AdmissionBoundaryPort)
    (arm : SelectArmAdmissionArtifact)
    (variant : SelectVariantArtifact) :
    Bool :=
  decide
      (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
        [variant.port.compatibilityShape]) &&
    Check.permCheck
      (arm.bodyExits.map AdmissionBoundaryPort.outputShape)
      (SelectConditionBridgeOutputShapes selectAdmission exits)

/-- Successful non-identity arm shape checking proves the body-boundary branch. -/
theorem selectArmNonIdentityBodyShapeCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    {exits : List AdmissionBoundaryPort}
    {arm : SelectArmAdmissionArtifact}
    {variant : SelectVariantArtifact}
    (hCheck :
      selectArmNonIdentityBodyShapeCheck selectAdmission exits arm variant = true) :
    arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
        [variant.port.compatibilityShape] ∧
      (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
        (SelectConditionBridgeOutputShapes selectAdmission exits) := by
  unfold selectArmNonIdentityBodyShapeCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  exact ⟨of_decide_eq_true hCheck.left, Check.permCheck_sound hCheck.right⟩

/-- Executable checker for one select arm's body boundary shape. -/
def selectArmBodyBoundaryShapeCheck
    (selectAdmission : SelectAdmissionArtifact)
    (exits : List AdmissionBoundaryPort)
    (arm : SelectArmAdmissionArtifact)
    (variant : SelectVariantArtifact) :
    Bool :=
  decide (variant.key = arm.canonicalKey) &&
    (selectArmIdentityBodyShapeCheck selectAdmission exits arm variant ||
      selectArmNonIdentityBodyShapeCheck selectAdmission exits arm variant)

/-- Successful arm-boundary shape checking proves the relational branch shape. -/
theorem selectArmBodyBoundaryShapeCheck_sound
    {selectAdmission : SelectAdmissionArtifact}
    {exits : List AdmissionBoundaryPort}
    {arm : SelectArmAdmissionArtifact}
    {variant : SelectVariantArtifact}
    (hCheck :
      selectArmBodyBoundaryShapeCheck selectAdmission exits arm variant = true) :
    variant.key = arm.canonicalKey ∧
      (((arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
          SelectConditionBridgeOutputShapes selectAdmission exits =
            [variant.port.identityOutputShape]) ∨
        (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
            [variant.port.compatibilityShape] ∧
          (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
            (SelectConditionBridgeOutputShapes selectAdmission exits))) := by
  unfold selectArmBodyBoundaryShapeCheck at hCheck
  rw [Bool.and_eq_true] at hCheck
  have hKey : variant.key = arm.canonicalKey :=
    of_decide_eq_true hCheck.left
  cases hIdentity :
      selectArmIdentityBodyShapeCheck selectAdmission exits arm variant with
  | true =>
      exact
        ⟨ hKey
        , Or.inl (selectArmIdentityBodyShapeCheck_sound hIdentity)
        ⟩
  | false =>
      have hBody :
          selectArmNonIdentityBodyShapeCheck selectAdmission exits arm variant =
            true := by
        simpa [hIdentity] using hCheck.right
      exact
        ⟨ hKey
        , Or.inr (selectArmNonIdentityBodyShapeCheck_sound hBody)
        ⟩

/-- Row checker for all select-arm bodies against one condition-node primitive row. -/
def selectArmBodyBoundariesPrimitiveStepCheck
    (selectAdmission : SelectAdmissionArtifact) :
    PrimitiveGraphStep → Bool
  | PrimitiveGraphStep.node node _entries exits =>
      decide (node = selectAdmission.conditionNode) &&
        Check.allBool selectAdmission.arms fun arm =>
          selectAdmission.variants.any fun variant =>
            selectArmBodyBoundaryShapeCheck selectAdmission exits arm variant
  | PrimitiveGraphStep.empty =>
      false
  | PrimitiveGraphStep.bindingRef _binding =>
      false
  | PrimitiveGraphStep.overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      false
  | PrimitiveGraphStep.connect _leftExits _rightEntries _matchedPairs
      _unmatchedLeftExits _unmatchedRightEntries =>
      false

/-- Executable checker for one select row's latent arm body boundary facts. -/
def selectArmBodyBoundariesMatchConditionRowCheck
    (artifact : WireAdmissionArtifact)
    (selectAdmission : SelectAdmissionArtifact) :
    Bool :=
  artifact.primitiveSteps.any
    (selectArmBodyBoundariesPrimitiveStepCheck selectAdmission)

/-- Successful row checking proves body-boundary facts for one select row. -/
theorem selectArmBodyBoundariesMatchConditionRowCheck_sound
    {artifact : WireAdmissionArtifact}
    {selectAdmission : SelectAdmissionArtifact}
    (hCheck :
      selectArmBodyBoundariesMatchConditionRowCheck artifact selectAdmission =
        true) :
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        ∀ arm, arm ∈ selectAdmission.arms →
          ∃ variant, variant ∈ selectAdmission.variants ∧
            variant.key = arm.canonicalKey ∧
            (((arm.bodyNodes = [] ∧ arm.bodyEntries = [] ∧ arm.bodyExits = []) ∧
                SelectConditionBridgeOutputShapes selectAdmission exits =
                  [variant.port.identityOutputShape]) ∨
              (arm.bodyEntries.map AdmissionBoundaryPort.compatibilityShape =
                  [variant.port.compatibilityShape] ∧
                (arm.bodyExits.map AdmissionBoundaryPort.outputShape).Perm
                  (SelectConditionBridgeOutputShapes selectAdmission exits))) := by
  unfold selectArmBodyBoundariesMatchConditionRowCheck at hCheck
  rcases List.any_eq_true.mp hCheck with
    ⟨primitiveStep, hPrimitiveStep, hPrimitiveCheck⟩
  cases primitiveStep with
  | empty =>
      simp [selectArmBodyBoundariesPrimitiveStepCheck] at hPrimitiveCheck
  | bindingRef _binding =>
      simp [selectArmBodyBoundariesPrimitiveStepCheck] at hPrimitiveCheck
  | overlay _leftNodes _rightNodes _leftBindings _rightBindings =>
      simp [selectArmBodyBoundariesPrimitiveStepCheck] at hPrimitiveCheck
  | connect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries =>
      simp [selectArmBodyBoundariesPrimitiveStepCheck] at hPrimitiveCheck
  | node primitiveNode entries exits =>
      unfold selectArmBodyBoundariesPrimitiveStepCheck at hPrimitiveCheck
      rw [Bool.and_eq_true] at hPrimitiveCheck
      have hNode : primitiveNode = selectAdmission.conditionNode :=
        of_decide_eq_true hPrimitiveCheck.left
      refine ⟨entries, exits, ?_, ?_⟩
      · simpa [hNode] using hPrimitiveStep
      · intro arm hArm
        have hArmCheck :=
          Check.allBool_sound hPrimitiveCheck.right
            (fun checkedArm _ hCheckedArm =>
              show
                ∃ variant, variant ∈ selectAdmission.variants ∧
                  variant.key = checkedArm.canonicalKey ∧
                  (((checkedArm.bodyNodes = [] ∧ checkedArm.bodyEntries = [] ∧
                        checkedArm.bodyExits = []) ∧
                      SelectConditionBridgeOutputShapes selectAdmission exits =
                        [variant.port.identityOutputShape]) ∨
                    (checkedArm.bodyEntries.map
                          AdmissionBoundaryPort.compatibilityShape =
                        [variant.port.compatibilityShape] ∧
                      (checkedArm.bodyExits.map
                          AdmissionBoundaryPort.outputShape).Perm
                        (SelectConditionBridgeOutputShapes selectAdmission exits))) by
                rcases List.any_eq_true.mp hCheckedArm with
                  ⟨variant, hVariant, hVariantCheck⟩
                exact
                  ⟨ variant
                  , hVariant
                  , selectArmBodyBoundaryShapeCheck_sound hVariantCheck
                  ⟩)
            arm hArm
        exact hArmCheck

/-- Executable checker for all select arm body boundary facts. -/
def selectArmBodyBoundariesMatchConditionCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.allBool artifact.selects
    (selectArmBodyBoundariesMatchConditionRowCheck artifact)

/-- Successful select arm body-boundary checking proves `SelectArmBodyBoundariesMatchCondition`. -/
theorem selectArmBodyBoundariesMatchConditionCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectArmBodyBoundariesMatchConditionCheck = true) :
    artifact.SelectArmBodyBoundariesMatchCondition :=
  Check.allBool_sound hCheck
    (fun _selectAdmission _ hSelect =>
      selectArmBodyBoundariesMatchConditionRowCheck_sound hSelect)

/-- Executable checker that latent select body nodes are fresh from the top-level summary. -/
def selectArmBodyNodesFreshFromSummaryCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.allBool artifact.selects fun selectAdmission =>
    Check.allBool selectAdmission.arms fun arm =>
      Check.allDecide arm.bodyNodes fun node =>
        node ∉ artifact.nodes

/-- Successful freshness checking proves `SelectArmBodyNodesFreshFromSummary`. -/
theorem selectArmBodyNodesFreshFromSummaryCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectArmBodyNodesFreshFromSummaryCheck = true) :
    artifact.SelectArmBodyNodesFreshFromSummary := by
  intro selectAdmission hSelect arm hArm node hNode
  have hSelectCheck :=
    Check.allBool_sound hCheck
      (fun checkedSelect _ hCheckedSelect =>
        Check.allBool_sound hCheckedSelect
          (fun checkedArm _ hCheckedArm =>
            Check.allDecide_sound hCheckedArm))
      selectAdmission hSelect
  have hArmCheck := hSelectCheck arm hArm
  exact hArmCheck node hNode

/-- Row-pair checker that latent select arm body nodes are pairwise disjoint. -/
def selectArmBodyNodesDisjointPairCheck
    (left right : SelectArmAdmissionArtifact) :
    Bool :=
  if left.canonicalKey = right.canonicalKey then
    true
  else
    Check.allDecide left.bodyNodes fun node =>
      node ∉ right.bodyNodes

/-- Successful row-pair checking proves body-node disjointness for distinct canonical keys. -/
theorem selectArmBodyNodesDisjointPairCheck_sound
    {left right : SelectArmAdmissionArtifact}
    (hCheck : selectArmBodyNodesDisjointPairCheck left right = true)
    (hKeys : left.canonicalKey ≠ right.canonicalKey) :
    ∀ node, node ∈ left.bodyNodes → node ∉ right.bodyNodes := by
  unfold selectArmBodyNodesDisjointPairCheck at hCheck
  rw [if_neg hKeys] at hCheck
  exact Check.allDecide_sound hCheck

/-- Executable checker that latent select arm body-node domains are pairwise disjoint. -/
def selectArmBodyNodesPairwiseDisjointCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  Check.allBool artifact.selects fun selectAdmission =>
    Check.allBool selectAdmission.arms fun left =>
      Check.allBool selectAdmission.arms fun right =>
        selectArmBodyNodesDisjointPairCheck left right

/-- Successful body-node disjointness checking proves `SelectArmBodyNodesPairwiseDisjoint`. -/
theorem selectArmBodyNodesPairwiseDisjointCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.selectArmBodyNodesPairwiseDisjointCheck = true) :
    artifact.SelectArmBodyNodesPairwiseDisjoint := by
  intro selectAdmission hSelect left hLeft right hRight hKeys node hNode
  have hSelectCheck :=
    Check.allBool_sound hCheck
      (fun checkedSelect _ hCheckedSelect =>
        Check.allBool_sound hCheckedSelect
          (fun checkedLeft _ hCheckedLeft =>
            Check.allBool_sound hCheckedLeft
              (fun checkedRight _ hCheckedRight =>
                show
                  selectArmBodyNodesDisjointPairCheck
                    checkedLeft checkedRight = true by
                  exact hCheckedRight)))
      selectAdmission hSelect
  have hLeftCheck := hSelectCheck left hLeft
  have hRightCheck := hLeftCheck right hRight
  exact selectArmBodyNodesDisjointPairCheck_sound hRightCheck hKeys node hNode

/-- Executable checker for all component-domain closure obligations. -/
def componentDomainsClosedCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.primitiveSteps
      (primitiveStepDomainClosedCheck artifact.nodes artifact.bindingRefs) &&
    Check.allBool artifact.generatedForms
      (generatedFormDomainClosedCheck artifact.nodes) &&
      Check.allBool artifact.phantomAdapters
        (phantomAdapterDomainClosedCheck artifact.nodes) &&
        Check.allBool artifact.selects
          (selectAdmissionDomainClosedCheck artifact.nodes)

/-- Successful component-domain checking proves `ComponentDomainsClosed`. -/
theorem componentDomainsClosedCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.componentDomainsClosedCheck = true) :
    artifact.ComponentDomainsClosed := by
  unfold componentDomainsClosedCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with ⟨⟨⟨hPrimitive, hGenerated⟩, hPhantom⟩, hSelects⟩
  exact
    { primitiveStepsClosed :=
        Check.allBool_sound hPrimitive
          (fun _primitiveStep _ hPrimitiveStep =>
            primitiveStepDomainClosedCheck_sound hPrimitiveStep)
    , generatedFormsClosed :=
        Check.allBool_sound hGenerated
          (fun _generated _ hGenerated =>
            generatedFormDomainClosedCheck_sound hGenerated)
    , phantomAdaptersClosed :=
        Check.allBool_sound hPhantom
          (fun _phantom _ hPhantom =>
            phantomAdapterDomainClosedCheck_sound hPhantom)
    , selectsClosed :=
        Check.allBool_sound hSelects
          (fun _selectAdmission _ hSelect =>
            selectAdmissionDomainClosedCheck_sound hSelect)
    }

/-- Executable checker that generated-form rows are replay-addressable. -/
def generatedFormsReferencedCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.generatedForms
    (generatedFormReferencedCheck artifact.bindingRefs)

/-- Successful generated-form reference checking proves `GeneratedFormsReferenced`. -/
theorem generatedFormsReferencedCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.generatedFormsReferencedCheck = true) :
    artifact.GeneratedFormsReferenced :=
  Check.allBool_sound hCheck
    (fun _generated _ hGenerated =>
      generatedFormReferencedCheck_sound hGenerated)

/-- Executable checker that all generated-form rows are locally valid. -/
def generatedFormsValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.generatedForms generatedFormValidCheck

/-- Successful generated-form list checking proves `GeneratedFormsValid`. -/
theorem generatedFormsValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.generatedFormsValidCheck = true) :
    artifact.GeneratedFormsValid :=
  Check.allBool_sound hCheck
    (fun _generated _ hGenerated =>
      generatedFormValidCheck_sound hGenerated)

/-- Executable checker that all phantom-adapter rows are locally valid. -/
def phantomAdaptersValidCheck (artifact : WireAdmissionArtifact) : Bool :=
  Check.allBool artifact.phantomAdapters phantomAdapterValidCheck

/-- Successful phantom-adapter list checking proves `PhantomAdaptersValid`. -/
theorem phantomAdaptersValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.phantomAdaptersValidCheck = true) :
    artifact.PhantomAdaptersValid :=
  Check.allBool_sound hCheck
    (fun _phantom _ hPhantom =>
      phantomAdapterValidCheck_sound hPhantom)

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
  componentDomainsClosed : artifact.ComponentDomainsClosed
  selectsValid : artifact.SelectsValid
  componentRowsUnique : artifact.ComponentRowsUnique
  generatedFormsReferenced : artifact.GeneratedFormsReferenced
  generatedFormsValid : artifact.GeneratedFormsValid
  phantomAdaptersValid : artifact.PhantomAdaptersValid
  primitiveStepsValid : artifact.PrimitiveStepsValid
  primitiveTraceStackValid : artifact.PrimitiveTraceStackValid
  primitiveOverlayLedgersPrefixAvailable :
    artifact.PrimitiveOverlayLedgersPrefixAvailable
  primitiveConnectFrontiersBackedByNodes :
    artifact.PrimitiveConnectFrontiersBackedByNodes
  primitiveConnectFrontiersPrefixAvailable :
    artifact.PrimitiveConnectFrontiersPrefixAvailable
  selectBridgeFrontiersBackedByPrimitive :
    artifact.SelectBridgeFrontiersBackedByPrimitive
  selectBridgeEntriesConsumed : artifact.SelectBridgeEntriesConsumed
  selectArmBodyBoundariesMatchCondition :
    artifact.SelectArmBodyBoundariesMatchCondition
  selectArmBodyNodesFreshFromSummary :
    artifact.SelectArmBodyNodesFreshFromSummary
  selectArmBodyNodesPairwiseDisjoint :
    artifact.SelectArmBodyNodesPairwiseDisjoint

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
  componentDomainsClosed := hReady.componentDomainsClosed
  selectsValid := hReady.selectsValid
  componentRowsUnique := hReady.componentRowsUnique
  generatedFormsReferenced := hReady.generatedFormsReferenced
  generatedFormsValid := hReady.generatedFormsValid
  phantomAdaptersValid := hReady.phantomAdaptersValid
  primitiveStepsValid := hReady.primitiveStepsValid
  primitiveTraceStackValid := hReady.primitiveTraceStackValid
  primitiveOverlayLedgersPrefixAvailable :=
    hReady.primitiveOverlayLedgersPrefixAvailable
  primitiveConnectFrontiersBackedByNodes :=
    hReady.primitiveConnectFrontiersBackedByNodes
  primitiveConnectFrontiersPrefixAvailable :=
    hReady.primitiveConnectFrontiersPrefixAvailable
  selectBridgeFrontiersBackedByPrimitive :=
    hReady.selectBridgeFrontiersBackedByPrimitive
  selectBridgeEntriesConsumed := hReady.selectBridgeEntriesConsumed
  selectArmBodyBoundariesMatchCondition :=
    hReady.selectArmBodyBoundariesMatchCondition
  selectArmBodyNodesFreshFromSummary := hReady.selectArmBodyNodesFreshFromSummary
  selectArmBodyNodesPairwiseDisjoint := hReady.selectArmBodyNodesPairwiseDisjoint

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
                    artifact.componentDomainsClosedCheck &&
                      artifact.selectsValidCheck &&
                        artifact.componentRowsUniqueCheck &&
                          artifact.generatedFormsReferencedCheck &&
                            artifact.generatedFormsValidCheck &&
                              artifact.phantomAdaptersValidCheck &&
                                artifact.primitiveStepsValidCheck &&
                                  artifact.primitiveTraceStackValidCheck &&
                                    artifact.primitiveOverlayLedgersPrefixAvailableCheck &&
                                      artifact.primitiveConnectFrontiersBackedByNodesCheck &&
                                        artifact.primitiveConnectFrontiersPrefixAvailableCheck &&
                                          artifact.selectBridgeFrontiersBackedByPrimitiveCheck &&
                                            artifact.selectBridgeEntriesConsumedCheck &&
                                              artifact.selectArmBodyBoundariesMatchConditionCheck &&
                                                artifact.selectArmBodyNodesFreshFromSummaryCheck &&
                                                  artifact.selectArmBodyNodesPairwiseDisjointCheck

/-- Successful core checking proves the representative validator-ready core. -/
theorem validatorReadyCoreCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.validatorReadyCoreCheck = true) :
    artifact.ValidatorReadyCore := by
  unfold validatorReadyCoreCheck at hCheck
  simp only [Bool.and_eq_true] at hCheck
  rcases hCheck with
    ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨hSchema, hSummaryKeys⟩, hSummaryRows⟩,
      hSummaryDomain⟩, hSummaryIdentities⟩, hSummaryBacked⟩, hSummaryFrontiers⟩,
      hRawConnections⟩, hComponentDomains⟩, hSelects⟩, hComponentRows⟩,
      hGeneratedReferenced⟩, hGeneratedValid⟩, hPhantomValid⟩, hPrimitiveSteps⟩,
      hPrimitiveTrace⟩, hPrimitiveOverlayPrefix⟩, hPrimitiveConnectBacked⟩,
      hPrimitiveConnectPrefix⟩, hSelectBridgeFrontiers⟩, hSelectBridgeEntries⟩,
      hSelectArmBodyBoundaries⟩, hSelectArmBodyFresh⟩, hSelectArmBodyDisjoint⟩
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
    , componentDomainsClosed := componentDomainsClosedCheck_sound hComponentDomains
    , selectsValid := selectsValidCheck_sound hSelects
    , componentRowsUnique := componentRowsUniqueCheck_sound hComponentRows
    , generatedFormsReferenced :=
        generatedFormsReferencedCheck_sound hGeneratedReferenced
    , generatedFormsValid := generatedFormsValidCheck_sound hGeneratedValid
    , phantomAdaptersValid := phantomAdaptersValidCheck_sound hPhantomValid
    , primitiveStepsValid := primitiveStepsValidCheck_sound hPrimitiveSteps
    , primitiveTraceStackValid := primitiveTraceStackValidCheck_sound hPrimitiveTrace
    , primitiveOverlayLedgersPrefixAvailable :=
        primitiveOverlayLedgersPrefixAvailableCheck_sound hPrimitiveOverlayPrefix
    , primitiveConnectFrontiersBackedByNodes :=
        primitiveConnectFrontiersBackedByNodesCheck_sound hPrimitiveConnectBacked
    , primitiveConnectFrontiersPrefixAvailable :=
        primitiveConnectFrontiersPrefixAvailableCheck_sound hPrimitiveConnectPrefix
    , selectBridgeFrontiersBackedByPrimitive :=
        selectBridgeFrontiersBackedByPrimitiveCheck_sound hSelectBridgeFrontiers
    , selectBridgeEntriesConsumed :=
        selectBridgeEntriesConsumedCheck_sound hSelectBridgeEntries
    , selectArmBodyBoundariesMatchCondition :=
        selectArmBodyBoundariesMatchConditionCheck_sound hSelectArmBodyBoundaries
    , selectArmBodyNodesFreshFromSummary :=
        selectArmBodyNodesFreshFromSummaryCheck_sound hSelectArmBodyFresh
    , selectArmBodyNodesPairwiseDisjoint :=
        selectArmBodyNodesPairwiseDisjointCheck_sound hSelectArmBodyDisjoint
    }

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
