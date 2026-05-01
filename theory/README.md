# Cortex theory

Lean 4 mechanization of the Cortex substrate. This directory builds as its own Lake project
(`lakefile.lean`, `lean-toolchain`) and is wired into the repo's nix flake under
`packages.cortex-theory` via `nix/lean.nix`.

The point of having a Lean track at all is to turn the substrate guarantees from prose into proof:

- Wire / Graph laws aren't conventions — they're theorems.
- Pulse frontier safety isn't a code review property — it's a mechanized invariant.
- Rewrite admission isn't a runtime check we hope is correct — it's a soundness theorem we
  discharge.
- Pulse determinism modulo external sparks is the audit-trail property that makes runs replayable.

Together these put the substrate's correctness story under machine-checked assurance. Downstream
model-backed libraries such as Logos may remain stochastic; the substrate they run on does not.

## Tracks

The five tracks are sketched below. Each track begins as an explicit obligation surface; completed
slices replace scaffold assumptions with theorems, while unfinished tracks keep proof debt visible.

### Track 1 — Graph algebra (Mokhov)

`Cortex.Graph.Core` defines the inductive `Graph α` with constructors `empty`, `vertex`, `overlay`,
`connect`. `Cortex.Graph.Relation` defines the finite relation denotation used by the Haskell
`toRelation` implementation and proves the Mokhov laws on that denotation with mathlib `Finset`s.
`Cortex.Graph.Laws` now exposes the AST-facing laws as theorems over denotational equality
(`GraphEq`), because raw syntax trees are not definitionally equal. `Cortex.Graph.Quotient` defines
`AlgGraph α`, the quotient of raw graph expressions by `GraphEq`, and lifts the same laws to
ordinary equality on that algebraic carrier. `Cortex.Graph.Safety` defines the graph-safety bridge
shared by later tracks: relation paths, relation and graph acyclicity, endpoint closure for denoted
Mokhov graphs, a runtime-style boolean edge predicate, and quotient-stable acyclicity facts.

**Headline obligation:** `connect_decomposition` (`g · h · k = g · h ⊕ g · k ⊕ h · k`). This is what
licenses circuit simplification and the executor's compatibility-edge derivation. The relation-level
theorem, denotational AST theorem, and quotient-equality theorem now exist.

Mechanized bridge results now include:

- `Relation.Path`, `Relation.Acyclic`, `GraphPath`, and `GraphAcyclic`: a canonical reachability and
  acyclicity vocabulary for downstream Pulse and Wire proofs.
- `Relation.edgeBool`, `Relation.edgeBool_true_iff`, `Relation.edgeBool_source_mem`, and
  `Relation.edgeBool_target_mem`: the finite relation edge predicate can be consumed by
  runtime-style boolean-edge models while preserving endpoint membership.
- `Cortex.Pulse.EdgePath.edgeBool_iff_relationPath`, `Cortex.Pulse.DAG.ofRelation`,
  `Cortex.Pulse.DAG.ofRelation_edge_true_iff`, and `Cortex.Pulse.DAG.ofRelation_reaches_iff_path`:
  endpoint-closed acyclic relations instantiate the fixed-topology Pulse DAG surface.
- `Cortex.Wire.graphPath_iff_graphSafetyPath` and `Cortex.Wire.acyclic_iff_graphSafetyAcyclic`:
  Wire's existing rewrite path and acyclicity predicates are propositionally equivalent to the
  canonical graph-safety vocabulary.
- `Relation.empty_edgeEndpointsInVertices`, `Relation.vertex_edgeEndpointsInVertices`,
  `Relation.overlay_edgeEndpointsInVertices`, `Relation.connect_edgeEndpointsInVertices`, and
  `denote_edgeEndpointsInVertices`: every denoted Mokhov graph relation is endpoint-closed.
- `graphPath_source_mem`, `graphPath_target_mem`, `GraphEq.acyclic`, `GraphEq.acyclic_iff`,
  `AlgGraph.Acyclic`, `AlgGraph.acyclic_ofGraph`, and `AlgGraph.acyclic_congr`: graph safety facts
  are stable across denotational equality and quotient equality.

