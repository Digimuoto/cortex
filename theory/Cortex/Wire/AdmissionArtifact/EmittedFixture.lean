import Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck

/-!
## Overview

Concrete decoded admission artifact emitted by the Haskell Wire compiler,
checked by the Lean-owned executable validator.

The value below is the artifact the Haskell compiler attaches to the compiled
circuit for the `CompileSpec` labeled-chain fixture (`planner => analyst`),
hand-transcribed field-for-field from the emitted metadata. `#guard` then runs
`validatorReadyCheck` on it. This was the first emitted-artifact fixture and
remains as the original hand-transcribed instance of the route.

## Context

The transcription route this file pioneered is now automated:
`Cortex.Wire.LeanFixture` renders compiler-emitted artifacts as the generated
modules under `Cortex.Wire.AdmissionArtifact.Emitted`, the build checks them
at every `lean-check`, and the Haskell test suite fails on drift between the
checked-in modules and current compiler output (`just wire-lean-fixtures`
regenerates). This file keeps the manual original alongside the generated set.
The checker and its soundness theorems are shared by both routes:
`validatorReadyCheck_soundness` turns this build-time check into
`WireAdmissionArtifact.Sound` for this artifact.
-/

namespace Cortex.Wire
namespace AdmissionArtifact
namespace EmittedFixture

open Cortex.Wire.ElaborationIR

/-! ## Labeled Chain Artifact

Source fixture (`simpleChainSourceText` in `test/Cortex/Wire/CompileSpec.hs`):
a `planner` node with one labeled output connected to an `analyst` node with
one labeled input and one labeled output, `planner => analyst`.
-/

/-- Planner output port row serialized by the chain artifact. -/
def plannerPlanExit : AdmissionBoundaryPort where
  node := ⟨"planner"⟩
  port := ⟨"plan"⟩
  contract := ⟨"PlannerOutput"⟩
  label := .label ⟨"plan"⟩
  exclusiveGroup := none

/-- Analyst input port row consumed by the chain connect step. -/
def analystPlanEntry : AdmissionBoundaryPort where
  node := ⟨"analyst"⟩
  port := ⟨"plan"⟩
  contract := ⟨"PlannerOutput"⟩
  label := .label ⟨"plan"⟩
  exclusiveGroup := none

/-- Analyst output port row exposed as the final summary exit. -/
def analystAnalysisExit : AdmissionBoundaryPort where
  node := ⟨"analyst"⟩
  port := ⟨"analysis"⟩
  contract := ⟨"AnalysisFragment"⟩
  label := .label ⟨"analysis"⟩
  exclusiveGroup := none

/-- The single matched boundary pair recorded by the connect step. -/
def chainMatchedPair : AdmissionConnection where
  fromPort := plannerPlanExit
  toPort := analystPlanEntry

/-- The raw summary connection projected from the matched pair. -/
def chainRawConnection : AdmissionRawConnection where
  fromEndpoint := { node := ⟨"planner"⟩, port := some ⟨"plan"⟩ }
  toEndpoint := { node := ⟨"analyst"⟩, port := some ⟨"plan"⟩ }

/-- The full admission artifact the Haskell compiler emits for the chain. -/
def chainArtifact : WireAdmissionArtifact where
  schemaVersion := 4
  closureMode := .closedExecutable
  nodes := [⟨"analyst"⟩, ⟨"planner"⟩]
  bindingRefs := []
  entries := []
  exits := [analystAnalysisExit]
  connections := [chainRawConnection]
  primitiveSteps :=
    [ .node ⟨"planner"⟩ [] [plannerPlanExit]
    , .node ⟨"analyst"⟩ [analystPlanEntry] [analystAnalysisExit]
    , .connect [plannerPlanExit] [analystPlanEntry] [chainMatchedPair] [] []
    ]
  generatedForms := []
  phantomAdapters := []
  selects := []
  endpointUses :=
    { inputUses :=
        [ { port := analystPlanEntry
          , useKind := .producedByEdge plannerPlanExit
          }
        ]
    , outputUses :=
        [ { port := plannerPlanExit
          , useKind := .consumedByEdge analystPlanEntry
          }
        , { port := analystAnalysisExit
          , useKind := .terminalDischarge .hostReturn
          }
        ]
    }

-- The Lean-owned executable validator accepts the emitted chain artifact.
#guard chainArtifact.validatorReadyCheck

/-- The accepted artifact satisfies the proof-facing soundness contract. -/
theorem chainArtifact_sound : chainArtifact.Sound :=
  WireAdmissionArtifact.validatorReadyCheck_soundness (by native_decide)

end EmittedFixture
end AdmissionArtifact
end Cortex.Wire
