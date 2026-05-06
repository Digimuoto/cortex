import Mathlib.Data.Finset.Basic
import Cortex.Graph.Relation
import Cortex.Wire.Select

/-!
## Overview

Proof-facing model of Wire source and closed actualized port linearity.

## Context

Paper 5 and the Wire reference make port consumption linear at the actualized
port-instance boundary. The linear unit is not a contract type and not a node:
it is a named port on a concrete actualized node. A closed actualized graph
must account for both sides of value flow:

- every output port has exactly one consumer, either one value-flow edge or one
  terminal egress, sink, or exported-boundary discharge;
- every input port has exactly one producer, through one value-flow edge.

This module has two deliberately separate layers:

1. `LinearPortGraph` is the source-level carrier above Mokhov relations. It
   proves preservation for already-certified source objects and single-pair
   contractions, not admission of raw Wire `=>` syntax.
2. `PortUseWitness` is the closed actualized proof witness that the compiler or
   admission layer must eventually produce. Its input and output domains are
   caller-supplied finite sets; this module does not claim they already match a
   concrete Haskell topology.

Raw `=>` matching determinism, repeated-reference rejection, source `make`/`*`
expansion into certified objects, and executable projection into the closed
actualized view remain correspondence obligations tracked outside this file.

## Theorem Split

The source section defines `LinearPortGraph`, `PortLinear`, `forgetPorts`,
certified overlay, certified contraction, and certified bulk contraction. The
actualized section defines `PortUseWitness`;
`portUseWitness_toGraph_closedPortLinear` turns a supplied witness domain into
an `ActualizedPortGraph` satisfying `ClosedPortLinear`.
-/

namespace Cortex.Wire

/-! ## Source Linear Port Graphs -/

/-- `SourcePortInstance` identifies one named source-level port on one Wire/Circuit node.

Unlike `ActualizedPortInstance`, this lives before lowering to the closed actualized runtime view.
It is the proof-side carrier for ADR 0047's typed-frontier endpoint resources. -/
structure SourcePortInstance (node port : Type) where
  /-- Source node that owns this port instance. -/
  node : node
  /-- Source port label or proof-side identity on that node. -/
  port : port
  deriving DecidableEq, Repr

/-- `LinearPortGraph` is the source Wire/Circuit port graph above Mokhov relations.

