import Cortex.Wire.PortLinearity

/-!
## Overview

Structural reclaim boundary for ephemeral Wire execution.

## Context

The source linear port graph gives Wire a syntactic lifetime boundary. A frontier is finished when
it exposes no remaining input or output endpoints. Under `PortLinear`, that means every owned output
has exactly one internal consumer edge, and every owned input has exactly one internal producer
edge. No future implicit fan-out, fan-in, or hidden reader can be attached through that frontier.

This module states that fact as an in-memory reclaim theorem. It is intentionally about ephemeral
execution resources. Durable profiles may still retain settled nodes, materialized outputs,
checkpoints, and provenance records as a separate observability feature.
-/

namespace Cortex.Wire
namespace LinearPortGraph

variable {node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

/-! ## Finished Frontiers -/

/-- A source frontier is finished when no input or output endpoint remains exposed. -/
def FrontierFinished
    (graph : LinearPortGraph node outputPort inputPort) : Prop :=
  graph.exposedOutputs = ∅ ∧ graph.exposedInputs = ∅

/-- An output endpoint is reclaimable when it has left the frontier and has one consumer edge. -/
def OutputReclaimable
    (graph : LinearPortGraph node outputPort inputPort)
    (output : SourcePortInstance node outputPort) : Prop :=
  output ∈ graph.outputs ∧
    output ∉ graph.exposedOutputs ∧
      ∃ input,
        input ∈ graph.inputs ∧
          graph.portEdges.filter (fun edge => edge.1 = output) = {(output, input)}

/-- An input endpoint is reclaimable when it has left the frontier and has one producer edge. -/
def InputReclaimable
    (graph : LinearPortGraph node outputPort inputPort)
    (input : SourcePortInstance node inputPort) : Prop :=
  input ∈ graph.inputs ∧
    input ∉ graph.exposedInputs ∧
      ∃ output,
        output ∈ graph.outputs ∧
          graph.portEdges.filter (fun edge => edge.2 = input) = {(output, input)}

/-- There are no remaining output-side frontier consumer obligations. -/
def NoRemainingConsumerObligations
    (graph : LinearPortGraph node outputPort inputPort) : Prop :=
  ∀ output,
    output ∈ graph.outputs →
      graph.OutputReclaimable output

/-- There are no remaining input-side frontier producer obligations. -/
def NoRemainingProducerObligations
    (graph : LinearPortGraph node outputPort inputPort) : Prop :=
  ∀ input,
    input ∈ graph.inputs →
      graph.InputReclaimable input

/-- All source endpoints in a finished frontier are structurally reclaimable.

This is a source-proof predicate: it says no frontier obligations remain. It does not by itself
prove that a runtime implementation released memory; that is a separate correspondence
obligation. -/
def EphemeralResourcesReclaimable
    (graph : LinearPortGraph node outputPort inputPort) : Prop :=
  graph.NoRemainingConsumerObligations ∧ graph.NoRemainingProducerObligations

/-! ## Reclaim Theorems -/

/-- A finished linear frontier leaves no output-side consumer obligations open. -/
theorem frontierFinished_noRemainingConsumerObligations
    (graph : LinearPortGraph node outputPort inputPort)
    (hLinear : graph.PortLinear)
    (hFinished : graph.FrontierFinished) :
    graph.NoRemainingConsumerObligations := by
  intro output hOutput
  have hNotExposed : output ∉ graph.exposedOutputs := by
    rw [hFinished.left]
    simp
  rcases hLinear.left output hOutput with hOpen | hConsumed
  · exact False.elim (hNotExposed hOpen.1)
  · rcases hConsumed with ⟨hClosed, input, hInput, hEdges⟩
    exact ⟨hOutput, hClosed, input, hInput, hEdges⟩

/-- A finished linear frontier leaves no input-side producer obligations open. -/
theorem frontierFinished_noRemainingProducerObligations
    (graph : LinearPortGraph node outputPort inputPort)
    (hLinear : graph.PortLinear)
    (hFinished : graph.FrontierFinished) :
    graph.NoRemainingProducerObligations := by
  intro input hInput
  have hNotExposed : input ∉ graph.exposedInputs := by
    rw [hFinished.right]
    simp
  rcases hLinear.right input hInput with hOpen | hProduced
  · exact False.elim (hNotExposed hOpen.1)
  · rcases hProduced with ⟨hClosed, output, hOutput, hEdges⟩
    exact ⟨hInput, hClosed, output, hOutput, hEdges⟩

/-- Finished linear frontiers are structurally reclaimable for ephemeral in-memory execution. -/
theorem frontierFinished_reclaimable
    (graph : LinearPortGraph node outputPort inputPort)
    (hLinear : graph.PortLinear)
    (hFinished : graph.FrontierFinished) :
    graph.EphemeralResourcesReclaimable :=
  ⟨ frontierFinished_noRemainingConsumerObligations graph hLinear hFinished
  , frontierFinished_noRemainingProducerObligations graph hLinear hFinished
  ⟩

end LinearPortGraph
end Cortex.Wire
