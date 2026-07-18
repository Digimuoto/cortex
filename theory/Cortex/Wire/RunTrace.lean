import Cortex.Pulse.Classify
import Cortex.Wire.SelectRecovery

/-!
## Overview

Closed admitted-middle run traces for the Wire/Pulse proof boundary.

## Context

`Cortex.Wire.PulseSafety` proves that each admitted recovery, execution,
rewrite, and selected-branch step preserves `SafeWireRunState`. This module
packages those local preservation theorems into one closed finite-trace
surface. The compiler, parser, executor bodies, materialization, and durable
lineage decoding remain boundary witnesses: once those witnesses are supplied,
only the constructors below are admitted as proof-side middle transitions.

## Theorem Split

The page defines:

* `WirePulseSnapshot`, the changing state carried by the admitted middle;
* `AdmittedWirePulseStep`, the closed alphabet of admitted middle transitions;
* `AdmittedWirePulseTrace`, finite composition of admitted steps;
* trace preservation from either an already-safe snapshot or persisted recovery
  preconditions;
* final non-stuck classification theorems.
-/

namespace Cortex.Wire

open Cortex.Pulse

/-! ## Snapshots -/

section RunTrace

variable {executor config contract authority payload : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

/-- `WirePulseSnapshot` is the mutable proof-side state of the admitted runtime middle.

The executor registry and initial budget are fixed for a run, so they remain
parameters of the safety predicate rather than fields of each snapshot. -/
structure WirePulseSnapshot
    (executor config authority payload : Type) where
  /-- Remaining rewrite budget at this point in the run. -/
  remainingBudget : RewriteBudget
  /-- Current Wire planning context. -/
  context : PlanningContext (WireNode executor config authority)
  /-- Current materialized Pulse DAG. -/
  G : DAG (WireNode executor config authority)
  /-- Current persisted Pulse graph state. -/
  state : GraphState (WireNode executor config authority) payload

namespace WirePulseSnapshot

/-- The snapshot reached by applying Pulse recovery to the persisted graph state. -/
def recovered (snapshot : WirePulseSnapshot executor config authority payload)
    [DecidableRel snapshot.G.reaches] :
    WirePulseSnapshot executor config authority payload :=
  { remainingBudget := snapshot.remainingBudget
    context := snapshot.context
    G := snapshot.G
    state := recoveredState snapshot.G snapshot.state }

end WirePulseSnapshot

/-- `SafeWirePulseSnapshot` applies the existing safe-run envelope to a snapshot. -/
abbrev SafeWirePulseSnapshot
    (registry : ExecutorRegistry executor config contract authority)
    (initialBudget : RewriteBudget)
    (snapshot : WirePulseSnapshot executor config authority payload) :
    Prop :=
  SafeWireRunState
    registry
    initialBudget
    snapshot.remainingBudget
    snapshot.context
    snapshot.G
    snapshot.state

namespace WirePulseSnapshot

/-- Persisted recovery preconditions establish the first safe snapshot of a run. -/
theorem runStart_establishes_safeRunState
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    (snapshot : WirePulseSnapshot executor config authority payload)
    [DecidableRel snapshot.G.reaches]
    (hSourceValid : SourcePlanningContextValid snapshot.context)
    (hBoundary : _root_.Cortex.Wire.registryBoundary registry snapshot.context.topology)
    (hBridge : WireTopologyDAGBridge snapshot.context.topology snapshot.G)
    (hBudget : snapshot.remainingBudget.le initialBudget)
    (hPersisted : persistedRecoveryPreconditions snapshot.G snapshot.state) :
    SafeWirePulseSnapshot registry initialBudget snapshot.recovered := by
  change
    SafeWireRunState
      registry
      initialBudget
      snapshot.remainingBudget
      snapshot.context
      snapshot.G
      (recoveredState snapshot.G snapshot.state)
  exact
    SafeWireRunState.wirePulseRecoveryStep_establishes_safeRunState
      hSourceValid
      hBoundary
      hBridge
      hBudget
      hPersisted

end WirePulseSnapshot

/-! ## Closed Step Alphabet -/

/-- One admitted transition inside the Wire/Pulse proof boundary.

This is a closed proof-side alphabet. Any runtime action that cannot be
represented by one of these constructors is outside the admitted middle until a
new constructor and preservation theorem are added.

Each trace fixes one `payload` type. The CorePure-success constructor is
therefore available only for traces whose payload is
`CorePure.Name → Option CorePure.Value`; the other constructors are polymorphic
in the trace payload. -/
inductive AdmittedWirePulseStep
    (registry : ExecutorRegistry executor config contract authority)
    (initialBudget : RewriteBudget) :
    (payload : Type) →
      WirePulseSnapshot executor config authority payload →
        WirePulseSnapshot executor config authority payload →
          Prop where
  | recovery
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload)
      [DecidableRel snapshot.G.reaches] :
      AdmittedWirePulseStep
        registry
        initialBudget
        payload
        snapshot
        snapshot.recovered
  | frontierFacts
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload)
      [DecidableRel snapshot.G.reaches]
      (results : List (NodeResult (WireNode executor config authority) payload))
      (hResults : NodeResult.AllAdmissibleFold snapshot.G snapshot.state results) :
      AdmittedWirePulseStep
        registry
        initialBudget
        payload
        snapshot
        { remainingBudget := snapshot.remainingBudget
          context := snapshot.context
          G := snapshot.G
          state := recoveredState snapshot.G (NodeResult.applyNodeFacts results snapshot.state) }
  /-- Successful CorePure evaluation emits the proof-side CorePure payload shape. -/
  | corePureSuccess
      {ctx : CorePure.StaticContext}
      {env : CorePure.Env}
      {pureNode : CorePure.PureNode}
      {lookup : CorePure.Name → Option CorePure.Value}
      {contracts : CorePure.OutputValueContracts}
      {node : WireNode executor config authority}
      (snapshot :
        WirePulseSnapshot executor config authority
          (CorePure.Name → Option CorePure.Value))
      [DecidableRel snapshot.G.reaches]
      (hNode : CorePure.PureNodeAdmitted ctx pureNode)
      (hEval : pureNode.evalOutputs env = Except.ok lookup)
      (hContracts :
        ∀ outerEnv localEnv,
          CorePure.evalBindings env pureNode.bindings = Except.ok outerEnv →
            CorePure.evalWhereEnv outerEnv pureNode.whereExpr = Except.ok localEnv →
              CorePure.OutputExpressionsSatisfyContracts
                (CorePure.outputValueContractOk contracts)
                localEnv
                pureNode.outputs)
      (hAdmissible :
        NodeResult.Admissible
          snapshot.G
          snapshot.state
          { node := node
            outcome := NodeOutcome.succeeded lookup }) :
      AdmittedWirePulseStep
        registry
        initialBudget
        (CorePure.Name → Option CorePure.Value)
        snapshot
        { remainingBudget := snapshot.remainingBudget
          context := snapshot.context
          G := snapshot.G
          state :=
            recoveredState
              snapshot.G
              (NodeResult.applyNodeFacts
                [ { node := node
                    outcome := NodeOutcome.succeeded lookup } ]
                snapshot.state) }
  | constructedRewrite
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload)
      {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
      {rawRewrite : GraphRewrite (WireNode executor config authority)}
      {insertedDepth : Nat}
      {nextBudget : RewriteBudget}
      {nextG : DAG (WireNode executor config authority)}
      {nextState : GraphState (WireNode executor config authority) payload}
      (step :
        ConstructedPlanningStep
          policy
          (_root_.Cortex.Wire.registryBoundary registry)
          snapshot.context
          snapshot.remainingBudget
          rawRewrite
          insertedDepth
          nextBudget)
      (hDelta : RegistryBoundaryDeltaAdmitted registry step.delta)
      (hMaterialized : MaterializedPulseState step.nextContext nextG nextState) :
      AdmittedWirePulseStep
        registry
        initialBudget
        payload
        snapshot
        { remainingBudget := nextBudget
          context := step.nextContext
          G := nextG
          state := nextState }
  | selectActualize
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload)
      {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
      {arm : Type}
      {family : LatentBranchFamily (WireNode executor config authority) arm}
      {actualize : SelectActualize family}
      {insertedDepth : Nat}
      {nextBudget : RewriteBudget}
      {nextG : DAG (WireNode executor config authority)}
      {nextState : GraphState (WireNode executor config authority) payload}
      (step :
        ConstructedPlanningStep
          policy
          (_root_.Cortex.Wire.registryBoundary registry)
          snapshot.context
          snapshot.remainingBudget
          actualize.toGraphRewrite
          insertedDepth
          nextBudget)
      (hDelta : RegistryBoundaryDeltaAdmitted registry step.delta)
      (hMaterialized : MaterializedPulseState step.nextContext nextG nextState) :
      AdmittedWirePulseStep
        registry
        initialBudget
        payload
        snapshot
        { remainingBudget := nextBudget
          context := step.nextContext
          G := nextG
          state := nextState }
  /-- Selected-branch recovery requires durable provenance before the constructor is available.

  Safety preservation itself uses the recovered `record`; the persisted admission and provenance
  are load-bearing for replay identity and determinism rather than for the safe-run projection. -/
  | selectedBranchRecovery
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload)
      {policy : RuntimeNamespacePolicy (WireNode executor config authority)}
      {arm : Type}
      {family : LatentBranchFamily (WireNode executor config authority) arm}
      {nextG : DAG (WireNode executor config authority)}
      {nextState : GraphState (WireNode executor config authority) payload}
      (persisted :
        PersistedSelectedBranchAdmission
          family
          policy
          (_root_.Cortex.Wire.registryBoundary registry)
          snapshot.context
          snapshot.remainingBudget)
      (record :
        SelectedBranchRecoveryRecord
          family
          policy
          (_root_.Cortex.Wire.registryBoundary registry)
          snapshot.context
          snapshot.remainingBudget)
      (hProvenance :
        SelectedBranchRecoveryRecord.Provenance persisted.toRecoveryRecord record)
      (hDelta : RegistryBoundaryDeltaAdmitted registry record.step.delta)
      (hMaterialized : MaterializedPulseState record.step.nextContext nextG nextState) :
      AdmittedWirePulseStep
        registry
        initialBudget
        payload
        snapshot
        { remainingBudget := record.remaining
          context := record.step.nextContext
          G := nextG
          state := nextState }

