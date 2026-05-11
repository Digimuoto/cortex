import Cortex.Wire.AdmissionArtifact.Generated
import Cortex.Wire.AdmissionArtifact.Phantom
import Cortex.Wire.AdmissionArtifact.Primitive
import Cortex.Wire.AdmissionArtifact.Select

/-!
## Overview

Core top-level decoded Wire admission artifact shape and validator-ready contract.

This page defines the aggregate artifact record, primitive replay frames, summary/component
predicates, and the single `ValidatorReady` predicate mirrored by the Haskell validator.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Top-Level Artifact -/

/-- Decoded top-level admission artifact shape.

The Haskell JSON encoder emits the same fields under
`wireAdmissionMetadataKey`. Constructing this Lean record from that JSON is a
future validation step; this module names the target shape and the first
projections that feed existing Lean carriers.
-/
structure WireAdmissionArtifact where
  schemaVersion : Nat
  nodes : List NodeId
  bindingRefs : List BindingName
  entries : List AdmissionBoundaryPort
  exits : List AdmissionBoundaryPort
  connections : List AdmissionRawConnection
  primitiveSteps : List PrimitiveGraphStep
  generatedForms : List GeneratedFormArtifact
  phantomAdapters : List PhantomAdapterArtifact
  selects : List SelectAdmissionArtifact
  deriving Repr

namespace WireAdmissionArtifact

/-- The artifact uses the current schema version known to this proof module. -/
def SchemaCurrent (artifact : WireAdmissionArtifact) : Prop :=
  artifact.schemaVersion = currentSchemaVersion

/-- Node identities claimed by generated component rows.

Only used children appear here: source children that were pruned away still
document source generation, but they are not compiled primitive nodes with a
runtime component role.
-/
def generatedUsedChildNodes (artifact : WireAdmissionArtifact) : List NodeId :=
  (artifact.generatedForms.map
      (fun generated => generated.usedChildren.map GeneratedChildArtifact.node)).flatten

/-- Primitive nodes claimed by generated, phantom-adapter, or select component rows. -/
def componentRoleNodes (artifact : WireAdmissionArtifact) : List NodeId :=
  artifact.generatedUsedChildNodes ++
    artifact.phantomAdapters.map PhantomAdapterArtifact.node ++
    artifact.selects.map SelectAdmissionArtifact.conditionNode

/-- Replay frame for the primitive graph-step stack.

The Haskell artifact emits primitive rows in postorder. Nodes and empty graphs
push frames, binding references annotate the top frame, and overlay/connect
consume the two preceding frames. This carrier names the replay object without
turning the decoded JSON row into a proof term.
-/
structure PrimitiveTraceFrame where
  nodes : List NodeId
  bindingRefs : List BindingName
  entries : List AdmissionBoundaryPort
  exits : List AdmissionBoundaryPort
  connections : List AdmissionRawConnection
  deriving Repr

namespace PrimitiveTraceFrame

/-- Empty primitive replay frame. -/
def empty : PrimitiveTraceFrame where
  nodes := []
  bindingRefs := []
  entries := []
  exits := []
  connections := []

/-- Singleton primitive replay frame for a node frontier row. -/
def nodeFrame
    (node : NodeId)
    (entries exits : List AdmissionBoundaryPort) :
    PrimitiveTraceFrame where
  nodes := [node]
  bindingRefs := []
  entries := entries
  exits := exits
  connections := []

/-- A replay frame has exactly the top-level artifact summary rows. -/
def MatchesSummary (frame : PrimitiveTraceFrame) (artifact : WireAdmissionArtifact) : Prop :=
  frame.nodes.Perm artifact.nodes ∧
    frame.bindingRefs.Perm artifact.bindingRefs ∧
    frame.entries.Perm artifact.entries ∧
    frame.exits.Perm artifact.exits ∧
    frame.connections.Perm artifact.connections

/-- Summary-matching replay frames carry exactly the serialized node summary. -/
theorem matchesSummary_nodes_perm
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact) :
    frame.nodes.Perm artifact.nodes :=
  hMatch.left

/-- Summary-matching replay frames carry exactly the serialized binding-ref summary. -/
theorem matchesSummary_bindingRefs_perm
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact) :
    frame.bindingRefs.Perm artifact.bindingRefs :=
  hMatch.right.left

/-- Summary-matching replay frames carry exactly the serialized entry summary. -/
theorem matchesSummary_entries_perm
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact) :
    frame.entries.Perm artifact.entries :=
  hMatch.right.right.left

/-- Summary-matching replay frames carry exactly the serialized exit summary. -/
theorem matchesSummary_exits_perm
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact) :
    frame.exits.Perm artifact.exits :=
  hMatch.right.right.right.left

/-- Summary-matching replay frames carry exactly the serialized raw-connection summary. -/
theorem matchesSummary_connections_perm
    {frame : PrimitiveTraceFrame}
    {artifact : WireAdmissionArtifact}
    (hMatch : frame.MatchesSummary artifact) :
    frame.connections.Perm artifact.connections :=
  hMatch.right.right.right.right

/-- Overlay replay merges the two operand ledgers. -/
def overlay (left right : PrimitiveTraceFrame) : PrimitiveTraceFrame where
  nodes := left.nodes ++ right.nodes
  bindingRefs := left.bindingRefs ++ right.bindingRefs
  entries := left.entries ++ right.entries
  exits := left.exits ++ right.exits
  connections := left.connections ++ right.connections

