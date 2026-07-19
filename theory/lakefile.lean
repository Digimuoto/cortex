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
    `Cortex.Wire.NativePure.Type,
    `Cortex.Wire.SemanticC,
    `Cortex.Wire.C11,
    `Cortex.Wire.StaticCEmitter,
    `Cortex.Wire.StaticCEmitter.Layout,
    `Cortex.Wire.StaticCEmitter.Unit,
    `Cortex.Wire.NativePure,
    `Cortex.Wire.NativePure.C,
    `Cortex.Wire.NativePure.C.Unit,
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
    `Cortex.Wire.BoundaryPortLinearity,
    `Cortex.Wire.ElaborationIR,
    `Cortex.Wire.ElaborationIRDecide,
    `Cortex.Wire.GraphElaboration,
    `Cortex.Wire.GraphElaborationExec,
    `Cortex.Wire.ContractValidation,
    `Cortex.Wire.ContractValidationCheck,
    `Cortex.Wire.ContractValidation.Emitted,
    `Cortex.Wire.ContractValidation.Emitted.BoundsVacuity,
    `Cortex.Wire.ContractValidation.Emitted.ItemsVacuity,
    `Cortex.Wire.ContractValidation.Emitted.AdditionalTrue,
    `Cortex.Wire.ContractValidation.Emitted.RequiredVacuity,
    `Cortex.Wire.ContractValidation.Emitted.SubsetAccept,
    `Cortex.Wire.ContractValidation.Emitted.RequiredNested,
    `Cortex.Wire.ContractValidation.Emitted.AdditionalProperties,
    `Cortex.Wire.ContractValidation.Emitted.EnumMismatch,
    `Cortex.Wire.ContractValidation.Emitted.ItemsElement,
    `Cortex.Wire.ContractValidation.Emitted.StringBounds,
    `Cortex.Wire.ContractValidation.Emitted.NumberBounds,
    `Cortex.Wire.ContractValidation.Emitted.IntegerScalar,
    `Cortex.Wire.ContractValidation.Emitted.TypeUnion,
    `Cortex.Wire.ContractValidation.Emitted.EmptyEnum,
    `Cortex.Wire.ContractValidation.Emitted.EmptyTypes,
    `Cortex.Wire.ContractValidation.Json,
    `Cortex.Wire.FrontierTyping,
    `Cortex.Wire.Make,
    `Cortex.Wire.PhantomAdapter,
    `Cortex.Wire.GeneratedForms,
    `Cortex.Wire.GeneratedFormsDeterminism,
    `Cortex.Wire.AdmissionArtifact,
    `Cortex.Wire.AdmissionArtifact.Check,
    `Cortex.Wire.AdmissionArtifact.Boundary,
    `Cortex.Wire.AdmissionArtifact.BoundaryPortUse,
    `Cortex.Wire.AdmissionArtifact.EmittedFixture,
    `Cortex.Wire.AdmissionArtifact.Emitted,
    `Cortex.Wire.AdmissionArtifact.Differential,
    `Cortex.Wire.AdmissionArtifact.Differential.Chain,
    `Cortex.Wire.AdmissionArtifact.Differential.IndexedGather,
    `Cortex.Wire.AdmissionArtifact.Differential.IndexedScatter,
    `Cortex.Wire.AdmissionArtifact.Differential.Make,
    `Cortex.Wire.AdmissionArtifact.Differential.MakeEach,
    `Cortex.Wire.AdmissionArtifact.Differential.RecordScatter,
    `Cortex.Wire.AdmissionArtifact.Differential.SelectLabel,
    `Cortex.Wire.AdmissionArtifact.Differential.SelectContract,
    `Cortex.Wire.AdmissionArtifact.Emitted.Chain,
    `Cortex.Wire.AdmissionArtifact.Emitted.IndexedGather,
    `Cortex.Wire.AdmissionArtifact.Emitted.IndexedScatter,
    `Cortex.Wire.AdmissionArtifact.Emitted.Make,
    `Cortex.Wire.AdmissionArtifact.Emitted.MakeEach,
    `Cortex.Wire.AdmissionArtifact.Emitted.RecordScatter,
    `Cortex.Wire.AdmissionArtifact.Emitted.SelectContract,
    `Cortex.Wire.AdmissionArtifact.Emitted.SelectLabel,
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
    `Cortex.Wire.AdmissionArtifact.SelectReconstruction,
    `Cortex.Wire.AdmissionArtifact.Sound,
    `Cortex.Wire.AdmissionArtifact.StaticValue,
    `Cortex.Wire.AdmissionArtifact.Validator,
    `Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck,
    `Cortex.Wire.AdmissionArtifact.ValidatorCore,
    `Cortex.Wire.FrontierReclaim,
    `Cortex.Wire.PulseSafety,
    `Cortex.Wire.SelectRecovery,
    `Cortex.Wire.SelectAdmission,
    `Cortex.Wire.AdditiveFragment,
    `Cortex.Wire.RunTrace,
    `Cortex.Wire.StaticC
  ]

-- Smoke-test executable. Prints a build banner; useful for confirming
-- the Lake project compiles end-to-end without diving into the proof tree.
lean_exe «cortex-theory» where
  root := `Main

-- Extraction spike for the host-neutral fixed-topology Cortex kernel.
-- Keeping this target separate from the whole-theory smoke executable makes
-- its generated C and native linkage surface directly inspectable.
lean_exe «cortex-kernel-spike» where
  root := `CortexKernelSpike

-- Host-side static Wire validator and freestanding C emitter (ADR 0091).
lean_exe «cortex-wire-c» where
  root := `CortexWireC

-- Concrete NativePure C artifact writer used by differential and target gates.
lean_exe «cortex-native-pure-c-fixture» where
  root := `CortexNativePureCFixture

-- Lean reference interpreter for the ADR 0091 three-way differential suite.
-- Replays the shared scenario corpus through the restricted target semantics
-- and emits canonical trace lines for comparison against the generated C and
-- the Haskell GraphRuntime driver. Core Lean only, like `cortex-wire-c`.
lean_exe «cortex-wire-diff» where
  root := `CortexWireDiff
