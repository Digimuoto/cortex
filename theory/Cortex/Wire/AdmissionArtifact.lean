import Cortex.Wire.AdmissionArtifact.Check
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
trace and a representative validator-ready core now have Lean-owned executable
checkers with soundness theorems. Importing this module preserves the public
import path for downstream theory code.
-/
