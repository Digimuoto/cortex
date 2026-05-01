---
title: "ADR 0038 - Wire Proof-Track Theorem Ledger"
description:
  "Collects the Wire proof-track theorem targets and separates Lean proof work from Haskell
  correspondence obligations."
sidebar:
  label: "0038. Proof ledger"
  order: 38
status: proposed
date: 2026-04-30
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/pure-execution.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - "GitHub #99"
  - "GitHub #103"
  - "GitHub #106"
---

# ADR 0038 - Wire Proof-Track Theorem Ledger

## Status

Proposed - this ADR is the theorem-ledger slice for the Wire boundary-resource ADR stack. It names
the proof obligations that guide the next Lean and Haskell correspondence work without deciding that
the Wire compiler must move into Lean.

## Context

ADRs 0032-0037 define the semantic vocabulary for boundary resources, guarded-affine `select(...)`,
restricted actualization authority, rewrite boundary laws, selected-branch budget policy, and latent
structural control operators.

The proof obligations from those ADRs are intentionally precise, but they are spread across several
documents. The current Lean track also already proves a substantial subset of Wire rewrite and
CorePure obligations, while other claims still depend on Haskell compiler/runtime correspondence or
future runtime policy.

Cortex therefore needs one proof-track ledger that states which theorem targets exist, which layer
owns each target, and which open issue advances it. This is the ADR-A slice from GitHub #103: it
settles what must be proved before deciding whether the compiler remains Haskell-first, becomes a
Lean-specified Haskell implementation, or eventually moves into Lean.

## Decision

Wire proof work should use a theorem ledger that separates four classes of obligations:

1. **Mechanized Lean surfaces** - theorem statements already present under `theory/`.
2. **Immediate Lean theorem targets** - proof-side declarations that can be added before proving
   executable Haskell correspondence.
3. **Haskell correspondence targets** - executable compiler/runtime paths that must produce the
   witnesses consumed by the Lean proof model, usually through tests or a future Lean oracle.
4. **Deferred semantic targets** - obligations that require a later runtime or language decision
   before they should be mechanized.

The ledger is the canonical place to add or retire Wire proof targets. Individual ADRs should state
their semantic obligations, while this ADR records the implementation-facing theorem names,
dependencies, and status.

## Ledger

In the status column, "Mechanized" means the named proof-side declaration has landed for the row's
claim. "Mechanized on the Lean side" emphasizes that the proof-side theorem exists while executable
Haskell correspondence remains a separate open target.

