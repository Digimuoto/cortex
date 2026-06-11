import Cortex.Wire.AdmissionArtifact.Differential.Chain
import Cortex.Wire.AdmissionArtifact.Differential.Make
import Cortex.Wire.AdmissionArtifact.Differential.MakeEach
import Cortex.Wire.AdmissionArtifact.Differential.RecordScatter
import Cortex.Wire.AdmissionArtifact.Differential.IndexedGather
import Cortex.Wire.AdmissionArtifact.Differential.IndexedScatter
import Cortex.Wire.AdmissionArtifact.Differential.SelectLabel
import Cortex.Wire.AdmissionArtifact.Differential.SelectContract

/-!
## Overview

Umbrella for the generated differential-oracle modules: per fixture, the
executable admission kernel replays the compiler's composition and must
land on the same exposed boundary the artifact records. Regenerate with
`just wire-lean-fixtures`; the Haskell test suite fails on drift.
-/