### Track 2 — Fixed-topology Pulse kernel

`Cortex.Pulse.DAG`, `State`, `Fact`, `Frontier`, `Closure`, `Validity`, and `Recovery` model the
Paper 1 fixed-topology staged-reduction kernel. The current model is extensional: a finite node
type, an edge-derived DAG reachability relation, abstract payloads, node-local facts,
reachability-level readiness, direct-predecessor runtime readiness, topology-domain validity, and
failure closure over the DAG. It avoids runtime UUID/database shapes and keeps payload and failure
details abstract.

Mechanized results now include:

- `frontier_only_ready`: frontier membership implies readiness.
- `frontier_antichain`: frontier nodes are mutually incomparable by strict reachability.
- `NodeResult.applyNodeFact_comm`: node-local facts for distinct nodes commute.
- `NodeResult.applyNodeFacts_perm_invariant`: disjoint-key fact folds are invariant under list
  permutation.
- `propagateFailure_extensive`: propagation preserves failed nodes.
- `propagateFailure_monotone`: failure propagation is monotone over pointwise failure-growth.
- `propagateFailure_failureClosureComplete`: one propagation pass closes failure over propagatable
  descendants.
- `propagateFailure_preserves_topologyDomain`: propagation preserves the absence of off-topology
  durable state.
- `propagateFailure_preserves_outputsRespectStatuses`: propagation preserves output ownership.
- `propagateFailure_preserves_outputsCompleteForStatuses`: propagation preserves required outputs
  for completed and rewritten nodes.
- `propagateFailure_idempotent`: failure propagation is idempotent.
- `directReady_sound`: executable direct-predecessor readiness implies proof-level reachability
  readiness under causal-history closure.
- `readyNodes_eq_directReadyNodes`: proof and runtime frontiers coincide under closure and
  causal-history invariants.
- `NodeResult.Admissible`: node facts must target the topology and come from the executable frontier
  before preservation theorems apply.
- `frontierFacts_recovered_wellFormedGraphState`: admissible fact folds become structurally
  well-formed again after recovery normalization and failure closure.
- `persistence_safety`: recovered states are structurally well-formed, conditional on explicit
  persisted topology-domain, output ownership, output-completeness, and causal-history preconditions
  that recovery preserves.
- `classifyClosedGraphState_exhaustive_of_wellFormed`: well-formed closed states classify into
  failed, progressing, completed, or suspended branches.
- `classifyGraphState_not_stuck_of_wellFormed`: well-formed states cannot classify as stuck after
  the runtime closure step.
- `SafePulseRunState`: the reusable Track 2 structural run-safety surface, kept as an abbreviation
  for `wellFormedGraphState` rather than a competing invariant. It is not a progress predicate by
  itself.
- `pulseRecoveryStep_preserves_safeRunState` and `pulseExecutionStep_preserves_safeRunState`:
  recovery and admissible frontier fact folds after recovery normalization preserve the structural
  safe-state predicate.
- `pulseReplayDeterminism_modulo_fixedOutcomes`: fixed node-local outcomes classify identically
  after any permutation of a distinct-node fact list; admissibility is a safety-preservation
  hypothesis, not part of this equality theorem.

The Paper 1 Lean-Haskell modeling boundary is documented in
`docs/Publications/Paper-1-staged-reduction/lean-haskell-boundary.md`. The executable resume path
now validates that the post-decode, post-reconciliation, post-rewrite-materialization, and
post-signal-resolution resume input state satisfies the Haskell counterpart of the persisted
recovery preconditions, then classifies the reset-and-failure-propagated recovered state before
continuing from materialized graph state.

### Track 3 — Rewrite soundness

