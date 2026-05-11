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
    `Cortex.Graph.Quotient,
    `Cortex.Graph.Safety,
    `Cortex.Pulse.DAG,
    `Cortex.Pulse.State,
    `Cortex.Pulse.Fact,
    `Cortex.Pulse.Frontier,
    `Cortex.Pulse.Closure,
    `Cortex.Pulse.Validity,
    `Cortex.Pulse.Recovery,
    `Cortex.Pulse.Classify,
    `Cortex.Pulse.RunSafety,
    `Cortex.Wire.Pure,
    `Cortex.Wire.Registry,
    `Cortex.Wire.Rewrite,
    `Cortex.Wire.Admission,
    `Cortex.Wire.Planner,
    `Cortex.Wire.Planner.Construction,
    `Cortex.Wire.Planner.Chain,
    `Cortex.Wire.Select,
    `Cortex.Wire.BoundaryResource,
    `Cortex.Wire.NodeBoundary,
    `Cortex.Wire.PortLinearity,
    `Cortex.Wire.ActualizedBridge,
    `Cortex.Wire.ElaborationIR,
    `Cortex.Wire.GraphElaboration,
    `Cortex.Wire.Make,
    `Cortex.Wire.PhantomAdapter,
    `Cortex.Wire.GeneratedForms,
    `Cortex.Wire.AdmissionArtifact,
    `Cortex.Wire.AdmissionArtifact.Check,
    `Cortex.Wire.AdmissionArtifact.Boundary,
    `Cortex.Wire.AdmissionArtifact.Generated,
    `Cortex.Wire.AdmissionArtifact.GeneratedReconstruction,
    `Cortex.Wire.AdmissionArtifact.Phantom,
    `Cortex.Wire.AdmissionArtifact.PhantomReconstruction,
    `Cortex.Wire.AdmissionArtifact.Primitive,
    `Cortex.Wire.AdmissionArtifact.PrimitiveReconstruction,
    `Cortex.Wire.AdmissionArtifact.PrimitiveTraceCheck,
    `Cortex.Wire.AdmissionArtifact.ReadyGeneral,
    `Cortex.Wire.AdmissionArtifact.ReadyGenerated,
    `Cortex.Wire.AdmissionArtifact.ReadyPhantom,
    `Cortex.Wire.AdmissionArtifact.ReadyPhantomBridge,
    `Cortex.Wire.AdmissionArtifact.ReadyPrimitive,
    `Cortex.Wire.AdmissionArtifact.ReadyPrimitiveRows,
    `Cortex.Wire.AdmissionArtifact.ReadySelect,
    `Cortex.Wire.AdmissionArtifact.ReadySelectBridge,
    `Cortex.Wire.AdmissionArtifact.ReadySummary,
    `Cortex.Wire.AdmissionArtifact.Select,
    `Cortex.Wire.AdmissionArtifact.Sound,
    `Cortex.Wire.AdmissionArtifact.StaticValue,
    `Cortex.Wire.AdmissionArtifact.Validator,
    `Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck,
    `Cortex.Wire.AdmissionArtifact.ValidatorCore,
    `Cortex.Wire.FrontierReclaim,
    `Cortex.Wire.PulseSafety,
    `Cortex.Wire.SelectRecovery,
    `Cortex.Wire.SelectAdmission,
    `Cortex.Wire.RunTrace
  ]

-- Smoke-test executable. Prints a build banner; useful for confirming
-- the Lake project compiles end-to-end without diving into the proof tree.
lean_exe «cortex-theory» where
  root := `Main
