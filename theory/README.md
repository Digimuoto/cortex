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
effect-class policy, output validation, and host authority. `Cortex.Wire.NodeBoundary` names ADR
0039's ingress/body/egress/edge normal-form obligations and instantiates them for CorePure and
registry-admitted edges. `Cortex.Wire.BoundaryResource` names ADR 0032/0035's local resource
vocabulary for boundary laws, anchor rewrite slots, and anchor-boundary use. `Cortex.Wire.Rewrite`
defines the proof-carrying rewrite certificate surface: an admitted `Rewrite` carries preservation
evidence for graph acyclicity, the caller-supplied contract predicate, and consumption of the
five-dimensional runtime rewrite budget. `Cortex.Wire.Admission` now models the proof-side bridge
from `planGraphRewrite` and `admitRewriteDelta`: anchor existence, anchor definition coverage,
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
`Cortex.Wire.PortLinearity` models both ADR 0047's source linear port carrier and the closed
actualized port-use witness layer. The source layer carries node identities, typed source port
instances, exposed frontier endpoints, source `PortLinear`, and `forgetPorts` lowering into
`Cortex.Graph.Relation`; overlay lowering and source linearity preservation are mechanized under
node-and-endpoint-domain disjointness. `Cortex.Wire.Make` and `Cortex.Wire.PhantomAdapter` then
exhibit ADR 0048's `make` and ADR 0049's `*` as constructions over those certified primitives.
`Cortex.Wire.GeneratedForms` is the admission seam: it abstracts the per-binding identity scheme as
a `GeneratedNamePolicy`, supplies the ADR 0048 `<binding>_<index>` default through
`prefixedIndexPolicy`, carries `KindInstantiatedFrontiers` as the handoff from kind substitution to
exact child port sets indexed by the accepted kind being instantiated, and requires the accepted
kind to use its generated `PortLabel` formal at every frontier label position before `make` or
`makeEach` admission can replace labels. It exposes named admission entry points `Make.accept`,
`MakeEach.accept`, and `Star.accept` that return either a certified `LinearPortObject` or a small
named diagnostic. `Cortex.Wire.ElaborationIR` adds the first Lean-owned post-parse,
post-source-include Wire IR: nominal contracts, record fields, port signatures, opaque node-body
boundaries, raw list-shaped declarations, accepted finite-frontier declarations, graph expressions
for `()`, `<>`, `=>`, `*`, `select(...)`, `make`, and `makeEach`, and explicit static diagnostics.
Isolated accepted node declarations project mechanically to the open `node_ports` source object; raw
parsing, source includes, full identifier grammar validation, registry binding, graph admission, and
executable elaboration certificates remain outside this module. The local accepted carriers do
enforce non-empty nominal names, valid port signatures, per-direction label uniqueness, record-field
label uniqueness, kind-parameter name uniqueness, module-level contract/kind/node/graph-binding name
uniqueness, graph-binding name validity, generated-form ownership by the containing graph binding,
select-arm nominal validity, and local reference closure for record-field contracts, frontier
contracts, and graph-expression references. The `node_ports` projection keeps input and output port
instances direction-distinct even when source labels match across directions.
`Cortex.Wire.FrontierReclaim` states the in-memory lifetime consequence: once a linear source
frontier is finished, no output or input endpoint has an open frontier obligation left. The source
algebra is a certified proof-object layer, so raw syntax such as `=>` is not assumed linear by
itself. The closed runtime-facing slice proves that every closed actualized input has exactly one
producer, and every closed actualized output has exactly one edge consumer or terminal discharge.
Raw `=>` matching, repeated-reference rejection, Haskell `make`/`*` expansion, runtime reclaim
hooks, and executable projection into actualized port use remain explicit correspondence obligations
rather than hidden assumptions. `Cortex.Wire.SelectRecovery` models recovery of selected latent
branches as replay of the admitted selected append rewrite, not as a new graph operator or a re-run
of selector code.

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
- `NodeBoundaryNormalForm`, `ingress_sound`, `body_sound`, `egress_sound`, and `edge_sound`: ADR
  0039's four normal-form obligations now have a named proof carrier and generic theorem surfaces.
- `CorePure.corePureBoundary`, `CorePure.corePure_ingress_sound`, `CorePure.corePure_body_sound`,
  `CorePure.corePure_egress_sound`, and
  `CorePure.corePure_evalOutputs_eq_egress_after_body_after_ingress`: proof-side CorePure evaluation
  instantiates the generic normal-form carrier and factors through ingress, body, and egress while
  preserving the admitted static environment, declared output ports, and output value contracts.
- `registered_body_sound`: registered executor body soundness is explicitly certificate territory at
  this layer, rather than being smuggled into Wire's structural proofs.
- `registry_contract_edge_sound`, `registry_edge_sound`, and `registryBoundary_edge_sound`:
  registry-admitted edges discharge ADR 0039's edge-compatibility obligation through the generic
  `EdgeSound` predicate.