namespace AdmittedWirePulseStep

/-- Every admitted middle step preserves the Wire/Pulse safe-run envelope. -/
theorem preserves_safeRunState
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {payload : Type}
    {before after : WirePulseSnapshot executor config authority payload}
    (transition : AdmittedWirePulseStep registry initialBudget payload before after)
    (hSafe : SafeWirePulseSnapshot registry initialBudget before) :
    SafeWirePulseSnapshot registry initialBudget after := by
  cases transition with
  | recovery snapshot =>
      change
        SafeWireRunState
          registry
          initialBudget
          before.remainingBudget
          before.context
          before.G
          (recoveredState before.G before.state)
      exact SafeWireRunState.wirePulseRecoveryStep_preserves_safeRunState hSafe
  | frontierFacts snapshot results hResults =>
      exact
        SafeWireRunState.wirePulseExecutionStep_preserves_safeRunState
          hSafe
          results
          hResults
  | corePureSuccess snapshot hNode hEval hContracts hAdmissible =>
      exact
        (SafeWireRunState.corePureExecutionStep_preserves_safeRunState
          hSafe
          hNode
          hEval
          hContracts
          hAdmissible).2
  | constructedRewrite snapshot step hDelta hMaterialized =>
      exact
        SafeWireRunState.wirePulseAdmittedRewrite_preserves_safeRunState
          hSafe
          step
          hDelta
          hMaterialized
  | selectActualize snapshot step hDelta hMaterialized =>
      exact
        SafeWireRunState.selectActualize_preserves_safeRunState
          hSafe
          step
          hDelta
          hMaterialized
  | selectedBranchRecovery snapshot persisted record hProvenance hDelta hMaterialized =>
      exact
        selectedBranch_recovery_preserves_safeRunState
          hSafe
          record
          hDelta
          hMaterialized