`Cortex.Wire.Pure` models the proof-facing CorePure subset for pure output equations: deterministic
integer/boolean/record evaluation, static `where`-field discovery soundness, an expression ADT with
no authority-bearing constructors, and one-source-node-to-one-native-pure-task lowering.
`Cortex.Wire.Registry` models the `@` executor boundary as pure staging of registered authority:
executor lookup, config validation, registry-wide contract vocabulary, endpoint compatibility,
effect-class policy, output validation, and host authority. `Cortex.Wire.Rewrite` defines the
proof-carrying rewrite certificate surface: an admitted `Rewrite` carries preservation evidence for
graph acyclicity, the caller-supplied contract predicate, and consumption of the five-dimensional
runtime rewrite budget. `Cortex.Wire.Admission` now models the proof-side bridge from
`planGraphRewrite` and `admitRewriteDelta`: anchor existence, anchor definition coverage,
inserted-subgraph validity, entry/exit non-emptiness, orphan-freedom, denotational equality to a
relation-level final-topology construction, relation-diff equations, anchor-disposition coupling,
structural cost equations for every budget dimension, the final definition-domain update equation,
final-definition coverage, final acyclicity, and pointwise budget consumption. `Cortex.Wire.Planner`
names the executable-planner correspondence boundary: subgraph namespacing, namespace discipline,
the AST-to-relation mapping lemma, and the construction-to-checks theorem used to feed
runtime-shaped planner equations into `PlanGraphRewriteChecks`. `Cortex.Wire.Planner.Construction`
adds a proof-side planner construction: it realizes the relation-level final topology as a graph
representative, computes delta diff sets and costs from that relation, and proves the constructed
delta establishes the planner-construction bridge under the remaining runtime validation witnesses.

Mechanized results now include:

- `pureEvaluation_deterministic`: CorePure subset evaluation is deterministic because evaluation is
  a pure function over an explicit environment.
- `where_staticFields_record`, `where_staticFields_merge`, and `where_staticFields_let`: static
  field discovery computes record-literal fields, merge unions, and ADR 0031-style local `let`
  transparency explicitly.
- `whereStaticFields_sound`, `evalBindingsNoDuplicate_preserves_static_context`, and
  `evalBindings_preserves_static_context`: static `where` discovery is sound for runtime
  environments that match the static context when local `let` binders do not shadow statically known
  module-level records.
- `pureOutput_keys_match_declaredPorts`, `where_noInputCollision`, `pureNode_whereFields_known`, and
  `pureNode_lowers_to_one_nativeTask`: admitted source pure nodes lower to one native pure task
  while preserving output equations and the statically checked `where` boundary.
- `pureNode_bindings_noShadow`, `pureNode_where_letSafe`, `pureNode_where_hasOnlyFields`,
  `pureNode_evalWhereEnv_record_hasOnlyFields`, `openRecordIntoEnv_preserves_hidden_static_context`,
  and `pureNode_evalWhereEnv_localEnv_match`: admitted nodes carry the no-shadow obligations needed
  to apply static `where` soundness through the actual `evalWhereEnv` call site, while opened
  `where` fields hide any same-named static record facts.
- `evalOutputEquationValues_preserves_names`, `evalOutputEquations_keys_subset`,
  `evalOutputEquations_keys_present`, `pureNode_evalOutputs_keys_in_outputPorts`, and
  `pureNode_evalOutputs_outputPorts_present`: successful proof-side pure-node evaluation exposes
  exactly the declared output ports.
- `closedBuiltinSignature_eq` and `closedBuiltinEnv_authorityFree`: the proof-side closed CorePure
  builtin signature mirror contains only pure-value builtin entries. The Haskell evaluator parity
  remains a runtime review-hook obligation, not a theorem in this file.
- `topLevelBinding_value_hasOnlyFields`, `evalBindings_establish_staticContext`, and
  `topLevelBindings_establish_staticContext`: top-level binding evaluation from the empty
  environment constructs an `EnvMatchesStatic` witness for the static context established by those
  bindings.
