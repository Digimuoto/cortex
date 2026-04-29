---
title: "ADR 0036 - Latent Branch Budget and Recovery Policy"
description:
  "States the budget and recovery policy for closed-world latent branches under the current
  selected-branch materialization model."
sidebar:
  label: "0036. Latent branch budget"
  order: 36
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/Reference/Wire/conditionality.md
  - docs/Roadmap/Plans/rewrite-materialization-and-recovery.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #99"
---

# ADR 0036 - Latent Branch Budget and Recovery Policy

## Status

Proposed - documents the current selected-branch policy and separates it from possible reserved
capacity policies.

## Context

Latent branches are closed-world alternatives. Only one branch can become live, so summing the cost
of every branch is a poor semantic fit. The conditionality reference already records the right
intuition: branch reserve is closer to `max` than `sum`, while the current runtime does not yet
reserve latent capacity.

The current implementation realizes selected branches through ordinary admitted rewrites. That means
the selected branch consumes rewrite budget when it is actualized. If unrelated rewrites consume the
remaining budget first, a later branch actualization can fail admission. That is honest current
behavior, but it is not the same as promising that every compiled latent branch is already reserved
and guaranteed.

Recovery also needs a precise story. A crash around branch selection must not turn latent
alternatives into live fan-out or allow a different branch to materialize silently.

## Decision

Under the current runtime model, latent branches use selected-branch budgeting:

- unselected branches do not consume runtime rewrite budget;
- the selected branch consumes ordinary rewrite budget at actualization time;
- branch actualization is admitted or rejected by the same durable rewrite admission path as other
  runtime graph evolution;
- the runtime does not yet guarantee capacity for every compiled latent branch;
- recovery replays the admitted selected branch from durable rewrite state;
- unselected branches remain sealed latent alternatives in the compiled artifact and are never
  materialized for that run. The current model has no durable "discard branch" event.

This policy is intentionally narrower than a future reserved-capacity model. If Cortex later wants
to guarantee that every compiled latent branch can always materialize, that should be a separate
decision introducing max-branch reservation or another escrow rule.

## Consequences

### Positive

- Matches the current runtime implementation and rewrite-budget accounting.
- Avoids charging for branches that cannot all become live.
- Keeps branch materialization auditable through the existing rewrite log and watermark machinery.
- Leaves room for a future reserved-capacity ADR without overstating current guarantees.

### Negative

- A selected branch may fail if earlier rewrites have exhausted the remaining budget.
- Authors cannot yet treat compiled latent branches as prepaid guaranteed capacity.
- Operators need clear rejected-rewrite events when branch actualization fails after selection.

### Obligations

- Docs must distinguish selected-cost semantics from max-reserved latent capacity.
- Runtime recovery tests should cover crashes before branch selection, after selection but before
  materialization, and after materialization.
- Lean theorem targets: selected-cost budget preservation, stating that only the admitted selected
  branch consumes rewrite budget, and recovery determinism, stating that replay materializes the
  same selected branch without making unselected alternatives live.
- ADR 0038 tracks the concrete theorem names and implementation issues for these proof targets.
- After acceptance, architecture chapter 07, the rewrite reference, and the recovery plan should
  distinguish selected-cost semantics from any future reserved-capacity policy.
- Any future capacity guarantee must specify whether it reserves `max(branchCosts)`, reserves per
  branch family, or changes the rewrite-budget algebra.

## Alternatives considered

- **Sum-prepay all branches** - rejected because it charges for mutually exclusive futures and makes
  large branch families unnecessarily expensive.
- **Max-reserve branch families now** - deferred because it requires new runtime accounting and
  recovery rules beyond the current selected-branch implementation.
- **Make latent branch actualization free** - rejected because selected branches still add live
  topology and must remain bounded by runtime authority.

## Related

- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)
- [../Roadmap/Plans/rewrite-materialization-and-recovery.md](../Roadmap/Plans/rewrite-materialization-and-recovery.md)
- [0005-budgeted-rewrite-admission-and-materialization.md](0005-budgeted-rewrite-admission-and-materialization.md)
- [0007-latent-branch-conditional-lowering.md](0007-latent-branch-conditional-lowering.md)
- [0009-rewrite-provenance-and-topology-integrity.md](0009-rewrite-provenance-and-topology-integrity.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0034-wire-pure-select-actualization-authority.md](0034-wire-pure-select-actualization-authority.md)
- [0035-wire-rewrite-algebra-forms.md](0035-wire-rewrite-algebra-forms.md)
- [0037-wire-latent-structural-control.md](0037-wire-latent-structural-control.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
- GitHub #99
