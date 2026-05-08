import Cortex.Wire.PortLinearity

/-!
## Overview

Source-to-actualized **projection exactness** bridge for compiled port-use
witnesses. The theorems here pin source ↔ actualized port-set and edge bijection;
they do not bridge the witness to a Haskell-compiled runtime artifact, so
they are not yet "executable correspondence."

## Context

`Cortex.Wire.PortLinearity` defines two complementary carriers. The source
side uses `LinearPortObject` over `SourcePortInstance`; the closed actualized
side uses `ActualizedPortGraph` over `ActualizedPortInstance`, plus the
`PortUseWitness` shape that compiler or admission must eventually produce.
`portUseWitness_toGraph_closedPortLinear` already proves *sufficiency*: a
supplied witness establishes closed port linearity on its declared domain.

What it does not prove is *projection exactness*: the witness's actualized
output and input port sets correspond bijectively to the source object's
port instances, so a runtime cannot smuggle in actualized ports the source
carrier never admitted, and its actualized edge consumers coincide with the
source object's port edges. This file closes that gap as a deterministic
structural projection. **Runtime-witness production, terminal-discharge
correspondence, and the bridge to compiled Haskell artifacts remain open**.

## Theorem Split

The page defines:

* `projectSourceOutput` and `projectSourceInput`, the canonical injections
  from source to actualized port instances;
* `SourceToActualizedProjection`, the deterministic projection of a source
  `LinearPortObject` onto an `ActualizedPortGraph` skeleton;
* recovered port-node-domain, output, input, and edge correspondence equalities
  exposed as theorems (`portNodeDomain_eq`, `projection_outputs_image_eq`,
  etc.);
* `PortUseWitness.AlignedWith`, the predicate that the witness's actualized
  graph coincides with the projection of a certified source object on domains
  and edge consumers;
* `compiledPortUseWitness_exact_forward`, the load-bearing forward direction
  showing every actualized port of an aligned witness comes from a source
  port instance;
* `compiledPortUseWitness_exact_reverse`, the symmetric reverse direction
  showing every source port instance is represented in the witness;
* `compiledPortUseWitness_exact`, the iff combining both directions for one
  uniform exactness statement.

The projection is intentionally restricted to the case where the source-side
output, input, and actualized-side output, input port label alphabets agree.
That is enough to rule out the "runtime port not in source" failure mode for
the compiler-emitted witness; richer projections that re-label ports remain
out of scope for this slice.
-/

namespace Cortex.Wire

open LinearPortGraph

/-! ## Source-to-actualized port projection -/

section Projection

variable
  {node outputPort inputPort terminal : Type}
  [DecidableEq node]
  [DecidableEq outputPort]
  [DecidableEq inputPort]
  [DecidableEq terminal]

/-- `projectSourceOutput sp` is the canonical actualized image of a source output port instance.

The map preserves node identity and port label literally, so every source-side
declared output port becomes a distinct actualized port instance. -/
def projectSourceOutput
    (sp : SourcePortInstance node outputPort) :
    ActualizedPortInstance node outputPort :=
  { node := sp.node
    port := sp.port }

/-- `projectSourceInput sp` is the canonical actualized image of a source input port instance.

The map preserves node identity and port label literally, so every source-side
declared input port becomes a distinct actualized port instance. -/
def projectSourceInput
    (sp : SourcePortInstance node inputPort) :
    ActualizedPortInstance node inputPort :=
  { node := sp.node
    port := sp.port }

omit [DecidableEq node] [DecidableEq outputPort] [DecidableEq inputPort] [DecidableEq terminal] in
/-- `projectSourceOutput` is injective. -/
theorem projectSourceOutput_injective :
    Function.Injective (projectSourceOutput (node := node) (outputPort := outputPort)) := by
  intro left right hEq
  have hNode : left.node = right.node := congrArg ActualizedPortInstance.node hEq
  have hPort : left.port = right.port := congrArg ActualizedPortInstance.port hEq
  cases left
  cases right
  cases hNode
  cases hPort
  rfl

omit [DecidableEq node] [DecidableEq outputPort] [DecidableEq inputPort] [DecidableEq terminal] in
/-- `projectSourceInput` is injective. -/
theorem projectSourceInput_injective :
    Function.Injective (projectSourceInput (node := node) (inputPort := inputPort)) := by
  intro left right hEq
  have hNode : left.node = right.node := congrArg ActualizedPortInstance.node hEq
  have hPort : left.port = right.port := congrArg ActualizedPortInstance.port hEq
  cases left
  cases right
  cases hNode
  cases hPort
  rfl