- `SourcePortInstance`, `LinearPortGraph`, `LinearPortGraph.PortLinear`,
  `LinearPortGraph.forgetPorts`, `forgetPorts_edgeEndpointsInVertices`, `forgetPorts_overlay`,
  `overlay_preserves_portLinear`, `contract_preserves_portLinear`, `forgetPorts_contract`,
  `BulkContract`, `bulkContract_preserves_portLinear`, `forgetPorts_bulkContract`,
  `LinearPortObject.nodePorts`, `LinearPortOperation.apply_result_portLinear`, and
  `LinearPortSystem.certified_portLinear`: ADR 0047's source linear port carrier has a source
  exact-once/open-frontier endpoint rule, endpoint-closed lowering into `Cortex.Graph.Relation`,
  overlay preservation under node-and-endpoint-domain disjointness, certified single-pair and bulk
  source contraction, contraction lowering, bulk-contraction lowering, and a certified
  operation/node-port interface that exposes bundled source-linearity proofs.
- `LinearPortGraph.MakeWitness`, `LinearPortGraph.MakeWitness.toObject`,
  `LinearPortGraph.MakeWitness.make_disjoint_of_distinctBindings`,
  `LinearPortGraph.PhantomDirection`, `LinearPortGraph.ProductAdapterKind`,
  `LinearPortGraph.PhantomProductShape`, `LinearPortGraph.LinearPortObject.bulkContract`,
  `LinearPortGraph.PhantomAdapterWitness`, and
  `LinearPortGraph.PhantomAdapterWitness.starInsertion`: ADR 0048's `make` elaboration and ADR
  0049/0052's finite-product `*` phantom adapter are represented as certified constructions over
  `nodePorts`, `overlay`, and `BulkContract`. `MakeWitness` pins generated nodes to a shared binding
  projection and exact kind-derived child port sets; `PhantomProductShape` pins the generated
  adapter to one phantom node with a declared multi/singular boundary, bounded-indexed arity,
  element-contract uniformity, singular aggregate contract exactness, label uniqueness, and
  source-order enumeration when the product is `[T; N]`. `PhantomAdapterWitness` also records exact
  phantom-side boundary coverage for the two bulk contractions. The case `[T; 0]` is the empty
  finite product. No separate `make` or `*` preservation theorem is needed; the returned
  `LinearPortObject` carries source linearity by construction.
- `LinearPortGraph.GeneratedNamePolicy`, `LinearPortGraph.GeneratedNamePolicy.childIndex`,
  `LinearPortGraph.GeneratedNamePolicy.childIndex_injective`, `LinearPortGraph.prefixedIndexNodeId`,
  `LinearPortGraph.PrefixedIndexCarrier`, `LinearPortGraph.prefixedIndexPolicy`,
  `LinearPortGraph.MakeError`, `LinearPortGraph.MakeEachError`, `LinearPortGraph.StarError`,
  `LinearPortGraph.MakeItem`, `LinearPortGraph.MakeItem.LabelsUnique`,
  `LinearPortGraph.generatedNodes`, `LinearPortGraph.KindInstantiatedFrontiers`,
  `LinearPortGraph.KindInstantiatedFrontiers.toMakeWitness`,
  `LinearPortGraph.KindInstantiatedFrontiers.toMakeWitness_portLinear`,
  `LinearPortGraph.Make.accept`, `LinearPortGraph.Make.accept_ok_eq`,
  `LinearPortGraph.Make.accept_childLabel_eq`, `LinearPortGraph.Make.accept_childOutputPorts_exact`,
  `LinearPortGraph.Make.accept_childInputPorts_exact`, `LinearPortGraph.Make.accept_outputs_exact`,
  `LinearPortGraph.Make.accept_inputs_exact`, `LinearPortGraph.Make.accept_portLinear`,
  `LinearPortGraph.MakeEach.acceptItems`, `LinearPortGraph.MakeEach.accept`,
  `LinearPortGraph.MakeEach.accept_ok_eq`, `LinearPortGraph.MakeEach.accept_childLabel_eq`,
  `LinearPortGraph.MakeEach.accept_childOutputPorts_exact`,
  `LinearPortGraph.MakeEach.accept_childInputPorts_exact`,
  `LinearPortGraph.MakeEach.accept_outputs_exact`, `LinearPortGraph.MakeEach.accept_inputs_exact`,
  `LinearPortGraph.MakeEach.accept_portLinear`, `LinearPortGraph.Star.accept`,
  `LinearPortGraph.Star.accept_ok_eq`, and `LinearPortGraph.Star.accept_portLinear`: the
  source-linearity admission seam for Wire's three generated forms. `GeneratedNamePolicy` abstracts
  the per-binding identity scheme as an opaque injective indexing function plus a binding-projection
  witness; `PrefixedIndexCarrier` and `prefixedIndexPolicy` realize ADR 0048's `<binding>_<index>`
  default with the encoder kept parametric so the Haskell elaborator can pick its own deterministic
  suffix. `KindInstantiatedFrontiers` is the proof-side result of substituting each generated
  `PortLabel` and any static `Value` parameter into the reusable kind frontier. Its accepted-kind
  type index prevents callers from pairing `KindSupportsMake` evidence for one kind with frontiers
  produced for another kind, and `KindSupportsMake`/`KindSupportsMakeEach` now require every
  template frontier label to be the declared `PortLabel` formal before generated child labels can
  replace it. Its exactness fields require every generated child frontier to preserve the kind
  template contracts under the generated child labels. `Make.accept` and `MakeEach.accept` turn that
  exact frontier evidence into a `MakeWitness` over Wire's direction-tagged port wrappers, while
  `Star.accept` reuses `PhantomAdapterWitness.starInsertion`. The returned `LinearPortObject`
  carries source linearity by construction. ADR 0052 `workers[i]` projection is parser/expander
  syntax resolved before this post-expansion IR; Lean receives the selected child as an ordinary
  graph node reference. Executable production of the exact generated-form witnesses remains the
  Haskell correspondence obligation.
