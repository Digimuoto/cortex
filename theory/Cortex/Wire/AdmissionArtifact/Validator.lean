import Cortex.Wire.AdmissionArtifact.ReadyGenerated
import Cortex.Wire.AdmissionArtifact.ReadyPhantom
import Cortex.Wire.AdmissionArtifact.ReadySelect

/-!
## Overview

Umbrella module for top-level decoded Wire admission artifacts and validator-ready accessors.

The validator surface is split into `ValidatorCore`, primitive/summary accessors, and generated,
phantom, and select ready-row theorem pages. Importing this module preserves the public validator
module path while keeping each rendered Theory page reviewable.
-/
