import Cortex.Wire.AdmissionArtifact.ValidatorCore

/-!
## Overview

Executable primitive-trace replay checks for decoded Wire admission artifacts.

`PrimitiveTraceStackValid` is currently relational: it says there exists a
final primitive replay frame produced by the serialized postorder trace and
that the frame matches the artifact summary. This module adds the first
Lean-owned executable checker for that relation. The checker is not yet the
full artifact validator; it is a sound executable core for one validator field.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

namespace WireAdmissionArtifact

/-- Boolean form of `SelectInternalTraceExit`. -/
def selectInternalTraceExitCheck
    (artifact : WireAdmissionArtifact)
    (exit : AdmissionBoundaryPort) :
    Bool :=
  artifact.selects.any fun selectAdmission =>
    SelectInternalChoiceExit selectAdmission exit

/-- The boolean hidden-exit classifier is exact for the relational classifier. -/
theorem selectInternalTraceExitCheck_eq_true_iff
    {artifact : WireAdmissionArtifact}
    {exit : AdmissionBoundaryPort} :
    artifact.selectInternalTraceExitCheck exit = true ↔
      artifact.SelectInternalTraceExit exit := by
  unfold selectInternalTraceExitCheck SelectInternalTraceExit
  constructor
  · intro hCheck
    rcases List.any_eq_true.mp hCheck with ⟨selectAdmission, hSelect, hChoice⟩
    exact ⟨selectAdmission, hSelect, hChoice⟩
  · rintro ⟨selectAdmission, hSelect, hChoice⟩
    exact List.any_eq_true.mpr ⟨selectAdmission, hSelect, hChoice⟩

/-- Source-visible primitive node exits after erasing select-internal bridge exits. -/
def visiblePrimitiveExits
    (artifact : WireAdmissionArtifact)
    (exits : List AdmissionBoundaryPort) :
    List AdmissionBoundaryPort :=
  exits.filter fun exit => !(artifact.selectInternalTraceExitCheck exit)

/-- The executable visible-exit filter matches the primitive replay relation. -/
theorem mem_visiblePrimitiveExits_iff
    {artifact : WireAdmissionArtifact}
    {exits : List AdmissionBoundaryPort}
    {exit : AdmissionBoundaryPort} :
    exit ∈ artifact.visiblePrimitiveExits exits ↔
      exit ∈ exits ∧ ¬ artifact.SelectInternalTraceExit exit := by
  unfold visiblePrimitiveExits
  rw [List.mem_filter]
  constructor
  · intro hMem
    refine ⟨hMem.left, ?_⟩
    intro hHidden
    have hCheck : artifact.selectInternalTraceExitCheck exit = true :=
      selectInternalTraceExitCheck_eq_true_iff.mpr hHidden
    rw [hCheck] at hMem
    simp at hMem
  · intro hMem
    refine ⟨hMem.left, ?_⟩
    cases hCheck : artifact.selectInternalTraceExitCheck exit with
    | false =>
        rfl
    | true =>
        have hHidden : artifact.SelectInternalTraceExit exit :=
          selectInternalTraceExitCheck_eq_true_iff.mp hCheck
        exact False.elim (hMem.right hHidden)