- `ElaborationIR.RawNodeDecl`, `ElaborationIR.AcceptedNodeDecl`, `ElaborationIR.GraphExpr`,
  `ElaborationIR.GraphBinding`, `ElaborationIR.ElabDiagnostic`, `ElaborationIR.ElabResult`,
  `ElaborationIR.RawModule`, `ElaborationIR.AdmittedModuleShell`,
  `ElaborationIR.OutputPortSignature`, `ElaborationIR.InputPortSignature`,
  `ElaborationIR.RawNodeDecl.LocallyAdmissible`, `ElaborationIR.RawNodeDecl.toAccepted`,
  `ElaborationIR.RawNodeDecl.toAccepted_toLinearPortObject_portLinear`,
  `ElaborationIR.RecordContractDecl.LocallyAdmissible`,
  `ElaborationIR.RecordContractDecl.toAccepted`, `ElaborationIR.AcceptedRecordContractDecl`,
  `ElaborationIR.RecordContractDecl.FieldContractsClosed`,
  `ElaborationIR.AcceptedRecordFieldContractsClosed`, `ElaborationIR.KindParamDecl`,
  `ElaborationIR.KindParamClass`, `ElaborationIR.RawKindDecl.LocallyAdmissible`,
  `ElaborationIR.RawKindDecl.toAccepted`, `ElaborationIR.RawModule.LocallyAdmissible`,
  `ElaborationIR.GraphExpr.BindingRefIn`, `ElaborationIR.GraphExpr.RawRefsClosed`,
  `ElaborationIR.GraphExpr.AcceptedRefsClosed`, `ElaborationIR.GraphBinding.LocalValid`,
  `ElaborationIR.GraphBinding.BindingRefEdge`, `ElaborationIR.GraphBinding.BindingRefAcyclic`,
  `ElaborationIR.RawModule.acceptedContracts`, `ElaborationIR.RawModule.acceptedKinds`,
  `ElaborationIR.RawModule.acceptedNodes`, `ElaborationIR.RawModule.rawRefsClosed_toAccepted`,
  `ElaborationIR.RawModule.toAccepted`, `ElaborationIR.PortLabelsUnique`,
  `ElaborationIR.AcceptedNodeDecl.toLinearPortObject`, and
  `ElaborationIR.Examples.cBuildGraphShape`: the first Lean-owned Wire elaboration IR can represent
  raw post-source-include syntax separately from accepted declarations, including empty graphs,
  `select(...)`, shape-level `makeEach`, and `*`, while accepted records, nodes, and kinds carry
  local non-empty-name, valid-field/port, per-direction label-uniqueness, and kind-parameter
  witnesses. Accepted modules also carry contract/kind/node/graph-binding name uniqueness, graph
  binding name validity, and local closure predicates for record-field contracts, frontier
  contracts, node references, kind references, graph-binding references, and select-arm nominal
  spelling. Locally admitted raw modules project to accepted module shells while preserving
  declaration name lists and graph reference closure; locally admitted raw nodes have a named
  theorem exposing their source-linear, direction-separated `node_ports` lift.