/-- Connect replay contracts the serialized matched pairs and keeps the residual frontier rows. -/
def connect
    (left right : PrimitiveTraceFrame)
    (matchedPairs : List AdmissionConnection)
    (unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort) :
    PrimitiveTraceFrame where
  nodes := left.nodes ++ right.nodes
  bindingRefs := left.bindingRefs ++ right.bindingRefs
  entries := left.entries ++ unmatchedRightEntries
  exits := unmatchedLeftExits ++ right.exits
  connections :=
    left.connections ++ right.connections ++
      matchedPairs.map (fun pair => AdmissionRawConnection.ofAdmissionConnection pair)

end PrimitiveTraceFrame

/-- One replay step for the primitive graph-step stack.

The hidden-exit predicate removes primitive bridge exits that are not
source-visible before the row enters the replay stack.
-/
inductive PrimitiveTraceStep (hiddenExit : AdmissionBoundaryPort → Prop) :
    List PrimitiveTraceFrame → PrimitiveGraphStep → List PrimitiveTraceFrame → Prop where
  | empty (stack : List PrimitiveTraceFrame) :
      PrimitiveTraceStep hiddenExit stack PrimitiveGraphStep.empty
        (PrimitiveTraceFrame.empty :: stack)
  | node (stack : List PrimitiveTraceFrame)
      (node : NodeId)
      (entries exits visibleExits : List AdmissionBoundaryPort)
      (hVisibleExits :
        ∀ exit, exit ∈ visibleExits ↔ exit ∈ exits ∧ ¬ hiddenExit exit) :
      PrimitiveTraceStep hiddenExit stack (PrimitiveGraphStep.node node entries exits)
        (PrimitiveTraceFrame.nodeFrame node entries visibleExits :: stack)
  | bindingRef
      (binding : BindingName)
      (frame : PrimitiveTraceFrame)
      (rest : List PrimitiveTraceFrame) :
      PrimitiveTraceStep hiddenExit (frame :: rest) (PrimitiveGraphStep.bindingRef binding)
        ({ frame with bindingRefs := binding :: frame.bindingRefs } :: rest)
  | overlay
      {left right : PrimitiveTraceFrame}
      {rest : List PrimitiveTraceFrame}
      {leftNodes rightNodes : List NodeId}
      {leftBindings rightBindings : List BindingName}
      (hLeftNodes : leftNodes.Perm left.nodes)
      (hRightNodes : rightNodes.Perm right.nodes)
      (hLeftBindings : leftBindings.Perm left.bindingRefs)
      (hRightBindings : rightBindings.Perm right.bindingRefs) :
      PrimitiveTraceStep hiddenExit (right :: left :: rest)
        (PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings)
        (PrimitiveTraceFrame.overlay left right :: rest)
  | connect
      {left right : PrimitiveTraceFrame}
      {rest : List PrimitiveTraceFrame}
      {leftExits rightEntries : List AdmissionBoundaryPort}
      {matchedPairs : List AdmissionConnection}
      {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
      (hLeftExits : leftExits.Perm left.exits)
      (hRightEntries : rightEntries.Perm right.entries)
      (hUnmatchedLeft :
        ((matchedPairs.map (fun pair => pair.fromPort)) ++ unmatchedLeftExits).Perm
          left.exits)
      (hUnmatchedRight :
        ((matchedPairs.map (fun pair => pair.toPort)) ++ unmatchedRightEntries).Perm
          right.entries) :
      PrimitiveTraceStep hiddenExit (right :: left :: rest)
        (PrimitiveGraphStep.connect
          leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries)
        (PrimitiveTraceFrame.connect
          left right matchedPairs unmatchedLeftExits unmatchedRightEntries :: rest)

/-- Replayed primitive empty rows push the empty frame onto the trace stack. -/
theorem primitiveTraceStep_empty_exact
    {hiddenExit : AdmissionBoundaryPort → Prop}
    {stack next : List PrimitiveTraceFrame}
    (hStep :
      PrimitiveTraceStep hiddenExit stack PrimitiveGraphStep.empty next) :
    next = PrimitiveTraceFrame.empty :: stack := by
  cases hStep with
  | empty _stack =>
      rfl

/-- Replayed primitive node rows expose the exact hidden-exit filter contract.

Haskell removes select-internal exits before a node row enters the primitive
trace stack. The Lean replay relation records the same condition as a
membership equivalence, abstracting away list order while preserving which exits
remain source-visible. -/
theorem primitiveTraceStep_node_visibleExits_exact
    {hiddenExit : AdmissionBoundaryPort → Prop}
    {stack next : List PrimitiveTraceFrame}
    {node : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hStep :
      PrimitiveTraceStep hiddenExit stack
        (PrimitiveGraphStep.node node entries exits)
        next) :
    ∃ visibleExits,
      next = PrimitiveTraceFrame.nodeFrame node entries visibleExits :: stack ∧
        ∀ exit, exit ∈ visibleExits ↔ exit ∈ exits ∧ ¬ hiddenExit exit := by
  cases hStep with
  | node _stack _node _entries _exits visibleExits hVisibleExits =>
      exact ⟨visibleExits, rfl, hVisibleExits⟩

/-- Replayed primitive binding rows extend exactly the current frame's binding ledger. -/
theorem primitiveTraceStep_bindingRef_exact
    {hiddenExit : AdmissionBoundaryPort → Prop}
    {binding : BindingName}
    {frame : PrimitiveTraceFrame}
    {rest next : List PrimitiveTraceFrame}
    (hStep :
      PrimitiveTraceStep hiddenExit (frame :: rest)
        (PrimitiveGraphStep.bindingRef binding)
        next) :
    next = { frame with bindingRefs := binding :: frame.bindingRefs } :: rest := by
  cases hStep with
  | bindingRef _binding _frame _rest =>
      rfl

/-- Replayed primitive overlay rows expose the exact operand-ledger contract. -/
theorem primitiveTraceStep_overlay_exact
    {hiddenExit : AdmissionBoundaryPort → Prop}
    {left right : PrimitiveTraceFrame}
    {rest next : List PrimitiveTraceFrame}
    {leftNodes rightNodes : List NodeId}
    {leftBindings rightBindings : List BindingName}
    (hStep :
      PrimitiveTraceStep hiddenExit (right :: left :: rest)
        (PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings)
        next) :
    next = PrimitiveTraceFrame.overlay left right :: rest ∧
      leftNodes.Perm left.nodes ∧
        rightNodes.Perm right.nodes ∧
          leftBindings.Perm left.bindingRefs ∧
            rightBindings.Perm right.bindingRefs := by
  cases hStep with
  | overlay hLeftNodes hRightNodes hLeftBindings hRightBindings =>
      exact
        ⟨ rfl
        , ⟨ hLeftNodes
          , ⟨ hRightNodes
            , ⟨ hLeftBindings, hRightBindings ⟩
            ⟩
          ⟩
        ⟩

/-- Replayed primitive connect rows expose the exact operand-frontier contract.

This is the Lean mirror of Haskell's stack replay check for `PrimitiveConnect`:
the serialized left exits and right entries must be the current operand frame
frontiers, and the matched/unmatched rows partition those frontiers exactly. -/
theorem primitiveTraceStep_connect_exact
    {hiddenExit : AdmissionBoundaryPort → Prop}
    {left right : PrimitiveTraceFrame}
    {rest next : List PrimitiveTraceFrame}
    {leftExits rightEntries : List AdmissionBoundaryPort}
    {matchedPairs : List AdmissionConnection}
    {unmatchedLeftExits unmatchedRightEntries : List AdmissionBoundaryPort}
    (hStep :
      PrimitiveTraceStep hiddenExit (right :: left :: rest)
        (PrimitiveGraphStep.connect
          leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries)
        next) :
    next =
        PrimitiveTraceFrame.connect
          left right matchedPairs unmatchedLeftExits unmatchedRightEntries :: rest ∧
      leftExits.Perm left.exits ∧
        rightEntries.Perm right.entries ∧
          ((matchedPairs.map (fun pair => pair.fromPort)) ++ unmatchedLeftExits).Perm
            left.exits ∧
            ((matchedPairs.map (fun pair => pair.toPort)) ++ unmatchedRightEntries).Perm
              right.entries := by
  cases hStep with
  | connect hLeftExits hRightEntries hUnmatchedLeft hUnmatchedRight =>
      exact
        ⟨ rfl
        , ⟨ hLeftExits
          , ⟨ hRightEntries
            , ⟨ hUnmatchedLeft, hUnmatchedRight ⟩
            ⟩
          ⟩
        ⟩

/-- Replay a list of primitive rows through the primitive graph-step stack. -/
inductive PrimitiveTraceReplays (hiddenExit : AdmissionBoundaryPort → Prop) :
    List PrimitiveGraphStep → List PrimitiveTraceFrame → List PrimitiveTraceFrame → Prop where
  | nil (stack : List PrimitiveTraceFrame) :
      PrimitiveTraceReplays hiddenExit [] stack stack
  | cons
      {step : PrimitiveGraphStep}
      {steps : List PrimitiveGraphStep}
      {before middle after : List PrimitiveTraceFrame}
      (hStep : PrimitiveTraceStep hiddenExit before step middle)
      (hRest : PrimitiveTraceReplays hiddenExit steps middle after) :
      PrimitiveTraceReplays hiddenExit (step :: steps) before after

/-- Top-level summary rows are unique by their source-level identities. -/
structure SummaryKeysUnique (artifact : WireAdmissionArtifact) : Prop where
  nodesUnique : artifact.nodes.Nodup
  bindingRefsUnique : artifact.bindingRefs.Nodup
  entriesUnique : (artifact.entries.map AdmissionBoundaryPort.key).Nodup
  exitsUnique : (artifact.exits.map AdmissionBoundaryPort.key).Nodup
  connectionsUnique : artifact.connections.Nodup

/-- Top-level summary rows carry structurally valid identifiers and boundary rows. -/
structure SummaryRowsValid (artifact : WireAdmissionArtifact) : Prop where
  nodesValid : ∀ node, node ∈ artifact.nodes → node.Valid
  bindingRefsValid : ∀ binding, binding ∈ artifact.bindingRefs → binding.Valid
  entriesValid : BoundaryPortsValid artifact.entries
  exitsValid : BoundaryPortsValid artifact.exits
  connectionsValid : ∀ connection, connection ∈ artifact.connections → connection.Valid

/-- Top-level boundary and raw connection rows are closed over the serialized node summary. -/
structure SummaryDomainClosed (artifact : WireAdmissionArtifact) : Prop where
  entriesClosed :
    BoundaryPortsClosed artifact.nodes artifact.entries
  exitsClosed :
    BoundaryPortsClosed artifact.nodes artifact.exits
  connectionsClosed :
    ∀ connection, connection ∈ artifact.connections →
      connection.fromEndpoint.node ∈ artifact.nodes ∧
        connection.toEndpoint.node ∈ artifact.nodes

/-- Structured trace rows are closed over the top-level node and binding summaries.

This prevents a validator-ready artifact from proving local row shape while its
primitive trace, generated forms, phantom adapters, or select rows point at
entities absent from the serialized compiled graph summary. -/
structure ComponentDomainsClosed (artifact : WireAdmissionArtifact) : Prop where
  primitiveStepsClosed :
    ∀ primitiveStep, primitiveStep ∈ artifact.primitiveSteps →
      PrimitiveGraphStep.DomainClosed artifact.nodes artifact.bindingRefs primitiveStep
  generatedFormsClosed :
    ∀ generated, generated ∈ artifact.generatedForms →
      GeneratedFormArtifact.DomainClosed artifact.nodes generated
  phantomAdaptersClosed :
    ∀ phantom, phantom ∈ artifact.phantomAdapters →
      PhantomAdapterArtifact.DomainClosed artifact.nodes phantom
  selectsClosed :
    ∀ selectAdmission, selectAdmission ∈ artifact.selects →
      SelectAdmissionArtifact.DomainClosed artifact.nodes selectAdmission

/-- Top-level component rows are unique by the identity that witness replay consumes.

Local component validators reject duplicate rows inside one generated form,
phantom adapter, or select admission. This top-level predicate rejects two
component rows that claim the same generated binding, phantom adapter node, or
select condition node before replay turns them into proof witnesses.
-/
structure ComponentRowsUnique (artifact : WireAdmissionArtifact) : Prop where
  generatedFormBindingsUnique :
    (artifact.generatedForms.map GeneratedFormArtifact.binding).Nodup
  phantomAdapterNodesUnique :
    (artifact.phantomAdapters.map PhantomAdapterArtifact.node).Nodup
  selectConditionNodesUnique :
    (artifact.selects.map SelectAdmissionArtifact.conditionNode).Nodup
  componentRoleNodesUnique :
    artifact.componentRoleNodes.Nodup

/-- Generated-family rows are anchored by surviving children or an empty-family binding ref.

Rows with surviving children are tied to primitive node rows by
`GeneratedChildFrontiersMatchPrimitive`. Empty generated-family rows have no
child domain, so they must correspond to a binding reference in the compiled
primitive trace and have no source children. Otherwise a validator-ready
artifact could carry either an unused empty family or a pruned non-empty family
that replay cannot associate with the source graph.
-/
def GeneratedFormsReferenced (artifact : WireAdmissionArtifact) : Prop :=
  ∀ generated, generated ∈ artifact.generatedForms →
    generated.usedChildren ≠ [] ∨
      (generated.sourceChildren = [] ∧ generated.binding ∈ artifact.bindingRefs)

/-- The top-level raw connection summary is exactly the primitive connect matched-pair ledger. -/
def RawConnectionsMatchPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  artifact.connections.Perm
    (PrimitiveGraphStep.rawConnectionsList artifact.primitiveSteps)

/-- Top-level node and binding-ref summaries are exactly the primitive identity rows. -/
def SummaryIdentitiesMatchPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  artifact.nodes.Perm (PrimitiveGraphStep.nodeRowsList artifact.primitiveSteps) ∧
    artifact.bindingRefs.Perm (PrimitiveGraphStep.bindingRowsList artifact.primitiveSteps)

/-- Top-level boundary summaries are backed by primitive node frontiers and not already consumed.

This is intentionally a one-way validator contract: it rejects fabricated
summary entry/exit rows without yet claiming that every residual primitive
frontier must appear in the top-level summary. Exact residual coverage is named
separately by `SummaryFrontiersMatchPrimitive`.
-/
def SummaryFrontiersBackedByPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  (∀ entry, entry ∈ artifact.entries →
      entry.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
        entry.key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps) ∧
  (∀ exit, exit ∈ artifact.exits →
      exit.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
        exit.key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps)

/-- A primitive exit key belongs to the compiler-generated select-condition interior.

Select bridge nodes expose internal exclusive branch exits that model branch
choice inside the bridge. They are primitive node exits, but they are not
source-visible top-level exits.
-/
def SelectInternalExitKey
    (artifact : WireAdmissionArtifact)
    (key : NodeId × FieldLabel × ContractId) :
    Prop :=
  ∃ selectAdmission, selectAdmission ∈ artifact.selects ∧
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        ∃ exit, exit ∈ exits ∧
          exit.key = key ∧
            (∃ index, exit.exclusiveGroup = some (selectAdmission.conditionNode, index)) ∧
              ∃ variant, variant ∈ selectAdmission.variants ∧
                variant.port.CompatibleWith exit

/-- Top-level boundary summaries are exactly the residual primitive node frontiers.

Entries and exits are the primitive node frontier rows minus the endpoints
consumed by primitive connect rows. Exits additionally exclude select-condition
internal branch exits: those are primitive bridge-node exits, but they are not
source-visible top-level boundaries. This is the residual-frontier contract a
future witness replayer needs in order to treat the top-level summary as a
faithful source-visible view of the primitive trace, not merely a backed subset.
-/
def SummaryFrontiersMatchPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  (∀ key, key ∈ artifact.entries.map AdmissionBoundaryPort.key ↔
      key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
        key ∉ PrimitiveGraphStep.consumedEntryKeysList artifact.primitiveSteps) ∧
  (∀ key, key ∈ artifact.exits.map AdmissionBoundaryPort.key ↔
      key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
        key ∉ PrimitiveGraphStep.consumedExitKeysList artifact.primitiveSteps ∧
          ¬ artifact.SelectInternalExitKey key)

/-- Component-specific frontier rows are backed by primitive node frontiers.

Generated forms and phantom adapters may refer to boundaries that are consumed
later and therefore absent from the top-level summary. They still must be
boundaries that came from primitive node rows rather than free-floating
component-local claims.
-/
structure ComponentFrontiersBackedByPrimitive (artifact : WireAdmissionArtifact) : Prop where
  generatedChildren :
    ∀ generated, generated ∈ artifact.generatedForms →
      ∀ child, child ∈ generated.usedChildren →
        (∀ output, output ∈ child.outputs →
          output.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps) ∧
        (∀ input, input ∈ child.inputs →
          input.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps)
  phantomAdapters :
    ∀ phantom, phantom ∈ artifact.phantomAdapters →
      match phantom.direction with
      | .gather =>
          phantom.singular.key ∈
            PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps ∧
          (∀ multi, multi ∈ phantom.multi →
            multi.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps)
      | .scatter =>
          phantom.singular.key ∈
            PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps ∧
          (∀ multi, multi ∈ phantom.multi →
            multi.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps)
  selectVariants :
    ∀ selectAdmission, selectAdmission ∈ artifact.selects →
      ∀ variant, variant ∈ selectAdmission.variants →
        variant.port.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps

/-- Generated used-child frontiers exactly match their primitive node row.

`ComponentFrontiersBackedByPrimitive` rejects invented generated child
frontiers. This stronger predicate also rejects under-reporting: a generated
child artifact must carry the same input and output frontier identities as the
primitive node row emitted for that child.
-/
def GeneratedChildFrontiersMatchPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  ∀ generated, generated ∈ artifact.generatedForms →
    ∀ child, child ∈ generated.usedChildren →
      ∃ entries exits,
        PrimitiveGraphStep.node child.node entries exits ∈ artifact.primitiveSteps ∧
          child.inputKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
          child.outputKeys.Perm (exits.map AdmissionBoundaryPort.key)

/-- Primitive overlay rows combine only node/binding ledgers available in their trace prefix.

This strengthens global node/binding backing with replay order: an overlay may
not claim a side ledger whose primitive identity row appears only later. -/
def PrimitiveOverlayLedgersPrefixAvailable (artifact : WireAdmissionArtifact) :
    Prop :=
  ∀ tracePrefix suffix leftNodes rightNodes leftBindings rightBindings,
    artifact.primitiveSteps =
      tracePrefix ++
        [PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings] ++
        suffix →
      (∀ node, node ∈ leftNodes ++ rightNodes →
        node ∈ PrimitiveGraphStep.nodeRowsList tracePrefix) ∧
      (∀ binding, binding ∈ leftBindings ++ rightBindings →
        binding ∈ PrimitiveGraphStep.bindingRowsList tracePrefix)

/-- Primitive connect rows draw their left/right frontier rows from primitive node rows. -/
def PrimitiveConnectFrontiersBackedByNodes (artifact : WireAdmissionArtifact) : Prop :=
  ∀ leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries,
    PrimitiveGraphStep.connect
        leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ∈
      artifact.primitiveSteps →
      (∀ leftExit, leftExit ∈ leftExits →
        leftExit.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps) ∧
      (∀ rightEntry, rightEntry ∈ rightEntries →
        rightEntry.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps)

/-- Primitive connect rows consume only frontiers available in their trace prefix.

This strengthens global primitive backing with replay order: a connect may not
consume an endpoint introduced only by a later primitive node row, and it may
not consume an endpoint already matched by an earlier connect row. -/
def PrimitiveConnectFrontiersPrefixAvailable (artifact : WireAdmissionArtifact) :
    Prop :=
  ∀ tracePrefix suffix leftExits rightEntries matchedPairs unmatchedLeftExits
      unmatchedRightEntries,
    artifact.primitiveSteps =
      tracePrefix ++
        [PrimitiveGraphStep.connect
          leftExits rightEntries matchedPairs unmatchedLeftExits
          unmatchedRightEntries] ++
        suffix →
      (∀ leftExit, leftExit ∈ leftExits →
        leftExit.key ∈ PrimitiveGraphStep.nodeExitKeysList tracePrefix ∧
          leftExit.key ∉ PrimitiveGraphStep.consumedExitKeysList tracePrefix) ∧
      (∀ rightEntry, rightEntry ∈ rightEntries →
        rightEntry.key ∈ PrimitiveGraphStep.nodeEntryKeysList tracePrefix ∧
          rightEntry.key ∉ PrimitiveGraphStep.consumedEntryKeysList tracePrefix)

/-- A select variant has exactly one compatible condition-node entry row. -/
def SelectBridgeEntryUnique
    (variant : SelectVariantArtifact)
    (entries : List AdmissionBoundaryPort) :
    Prop :=
  ∃ entry, entry ∈ entries ∧
    variant.port.CompatibleWith entry ∧
      ∀ other, other ∈ entries → variant.port.CompatibleWith other → other = entry

/-- A unique select bridge entry exposes a compatible primitive entry row. -/
theorem selectBridgeEntryUnique_entry
    {variant : SelectVariantArtifact}
    {entries : List AdmissionBoundaryPort}
    (hUnique : SelectBridgeEntryUnique variant entries) :
    ∃ entry, entry ∈ entries ∧ variant.port.CompatibleWith entry := by
  obtain ⟨entry, hEntry, hCompatible, _hUnique⟩ := hUnique
  exact ⟨entry, hEntry, hCompatible⟩

/-- A select variant has exactly one compatible internal condition-node exit row. -/
def SelectBridgeInternalExitUnique
    (conditionNode : NodeId)
    (variant : SelectVariantArtifact)
    (exits : List AdmissionBoundaryPort) :
    Prop :=
  ∃ exit, exit ∈ exits ∧
    variant.port.CompatibleWith exit ∧
      (∃ index, exit.exclusiveGroup = some (conditionNode, index)) ∧
        ∀ other, other ∈ exits →
          variant.port.CompatibleWith other →
            (∃ index, other.exclusiveGroup = some (conditionNode, index)) →
              other = exit

/-- Select condition bridge nodes expose primitive frontiers for every base variant.

The variant rows identify source-visible base outputs. This predicate ties each
variant to the compiler-generated condition node by requiring exactly one
compatible condition-node entry and exactly one compatible internal exclusive
branch exit in the primitive node row for that condition node.
-/
def SelectBridgeFrontiersBackedByPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    ∃ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps ∧
        ∀ variant, variant ∈ selectAdmission.variants →
          SelectBridgeEntryUnique variant entries ∧
            SelectBridgeInternalExitUnique selectAdmission.conditionNode variant exits

/-- Select bridge entries are internal and must be consumed by primitive replay.

The condition node may carry one compatible entry per base variant, but those
entries are bridge inputs from the selected base output. A validator-ready
artifact therefore records the exact variant-output-to-condition-entry
contraction row, so the bridge entry cannot remain source-visible.
-/
def SelectBridgeEntriesConsumed (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    ∀ entries exits,
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps →
      ∀ variant, variant ∈ selectAdmission.variants →
        ∀ entry, entry ∈ entries →
          variant.port.CompatibleWith entry →
            { fromPort := variant.port, toPort := entry } ∈
              PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps

/-- Boolean classifier for select condition exits that encode branch choice. -/
def SelectInternalChoiceExit
    (selectAdmission : SelectAdmissionArtifact)
    (exit : AdmissionBoundaryPort) :
    Bool :=
  let ownedByCondition :=
    match exit.exclusiveGroup with
    | none => false
    | some (owner, _index) => decide (owner = selectAdmission.conditionNode)
  ownedByCondition &&
    selectAdmission.variants.any fun variant =>
      decide (variant.port.CompatibleWith exit)

/-- Primitive replay exits hidden from the top-level source summary.

These are the internal exclusive branch-choice exits exposed by select
condition nodes. They participate in primitive replay and component validation,
but `wireAdmissionExits` records only source-visible exits.
-/
def SelectInternalTraceExit
    (artifact : WireAdmissionArtifact)
    (exit : AdmissionBoundaryPort) : Prop :=
  ∃ selectAdmission, selectAdmission ∈ artifact.selects ∧
    SelectInternalChoiceExit selectAdmission exit = true

/-- A condition-node internal choice exit contributes a select-internal exit key.

This is the Lean-side counterpart of Haskell
`primitiveGraphStepSelectInternalExitKeys`: only exits from the corresponding
condition-node primitive row are projected into the key-level summary-exclusion
set.
-/
theorem selectInternalChoiceExit_key
    {artifact : WireAdmissionArtifact}
    {selectAdmission : SelectAdmissionArtifact}
    (hSelect : selectAdmission ∈ artifact.selects)
    {entries exits : List AdmissionBoundaryPort}
    (hNode :
      PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
        artifact.primitiveSteps)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ exits)
    (hChoice : SelectInternalChoiceExit selectAdmission exit = true) :
    artifact.SelectInternalExitKey exit.key := by
  unfold SelectInternalChoiceExit at hChoice
  cases hGroup : exit.exclusiveGroup with
  | none =>
      simp [hGroup] at hChoice
  | some group =>
      cases group with
      | mk owner index =>
          rw [Bool.and_eq_true] at hChoice
          have hOwnerBool :
              decide (owner = selectAdmission.conditionNode) = true := by
            simpa [hGroup] using hChoice.left
          have hOwner : owner = selectAdmission.conditionNode :=
            of_decide_eq_true hOwnerBool
          rcases List.any_eq_true.mp hChoice.right with
            ⟨variant, hVariant, hCompatibleBool⟩
          have hCompatible : variant.port.CompatibleWith exit :=
            of_decide_eq_true hCompatibleBool
          exact
            ⟨ selectAdmission
            , hSelect
            , entries
            , exits
            , hNode
            , exit
            , hExit
            , rfl
            , ⟨index, by simp [hGroup, hOwner]⟩
            , variant
            , hVariant
            , hCompatible
            ⟩

/-- A unique select bridge internal exit is classified as an internal choice exit. -/
theorem selectBridgeInternalExitUnique_choiceExit
    {selectAdmission : SelectAdmissionArtifact}
    {variant : SelectVariantArtifact}
    {exits : List AdmissionBoundaryPort}
    (hVariant : variant ∈ selectAdmission.variants)
    (hUnique :
      SelectBridgeInternalExitUnique selectAdmission.conditionNode variant exits) :
    ∃ exit, exit ∈ exits ∧
      variant.port.CompatibleWith exit ∧
        SelectInternalChoiceExit selectAdmission exit = true := by
  obtain ⟨exit, hExit, hCompatible, hGroup, _hUnique⟩ := hUnique
  obtain ⟨index, hGroupEq⟩ := hGroup
  refine ⟨exit, hExit, hCompatible, ?_⟩
  unfold SelectInternalChoiceExit
  rw [hGroupEq]
  rw [Bool.and_eq_true]
  constructor
  · simp
  · exact
      List.any_eq_true.mpr
        ⟨variant, hVariant, by simp [hCompatible]⟩

/-- Row-valid replay-hidden select exits are key-level select-internal exits.

Primitive replay hides exits through `SelectInternalTraceExit`, while the
top-level summary exclusion is phrased through `SelectInternalExitKey`. Local
primitive-row validity bridges the two: a hidden exit with an exclusive group
owned by a select condition node must belong to that condition-node primitive
row.
-/
theorem selectInternalTraceExit_key_of_valid_node
    {artifact : WireAdmissionArtifact}
    {node : NodeId}
    {entries exits : List AdmissionBoundaryPort}
    (hStepValid : (PrimitiveGraphStep.node node entries exits).Valid)
    (hNode : PrimitiveGraphStep.node node entries exits ∈ artifact.primitiveSteps)
    {exit : AdmissionBoundaryPort}
    (hExit : exit ∈ exits)
    (hHidden : artifact.SelectInternalTraceExit exit) :
    artifact.SelectInternalExitKey exit.key := by
  obtain ⟨selectAdmission, hSelect, hChoice⟩ := hHidden
  have hChoiceOriginal : SelectInternalChoiceExit selectAdmission exit = true := hChoice
  have hExitValid : exit.Valid := hStepValid.exitsValid exit hExit
  have hOwned : PrimitiveGraphStep.NodeFrontiersOwned node entries exits :=
    hStepValid.frontiersOwned
  have hExitNode : exit.node = node := hOwned.right exit hExit
  unfold SelectInternalChoiceExit at hChoice
  cases hGroup : exit.exclusiveGroup with
  | none =>
      simp [hGroup] at hChoice
  | some group =>
      cases group with
      | mk owner index =>
          rw [Bool.and_eq_true] at hChoice
          have hOwnerBool :
              decide (owner = selectAdmission.conditionNode) = true := by
            simpa [hGroup] using hChoice.left
          have hOwner : owner = selectAdmission.conditionNode :=
            of_decide_eq_true hOwnerBool
          have hLocalOwner : owner = exit.node := by
            have hLocal := hExitValid.right.right.right.right
            rw [hGroup] at hLocal
            exact hLocal.left
          have hConditionNode : selectAdmission.conditionNode = node :=
            hOwner.symm.trans (hLocalOwner.trans hExitNode)
          have hConditionRow :
              PrimitiveGraphStep.node selectAdmission.conditionNode entries exits ∈
                artifact.primitiveSteps := by
            simpa [hConditionNode] using hNode
          exact
            selectInternalChoiceExit_key hSelect hConditionRow hExit hChoiceOriginal

/-- Primitive rows replay to exactly one final frame matching the top-level summary.

This is stronger than row-local validity: overlay/connect rows must consume the
two graph fragments immediately preceding them in the serialized postorder
trace, and connect rows must expose the complete operand frontiers rather than
an arbitrary subset. Select-internal branch-choice exits are erased before the
final frame is compared with source-visible summary exits.
-/
def PrimitiveTraceStackValid (artifact : WireAdmissionArtifact) : Prop :=
  ∃ finalFrame,
    PrimitiveTraceReplays artifact.SelectInternalTraceExit artifact.primitiveSteps [] [finalFrame] ∧
      finalFrame.MatchesSummary artifact

/-- Source-visible bridge-output shapes exposed by a select condition node.

Internal branch-choice exits are condition-owned and compatible with a base
variant. The remaining exits are the shared boundary that every latent arm body
must produce after consuming its selected variant. -/
def SelectConditionBridgeOutputShapes
    (selectAdmission : SelectAdmissionArtifact)
    (exits : List AdmissionBoundaryPort) :
    List (AdmissionPortLabel × ContractId × Option Nat) :=
  (exits.filter fun exit =>
    !(SelectInternalChoiceExit selectAdmission exit)).map AdmissionBoundaryPort.outputShape

/-- Latent select arm body boundaries match the condition-node bridge contract.

For a non-empty arm body, the body must consume exactly the selected variant
compatibility shape and produce the condition node's shared bridge output
shapes. An identity arm has no latent body rows; it is accepted only when the
shared bridge output shape is exactly the selected variant shape with no
exclusive group, which is the executable identity-arm rule.
-/
def SelectArmBodyBoundariesMatchCondition (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
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
                  (SelectConditionBridgeOutputShapes selectAdmission exits)))