- `OutputExpressionsSatisfyContracts`, `evalOutputEquationValues_satisfy_outputContracts`,
  `evalOutputEquations_values_satisfy_outputContracts`,
  `pureNode_evalOutputs_values_satisfy_outputContracts`, `ValueContract`, `outputValueContractOk`,
  and `pureNode_evalOutputs_values_satisfy_valueContracts`: successful proof-side pure-node
  evaluation can lift an abstract per-output contract relation, and a first concrete value-contract
  carrier, from output expressions to the final output lookup.
- `pureNode_lowering_evalOutputs_eq`: lowered native pure-task configs evaluate to the same
  proof-side output lookup function as their source pure nodes.
- `plannedRewriteSafety_of_checks`: runtime planning checks supply the acyclicity and positive
  rewrite-operation parts of a proof-carrying rewrite.
- `planGraphRewriteChecks_topology_matches`: planning checks expose the final-topology construction
  equation.
- `planGraphRewriteChecks_topologyDiffMatches`: planning checks expose relation-diff equations for
  new nodes, removed nodes, and added edges.
- `planGraphRewriteChecks_costMatches`: planning checks expose structural cost equations for added
  nodes, added edges, inserted depth, frontier delta, and rewrite-operation budget.
- `planGraphRewriteChecks_anchorDispositionMatches`: planning checks expose anchor-disposition
  agreement and final anchor membership.
- `planGraphRewriteChecks_definitions_eq`: planning checks expose the exact definition-domain update
  formula for removed versus retained anchors.
- `admittedRewriteDelta_remaining_le_initial`: budget admission never replenishes any structural
  budget dimension.
- `admittedRewriteDelta_rewriteOps_bound`: the runtime rewrite-operation bound is exposed for chain
  termination.
- `admittedPlannedRewrite_admissible`: an admitted planned delta instantiates the abstract
  `admissible` predicate.
- `planGraphRewriteChecks_admissible`: runtime planning checks plus budget admission produce an
  abstract admissible rewrite.
- `namespaceGraphRewrite_anchor` and `namespaceGraphRewrite_anchorDisposition`: runtime namespacing
  changes the inserted subgraph but not the anchor or removal/retention decision.
- `RuntimeNamespacePolicy`: the proof-side model of the executable namespace function, its
  fixed-anchor injectivity fact, and the local-node syntax predicate accepted by the runtime
  namespace validator.
- `denote_mapGraph`: mapping the graph AST and then denoting it agrees with relation-level mapping.
- `namespaceSubgraphSpec_preserves_valid`: injective namespacing preserves inserted-subgraph
  validity.
- `RuntimeNodeListMatches.card_eq_length`: duplicate-free runtime entry lists agree with the
  `Finset` cardinalities used by frontier-delta cost proofs.
- `runtimePlannerConstruction_planGraphRewriteChecks`: proof-shaped executable planner equations
  establish the planning contract consumed by the admission bridge.
- `runtimePlannerConstruction_local_allowed` and `runtimePlannerConstruction_namespaced_fresh`:
  runtime planner construction exposes the namespace validator's local syntax and freshness
  obligations.
- `runtimePlannerConstruction_admissible`: runtime planner construction plus budget admission
  directly instantiates the abstract admissible-rewrite predicate.
- `Relation.EdgeEndpointsInVertices`, `graphOfRelation`, and `denote_graphOfRelation`: endpoint-
  closed finite relations can be realized by graph expressions without quotienting raw graph syntax.
- `RuntimeNodeId.namespacePolicy`: structured namespace segments model the runtime `NodeId`
  namespacing discipline with fixed-anchor injectivity and local-id syntax.
- `plannedFinalRelation_edgeEndpointsInVertices`: the relation-level planner output is always
  endpoint-closed, so it has a graph representative.
- `SourcePlanningContextValid` and `RuntimeConstructionInputs`: source topology acyclicity and
  definition-domain coverage are named planner-input invariants, rather than repeated free fields.
- `constructedPlannedRewriteDelta_finalDefinitionsCover`: final definition coverage is derived from
  source definition coverage, raw subgraph validity, and the construction equations.
- `RuntimeConstructionInputs.toValidation`: runtime-shaped planner inputs derive the older
  `RuntimeConstructionValidation` bundle.
