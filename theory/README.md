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

The five tracks are sketched below. The current scaffold lands the
type signatures and admits the load-bearing theorems as `axiom`s;
each track is then a sequence of obligations to discharge.

### Track 1 — Graph algebra (Mokhov)

`Cortex.Graph.Core` defines the inductive `Graph α` with constructors
`empty`, `vertex`, `overlay`, `connect`. `Cortex.Graph.Relation`
defines the finite relation denotation used by the Haskell
`toRelation` implementation and proves the Mokhov laws on that
denotation with mathlib `Finset`s. `Cortex.Graph.Laws` still states the
AST-facing laws as axioms because raw syntax trees are not definitionally
equal; discharging those axioms requires the next quotient step
(`Cortex.Graph.Quotient`, TODO).

**Headline obligation:** `connect_decomposition`
(`g · h · k = g · h ⊕ g · k ⊕ h · k`). This is what licenses circuit
simplification and the executor's compatibility-edge derivation. The
relation-level theorem now exists; the remaining obligation is lifting it
through graph equivalence.

### Track 2 — Frontier safety

`Cortex.Pulse.Frontier` models the runtime as a transition system
over `State`. The headline invariant — every frontier node has
terminal dependencies — is proved trivially from the filter
definition. The interesting obligations are:

- `step_independent`: parallel commutativity of frontier subsets.
  Licenses the executor's parallel scheduling.
- `progress`: every non-terminal reachable state advances or stalls
  with a structural reason (cycle, missing executor, budget).
- `determinism_modulo_sparks`: replayability under fixed external
  sparks.

These admit the audit-trail story: given the same plan, same initial
state, and same sequence of LLM/IO results, Pulse produces the same
final state. This is the property finance regulators need.

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
| 1b. Graph quotient laws | AST laws over graph equivalence | pending | 9 |
| 2. Frontier safety | 4 | 1 | 3 |
| 3. Rewrite soundness | 3 | 0 | 3 |
| 4. Provider / sparks | — | — | not started |
| 5. Substrate / consumer boundary | — | — | not started |

Discharging the axioms is the actual work. The scaffold's only job is
to make the obligation graph compile and run end-to-end so that the
proof debt is visible and the first axiom-to-theorem promotion has a
home to land in.
