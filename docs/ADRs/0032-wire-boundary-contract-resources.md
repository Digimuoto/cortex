---
title: "ADR 0032 - Wire Boundary Contracts as Planning Resources"
description:
  "Treats Wire boundary contracts, not nodes themselves, as the local resources that rewrites,
  conditionals, and planning certificates must account for."
sidebar:
  label: "0032. Boundary resources"
  order: 32
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #99"
---

# ADR 0032 - Wire Boundary Contracts as Planning Resources

## Status

Proposed - establishes the resource vocabulary used by the follow-up Wire rewrite and conditionality
ADRs.

## Context

Wire already has strong global admission checks: rewrite proposals must fit the remaining budget,
stay inside the registered executor and contract vocabulary, preserve topology validity, and
materialize through the durable rewrite log. Lean also models proof-carrying rewrite chains whose
per-step certificates lift to chain-level preservation.

Those mechanisms still leave an important semantic distinction implicit. A node is both an
addressable runtime/provenance object and a boundary of port contracts. Rewrites and conditionals do
not always consume the node as an object. A retained conditional owner stays visible for lineage,
and an append continuation keeps the anchor computation in place. What must be accounted for locally
is the boundary contract that the operation consumes, forwards, or transforms.

Treating the node itself as the linear resource is therefore too coarse. Treating only global
predicates as the accounting surface is too diffuse. Wire needs a local vocabulary for the resources
that graph operations spend and return.

## Decision

Wire should treat boundary contracts as first-class planning resources. A rewrite, conditional
selection, or planner certificate consumes or transforms a boundary obligation and must provide a
witness for how the resulting graph satisfies the exposed contract.

The resource vocabulary is:

| Resource                  | Meaning                                                                         | Mode                                                     |
| ------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Boundary obligation       | The input/output contract boundary exposed by a node or graph expression.       | Linear unless explicitly guarded or optional.            |
| Rewrite slot              | Exclusive authority to transform a boundary at an anchor in one planning epoch. | Linear.                                                  |
| Port obligation           | A concrete labeled input or output obligation within a boundary.                | Linear, affine, or graded according to port cardinality. |
| Branch-local obligation   | A boundary obligation inside a not-yet-selected conditional branch.             | Guarded affine.                                          |
| Rewrite budget            | The natural-vector budget consumed by admitted structural change.               | Graded.                                                  |
| Namespace freshness       | Authority to allocate deterministic names under an anchor or namespace.         | Ghost planning resource.                                 |
| Registry/contract witness | Evidence that introduced nodes stay within the registered boundary.             | Ghost proof resource.                                    |

This is a semantic layer over the existing graph algebra. Mokhov overlay and connect still describe
the denotation of graph expressions. Boundary resources describe whether a graph operation is
locally well-accounted before it is admitted or proved safe.

## Consequences

### Positive

- Separates node identity from the contract obligation carried by the node boundary.
- Gives later ADRs precise language for replacement, append, retained envelopes, and conditionals.
- Makes it possible to state local no-double-spend and port-coverage obligations without relying
  only on global topology checks.
- Matches the existing rewrite-budget model by treating budget as a graded resource rather than a
  boolean permission.

### Negative

- Adds another semantic layer that authors and implementers must keep distinct from graph equality.
- Requires care around cardinality: not every port-like thing is exactly-once linear.
- Does not by itself prove Haskell runtime correspondence or Lean-side construction witnesses.

### Obligations

#### Semantic and Proof Obligations

- Future rewrite and conditional specs should say which boundary obligation they consume and which
  boundary they produce.
- Lean models should prefer resource-context predicates over ad hoc per-node token language.
- Lean theorem target: resource-consumption faithfulness, stating that a valid operation consumes
  exactly the declared boundary resources.
- Lean theorem target: per-epoch rewrite-slot uniqueness, stating that a rewrite slot is spent at
  most once in a planning epoch.
- Lean theorem target: boundary preservation, stating that a valid operation preserves the exposed
  boundary promised by the operation.
- ADR 0038 tracks the concrete theorem names and implementation issues for these proof targets.
- Runtime prose should avoid claiming that nodes are linear resources. The stricter claim is that
  boundary obligations are locally accounted resources.

#### Documentation Obligations After Acceptance

- After acceptance, architecture chapters 03, 05, and 07 should introduce the boundary-resource
  vocabulary and cite this ADR stack.

## Alternatives considered

- **Nodes as linear tokens** - rejected as the canonical model because retained owners, append
  continuations, and provenance envelopes can keep node identity while transforming boundary
  obligations.
- **Global predicates only** - rejected because global admission checks are necessary but do not
  express local resource consumption, guarded branch discard, or no-double-rewrite discipline.
- **Runtime leases only** - rejected because leases can protect implementation state but do not
  state the source-language or proof-side contract semantics.

## Related

- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/Wire/contracts-ports-and-matching.md](../Reference/Wire/contracts-ports-and-matching.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [0005-budgeted-rewrite-admission-and-materialization.md](0005-budgeted-rewrite-admission-and-materialization.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0009-rewrite-provenance-and-topology-integrity.md](0009-rewrite-provenance-and-topology-integrity.md)
- [0028-wire-topology-composition-and-boundary-labels.md](0028-wire-topology-composition-and-boundary-labels.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0036-wire-latent-branch-budget-recovery.md](0036-wire-latent-branch-budget-recovery.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
- GitHub #99
