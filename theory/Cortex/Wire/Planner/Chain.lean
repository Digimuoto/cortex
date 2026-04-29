import Cortex.Wire.Planner.Construction

/-!
## Overview

Runtime-shaped chains for constructed Wire planner rewrites.

## Context

`Cortex.Wire.Planner.Construction` proves that one runtime-shaped planner
step can construct an admissible proof-carrying rewrite and carry the
`SourcePlanningContextValid` invariant to the next planned topology. This
module lifts that single-step surface to finite chains over `PlanningContext`.

The abstraction remains proof-side. It does not execute Haskell and does not
prove that `planGraphRewrite` produces the witnesses. Instead, every chain
step carries the same runtime-shaped witnesses used by the single-step
construction: source validity, namespace discipline, anchor membership, raw
subgraph validity, inserted-depth agreement, final acyclicity, budget
admission, and caller-supplied contract preservation.

## Theorem Split

The page defines constructed planning steps, constructed planning chains,
the conversion from constructed chains to abstract `RewriteChain`s, and the
chain-level preservation theorems for source validity, budget, generic
contracts, and the registry boundary specialization.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Constructed Planning Steps -/

section ConstructedPlanningStep

variable {node : Type}
variable [DecidableEq node]

/-- `ConstructedPlanningStep` is one runtime-shaped planned rewrite.

The step starts from a `PlanningContext`, consumes a `RewriteBudget`, and uses
the concrete planner construction from `Cortex.Wire.Planner.Construction`.
It keeps the caller-supplied contract preservation witness because contract
meaning is external to the generic planner model. -/
structure ConstructedPlanningStep
    (policy : RuntimeNamespacePolicy node)
    (contractOk : Graph node → Prop)
    (context : PlanningContext node)
    (budget : RewriteBudget)
    (rawRewrite : GraphRewrite node)
    (insertedDepth : Nat)
    (remaining : RewriteBudget) :
    Prop where
  /-- Runtime-shaped construction inputs for this step. -/
  inputs : RuntimeConstructionInputs policy context rawRewrite insertedDepth
  /-- Budget admission for the constructed delta. -/
  admitted :
    AdmittedRewriteDelta
      budget
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth)
      remaining
  /-- Caller-specific contract preservation for this planned rewrite. -/
  contractPreserved :
    ∀ g,
      denote g = denote context.topology →
        contractOk g →
          contractOk
            (constructedPlannedRewriteDelta
              policy
              context
              rawRewrite
              insertedDepth).topology

namespace ConstructedPlanningStep

variable {policy : RuntimeNamespacePolicy node}
variable {contractOk : Graph node → Prop}
variable {context : PlanningContext node}
variable {budget remaining : RewriteBudget}
variable {rawRewrite : GraphRewrite node}
variable {insertedDepth : Nat}

/-- The constructed planned delta for this step. -/
noncomputable def delta
    (_step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    PlannedRewriteDelta node :=
  constructedPlannedRewriteDelta policy context rawRewrite insertedDepth

/-- The next planning context produced by this step. -/
noncomputable def nextContext
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    PlanningContext node :=
  { topology := step.delta.topology
    definitions := step.delta.definitions }

/-- The proof-carrying rewrite induced by this constructed planning step. -/
noncomputable def toRewrite
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    Rewrite node contractOk :=
  step.delta.toRewrite
    context.topology
    (plannedRewriteSafety_of_checks
      (runtimePlannerConstruction_planGraphRewriteChecks
        (constructedPlannedRewriteDelta_runtimePlannerConstruction
          step.inputs.toValidation))
      step.contractPreserved)

/-- Constructed planning steps derive the older validation bundle. -/
theorem toValidation
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    RuntimeConstructionValidation policy context rawRewrite insertedDepth :=
  step.inputs.toValidation

/-- Constructed planning steps instantiate the abstract admissibility predicate. -/
theorem toAdmissible
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    admissible step.toRewrite context.topology budget :=
  constructedPlannedRewriteDelta_admissible_of_inputs
    step.inputs
    step.admitted
    step.contractPreserved

/-- Constructed planning steps carry source validity to their next context. -/
theorem toNextSourceValid
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    SourcePlanningContextValid step.nextContext :=
  step.inputs.toNextSourceValid

/-- The induced proof-carrying rewrite applies to the context it was planned against. -/
theorem apply_eq_some
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    step.toRewrite.apply context.topology = some step.nextContext.topology := by
  simp only
    [ toRewrite
    , nextContext
    , delta
    , PlannedRewriteDelta.toRewrite
    , if_true
    ]

/-- The admitted remaining budget matches the induced rewrite's consumed budget. -/
theorem remaining_eq_consume
    (step :
      ConstructedPlanningStep
        policy
        contractOk
        context
        budget
        rawRewrite
        insertedDepth
        remaining) :
    remaining = budget.consume step.toRewrite.cost := by
  simpa only
    [ toRewrite
    , delta
    , PlannedRewriteDelta.toRewrite
    ] using step.admitted.remaining_eq

end ConstructedPlanningStep

end ConstructedPlanningStep

/-! ## Constructed Planning Chains -/

section ConstructedPlanningChain

variable {node : Type}
variable [DecidableEq node]

/-- `ConstructedPlanningChain` is a finite sequence of runtime-shaped planner steps.

The chain indexes current context, current budget, final context, final budget,
and step count. Each step constructs the next `PlanningContext` from the
planned delta's topology and definition domain before continuing. -/
inductive ConstructedPlanningChain
    (policy : RuntimeNamespacePolicy node)
    (contractOk : Graph node → Prop) :
    PlanningContext node →
      RewriteBudget →
        PlanningContext node →
          RewriteBudget →
            Nat →
              Prop where
  | done {context : PlanningContext node} {budget : RewriteBudget} :
      ConstructedPlanningChain policy contractOk context budget context budget 0
  | step
      {context finalContext : PlanningContext node}
      {budget remaining finalBudget : RewriteBudget}
      {rawRewrite : GraphRewrite node}
      {insertedDepth steps : Nat}
      (planningStep :
        ConstructedPlanningStep
          policy
          contractOk
          context
          budget
          rawRewrite
          insertedDepth
          remaining)
      (tail :
        ConstructedPlanningChain
          policy
          contractOk
          planningStep.nextContext
          remaining
          finalContext
          finalBudget
          steps) :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        (Nat.succ steps)

namespace ConstructedPlanningChain

variable {policy : RuntimeNamespacePolicy node}
variable {contractOk : Graph node → Prop}
variable {context finalContext : PlanningContext node}
variable {budget finalBudget : RewriteBudget}
variable {steps : Nat}

/-- Constructed planner chains erase to abstract proof-carrying rewrite chains. -/
theorem toRewriteChain
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps) :
    RewriteChain
      contractOk
      context.topology
      budget
      finalContext.topology
      finalBudget
      steps := by
  induction chain with
  | done =>
      exact RewriteChain.done
  | step planningStep _tail ih =>
      exact
        RewriteChain.step
          planningStep.toRewrite
          planningStep.toAdmissible
          planningStep.apply_eq_some
          planningStep.remaining_eq_consume
          ih