end Projection

/-! ## Deterministic projection of source linear objects -/

section SourceProjection

variable
  {node outputPort inputPort terminal : Type}
  [DecidableEq node]
  [DecidableEq outputPort]
  [DecidableEq inputPort]
  [DecidableEq terminal]

/-- `projectedActualizedGraph object` is the canonical `ActualizedPortGraph`
projection of a certified source linear object.

Outputs and inputs are the literal images of the source object's source port
instances under `projectSourceOutput` and `projectSourceInput`. Edge
consumers, terminal discharges, and input producers are derived from the
source `portEdges`: the consumer of a source-image output is the projected
input that the source edge targets; the producer of a source-image input is
the projected output that produces it. Source frontier endpoints map to
empty edge consumers, leaving terminal-discharge accounting to the caller's
witness layer. -/
def projectedActualizedGraph
    (object : LinearPortObject node outputPort inputPort) :
    ActualizedPortGraph node outputPort inputPort terminal where
  outputs := object.graph.outputs.image projectSourceOutput
  inputs := object.graph.inputs.image projectSourceInput
  edgeConsumers := fun output =>
    (object.graph.portEdges.filter (fun edge => projectSourceOutput edge.1 = output)).image
      (fun edge => projectSourceInput edge.2)
  terminalDischarges := fun _ => ∅
  inputProducers := fun input =>
    (object.graph.portEdges.filter (fun edge => projectSourceInput edge.2 = input)).image
      (fun edge => projectSourceOutput edge.1)

/-- `SourceToActualizedProjection object actualized` records the exact correspondence
between a source object and a candidate actualized port graph.

The bridge is a structure rather than a definitional equality so callers can
supply alternate but equivalent runtime materializations. The fields demand
extensional equality on every port-instance domain, plus on the edge
relation; the canonical witness is `SourceToActualizedProjection.canonical`. -/
structure SourceToActualizedProjection
    (object : LinearPortObject node outputPort inputPort)
    (actualized : ActualizedPortGraph node outputPort inputPort terminal) :
    Prop where
  /-- Actualized outputs are exactly the projected source outputs. -/
  outputs_eq : actualized.outputs = object.graph.outputs.image projectSourceOutput
  /-- Actualized inputs are exactly the projected source inputs. -/
  inputs_eq : actualized.inputs = object.graph.inputs.image projectSourceInput
  /-- An actualized edge runs between projected source endpoints iff the source carries it. -/
  edge_iff :
    ∀ output input,
      input ∈ actualized.edgeConsumers output ↔
        ∃ source,
          source ∈ object.graph.portEdges ∧
            projectSourceOutput source.1 = output ∧
              projectSourceInput source.2 = input

namespace SourceToActualizedProjection

variable
  {object : LinearPortObject node outputPort inputPort}
  {actualized : ActualizedPortGraph node outputPort inputPort terminal}

/-- Nodes that occur in an actualized port domain. `ActualizedPortGraph` has no
separate node set, so the domain is recovered from output and input instances. -/
def actualizedPortNodeDomain
    (graph : ActualizedPortGraph node outputPort inputPort terminal) :
    Finset node :=
  graph.outputs.image ActualizedPortInstance.node ∪
    graph.inputs.image ActualizedPortInstance.node

/-- Nodes that occur in a source object's port domain. This intentionally
ignores isolated source nodes with no port instances; those are not recoverable
from an actualized port-use graph. -/
def sourcePortNodeDomain
    (object : LinearPortObject node outputPort inputPort) :
    Finset node :=
  object.graph.outputs.image SourcePortInstance.node ∪
    object.graph.inputs.image SourcePortInstance.node

/-- The canonical projection always satisfies the bridge predicate. -/
theorem canonical
    (object : LinearPortObject node outputPort inputPort) :
    SourceToActualizedProjection
      (terminal := terminal)
      object
      (projectedActualizedGraph object) := by
  refine ⟨rfl, rfl, ?_⟩
  intro output input
  simp only [projectedActualizedGraph, Finset.mem_image, Finset.mem_filter]
  constructor
  · rintro ⟨edge, ⟨hEdge, hOutput⟩, hInput⟩
    exact ⟨edge, hEdge, hOutput, hInput⟩
  · rintro ⟨edge, hEdge, hOutput, hInput⟩
    exact ⟨edge, ⟨hEdge, hOutput⟩, hInput⟩