- `RuntimeConstructionInputs.toNextSourceValid`: runtime-shaped planner inputs carry the
  source-valid planning-context invariant to the next planned topology and definition domain.
- `constructedPlannedRewriteDelta_runtimePlannerConstruction`: the proof-side planner construction
  computes the final topology, relation diffs, entry/exit sets, definition update, and structural
  costs needed by `RuntimePlannerConstruction`; anchor absence for replacement rewrites is derived
  from namespace freshness plus source-topology acyclicity.
- `RegistryBoundaryDeltaAdmitted`, `registryBoundary_preserved_of_addedNodes_addedEdges_admitted`,
  and `constructedPlannedRewriteDelta_preserves_registryBoundary`: constructed planner deltas
  preserve the registry boundary from a bundled added-node and added-edge admission payload, without
  an arbitrary caller-supplied preservation witness for `registryBoundary`.
- `constructedPlannedRewriteDelta_registryBoundaryContractPreserved`,
  `ConstructedPlanningStep.ofRegistryBoundary`, `.registryBoundaryPreserved`,
  `.registryBoundaryContractPreserved`, `ConstructedPlanningChain.RegistryBoundaryDeltasAdmitted`,
  and `constructedPlanningChain_preserves_registryBoundary_of_constructedDelta`: registry-boundary
  constructed steps and chains can discharge the generic `contractPreserved` slot from constructed
  delta admission obligations.
- `constructedPlannedRewriteDelta_admissible`: the constructed delta, runtime validation witnesses,
  and budget admission instantiate the abstract admissible-rewrite predicate.
- `constructedPlannedRewriteDelta_admissible_of_inputs`: the source-valid planner input bundle,
  constructed delta, and budget admission directly instantiate the abstract admissible-rewrite
  predicate.
- `ConstructedPlanningStep` and `ConstructedPlanningChain`: runtime-shaped constructed planner steps
  lift to finite chains over `PlanningContext`, carrying constructed topologies and definition
  domains from one step to the next.
- `ConstructedPlanningChain.toRewriteChain`, `.preserves_sourceValid`,
  `.terminal_sourceValid_of_nonempty`, `.terminal_acyclic_of_nonempty`, `.steps_le_rewriteOps`,
  `.finalBudget_le_initial`, `.preserves_contracts`, and
  `constructedPlanningChain_preserves_registryBoundary`: constructed planner chains erase to the
  abstract `RewriteChain` model while preserving source validity, budget bounds, generic contracts,
  and registry-boundary invariants. The stronger constructed-delta registry theorem above avoids
  making the headline boundary theorem depend on arbitrary caller preservation proofs.
- `LatentBranchFamily.fragmentsValid`, `.fragmentsPairwiseDisjoint`, `SelectActualize`,
  `selectActualize_selectedFragment_valid`, `selectActualize_lowers_to_appendAfter`,
  `selectActualize_admissible_of_constructedStep`,
  `selectActualize_unselected_not_in_selectedFragment`, `selectActualize_runtimeRewrite_spec_eq`,
  `selectActualize_consumes_selected_cost`,
  `selectActualize_namespaced_selected_subgraph_contained`, and
  `selectActualize_preserves_registryBoundary`: proof-side `select(...)` actualization is modeled as
  certified latent structural control whose selected arm lowers definitionally to the existing
  retained-owner `appendAfter` rewrite surface, reuses constructed-step admission, consumes the
  constructed selected-arm delta cost, carries the namespaced selected subgraph into the admission
  checks, inherits constructed-delta registry-boundary preservation, and keeps unselected branch
  fragments outside the selected raw fragment through the family disjointness invariant.
- `rewriteChain_preserves_acyclic`, `rewriteChain_preserves_contracts`,
  `rewriteChain_preserves_registryBoundary`, `rewriteChain_steps_le_rewriteOps`, and
  `rewriteChain_finalBudget_le_initial`: local rewrite certificates lift across finite chains.