/-- Constructed planner chains preserve the source-valid planning-context invariant. -/
theorem preserves_sourceValid
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps)
    (hSource : SourcePlanningContextValid context) :
    SourcePlanningContextValid finalContext := by
  induction chain with
  | done =>
      exact hSource
  | step planningStep _tail ih =>
      exact ih planningStep.toNextSourceValid

/-- Non-empty constructed planner chains expose terminal source validity directly.

The initial source-validity hypothesis is only needed by the empty chain case;
once at least one constructed step exists, that step's runtime inputs already
carry the invariant to the tail. -/
theorem terminal_sourceValid_of_nonempty
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        (Nat.succ steps)) :
    SourcePlanningContextValid finalContext := by
  cases chain with
  | step planningStep tail =>
      exact tail.preserves_sourceValid planningStep.toNextSourceValid

/-- Non-empty constructed planner chains expose terminal acyclicity directly.

This is the acyclicity projection of `terminal_sourceValid_of_nonempty`;
the first constructed step supplies the source-valid tail input. -/
theorem terminal_acyclic_of_nonempty
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        (Nat.succ steps)) :
    Acyclic finalContext.topology :=
  chain.terminal_sourceValid_of_nonempty.sourceAcyclic

/-- Constructed planner chain length is bounded by the initial rewrite-operation budget. -/
theorem steps_le_rewriteOps
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps) :
    steps ≤ budget.rewriteOps :=
  rewriteChain_steps_le_rewriteOps chain.toRewriteChain

/-- Constructed planner chains never replenish rewrite budget. -/
theorem finalBudget_le_initial
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps) :
    finalBudget.le budget :=
  rewriteChain_finalBudget_le_initial chain.toRewriteChain

/-- Constructed planner chains preserve the caller-supplied contract predicate. -/
theorem preserves_contracts
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps)
    (hContracts : contractOk context.topology) :
    contractOk finalContext.topology :=
  rewriteChain_preserves_contracts chain.toRewriteChain hContracts

/-- Constructed planner chains preserve acyclicity of the materialized topology. -/
theorem preserves_acyclic
    (chain :
      ConstructedPlanningChain
        policy
        contractOk
        context
        budget
        finalContext
        finalBudget
        steps)
    (hAcyclic : Acyclic context.topology) :
    Acyclic finalContext.topology :=
  rewriteChain_preserves_acyclic chain.toRewriteChain hAcyclic

end ConstructedPlanningChain

end ConstructedPlanningChain

/-! ## Registry Boundary Specialization -/

section RegistryBoundary

variable {executor config contract authority : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

/-- Constructed planner chains preserve the Wire registry boundary. -/
theorem constructedPlanningChain_preserves_registryBoundary
    (registry : ExecutorRegistry executor config contract authority)
    {policy :
      RuntimeNamespacePolicy (StagedExecutorNode executor config authority)}
    {context finalContext :
      PlanningContext (StagedExecutorNode executor config authority)}
    {budget finalBudget : RewriteBudget}
    {steps : Nat}
    (chain :
      ConstructedPlanningChain
        policy
        (registryBoundary registry)
        context
        budget
        finalContext
        finalBudget
        steps)
    (hBoundary : registryBoundary registry context.topology) :
    registryBoundary registry finalContext.topology :=
  rewriteChain_preserves_registryBoundary registry chain.toRewriteChain hBoundary

end RegistryBoundary

end Cortex.Wire