end AdmittedWirePulseStep

/-! ## Finite Traces -/

/-- Finite admitted run traces are reflexive-transitive closure with named constructors. -/
inductive AdmittedWirePulseTrace
    (registry : ExecutorRegistry executor config contract authority)
    (initialBudget : RewriteBudget) :
    (payload : Type) →
      WirePulseSnapshot executor config authority payload →
        WirePulseSnapshot executor config authority payload →
          Prop where
  | done
      {payload : Type}
      (snapshot : WirePulseSnapshot executor config authority payload) :
      AdmittedWirePulseTrace registry initialBudget payload snapshot snapshot
  | step
      {payload : Type}
      {first second third : WirePulseSnapshot executor config authority payload}
      (head : AdmittedWirePulseStep registry initialBudget payload first second)
      (tail : AdmittedWirePulseTrace registry initialBudget payload second third) :
      AdmittedWirePulseTrace registry initialBudget payload first third

namespace AdmittedWirePulseTrace

/-- Every finite admitted middle trace preserves the Wire/Pulse safe-run envelope. -/
theorem preserves_safeRunState
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {payload : Type}
    {first last : WirePulseSnapshot executor config authority payload}
    (trace : AdmittedWirePulseTrace registry initialBudget payload first last)
    (hSafe : SafeWirePulseSnapshot registry initialBudget first) :
    SafeWirePulseSnapshot registry initialBudget last := by
  induction trace with
  | done snapshot =>
      exact hSafe
  | step head tail ih =>
      exact ih (AdmittedWirePulseStep.preserves_safeRunState head hSafe)