The carrier keeps node identities, source input/output port instances, open frontier endpoints, and
port-to-port edges. Its `forgetPorts` lowering erases port identity and exposes only the node-level
relation topology. -/
structure LinearPortGraph
    (node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Nodes present in the source graph. -/
  nodes : Finset node
  /-- Source output port instances owned by graph nodes. -/
  outputs : Finset (SourcePortInstance node outputPort)
  /-- Source input port instances owned by graph nodes. -/
  inputs : Finset (SourcePortInstance node inputPort)
  /-- Open output frontier endpoints not consumed by an internal edge. -/
  exposedOutputs : Finset (SourcePortInstance node outputPort)
  /-- Open input frontier endpoints not produced by an internal edge. -/
  exposedInputs : Finset (SourcePortInstance node inputPort)
  /-- Source port edges from output instances to input instances. -/
  portEdges : Finset (SourcePortInstance node outputPort × SourcePortInstance node inputPort)
  /-- Every output port belongs to a graph node. -/
  output_nodes : ∀ output, output ∈ outputs → output.node ∈ nodes
  /-- Every input port belongs to a graph node. -/
  input_nodes : ∀ input, input ∈ inputs → input.node ∈ nodes
  /-- Exposed output endpoints are graph outputs. -/
  exposedOutput_mem : ∀ output, output ∈ exposedOutputs → output ∈ outputs
  /-- Exposed input endpoints are graph inputs. -/
  exposedInput_mem : ∀ input, input ∈ exposedInputs → input ∈ inputs
  /-- Every port-edge source is a graph output. -/
  edge_output_mem : ∀ edge, edge ∈ portEdges → edge.1 ∈ outputs
  /-- Every port-edge target is a graph input. -/
  edge_input_mem : ∀ edge, edge ∈ portEdges → edge.2 ∈ inputs

namespace LinearPortGraph

variable {node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

/-- Outputs from `left` and `right` are disjoint as source endpoint resources. -/
def OutputDisjoint
    (left right : LinearPortGraph node outputPort inputPort) : Prop :=
  ∀ output,
    output ∈ left.outputs →
      output ∈ right.outputs →
        False

/-- Inputs from `left` and `right` are disjoint as source endpoint resources. -/
def InputDisjoint
    (left right : LinearPortGraph node outputPort inputPort) : Prop :=
  ∀ input,
    input ∈ left.inputs →
      input ∈ right.inputs →
        False

/-- Nodes from `left` and `right` are disjoint as source graph identities. -/
def NodeDisjoint
    (left right : LinearPortGraph node outputPort inputPort) : Prop :=
  ∀ graphNode,
    graphNode ∈ left.nodes →
      graphNode ∈ right.nodes →
        False

/-- Source graph domains are disjoint at node and endpoint-resource levels.

`NodeDisjoint` is the load-bearing source-reference condition; the endpoint fields are kept
explicit so callers can use the exact port direction without re-deriving it from node ownership. -/
def DomainDisjoint
    (left right : LinearPortGraph node outputPort inputPort) : Prop :=
  NodeDisjoint left right ∧ OutputDisjoint left right ∧ InputDisjoint left right

/-- `PortLinear graph` states the certified source endpoint rule from ADR 0047.

Each output endpoint is either open on the output frontier or consumed by exactly one internal
edge; each input endpoint is either open on the input frontier or produced by exactly one internal
edge. -/
def PortLinear
    (graph : LinearPortGraph node outputPort inputPort) : Prop :=
  (∀ output,
      output ∈ graph.outputs →
        (output ∈ graph.exposedOutputs ∧
            graph.portEdges.filter (fun edge => edge.1 = output) = ∅) ∨
          (output ∉ graph.exposedOutputs ∧
            ∃ input,
              input ∈ graph.inputs ∧
                graph.portEdges.filter (fun edge => edge.1 = output) = {(output, input)})) ∧
    (∀ input,
      input ∈ graph.inputs →
        (input ∈ graph.exposedInputs ∧
            graph.portEdges.filter (fun edge => edge.2 = input) = ∅) ∨
          (input ∉ graph.exposedInputs ∧
            ∃ output,
              output ∈ graph.outputs ∧
                graph.portEdges.filter (fun edge => edge.2 = input) = {(output, input)}))

/-- Forget source port identity and expose only node-level relation topology. -/
def forgetPorts
    (graph : LinearPortGraph node outputPort inputPort) : Cortex.Graph.Relation node :=
  { vertices := graph.nodes
    edges := graph.portEdges.image (fun edge => (edge.1.node, edge.2.node)) }

/-- Source port graphs lower to endpoint-closed node relations. -/
theorem forgetPorts_edgeEndpointsInVertices
    (graph : LinearPortGraph node outputPort inputPort) :
    Cortex.Graph.Relation.EdgeEndpointsInVertices graph.forgetPorts := by
  intro edge hEdge
  simp only [forgetPorts] at hEdge ⊢
  rcases Finset.mem_image.mp hEdge with ⟨portEdge, hPortEdge, hEq⟩
  rcases hEq
  exact
    ⟨ graph.output_nodes portEdge.1 (graph.edge_output_mem portEdge hPortEdge)
    , graph.input_nodes portEdge.2 (graph.edge_input_mem portEdge hPortEdge)
    ⟩

/-- Overlay of source port graphs preserves all endpoint/resource domains by union. -/
def overlay
    (left right : LinearPortGraph node outputPort inputPort) :
    LinearPortGraph node outputPort inputPort where
  nodes := left.nodes ∪ right.nodes
  outputs := left.outputs ∪ right.outputs
  inputs := left.inputs ∪ right.inputs
  exposedOutputs := left.exposedOutputs ∪ right.exposedOutputs
  exposedInputs := left.exposedInputs ∪ right.exposedInputs
  portEdges := left.portEdges ∪ right.portEdges
  output_nodes := by
    intro output hOutput
    rcases Finset.mem_union.mp hOutput with hLeft | hRight
    · exact Finset.mem_union_left right.nodes (left.output_nodes output hLeft)
    · exact Finset.mem_union_right left.nodes (right.output_nodes output hRight)
  input_nodes := by
    intro input hInput
    rcases Finset.mem_union.mp hInput with hLeft | hRight
    · exact Finset.mem_union_left right.nodes (left.input_nodes input hLeft)
    · exact Finset.mem_union_right left.nodes (right.input_nodes input hRight)
  exposedOutput_mem := by
    intro output hOutput
    rcases Finset.mem_union.mp hOutput with hLeft | hRight
    · exact Finset.mem_union_left right.outputs (left.exposedOutput_mem output hLeft)
    · exact Finset.mem_union_right left.outputs (right.exposedOutput_mem output hRight)
  exposedInput_mem := by
    intro input hInput
    rcases Finset.mem_union.mp hInput with hLeft | hRight
    · exact Finset.mem_union_left right.inputs (left.exposedInput_mem input hLeft)
    · exact Finset.mem_union_right left.inputs (right.exposedInput_mem input hRight)
  edge_output_mem := by
    intro edge hEdge
    rcases Finset.mem_union.mp hEdge with hLeft | hRight
    · exact Finset.mem_union_left right.outputs (left.edge_output_mem edge hLeft)
    · exact Finset.mem_union_right left.outputs (right.edge_output_mem edge hRight)
  edge_input_mem := by
    intro edge hEdge
    rcases Finset.mem_union.mp hEdge with hLeft | hRight
    · exact Finset.mem_union_left right.inputs (left.edge_input_mem edge hLeft)
    · exact Finset.mem_union_right left.inputs (right.edge_input_mem edge hRight)

/-- Forgetting ports commutes with source overlay. -/
theorem forgetPorts_overlay
    (left right : LinearPortGraph node outputPort inputPort) :
    (overlay left right).forgetPorts =
      Cortex.Graph.Relation.overlay left.forgetPorts right.forgetPorts := by
  ext x <;> simp [forgetPorts, overlay, Cortex.Graph.Relation.overlay, Finset.image_union]

/-- Filtering overlay edges by a left-owned output ignores the right edge set. -/
theorem overlay_filter_output_left
    (left right : LinearPortGraph node outputPort inputPort)
    {output : SourcePortInstance node outputPort}
    (hNotRight : output ∉ right.outputs) :
    (overlay left right).portEdges.filter (fun edge => edge.1 = output) =
      left.portEdges.filter (fun edge => edge.1 = output) := by
  ext edge
  constructor
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∪ right.portEdges ∧ edge.1 = output := by
      simpa [overlay] using hEdge
    rcases hMember with ⟨hUnion, hSource⟩
    rcases Finset.mem_union.mp hUnion with hLeft | hRight
    · exact Finset.mem_filter.mpr ⟨hLeft, hSource⟩
    · have hRightOutput : output ∈ right.outputs := by
        rw [← hSource]
        exact right.edge_output_mem edge hRight
      exact False.elim (hNotRight hRightOutput)
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∧ edge.1 = output := by
      simpa using hEdge
    exact
      Finset.mem_filter.mpr
        ⟨Finset.mem_union_left right.portEdges hMember.1, hMember.2⟩

/-- Filtering overlay edges by a right-owned output ignores the left edge set. -/
theorem overlay_filter_output_right
    (left right : LinearPortGraph node outputPort inputPort)
    {output : SourcePortInstance node outputPort}
    (hNotLeft : output ∉ left.outputs) :
    (overlay left right).portEdges.filter (fun edge => edge.1 = output) =
      right.portEdges.filter (fun edge => edge.1 = output) := by
  ext edge
  constructor
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∪ right.portEdges ∧ edge.1 = output := by
      simpa [overlay] using hEdge
    rcases hMember with ⟨hUnion, hSource⟩
    rcases Finset.mem_union.mp hUnion with hLeft | hRight
    · have hLeftOutput : output ∈ left.outputs := by
        rw [← hSource]
        exact left.edge_output_mem edge hLeft
      exact False.elim (hNotLeft hLeftOutput)
    · exact Finset.mem_filter.mpr ⟨hRight, hSource⟩
  · intro hEdge
    have hMember : edge ∈ right.portEdges ∧ edge.1 = output := by
      simpa using hEdge
    exact
      Finset.mem_filter.mpr
        ⟨Finset.mem_union_right left.portEdges hMember.1, hMember.2⟩

/-- Filtering overlay edges by a left-owned input ignores the right edge set. -/
theorem overlay_filter_input_left
    (left right : LinearPortGraph node outputPort inputPort)
    {input : SourcePortInstance node inputPort}
    (hNotRight : input ∉ right.inputs) :
    (overlay left right).portEdges.filter (fun edge => edge.2 = input) =
      left.portEdges.filter (fun edge => edge.2 = input) := by
  ext edge
  constructor
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∪ right.portEdges ∧ edge.2 = input := by
      simpa [overlay] using hEdge
    rcases hMember with ⟨hUnion, hTarget⟩
    rcases Finset.mem_union.mp hUnion with hLeft | hRight
    · exact Finset.mem_filter.mpr ⟨hLeft, hTarget⟩
    · have hRightInput : input ∈ right.inputs := by
        rw [← hTarget]
        exact right.edge_input_mem edge hRight
      exact False.elim (hNotRight hRightInput)
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∧ edge.2 = input := by
      simpa using hEdge
    exact
      Finset.mem_filter.mpr
        ⟨Finset.mem_union_left right.portEdges hMember.1, hMember.2⟩

/-- Filtering overlay edges by a right-owned input ignores the left edge set. -/
theorem overlay_filter_input_right
    (left right : LinearPortGraph node outputPort inputPort)
    {input : SourcePortInstance node inputPort}
    (hNotLeft : input ∉ left.inputs) :
    (overlay left right).portEdges.filter (fun edge => edge.2 = input) =
      right.portEdges.filter (fun edge => edge.2 = input) := by
  ext edge
  constructor
  · intro hEdge
    have hMember : edge ∈ left.portEdges ∪ right.portEdges ∧ edge.2 = input := by
      simpa [overlay] using hEdge
    rcases hMember with ⟨hUnion, hTarget⟩
    rcases Finset.mem_union.mp hUnion with hLeft | hRight
    · have hLeftInput : input ∈ left.inputs := by
        rw [← hTarget]
        exact left.edge_input_mem edge hLeft
      exact False.elim (hNotLeft hLeftInput)
    · exact Finset.mem_filter.mpr ⟨hRight, hTarget⟩
  · intro hEdge
    have hMember : edge ∈ right.portEdges ∧ edge.2 = input := by
      simpa using hEdge
    exact
      Finset.mem_filter.mpr
        ⟨Finset.mem_union_right left.portEdges hMember.1, hMember.2⟩

/-- Source overlay preserves source port linearity when endpoint domains are disjoint. -/
theorem overlay_preserves_portLinear
    (left right : LinearPortGraph node outputPort inputPort)
    (hLeft : left.PortLinear)
    (hRight : right.PortLinear)
    (hDisjoint : DomainDisjoint left right) :
    (overlay left right).PortLinear := by
  constructor
  · intro output hOutput
    have hOutputDisjoint : OutputDisjoint left right := hDisjoint.right.left
    rcases Finset.mem_union.mp hOutput with hLeftOutput | hRightOutput
    · have hNotRight : output ∉ right.outputs := by
        intro hRightOutput
        exact hOutputDisjoint output hLeftOutput hRightOutput
      have hLeftLinear := hLeft.left output hLeftOutput
      rcases hLeftLinear with hOpen | hConsumed
      · left
        refine ⟨?_, ?_⟩
        · exact Finset.mem_union_left right.exposedOutputs hOpen.1
        · rw [overlay_filter_output_left left right hNotRight]
          exact hOpen.2
      · right
        rcases hConsumed with ⟨hNotExposed, input, hInput, hEdges⟩
        refine ⟨?_, input, ?_, ?_⟩
        · intro hExposed
          rcases Finset.mem_union.mp hExposed with hLeftExposed | hRightExposed
          · exact hNotExposed hLeftExposed
          · exact hNotRight (right.exposedOutput_mem output hRightExposed)
        · exact Finset.mem_union_left right.inputs hInput
        · rw [overlay_filter_output_left left right hNotRight]
          exact hEdges
    · have hNotLeft : output ∉ left.outputs := by
        intro hLeftOutput
        exact hOutputDisjoint output hLeftOutput hRightOutput
      have hRightLinear := hRight.left output hRightOutput
      rcases hRightLinear with hOpen | hConsumed
      · left
        refine ⟨?_, ?_⟩
        · exact Finset.mem_union_right left.exposedOutputs hOpen.1
        · rw [overlay_filter_output_right left right hNotLeft]
          exact hOpen.2
      · right
        rcases hConsumed with ⟨hNotExposed, input, hInput, hEdges⟩
        refine ⟨?_, input, ?_, ?_⟩
        · intro hExposed
          rcases Finset.mem_union.mp hExposed with hLeftExposed | hRightExposed
          · exact hNotLeft (left.exposedOutput_mem output hLeftExposed)
          · exact hNotExposed hRightExposed
        · exact Finset.mem_union_right left.inputs hInput
        · rw [overlay_filter_output_right left right hNotLeft]
          exact hEdges
  · intro input hInput
    have hInputDisjoint : InputDisjoint left right := hDisjoint.right.right
    rcases Finset.mem_union.mp hInput with hLeftInput | hRightInput
    · have hNotRight : input ∉ right.inputs := by
        intro hRightInput
        exact hInputDisjoint input hLeftInput hRightInput
      have hLeftLinear := hLeft.right input hLeftInput
      rcases hLeftLinear with hOpen | hProduced
      · left
        refine ⟨?_, ?_⟩
        · exact Finset.mem_union_left right.exposedInputs hOpen.1
        · rw [overlay_filter_input_left left right hNotRight]
          exact hOpen.2
      · right
        rcases hProduced with ⟨hNotExposed, output, hOutput, hEdges⟩
        refine ⟨?_, output, ?_, ?_⟩
        · intro hExposed
          rcases Finset.mem_union.mp hExposed with hLeftExposed | hRightExposed
          · exact hNotExposed hLeftExposed
          · exact hNotRight (right.exposedInput_mem input hRightExposed)
        · exact Finset.mem_union_left right.outputs hOutput
        · rw [overlay_filter_input_left left right hNotRight]
          exact hEdges
    · have hNotLeft : input ∉ left.inputs := by
        intro hLeftInput
        exact hInputDisjoint input hLeftInput hRightInput
      have hRightLinear := hRight.right input hRightInput
      rcases hRightLinear with hOpen | hProduced
      · left
        refine ⟨?_, ?_⟩
        · exact Finset.mem_union_right left.exposedInputs hOpen.1
        · rw [overlay_filter_input_right left right hNotLeft]
          exact hOpen.2
      · right
        rcases hProduced with ⟨hNotExposed, output, hOutput, hEdges⟩
        refine ⟨?_, output, ?_, ?_⟩
        · intro hExposed
          rcases Finset.mem_union.mp hExposed with hLeftExposed | hRightExposed
          · exact hNotLeft (left.exposedInput_mem input hLeftExposed)
          · exact hNotExposed hRightExposed
        · exact Finset.mem_union_right left.outputs hOutput
        · rw [overlay_filter_input_right left right hNotLeft]
          exact hEdges

/-! ## Certified Source Contraction -/

/-- `contract graph output input` consumes one exposed output and one exposed input, adding the
single source port edge between them.

This is the proof-side shape after elaboration has already selected one compatible pair. It is not
ADR 0047's raw `=>` matching algorithm: compatibility, counterpart cardinality, bulk contraction,
and static-error cases are separate admission obligations. -/
def contract
    (graph : LinearPortGraph node outputPort inputPort)
    (output : SourcePortInstance node outputPort)
    (input : SourcePortInstance node inputPort)
    (hOutputExposed : output ∈ graph.exposedOutputs)
    (hInputExposed : input ∈ graph.exposedInputs) :
    LinearPortGraph node outputPort inputPort where
  nodes := graph.nodes
  outputs := graph.outputs
  inputs := graph.inputs
  exposedOutputs := graph.exposedOutputs.erase output
  exposedInputs := graph.exposedInputs.erase input
  portEdges := insert (output, input) graph.portEdges
  output_nodes := graph.output_nodes
  input_nodes := graph.input_nodes
  exposedOutput_mem := by
    intro candidate hCandidate
    exact graph.exposedOutput_mem candidate (Finset.mem_of_mem_erase hCandidate)
  exposedInput_mem := by
    intro candidate hCandidate
    exact graph.exposedInput_mem candidate (Finset.mem_of_mem_erase hCandidate)
  edge_output_mem := by
    intro edge hEdge
    rcases Finset.mem_insert.mp hEdge with hNew | hOld
    · rcases hNew
      exact graph.exposedOutput_mem output hOutputExposed
    · exact graph.edge_output_mem edge hOld
  edge_input_mem := by
    intro edge hEdge
    rcases Finset.mem_insert.mp hEdge with hNew | hOld
    · rcases hNew
      exact graph.exposedInput_mem input hInputExposed
    · exact graph.edge_input_mem edge hOld


/-- Forgetting ports after certified contraction inserts the contracted node edge.

The insert is set-theoretic: if another source port edge already lowered to the same node edge, the
lowered relation is unchanged. -/
theorem forgetPorts_contract
    (graph : LinearPortGraph node outputPort inputPort)
    (output : SourcePortInstance node outputPort)
    (input : SourcePortInstance node inputPort)
    (hOutputExposed : output ∈ graph.exposedOutputs)
    (hInputExposed : input ∈ graph.exposedInputs) :
    (graph.contract output input hOutputExposed hInputExposed).forgetPorts =
      { vertices := graph.forgetPorts.vertices
        edges := insert (output.node, input.node) graph.forgetPorts.edges } := by
  ext edge <;> simp [forgetPorts, contract]

/-- Certified single-edge contraction preserves source port linearity.

The assumptions say the matched endpoints are exposed. Their existing edge filters are therefore
empty by `PortLinear`; inserting exactly their edge makes them consumed exactly once, while every
other endpoint keeps its previous filter. -/
theorem contract_preserves_portLinear
    (graph : LinearPortGraph node outputPort inputPort)
    (hLinear : graph.PortLinear)
    (output : SourcePortInstance node outputPort)
    (input : SourcePortInstance node inputPort)
    (hOutputExposed : output ∈ graph.exposedOutputs)
    (hInputExposed : input ∈ graph.exposedInputs) :
    (graph.contract output input hOutputExposed hInputExposed).PortLinear := by
  have hOutputMem : output ∈ graph.outputs := graph.exposedOutput_mem output hOutputExposed
  have hInputMem : input ∈ graph.inputs := graph.exposedInput_mem input hInputExposed
  have hOutputOpen := hLinear.left output hOutputMem
  have hInputOpen := hLinear.right input hInputMem
  have hOutputNoEdges : graph.portEdges.filter (fun edge => edge.1 = output) = ∅ := by
    rcases hOutputOpen with hOpen | hConsumed
    · exact hOpen.2
    · exact False.elim (hConsumed.1 hOutputExposed)
  have hInputNoEdges : graph.portEdges.filter (fun edge => edge.2 = input) = ∅ := by
    rcases hInputOpen with hOpen | hProduced
    · exact hOpen.2
    · exact False.elim (hProduced.1 hInputExposed)
  constructor
  · intro candidate hCandidate
    by_cases hSame : candidate = output
    · subst candidate
      right
      refine ⟨?_, input, hInputMem, ?_⟩
      · simp [contract]
      · ext edge
        constructor
        · intro hEdge
          have hMember :
              edge ∈ insert (output, input) graph.portEdges ∧ edge.1 = output := by
            simpa [contract] using hEdge
          rcases hMember with ⟨hInsert, hSource⟩
          rcases Finset.mem_insert.mp hInsert with hNew | hOld
          · simpa using hNew
          · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.1 = output) :=
              Finset.mem_filter.mpr ⟨hOld, hSource⟩
            rw [hOutputNoEdges] at hOldFiltered
            simp at hOldFiltered
        · intro hEdge
          have hEq : edge = (output, input) := by simpa using hEdge
          subst hEq
          exact Finset.mem_filter.mpr ⟨Finset.mem_insert_self _ _, rfl⟩
    · have hOldLinear := hLinear.left candidate hCandidate
      rcases hOldLinear with hOpen | hConsumed
      · left
        refine ⟨?_, ?_⟩
        · simp [contract, hSame, hOpen.1]
        · ext edge
          constructor
          · intro hEdge
            have hMember :
                edge ∈ insert (output, input) graph.portEdges ∧ edge.1 = candidate := by
              simpa [contract] using hEdge
            rcases hMember with ⟨hInsert, hSource⟩
            rcases Finset.mem_insert.mp hInsert with hNew | hOld
            · rcases hNew
              exact False.elim (hSame hSource.symm)
            · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.1 = candidate) :=
                Finset.mem_filter.mpr ⟨hOld, hSource⟩
              rw [hOpen.2] at hOldFiltered
              simp at hOldFiltered
          · intro hEdge
            simp at hEdge
      · right
        rcases hConsumed with ⟨hNotExposed, oldInput, hOldInput, hEdges⟩
        refine ⟨?_, oldInput, hOldInput, ?_⟩
        · simp [contract, hSame, hNotExposed]
        · ext edge
          constructor
          · intro hEdge
            have hMember :
                edge ∈ insert (output, input) graph.portEdges ∧ edge.1 = candidate := by
              simpa [contract] using hEdge
            rcases hMember with ⟨hInsert, hSource⟩
            rcases Finset.mem_insert.mp hInsert with hNew | hOld
            · rcases hNew
              exact False.elim (hSame hSource.symm)
            · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.1 = candidate) :=
                Finset.mem_filter.mpr ⟨hOld, hSource⟩
              rw [hEdges] at hOldFiltered
              simpa using hOldFiltered
          · intro hEdge
            have hEdgeOld : edge ∈ graph.portEdges.filter (fun edge => edge.1 = candidate) := by
              rw [hEdges]
              exact hEdge
            rcases Finset.mem_filter.mp hEdgeOld with ⟨hOld, hSource⟩
            exact Finset.mem_filter.mpr ⟨Finset.mem_insert_of_mem hOld, hSource⟩
  · intro candidate hCandidate
    by_cases hSame : candidate = input
    · subst candidate
      right
      refine ⟨?_, output, hOutputMem, ?_⟩
      · simp [contract]
      · ext edge
        constructor
        · intro hEdge
          have hMember :
              edge ∈ insert (output, input) graph.portEdges ∧ edge.2 = input := by
            simpa [contract] using hEdge
          rcases hMember with ⟨hInsert, hTarget⟩
          rcases Finset.mem_insert.mp hInsert with hNew | hOld
          · simpa using hNew
          · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.2 = input) :=
              Finset.mem_filter.mpr ⟨hOld, hTarget⟩
            rw [hInputNoEdges] at hOldFiltered
            simp at hOldFiltered
        · intro hEdge
          have hEq : edge = (output, input) := by simpa using hEdge
          subst hEq
          exact Finset.mem_filter.mpr ⟨Finset.mem_insert_self _ _, rfl⟩
    · have hOldLinear := hLinear.right candidate hCandidate
      rcases hOldLinear with hOpen | hProduced
      · left
        refine ⟨?_, ?_⟩
        · simp [contract, hSame, hOpen.1]
        · ext edge
          constructor
          · intro hEdge
            have hMember :
                edge ∈ insert (output, input) graph.portEdges ∧ edge.2 = candidate := by
              simpa [contract] using hEdge
            rcases hMember with ⟨hInsert, hTarget⟩
            rcases Finset.mem_insert.mp hInsert with hNew | hOld
            · rcases hNew
              exact False.elim (hSame hTarget.symm)
            · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.2 = candidate) :=
                Finset.mem_filter.mpr ⟨hOld, hTarget⟩
              rw [hOpen.2] at hOldFiltered
              simp at hOldFiltered
          · intro hEdge
            simp at hEdge
      · right
        rcases hProduced with ⟨hNotExposed, oldOutput, hOldOutput, hEdges⟩
        refine ⟨?_, oldOutput, hOldOutput, ?_⟩
        · simp [contract, hSame, hNotExposed]
        · ext edge
          constructor
          · intro hEdge
            have hMember :
                edge ∈ insert (output, input) graph.portEdges ∧ edge.2 = candidate := by
              simpa [contract] using hEdge
            rcases hMember with ⟨hInsert, hTarget⟩
            rcases Finset.mem_insert.mp hInsert with hNew | hOld
            · rcases hNew
              exact False.elim (hSame hTarget.symm)
            · have hOldFiltered : edge ∈ graph.portEdges.filter (fun edge => edge.2 = candidate) :=
                Finset.mem_filter.mpr ⟨hOld, hTarget⟩
              rw [hEdges] at hOldFiltered
              simpa using hOldFiltered
          · intro hEdge
            have hEdgeOld : edge ∈ graph.portEdges.filter (fun edge => edge.2 = candidate) := by
              rw [hEdges]
              exact hEdge
            rcases Finset.mem_filter.mp hEdgeOld with ⟨hOld, hTarget⟩
            exact Finset.mem_filter.mpr ⟨Finset.mem_insert_of_mem hOld, hTarget⟩