- `ElaborationIR.OutputArmDecl`, `ElaborationIR.OutputArmDecl.Valid`, `ElaborationIR.OutputShape`,
  `ElaborationIR.OutputShape.ports`, `ElaborationIR.OutputShape.LocallyAdmissible`,
  `ElaborationIR.OutputShape.ports_valid_of_locallyAdmissible`,
  `ElaborationIR.OutputShape.ports_labels_nodup_of_locallyAdmissible`,
  `ElaborationIR.OutputShapeListPorts`, `ElaborationIR.OutputShapeListAdmissible`,
  `ElaborationIR.outputShapeListPorts_valid`, `ElaborationIR.RawNodeDecl.outputPortsList`,
  `ElaborationIR.RawKindDecl.outputPortsList`, `ElaborationIR.AcceptedNodeDecl.outputPortsList`,
  `ElaborationIR.AcceptedNodeDecl.outputPorts`,
  `ElaborationIR.AcceptedNodeDecl.outputPorts_eq_toFinset`,
  `ElaborationIR.AcceptedNodeDecl.outputPorts_valid`,
  `ElaborationIR.AcceptedNodeDecl.outputPorts_labelsUnique`,
  `ElaborationIR.AcceptedNodeDecl.outputPortsList_eq_flatMap`,
  `ElaborationIR.AcceptedNodeDecl.outputPorts_eq_flatMap_toFinset`,
  `ElaborationIR.AcceptedKindDecl.outputPortsList`, `ElaborationIR.AcceptedKindDecl.outputPorts`,
  `ElaborationIR.AcceptedKindDecl.outputPorts_eq_toFinset`,
  `ElaborationIR.AcceptedKindDecl.outputPorts_valid`,
  `ElaborationIR.AcceptedKindDecl.outputPorts_labelsUnique`,
  `ElaborationIR.AcceptedKindDecl.outputPortsList_eq_flatMap`,
  `ElaborationIR.AcceptedKindDecl.outputPorts_eq_flatMap_toFinset`,
  `ElaborationIR.AcceptedKindDecl.kindSupportsMake_outputPortsList_length_le_one`,
  `ElaborationIR.RawNodeDecl.toAccepted_outputs`, `ElaborationIR.RawKindDecl.toAccepted_outputs`,
  `ElaborationIR.Examples.artifactSingleShape`,
  `ElaborationIR.Examples.artifactSingleShape_admissible`, `ElaborationIR.Examples.specSingleShape`,
  `ElaborationIR.Examples.specSingleShape_admissible`,
  `ElaborationIR.Examples.singleton_outputShapeListAdmissible`, and
  `ElaborationIR.Examples.singleton_outputShapeListPortsLabelsUnique`: accepted node and kind output
  declarations preserve authored output shape, distinguishing a single output port from an exclusive
  output sum group while flattening to the same `Finset PortSignature` view consumed by the
  source-linearity lift. The shape carrier admits valid arm keys, unique arm keys, unique port
  labels per group, valid flattened ports across the whole frontier, and equality between the
  flattened authored shapes and the projected `outputPorts` finset. Sum-group arms may share
  contracts; only the arm-local label set must be Nodup. The per-shape and per-list admission
  predicates expose `Decidable` instances where natural and transport across
  `RawNodeDecl.toAccepted` and `RawKindDecl.toAccepted` without losing the authored shape
  distinction.
- `ElaborationIR.CertifiedGraph`, `ElaborationIR.CertifiedGraph.empty`,
  `ElaborationIR.CertifiedGraph.nodeOf`, `ElaborationIR.CertifiedGraph.bindingOf`,
  `ElaborationIR.CertifiedGraph.Disjoint`, `ElaborationIR.CertifiedGraph.overlayOf`,
  `ElaborationIR.CertifiedGraph.SingletonMatch`,
  `ElaborationIR.CertifiedGraph.BulkContractContainsPair`,
  `ElaborationIR.CertifiedGraph.CompatiblePair`, `ElaborationIR.CertifiedGraph.BoundaryMatchTrace`,
  `ElaborationIR.CertifiedGraph.connectOf`, `ElaborationIR.Admits`,
  `ElaborationIR.CertifiedGraph.admits_overlay_usedRefs_disjoint`,
  `ElaborationIR.CertifiedGraph.admits_overlay_usedNodes_disjoint`,
  `ElaborationIR.CertifiedGraph.admits_overlay_self_binding_false`,
  `ElaborationIR.CertifiedGraph.singletonMatch_unique`, and
  `ElaborationIR.CertifiedGraph.admits_overlay_object_eq`,
  `ElaborationIR.CertifiedGraph.admits_connect_object_graph_eq`: primitive `GraphExpr` shapes
  (`empty`, `node`, `binding`, `overlay`, `connect`) admit to certified graph objects packaging a
  source-linear `LinearPortObject` with finite ledgers of consumed source-node identities and
  resolved graph-binding references; admitted overlays carry disjoint node and reference ledgers, so
  `a <> a` is rejected even when the resolved binding has empty node domain. `connectOf` now
  consumes a certified `BulkContract` trace through `BoundaryMatchTrace` plus its bundled
  `determined` witness that the trace contains exactly the compatible exposed boundary pairs, so
  bulk-frontier source-linearity preservation and match-set exactness are part of the primitive
  graph-admission carrier. Recursive admission of bound graph expressions remains an explicit
  follow-up obligation.
