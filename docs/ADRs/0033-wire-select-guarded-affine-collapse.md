---
title: "ADR 0033 - Wire Select as Guarded Affine Collapse"
description:
  "Defines `select(...)` as guarded affine alternatives under one linear boundary contract, with
  superposition collapse retained only as a colloquial explanation."
sidebar:
  label: "0033. Guarded collapse"
  order: 33
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/Wire/grammar.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #99"
---

# ADR 0033 - Wire Select as Guarded Affine Collapse

## Status

Proposed - extends ADR 0007 with resource semantics for latent conditional branches. ADR 0037 places
`select(...)` in the broader category of latent structural control operators.

## Context

ADR 0007 establishes that Wire conditionals lower to condition anchors with latent branch fragments.
The conditionality reference states the target model as exclusive-output reduction: compiled
possibility is wider than current actuality, and exactly one continuation becomes live.

The resource question is what kind of obligation lives inside those alternatives before selection.
If every branch edge were ordinary linear topology, all branches would need to run or be discharged
as live work. That is the fan-out mistake ADR 0007 rejects. If branches were hidden inside
imperative code, the workflow artifact would stop telling the truth about possible obligations.

Wire needs a model that preserves both intuitions: several futures are represented, but only one
becomes actual runtime topology. Colloquial explanations may call that state a superposition, but
the formal term should be guarded affine collapse.

## Decision

Wire should define `select(...)` formally as guarded affine choice under a linear boundary contract.
Colloquial explanations may describe the intuition as superposition collapse: the wavefront reaches
a conditional, possibilities fan out as latent alternatives, and selection collapses the frontier to
one live continuation. Formal specs, theorem statements, and implementation names should use guarded
affine collapse.

The rules are:

- The selecting graph exposes one exclusive output boundary.
- Each arm provides a latent continuation for one variant of that boundary.
- Each branch-local resource is guarded by its arm key and is affine before selection.
- Branch validation is universal: every arm must be locally valid if chosen.
- Branch execution is exclusive: runtime selects exactly one arm.
- The selected arm is promoted into the live linear resource context.
- Unselected arms are discarded and never become runnable topology.
- The reduced `select(...)` expression exposes the common downstream boundary produced by the
  productive arms.

## Consequences

### Positive

- Explains why branch internals are not globally linear before selection.
- Preserves the existing latent-branch model without lowering conditionals to ordinary fan-out.
- Gives a controlled author-facing metaphor for branch choice while retaining a precise formal
  model.
- Aligns with boundary resources: the outer boundary is linear, branch interiors are guarded affine,
  and the chosen branch becomes linear after collapse.

### Negative

- The word "superposition" can mislead if used without the formal guarded-affine explanation.
- Tooling and docs must keep latent branch visibility distinct from materialized topology.
- Native n-way selection still lowers to a nested binary condition tree, not a native n-way runtime
  node. The runtime guard source that drives that tree - reading a producer's committed output
  variant label and routing it through the compiled then/else keys - is implemented as
  `committedVariantConditionBinding` (ADR 0062, GitHub #314); a native n-way runtime representation
  remains future work.

### Obligations

- Reference docs should use "superposition" only as the intuition and "guarded affine choice" as the
  formal model.
- Type and proof work should validate every branch while executing at most one branch.
- Lean theorem target: guarded-affine collapse soundness, stating that if every arm is valid from
  its variant boundary to the common downstream boundary, then selecting one arm promotes only that
  arm to the live linear context and preserves the reduced graph boundary.
- ADR 0038 tracks the concrete theorem names and implementation issues for this proof target.
- After acceptance, architecture chapter 05 and the conditionality reference should adopt the
  guarded-affine-collapse vocabulary.
- Runtime and operator surfaces should continue to distinguish compiled latent alternatives from
  materialized graph state.

## Alternatives considered

- **Ordinary fan-out** - rejected because all branches would become live under readiness rules.
- **Hidden imperative branching** - rejected because the compiled artifact would omit real possible
  obligations.
- **Literal probabilistic or quantum semantics** - rejected because Wire branch selection is
  deterministic or replayable runtime choice, not amplitude evolution.

## Traceability

- Feature keys: `wire.select_guarded_affine`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/conditionality.md`
- Implementation: `src/Cortex/Wire/Syntax.hs` (`ExprSelect`, `SelectArm`),
  `src/Cortex/Wire/Compile.hs` (`lowerSelectStep`, `buildSelectConditionTree`,
  `SelectAdmissionArtifact`)
- Tests: `test/Cortex/Wire/CompileSpec.hs` (`nested select`, select admission-artifact rows)
- Theory/proof:
  [the "Select source admission" and "Select actualization" rows](../Reference/proof-status.md)
- Tracking: GitHub #99

## Related

- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Reference/Wire/grammar.md](../Reference/Wire/grammar.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0028-wire-topology-composition-and-boundary-labels.md](0028-wire-topology-composition-and-boundary-labels.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
- GitHub #99
