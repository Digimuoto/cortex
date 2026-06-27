---
title: "ADR 0037 - Wire Latent Structural Control Operators"
description:
  "Names the category for Wire constructs, including `select(...)`, that carry possible topology at
  compile time and materialize only a controlled subset at runtime."
sidebar:
  label: "0037. Latent control"
  order: 37
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #99"
---

# ADR 0037 - Wire Latent Structural Control Operators

## Status

Proposed - names the category that `select(...)` belongs to and records seams that should stay
explicit before Wire adds more operators in the same family.

## Context

Wire's algebraic graph layer is intentionally small. `<>` and `=>` lower to overlay and connect,
refining Mokhov-style algebraic graphs with port labels and contract matching. A materialized
conditional result can be described in that algebra after selection:

```text
selector => selected_branch => continuation
```

The pre-selection conditional is different:

```wire
selector select(
  A: branch_a,
  B: branch_b
)
```

That expression is not one live graph. It is a sealed family of possible graph fragments, plus a
rule that exactly one member may become live. ADR 0033 defines that rule for `select(...)` as
guarded affine collapse. ADR 0034 then separates branch-choice computation from structural
actualization authority.

This creates an architectural seam: some Wire constructs may carry possible topology that is
compiled, validated, and explained, but not yet materialized as live topology.

## Decision

Wire should name this category **latent structural control operators**.

A latent structural control operator has four layers:

1. **Algebraic result.** After the operator resolves, the live result is an ordinary graph fragment
   expressible with Wire's overlay/connect composition.
2. **Latent family.** Before resolution, the operator carries one or more sealed graph fragments
   that are validated but not live topology.
3. **Proof or compile-time promise.** Compilation checks closure, arm/key coverage, boundary
   compatibility, and authority limits for every possible fragment.
4. **Runtime materialization.** Runtime observes a selector or guard, admits the chosen structural
   effect, persists enough state for replay, and keeps non-chosen fragments from becoming runnable.

`select(...)` is the first operator in this category and the only one accepted by the current Wire
surface. The category does not add new runtime authority by itself. Every member needs its own ADR,
admission rules, budget policy, recovery story, and Lean theorem targets.

## Boundary With Mokhov Algebra

Mokhov overlay/connect remains the graph denotation layer. Latent structural control is not a fifth
Mokhov constructor.

- Before resolution, a latent family is a controlled set of graph possibilities, not a graph.
- After resolution, the selected result lowers to ordinary graph composition.
- Equational laws over overlay/connect apply to the selected materialized graph, not automatically
  to the sealed family before selection.

This keeps the graph algebra small while allowing Wire to represent structured runtime choice
without lowering it to ordinary fan-out or hiding it in imperative executor code.

## Candidate Operators

The category is intentionally broader than `select(...)`, but candidates are not admitted by this
ADR.

| Candidate                           | Shape                                                                   | Main unresolved seam                                            |
| ----------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------- |
| `select(...)`                       | Exactly one of `N` latent continuations becomes live.                   | Already scoped by ADRs 0033-0036.                               |
| `onFailure` / `recover`             | A failure variant actualizes a recovery continuation.                   | Failure taxonomy, retry interaction, and provenance.            |
| `optional`                          | Zero or one continuation becomes live.                                  | Boundary typing when no continuation is selected.               |
| `race` / `firstSuccess`             | Several candidates may start, but one winner remains semantically live. | Cancellation, side effects, replay, and budget accounting.      |
| Bounded `repeat` / `unfold`         | A guarded continuation may actualize repeatedly up to a bound.          | Loop bounds, acyclicity, and accumulated budget.                |
| Data-indexed `forEach` / `fanoutBy` | One continuation actualizes for each selected data item.                | Cardinality, namespace generation, and branch-cost aggregation. |

Any such operator must be introduced as a separate decision. The default stance is rejection until
its boundary law, resource consumption, runtime realization, and recovery behavior are explicit.

## Open Seams