| Area                                   | Theorem or witness target                                                                                                                                                                                                                                                                                             | Runtime or proof counterpart                                                                                                                                                                                                        | Status                                                                                                                                                              |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CorePure output keys                   | `pureNode_evalOutputs_keys_in_outputPorts`, `pureNode_evalOutputs_outputPorts_present`                                                                                                                                                                                                                                | Source pure nodes lower to one native pure task whose successful output map exposes exactly the declared ports.                                                                                                                     | Mechanized.                                                                                                                                                         |
| CorePure where fields                  | `whereStaticFields_sound`, `pureNode_evalWhereEnv_record_hasOnlyFields`, `pureNode_evalWhereEnv_localEnv_match`                                                                                                                                                                                                       | Static `where` discovery is sound for matching runtime environments, and opened fields hide same-named static facts.                                                                                                                | Mechanized.                                                                                                                                                         |
| CorePure lowering                      | `pureNode_lowering_evalOutputs_eq`                                                                                                                                                                                                                                                                                    | Lowered native pure-task configs evaluate like their source pure node in the proof model.                                                                                                                                           | Mechanized.                                                                                                                                                         |
| CorePure value contracts               | `pureNode_evalOutputs_values_satisfy_outputContracts`, `pureNode_evalOutputs_values_satisfy_valueContracts`                                                                                                                                                                                                           | Successful pure outputs propagate abstract output-expression contracts and a first concrete proof-side value-contract table.                                                                                                        | Lean value-contract carrier mechanized; full Wire wrapping remains tracked by GitHub #117.                                                                          |
| CorePure builtin authority             | `closedBuiltinSignature_eq`, `closedBuiltinEnv_authorityFree`                                                                                                                                                                                                                                                         | The proof-side builtin signature mirror contains only pure-value entries; Haskell exposes a separate signature review hook.                                                                                                         | Lean mirror and Haskell signature hook landed; evaluator correspondence remains tracked by GitHub #116.                                                             |
| CorePure static context correspondence | `topLevelBindings_establish_staticContext`                                                                                                                                                                                                                                                                            | Successful proof-side top-level binding evaluation from the empty environment constructs `EnvMatchesStatic`.                                                                                                                        | Lean bridge target mechanized; executable Haskell correspondence remains tracked by GitHub #114.                                                                    |
| CorePure duplicate record fields       | Parser/elaborator witness for duplicate and prefix-conflicting record paths                                                                                                                                                                                                                                           | ADR 0023's duplicate-name discipline prevents admitted record literals from relying on silent overwrite.                                                                                                                            | Runtime preflight and tests landed; parser/elaborator witness remains tracked by GitHub #115.                                                                       |
| Pulse transition envelope              | `SafePulseRunState`, `pulseRecoveryStep_preserves_safeRunState`, `pulseExecutionStep_preserves_safeRunState`, `pulseReplayDeterminism_modulo_fixedOutcomes`                                                                                                                                                           | Fixed-topology Pulse recovery and admissible frontier fact folds after recovery normalization preserve structural `wellFormedGraphState`, classify without stuck, and replay fixed distinct-node facts independently of fold order. | Mechanized on the Lean side; executable correspondence has proof-shaped GraphRuntime tests.                                                                         |
| Rewrite admission                      | `planGraphRewriteChecks_admissible`, `runtimePlannerConstruction_admissible`, `constructedPlannedRewriteDelta_admissible_of_inputs`                                                                                                                                                                                   | Runtime-shaped planner witnesses instantiate abstract admissible rewrites.                                                                                                                                                          | Mechanized on the Lean side.                                                                                                                                        |
| Constructed chains                     | `ConstructedPlanningChain.toRewriteChain`, `.preserves_sourceValid`, `.steps_le_rewriteOps`, `.finalBudget_le_initial`                                                                                                                                                                                                | Finite constructed chains erase to abstract rewrite chains and preserve source validity and budget bounds.                                                                                                                          | Mechanized on the Lean side.                                                                                                                                        |
| Registry boundary                      | `constructedPlannedRewriteDelta_preserves_registryBoundary`, `constructedPlanningChain_preserves_registryBoundary_of_constructedDelta`                                                                                                                                                                                | Constructed deltas and chains preserve `registryBoundary registry` from bundled added-node and added-edge admission obligations.                                                                                                    | Mechanized on the Lean side; runtime witness production remains #110.                                                                                               |
| Planner/runtime correspondence         | `planGraphRewrite_produces_RuntimeConstructionInputs` and `admitRewriteDelta_produces_AdmittedRewriteDelta`                                                                                                                                                                                                           | Haskell `planGraphRewrite`, `consumeRewriteBudget`, and `admitRewriteDelta` produce the Lean witness fields.                                                                                                                        | Open; tracked by GitHub #110.                                                                                                                                       |
| Boundary resources                     | `resourceConsumption_faithful`, `rewriteSlot_spent_at_most_once`, `boundaryPreserved`                                                                                                                                                                                                                                 | Valid operations consume declared boundary resources, spend the anchor rewrite slot at most once, and preserve the exposed boundary.                                                                                                | Target named by ADR 0032; proof decomposition still open.                                                                                                           |
| Rewrite boundary laws                  | `substitution_preserves_boundary`, `appendContinuation_preserves_boundary`                                                                                                                                                                                                                                            | Replacement and append are separate boundary laws even when both pass through runtime rewrite admission.                                                                                                                            | Target named by ADR 0035; depends on the resource model.                                                                                                            |
| Select actualization                   | `LatentBranchFamily.fragmentsValid`, `.fragmentsPairwiseDisjoint`, `selectActualize_lowers_to_appendAfter`, `selectActualize_runtimeRewrite_spec_eq`, `selectActualize_admissible_of_constructedStep`, `selectActualize_preserves_registryBoundary`                                                                   | Certified latent families carry per-fragment validity and disjointness; the selected arm then lowers definitionally to the current retained-owner `AppendAfter` realization and inherits existing admission and boundary proofs.    | Mechanized on the Lean side; runtime correspondence remains tracked by GitHub #108.                                                                                 |
| Unselected branches                    | `selectActualize_unselected_not_in_selectedFragment`                                                                                                                                                                                                                                                                  | Unselected branch fragments are outside the selected raw fragment by the certified-family disjointness invariant.                                                                                                                   | Mechanized on the Lean side; final-topology and recovery integration remain tracked by GitHub #108.                                                                 |
| Latent branch budget                   | `selectActualize_consumes_selected_cost`                                                                                                                                                                                                                                                                              | The admitted selected-arm constructed delta consumes runtime rewrite budget under ADR 0036's selected-cost policy.                                                                                                                  | Mechanized on the Lean side; runtime correspondence remains tracked by GitHub #108.                                                                                 |
| CorePure execution facts               | `corePureExecutionStep_preserves_safeRunState`                                                                                                                                                                                                                                                                        | Successful admitted CorePure output evaluation can be emitted as a Pulse success fact, retaining output-port and proof-side value-contract evidence while preserving the safe-run envelope.                                         | Mechanized on the Lean side; runtime fact production remains a Haskell correspondence target.                                                                       |
| Wire/Pulse safe-run envelope           | `WireTopologyDAGBridge`, `MaterializedPulseState`, `SafeWireRunState`, `wirePulseRecoveryStep_establishes_safeRunState`, `wirePulseRecoveryStep_preserves_safeRunState`, `wirePulseExecutionStep_preserves_safeRunState`, `wirePulseAdmittedRewrite_preserves_safeRunState`, `selectActualize_preserves_safeRunState` | Wire planning validity, registry boundary, rewrite budget bounds, and Pulse `wellFormedGraphState` move together across crash recovery, fixed-result execution, constructed rewrites, and selected-arm actualization.               | Mechanized on the Lean side; graph-to-DAG construction, executable materialization witnesses, and retained-state continuity remain separate correspondence targets. |
| Fixed-result replay                    | `wirePulseExecutionFacts_replay_deterministic`                                                                                                                                                                                                                                                                        | Given the same external frontier facts for distinct nodes, recovered state is invariant under fact order.                                                                                                                           | Mechanized for the fixed-topology Pulse/Wire envelope.                                                                                                              |
| Latent recovery                        | `selectedBranch_recovery_deterministic`                                                                                                                                                                                                                                                                               | Recovery replays the same admitted selected branch and never materializes unselected alternatives.                                                                                                                                  | Deferred until the durable selection/rewrite record boundary is settled.                                                                                            |

