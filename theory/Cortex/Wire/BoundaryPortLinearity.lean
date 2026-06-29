import Cortex.Wire.PortLinearity

/-!
## Overview

Boundary-generalized actualized port linearity.

`Cortex.Wire.PortLinearity` certifies the *closed* shape: a `PortUseWitness`
forces every input to have an internal output producer (`inputProducer` is total
and `inputProducer_edge` ties it to an edge), so `portUseWitness_toGraph` lands
in `ClosedPortLinear`. A host input or an imported open-fragment obligation has
no internal producer, so it cannot even construct a `PortUseWitness`.

This module adds the boundary generalization on the *input* side only. The
output side is already boundary-general: `OutputPortUse` carries a
`terminalDischarge` constructor and `ClosedOutputLinear` already admits it
(host return, exported boundary, proof boundary sink). `InputPortUse` mirrors
`OutputPortUse`: an input is satisfied either by an internal `edge` or by a
`boundarySource` (a host input or imported obligation with no internal
producer). `BoundaryPortLinear` relaxes the input rule accordingly, and
`ClosedPortLinear` is recovered exactly as the empty-boundary corollary
(`boundaryPortLinear_empty_iff_closedPortLinear`), with
`portUseWitness_closedPortLinear_via_boundary` re-deriving the closed theorem
through the boundary machinery via the `ofPortUseWitness` embedding.

This mirrors the ADR 0081 endpoint-use partition at the proof layer:

> input_use  = produced_by_edge | host_input | imported_obligation
> output_use = consumed_by_edge | terminal_discharge
-/

namespace Cortex.Wire

/-! ## Input Port Uses -/

/-- `InputPortUse` is one producer for one input port instance, dual to
`OutputPortUse`. An input is satisfied by an internal upstream `edge` or by a
`boundarySource` (a host input or an imported open-fragment obligation with no
internal producer). The `boundarySource` payload abstracts over the boundary
kind exactly as `OutputPortUse`'s `terminal` abstracts over discharge kinds;
boundary port linearity only needs to know that a boundary input has no internal
producer, not its operational kind. -/
inductive InputPortUse (output boundarySource : Type) : Type where
  | edge (output : output)
  | boundarySource (source : boundarySource)
  deriving DecidableEq, Repr

namespace InputPortUse

/-- Whether an input use is a boundary source rather than an internal edge. -/
def isBoundary {output boundarySource : Type} :
    InputPortUse output boundarySource → Bool
  | .edge _ => false
  | .boundarySource _ => true

end InputPortUse

/-! ## Boundary Port Linearity -/

namespace ActualizedPortGraph

variable {node outputPort inputPort terminal : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]
variable [DecidableEq terminal]

/-- A boundary input is either supplied by a boundary source, in which case it
has no internal producer, or it is produced internally exactly once. The closed
rule `InputProducedExactlyOnce` is reused verbatim as the right disjunct. -/
def BoundaryInputSourcedExactlyOnce
    (graph : ActualizedPortGraph node outputPort inputPort terminal)
    (boundaryInputs : Finset (ActualizedPortInstance node inputPort))
    (input : ActualizedPortInstance node inputPort) : Prop :=
  (input ∈ boundaryInputs ∧ graph.inputProducers input = ∅) ∨
    graph.InputProducedExactlyOnce input

/-- Every actualized input is boundary-sourced or produced exactly once. -/
def BoundaryInputLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal)
    (boundaryInputs : Finset (ActualizedPortInstance node inputPort)) : Prop :=
  ∀ input,
    input ∈ graph.inputs →
      graph.BoundaryInputSourcedExactlyOnce boundaryInputs input

/-- `BoundaryPortLinear graph boundaryInputs` is the open/boundary generalization
of `ClosedPortLinear`: the output rule is unchanged (every output consumed once
or discharged once) and the input rule allows the declared boundary inputs to be
supplied externally. -/
def BoundaryPortLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal)
    (boundaryInputs : Finset (ActualizedPortInstance node inputPort)) : Prop :=
  graph.ClosedOutputLinear ∧ graph.BoundaryInputLinear boundaryInputs

/-- With no boundary inputs, boundary linearity is exactly closed linearity:
`ClosedPortLinear` is the fully-internal corollary of `BoundaryPortLinear`. -/
theorem boundaryPortLinear_empty_iff_closedPortLinear
    (graph : ActualizedPortGraph node outputPort inputPort terminal) :
    graph.BoundaryPortLinear ∅ ↔ graph.ClosedPortLinear := by
  unfold BoundaryPortLinear ClosedPortLinear
  refine and_congr_right (fun _ => ?_)
  unfold BoundaryInputLinear ClosedInputLinear BoundaryInputSourcedExactlyOnce
  constructor
  · intro hBoundary input hInput
    rcases hBoundary input hInput with ⟨hMem, _⟩ | hProduced
    · exact absurd hMem (by simp)
    · exact hProduced
  · intro hClosed input hInput
    exact Or.inr (hClosed input hInput)

