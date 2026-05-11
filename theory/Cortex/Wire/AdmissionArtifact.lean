import Cortex.Wire.AdmissionArtifact.Check
import Cortex.Wire.AdmissionArtifact.GeneratedReconstruction
import Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction
import Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck
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
artifact rows also reconstruct source item provenance and primitive-backed child
frontier evidence. Importing this module preserves the public import path for
downstream theory code.
-/
