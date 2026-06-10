import Cortex.Wire.AdmissionArtifact.Emitted.Chain
import Cortex.Wire.AdmissionArtifact.Emitted.Make
import Cortex.Wire.AdmissionArtifact.Emitted.MakeEach
import Cortex.Wire.AdmissionArtifact.Emitted.RecordScatter
import Cortex.Wire.AdmissionArtifact.Emitted.IndexedGather
import Cortex.Wire.AdmissionArtifact.Emitted.IndexedScatter
import Cortex.Wire.AdmissionArtifact.Emitted.SelectLabel
import Cortex.Wire.AdmissionArtifact.Emitted.SelectContract

/-!
## Overview

Umbrella for the generated emitted-artifact fixtures. Each import is a
Lean module generated from a compiled Wire fixture by
`Cortex.Wire.LeanFixture`; regenerate with `just wire-lean-fixtures`.
The Haskell test suite fails when any generated module drifts from the
current compiler output.
-/