- `AdmissionArtifact.PrimitiveTraceFrame`, `AdmissionArtifact.PrimitiveTraceStep`,
  `AdmissionArtifact.PrimitiveTraceReplays`, `AdmissionArtifact.PrimitiveTraceStackValid`, and
  `AdmissionArtifact.validatorReady_primitiveTraceStackValid`: decoded Haskell admission artifacts
  must replay primitive `empty`/node/binding/overlay/connect rows as one postorder stack whose final
  source-visible node, binding, frontier, and connection ledgers match the artifact summary. Select
  condition branch-choice exits remain primitive bridge exits but are erased from the source-visible
  final frontier before comparison. `AdmissionArtifact.SelectBridgeEntriesConsumed`,
  `AdmissionArtifact.PhantomBridgeBulkConnectionsReplayed`,
  `AdmissionArtifact.validatorReady_primitiveConnect_compatiblePair_replayed`,
  `AdmissionArtifact.validatorReady_primitiveConnect_compatiblePair_consumed`,
  `AdmissionArtifact.validatorReady_summary_connection_replayedByPrimitiveMatch`,
  `AdmissionArtifact.validatorReady_primitiveMatchedConnection_in_summary`,
  `AdmissionArtifact.validatorReady_primitiveOverlay_mem_prefixAvailable`, and
  `AdmissionArtifact.validatorReady_primitiveConnect_mem_prefixAvailable` additionally expose exact
  bridge replay, compatible-pair consumption, raw-edge summary projection, and prefix-order
  availability for overlay/connect rows, so those bridge rows cannot be justified by
  shape-compatible but unrelated replay. `AdmissionArtifact.primitiveTraceStepCheck`,
  `AdmissionArtifact.primitiveTraceReplayCheck`, `AdmissionArtifact.primitiveTraceStackValidCheck`,
  and `AdmissionArtifact.primitiveTraceStackValidCheck_sound` are the first Lean-owned executable
  checker slice for this artifact contract: a successful primitive-stack check implies the
  relational `PrimitiveTraceStackValid` field required by `ValidatorReady`.
  `AdmissionArtifact.ValidatorReadyCore`, `AdmissionArtifact.validatorReadyCoreCheck`, and
  `AdmissionArtifact.validatorReadyCoreCheck_sound` extend that strategy to a representative
  executable validator core: schema version, summary-key uniqueness, summary-row validity, summary
  domain closure, summary identity/frontier/raw-connection matching against primitive rows,
  primitive overlay ledger prefix availability, primitive connect frontier backing, primitive
  connect frontier prefix availability, component-domain closure, local generated/select/phantom row
  validity, generated-form reference anchoring, component-row uniqueness, primitive row validity,
  and primitive stack replay. `AdmissionArtifact.validatorReady_generated_usedChild_sourceChild` and
  `AdmissionArtifact.validatorReady_emptyGeneratedForm_bindingRow` recover the concrete source
  generated-child or empty-family row for each generated artifact, rather than only a label
  membership fact. `AdmissionArtifact.validatorReady_generated_usedChild_sourceMakeItem` then
  carries each surviving generated child through the decoded source-row-to-`MakeItem` projection,
  `AdmissionArtifact.validatorReady_generated_usedChild_uniqueSourceMakeItem` makes that projected
  source item unique by generated label, and
  `AdmissionArtifact.validatorReady_generated_make_usedChild_sourceMakeItem_value_empty` specializes
  the bridge to `make` rows whose generated source items have no static payload. Static `makeEach`
  record payloads expose duplicate-free serialized and converted field labels through
  `AdmissionArtifact.validatorReady_generated_sourceChild_staticRecordFieldsUnique` and
  `AdmissionArtifact.validatorReady_generated_sourceChild_staticRecordFieldsUnique_toStaticValue`.
  The decoded artifact surface also exposes select body-shape branch facts
  (`AdmissionArtifact.validatorReady_select_identityArm_bridgeShape`,
  `AdmissionArtifact.validatorReady_select_nonIdentityArm_bodyShapes`) plus the source exclusive
  group shared by persisted base variants
  (`AdmissionArtifact.validatorReady_select_variantsShareExclusiveGroup`,
  `AdmissionArtifact.validatorReady_select_variants_sameSourceNode`).
  `AdmissionArtifact.SelectAdmissionArtifact.toLatentSelectAdmission` projects decoded select rows
  into the generic `SelectAdmission.LatentSelectAdmission` key carrier, with decoded arm rows kept
  as latent metadata rather than claimed executable branch fragments; the
  `AdmissionArtifact.SelectAdmissionArtifact.toLatentSelectAdmission_entry_sourceArm` and
  `AdmissionArtifact.validatorReady_select_latentEntry_sourceArm` accessors expose that every latent
  body in this projection is exactly one persisted source arm row, and
  `AdmissionArtifact.validatorReady_select_latentEntry_bodyNodeFresh` plus
  `AdmissionArtifact.validatorReady_select_latentEntries_bodyNodesDisjoint` carry the serialized
  body-node freshness/disjointness facts through that projection. The decoded artifact surface also
  exposes record/indexed phantom product row facts
  (`AdmissionArtifact.validatorReady_phantomAdapter_product_contractValid`,
  `AdmissionArtifact.validatorReady_phantomAdapter_record_multi_boundary_labeled`,
  `AdmissionArtifact.validatorReady_phantomAdapter_record_multi_boundary_field_mem`,
  `AdmissionArtifact.validatorReady_phantomAdapter_record_singular_contract_eq`,
  `AdmissionArtifact.validatorReady_phantomAdapter_record_multi_length_eq`,
  `AdmissionArtifact.validatorReady_phantomAdapter_indexed_multi_contract_eq`,
  `AdmissionArtifact.validatorReady_phantomAdapter_indexed_multiCompatibilityShapesUnique`,
  `AdmissionArtifact.validatorReady_phantomAdapter_indexed_singular_contract_eq`,
  `AdmissionArtifact.validatorReady_phantomAdapter_indexed_elementValid`,
  `AdmissionArtifact.validatorReady_phantomAdapter_indexed_elementNominal`) for the Haskell
  validator-ready payload. Direction-specific replay accessors such as
  `AdmissionArtifact.validatorReady_phantomAdapter_gather_multiEndpoint_replayed` and
  `AdmissionArtifact.validatorReady_phantomAdapter_scatter_multiEndpoint_replayed` combine the
  phantom row's endpoint partition with primitive matched-connection replay, so every source-visible
  multi/singular side has a replayed primitive contraction row in the expected gather/scatter
  position. Schema version 3 additionally makes the record product's aggregate contract explicit, so
  Lean can compare the serialized product row to the singular endpoint rather than inferring the
  record contract from field rows; the validator-ready indexed-product surface also rejects nested
  indexed elements and exposes duplicate-free indexed multi-side compatibility keys. Full source
  identifier grammar for the indexed element remains a parser/Haskell correspondence obligation.
  `AdmissionArtifact.PrimitiveSound`, `AdmissionArtifact.GeneratedSound`,
  `AdmissionArtifact.SelectSound`, `AdmissionArtifact.PhantomSound`, `AdmissionArtifact.Sound`, and
  `AdmissionArtifact.validatorReady_sound` now name the proof-facing cutline for this decoded
  artifact layer: Haskell validation should establish `AdmissionArtifact.ValidatorReady`, and Lean
  then exposes the grouped primitive, generated-form, select, and phantom-adapter consequences
  without downstream proofs depending on checker-internal field layout. This is still not a
  completeness proof that the Haskell compiler emits such an artifact for every accepted Wire
  program; it is the reusable target that such a proof must hit.
