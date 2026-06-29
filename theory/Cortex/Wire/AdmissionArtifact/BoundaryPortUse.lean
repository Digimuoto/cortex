import Cortex.Wire.BoundaryPortLinearity
import Cortex.Wire.AdmissionArtifact.Boundary

/-!
## Overview

Boundary port-use bridge from the schema-v4 admission endpoint-use witness to the
proof-side `BoundaryPortUseWitness`.

`Cortex.Wire.AdmissionArtifact.Boundary` defines the persisted endpoint-use
witness (`AdmissionEndpointUseWitness`): one row per primitive input/output
boundary port, classifying each input as `producedByEdge | hostInput |
importedObligation` and each output as `consumedByEdge | terminalDischarge`.
`Cortex.Wire.BoundaryPortLinearity` defines the abstract `BoundaryPortUseWitness`
and proves it induces a `BoundaryPortLinear` actualized graph, with
`ClosedPortLinear` as the empty-boundary corollary.

This module projects the persisted witness onto actualized port instances and
defines `EndpointUseLinear`, a decidable predicate asserting the edge matching is
internally consistent: every internal input edge has a symmetric output edge in
the domain, and dually. `EndpointUseLinear` is exactly the four
`BoundaryPortUseWitness` well-formedness obligations stated over the projected
total use functions, so a passing witness constructs `artifactBoundaryWitness`
and lands in `BoundaryPortLinear` for free. For a fully internal graph (no host
inputs and no imported obligations, so no boundary inputs) the corollary
`artifactBoundaryWitness_closedPortLinear` recovers `ClosedPortLinear`.

The projection mirrors the actualized port identities used by the source-to-
actualized bridge (`projectSourceOutput`/`projectSourceInput`): node identity and
the `(label, contract)` port signature are preserved literally, with output and
input directions kept type-distinct.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-- Proof-side boundary-input kind: the operational reason an input is supplied
externally rather than by an internal edge. The `BoundaryPortLinear` property
ignores this payload; it is retained for fidelity to ADR 0081. -/
inductive InputBoundaryKind where
  | hostInput
  | importedObligation
  deriving DecidableEq, Repr

namespace AdmissionBoundaryPort

/-- Output-direction actualized port instance projected from a boundary row. -/
def actualizedOutputInstance
    (boundary : AdmissionBoundaryPort) :
    ActualizedPortInstance NodeId OutputPortSignature :=
  { node := boundary.node
    port := { signature := { label := boundary.port, contract := boundary.contract } } }

/-- Input-direction actualized port instance projected from a boundary row. -/
def actualizedInputInstance
    (boundary : AdmissionBoundaryPort) :
    ActualizedPortInstance NodeId InputPortSignature :=
  { node := boundary.node
    port := { signature := { label := boundary.port, contract := boundary.contract } } }

end AdmissionBoundaryPort

/-- Project a persisted input use kind onto a proof-side `InputPortUse`. -/
def inputUseKindToPortUse :
    AdmissionInputUseKind →
      InputPortUse (ActualizedPortInstance NodeId OutputPortSignature) InputBoundaryKind
  | .producedByEdge fromPort =>
      InputPortUse.edge fromPort.actualizedOutputInstance
  | .hostInput => InputPortUse.boundarySource InputBoundaryKind.hostInput
  | .importedObligation =>
      InputPortUse.boundarySource InputBoundaryKind.importedObligation

/-- Project a persisted output use kind onto a proof-side `OutputPortUse`. -/
def outputUseKindToPortUse :
    AdmissionOutputUseKind →
      OutputPortUse (ActualizedPortInstance NodeId InputPortSignature)
        AdmissionTerminalDischargeKind
  | .consumedByEdge toPort => OutputPortUse.edge toPort.actualizedInputInstance
  | .terminalDischarge kind => OutputPortUse.terminalDischarge kind

namespace AdmissionEndpointUseWitness

/-- Actualized output port instances declared by the endpoint-use witness. -/
def outputInstances
    (witness : AdmissionEndpointUseWitness) :
    Finset (ActualizedPortInstance NodeId OutputPortSignature) :=
  (witness.outputUses.map (fun row => row.port.actualizedOutputInstance)).toFinset

/-- Actualized input port instances declared by the endpoint-use witness. -/
def inputInstances
    (witness : AdmissionEndpointUseWitness) :
    Finset (ActualizedPortInstance NodeId InputPortSignature) :=
  (witness.inputUses.map (fun row => row.port.actualizedInputInstance)).toFinset

/-- Total output-use function: look up the row whose port projects to this
instance, projecting its use kind; the out-of-domain default is irrelevant
because the well-formedness obligations only quantify over `outputInstances`. -/
def outputUseOf
    (witness : AdmissionEndpointUseWitness)
    (inst : ActualizedPortInstance NodeId OutputPortSignature) :
    OutputPortUse (ActualizedPortInstance NodeId InputPortSignature)
      AdmissionTerminalDischargeKind :=
  match witness.outputUses.find? (fun row => decide (row.port.actualizedOutputInstance = inst)) with
  | some row => outputUseKindToPortUse row.useKind
  | none => OutputPortUse.terminalDischarge AdmissionTerminalDischargeKind.proofBoundarySink

