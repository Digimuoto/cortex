import Cortex.Pulse.Classify
import Cortex.Pulse.Fact
import Cortex.Wire.SemanticC

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

open Cortex.Wire.NativePure

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

/-- Stable target-internal status code used by shared semantic C lowering. -/
def semanticCode : Status → U8
  | pending => { value := 0, upper := by decide }
  | running => { value := 1, upper := by decide }
  | completed => { value := 2, upper := by decide }
  | failed => { value := 3, upper := by decide }
  | skipped => { value := 4, upper := by decide }

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

/-! ### Shared semantic C scheduler lowering -/

open Cortex.Wire.NativePure

/-- Dense node identifier represented in the target-internal uint64 basis. -/
private def nodeCode
    (nodeCountWithinU64 : n < 2 ^ 64)
    (node : Fin n) : U64 :=
  { value := node.val, upper := lt_trans node.isLt nodeCountWithinU64 }

/-- Read one statically in-bounds status from the scheduler status vector. -/
private def statusAt
    (nodeCountWithinU64 : n < 2 ^ 64)
    (node : Fin n) : SemanticC.Expr [.vector n .u8] .u8 :=
  .index (.load .zero) (.u64 (nodeCode nodeCountWithinU64 node))

/-- Semantic expression for the scheduler's successful-predecessor policy. -/
private def statusUnblocks
    (status : SemanticC.Expr context .u8) : SemanticC.Expr context .bool :=
  .or
    (.eqU8 status (.u8 Status.completed.semanticCode))
    (.eqU8 status (.u8 Status.skipped.semanticCode))

/-- Topology-specialized readiness expression for one dense node. The edge
relation is partially evaluated: only actual predecessor checks remain. -/
def semanticReadyExpr
    (program : Program n)
    (nodeCountWithinU64 : n < 2 ^ 64)
    (node : Fin n) : SemanticC.Expr [.vector n .u8] .bool :=
  let pending :=
    SemanticC.Expr.eqU8
      (statusAt nodeCountWithinU64 node)
      (.u8 Status.pending.semanticCode)
  (List.ofFn fun predecessor : Fin n => predecessor).foldl
    (fun ready predecessor =>
      if program.edge predecessor node = true then
        .and ready (statusUnblocks (statusAt nodeCountWithinU64 predecessor))
      else ready)
    pending

private def semanticReadySignature (n : Nat) : SemanticC.Signature :=
  { params := [.vector n .u8], result := .bool }

/-- One scheduler readiness function in the shared semantic IR. -/
def semanticReadyFunction
    (program : Program n)
    (nodeCountWithinU64 : n < 2 ^ 64)
    (node : Fin n) : SemanticC.Function (semanticReadySignature n) :=
  { name := s!"cortex_static_ready_{node.val}"
  , body := .ret (semanticReadyExpr program nodeCountWithinU64 node)
  }

/-- Semantic-module form of the readiness functions. No theorem yet relates
this lowering to `Program.Ready`, and the shipped scheduler emitter lowers
directly to the C11 AST without consuming it; the module is a stated target,
checked only by a smoke example, until the correspondence lemma lands. -/
def semanticModule
    (program : Program n)
    (nodeCountWithinU64 : n < 2 ^ 64) : SemanticC.Module :=
  { functions :=
      (List.ofFn fun node : Fin n => node).map fun node =>
        .mk (semanticReadySignature n) (semanticReadyFunction program nodeCountWithinU64 node)
  }

private def singletonNoEdgeProgram : Program 1 where
  edge := fun _ _ => false
  acyclic := by
    intro node path
    have impossible : ∀ {source target : Fin 1},
        EdgePath (fun _ _ => false) source target → False := by
      intro source target candidate
      induction candidate with
      | direct hEdge => simp at hEdge
      | trans _ _ leftImpossible _ => exact leftImpossible
    exact impossible path

example :
    (SemanticC.evalClosed
          (semanticReadyExpr singletonNoEdgeProgram (by decide) 0)
          [.vector [.u8 Status.pending.semanticCode]]).bind
        (fun
          | .bool value => some value
          | .unit | .u8 _ | .u32 _ | .i64 _ | .u64 _ | .f64 _ | .text _ |
            .vector _ | .record _ | .sum _ _ => none) =
      some true := by
  native_decide

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

/-! ## Versioned Engine State -/

/-- Terminal state carried by the separately versioned hosted engine ABI. -/
inductive EngineTerminal : Type where
  | active
  | completed
  | failed
  | cancelled
  deriving Repr, DecidableEq

/-- Checkpoint-gated engine state. Runtime authority remains outside this value. -/
structure EngineState (n : Nat) where
  /-- Fixed-topology lifecycle and opaque output handles. -/
  machine : MachineState n
  /-- Monotonic durable-checkpoint sequence. -/
  checkpointSequence : Nat
  /-- Whether the current sequence must be acknowledged before another drive. -/
  checkpointPending : Bool
  /-- Structural terminal state. -/
  terminal : EngineTerminal

/-- Typed durable representation exported across the engine/host boundary. -/
structure Snapshot (n : Nat) where
  /-- Program node lifecycle statuses. -/
  status : Fin n → Status
  /-- Opaque, host-stable output handles. -/
  output : Fin n → Option UInt64
  /-- Monotonic durable-checkpoint sequence. -/
  checkpointSequence : Nat
  /-- Structural terminal state. -/
  terminal : EngineTerminal

namespace Snapshot

/-- Restore validation rejects volatile running state. -/
def Normalized (snapshot : Snapshot n) : Prop :=
  ∀ node : Fin n, snapshot.status node ≠ Status.running