/-- The canonical projection has no terminal discharges.

This names the current source-side target for future runtime witness production:
terminal discharge correspondence is not part of `SourceToActualizedProjection`,
but the deterministic projection used by this file leaves every output
undischarged at the terminal layer. -/
theorem canonical_terminalDischarges_eq_empty
    (object : LinearPortObject node outputPort inputPort)
    (output : ActualizedPortInstance node outputPort) :
    (projectedActualizedGraph (terminal := terminal) object).terminalDischarges output = ∅ :=
  rfl

/-- The actualized port-node domain is exactly the source port-node domain. -/
theorem portNodeDomain_eq
    (hProj : SourceToActualizedProjection (terminal := terminal) object actualized) :
    actualizedPortNodeDomain actualized = sourcePortNodeDomain object := by
  ext portNode
  unfold actualizedPortNodeDomain sourcePortNodeDomain
  rw [hProj.outputs_eq, hProj.inputs_eq]
  simp only [Finset.mem_union, Finset.mem_image]
  constructor
  · rintro (⟨_, ⟨output, hOutput, rfl⟩, rfl⟩ | ⟨_, ⟨input, hInput, rfl⟩, rfl⟩)
    · exact Or.inl ⟨output, hOutput, rfl⟩
    · exact Or.inr ⟨input, hInput, rfl⟩
  · rintro (⟨output, hOutput, rfl⟩ | ⟨input, hInput, rfl⟩)
    · exact Or.inl ⟨projectSourceOutput output, ⟨output, hOutput, rfl⟩, rfl⟩
    · exact Or.inr ⟨projectSourceInput input, ⟨input, hInput, rfl⟩, rfl⟩

/-- Every source output appears as an actualized output. -/
theorem source_output_mem
    (hProj : SourceToActualizedProjection (terminal := terminal) object actualized)
    {sp : SourcePortInstance node outputPort}
    (hSource : sp ∈ object.graph.outputs) :
    projectSourceOutput sp ∈ actualized.outputs := by
  rw [hProj.outputs_eq]
  exact Finset.mem_image.mpr ⟨sp, hSource, rfl⟩

/-- Every source input appears as an actualized input. -/
theorem source_input_mem
    (hProj : SourceToActualizedProjection (terminal := terminal) object actualized)
    {sp : SourcePortInstance node inputPort}
    (hSource : sp ∈ object.graph.inputs) :
    projectSourceInput sp ∈ actualized.inputs := by
  rw [hProj.inputs_eq]
  exact Finset.mem_image.mpr ⟨sp, hSource, rfl⟩

/-- Every actualized output traces back to a unique source output. -/
theorem actualized_output_source
    (hProj : SourceToActualizedProjection (terminal := terminal) object actualized)
    {output : ActualizedPortInstance node outputPort}
    (hOutput : output ∈ actualized.outputs) :
    ∃ sp, sp ∈ object.graph.outputs ∧ projectSourceOutput sp = output := by
  have hImage : output ∈ object.graph.outputs.image projectSourceOutput := by
    rw [← hProj.outputs_eq]; exact hOutput
  exact Finset.mem_image.mp hImage

/-- Every actualized input traces back to a unique source input. -/
theorem actualized_input_source
    (hProj : SourceToActualizedProjection (terminal := terminal) object actualized)
    {input : ActualizedPortInstance node inputPort}
    (hInput : input ∈ actualized.inputs) :
    ∃ sp, sp ∈ object.graph.inputs ∧ projectSourceInput sp = input := by
  have hImage : input ∈ object.graph.inputs.image projectSourceInput := by
    rw [← hProj.inputs_eq]; exact hInput
  exact Finset.mem_image.mp hImage

end SourceToActualizedProjection

end SourceProjection

/-! ## Aligned port-use witnesses -/

section Alignment

variable
  {node outputPort inputPort terminal : Type}
  [DecidableEq node]
  [DecidableEq outputPort]
  [DecidableEq inputPort]
  [DecidableEq terminal]