- `LinearPortGraph.FrontierFinished`, `LinearPortGraph.OutputReclaimable`,
  `LinearPortGraph.InputReclaimable`, `frontierFinished_noRemainingConsumerObligations`,
  `frontierFinished_noRemainingProducerObligations`, and `frontierFinished_reclaimable`: finished
  linear source frontiers have no remaining open producer or consumer obligations, so ephemeral
  in-memory endpoint resources are structurally reclaimable. Durable provenance retention is a
  runtime profile choice, not a contradiction of the source frontier theorem.
- `ActualizedPortInstance`, `OutputPortUse`, `ActualizedPortGraph.ClosedPortLinear`,
  `actualizedOutputPort_consumed_exactly_once`, `actualizedInputPort_produced_exactly_once`,
  `compiledPortUseWitness_edge_input_uniqueProducer`, `portUseWitness_toGraph_closedPortLinear`, and
  `selectActualize_preserves_closedPortLinearity`: closed actualized port-use witnesses establish
  exact-once producer/consumer accounting for concrete port instances, and selected-branch
  actualization preserves that accounting under namespace-freshness/domain-disjointness premises.
  This does not yet mechanize exact selected-fragment projection or runtime `actualizedPortGraphOf`
  projection.
- `projectSourceOutput`, `projectSourceInput`, `projectSourceOutput_injective`,
  `projectSourceInput_injective`, `projectedActualizedGraph`, `SourceToActualizedProjection`,
  `SourceToActualizedProjection.canonical`, `SourceToActualizedProjection.portNodeDomain_eq`,
  `SourceToActualizedProjection.canonical_terminalDischarges_eq_empty`,
  `SourceToActualizedProjection.source_output_mem`, `SourceToActualizedProjection.source_input_mem`,
  `SourceToActualizedProjection.actualized_output_source`,
  `SourceToActualizedProjection.actualized_input_source`, `PortUseWitness.AlignedWith`,
  `compiledPortUseWitness_exact_output_forward`, `compiledPortUseWitness_exact_input_forward`,
  `compiledPortUseWitness_exact_output_reverse`, `compiledPortUseWitness_exact_input_reverse`,
  `compiledPortUseWitness_exact_output`, `compiledPortUseWitness_exact_input`,
  `AlignedPortUseWitnessSoundness`, and `alignedPortUseWitness_closedPortLinear`:
  source-to-actualized projection is a deterministic injective image of source `LinearPortObject`
  carriers; an aligned `PortUseWitness` matches that projection extensionally on outputs, inputs,
  and edge consumers, ruling out runtime ports the source carrier never declared, source ports the
  witness silently drops, and source-edge mismatch. Aligned witnesses also discharge closed
  actualized port linearity. Terminal-discharge correspondence, compiler witness production, and
  richer port-relabelling projections remain open.
- `BoundaryLaw`, `AnchorBoundaryUse`, `RewriteSlot`, `BoundaryResourceUse`,
  `BudgetedBoundaryResourceUse`, `GraphRewrite.expandNode_resourceUse`,
  `GraphRewrite.appendAfter_resourceUse`, `ConstructedPlanningStep.boundaryResourceUse`,
  `ConstructedPlanningStep.boundaryResourceCost_fits_budget`,
  `ConstructedPlanningStep.rewriteSlotsUnique`, `ConstructedPlanningChain.ContainsRewriteSlot`,
  `ConstructedPlanningChain.SlotUnique`, `ConstructedPlanningChain.SlotUniqueTrace`,
  `RewriteSlotsUnique`, `rewriteSlot_spent_at_most_once`, and `BoundaryResource.boundaryPreserved`:
  ADR 0032's boundary-resource vocabulary now has a Lean-side carrier for constructor-specific
  resource use, budgeted constructed-step resource use, single-step rewrite-slot uniqueness,
  proof-relevant slot-unique epoch traces, and constructed-step boundary preservation.
  `RewriteSlotsUnique` is occurrence-sensitive through `Nodup` over the projected rewrite slots.