The remaining Track 3 obligations are now tracked in
`docs/ADRs/0038-wire-proof-track-theorem-ledger.md`. The next proof slices are:

- Haskell correspondence for CorePure static-context construction, builtin authority review hooks,
  duplicate record-path admission before every compiler surface, and full Wire output contract
  wrapping;
- Haskell planner and budget-admission correspondence for `RuntimeConstructionInputs`,
  added-node/added-edge registry admission, and `AdmittedRewriteDelta`;
- `SelectActualize` executable witness integration and later durable selected-branch recovery
  determinism.

This is the "sandbox by proof" story for dynamic graph rewriting. Rewrites may transform topology,
but chain-level preservation requires them to stay inside the registry boundary documented in
`docs/Reference/Wire/executors-and-alphabet.md`.

### Track 4 — Provider / spark abstraction (TODO)

A formal model of `Cortex.Capability.Model.Client` and its `spark`-shaped contract: an external call
returns `Either CallError Result`. Discharging this lets us state determinism modulo sparks without
hand-waving over external model nondeterminism.

### Track 5 — Substrate / consumer boundary (TODO)

Per ADR 0015, the Cortex runtime never imports the structured reasoning library or any consumer
module. A Lean encoding of the import graph as a strict partial order makes this enforceable
mechanically rather than by code review.

Track 5 sits inside the substrate proof; Track 4 sits between the substrate and external
nondeterminism.

## Build

The Lean toolchain version lives in `lean-toolchain` (currently `leanprover/lean4:v4.29.0`). The
standard Lake commands work:

```
cd theory
lake update     # first-time setup
lake build      # builds the library/default targets
lake build cortex-theory   # builds the smoke executable
lake env Cortex.lean   # type-check the root module
./.lake/build/bin/cortex-theory  # smoke executable
```

Through the repo's nix flake:

```
nix build .#cortex-theory
just lean-check
```

For direct Lake workflows, `nix develop` still provides a working Lean toolchain in the repo shell.
The repo's pre-commit hook checks theory changes through the flake surface
(`nix build .#cortex-theory`) so that local commits and CI agree on the Lean gate.

## Status

| Track                            | Statements                                                                                                      | Proved                                                                                                                                                                                                                                                                                                                           | Axiomatized |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1a. Graph relation semantics     | finite relation denotation + Mokhov laws                                                                        | relation-level laws                                                                                                                                                                                                                                                                                                              | none        |
| 1b. Graph denotational AST laws  | AST laws over graph equivalence                                                                                 | denotational law surface                                                                                                                                                                                                                                                                                                         | none        |
| 1c. Graph quotient laws          | lifted quotient equality laws                                                                                   | `AlgGraph` quotient carrier, lifted operations, quotient equality bridge, Mokhov laws as `=`                                                                                                                                                                                                                                     | none        |
| 2. Fixed-topology Pulse kernel   | edge-derived DAG/state/fact/frontier/closure/recovery/classification/run-safety surface                         | frontier antichain, direct/runtime frontier bridge, fact commutativity, admissible fact recovery, closure idempotence, topology-domain/output/volatile-state/causal preservation, structural recovery predicate, classification exhaustiveness, recovery/execution safe-state envelope, replay determinism modulo fixed outcomes | none        |
| 3. Rewrite soundness             | CorePure proof subset + registry-boundary model + proof-carrying rewrite certificate + runtime admission bridge | pure evaluator determinism/static-field soundness/lowering preservation, node/edge registry predicates, runtime planning predicates, acyclicity/contract/budget projections, admitted planned-delta bridge, chain-level preservation, step bound by rewrite-operation budget                                                     | none        |
| 4. Provider / sparks             | —                                                                                                               | —                                                                                                                                                                                                                                                                                                                                | not started |
| 5. Substrate / consumer boundary | —                                                                                                               | —                                                                                                                                                                                                                                                                                                                                | not started |

Discharging the remaining obligations is the actual work. The scaffold's job is to make the
obligation graph compile and run end-to-end so that proof debt is visible and each abstract
certificate or predicate can be connected to executable Cortex code.