end ActualizedPortGraph

/-! ## Boundary Port-Use Witnesses -/

/-- `BoundaryPortUseWitness` is `PortUseWitness` generalized on the input side.
The total `inputProducer` of `PortUseWitness` is replaced by a total `inputUse`
that may classify an input as a `boundarySource` instead of an internal `edge`.
The four well-formedness obligations fire only on the edge case, establishing a
bijection between edge outputs and internally produced inputs; boundary inputs
carry no obligation beyond being declared. -/
structure BoundaryPortUseWitness
    (node outputPort inputPort terminal boundarySource : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort]
    [DecidableEq terminal] where
  /-- Actualized output port instances known to the graph. -/
  outputs : Finset (ActualizedPortInstance node outputPort)
  /-- Actualized input port instances known to the graph. -/
  inputs : Finset (ActualizedPortInstance node inputPort)
  /-- Exactly one use chosen for each output port instance. -/
  outputUse :
    ActualizedPortInstance node outputPort →
      OutputPortUse (ActualizedPortInstance node inputPort) terminal
  /-- Exactly one producer-or-boundary chosen for each input port instance. -/
  inputUse :
    ActualizedPortInstance node inputPort →
      InputPortUse (ActualizedPortInstance node outputPort) boundarySource
  /-- An internally produced input's declared producer is an actualized output. -/
  inputEdge_mem :
    ∀ input,
      input ∈ inputs →
        ∀ output,
          inputUse input = InputPortUse.edge output → output ∈ outputs
  /-- An internally produced input's declared producer has an edge use to it. -/
  inputEdge_use :
    ∀ input,
      input ∈ inputs →
        ∀ output,
          inputUse input = InputPortUse.edge output →
            outputUse output = OutputPortUse.edge input
  /-- Every edge consumer is an actualized input port instance. -/
  edgeInput_mem :
    ∀ output,
      output ∈ outputs →
        ∀ input,
          outputUse output = OutputPortUse.edge input → input ∈ inputs
  /-- Every edge consumer's input is internally produced by exactly this output. -/
  edgeInput_use :
    ∀ output,
      output ∈ outputs →
        ∀ input,
          outputUse output = OutputPortUse.edge input →
            inputUse input = InputPortUse.edge output

namespace BoundaryPortUseWitness

variable {node outputPort inputPort terminal boundarySource : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]
variable [DecidableEq terminal]

/-- Convert a boundary port-use witness into the relation-shaped graph model.
The output fields are identical to `PortUseWitness.toGraph`; boundary inputs are
modelled by an empty producer set. -/
def toBoundaryGraph
    (witness : BoundaryPortUseWitness node outputPort inputPort terminal boundarySource) :
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
      match witness.inputUse input with
      | InputPortUse.edge output => {output}
      | InputPortUse.boundarySource _source => ∅
    else
      ∅

/-- Inputs supplied by a boundary source rather than an internal producer. -/
def boundaryInputs
    (witness : BoundaryPortUseWitness node outputPort inputPort terminal boundarySource) :
    Finset (ActualizedPortInstance node inputPort) :=
  witness.inputs.filter (fun input => (witness.inputUse input).isBoundary = true)

/-- A witnessed output is consumed by exactly one edge or terminal discharge.
The output side is unchanged from the closed witness. -/
theorem toBoundaryGraph_outputConsumedExactlyOnce
    (witness : BoundaryPortUseWitness node outputPort inputPort terminal boundarySource)
    {output : ActualizedPortInstance node outputPort}
    (hOutput : output ∈ witness.outputs) :
    witness.toBoundaryGraph.OutputConsumedExactlyOnce output := by
  cases hUse : witness.outputUse output with
  | edge input =>
      left
      refine ⟨input, ?_, ?_, ?_⟩
      · exact witness.edgeInput_mem output hOutput input hUse
      · simp only [toBoundaryGraph, hOutput, hUse, ↓reduceDIte]
      · simp only [toBoundaryGraph, hOutput, hUse, ↓reduceDIte]
  | terminalDischarge terminal =>
      right
      refine ⟨terminal, ?_, ?_⟩
      · simp only [toBoundaryGraph, hOutput, hUse, ↓reduceDIte]
      · simp only [toBoundaryGraph, hOutput, hUse, ↓reduceDIte]

