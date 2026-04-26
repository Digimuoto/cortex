/-
# Cortex — root mechanization module

Imports every proof track. Pulling `import Cortex` into a downstream file
exposes the full surface (Graph algebra, Pulse frontier, Wire rewrites).
-/

-- Track 1 — Graph algebra (Mokhov)
import Cortex.Graph.Core
import Cortex.Graph.Laws

-- Track 2 — Pulse runtime, frontier safety
import Cortex.Pulse.Frontier

-- Track 3 — Wire rewrite soundness
import Cortex.Wire.Rewrite
