-- Track 1 — Graph algebra (Mokhov)
import Cortex.Graph.Core
import Cortex.Graph.Relation
import Cortex.Graph.Laws

-- Track 2 — Pulse runtime, fixed-topology kernel
import Cortex.Pulse.DAG
import Cortex.Pulse.State
import Cortex.Pulse.Fact
import Cortex.Pulse.Frontier
import Cortex.Pulse.Closure
import Cortex.Pulse.Validity
import Cortex.Pulse.Recovery
import Cortex.Pulse.Classify

-- Track 3 — Wire rewrite soundness
import Cortex.Wire.Registry
import Cortex.Wire.Rewrite

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
`Cortex.Wire.*` for registry-boundary and rewrite admission.
-/