/-- `PortUseWitness.AlignedWith witness object` says the witness's actualized graph
is exactly the projection of the source object on port domains and edge consumers.

This is the proof-side closure of the open exactness obligation called out in
`PortUseWitness`'s docstring. Once a compiler discharges the predicate, the
runtime cannot operate on actualized ports that the source side did not
declare, and cannot add or omit source port edges. Terminal-discharge
correspondence remains a later runtime-facing obligation. -/
def PortUseWitness.AlignedWith
    (witness : PortUseWitness node outputPort inputPort terminal)
    (object : LinearPortObject node outputPort inputPort) : Prop :=
  SourceToActualizedProjection object witness.toGraph

namespace PortUseWitness

/-- An aligned witness's outputs equal the canonical projection's outputs. -/
theorem alignedWith_outputs
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object) :
    witness.outputs = object.graph.outputs.image projectSourceOutput :=
  hAligned.outputs_eq

/-- An aligned witness's inputs equal the canonical projection's inputs. -/
theorem alignedWith_inputs
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object) :
    witness.inputs = object.graph.inputs.image projectSourceInput :=
  hAligned.inputs_eq

/-- An aligned witness's edge consumers are exactly the projected source edges. -/
theorem alignedWith_edge_iff
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    (output : ActualizedPortInstance node outputPort)
    (input : ActualizedPortInstance node inputPort) :
    input ∈ witness.toGraph.edgeConsumers output ↔
      ∃ source,
        source ∈ object.graph.portEdges ∧
          projectSourceOutput source.1 = output ∧
            projectSourceInput source.2 = input :=
  hAligned.edge_iff output input

/-- Aligned witnesses match the canonical projection's actualized domain extensionally. -/
theorem alignedWith_canonical
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object) :
    witness.outputs = (projectedActualizedGraph
        (terminal := terminal) object).outputs ∧
      witness.inputs = (projectedActualizedGraph
        (terminal := terminal) object).inputs := by
  refine ⟨?_, ?_⟩
  · simpa [projectedActualizedGraph, PortUseWitness.toGraph] using hAligned.outputs_eq
  · simpa [projectedActualizedGraph, PortUseWitness.toGraph] using hAligned.inputs_eq

end PortUseWitness

/-! ## Exactness corollary -/

/-- Forward direction of the exactness corollary.

Every actualized output port that an aligned witness operates on is the image of a
source-side declared output port. This is the load-bearing claim that prevents the
runtime from using actualized output ports the source admission carrier never
declared. -/
theorem compiledPortUseWitness_exact_output_forward
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    {output : ActualizedPortInstance node outputPort}
    (hOutput : output ∈ witness.outputs) :
    ∃ sp, sp ∈ object.graph.outputs ∧ projectSourceOutput sp = output := by
  have hImage : output ∈ object.graph.outputs.image projectSourceOutput := by
    rw [← hAligned.outputs_eq]
    simpa [PortUseWitness.toGraph] using hOutput
  exact Finset.mem_image.mp hImage

/-- Forward direction of the exactness corollary, input side.

Every actualized input port that an aligned witness operates on is the image of a
source-side declared input port. -/
theorem compiledPortUseWitness_exact_input_forward
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    {input : ActualizedPortInstance node inputPort}
    (hInput : input ∈ witness.inputs) :
    ∃ sp, sp ∈ object.graph.inputs ∧ projectSourceInput sp = input := by
  have hImage : input ∈ object.graph.inputs.image projectSourceInput := by
    rw [← hAligned.inputs_eq]
    simpa [PortUseWitness.toGraph] using hInput
  exact Finset.mem_image.mp hImage

/-- Reverse direction of the exactness corollary, output side.

Every source-side declared output port appears in the aligned witness's output
domain. This rules out the dual under-approximation failure mode where the
witness silently drops a source port. -/
theorem compiledPortUseWitness_exact_output_reverse
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    {sp : SourcePortInstance node outputPort}
    (hSource : sp ∈ object.graph.outputs) :
    projectSourceOutput sp ∈ witness.outputs := by
  have hProjected : projectSourceOutput sp ∈ witness.toGraph.outputs := by
    rw [hAligned.outputs_eq]
    exact Finset.mem_image.mpr ⟨sp, hSource, rfl⟩
  simpa [PortUseWitness.toGraph] using hProjected