/-- Output presence and nonzero-handle validity agree with lifecycle status. -/
def HandlesValid (snapshot : Snapshot n) : Prop :=
  ∀ node : Fin n,
    match snapshot.status node with
    | .completed => ∃ handle, snapshot.output node = some handle ∧ handle ≠ 0
    | .pending | .running | .failed | .skipped => snapshot.output node = none

/-- Completed and skipped nodes carry closed direct dependency history. -/
def DependencyClosed (program : Program n) (snapshot : Snapshot n) : Prop :=
  ∀ node : Fin n,
    Status.unblocksSuccessors (snapshot.status node) →
      ∀ predecessor : Fin n,
        program.edge predecessor node = true →
          Status.unblocksSuccessors (snapshot.status predecessor)

/-- Restore-valid snapshots combine sequencing, normalization, handles, and closure. -/
structure Valid (program : Program n) (snapshot : Snapshot n) : Prop where
  /-- Checkpoint zero is never exported. -/
  sequencePositive : 0 < snapshot.checkpointSequence
  /-- Volatile running statuses are replay-normalized by the host before restore. -/
  normalized : snapshot.Normalized
  /-- Only completed nodes carry nonzero opaque handles. -/
  handlesValid : snapshot.HandlesValid
  /-- Successful nodes have successful direct predecessor history. -/
  dependencyClosed : snapshot.DependencyClosed program

end Snapshot

/-- Export omits the transient acknowledgement gate and carries no runtime authority. -/
def exportSnapshot (state : EngineState n) : Snapshot n where
  status := state.machine.status
  output := state.machine.output
  checkpointSequence := state.checkpointSequence
  terminal := state.terminal

/-- Import raises the checkpoint gate so the host must acknowledge restored durability. -/
def importSnapshot (snapshot : Snapshot n) : EngineState n where
  machine := { status := snapshot.status, output := snapshot.output }
  checkpointSequence := snapshot.checkpointSequence
  checkpointPending := true
  terminal := snapshot.terminal

/-- Export after import is an exact typed snapshot round trip. -/
theorem export_import_snapshot (snapshot : Snapshot n) :
    exportSnapshot (importSnapshot snapshot) = snapshot :=
  rfl

/-- Import after export preserves all durable state and raises only the acknowledgement gate. -/
theorem import_export_snapshot (state : EngineState n) :
    importSnapshot (exportSnapshot state) =
      { state with checkpointPending := true } :=
  rfl

/-- Snapshot validity is unchanged by an import/export round trip. -/
theorem valid_export_import
    (program : Program n)
    (snapshot : Snapshot n)
    (hValid : snapshot.Valid program) :
    (exportSnapshot (importSnapshot snapshot)).Valid program := by
  simpa [export_import_snapshot] using hValid

/-! ## Checkpoint-Gated Whole Drive -/

/-- Whole-drive decision exposed by the target-independent circuit engine. -/
inductive EngineDriveResult (n : Nat) : Type 2 where
  | checkpointRequired
  | awaitingCompletions
  | decided (result : StepResult (Fin n) UInt64)
  | terminal (result : EngineTerminal)

/-- The whole engine decision, including durable acknowledgement gating. -/
def driveEngine
    (program : Program n)
    (state : EngineState n) : EngineDriveResult n :=
  if state.checkpointPending then
    .checkpointRequired
  else if state.terminal ≠ EngineTerminal.active then
    .terminal state.terminal
  else
    match interpretClosed program state.machine with
    | .awaitingCompletions => .awaitingCompletions
    | .classified result => .decided result

/-- A pending checkpoint blocks all scheduling and terminal observation. -/
theorem driveEngine_checkpointRequired
    (program : Program n)
    (state : EngineState n)
    (hPending : state.checkpointPending = true) :
    driveEngine program state = .checkpointRequired := by
  simp [driveEngine, hPending]

/-- With an acknowledged checkpoint and active run, whole-drive running
detection refines Track 2. -/
theorem driveEngine_awaiting_refinement
    (program : Program n)
    (state : EngineState n)
    (hAcknowledged : state.checkpointPending = false)
    (hActive : state.terminal = EngineTerminal.active)
    (hRunning : hasRunning state.machine) :
    driveEngine program state = .awaitingCompletions := by
  simp [driveEngine, hAcknowledged, hActive, interpretClosed, hRunning]

/-- With an acknowledged checkpoint and no running effect, whole drive is exactly classification. -/
theorem driveEngine_classification_refinement
    (program : Program n)
    (state : EngineState n)
    (hAcknowledged : state.checkpointPending = false)
    (hActive : state.terminal = EngineTerminal.active)
    (hNoRunning : ¬ hasRunning state.machine) :
    driveEngine program state =
      .decided (classifyClosedGraphState program.toDAG state.machine.toGraphState) := by
  simp [driveEngine, hAcknowledged, hActive, interpretClosed, hNoRunning]

/-- An accepted completion advances the sequence and raises the checkpoint gate. -/
def acceptCompletion
    (node : Fin n)
    (completion : Completion)
    (state : EngineState n) : EngineState n :=
  { state with
    machine := applyCompletion node completion state.machine
    checkpointSequence := state.checkpointSequence + 1
    checkpointPending := true }

/-- Accepted completions advance the checkpoint sequence exactly once. -/
theorem acceptCompletion_sequence
    (node : Fin n)
    (completion : Completion)
    (state : EngineState n) :
    (acceptCompletion node completion state).checkpointSequence =
      state.checkpointSequence + 1 :=
  rfl

/-- Accepted completions cannot unlock another drive before durable acknowledgement. -/
theorem acceptCompletion_blocks_drive
    (program : Program n)
    (node : Fin n)
    (completion : Completion)
    (state : EngineState n) :
    driveEngine program (acceptCompletion node completion state) =
      .checkpointRequired := by
  simp [acceptCompletion, driveEngine]

end Cortex.Wire.StaticC