/-! ## Certified Bulk Contraction -/

/-- `BulkContract start finish` is a sequence of certified single-pair contractions.

This models the preservation side of bulk `=>` contraction after deterministic matching has already
chosen the pairs and ordered the certified steps. The raw compatibility/match-count algorithm and
static-error cases remain compiler-admission obligations.

ADR 0047 treats the selected matches as one simultaneous boundary contraction. This proof carrier
records them as an ordered trace only so preservation can proceed by induction over the already
certified single-pair contraction theorem. The trace order is not intended to carry source
semantics; a future `bulkContract_permutation_invariant` lemma should make the permutation
invariance explicit. -/
inductive BulkContract :
    LinearPortGraph node outputPort inputPort →
      LinearPortGraph node outputPort inputPort →
        Type where
  | done (graph : LinearPortGraph node outputPort inputPort) :
      BulkContract graph graph
  | step
      (graph : LinearPortGraph node outputPort inputPort)
      (output : SourcePortInstance node outputPort)
      (input : SourcePortInstance node inputPort)
      (hOutputExposed : output ∈ graph.exposedOutputs)
      (hInputExposed : input ∈ graph.exposedInputs)
      {finish : LinearPortGraph node outputPort inputPort}
      (tail :
        BulkContract
          (graph.contract output input hOutputExposed hInputExposed)
          finish) :
      BulkContract graph finish

