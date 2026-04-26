/-
# Cortex theory — smoke entry point

Imports every track's root module so that `lake build` exercises the
whole proof tree. The executable just prints a banner; the value is in
`#check`-able definitions and theorems compiling.
-/

import Cortex

def main : IO Unit := do
  IO.println "Cortex theory — Lean 4 mechanization (scaffold)"
  IO.println "  Track 1 (Graph algebra) ......... import Cortex.Graph.Core / Laws"
  IO.println "  Track 2 (Frontier safety) ....... import Cortex.Pulse.Frontier"
  IO.println "  Track 3 (Rewrite soundness) ..... import Cortex.Wire.Rewrite"
  IO.println ""
  IO.println "Open obligations: see `theory/README.md`."
