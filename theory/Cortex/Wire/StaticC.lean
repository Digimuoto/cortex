import Cortex.Pulse.Classify
import Cortex.Pulse.Fact

/-!
## Overview

This module defines the small state-machine semantics consumed by the
freestanding Wire C emitter. The target is deliberately narrower than the
general Pulse runtime: a fixed `Fin n` topology, five lifecycle statuses,
opaque `UInt64` output handles, and success, skipped, or failure completions.

## Context

The Haskell compiler remains authoritative for Wire parsing and elaboration.
The host-side `cortex-wire-c` executable validates a normalized deployment
artifact and emits a topology-specialized C implementation. The pretty-printer
and C compiler remain outside this proof; the definitions below pin the
semantics that differential and boot tests must check against emitted code.

## Theorem Split

The refinement lemmas relate target readiness and completion application to
the existing Track 2 definitions. Failure closure and terminal classification
are exposed through the same Track 2 operators, while the target interpreter
adds an explicit awaiting-completions branch before classification.
-/

namespace Cortex.Wire.StaticC

open Cortex.Pulse

/-! ## Restricted Target State -/

/-- Lifecycle statuses representable by the v1 generated C ABI. -/
inductive Status : Type where
  | pending
  | running
  | completed
  | failed
  | skipped
  deriving Repr, DecidableEq

namespace Status

/-- Embed a target status into the existing Track 2 status lattice. -/
def toNodeStatus : Status → NodeStatus
  | pending => .pending
  | running => .running
  | completed => .completed
  | failed => .failed
  | skipped => .skipped

/-- Successful terminal target statuses unblock direct successors. -/
def unblocksSuccessors : Status → Prop
  | completed => True
  | skipped => True
  | pending => False
  | running => False
  | failed => False

/-- Target unblocking agrees with the Track 2 status predicate. -/
theorem unblocksSuccessors_iff (status : Status) :
    unblocksSuccessors status ↔ NodeStatus.unblocksSuccessors status.toNodeStatus := by
  cases status <;> simp [unblocksSuccessors, toNodeStatus, NodeStatus.unblocksSuccessors]

/-- Pending target state is reflected exactly by the Track 2 embedding. -/
theorem toNodeStatus_eq_pending_iff (status : Status) :
    status.toNodeStatus = NodeStatus.pending ↔ status = Status.pending := by
  cases status <;> simp [toNodeStatus]

end Status

/-- Mutable state interpreted by the target machine. -/
structure MachineState (n : Nat) where
  /-- Per-node lifecycle state. -/
  status : Fin n → Status
  /-- Opaque adapter-owned payload handles. -/
  output : Fin n → Option UInt64

namespace MachineState

/-- Embed target state into the existing extensional graph state. -/
def toGraphState (state : MachineState n) : GraphState (Fin n) UInt64 where
  status := fun node => (state.status node).toNodeStatus
  output := state.output

end MachineState

/-! ## Certified Static Topology -/

/-- A target program is a finite boolean edge table with an acyclicity witness. -/
structure Program (n : Nat) where
  /-- Direct predecessor relation over dense node identifiers. -/
  edge : Fin n → Fin n → Bool
  /-- The normalized artifact validator establishes absence of directed cycles. -/
  acyclic : ∀ node : Fin n, ¬ EdgePath edge node node

namespace Program

/-- Every dense node belongs to the program topology by construction. -/
def toDAG (program : Program n) : DAG (Fin n) where
  nodes := Finset.univ
  edge := program.edge
  edge_source_mem := fun {_source _target} _hEdge => Finset.mem_univ _
  edge_target_mem := fun {_source _target} _hEdge => Finset.mem_univ _
  acyclic := program.acyclic

/-- The target readiness scan over direct predecessor rows. -/
def Ready
    (program : Program n)
    (state : MachineState n)
    (node : Fin n) : Prop :=
  state.status node = Status.pending ∧
    ∀ predecessor : Fin n,
      program.edge predecessor node = true →
        Status.unblocksSuccessors (state.status predecessor)

/-- Target readiness is exactly Track 2 direct readiness over `Fin n`. -/
theorem ready_iff_directReady
    (program : Program n)
    (state : MachineState n)
    (node : Fin n) :
    program.Ready state node ↔
      DirectReady program.toDAG state.toGraphState node := by
  constructor
  · intro hReady
    refine ⟨Finset.mem_univ node, ?_, ?_⟩
    · exact (Status.toNodeStatus_eq_pending_iff (state.status node)).mpr hReady.1
    intro predecessor hEdge
    exact (Status.unblocksSuccessors_iff (state.status predecessor)).mp (hReady.2 predecessor hEdge)
  · intro hReady
    refine ⟨?_, ?_⟩
    · exact (Status.toNodeStatus_eq_pending_iff (state.status node)).mp hReady.2.1
    intro predecessor hEdge
    exact
      (Status.unblocksSuccessors_iff (state.status predecessor)).mpr
        (hReady.2.2 predecessor hEdge)