/-- Certified bulk contraction preserves source port linearity. -/
theorem bulkContract_preserves_portLinear
    {start finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract start finish)
    (hLinear : start.PortLinear) :
    finish.PortLinear := by
  induction hBulk with
  | done graph =>
      exact hLinear
  | step graph output input hOutputExposed hInputExposed tail ih =>
      exact
        ih
          (contract_preserves_portLinear
            graph
            hLinear
            output
            input
            hOutputExposed
            hInputExposed)

/-- Node-level relation edges inserted by a certified bulk contraction trace. -/
def BulkContract.loweredEdges :
    {start finish : LinearPortGraph node outputPort inputPort} →
      BulkContract start finish →
        Finset (node × node)
  | _, _, BulkContract.done _ => ∅
  | _, _, BulkContract.step _ output input _ _ tail =>
      insert (output.node, input.node) (BulkContract.loweredEdges tail)

/-- Forgetting ports after certified bulk contraction inserts some finite set of node edges.

The inserted relation edges are projected from the certified contraction trace. After lowering,
port identity is forgotten, but the node-level edge set remains tied to the source proof object. -/
theorem forgetPorts_bulkContract
    {start finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract start finish) :
    finish.forgetPorts =
      { vertices := start.forgetPorts.vertices
        edges := start.forgetPorts.edges ∪ hBulk.loweredEdges } := by
  induction hBulk with
  | done graph =>
      ext edge <;> simp [BulkContract.loweredEdges]
  | step graph output input hOutputExposed hInputExposed tail ih =>
      rw [ih]
      ext edge <;>
        simp
          [ forgetPorts_contract graph output input hOutputExposed hInputExposed
          , Finset.union_insert
          , BulkContract.loweredEdges
          ]