/-- Latent select arm body node domains are pairwise disjoint across canonical arms.

Select arm bodies are latent fragments, so they are not required to appear in
the already-compiled top-level node summary. They still must not reuse a node
identity across exclusive arms: selected-branch replay can then treat
canonical-arm choice as a partition of latent branch node domains. -/
def SelectArmBodyNodesPairwiseDisjoint (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    ∀ left, left ∈ selectAdmission.arms →
      ∀ right, right ∈ selectAdmission.arms →
        left.canonicalKey ≠ right.canonicalKey →
          ∀ node, node ∈ left.bodyNodes → node ∉ right.bodyNodes

/-- Latent select arm body nodes are fresh relative to the top-level node summary.

Select arm bodies are replay candidates, not nodes already admitted into the
outer graph. Freshness against `artifact.nodes` keeps the serialized artifact
from smuggling a live top-level node into a latent branch body. -/
def SelectArmBodyNodesFreshFromSummary (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    ∀ arm, arm ∈ selectAdmission.arms →
      ∀ node, node ∈ arm.bodyNodes → node ∉ artifact.nodes

/-- Phantom adapter bulk ledgers use primitive-backed phantom-node frontiers.

The source-visible multi/singular endpoints are covered by
`ComponentFrontiersBackedByPrimitive`; this predicate covers the generated
phantom-node endpoints on the inside of the two bulk contraction ledgers.
-/
def PhantomBridgeFrontiersBackedByPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  ∀ phantom, phantom ∈ artifact.phantomAdapters →
    (∀ pair, pair ∈ phantom.leftBulk →
      pair.toPort.key ∈ PrimitiveGraphStep.nodeEntryKeysList artifact.primitiveSteps) ∧
    (∀ pair, pair ∈ phantom.rightBulk →
      pair.fromPort.key ∈ PrimitiveGraphStep.nodeExitKeysList artifact.primitiveSteps)

/-- Phantom adapter bridge ledgers exactly match the primitive phantom-node row.

`PhantomBridgeFrontiersBackedByPrimitive` rejects unbacked internal endpoints.
This stronger predicate also rejects under-reporting or extra internal phantom
frontiers by tying the left-bulk targets and right-bulk sources to the
primitive node row for the phantom adapter node.
-/
def PhantomBridgeFrontiersMatchPrimitive (artifact : WireAdmissionArtifact) : Prop :=
  ∀ phantom, phantom ∈ artifact.phantomAdapters →
    ∃ entries exits,
      PrimitiveGraphStep.node phantom.node entries exits ∈ artifact.primitiveSteps ∧
        phantom.leftBulkTargetKeys.Perm (entries.map AdmissionBoundaryPort.key) ∧
        phantom.rightBulkSourceKeys.Perm (exits.map AdmissionBoundaryPort.key)

/-- Phantom adapter bulk ledgers are the exact contractions replayed by primitive connect rows.

Frontier backing proves that the phantom-node endpoints exist. This predicate
ties the bulk ledger itself to primitive replay, ruling out artifacts that
claim an adapter contraction without a matching primitive connect row.
-/
def PhantomBridgeBulkConnectionsReplayed (artifact : WireAdmissionArtifact) : Prop :=
  ∀ phantom, phantom ∈ artifact.phantomAdapters →
    (∀ pair, pair ∈ phantom.leftBulk →
      pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps) ∧
    (∀ pair, pair ∈ phantom.rightBulk →
      pair ∈ PrimitiveGraphStep.matchedConnectionsList artifact.primitiveSteps)

/-- All primitive graph-step rows satisfy their local validator obligations. -/
def PrimitiveStepsValid (artifact : WireAdmissionArtifact) : Prop :=
  ∀ primitiveStep, primitiveStep ∈ artifact.primitiveSteps →
    primitiveStep.Valid

/-- All generated-form rows satisfy their local validator obligations. -/
def GeneratedFormsValid (artifact : WireAdmissionArtifact) : Prop :=
  ∀ generated, generated ∈ artifact.generatedForms →
    generated.Valid

/-- All phantom-adapter rows satisfy their local validator obligations. -/
def PhantomAdaptersValid (artifact : WireAdmissionArtifact) : Prop :=
  ∀ phantom, phantom ∈ artifact.phantomAdapters →
    phantom.Valid

/-- All select-admission rows satisfy their local validator obligations. -/
def SelectsValid (artifact : WireAdmissionArtifact) : Prop :=
  ∀ selectAdmission, selectAdmission ∈ artifact.selects →
    selectAdmission.Valid

/-- Top-level contract a decoded Haskell admission artifact must satisfy before witness replay.

The artifact remains data, not a proof term. `ValidatorReady` is the single
predicate a future JSON validator should construct from schema checks and row
local checks before mapping artifacts into the stronger Wire admission
witnesses.
-/
structure ValidatorReady (artifact : WireAdmissionArtifact) : Prop where
  schemaCurrent : artifact.SchemaCurrent
  summaryKeysUnique : artifact.SummaryKeysUnique
  summaryRowsValid : artifact.SummaryRowsValid
  summaryDomainClosed : artifact.SummaryDomainClosed
  summaryIdentitiesMatchPrimitive : artifact.SummaryIdentitiesMatchPrimitive
  summaryFrontiersBackedByPrimitive : artifact.SummaryFrontiersBackedByPrimitive
  summaryFrontiersMatchPrimitive : artifact.SummaryFrontiersMatchPrimitive
  rawConnectionsMatchPrimitive : artifact.RawConnectionsMatchPrimitive
  componentDomainsClosed : artifact.ComponentDomainsClosed
  componentRowsUnique : artifact.ComponentRowsUnique
  generatedFormsReferenced : artifact.GeneratedFormsReferenced
  componentFrontiersBackedByPrimitive : artifact.ComponentFrontiersBackedByPrimitive
  generatedChildFrontiersMatchPrimitive :
    artifact.GeneratedChildFrontiersMatchPrimitive
  primitiveTraceStackValid : artifact.PrimitiveTraceStackValid
  primitiveOverlayLedgersPrefixAvailable :
    artifact.PrimitiveOverlayLedgersPrefixAvailable
  primitiveConnectFrontiersBackedByNodes :
    artifact.PrimitiveConnectFrontiersBackedByNodes
  primitiveConnectFrontiersPrefixAvailable :
    artifact.PrimitiveConnectFrontiersPrefixAvailable
  selectBridgeFrontiersBackedByPrimitive :
    artifact.SelectBridgeFrontiersBackedByPrimitive
  selectBridgeEntriesConsumed :
    artifact.SelectBridgeEntriesConsumed
  selectArmBodyBoundariesMatchCondition :
    artifact.SelectArmBodyBoundariesMatchCondition
  selectArmBodyNodesFreshFromSummary :
    artifact.SelectArmBodyNodesFreshFromSummary
  selectArmBodyNodesPairwiseDisjoint :
    artifact.SelectArmBodyNodesPairwiseDisjoint
  phantomBridgeFrontiersBackedByPrimitive :
    artifact.PhantomBridgeFrontiersBackedByPrimitive
  phantomBridgeFrontiersMatchPrimitive :
    artifact.PhantomBridgeFrontiersMatchPrimitive
  phantomBridgeBulkConnectionsReplayed :
    artifact.PhantomBridgeBulkConnectionsReplayed
  primitiveStepsValid : artifact.PrimitiveStepsValid
  generatedFormsValid : artifact.GeneratedFormsValid
  phantomAdaptersValid : artifact.PhantomAdaptersValid
  selectsValid : artifact.SelectsValid

instance schemaCurrentDecidable (artifact : WireAdmissionArtifact) :
    Decidable artifact.SchemaCurrent :=
  inferInstanceAs (Decidable (artifact.schemaVersion = currentSchemaVersion))

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