/-- A witnessed input is boundary-sourced or produced internally exactly once. -/
theorem toBoundaryGraph_boundaryInputSourcedExactlyOnce
    (witness : BoundaryPortUseWitness node outputPort inputPort terminal boundarySource)
    {input : ActualizedPortInstance node inputPort}
    (hInput : input ∈ witness.inputs) :
    witness.toBoundaryGraph.BoundaryInputSourcedExactlyOnce witness.boundaryInputs input := by
  cases hUse : witness.inputUse input with
  | edge output =>
      right
      refine ⟨output, ?_, ?_, ?_⟩
      · exact witness.inputEdge_mem input hInput output hUse
      · simp only [toBoundaryGraph, hInput, hUse, ↓reduceDIte]
      · have hOutputMem : output ∈ witness.outputs :=
          witness.inputEdge_mem input hInput output hUse
        have hOutputUse : witness.outputUse output = OutputPortUse.edge input :=
          witness.inputEdge_use input hInput output hUse
        simp only [toBoundaryGraph, hOutputMem, hOutputUse, ↓reduceDIte]
  | boundarySource source =>
      left
      refine ⟨?_, ?_⟩
      · rw [boundaryInputs, Finset.mem_filter]
        exact ⟨hInput, by simp only [hUse, InputPortUse.isBoundary]⟩
      · simp only [toBoundaryGraph, hInput, hUse, ↓reduceDIte]

/-- A supplied boundary port-use witness establishes boundary linearity for its
own graph domain, with its declared boundary inputs left open. -/
theorem boundaryPortUseWitness_toBoundaryGraph_boundaryPortLinear
    (witness : BoundaryPortUseWitness node outputPort inputPort terminal boundarySource) :
    witness.toBoundaryGraph.BoundaryPortLinear witness.boundaryInputs := by
  constructor
  · intro output hOutput
    have hMem : output ∈ witness.outputs := by
      simpa only [toBoundaryGraph] using hOutput
    exact witness.toBoundaryGraph_outputConsumedExactlyOnce hMem
  · intro input hInput
    have hMem : input ∈ witness.inputs := by
      simpa only [toBoundaryGraph] using hInput
    exact witness.toBoundaryGraph_boundaryInputSourcedExactlyOnce hMem

/-! ## Closed Witnesses Are Boundary Witnesses -/

/-- Every closed `PortUseWitness` is a boundary witness with no open inputs:
each input uses its internal producing edge, and there is no boundary source. -/
def ofPortUseWitness
    (witness : PortUseWitness node outputPort inputPort terminal) :
    BoundaryPortUseWitness node outputPort inputPort terminal PEmpty where
  outputs := witness.outputs
  inputs := witness.inputs
  outputUse := witness.outputUse
  inputUse := fun input => InputPortUse.edge (witness.inputProducer input)
  inputEdge_mem := by
    intro input hInput output hUse
    simp only [InputPortUse.edge.injEq] at hUse
    subst hUse
    exact witness.inputProducer_mem input hInput
  inputEdge_use := by
    intro input hInput output hUse
    simp only [InputPortUse.edge.injEq] at hUse
    subst hUse
    exact witness.inputProducer_edge input hInput
  edgeInput_mem := witness.edgeInput_mem
  edgeInput_use := by
    intro output hOutput input hUse
    have hEq : witness.inputProducer input = output :=
      witness.edgeInput_producer_eq output hOutput input hUse
    simp only [hEq]

/-- The boundary graph of an embedded closed witness is its closed graph. -/
theorem ofPortUseWitness_toBoundaryGraph
    (witness : PortUseWitness node outputPort inputPort terminal) :
    (ofPortUseWitness witness).toBoundaryGraph = witness.toGraph := by
  rfl

/-- An embedded closed witness declares no boundary inputs. -/
theorem ofPortUseWitness_boundaryInputs_empty
    (witness : PortUseWitness node outputPort inputPort terminal) :
    (ofPortUseWitness witness).boundaryInputs = ∅ := by
  rw [boundaryInputs, Finset.filter_eq_empty_iff]
  intro input _hInput
  simp only [ofPortUseWitness, InputPortUse.isBoundary, Bool.false_eq_true, not_false_eq_true]

/-- `ClosedPortLinear` is the empty-boundary corollary: the closed theorem
`portUseWitness_toGraph_closedPortLinear` is recovered through the boundary
soundness theorem and the empty-boundary collapse. -/
theorem portUseWitness_closedPortLinear_via_boundary
    (witness : PortUseWitness node outputPort inputPort terminal) :
    witness.toGraph.ClosedPortLinear := by
  have hBoundary :
      (ofPortUseWitness witness).toBoundaryGraph.BoundaryPortLinear
        (ofPortUseWitness witness).boundaryInputs :=
    boundaryPortUseWitness_toBoundaryGraph_boundaryPortLinear (ofPortUseWitness witness)
  rw [ofPortUseWitness_toBoundaryGraph, ofPortUseWitness_boundaryInputs_empty] at hBoundary
  exact
    (ActualizedPortGraph.boundaryPortLinear_empty_iff_closedPortLinear witness.toGraph).mp
      hBoundary

end BoundaryPortUseWitness

end Cortex.Wire