/-- Total input-use function, dual to `outputUseOf`. -/
def inputUseOf
    (witness : AdmissionEndpointUseWitness)
    (inst : ActualizedPortInstance NodeId InputPortSignature) :
    InputPortUse (ActualizedPortInstance NodeId OutputPortSignature) InputBoundaryKind :=
  match witness.inputUses.find? (fun row => decide (row.port.actualizedInputInstance = inst)) with
  | some row => inputUseKindToPortUse row.useKind
  | none => InputPortUse.boundarySource InputBoundaryKind.importedObligation

/-- An internal input edge points to a declared output that edges back to it. -/
def InputEdgeConsistent
    (witness : AdmissionEndpointUseWitness)
    (input : ActualizedPortInstance NodeId InputPortSignature) : Prop :=
  match witness.inputUseOf input with
  | .edge output =>
      output ∈ witness.outputInstances ∧
        witness.outputUseOf output = OutputPortUse.edge input
  | .boundarySource _ => True

/-- An output edge points to a declared input that edges back to it. -/
def OutputEdgeConsistent
    (witness : AdmissionEndpointUseWitness)
    (output : ActualizedPortInstance NodeId OutputPortSignature) : Prop :=
  match witness.outputUseOf output with
  | .edge input =>
      input ∈ witness.inputInstances ∧
        witness.inputUseOf input = InputPortUse.edge output
  | .terminalDischarge _ => True

instance instDecidableInputEdgeConsistent
    (witness : AdmissionEndpointUseWitness)
    (input : ActualizedPortInstance NodeId InputPortSignature) :
    Decidable (witness.InputEdgeConsistent input) := by
  unfold InputEdgeConsistent
  split <;> infer_instance

instance instDecidableOutputEdgeConsistent
    (witness : AdmissionEndpointUseWitness)
    (output : ActualizedPortInstance NodeId OutputPortSignature) :
    Decidable (witness.OutputEdgeConsistent output) := by
  unfold OutputEdgeConsistent
  split <;> infer_instance

/-- `EndpointUseLinear` is the decidable boundary-port-linearity admission rule:
the edge matching declared by the endpoint-use witness is internally consistent
on both directions over its own declared port domain. -/
def EndpointUseLinear (witness : AdmissionEndpointUseWitness) : Prop :=
  (∀ input ∈ witness.inputInstances, witness.InputEdgeConsistent input) ∧
    (∀ output ∈ witness.outputInstances, witness.OutputEdgeConsistent output)

instance instDecidableEndpointUseLinear
    (witness : AdmissionEndpointUseWitness) :
    Decidable witness.EndpointUseLinear := by
  unfold EndpointUseLinear
  infer_instance

/-! ## Bridge -/

/-- The proof-side boundary witness induced by a linearity-consistent endpoint-use
witness. The four obligations are exactly `EndpointUseLinear`. -/
def artifactBoundaryWitness
    (witness : AdmissionEndpointUseWitness)
    (hLinear : witness.EndpointUseLinear) :
    BoundaryPortUseWitness NodeId OutputPortSignature InputPortSignature
      AdmissionTerminalDischargeKind InputBoundaryKind where
  outputs := witness.outputInstances
  inputs := witness.inputInstances
  outputUse := witness.outputUseOf
  inputUse := witness.inputUseOf
  inputEdge_mem := by
    intro input hInput output hUse
    have hc : witness.InputEdgeConsistent input := hLinear.1 input hInput
    simp only [InputEdgeConsistent, hUse] at hc
    exact hc.1
  inputEdge_use := by
    intro input hInput output hUse
    have hc : witness.InputEdgeConsistent input := hLinear.1 input hInput
    simp only [InputEdgeConsistent, hUse] at hc
    exact hc.2
  edgeInput_mem := by
    intro output hOutput input hUse
    have hc : witness.OutputEdgeConsistent output := hLinear.2 output hOutput
    simp only [OutputEdgeConsistent, hUse] at hc
    exact hc.1
  edgeInput_use := by
    intro output hOutput input hUse
    have hc : witness.OutputEdgeConsistent output := hLinear.2 output hOutput
    simp only [OutputEdgeConsistent, hUse] at hc
    exact hc.2

/-- The induced graph of a linearity-consistent endpoint-use witness is boundary
port linear, with the host/imported inputs as its declared boundary. -/
theorem artifactBoundaryWitness_boundaryPortLinear
    (witness : AdmissionEndpointUseWitness)
    (hLinear : witness.EndpointUseLinear) :
    (witness.artifactBoundaryWitness hLinear).toBoundaryGraph.BoundaryPortLinear
      (witness.artifactBoundaryWitness hLinear).boundaryInputs :=
  BoundaryPortUseWitness.boundaryPortUseWitness_toBoundaryGraph_boundaryPortLinear _

/-- A fully internal endpoint-use witness — no boundary inputs — is closed port
linear. This is the artifact-level image of the internally-closed corollary. -/
theorem artifactBoundaryWitness_closedPortLinear
    (witness : AdmissionEndpointUseWitness)
    (hLinear : witness.EndpointUseLinear)
    (hInternal : (witness.artifactBoundaryWitness hLinear).boundaryInputs = ∅) :
    (witness.artifactBoundaryWitness hLinear).toBoundaryGraph.ClosedPortLinear := by
  have hBoundary := artifactBoundaryWitness_boundaryPortLinear witness hLinear
  rw [hInternal] at hBoundary
  exact
    (ActualizedPortGraph.boundaryPortLinear_empty_iff_closedPortLinear _).mp hBoundary

end AdmissionEndpointUseWitness

end AdmissionArtifact
end Cortex.Wire