/-- Execute one primitive trace replay step, rejecting stack-shape or ledger mismatches. -/
def primitiveTraceStepCheck
    (artifact : WireAdmissionArtifact)
    (stack : List PrimitiveTraceFrame) :
    PrimitiveGraphStep → Option (List PrimitiveTraceFrame)
  | PrimitiveGraphStep.empty =>
      some (PrimitiveTraceFrame.empty :: stack)
  | PrimitiveGraphStep.node node entries exits =>
      some
        (PrimitiveTraceFrame.nodeFrame
          node entries (artifact.visiblePrimitiveExits exits) :: stack)
  | PrimitiveGraphStep.bindingRef binding =>
      match stack with
      | frame :: rest =>
          some ({ frame with bindingRefs := binding :: frame.bindingRefs } :: rest)
      | [] =>
          none
  | PrimitiveGraphStep.overlay leftNodes rightNodes leftBindings rightBindings =>
      match stack with
      | right :: left :: rest =>
          if _hLeftNodes : leftNodes.Perm left.nodes then
            if _hRightNodes : rightNodes.Perm right.nodes then
              if _hLeftBindings : leftBindings.Perm left.bindingRefs then
                if _hRightBindings : rightBindings.Perm right.bindingRefs then
                  some (PrimitiveTraceFrame.overlay left right :: rest)
                else
                  none
              else
                none
            else
              none
          else
            none
      | [] =>
          none
      | _only :: [] =>
          none
  | PrimitiveGraphStep.connect
      leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      match stack with
      | right :: left :: rest =>
          if _hLeftExits : leftExits.Perm left.exits then
            if _hRightEntries : rightEntries.Perm right.entries then
              if _hUnmatchedLeft :
                  ((matchedPairs.map (fun pair => pair.fromPort)) ++
                      unmatchedLeftExits).Perm left.exits then
                if _hUnmatchedRight :
                    ((matchedPairs.map (fun pair => pair.toPort)) ++
                        unmatchedRightEntries).Perm right.entries then
                  some
                    (PrimitiveTraceFrame.connect
                      left right matchedPairs unmatchedLeftExits unmatchedRightEntries ::
                        rest)
                else
                  none
              else
                none
            else
              none
          else
            none
      | [] =>
          none
      | _only :: [] =>
          none

/-- Successful executable primitive-step replay is accepted by the relational replay step. -/
theorem primitiveTraceStepCheck_sound
    {artifact : WireAdmissionArtifact}
    {stack next : List PrimitiveTraceFrame}
    {step : PrimitiveGraphStep}
    (hCheck : artifact.primitiveTraceStepCheck stack step = some next) :
    PrimitiveTraceStep artifact.SelectInternalTraceExit stack step next := by
  cases step with
  | empty =>
      unfold primitiveTraceStepCheck at hCheck
      cases hCheck
      exact PrimitiveTraceStep.empty stack
  | node node entries exits =>
      unfold primitiveTraceStepCheck at hCheck
      cases hCheck
      exact
        PrimitiveTraceStep.node
          stack node entries exits (artifact.visiblePrimitiveExits exits)
          (fun exit => mem_visiblePrimitiveExits_iff)
  | bindingRef binding =>
      unfold primitiveTraceStepCheck at hCheck
      cases stack with
      | nil =>
          simp at hCheck
      | cons frame rest =>
          cases hCheck
          exact PrimitiveTraceStep.bindingRef binding frame rest
  | overlay leftNodes rightNodes leftBindings rightBindings =>
      cases stack with
      | nil =>
          simp [primitiveTraceStepCheck] at hCheck
      | cons right tail =>
          cases tail with
          | nil =>
              simp [primitiveTraceStepCheck] at hCheck
          | cons left rest =>
              by_cases hLeftNodes : leftNodes.Perm left.nodes
              · by_cases hRightNodes : rightNodes.Perm right.nodes
                · by_cases hLeftBindings : leftBindings.Perm left.bindingRefs
                  · by_cases hRightBindings : rightBindings.Perm right.bindingRefs
                    · simp [primitiveTraceStepCheck, hLeftNodes, hRightNodes,
                        hLeftBindings, hRightBindings] at hCheck
                      cases hCheck
                      exact
                        PrimitiveTraceStep.overlay
                          hLeftNodes hRightNodes hLeftBindings hRightBindings
                    · simp [primitiveTraceStepCheck, hLeftNodes, hRightNodes,
                        hLeftBindings, hRightBindings] at hCheck
                  · simp [primitiveTraceStepCheck, hLeftNodes, hRightNodes,
                      hLeftBindings] at hCheck
                · simp [primitiveTraceStepCheck, hLeftNodes, hRightNodes] at hCheck
              · simp [primitiveTraceStepCheck, hLeftNodes] at hCheck
  | connect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries =>
      cases stack with
      | nil =>
          simp [primitiveTraceStepCheck] at hCheck
      | cons right tail =>
          cases tail with
          | nil =>
              simp [primitiveTraceStepCheck] at hCheck
          | cons left rest =>
              by_cases hLeftExits : leftExits.Perm left.exits
              · by_cases hRightEntries : rightEntries.Perm right.entries
                · by_cases hUnmatchedLeft :
                    ((matchedPairs.map (fun pair => pair.fromPort)) ++
                        unmatchedLeftExits).Perm left.exits
                  · by_cases hUnmatchedRight :
                      ((matchedPairs.map (fun pair => pair.toPort)) ++
                          unmatchedRightEntries).Perm right.entries
                    · simp [primitiveTraceStepCheck, hLeftExits, hRightEntries,
                        hUnmatchedLeft, hUnmatchedRight] at hCheck
                      cases hCheck
                      exact
                        PrimitiveTraceStep.connect
                          hLeftExits hRightEntries hUnmatchedLeft hUnmatchedRight
                    · simp [primitiveTraceStepCheck, hLeftExits, hRightEntries,
                        hUnmatchedLeft, hUnmatchedRight] at hCheck
                  · simp [primitiveTraceStepCheck, hLeftExits, hRightEntries,
                      hUnmatchedLeft] at hCheck
                · simp [primitiveTraceStepCheck, hLeftExits, hRightEntries] at hCheck
              · simp [primitiveTraceStepCheck, hLeftExits] at hCheck

