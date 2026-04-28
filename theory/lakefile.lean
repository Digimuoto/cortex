import Lake

/-!
## Overview

Lake configuration for the Cortex Lean theory package.

## Context

The package pins the proof dependencies and names the library roots that
repo-docs and Nix should build. Treat changes here as proof-surface
changes because they alter which modules are checked and rendered.
-/

open Lake DSL

package «cortex-theory» where
  -- Lean 4 mechanization of the Cortex substrate.
  -- See ./README.md for the proof-track roadmap.

require mathlib from git
  "https://github.com/leanprover-community/mathlib4.git" @ "v4.29.0"

@[default_target]
lean_lib «Cortex» where
  -- Reachable from `import Cortex`. Submodules are pulled in by Cortex.lean
  -- and the per-track root files (Cortex/Graph.lean, Cortex/Pulse.lean, …).
  roots := #[
    `Cortex,
    `Cortex.Graph.Core,
    `Cortex.Graph.Relation,
    `Cortex.Graph.Laws,
    `Cortex.Pulse.DAG,
    `Cortex.Pulse.State,
    `Cortex.Pulse.Fact,
    `Cortex.Pulse.Frontier,
    `Cortex.Pulse.Closure,
    `Cortex.Pulse.Validity,
    `Cortex.Pulse.Recovery,
    `Cortex.Pulse.Classify,
    `Cortex.Wire.Registry,
    `Cortex.Wire.Rewrite,
    `Cortex.Wire.Admission,
    `Cortex.Wire.Planner
  ]

-- Smoke-test executable. Prints a build banner; useful for confirming
-- the Lake project compiles end-to-end without diving into the proof tree.
lean_exe «cortex-theory» where
  root := `Main
