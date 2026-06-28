---
title: "ADR 0035 - Wire Rewrite Algebra Forms"
description:
  "Separates conceptual boundary laws from their current Wire rewrite runtime realizations."
sidebar:
  label: "0035. Rewrite forms"
  order: 35
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/Reference/Wire/conditionality.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
---

# ADR 0035 - Wire Rewrite Algebra Forms

## Status

Proposed - clarifies the conceptual rewrite taxonomy before further runtime or Lean changes.

## Context

The rewrite reference currently exposes forms such as `ExpandNode` and `AppendAfter`. The current
conditional runtime realizes selected latent branches through retained-anchor `AppendAfter`, which
is operationally useful because the condition owner remains visible for lineage and the selected
fragment materializes behind it.

That operational shape should not become the general mental model for expansion. If a rewrite claims
to replace a node, the replacement graph must satisfy the original boundary contract of the node.
Appending work after the node is sequencing, not substitution. The distinction matters for port
obligations, provenance, and future Lean statements.

## Decision

Wire should distinguish conceptual boundary laws from current runtime constructors.

The conceptual boundary laws are:

| Conceptual boundary law          | Resource use                                                                    | Contract effect                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Contract-preserving substitution | Consumes one rewrite slot at the anchor and consumes the anchor boundary.       | The replacement graph must expose the consumed anchor boundary.                                                                                   |
| Append continuation              | Consumes one rewrite slot at the anchor while retaining the anchor node.        | The anchor satisfies its own output; the continuation consumes that output and produces a new downstream boundary.                                |
| Conditional branch actualization | Consumes one owner-bound actualization capability and the owner's rewrite slot. | The selected branch consumes its variant boundary and yields the common downstream boundary, realizing the guarded-affine collapse from ADR 0033. |
| Observation/instrumentation      | No v1 resource path; a future form would need to consume an anchor slot.        | Observers must not consume or alter the anchor's required boundary.                                                                               |

The current runtime realization is:

| Boundary law                     | Current realization                  | Notes                                                                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Contract-preserving substitution | `ExpandNode anchor mode spec`        | v1 `GraphRewrite` constructor.                                                                                                                                                                                                          |
| Append continuation              | `AppendAfter anchor spec`            | v1 `GraphRewrite` constructor.                                                                                                                                                                                                          |
| Conditional branch actualization | `AppendAfter owner selectedFragment` | Current retained-owner conditional lowering realizes the selected branch with ordinary rewrite machinery. `SelectActualize owner selectedArm` names the restricted capability from ADR 0034; it is not a v1 `GraphRewrite` constructor. |
| Observation/instrumentation      | None                                 | Potential future boundary law only. It is not admitted by v1 and is not added by this ADR.                                                                                                                                              |

The conditional row names target resource semantics. In the current v1 realization, there is one
ordinary `AppendAfter` admission; the owner-bound actualization capability is not a separately
persisted runtime token.

`AppendAfter` remains a valid operational mechanism for the current retained-owner conditional
implementation. It should not be described as the canonical semantics of node expansion. Expansion
is substitution into an anchor boundary; conditional branch actualization is retained-owner branch
collapse. Both can preserve provenance, but they preserve it through different laws.

ADR 0037 separates this conditional actualization law from the broader graph-denotation layer:
latent branch families are not plain Mokhov graphs before resolution, even when the selected result
lowers to ordinary graph composition.

## Consequences

### Positive

- Prevents replacement and sequencing from being conflated.
- Makes the original port contract of an expanded node explicit.
- Lets the current conditional implementation keep using retained anchors without claiming that all
  rewrites are append-style.
- Gives proof work clearer theorem targets for substitution, continuation, and selection.

### Negative

- May require renaming or documentation around existing constructors whose operational names are
  broader than their conceptual role.
- Introduces more cases for admission docs and future mechanization.
- Names observation/instrumentation only as a deferred boundary law, so any future implementation
  still needs a separate ADR and runtime-version bump.
- Does not by itself change the current runtime representation.

### Obligations

- Rewrite docs should state which rewrite concept each runtime constructor realizes.
- Rewrite docs should state which rewrite slot each admitted constructor spends.
- Future constructors should be added only when they correspond to a distinct boundary law.
- Observation/instrumentation must remain non-admitted until a follow-up ADR introduces a concrete
  constructor and admission rules.
- Conditional lowering docs should treat retained-anchor `AppendAfter` as the current realization of
  branch actualization, not as the semantic definition of all conditionals.
- Lean theorem targets: boundary preservation under substitution, append-continuation boundary
  preservation, and selection realization of guarded-affine collapse. Observation has no theorem
  target until a concrete constructor exists.
- ADR 0038 tracks the concrete theorem names and implementation issues for these proof targets.

## Alternatives considered

- **Use append as the universal rewrite model** - rejected because replacement must discharge the
  original anchor boundary rather than merely run after the anchor.
- **Use substitution as the universal rewrite model** - rejected because append continuations,
  observers, and retained conditional owners are legitimate non-substitutional graph operations.
- **Keep provenance only in side tables and erase retained owners** - rejected because current
  operator and recovery surfaces benefit from lineage being visible in the graph evolution story.

## Traceability

- Feature keys: `wire.rewrite_algebra_forms`
- Public surface: `Cortex.Pulse` (the `GraphRewrite` constructors), `docs/Reference/rewrites.md`
- Implementation: `src/Cortex/Pulse/Rewrite.hs` (`GraphRewrite`, `ExpandNode`, `AppendAfter`,
  `ExpansionMode`, `RewriteAnchorDisposition`)
- Tests: `test/Cortex/Pulse/GraphRewriteSpec.hs` (`ExpandNode`, `AppendAfter`)
- Theory/proof:
  [the "Rewrite boundary laws" and "Boundary resource algebra" rows](../Reference/proof-status.md)

## Related

- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [0005-budgeted-rewrite-admission-and-materialization.md](0005-budgeted-rewrite-admission-and-materialization.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0009-rewrite-provenance-and-topology-integrity.md](0009-rewrite-provenance-and-topology-integrity.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