/-- Reverse direction of the exactness corollary, input side. -/
theorem compiledPortUseWitness_exact_input_reverse
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    {sp : SourcePortInstance node inputPort}
    (hSource : sp ∈ object.graph.inputs) :
    projectSourceInput sp ∈ witness.inputs := by
  have hProjected : projectSourceInput sp ∈ witness.toGraph.inputs := by
    rw [hAligned.inputs_eq]
    exact Finset.mem_image.mpr ⟨sp, hSource, rfl⟩
  simpa [PortUseWitness.toGraph] using hProjected

/-- Combined exactness biconditional for output ports.

A port instance is in the aligned witness's output domain iff it is the image of a
source output port. -/
theorem compiledPortUseWitness_exact_output
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    (output : ActualizedPortInstance node outputPort) :
    output ∈ witness.outputs ↔
      ∃ sp, sp ∈ object.graph.outputs ∧ projectSourceOutput sp = output := by
  constructor
  · intro hOutput
    exact compiledPortUseWitness_exact_output_forward hAligned hOutput
  · rintro ⟨sp, hSource, hEq⟩
    rw [← hEq]
    exact compiledPortUseWitness_exact_output_reverse hAligned hSource

/-- Combined exactness biconditional for input ports. -/
theorem compiledPortUseWitness_exact_input
    {witness : PortUseWitness node outputPort inputPort terminal}
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object)
    (input : ActualizedPortInstance node inputPort) :
    input ∈ witness.inputs ↔
      ∃ sp, sp ∈ object.graph.inputs ∧ projectSourceInput sp = input := by
  constructor
  · intro hInput
    exact compiledPortUseWitness_exact_input_forward hAligned hInput
  · rintro ⟨sp, hSource, hEq⟩
    rw [← hEq]
    exact compiledPortUseWitness_exact_input_reverse hAligned hSource

/-- Named soundness package for an aligned actualized port-use witness.

The fields are the four obligations downstream consumers usually need:
closed port linearity, exact projected output/input domains, and exact projected
edge consumers. Keeping them named avoids positional tuple access in later
compiler-correctness proofs. -/
structure AlignedPortUseWitnessSoundness
    (witness : PortUseWitness node outputPort inputPort terminal)
    (object : LinearPortObject node outputPort inputPort) : Prop where
  /-- The actualized graph induced by the witness is closed-port linear. -/
  closedPortLinear : witness.toGraph.ClosedPortLinear
  /-- Every actualized output is exactly a projected source output, and conversely. -/
  outputsExact :
    ∀ output,
      output ∈ witness.outputs ↔
        ∃ sp, sp ∈ object.graph.outputs ∧ projectSourceOutput sp = output
  /-- Every actualized input is exactly a projected source input, and conversely. -/
  inputsExact :
    ∀ input,
      input ∈ witness.inputs ↔
        ∃ sp, sp ∈ object.graph.inputs ∧ projectSourceInput sp = input
  /-- Actualized edge consumers are exactly the projections of source port edges. -/
  edgeExact :
    ∀ output input,
      input ∈ witness.toGraph.edgeConsumers output ↔
        ∃ source,
          source ∈ object.graph.portEdges ∧
            projectSourceOutput source.1 = output ∧
              projectSourceInput source.2 = input

/-- Aligned witnesses establish closed port linearity and projection exactness
on the actualized graph.

This is the slice's named soundness corollary: an aligned witness simultaneously
discharges port linearity on its declared domain and the exactness obligation that
its declared output/input domains and edge consumers coincide with the source
carrier's projection.

Compiler witness production, terminal-discharge correspondence, and the bridge to
Haskell-compiled artifacts remain open. -/
theorem alignedPortUseWitness_closedPortLinear
    (witness : PortUseWitness node outputPort inputPort terminal)
    {object : LinearPortObject node outputPort inputPort}
    (hAligned : witness.AlignedWith object) :
    AlignedPortUseWitnessSoundness witness object where
  closedPortLinear := portUseWitness_toGraph_closedPortLinear witness
  outputsExact := fun output => compiledPortUseWitness_exact_output hAligned output
  inputsExact := fun input => compiledPortUseWitness_exact_input hAligned input
  edgeExact := fun output input => PortUseWitness.alignedWith_edge_iff hAligned output input

end Alignment

end Cortex.Wire
