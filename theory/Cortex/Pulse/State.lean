/-
# Pulse Kernel — Graph State

This module defines the extensional state used by the fixed-topology
Pulse kernel. Runtime payloads, failure details, and signal contents stay
abstract; the proofs only inspect lifecycle status and whether a node has
an output.
-/

import Cortex.Pulse.DAG

namespace Cortex.Pulse

/-- Lifecycle status for a node in the fixed-topology kernel.

The constructors mirror the runtime states in `Cortex.Pulse.GraphRuntime`
while erasing payload details that are irrelevant to structural safety. -/
inductive NodeStatus : Type where
  | pending : NodeStatus
  | running : NodeStatus
  | completed : NodeStatus
  | failed : NodeStatus
  | skipped : NodeStatus
  | interrupted : NodeStatus
  | waiting : NodeStatus
  | rewritten : NodeStatus
  deriving Repr, DecidableEq

namespace NodeStatus

/-- Terminal statuses cannot make another local transition. -/
def terminal : NodeStatus → Prop
  | completed => True
  | failed => True
  | skipped => True
  | rewritten => True
  | pending => False
  | running => False
  | interrupted => False
  | waiting => False

/-- Statuses that failure closure may overwrite with `failed`. -/
def propagatable : NodeStatus → Prop
  | pending => True
  | waiting => True
  | completed => False
  | failed => False
  | skipped => False
  | running => False
  | interrupted => False
  | rewritten => False

/-- Statuses that may retain an output in the abstract state model. -/
def mayHaveOutput : NodeStatus → Prop
  | completed => True
  | failed => True
  | skipped => True
  | rewritten => True
  | pending => False
  | running => False
  | interrupted => False
  | waiting => False

/-- A pending node is not terminal. -/
theorem pending_not_terminal :
    ¬ terminal pending := by
  intro hTerminal
  exact hTerminal

/-- A failed node is not propagatable. -/
theorem failed_not_propagatable :
    ¬ propagatable failed := by
  intro hPropagatable
  exact hPropagatable

end NodeStatus

/-- Extensional graph state: node statuses plus optional node outputs. -/
structure GraphState (ν : Type u) (payload : Type v) where
  /-- Current lifecycle status for each node. -/
  status : ν → NodeStatus
  /-- Optional node output. Payload contents remain abstract. -/
  output : ν → Option payload

namespace GraphState

variable {ν : Type u} {payload : Type v}

@[ext]
theorem ext {s t : GraphState ν payload}
    (hStatus : ∀ n : ν, s.status n = t.status n)
    (hOutput : ∀ n : ν, s.output n = t.output n) :
    s = t := by
  cases s with
  | mk sStatus sOutput =>
      cases t with
      | mk tStatus tOutput =>
          simp only at hStatus hOutput
          cases funext hStatus
          cases funext hOutput
          rfl

/-- Initial graph state: every node is pending and no output exists. -/
def initial : GraphState ν payload where
  status := fun _ => NodeStatus.pending
  output := fun _ => none

/-- Reset only volatile execution statuses before resuming a persisted run. -/
def resetStatus : NodeStatus → NodeStatus
  | NodeStatus.running => NodeStatus.pending
  | NodeStatus.interrupted => NodeStatus.pending
  | NodeStatus.pending => NodeStatus.pending
  | NodeStatus.completed => NodeStatus.completed
  | NodeStatus.failed => NodeStatus.failed
  | NodeStatus.skipped => NodeStatus.skipped
  | NodeStatus.waiting => NodeStatus.waiting
  | NodeStatus.rewritten => NodeStatus.rewritten

/-- Crash-recovery normalization: in-flight nodes become pending again. -/
def resetRunningToPending (s : GraphState ν payload) : GraphState ν payload where
  status := fun n => resetStatus (s.status n)
  output := s.output

/-- A normalized state has no node still marked as running. -/
def noRunningNodes (s : GraphState ν payload) : Prop :=
  ∀ n : ν, s.status n ≠ NodeStatus.running

/-- Outputs only appear at statuses where the abstract kernel permits them. -/
def outputsRespectStatuses (s : GraphState ν payload) : Prop :=
  ∀ (n : ν) (value : payload),
    s.output n = some value → NodeStatus.mayHaveOutput (s.status n)

/-- Resetting volatile execution statuses removes every `running` marker. -/
theorem resetRunning_no_running (s : GraphState ν payload) :
    noRunningNodes (resetRunningToPending s) := by
  intro n
  cases hStatus : s.status n <;>
    simp [resetRunningToPending, resetStatus, hStatus]

end GraphState

end Cortex.Pulse
