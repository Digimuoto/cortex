import Cortex.Pulse.Classify
import Cortex.Pulse.Recovery

/-!
## Overview

Run safety is the reusable fixed-topology Pulse structural-validity
envelope. It does not introduce a second invariant: the accepted state
predicate remains `wellFormedGraphState`, and progress/liveness claims are
separate theorems. This page packages the existing recovery, frontier-fact,
classification, and permutation theorems into surfaces that later
Wire/Pulse integration proofs can consume directly.

## Context

The executable runtime alternates between graph-state recovery,
frontier-result accumulation, failure closure, and classification. Ordinary
frontier execution does not perform crash recovery after every wave; crash
recovery additionally resets volatile statuses before failure propagation.
The normalized frontier surface below intentionally composes fact folding
with `recoveredState` so preservation theorems can talk about the
post-recovery structural envelope.

Lean keeps external worker sparks abstract as `NodeResult`s. The replay
determinism theorem below only needs permutation of distinct-node fact
lists. Safety and frontier admissibility are carried by the preservation
theorems, not by the equality theorem itself.

## Theorem Split

The page defines `SafePulseRunState` as an abbreviation for the existing
well-formed predicate, names recovery and fact-fold-with-recovery
preservation, and lifts fact-fold permutation invariance through recovery
and classification.
-/

namespace Cortex.Pulse

variable {ν : Type u} {payload : Type v}

/-! ## Safe-State Surface -/

/-- `SafePulseRunState G state` is the published Pulse structural-safety predicate.

It is an abbreviation, not a new invariant: all obligations are still the
fields of `wellFormedGraphState`. It does not by itself assert progress;
non-stuck classification is supplied by separate theorems below.
-/
abbrev SafePulseRunState
    (G : DAG ν)
    (state : GraphState ν payload) : Prop :=
  wellFormedGraphState G state

/-- A safe run state supplies the persisted recovery preconditions. -/
theorem safePulseRunState_persistedRecoveryPreconditions
    (G : DAG ν)
    (state : GraphState ν payload)
    (hSafe : SafePulseRunState G state) :
    persistedRecoveryPreconditions G state :=
  { topologyDomain := hSafe.topologyDomain
    outputsRespectStatuses := hSafe.outputsRespectStatuses
    outputsCompleteForStatuses := hSafe.outputsCompleteForStatuses
    causalHistoryClosed := hSafe.causalHistoryClosed }

/-! ## Recovery Step -/

/-- Crash recovery preserves the Pulse safe-state predicate. -/
theorem pulseRecoveryStep_preserves_safeRunState
    (G : DAG ν)
    (state : GraphState ν payload)
    (hSafe : SafePulseRunState G state) :
    SafePulseRunState G (recoveredState G state) :=
  persistence_safety G state (safePulseRunState_persistedRecoveryPreconditions G state hSafe)

/-- Recovery followed by classification cannot expose the stuck branch from a safe state. -/
theorem pulseRecoveryStep_classifyGraphState_not_stuck
    (G : DAG ν)
    (state : GraphState ν payload)
    (hSafe : SafePulseRunState G state)
    (stuckState : GraphState ν payload) :
    classifyGraphState G (recoveredState G state) ≠ StepResult.stuck stuckState := by
  have hRecoveredSafe : SafePulseRunState G (recoveredState G state) :=
    pulseRecoveryStep_preserves_safeRunState G state hSafe
  exact
    classifyGraphState_not_stuck_of_wellFormed
      G
      (recoveredState G state)
      hRecoveredSafe
      stuckState

/-! ## Frontier Fact Fold With Recovery Normalization -/

/-- Apply frontier facts and normalize the accumulated state through crash recovery.

This embeds `recoveredState`, including `resetRunningToPending`. It is not
the ordinary non-crash runtime frontier transition; it is the proof surface
for reasoning about a fact fold once the state has been put back through the
recovery envelope.
-/
noncomputable def normalizedFrontierFactsState [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    (results : List (NodeResult ν payload)) : GraphState ν payload :=
  recoveredState G (NodeResult.applyNodeFacts results state)

/-- Admissible frontier facts preserve structural safety after recovery normalization. -/
theorem pulseExecutionStep_preserves_safeRunState [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    (results : List (NodeResult ν payload))
    (hSafe : SafePulseRunState G state)
    (hResults : NodeResult.AllAdmissibleFold G state results) :
    SafePulseRunState G (normalizedFrontierFactsState G state results) := by
  simpa [SafePulseRunState, normalizedFrontierFactsState] using
    frontierFacts_recovered_wellFormedGraphState G state results hSafe hResults

/-- A normalized admissible frontier fact fold cannot classify as stuck. -/
theorem pulseExecutionStep_classifyGraphState_not_stuck [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    (results : List (NodeResult ν payload))
    (hSafe : SafePulseRunState G state)
    (hResults : NodeResult.AllAdmissibleFold G state results)
    (stuckState : GraphState ν payload) :
    classifyGraphState G (normalizedFrontierFactsState G state results) ≠
      StepResult.stuck stuckState := by
  have hNextSafe : SafePulseRunState G (normalizedFrontierFactsState G state results) :=
    pulseExecutionStep_preserves_safeRunState G state results hSafe hResults
  exact
    classifyGraphState_not_stuck_of_wellFormed
      G
      (normalizedFrontierFactsState G state results)
      hNextSafe
      stuckState

/-! ## Replay Determinism Modulo Fixed Sparks -/

/-- Permuting distinct fixed frontier facts does not change the recovered state.

This equality theorem intentionally requires only distinct-node facts plus
permutation. Admissibility is required by the preservation theorem when the
claim is safety, not plain replay equality.
-/
theorem pulseExecutionStep_recoveredState_perm_invariant [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    {left right : List (NodeResult ν payload)}
    (hPerm : left.Perm right)
    (hDistinct : left.Pairwise (fun first second => first.node ≠ second.node)) :
    normalizedFrontierFactsState G state left =
      normalizedFrontierFactsState G state right := by
  have hFacts :
      NodeResult.applyNodeFacts left state =
        NodeResult.applyNodeFacts right state :=
    NodeResult.applyNodeFacts_perm_invariant hPerm hDistinct state
  exact congrArg (fun accumulated => recoveredState G accumulated) hFacts

/-- Fixed external outcomes classify the same after any permutation of distinct-node facts. -/
theorem pulseReplayDeterminism_modulo_fixedOutcomes [DecidableEq ν]
    (G : DAG ν)
    (state : GraphState ν payload)
    {left right : List (NodeResult ν payload)}
    (hPerm : left.Perm right)
    (hDistinct : left.Pairwise (fun first second => first.node ≠ second.node)) :
    classifyGraphState G (normalizedFrontierFactsState G state left) =
      classifyGraphState G (normalizedFrontierFactsState G state right) := by
  rw [pulseExecutionStep_recoveredState_perm_invariant G state hPerm hDistinct]

end Cortex.Pulse