- `GraphRewrite.substitution_consumes_anchor_boundary`,
  `GraphRewrite.appendContinuation_retains_anchor_boundary`,
  `BoundaryResource.SubstitutionExposesAnchorBoundary`,
  `BoundaryResource.substitution_preserves_boundary`, and
  `BoundaryResource.appendContinuation_preserves_boundary`: ADR 0035's substitution and
  append-continuation boundary laws are distinct theorem surfaces over existing rewrite forms;
  substitution carries a consumed-anchor-boundary exposure hook that append does not require.
- `LatentBranchFamily.resourceUse`,
  `SelectActualize.selectActualize_resourceUse_slot_coherent_with_lowering`, and
  `SelectActualize.selectActualize_toGraphRewrite_resourceUse_law_eq_appendContinuation`:
  selected-arm actualization uses the upper-layer conditional branch actualization resource law
  while sharing the owner rewrite slot with the retained-owner append rewrite seen by runtime
  admission.
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
- `WireTopologyDAGBridge`, `WireTopologyDAGBridge.ofAcyclic`, `MaterializedPulseState`, and
  `SafeWireRunState`: the Track 3 envelope that connects Wire planning validity, registry boundary,
  rewrite budget bounds, and Pulse `wellFormedGraphState` over the materialized DAG for the current
  Wire topology. Accepted acyclic Wire topologies now admit a canonical `DAG.ofRelation` bridge
  witness consumed by the envelope.
- `wirePulseRecoveryStep_establishes_safeRunState`, `wirePulseRecoveryStep_preserves_safeRunState`,
  `wirePulseExecutionStep_preserves_safeRunState`,
  `wirePulseAdmittedRewrite_preserves_safeRunState`, and `selectActualize_preserves_safeRunState`:
  crash recovery establishes the bundled Wire/Pulse safety envelope from persisted recovery
  preconditions; recovery, admissible frontier facts, constructed rewrites, and selected-arm
  actualization then preserve the envelope when the runtime supplies the corresponding materialized
  Pulse DAG/state witness.
- `SelectedBranchRecoveryRecord`, `SelectedBranchRecoveryRecord.Provenance`,
  `SelectedBranchRecoveryRecord.PhantomAdapterEmbedding`, `PersistedSelectedBranchAdmission`,
  `replayedRewrite_eq_of_selected_eq`, `selectedBranch_recovery_deterministic`,
  `selectedBranch_unselected_not_replayed`, `selectedBranch_unselected_not_in_delta_topology`,
  `selectedBranch_recovery_embeddedPhantomAdapter_artifact_replayed_and_pruned`, and
  `selectedBranch_recovery_preserves_safeRunState`: selected-branch recovery records loaded from the
  same persisted admission replay the same selected append rewrite, constructed delta, and remaining
  budget; unselected branch nodes stay out of the raw replayed fragment and, under namespace
  freshness, the constructed selected-branch delta topology; when a phantom-adapter witness is
  embedded in the selected branch, its persisted artifact node is replayed and still pruned from
  every unselected branch; the record then feeds the existing Wire/Pulse safe-run preservation
  theorem.
- `SelectAdmission.SelectableOutputShape`, `SelectAdmission.SelectArm`,
  `SelectAdmission.SelectExpr`, `SelectAdmission.SelectAdmissionError`,
  `SelectAdmission.LatentSelectAdmission`,
  `SelectAdmission.LatentSelectAdmission.keys_perm_shape_keys`,
  `SelectAdmission.LatentSelectAdmission.keys_eq_shape_keys`,
  `SelectAdmission.LatentSelectAdmission.length_eq_armPorts`,
  `SelectAdmission.LatentSelectAdmission.keys_nodup`, `SelectAdmission.detectDuplicateArm`,
  `SelectAdmission.contractFallbackCandidates`, `SelectAdmission.resolveArmKey`,
  `SelectAdmission.resolveArms`, `SelectAdmission.admitClause`, `SelectAdmission.admitClauseAtNode`,
  `SelectAdmission.admitClause_entries_keys_eq_shape`,
  `SelectAdmission.LatentSelectAdmission.FromClause`, `SelectAdmission.FragmentEvidence`,
  `SelectAdmission.LatentSelectAdmission.fragmentLookup`,
  `SelectAdmission.LatentSelectAdmission.fragmentLookup_entry`,
  `SelectAdmission.LatentSelectAdmission.toLatentBranchFamily`: source-level admission for Wire
  `select(...)` clauses projects a two-or-more exclusive output sum from the base node, resolves
  source arm keys label-first with unique contract-name fallback, rejects duplicate canonical arms,
  missing coverage, and ambiguous contract fallback with explicit `SelectAdmissionError`
  diagnostics, keeps admitted arm bodies latent rather than overlaying live topology, names the
  optional body-provenance obligation through `FromClause`, and bridges admitted `SubgraphSpec` arm
  bodies into the existing `LatentBranchFamily` carrier under caller-supplied per-arm validity and
  pairwise fragment-node disjointness evidence.