/-- Execute the primitive trace stack from a starting stack. -/
def primitiveTraceReplayCheck
    (artifact : WireAdmissionArtifact) :
    List PrimitiveGraphStep →
      List PrimitiveTraceFrame →
        Option (List PrimitiveTraceFrame)
  | [], stack =>
      some stack
  | step :: rest, stack =>
      match artifact.primitiveTraceStepCheck stack step with
      | none =>
          none
      | some next =>
          artifact.primitiveTraceReplayCheck rest next

/-- Successful executable primitive-trace replay is accepted by the relational replay. -/
theorem primitiveTraceReplayCheck_sound
    {artifact : WireAdmissionArtifact}
    {steps : List PrimitiveGraphStep}
    {stack finalStack : List PrimitiveTraceFrame}
    (hCheck :
      artifact.primitiveTraceReplayCheck steps stack = some finalStack) :
    PrimitiveTraceReplays artifact.SelectInternalTraceExit steps stack finalStack := by
  induction steps generalizing stack with
  | nil =>
      unfold primitiveTraceReplayCheck at hCheck
      cases hCheck
      exact PrimitiveTraceReplays.nil _
  | cons step rest ih =>
      unfold primitiveTraceReplayCheck at hCheck
      cases hStep : artifact.primitiveTraceStepCheck stack step with
      | none =>
          rw [hStep] at hCheck
          simp at hCheck
      | some next =>
          rw [hStep] at hCheck
          exact
            PrimitiveTraceReplays.cons
              (primitiveTraceStepCheck_sound hStep)
              (ih hCheck)

instance primitiveTraceFrameMatchesSummaryDecidable
    (frame : PrimitiveTraceFrame)
    (artifact : WireAdmissionArtifact) :
    Decidable (frame.MatchesSummary artifact) := by
  unfold PrimitiveTraceFrame.MatchesSummary
  infer_instance

/-- Execute primitive replay and require exactly one final frame matching the artifact summary. -/
def primitiveTraceStackValidCheck
    (artifact : WireAdmissionArtifact) :
    Bool :=
  match artifact.primitiveTraceReplayCheck artifact.primitiveSteps [] with
  | some [finalFrame] =>
      decide (finalFrame.MatchesSummary artifact)
  | some [] =>
      false
  | some (_first :: _second :: _rest) =>
      false
  | none =>
      false

/-- The executable primitive-stack checker is sound for `PrimitiveTraceStackValid`. -/
theorem primitiveTraceStackValidCheck_sound
    {artifact : WireAdmissionArtifact}
    (hCheck : artifact.primitiveTraceStackValidCheck = true) :
    artifact.PrimitiveTraceStackValid := by
  unfold primitiveTraceStackValidCheck at hCheck
  cases hReplay :
      artifact.primitiveTraceReplayCheck artifact.primitiveSteps [] with
  | none =>
      rw [hReplay] at hCheck
      simp at hCheck
  | some stack =>
      rw [hReplay] at hCheck
      cases stack with
      | nil =>
          simp at hCheck
      | cons finalFrame rest =>
          cases rest with
          | nil =>
              have hMatch : finalFrame.MatchesSummary artifact :=
                of_decide_eq_true hCheck
              exact
                ⟨ finalFrame
                , primitiveTraceReplayCheck_sound hReplay
                , hMatch
                ⟩
          | cons next tail =>
              simp at hCheck

end WireAdmissionArtifact

end AdmissionArtifact
end Cortex.Wire
