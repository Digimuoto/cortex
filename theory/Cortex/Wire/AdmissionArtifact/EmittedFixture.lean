import Cortex.Wire.AdmissionArtifact.ValidatorCoreCheck

/-!
## Overview

Concrete decoded admission artifact emitted by the Haskell Wire compiler,
checked by the Lean-owned executable validator.

The value below is the artifact the Haskell compiler attaches to the compiled
circuit for the `CompileSpec` labeled-chain fixture (`planner => analyst`),
hand-transcribed field-for-field from the emitted metadata. `#guard` then runs
`validatorReadyCheck` on it. This is the first hand-transcribed
emitted-artifact fixture, not an end-to-end validation: no Lean code consumes
actual Haskell output until a generator or decoder replaces the manual
transcription.

## Context

This is the fixture-transcription integration route for running the Lean
checker on emitted artifacts: Haskell (or, for this first instance, a person
reading the emitted metadata) renders the decoded artifact as a Lean value and
the build evaluates the checker. The transcription step is trusted; replacing
it with a generator inside the Haskell test suite, or with a JSON decoder on
the Lean side, are the alternative integration shapes under issue #201. The
checker itself and its soundness theorems are unchanged either way:
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
  schemaVersion := 3
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

-- The Lean-owned executable validator accepts the emitted chain artifact.
#guard chainArtifact.validatorReadyCheck

/-- The accepted artifact satisfies the proof-facing soundness contract. -/
theorem chainArtifact_sound : chainArtifact.Sound :=
  WireAdmissionArtifact.validatorReadyCheck_soundness (by native_decide)

end EmittedFixture
end AdmissionArtifact
end Cortex.Wire
