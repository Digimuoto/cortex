---
title: "ADR 0034 - Pure Selectors and Restricted Actualization Authority"
description:
  "Allows deterministic pure selectors to drive `select(...)` collapse without giving pure nodes
  general graph rewrite authority."
sidebar:
  label: "0034. Pure select authority"
  order: 34
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Reference/Wire/pure-execution.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #99"
---

# ADR 0034 - Pure Selectors and Restricted Actualization Authority

## Status

Proposed - separates deterministic branch-choice computation from structural rewrite authority.

## Context

Wire pure execution is deterministic and authority-free. A pure node can transform JSON-shaped
values from its inputs into declared outputs, but it cannot call tools, access durable state,
perform host callbacks, or author arbitrary runtime graph changes.

Executor-variant selection is the existing baseline. An executor node may declare a sum-grouped
output boundary, the runtime observes which variant the executor produced, and `select(...)`
resolves arm keys against that declared variant identity. In that case the selector source is the
executor's typed output boundary, not CorePure.

Conditionals need deterministic branch selection. That makes CorePure attractive as the selector
language: it can compute an arm key from upstream values, and replay can recompute or validate the
same choice without executor authority. But if "pure selector" becomes "pure node with rewrite
authority", pure execution would lose its clean authority boundary.

The language-level distinction is that CorePure `if ... then ... else ...` selects a value, while
Wire `select(...)` selects a continuation graph. Those operations must stay separate even when the
first drives the second.

## Decision

Pure execution may compute the branch choice for a compiled `select(...)`, but pure nodes do not
receive general rewrite authority. Whether the selected arm comes from an executor-emitted variant
or from a pure expression, the structural effect belongs to the compiled `select(...)` operator and
runtime admission.

A compiled `select(...)` may carry a compiler-minted, single-use actualization capability:

```text
SelectActualize owner selectedArm
```

That capability is narrower than `GraphRewrite` authority:

- it is bound to one conditional owner;
- it can actualize only one sealed branch from the compiled branch family;
- it cannot invent new nodes outside that branch;
- it cannot target unrelated anchors;
- it still passes through runtime admission, budget accounting, and durability;
- it is consumed once when the branch is actualized.

CorePure may produce the selected arm key or selection value. Executor outputs may produce the same
selection through sum-grouped variants. In both cases the selection value chooses an arm; it does
not itself carry arbitrary graph authority.

## Consequences

### Positive

- Preserves pure execution as deterministic and authority-free.
- Gives conditionals replayable branch choice without hiding topology in imperative stage code.
- Narrows the structural authority surface to a compiler-generated capability with one owner and one
  branch family.
- Fits the boundary-resource model: the pure selector computes collapse, while `SelectActualize`
  consumes the linear outer boundary and promotes one guarded branch.

### Negative

- Requires compiler/runtime vocabulary for restricted actualization instead of reusing arbitrary
  rewrite authority in docs and proofs.
- The current implementation realizes conditionals through retained-anchor `AppendAfter`, so the
  conceptual capability is ahead of the runtime naming.

### Obligations

- Pure execution docs must keep value-level `if` separate from topology-level `select(...)`.
- Pure-selector failures need a clear failure surface distinct from rejected branch materialization.
- Runtime admission should be able to distinguish compiler-minted branch actualization from
  planner-authored open rewrites.
- Lean theorem target: selected-branch admissibility, stating that a `SelectActualize` capability
  minted for one owner and arm can only admit the sealed branch for that owner and cannot produce an
  arbitrary planner rewrite.
- Future Lean statements should model the actualization capability separately from arbitrary planner
  rewrite certificates.
- ADR 0038 tracks the concrete theorem names and implementation issues for pure selector authority
  and selected-branch actualization.

## Alternatives considered

- **Give pure nodes general rewrite authority** - rejected because it collapses the authority
  boundary established by pure execution.
- **Require selectors to be effectful executor nodes** - rejected because deterministic branch
  choice should not require model/tool authority.
- **Materialize every branch and let pure values route around them** - rejected because it revives
  ordinary fan-out and makes unchosen branches runnable topology.

## Traceability

- Feature keys: `rewrite.select_actualization_authority`
- Public surface: `Cortex.Wire`,
  [`docs/Reference/Wire/pure-execution.md`](../Reference/Wire/pure-execution.md)
- Implementation: `src/Cortex/Wire/Circuit/Lowering.hs` (`lowerConditionNode`,
  `CircuitConditionSelection`, `circuitConditionSelectBranch`)
- Tests: `test/Cortex/Wire/Circuit/CompilerSpec.hs`
  (`admits only the selected latent branch through the rewrite witness surface`)
- Theory/proof: [Select actualization — `proof-status.md`](../Reference/proof-status.md)
- Tracking: GitHub #99

## Related

- [../Reference/Wire/pure-execution.md](../Reference/Wire/pure-execution.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [0005-budgeted-rewrite-admission-and-materialization.md](0005-budgeted-rewrite-admission-and-materialization.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0010-wire-closed-authority-and-three-layer-stack.md](0010-wire-closed-authority-and-three-layer-stack.md)
- [0020-wire-pure-output-equations.md](0020-wire-pure-output-equations.md)
- [0023-corepure-expression-surface.md](0023-corepure-expression-surface.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
- GitHub #99
