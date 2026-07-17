import Cortex.Pulse.Classify
import Cortex.Pulse.Recovery

/-!
## Overview

This executable is the narrow extraction spike for the host-neutral Cortex
kernel built from computable Pulse Track 2 decisions. It constructs a one-node
topology, recovers its persisted state, and classifies the result through the
same pure definitions used by the proofs.

## Context

The example topology has no edges, so strict reachability is constructively
empty. The explicit `DecidableRel` demonstrates the dependency that a concrete
finite-topology representation must supply to recovery and failure closure.

## Theorem Split

There are no proof obligations on this page. The executable prints enough of
the recovery, frontier, and classification result to prevent the compiler from
discarding the kernel path during generated-C and native-linkage inspection.
-/

namespace Cortex.Kernel.ExtractionSpike

open Cortex.Pulse

/-- No nonempty path can be constructed from an always-false edge predicate. -/
private theorem noFalseEdgePath {source target : Unit}
    (hPath : EdgePath (fun _ _ : Unit => false) source target) : False := by
  induction hPath with
  | direct hEdge => simp at hEdge
  | trans _ _ ihLeft _ => exact ihLeft

/-- The smallest nonempty fixed topology: one node and no edges. -/
def oneNodeDAG : DAG Unit where
  nodes := Finset.univ
  edge := fun _ _ => false
  edge_source_mem := by
    intro source _target _hEdge
    exact Finset.mem_univ source
  edge_target_mem := by
    intro _source target _hEdge
    exact Finset.mem_univ target
  acyclic := fun _node hPath => noFalseEdgePath hPath

/-- Empty strict reachability is constructively decidable for `oneNodeDAG`. -/
@[reducible] def oneNodeReachability : DecidableRel oneNodeDAG.reaches :=
  fun _source _target => isFalse fun hPath => noFalseEdgePath hPath

local instance : DecidableRel oneNodeDAG.reaches := oneNodeReachability

/-- A persisted node that was running when execution stopped. -/
def persistedState : GraphState Unit Nat where
  status := fun _ => NodeStatus.running
  output := fun _ => none

/-- The recovered example state evaluated by the extraction spike. -/
def recoveredExample : GraphState Unit Nat :=
  recoveredState oneNodeDAG persistedState

/-- The recovered example's direct executable frontier. -/
def recoveredFrontier : Finset Unit :=
  directReadyNodes oneNodeDAG recoveredExample

/-- The full recovery-and-classification result evaluated by the spike. -/
def classificationExample : StepResult Unit Nat :=
  classifyGraphState oneNodeDAG recoveredExample

private def classificationName : StepResult Unit Nat → String
  | .progressing _ frontier => "progressing:" ++ toString frontier.card
  | .settled _ .completed => "settled:completed"
  | .settled _ .failed => "settled:failed"
  | .suspended _ => "suspended"
  | .stuck _ => "stuck"

def main : IO Unit := do
  IO.println ("recovered:" ++ repr (recoveredExample.status ()))
  IO.println ("frontier:" ++ toString recoveredFrontier.card)
  IO.println ("classification:" ++ classificationName classificationExample)

end Cortex.Kernel.ExtractionSpike

/-- Lake executable entry point for the namespaced extraction spike. -/
def main : IO Unit :=
  Cortex.Kernel.ExtractionSpike.main
