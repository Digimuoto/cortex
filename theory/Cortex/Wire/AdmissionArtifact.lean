import Cortex.Wire.AdmissionArtifact.Check
import Cortex.Wire.AdmissionArtifact.GeneratedReconstruction
import Cortex.Wire.AdmissionArtifact.PhantomReconstruction
import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction
import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck
import Cortex.Wire.AdmissionArtifact.SelectReconstruction
import Cortex.Wire.AdmissionArtifact.Sound
import Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck

/-!
## Overview

Umbrella module for the decoded Wire admission artifact proof surface.

The implementation is split into rendered subpages under
`Cortex.Wire.AdmissionArtifact.*`: checker helpers, boundary rows, primitive
traces, static values, generated forms, phantom adapters, select rows, and the
top-level validator-ready and proof-facing soundness contracts. The primitive
trace and full validator-ready contract now have Lean-owned executable checkers
with soundness theorems, and the primitive replay contract reconstructs an
artifact-level graph witness with explicit frontier-key accounting. Generated
artifact rows reconstruct source item provenance and primitive-backed child
frontier evidence, and phantom rows reconstruct primitive-backed adapter-node
and bulk-replay evidence without yet claiming full `PhantomAdapterWitness`
construction. Select rows reconstruct projected latent admissions, arm
provenance, resolution, condition-bridge, and body-domain evidence without yet
claiming durable selected-branch replay. Importing this module preserves the
public import path for downstream theory code.
-/