- `WirePulseSnapshot`, `SafeWirePulseSnapshot`, `AdmittedWirePulseStep`, `AdmittedWirePulseTrace`,
  `WirePulseSnapshot.runStart_establishes_safeRunState`,
  `AdmittedWirePulseStep.preserves_safeRunState`, `AdmittedWirePulseTrace.preserves_safeRunState`,
  `AdmittedWirePulseTrace.preserves_safeRunState_from_runStart`, and
  `AdmittedWirePulseTrace.final_not_stuck_from_runStart`: the admitted runtime middle is closed as a
  finite trace over recovery, frontier facts, CorePure success facts, constructed rewrites,
  selected-arm actualization, and selected-branch recovery. CorePure success facts require the
  CorePure payload type; the other constructors are payload-polymorphic. Any such trace starting
  from persisted recovery preconditions ends in the safe Wire/Pulse envelope and cannot classify as
  stuck.
- `corePureExecutionStep_preserves_safeRunState`: successful admitted CorePure output evaluation can
  feed the Pulse success-fact surface while retaining output-port and proof-side value-contract
  evidence.
- `wirePulseExecutionFacts_replay_deterministic`: fixed external frontier facts replay to the same
  recovered state under permutation when they target distinct nodes.
- `rewriteChain_preserves_acyclic`, `rewriteChain_preserves_contracts`,
  `rewriteChain_preserves_registryBoundary`, `rewriteChain_steps_le_rewriteOps`, and
  `rewriteChain_finalBudget_le_initial`: local rewrite certificates lift across finite chains.

On the executable side, the current Haskell correspondence checks now include
`corePureStaticContextFromBindings` and `corePureWhereStaticFields` for CorePure static `where`
discovery, `corePureBuiltinAuthorityReport` for closed builtin-table review,
`validatePureTaskConfig` before serialized native-pure task configs reach runtime evaluation, a
private node-boundary normal-form IR with compiler validation hooks, shared runtime egress wrappers
for single and multi-output Wire values, plus `planGraphRewriteWithAdmissionWitness`, which reruns
the Lean-shaped planner and budget-admission equations around `planGraphRewrite` and
`admitRewriteDelta`. Circuit lowering tests now check that selected latent branches lower through
the same admitted `AppendAfter` witness surface, omit unselected branch nodes from the selected
delta, and charge only the selected branch cost. Regression tests pin name-by-name shadowing of
top-level CorePure bindings by `where` fields, the closed-builtin authority's missing-variable error
path, the wrap/unwrap round-trip across single and multi-output Wire values, and the structural
exclusion of unselected `select(...)` branch bodies from the outer compiled circuit.

The remaining Track 3 correspondence obligations are now tracked in
`docs/ADRs/0038-wire-proof-track-theorem-ledger.md`. The next slices are:

- Haskell correspondence for full CorePure evaluator/value semantics, compiler admission gates such
  as duplicate record-path coverage outside the native-pure lowering path, executor body
  certificates, and full Wire output contract wrapping;
- Haskell planner and budget-admission correspondence for full `RuntimeConstructionInputs` and
  added-node/added-edge registry admission;
- executable materialization witnesses for `MaterializedPulseState`, retained-node status/output
  continuity across rewrites, and persisted rewrite-lineage hooks that produce
  `SelectedBranchRecoveryRecord.Provenance` directly.

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

| Track                            | Statements                                                                                                                                    | Proved                                                                                                                                                                                                                                                                                                                                                                                                                                    | Axiomatized |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1a. Graph relation semantics     | finite relation denotation + Mokhov laws                                                                                                      | relation-level laws                                                                                                                                                                                                                                                                                                                                                                                                                       | none        |
| 1b. Graph denotational AST laws  | AST laws over graph equivalence                                                                                                               | denotational law surface                                                                                                                                                                                                                                                                                                                                                                                                                  | none        |
| 1c. Graph quotient laws          | lifted quotient equality laws                                                                                                                 | `AlgGraph` quotient carrier, lifted operations, quotient equality bridge, Mokhov laws as `=`                                                                                                                                                                                                                                                                                                                                              | none        |
| 2. Fixed-topology Pulse kernel   | edge-derived DAG/state/fact/frontier/closure/recovery/classification/run-safety surface                                                       | frontier antichain, direct/runtime frontier bridge, fact commutativity, admissible fact recovery, closure idempotence, topology-domain/output/volatile-state/causal preservation, structural recovery predicate, classification exhaustiveness, recovery/execution safe-state envelope, replay determinism modulo fixed outcomes                                                                                                          | none        |
| 3. Rewrite soundness             | CorePure proof subset + registry-boundary model + proof-carrying rewrite certificate + runtime admission bridge + closed Wire/Pulse run trace | pure evaluator determinism/static-field soundness/lowering preservation, CorePure success-fact bridge, node/edge registry predicates, port-use linearity witnesses, runtime planning predicates, acyclicity/contract/budget projections, admitted planned-delta bridge, chain-level preservation, step bound by rewrite-operation budget, SelectActualize lowering, closed admitted-run trace preservation over materialized Pulse states | none        |
| 4. Provider / sparks             | —                                                                                                                                             | —                                                                                                                                                                                                                                                                                                                                                                                                                                         | not started |
| 5. Substrate / consumer boundary | —                                                                                                                                             | —                                                                                                                                                                                                                                                                                                                                                                                                                                         | not started |

Discharging the remaining obligations is the actual work. The scaffold's job is to make the
obligation graph compile and run end-to-end so that proof debt is visible and each abstract
certificate or predicate can be connected to executable Cortex code.
