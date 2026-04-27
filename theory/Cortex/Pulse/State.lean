import Cortex.Pulse.DAG

/-!
## Overview

This module defines the extensional state used by the fixed-topology
Pulse kernel. Runtime payloads, failure details, and signal contents stay
abstract; the proofs only inspect lifecycle status and whether a node has
an output.

## Context

The Haskell runtime stores maps keyed by durable node identifiers. The
Lean model uses total functions over the finite topology instead, so the
proofs can focus on lifecycle invariants rather than map bookkeeping.

## Theorem Split

The page introduces the status lattice, the extensional graph state, the
topology-domain invariant, and the recovery normalization lemma that
removes volatile `running` marks.
-/

namespace Cortex.Pulse

/-! ## Node Status Lattice -/

/-- `NodeStatus` is the lifecycle status for a node in the fixed-topology kernel.

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

/-- `NodeStatus.terminal status` means the status cannot make another local transition. -/
def terminal : NodeStatus → Prop
  | completed => True
  | failed => True
  | skipped => True
  | rewritten => True
  | pending => False
  | running => False
  | interrupted => False
  | waiting => False

/-- `NodeStatus.propagatable status` means failure closure may overwrite it with `failed`. -/
def propagatable : NodeStatus → Prop
  | pending => True
  | waiting => True
  | completed => False
  | failed => False
  | skipped => False
  | running => False
  | interrupted => False
  | rewritten => False

/-- `NodeStatus.mayHaveOutput status` means the status owns a durable payload. -/
def mayHaveOutput : NodeStatus → Prop
  | completed => True
  | failed => False
  | skipped => False
  | rewritten => True
  | pending => False
  | running => False
  | interrupted => False
  | waiting => False

/-- `NodeStatus.unblocksSuccessors status` means direct successors may run past it. -/
def unblocksSuccessors : NodeStatus → Prop
  | completed => True
  | skipped => True
  | rewritten => True
  | failed => False
  | pending => False
  | running => False
  | interrupted => False
  | waiting => False

/-- `unblocks_terminal` says successor-unblocking statuses are terminal. -/
theorem unblocks_terminal {status : NodeStatus}
    (hUnblocks : unblocksSuccessors status) :
    terminal status := by
  cases status <;> simp [unblocksSuccessors, terminal] at hUnblocks ⊢

/-- `pending_not_terminal` states that a pending node is not terminal. -/
theorem pending_not_terminal :
    ¬ terminal pending := by
  intro hTerminal
  exact hTerminal

/-- `failed_not_propagatable` states that a failed node is not propagatable. -/
theorem failed_not_propagatable :
    ¬ propagatable failed := by
  intro hPropagatable
  exact hPropagatable

end NodeStatus

/-! ## Extensional Graph State -/

/-- `GraphState ν payload` is node statuses plus optional node outputs. -/
structure GraphState (ν : Type u) (payload : Type v) where
  /-- `status node` is the current lifecycle status for a node. -/
  status : ν → NodeStatus
  /-- `output node` is the optional node output. Payload contents remain abstract. -/
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

/-- `GraphState.initial` sets every node to pending with no output. -/
def initial : GraphState ν payload where
  status := fun _ => NodeStatus.pending
  output := fun _ => none

/-! ## Recovery Normalization -/

/-- `resetStatus status` resets only volatile execution statuses before resumption. -/
def resetStatus : NodeStatus → NodeStatus
  | NodeStatus.running => NodeStatus.pending
  | NodeStatus.interrupted => NodeStatus.pending
  | NodeStatus.pending => NodeStatus.pending
  | NodeStatus.completed => NodeStatus.completed
  | NodeStatus.failed => NodeStatus.failed
  | NodeStatus.skipped => NodeStatus.skipped
  | NodeStatus.waiting => NodeStatus.waiting
  | NodeStatus.rewritten => NodeStatus.rewritten

/-- `resetStatus_preserves_terminal` preserves terminal status through recovery reset. -/
theorem resetStatus_preserves_terminal {status : NodeStatus}
    (hTerminal : NodeStatus.terminal status) :
    NodeStatus.terminal (resetStatus status) := by
  cases status <;> simp [resetStatus, NodeStatus.terminal] at hTerminal ⊢

/-- `resetStatus_reflects_unblocks` recovers original unblocking from reset unblocking. -/
theorem resetStatus_reflects_unblocks {status : NodeStatus}
    (hUnblocks : NodeStatus.unblocksSuccessors (resetStatus status)) :
    NodeStatus.unblocksSuccessors status := by
  cases status <;> simp [resetStatus, NodeStatus.unblocksSuccessors] at hUnblocks ⊢

/-- `resetRunningToPending state` makes in-flight nodes pending again after a crash. -/
def resetRunningToPending (s : GraphState ν payload) : GraphState ν payload where
  status := fun n => resetStatus (s.status n)
  output := s.output

/-- `noRunningNodes state` means no node is still marked as running. -/
def noRunningNodes (s : GraphState ν payload) : Prop :=
  ∀ n : ν, s.status n ≠ NodeStatus.running

/-- `outputsRespectStatuses state` constrains outputs to statuses that may retain them. -/
def outputsRespectStatuses (s : GraphState ν payload) : Prop :=
  ∀ (n : ν) (value : payload),
    s.output n = some value → NodeStatus.mayHaveOutput (s.status n)

/-- `topologyDomain G state` says off-topology nodes are absent from durable state. -/
def topologyDomain (G : DAG ν) (s : GraphState ν payload) : Prop :=
  ∀ n : ν, n ∉ G.nodes → s.status n = NodeStatus.pending ∧ s.output n = none

/-! ## Normalization Theorem -/

/-- `resetRunning_no_running` proves status reset removes every `running` marker. -/
theorem resetRunning_no_running (s : GraphState ν payload) :
    noRunningNodes (resetRunningToPending s) := by
  intro n
  cases hStatus : s.status n <;>
    simp [resetRunningToPending, resetStatus, hStatus]

/-- `resetRunning_preserves_topologyDomain` preserves the off-topology invariant. -/
theorem resetRunning_preserves_topologyDomain
    (G : DAG ν)
    (s : GraphState ν payload)
    (hDomain : topologyDomain G s) :
    topologyDomain G (resetRunningToPending s) := by
  intro node hNotMem
  rcases hDomain node hNotMem with ⟨hStatus, hOutput⟩
  constructor
  · simp [resetRunningToPending, resetStatus, hStatus]
  · simpa [resetRunningToPending] using hOutput

/-- `resetRunning_preserves_outputsRespectStatuses` preserves output ownership. -/
theorem resetRunning_preserves_outputsRespectStatuses
    (s : GraphState ν payload)
    (hOutputs : outputsRespectStatuses s) :
    outputsRespectStatuses (resetRunningToPending s) := by
  intro node value hOutput
  have hMayHaveOutput : NodeStatus.mayHaveOutput (s.status node) :=
    hOutputs node value hOutput
  cases hStatus : s.status node <;>
    simp
      [ resetRunningToPending
      , resetStatus
      , NodeStatus.mayHaveOutput
      , hStatus
      ] at hMayHaveOutput ⊢

end GraphState

end Cortex.Pulse