/-- A trace from the recovered run-start snapshot preserves the safe-run envelope. -/
theorem preserves_safeRunState_from_runStart
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {payload : Type}
    {start last : WirePulseSnapshot executor config authority payload}
    [DecidableRel start.G.reaches]
    (trace : AdmittedWirePulseTrace registry initialBudget payload start.recovered last)
    (hSourceValid : SourcePlanningContextValid start.context)
    (hBoundary : _root_.Cortex.Wire.registryBoundary registry start.context.topology)
    (hBridge : WireTopologyDAGBridge start.context.topology start.G)
    (hBudget : start.remainingBudget.le initialBudget)
    (hPersisted : persistedRecoveryPreconditions start.G start.state) :
    SafeWirePulseSnapshot registry initialBudget last := by
  exact
    trace.preserves_safeRunState
      (start.runStart_establishes_safeRunState
        hSourceValid
        hBoundary
        hBridge
        hBudget
        hPersisted)

/-- A safe final snapshot reached by an admitted trace cannot classify as stuck. -/
theorem final_not_stuck
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {payload : Type}
    {first last : WirePulseSnapshot executor config authority payload}
    [DecidableRel last.G.reaches]
    (trace : AdmittedWirePulseTrace registry initialBudget payload first last)
    (hSafe : SafeWirePulseSnapshot registry initialBudget first)
    (stuckState : GraphState (WireNode executor config authority) payload) :
    classifyGraphState last.G last.state ≠ StepResult.stuck stuckState := by
  have hFinalSafe : SafeWirePulseSnapshot registry initialBudget last :=
    trace.preserves_safeRunState hSafe
  exact
    classifyGraphState_not_stuck_of_wellFormed
      last.G
      last.state
      hFinalSafe.pulseWellFormed
      stuckState

/-- A run that starts from persisted recovery preconditions and follows an admitted trace
cannot finish stuck. -/
theorem final_not_stuck_from_runStart
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {payload : Type}
    {start last : WirePulseSnapshot executor config authority payload}
    [DecidableRel start.G.reaches]
    [DecidableRel last.G.reaches]
    (trace : AdmittedWirePulseTrace registry initialBudget payload start.recovered last)
    (hSourceValid : SourcePlanningContextValid start.context)
    (hBoundary : _root_.Cortex.Wire.registryBoundary registry start.context.topology)
    (hBridge : WireTopologyDAGBridge start.context.topology start.G)
    (hBudget : start.remainingBudget.le initialBudget)
    (hPersisted : persistedRecoveryPreconditions start.G start.state)
    (stuckState : GraphState (WireNode executor config authority) payload) :
    classifyGraphState last.G last.state ≠ StepResult.stuck stuckState := by
  have hStartSafe : SafeWirePulseSnapshot registry initialBudget start.recovered :=
    start.runStart_establishes_safeRunState
      hSourceValid
      hBoundary
      hBridge
      hBudget
      hPersisted
  exact trace.final_not_stuck hStartSafe stuckState

end AdmittedWirePulseTrace

end RunTrace

end Cortex.Wire
