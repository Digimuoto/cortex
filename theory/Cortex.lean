/-
# Cortex — root mechanization module

Imports every proof track. Pulling `import Cortex` into a downstream file
exposes the full surface (Graph algebra, Pulse frontier, Wire rewrites).
-/

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

-- Track 3 — Wire rewrite soundness
import Cortex.Wire.Rewrite
