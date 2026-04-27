# Cortex theory

Lean 4 mechanization of the Cortex substrate. This directory builds as
its own Lake project (`lakefile.lean`, `lean-toolchain`) and is wired
into the repo's nix flake under `packages.cortex-theory` via
`nix/lean.nix`.

The point of having a Lean track at all is to turn the substrate
guarantees from prose into proof:

- Wire / Graph laws aren't conventions — they're theorems.
- Pulse frontier safety isn't a code review property — it's a
  mechanized invariant.
- Rewrite admission isn't a runtime check we hope is correct — it's
  a soundness theorem we discharge.
- Pulse determinism modulo external sparks is the audit-trail
  property that makes runs replayable.

Together these put the substrate's correctness story under
machine-checked assurance, leaving the LLM-driven layers above as the
"untrusted user" of a "trusted system". The agent layer remains
stochastic; the substrate it runs on does not.

## Tracks

The five tracks are sketched below. Each track begins as an explicit
obligation surface; completed slices replace scaffold assumptions with
theorems, while unfinished tracks keep proof debt visible.

### Track 1 — Graph algebra (Mokhov)

`Cortex.Graph.Core` defines the inductive `Graph α` with constructors
`empty`, `vertex`, `overlay`, `connect`. `Cortex.Graph.Relation`
defines the finite relation denotation used by the Haskell
`toRelation` implementation and proves the Mokhov laws on that
denotation with mathlib `Finset`s. `Cortex.Graph.Laws` now exposes the
AST-facing laws as theorems over denotational equality (`GraphEq`),
because raw syntax trees are not definitionally equal. The next quotient
step (`Cortex.Graph.Quotient`, TODO) can lift those denotational laws to
ordinary equality on a quotient carrier.

**Headline obligation:** `connect_decomposition`
(`g · h · k = g · h ⊕ g · k ⊕ h · k`). This is what licenses circuit
simplification and the executor's compatibility-edge derivation. The
relation-level theorem now exists; the remaining obligation is lifting it
through graph equivalence.

### Track 2 — Fixed-topology Pulse kernel

`Cortex.Pulse.DAG`, `State`, `Fact`, `Frontier`, `Closure`, `Validity`,
and `Recovery` model the Paper 1 fixed-topology staged-reduction kernel.
The current model is extensional: a finite node type, an edge-derived DAG
reachability relation, abstract payloads, node-local facts,
reachability-level readiness, topology-domain validity, and failure
closure over the DAG. It avoids runtime UUID/database shapes and keeps
payload and failure details abstract.

Mechanized results now include:

- `frontier_only_ready`: frontier membership implies readiness.
- `frontier_antichain`: frontier nodes are mutually incomparable by
  strict reachability.
- `NodeResult.applyNodeFact_comm`: node-local facts for distinct nodes
  commute.
- `propagateFailure_extensive`: propagation preserves failed nodes.
- `propagateFailure_failureClosureComplete`: one propagation pass closes
  failure over propagatable descendants.
- `propagateFailure_preserves_topologyDomain`: propagation preserves the
  absence of off-topology durable state.
- `propagateFailure_preserves_outputsRespectStatuses`: propagation
  preserves output ownership.
- `propagateFailure_idempotent`: failure propagation is idempotent.
- `directReady_sound`: executable direct-predecessor readiness implies
  proof-level reachability readiness under causal-history closure.
- `persistence_safety`: recovered states are structurally well-formed,
  parameterized by persisted topology-domain, output, and causal-history
  invariants that recovery preserves.

Remaining obligations include permutation invariance for whole frontier
result folds, full executable frontier classification, classification
exhaustiveness, and quotient lifting for the graph algebra laws.

### Track 3 — Rewrite soundness

`Cortex.Wire.Rewrite` sketches the admission predicate from
`src/Cortex/Pulse/Rewrite.hs`. Three obligations:

- `admissible_preserves_acyclic`: rewrites can't introduce cycles.
- `admissible_preserves_contracts`: rewrites can't violate the
  registry's boundary invariants.
- `apply_admissible_terminates`: rewrite chains are bounded by the
  per-run budget.

This is the "sandbox by proof" story for dynamic graph rewriting.

### Track 4 — Provider / spark abstraction (TODO)

A formal model of `Cortex.Capability.Model.Client` and its
`spark`-shaped contract: an external call returns
`Either CallError Result`. Discharging this lets us state determinism
modulo sparks without hand-waving over LLM nondeterminism.

### Track 5 — Substrate / consumer boundary (TODO)

Per ADR 0015, the Cortex runtime never imports the structured
reasoning library or any consumer module. A Lean encoding of the
import graph as a strict partial order makes this enforceable
mechanically rather than by code review.

Track 5 sits inside the substrate proof; Track 4 sits between the
substrate and external nondeterminism.

## Build

The Lean toolchain version lives in `lean-toolchain` (currently
`leanprover/lean4:v4.29.0`). The standard Lake commands work:

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

For direct Lake workflows, `nix develop` still provides a working Lean
toolchain in the repo shell. The repo's pre-commit hook checks theory
changes through the flake surface (`nix build .#cortex-theory`) so that
local commits and CI agree on the Lean gate.

## Status

| Track | Statements | Proved | Axiomatized |
|---|---|---|---|
| 1a. Graph relation semantics | finite relation denotation + Mokhov laws | relation-level laws | none |
| 1b. Graph denotational AST laws | AST laws over graph equivalence | denotational law surface | none |
| 1c. Graph quotient laws | lifted quotient equality laws | pending | none |
| 2. Fixed-topology Pulse kernel | edge-derived DAG/state/fact/frontier/closure/recovery surface | frontier antichain, fact commutativity, closure idempotence, topology-domain/output/causal preservation, structural recovery predicate | none |
| 3. Rewrite soundness | 3 | 0 | 3 |
| 4. Provider / sparks | — | — | not started |
| 5. Substrate / consumer boundary | — | — | not started |

Discharging the remaining axioms is the actual work. The scaffold's only
job is to make the obligation graph compile and run end-to-end so that
proof debt is visible and each axiom-to-theorem promotion has a home to
land in.
