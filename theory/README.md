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

Together these put the substrate's correctness story under machine-checked assurance, leaving the
LLM-driven layers above as the "untrusted user" of a "trusted system". The agent layer remains
stochastic; the substrate it runs on does not.

## Tracks

The five tracks are sketched below. Each track begins as an explicit obligation surface; completed
slices replace scaffold assumptions with theorems, while unfinished tracks keep proof debt visible.

### Track 1 — Graph algebra (Mokhov)

`Cortex.Graph.Core` defines the inductive `Graph α` with constructors `empty`, `vertex`, `overlay`,
`connect`. `Cortex.Graph.Relation` defines the finite relation denotation used by the Haskell
`toRelation` implementation and proves the Mokhov laws on that denotation with mathlib `Finset`s.
`Cortex.Graph.Laws` now exposes the AST-facing laws as theorems over denotational equality
(`GraphEq`), because raw syntax trees are not definitionally equal. The next quotient step
(`Cortex.Graph.Quotient`, TODO) can lift those denotational laws to ordinary equality on a quotient
carrier.

**Headline obligation:** `connect_decomposition` (`g · h · k = g · h ⊕ g · k ⊕ h · k`). This is what
licenses circuit simplification and the executor's compatibility-edge derivation. The relation-level
theorem now exists; the remaining obligation is lifting it through graph equivalence.

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

The Paper 1 Lean-Haskell modeling boundary is documented in
`docs/Publications/Paper-1-staged-reduction/lean-haskell-boundary.md`. Remaining obligations include
Haskell-side establishment of the persisted recovery preconditions and quotient lifting for the
graph algebra laws.

### Track 3 — Rewrite soundness

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
final-definition coverage, final acyclicity, and pointwise budget consumption.

Mechanized results now include:

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
- `rewriteChain_preserves_acyclic`, `rewriteChain_preserves_contracts`,
  `rewriteChain_preserves_registryBoundary`, `rewriteChain_steps_le_rewriteOps`, and
  `rewriteChain_finalBudget_le_initial`: local rewrite certificates lift across finite chains.

Remaining obligations:

- connect the Lean relation-level planner and namespaced `SubgraphSpec` input to the executable
  Haskell constructors in `planGraphRewrite`;
- connect registry-boundary witnesses to the Haskell compiler and registry;
- connect the abstract chain model to durable materialization order and lineage.

This is the "sandbox by proof" story for dynamic graph rewriting. Rewrites may transform topology,
but chain-level preservation requires them to stay inside the registry boundary documented in
`docs/Reference/Wire/executors-and-alphabet.md`.

### Track 4 — Provider / spark abstraction (TODO)

A formal model of `Cortex.Capability.Model.Client` and its `spark`-shaped contract: an external call
returns `Either CallError Result`. Discharging this lets us state determinism modulo sparks without
hand-waving over LLM nondeterminism.

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

| Track                            | Statements                                                                              | Proved                                                                                                                                                                                                                                         | Axiomatized |
| -------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1a. Graph relation semantics     | finite relation denotation + Mokhov laws                                                | relation-level laws                                                                                                                                                                                                                            | none        |
| 1b. Graph denotational AST laws  | AST laws over graph equivalence                                                         | denotational law surface                                                                                                                                                                                                                       | none        |
| 1c. Graph quotient laws          | lifted quotient equality laws                                                           | pending                                                                                                                                                                                                                                        | none        |
| 2. Fixed-topology Pulse kernel   | edge-derived DAG/state/fact/frontier/closure/recovery/classification surface            | frontier antichain, direct/runtime frontier bridge, fact commutativity, admissible fact recovery, closure idempotence, topology-domain/output/volatile-state/causal preservation, structural recovery predicate, classification exhaustiveness | none        |
| 3. Rewrite soundness             | registry-boundary model + proof-carrying rewrite certificate + runtime admission bridge | node/edge registry predicates, runtime planning predicates, acyclicity/contract/budget projections, admitted planned-delta bridge, chain-level preservation, step bound by rewrite-operation budget                                            | none        |
| 4. Provider / sparks             | —                                                                                       | —                                                                                                                                                                                                                                              | not started |
| 5. Substrate / consumer boundary | —                                                                                       | —                                                                                                                                                                                                                                              | not started |

Discharging the remaining obligations is the actual work. The scaffold's job is to make the
obligation graph compile and run end-to-end so that proof debt is visible and each abstract
certificate or predicate can be connected to executable Cortex code.