/-- `openNodePorts` creates a source graph whose node ports are all open frontier resources.

This is the primitive `node_ports` object in the linear source algebra. It does not add edges or
perform contraction; later operations must consume exposed endpoints explicitly. -/
def openNodePorts
    (nodes : Finset node)
    (outputs : Finset (SourcePortInstance node outputPort))
    (inputs : Finset (SourcePortInstance node inputPort))
    (hOutputNodes : ∀ output, output ∈ outputs → output.node ∈ nodes)
    (hInputNodes : ∀ input, input ∈ inputs → input.node ∈ nodes) :
    LinearPortGraph node outputPort inputPort where
  nodes := nodes
  outputs := outputs
  inputs := inputs
  exposedOutputs := outputs
  exposedInputs := inputs
  portEdges := ∅
  output_nodes := hOutputNodes
  input_nodes := hInputNodes
  exposedOutput_mem := by
    intro output hOutput
    exact hOutput
  exposedInput_mem := by
    intro input hInput
    exact hInput
  edge_output_mem := by
    intro edge hEdge
    simp at hEdge
  edge_input_mem := by
    intro edge hEdge
    simp at hEdge

/-- Open node-port resources are source-linear before any operation consumes them. -/
theorem openNodePorts_portLinear
    (nodes : Finset node)
    (outputs : Finset (SourcePortInstance node outputPort))
    (inputs : Finset (SourcePortInstance node inputPort))
    (hOutputNodes : ∀ output, output ∈ outputs → output.node ∈ nodes)
    (hInputNodes : ∀ input, input ∈ inputs → input.node ∈ nodes) :
    (openNodePorts nodes outputs inputs hOutputNodes hInputNodes).PortLinear := by
  constructor
  · intro output hOutput
    left
    constructor
    · exact hOutput
    · simp [openNodePorts]
  · intro input hInput
    left
    constructor
    · exact hInput
    · simp [openNodePorts]

/-- `LinearPortObject` packages a source port graph with its linear-resource proof.

