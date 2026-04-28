import Cortex

/-!
## Overview

This executable is the Lean smoke entry point. It imports `Cortex` so
`lake build` exercises the whole proof tree before producing a small
diagnostic binary.

## Context

The executable is not the proof artifact. The proof value is that every
definition and theorem exposed through `import Cortex` type-checks under
the pinned Lean, Lake, mathlib, and Nix setup.

## Theorem Split

There are no local theorems on this page. The printed lines summarize the
proof tracks imported by the root module.
-/

def main : IO Unit := do
  IO.println "Cortex theory — Lean 4 mechanization (scaffold)"
  IO.println "  Track 1 (Graph algebra) ......... import Cortex.Graph.Core / Laws"
  IO.println "  Track 2 (Pulse kernel) .......... import Cortex.Pulse.Classify"
  IO.println "  Track 3 (Wire rewrite) .......... import Cortex.Wire.Admission"
  IO.println ""
  IO.println "Open obligations: see `theory/README.md`."