- **Denotation.** Decide whether Lean models latent families as finite maps from guards to graph
  fragments, as an indexed family of resource contexts, or as a separate control layer that lowers
  into graph algebra after resolution.
- **Authority.** Decide which capabilities are compile-time witnesses only and which become durable
  runtime facts. In v1, `SelectActualize` is not a separately persisted token.
- **Composition.** State when latent operators may appear under `<>`, `=>`, or inside another latent
  operator, and whether any distributive laws are valid before resolution.
- **Budget.** Distinguish selected-cost, max-reserved, sum-prepaid, and escrow policies per
  operator. ADR 0036 chooses selected-cost only for current latent branches.
- **Recovery.** Decide whether an operator needs a distinct durable selection event or whether an
  admitted rewrite row is the only durable fact.
- **Failure and cancellation.** Operators such as `race`, `recover`, and bounded repetition require
  side-effect and retry semantics beyond the `select(...)` baseline.
- **Proof targets.** Each operator needs theorem targets for branch validity, boundary preservation,
  resource consumption, and replay determinism.

## Prior Art

- **Algebraic graphs** - Mokhov's overlay/connect algebra is the graph-denotation layer that Wire
  keeps small and does not extend for control.
- **Guarded commands** - Dijkstra's guarded-command discipline is useful prior art for separating
  guarded alternatives from ordinary sequential composition.
- **Linear logic and session types** - additive choice is the closest proof-theoretic analogue for
  guarded alternatives where one branch is selected and the others are discarded.
- **Selective applicative functors and build-system semantics** - useful prior art for separating
  static structure from dynamic choice without hiding possible dependencies.
- **Graph transformation control** - graph transformation literature distinguishes graph rewrite
  rules from control programs that choose, sequence, or repeat those rules.

## Consequences

### Positive

- Gives `select(...)` a home without pretending it is plain overlay/connect.
- Prevents future control constructs from entering Wire as ad hoc rewrite forms.
- Makes the proof, budget, recovery, and authority seams visible before new operators are accepted.
- Preserves Mokhov algebra as the graph-denotation layer.

### Negative

- Adds another layer of terminology that must stay separate from graph composition and runtime
  rewrite constructors.
- Leaves several useful workflow constructs explicitly deferred.
- Requires future docs to distinguish compile-time latent topology from live materialized topology.

### Obligations

- Architecture chapter 03 should state that latent structural control lowers to graph algebra after
  resolution rather than extending Mokhov's constructor set.
- Architecture chapter 05 and the conditionality reference should place `select(...)` in this
  category.
- Architecture chapter 07 and the rewrite reference should distinguish latent control from ordinary
  planner-authored rewrites.
- Lean theorem targets for future operators must include denotation-after-resolution and
  no-live-topology-before-resolution statements.
- ADR 0038 tracks the concrete theorem names and implementation issues for `select(...)` and
  deferred latent-control proof targets.

## Alternatives considered

- **Make `select(...)` a graph-algebra constructor** - rejected because pre-selection alternatives
  are not one graph and would enlarge the Graph layer beyond overlay/connect.
- **Treat `select(...)` as an ordinary rewrite constructor** - rejected because the branch family is
  compile-time sealed and typed before runtime admission; arbitrary planner rewrites do not have
  that shape.
- **Hide the branch choice inside executor code** - rejected because it makes possible topology
  invisible to compilation, proof, replay, and operator surfaces.

## Traceability

- Feature keys: `wire.latent_structural_control`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/conditionality.md`
- Implementation: `src/Cortex/Wire/Syntax.hs` (`ExprSelect`, `SelectArm` — `select(...)`, the only
  member admitted by the current Wire surface), `src/Cortex/Wire/Compile.hs` (`lowerSelectStep`)
- Tests: `test/Cortex/Wire/CompileSpec.hs` (`nested select`)
- Theory/proof: [the "Select source admission" row](../Reference/proof-status.md)
- Tracking: GitHub #99

## Related

- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0028-wire-topology-composition-and-boundary-labels.md](0028-wire-topology-composition-and-boundary-labels.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
- GitHub #99