/-- Dense node identifiers make every generated node-array access in bounds. -/
theorem nodeIndex_lt_count (node : Fin n) : node.val < n :=
  node.isLt

end Program

/-! ## Completion Interpreter -/

/-- Completion outcomes accepted from the platform adapter. -/
inductive Completion : Type where
  | succeeded (payload : UInt64)
  | skipped
  | failed
  deriving Repr, DecidableEq

namespace Completion

/-- Embed a target completion into a Track 2 node outcome. -/
def toNodeOutcome : Completion → NodeOutcome UInt64
  | succeeded payload => .succeeded payload
  | skipped => .skipped
  | failed => .failed

/-- Status written by a completion. -/
def status : Completion → Status
  | succeeded _payload => .completed
  | skipped => .skipped
  | failed => .failed

/-- Optional opaque handle written by a completion. -/
def output : Completion → Option UInt64
  | succeeded payload => some payload
  | skipped => none
  | failed => none

end Completion

/-- Apply one completion to its dense node slot. -/
def applyCompletion
    (node : Fin n)
    (completion : Completion)
    (state : MachineState n) : MachineState n where
  status := fun current => if current = node then completion.status else state.status current
  output := fun current => if current = node then completion.output else state.output current

/-- Completion application refines the existing Track 2 node-fact update. -/
theorem applyCompletion_refines_applyNodeFact
    (node : Fin n)
    (completion : Completion)
    (state : MachineState n) :
    (applyCompletion node completion state).toGraphState =
      NodeResult.applyNodeFact
        { node := node, outcome := completion.toNodeOutcome }
        state.toGraphState := by
  apply GraphState.ext
  · intro current
    by_cases hCurrent : current = node
    · subst current
      cases completion <;>
        simp
          [ applyCompletion
          , MachineState.toGraphState
          , Completion.status
          , Completion.toNodeOutcome
          , NodeResult.applyNodeFact
          , NodeOutcome.status
          , Status.toNodeStatus
          ]
    · cases completion <;>
        simp
          [ applyCompletion
          , MachineState.toGraphState
          , Completion.status
          , Completion.toNodeOutcome
          , NodeResult.applyNodeFact
          , NodeOutcome.status
          , Status.toNodeStatus
          , hCurrent
          ]
  · intro current
    by_cases hCurrent : current = node
    · subst current
      cases completion <;>
        simp
          [ applyCompletion
          , MachineState.toGraphState
          , Completion.output
          , Completion.toNodeOutcome
          , NodeResult.applyNodeFact
          , NodeOutcome.output
          ]
    · cases completion <;>
        simp
          [ applyCompletion
          , MachineState.toGraphState
          , Completion.output
          , Completion.toNodeOutcome
          , NodeResult.applyNodeFact
          , NodeOutcome.output
          , hCurrent
          ]

/-! ## Closure And Classification -/

/-- The semantic failure-closure operation interpreted by the target IR.

The generated C realizes this extensional operation as a topological pass;
that realization is checked differentially rather than claimed as a theorem of
the pretty-printer. -/
def closeFailures
    (program : Program n)
    [DecidableRel program.toDAG.reaches]
    (state : MachineState n) : GraphState (Fin n) UInt64 :=
  propagateFailure program.toDAG state.toGraphState

/-- Target failure closure is definitionally the Track 2 closure operation. -/
theorem closeFailures_refines_propagateFailure
    (program : Program n)
    [DecidableRel program.toDAG.reaches]
    (state : MachineState n) :
    closeFailures program state =
      propagateFailure program.toDAG state.toGraphState :=
  rfl

/-- Target interpreter result before the wireOS adapter interprets effects. -/
inductive DriveResult (n : Nat) : Type 2 where
  | awaitingCompletions
  | classified (result : StepResult (Fin n) UInt64)

/-- Whether any asynchronous effect is still running. -/
def hasRunning (state : MachineState n) : Prop :=
  ∃ node : Fin n, state.status node = Status.running

/-- Interpret a failure-closed state without classifying running effects as stuck. -/
def interpretClosed
    (program : Program n)
    (state : MachineState n) : DriveResult n := by
  letI : Decidable (hasRunning state) := by
    unfold hasRunning
    infer_instance
  if hasRunning state then
    exact .awaitingCompletions
  else
    exact .classified (classifyClosedGraphState program.toDAG state.toGraphState)

/-- With no running effect, target classification is exactly Track 2 classification. -/
theorem interpretClosed_refines_classifyClosedGraphState
    (program : Program n)
    (state : MachineState n)
    (hNoRunning : ¬ hasRunning state) :
    interpretClosed program state =
      DriveResult.classified
        (classifyClosedGraphState program.toDAG state.toGraphState) := by
  simp [interpretClosed, hNoRunning]

end Cortex.Wire.StaticC