The source algebra works over these objects, not over raw graph syntax. This is the proof-level
version of "{operations, node_ports}" as the linear interface. -/
structure LinearPortObject (node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Source port graph carried by this linear object. -/
  graph : LinearPortGraph node outputPort inputPort
  /-- The graph satisfies the source endpoint linearity rule. -/
  linear : graph.PortLinear

namespace LinearPortObject

/-- Construct a linear object from open node-port resources. -/
def nodePorts
    (nodes : Finset node)
    (outputs : Finset (SourcePortInstance node outputPort))
    (inputs : Finset (SourcePortInstance node inputPort))
    (hOutputNodes : ∀ output, output ∈ outputs → output.node ∈ nodes)
    (hInputNodes : ∀ input, input ∈ inputs → input.node ∈ nodes) :
    LinearPortObject node outputPort inputPort where
  graph := openNodePorts nodes outputs inputs hOutputNodes hInputNodes
  linear := openNodePorts_portLinear nodes outputs inputs hOutputNodes hInputNodes

/-- Certified overlay is a linear algebra operation when endpoint resources are disjoint. -/
def overlay
    (left right : LinearPortObject node outputPort inputPort)
    (hDisjoint : DomainDisjoint left.graph right.graph) :
    LinearPortObject node outputPort inputPort where
  graph := LinearPortGraph.overlay left.graph right.graph
  linear :=
    overlay_preserves_portLinear
      left.graph
      right.graph
      left.linear
      right.linear
      hDisjoint

end LinearPortObject

/-- A source operation is certified for linearity when it returns a linear proof object.

This is a proof-object interface, not an executable elaboration theorem. Raw syntax such as `=>`
becomes part of this layer only after the compiler supplies the corresponding certificate. -/
structure LinearPortOperation (node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Execute the certified operation on a linear source object. -/
  apply :
    LinearPortObject node outputPort inputPort →
      LinearPortObject node outputPort inputPort

namespace LinearPortOperation

/-- Sequential composition of certified linear source operations. -/
def thenOp
    (first second : LinearPortOperation node outputPort inputPort) :
    LinearPortOperation node outputPort inputPort where
  apply := fun object => second.apply (first.apply object)

/-- Running a certified operation exposes the returned object's source-linearity proof. -/
theorem apply_result_portLinear
    (operation : LinearPortOperation node outputPort inputPort)
    (object : LinearPortObject node outputPort inputPort) :
    (operation.apply object).graph.PortLinear :=
  (operation.apply object).linear

/-- Sequential composition exposes the returned object's source-linearity proof. -/
theorem thenOp_result_portLinear
    (first second : LinearPortOperation node outputPort inputPort)
    (object : LinearPortObject node outputPort inputPort) :
    ((first.thenOp second).apply object).graph.PortLinear :=
  ((first.thenOp second).apply object).linear

end LinearPortOperation

/-- `LinearPortSystem` packages a certified source object after source elaboration.

This is intentionally not raw Wire or Mokhov syntax. It is the interface that compiler elaboration
must target before claiming source frontier linearity. -/
structure LinearPortSystem (node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Certified linear object produced by the source algebra. -/
  object : LinearPortObject node outputPort inputPort

namespace LinearPortSystem

/-- The primitive `node_ports` generator for the source linear algebra. -/
def nodePorts
    (nodes : Finset node)
    (outputs : Finset (SourcePortInstance node outputPort))
    (inputs : Finset (SourcePortInstance node inputPort))
    (hOutputNodes : ∀ output, output ∈ outputs → output.node ∈ nodes)
    (hInputNodes : ∀ input, input ∈ inputs → input.node ∈ nodes) :
    LinearPortSystem node outputPort inputPort where
  object := LinearPortObject.nodePorts nodes outputs inputs hOutputNodes hInputNodes

/-- Certified overlay is one operation of the certified source system layer. -/
def overlay
    (left right : LinearPortSystem node outputPort inputPort)
    (hDisjoint : DomainDisjoint left.object.graph right.object.graph) :
    LinearPortSystem node outputPort inputPort where
  object := LinearPortObject.overlay left.object right.object hDisjoint

/-- Apply a certified operation inside the certified source system layer. -/
def operation
    (operation : LinearPortOperation node outputPort inputPort)
    (input : LinearPortSystem node outputPort inputPort) :
    LinearPortSystem node outputPort inputPort where
  object := operation.apply input.object

/-- A certified source system exposes its bundled source-linearity proof. -/
theorem certified_portLinear
    (system : LinearPortSystem node outputPort inputPort) :
    system.object.graph.PortLinear :=
  system.object.linear

end LinearPortSystem

end LinearPortGraph

/-! ## Port Instances And Uses -/

/-- `ActualizedPortInstance` identifies one named port on one actualized node. -/
structure ActualizedPortInstance (node port : Type) where
  /-- Actualized node that owns this port instance. -/
  node : node
  /-- Port label or proof-side port identity on that node. -/
  port : port
  deriving DecidableEq, Repr

/-- `OutputPortUse` is one concrete consumer for one output port instance.

The `terminal` payload abstracts over egress, sink, and exported-boundary
discharges. Port linearity only needs to know that terminal discharge consumes
the output once; the terminal's operational kind is a later correspondence
detail. -/
inductive OutputPortUse (input terminal : Type) : Type where
  | edge (input : input)
  | terminalDischarge (terminal : terminal)
  deriving DecidableEq, Repr

/-! ## Actualized Port Graphs -/

/-- `ActualizedPortGraph` records port consumers and producers for a closed graph. -/
structure ActualizedPortGraph
    (node outputPort inputPort terminal : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort]
    [DecidableEq terminal] where
  /-- Output port instances that must be accounted for. -/
  outputs : Finset (ActualizedPortInstance node outputPort)
  /-- Input port instances that must be accounted for. -/
  inputs : Finset (ActualizedPortInstance node inputPort)
  /-- Downstream input consumers for each output port instance. -/
  edgeConsumers :
    ActualizedPortInstance node outputPort →
      Finset (ActualizedPortInstance node inputPort)
  /-- Terminal discharges for each output port instance. -/
  terminalDischarges : ActualizedPortInstance node outputPort → Finset terminal
  /-- Upstream output producers for each input port instance. -/
  inputProducers :
    ActualizedPortInstance node inputPort →
      Finset (ActualizedPortInstance node outputPort)

namespace ActualizedPortGraph

variable {node outputPort inputPort terminal : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]
variable [DecidableEq terminal]

/-- An output has exactly one edge consumer or exactly one terminal discharge. -/
def OutputConsumedExactlyOnce
    (graph : ActualizedPortGraph node outputPort inputPort terminal)
    (output : ActualizedPortInstance node outputPort) : Prop :=
  (∃ input,
    input ∈ graph.inputs ∧
      graph.edgeConsumers output = {input} ∧
        graph.terminalDischarges output = ∅) ∨
    ∃ terminal,
      graph.edgeConsumers output = ∅ ∧
        graph.terminalDischarges output = {terminal}

/-- An input has exactly one edge producer. -/
def InputProducedExactlyOnce
    (graph : ActualizedPortGraph node outputPort inputPort terminal)
    (input : ActualizedPortInstance node inputPort) : Prop :=
  ∃ output,
    output ∈ graph.outputs ∧
      graph.inputProducers input = {output} ∧
        graph.edgeConsumers output = {input}

/-- `ClosedOutputLinear graph` is the output-consumer side of closed port use. -/
def ClosedOutputLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  ∀ output,
    output ∈ graph.outputs →
      graph.OutputConsumedExactlyOnce output

/-- `ClosedInputLinear graph` is the input-producer side of closed port use. -/
def ClosedInputLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  ∀ input,
    input ∈ graph.inputs →
      graph.InputProducedExactlyOnce input

/-- `ClosedPortLinear graph` is Paper 5's exact-once rule for closed actualized port use. -/
def ClosedPortLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  graph.ClosedOutputLinear ∧ graph.ClosedInputLinear

/-- Output domains are disjoint when no output port instance occurs in both graphs. -/
def OutputDisjoint
    (left right : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  ∀ output,
    output ∈ left.outputs →
      output ∈ right.outputs →
        False

/-- Input domains are disjoint when no input port instance occurs in both graphs. -/
def InputDisjoint
    (left right : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  ∀ input,
    input ∈ left.inputs →
      input ∈ right.inputs →
        False

/-- Port domains are disjoint when both input and output port domains are disjoint. -/
def DomainDisjoint
    (left right : ActualizedPortGraph node outputPort inputPort terminal) : Prop :=
  OutputDisjoint left right ∧ InputDisjoint left right

/-- `overlay left right` combines disjoint actualized port-use graphs. -/
def overlay
    (left right : ActualizedPortGraph node outputPort inputPort terminal) :
    ActualizedPortGraph node outputPort inputPort terminal where
  outputs := left.outputs ∪ right.outputs
  inputs := left.inputs ∪ right.inputs
  edgeConsumers := fun output =>
    if output ∈ left.outputs then
      left.edgeConsumers output
    else
      right.edgeConsumers output
  terminalDischarges := fun output =>
    if output ∈ left.outputs then
      left.terminalDischarges output
    else
      right.terminalDischarges output
  inputProducers := fun input =>
    if input ∈ left.inputs then
      left.inputProducers input
    else
      right.inputProducers input

/-- Closed port linearity is preserved by overlaying disjoint port domains. -/
theorem overlay_preserves_closedPortLinearity
    (left right : ActualizedPortGraph node outputPort inputPort terminal)
    (hLeft : left.ClosedPortLinear)
    (hRight : right.ClosedPortLinear)
    (hDisjoint : DomainDisjoint left right) :
    (overlay left right).ClosedPortLinear := by
  constructor
  · intro output hOutput
    have hOutputDisjoint : OutputDisjoint left right := hDisjoint.left
    have hUnion : output ∈ left.outputs ∪ right.outputs := by
      simpa only [overlay] using hOutput
    have hEither : output ∈ left.outputs ∨ output ∈ right.outputs :=
      Finset.mem_union.mp hUnion
    cases hEither with
    | inl hLeftOutput =>
        have hLinear : left.OutputConsumedExactlyOnce output :=
          hLeft.left output hLeftOutput
        cases hLinear with
        | inl hEdge =>
            rcases hEdge with ⟨input, hInput, hEdges, hTerminals⟩
            left
            refine ⟨input, ?_, ?_, ?_⟩
            · exact Finset.mem_union.mpr (Or.inl hInput)
            · simpa only [overlay, hLeftOutput, if_true] using hEdges
            · simpa only [overlay, hLeftOutput, if_true] using hTerminals
        | inr hTerminal =>
            rcases hTerminal with ⟨terminal, hEdges, hTerminals⟩
            right
            refine ⟨terminal, ?_, ?_⟩
            · simpa only [overlay, hLeftOutput, if_true] using hEdges
            · simpa only [overlay, hLeftOutput, if_true] using hTerminals
    | inr hRightOutput =>
        have hNotLeft : output ∉ left.outputs := by
          intro hLeftOutput
          exact hOutputDisjoint output hLeftOutput hRightOutput
        have hLinear : right.OutputConsumedExactlyOnce output :=
          hRight.left output hRightOutput
        cases hLinear with
        | inl hEdge =>
            rcases hEdge with ⟨input, hInput, hEdges, hTerminals⟩
            left
            refine ⟨input, ?_, ?_, ?_⟩
            · exact Finset.mem_union.mpr (Or.inr hInput)
            · simpa only [overlay, hNotLeft, if_false] using hEdges
            · simpa only [overlay, hNotLeft, if_false] using hTerminals
        | inr hTerminal =>
            rcases hTerminal with ⟨terminal, hEdges, hTerminals⟩
            right
            refine ⟨terminal, ?_, ?_⟩
            · simpa only [overlay, hNotLeft, if_false] using hEdges
            · simpa only [overlay, hNotLeft, if_false] using hTerminals
  · intro input hInput
    have hInputDisjoint : InputDisjoint left right := hDisjoint.right
    have hOutputDisjoint : OutputDisjoint left right := hDisjoint.left
    have hUnion : input ∈ left.inputs ∪ right.inputs := by
      simpa only [overlay] using hInput
    have hEither : input ∈ left.inputs ∨ input ∈ right.inputs :=
      Finset.mem_union.mp hUnion
    cases hEither with
    | inl hLeftInput =>
        rcases hLeft.right input hLeftInput with
          ⟨output, hLeftOutput, hProducer, hEdges⟩
        refine ⟨output, ?_, ?_, ?_⟩
        · exact Finset.mem_union.mpr (Or.inl hLeftOutput)
        · simpa only [overlay, hLeftInput, if_true] using hProducer
        · simpa only [overlay, hLeftOutput, if_true] using hEdges
    | inr hRightInput =>
        have hNotLeftInput : input ∉ left.inputs := by
          intro hLeftInput
          exact hInputDisjoint input hLeftInput hRightInput
        rcases hRight.right input hRightInput with
          ⟨output, hRightOutput, hProducer, hEdges⟩
        have hNotLeftOutput : output ∉ left.outputs := by
          intro hLeftOutput
          exact hOutputDisjoint output hLeftOutput hRightOutput
        refine ⟨output, ?_, ?_, ?_⟩
        · exact Finset.mem_union.mpr (Or.inr hRightOutput)
        · simpa only [overlay, hNotLeftInput, if_false] using hProducer
        · simpa only [overlay, hNotLeftOutput, if_false] using hEdges

end ActualizedPortGraph

/-! ## Compiler Port-Use Witnesses -/

/-- `PortUseWitness` is the proof-side witness produced by compiler or admission.

The finite `outputs` and `inputs` domains are intentionally explicit and
caller-supplied. The open Haskell correspondence obligation is to prove that
these domains are exactly the compiled graph's actualized port instances and
that the executable admission path rejects source graphs that cannot construct
such a witness. Without that exactness correspondence, this is only a witness
checker for the domain it is given. -/
structure PortUseWitness
    (node outputPort inputPort terminal : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort]
    [DecidableEq terminal] where
  /-- Actualized output port instances known to the closed graph. -/
  outputs : Finset (ActualizedPortInstance node outputPort)
  /-- Actualized input port instances known to the closed graph. -/
  inputs : Finset (ActualizedPortInstance node inputPort)
  /-- Exactly one use chosen for each output port instance. -/
  outputUse :
    ActualizedPortInstance node outputPort →
      OutputPortUse (ActualizedPortInstance node inputPort) terminal
  /-- Exactly one producer chosen for each input port instance. -/
  inputProducer :
    ActualizedPortInstance node inputPort →
      ActualizedPortInstance node outputPort
  /-- Input producers are actualized output port instances. -/
  inputProducer_mem :
    ∀ input,
      input ∈ inputs →
        inputProducer input ∈ outputs
  /-- The declared input producer has an edge use to that input. -/
  inputProducer_edge :
    ∀ input,
      input ∈ inputs →
        outputUse (inputProducer input) = OutputPortUse.edge input
  /-- Every edge consumer is an actualized input port instance. -/
  edgeInput_mem :
    ∀ output,
      output ∈ outputs →
        ∀ input,
          outputUse output = OutputPortUse.edge input →
            input ∈ inputs
  /-- Every edge consumer points back to the output that produced it. -/
  edgeInput_producer_eq :
    ∀ output,
      output ∈ outputs →
        ∀ input,
          outputUse output = OutputPortUse.edge input →
            inputProducer input = output

namespace PortUseWitness

variable {node outputPort inputPort terminal : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]
variable [DecidableEq terminal]

/-- Convert a compiler port-use witness into the relation-shaped graph model. -/
def toGraph
    (witness : PortUseWitness node outputPort inputPort terminal) :
    ActualizedPortGraph node outputPort inputPort terminal where
  outputs := witness.outputs
  inputs := witness.inputs
  edgeConsumers := fun output =>
    if _hOutput : output ∈ witness.outputs then
      match witness.outputUse output with
      | OutputPortUse.edge input => {input}
      | OutputPortUse.terminalDischarge _terminal => ∅
    else
      ∅
  terminalDischarges := fun output =>
    if _hOutput : output ∈ witness.outputs then
      match witness.outputUse output with
      | OutputPortUse.edge _input => ∅
      | OutputPortUse.terminalDischarge terminal => {terminal}
    else
      ∅
  inputProducers := fun input =>
    if _hInput : input ∈ witness.inputs then
      {witness.inputProducer input}
    else
      ∅

end PortUseWitness

section

variable
  {node outputPort inputPort terminal : Type}
  [DecidableEq node]
  [DecidableEq outputPort]
  [DecidableEq inputPort]
  [DecidableEq terminal]

/-- A witnessed output is consumed by exactly one edge or terminal discharge. -/
theorem actualizedOutputPort_consumed_exactly_once
    (witness : PortUseWitness node outputPort inputPort terminal)
    {output : ActualizedPortInstance node outputPort}
    (hOutput : output ∈ witness.outputs) :
    witness.toGraph.OutputConsumedExactlyOnce output := by
  cases hUse : witness.outputUse output with
  | edge input =>
      left
      refine ⟨input, ?_, ?_, ?_⟩
      · exact witness.edgeInput_mem output hOutput input hUse
      · simp only [PortUseWitness.toGraph, hOutput, hUse, ↓reduceDIte]
      · simp only [PortUseWitness.toGraph, hOutput, hUse, ↓reduceDIte]
  | terminalDischarge terminal =>
      right
      refine ⟨terminal, ?_, ?_⟩
      · simp only [PortUseWitness.toGraph, hOutput, hUse, ↓reduceDIte]
      · simp only [PortUseWitness.toGraph, hOutput, hUse, ↓reduceDIte]

/-- A witnessed input is produced by exactly one edge. -/
theorem actualizedInputPort_produced_exactly_once
    (witness : PortUseWitness node outputPort inputPort terminal)
    {input : ActualizedPortInstance node inputPort}
    (hInput : input ∈ witness.inputs) :
    witness.toGraph.InputProducedExactlyOnce input := by
  refine ⟨witness.inputProducer input, ?_, ?_, ?_⟩
  · exact witness.inputProducer_mem input hInput
  · simp only [PortUseWitness.toGraph, hInput, ↓reduceDIte]
  · have hProducerMem : witness.inputProducer input ∈ witness.outputs :=
      witness.inputProducer_mem input hInput
    have hProducerEdge :
        witness.outputUse (witness.inputProducer input) = OutputPortUse.edge input :=
      witness.inputProducer_edge input hInput
    simp only [PortUseWitness.toGraph, hProducerMem, hProducerEdge, ↓reduceDIte]

/-- Two edge outputs cannot produce the same input unless they are the same output. -/
theorem compiledPortUseWitness_edge_input_uniqueProducer
    (witness : PortUseWitness node outputPort inputPort terminal)
    {left right : ActualizedPortInstance node outputPort}
    {input : ActualizedPortInstance node inputPort}
    (hLeftOutput : left ∈ witness.outputs)
    (hRightOutput : right ∈ witness.outputs)
    (hLeftEdge : witness.outputUse left = OutputPortUse.edge input)
    (hRightEdge : witness.outputUse right = OutputPortUse.edge input) :
    left = right := by
  have hLeftProducer : witness.inputProducer input = left :=
    witness.edgeInput_producer_eq left hLeftOutput input hLeftEdge
  have hRightProducer : witness.inputProducer input = right :=
    witness.edgeInput_producer_eq right hRightOutput input hRightEdge
  calc
    left = witness.inputProducer input := by
      exact Eq.symm hLeftProducer
    _ = right := hRightProducer

/-- A supplied port-use witness establishes closed linearity for its own graph domain. -/
theorem portUseWitness_toGraph_closedPortLinear
    (witness : PortUseWitness node outputPort inputPort terminal) :
    witness.toGraph.ClosedPortLinear := by
  constructor
  · intro output hOutput
    have hWitnessOutput : output ∈ witness.outputs := by
      simpa only [PortUseWitness.toGraph] using hOutput
    exact actualizedOutputPort_consumed_exactly_once witness hWitnessOutput
  · intro input hInput
    have hWitnessInput : input ∈ witness.inputs := by
      simpa only [PortUseWitness.toGraph] using hInput
    exact actualizedInputPort_produced_exactly_once witness hWitnessInput

end

/-! ## Selected-Branch Preservation -/

/-- Port-use graph for the selected arm of a `select(...)` actualization.

The domain-exact projection from a runtime selected fragment into this graph is a separate
correspondence obligation; this structure records the local witness once supplied. -/
structure SelectedActualizedPortGraph
    (node arm outputPort inputPort terminal : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort]
    [DecidableEq terminal]
    {family : LatentBranchFamily node arm}
    (actualize : SelectActualize family) where
  /-- Port consumer and producer graph contributed by the selected branch. -/
  graph : ActualizedPortGraph node outputPort inputPort terminal
  /-- Every selected output belongs to the selected latent fragment's node set. -/
  outputsWithinSelectedFragment :
    ∀ output,
      output ∈ graph.outputs →
        output.node ∈ actualize.selectedFragmentNodes
  /-- Every selected input belongs to the selected latent fragment's node set. -/
  inputsWithinSelectedFragment :
    ∀ input,
      input ∈ graph.inputs →
        input.node ∈ actualize.selectedFragmentNodes

section

variable
  {node arm outputPort inputPort terminal : Type}
  [DecidableEq node]
  [DecidableEq outputPort]
  [DecidableEq inputPort]
  [DecidableEq terminal]
  {family : LatentBranchFamily node arm}
  {actualize : SelectActualize family}

/-- Selected output witnesses are tied to the chosen latent branch fragment. -/
theorem selectActualize_selectedOutputs_within_selectedFragment
    (selected :
      SelectedActualizedPortGraph node arm outputPort inputPort terminal actualize)
    {output : ActualizedPortInstance node outputPort}
    (hOutput : output ∈ selected.graph.outputs) :
    output.node ∈ actualize.selectedFragmentNodes :=
  selected.outputsWithinSelectedFragment output hOutput

/-- Selected input witnesses are tied to the chosen latent branch fragment. -/
theorem selectActualize_selectedInputs_within_selectedFragment
    (selected :
      SelectedActualizedPortGraph node arm outputPort inputPort terminal actualize)
    {input : ActualizedPortInstance node inputPort}
    (hInput : input ∈ selected.graph.inputs) :
    input.node ∈ actualize.selectedFragmentNodes :=
  selected.inputsWithinSelectedFragment input hInput

/-- Current outputs outside the selected fragment are disjoint from selected outputs. -/
theorem selectActualize_currentOutputs_disjoint_selectedOutputs
    (current : ActualizedPortGraph node outputPort inputPort terminal)
    (selected :
      SelectedActualizedPortGraph node arm outputPort inputPort terminal actualize)
    (hCurrentOutsideSelected :
      ∀ output,
        output ∈ current.outputs →
          output.node ∉ actualize.selectedFragmentNodes) :
    ActualizedPortGraph.OutputDisjoint current selected.graph := by
  intro output hCurrentOutput hSelectedOutput
  have hSelectedNode :
      output.node ∈ actualize.selectedFragmentNodes :=
    selected.outputsWithinSelectedFragment output hSelectedOutput
  exact hCurrentOutsideSelected output hCurrentOutput hSelectedNode

/-- Current inputs outside the selected fragment are disjoint from selected inputs. -/
theorem selectActualize_currentInputs_disjoint_selectedInputs
    (current : ActualizedPortGraph node outputPort inputPort terminal)
    (selected :
      SelectedActualizedPortGraph node arm outputPort inputPort terminal actualize)
    (hCurrentOutsideSelected :
      ∀ input,
        input ∈ current.inputs →
          input.node ∉ actualize.selectedFragmentNodes) :
    ActualizedPortGraph.InputDisjoint current selected.graph := by
  intro input hCurrentInput hSelectedInput
  have hSelectedNode :
      input.node ∈ actualize.selectedFragmentNodes :=
    selected.inputsWithinSelectedFragment input hSelectedInput
  exact hCurrentOutsideSelected input hCurrentInput hSelectedNode

/-- Selected-arm actualization preserves closed port linearity under namespace freshness. -/
theorem selectActualize_preserves_closedPortLinearity
    (current : ActualizedPortGraph node outputPort inputPort terminal)
    (selected :
      SelectedActualizedPortGraph node arm outputPort inputPort terminal actualize)
    (hCurrent : current.ClosedPortLinear)
    (hSelected : selected.graph.ClosedPortLinear)
    (hCurrentOutputsOutsideSelected :
      ∀ output,
        output ∈ current.outputs →
          output.node ∉ actualize.selectedFragmentNodes)
    (hCurrentInputsOutsideSelected :
      ∀ input,
        input ∈ current.inputs →
          input.node ∉ actualize.selectedFragmentNodes) :
    (current.overlay selected.graph).ClosedPortLinear := by
  have hOutputDisjoint :
      ActualizedPortGraph.OutputDisjoint current selected.graph :=
    selectActualize_currentOutputs_disjoint_selectedOutputs
      current
      selected
      hCurrentOutputsOutsideSelected
  have hInputDisjoint :
      ActualizedPortGraph.InputDisjoint current selected.graph :=
    selectActualize_currentInputs_disjoint_selectedInputs
      current
      selected
      hCurrentInputsOutsideSelected
  exact
    ActualizedPortGraph.overlay_preserves_closedPortLinearity
      current
      selected.graph
      hCurrent
      hSelected
      ⟨hOutputDisjoint, hInputDisjoint⟩

end

end Cortex.Wire
