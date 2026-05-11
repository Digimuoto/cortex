-- Track 1 — Graph algebra (Mokhov)
import Cortex.Graph.Core
import Cortex.Graph.Relation
import Cortex.Graph.Laws
import Cortex.Graph.Quotient
import Cortex.Graph.Safety

-- Track 2 — Pulse runtime, fixed-topology kernel
import Cortex.Pulse.DAG
import Cortex.Pulse.State
import Cortex.Pulse.Fact
import Cortex.Pulse.Frontier
import Cortex.Pulse.Closure
import Cortex.Pulse.Validity
import Cortex.Pulse.Recovery
import Cortex.Pulse.Classify
import Cortex.Pulse.RunSafety

-- Track 3 — Wire rewrite soundness
import Cortex.Wire.Pure
import Cortex.Wire.Registry
import Cortex.Wire.Rewrite
import Cortex.Wire.Admission
import Cortex.Wire.Planner
import Cortex.Wire.Planner.Construction
import Cortex.Wire.Planner.Chain
import Cortex.Wire.Select
import Cortex.Wire.BoundaryResource
import Cortex.Wire.NodeBoundary
import Cortex.Wire.PortLinearity
import Cortex.Wire.ActualizedBridge
import Cortex.Wire.ElaborationIR
import Cortex.Wire.GraphElaboration
import Cortex.Wire.Make
import Cortex.Wire.PhantomAdapter
import Cortex.Wire.GeneratedForms
import Cortex.Wire.AdmissionArtifact
import Cortex.Wire.AdmissionArtifact.Check
import Cortex.Wire.AdmissionArtifact.Boundary
import Cortex.Wire.AdmissionArtifact.Generated
import Cortex.Wire.AdmissionArtifact.Phantom
import Cortex.Wire.AdmissionArtifact.Primitive
import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction
import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck
import Cortex.Wire.AdmissionArtifact.ReadyGeneral
import Cortex.Wire.AdmissionArtifact.ReadyGenerated
import Cortex.Wire.AdmissionArtifact.ReadyPhantom
import Cortex.Wire.AdmissionArtifact.ReadyPhantomBridge
import Cortex.Wire.AdmissionArtifact.ReadyPrimitive
import Cortex.Wire.AdmissionArtifact.ReadyPrimitiveRows
import Cortex.Wire.AdmissionArtifact.ReadySelect
import Cortex.Wire.AdmissionArtifact.ReadySelectBridge
import Cortex.Wire.AdmissionArtifact.ReadySummary
import Cortex.Wire.AdmissionArtifact.Select
import Cortex.Wire.AdmissionArtifact.Sound
import Cortex.Wire.AdmissionArtifact.StaticValue
import Cortex.Wire.AdmissionArtifact.Validator
import Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck
import Cortex.Wire.AdmissionArtifact.ValidatorCore
import Cortex.Wire.FrontierReclaim
import Cortex.Wire.PulseSafety
import Cortex.Wire.SelectRecovery
import Cortex.Wire.SelectAdmission
import Cortex.Wire.RunTrace

/-!
## Overview

This is the root mechanization module. Pulling `import Cortex` into a
downstream file exposes the full proof surface: graph algebra, the
fixed-topology Pulse kernel, and Wire rewrite obligations.

## Context

The page is intentionally short. Its purpose is publication and build
wiring: repo-docs can render the whole theory tree from here, and Lake can
check that every proof track remains importable together.

## Theorem Split

The imported tracks are the theorem split: `Cortex.Graph.*` for algebra,
`Cortex.Pulse.*` for fixed-topology runtime safety, and
`Cortex.Wire.*` for pure-node, registry-boundary, and rewrite admission.
-/