## Ordering

The next implementation proof work should proceed in this order:

1. **CorePure value and authority bridge** - continue from the first abstract contract theorem, the
   closed-builtin proof hook, the duplicate-record preflight, and the static-context Lean bridge
   toward executable Haskell correspondence.
2. **Planner/runtime correspondence** - connect Haskell planner, registry-boundary admission, and
   budget admission paths to the Lean witness structures.
3. **Graph-to-DAG, SelectActualize, and materialization correspondence** - construct
   `WireTopologyDAGBridge` from accepted topologies, connect selected-arm actualization to
   executable runtime witnesses, and make runtime materialization produce `MaterializedPulseState`.
4. **Recovery determinism** - prove durable selected-branch replay properties after the runtime
   record boundary is sharp enough to state them.

This order is intentionally asymmetric: proof-side Lean targets should be named before Haskell
correspondence attempts to produce their witnesses.

## Consequences

### Positive

- Prevents proof obligations from being lost across ADRs, issues, and `theory/README.md`.
- Makes the Lean/Haskell boundary explicit without prematurely moving the compiler into Lean.
- Gives future proof PRs a canonical place to add, rename, discharge, or defer theorem targets.
- Keeps `select(...)` proof work tied to existing rewrite admission instead of inventing a parallel
  proof stack.

### Negative

- Adds one more internal ADR that must be kept current as theorem targets land or change names.
- Some theorem names in this ledger are target names, not current declarations.
- Haskell correspondence remains a testing/oracle obligation until Cortex chooses a stronger
  compiler-spec authority model.

### Obligations

- When a listed theorem target lands, update this ADR or the Track 3 proof summary so the status is
  no longer stale.
- New Wire proof work should link to the relevant ledger row and issue.
- If GitHub #103 later chooses Lean as compiler spec or implementation, this ADR should be updated
  or superseded to reflect the new authority model.

## Alternatives considered

- **Keep the proof roadmap only in `theory/README.md`** - rejected because the README should
  summarize landed proof surfaces, not be the canonical decision record for future theorem targets.
- **Track every proof target only in GitHub issues** - rejected because issues are active planning
  state, while the theorem split is an architectural decision.
- **Decide the Lean compiler question now** - rejected because the theorem list should come before
  choosing Haskell-first, Lean-spec, or Lean-implementation authority.

## Related

- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/Wire/pure-execution.md](../Reference/Wire/pure-execution.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [0010-wire-closed-authority-and-three-layer-stack.md](0010-wire-closed-authority-and-three-layer-stack.md)
- [0023-corepure-expression-surface.md](0023-corepure-expression-surface.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- GitHub #99
- GitHub #103
- GitHub #106
