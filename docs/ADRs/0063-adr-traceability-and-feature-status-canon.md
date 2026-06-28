---
title: "ADR 0063 — Feature Status Matrix and Feature Key Contract"
description:
  "Feature ADRs declare stable feature keys in Traceability blocks, and feature-status.md is the
  capability/status matrix joined to those keys."
sidebar:
  label: "0063. Feature status matrix"
  order: 63
status: accepted
date: 2026-06-27
superseded_by: null
related:
  - docs/ADRs/0001-canonical-documentation-contract.md
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Reference/proof-status.md
  - docs/Reference/feature-status.md
  - docs/Templates/adr.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
---

# ADR 0063 — Feature Status Matrix and Feature Key Contract

## Status

Accepted — establishes the feature-key identity contract, the `## Traceability` join for feature
ADRs, and the capability/status matrix. ADR 0001 owns the general documentation and ADR lifecycle;
this ADR owns only the feature-status slice. This is a docs-process governance decision, not a
shipped substrate capability, so it carries **no** Traceability block itself.

## Context

Cortex has a real ADR canon for decisions, but ADR status alone cannot express current capability,
verification, or proof state.

- ADR `status` answers whether a decision is `proposed`, `accepted`, or `superseded`; it does not
  answer whether code is shipped, tests exist, or proof correspondence has landed.
- One good precedent already exists: [`proof-status.md`](../Reference/proof-status.md) separates the
  human claim, Lean status, Haskell correspondence, proof links, and remaining gap. ADR 0038 records
  the decision while the Reference page owns the current proof-state view.
- Forcing release or implementation state into ADR prose would make ADRs worse. Many ADRs are not
  features at all: ownership boundaries, proof obligations, numbering policy, the module tree, and
  import direction.

The missing piece is a durable identity that joins feature ADRs, current status, source, tests,
proof rows, Reference docs, and release tooling without turning issues or PRs into canon.

## Decision

Feature status is a keyed Reference matrix. Feature ADRs declare stable feature keys; the matrix
records the current status and evidence for those keys.

### 1. Feature ADR Traceability block

A feature/runtime/language/proof ADR carries a `## Traceability` block; governance, boundary,
numbering/process, and ledger ADRs omit it.

```markdown
## Traceability

- Feature keys: `pulse.atomic_suspend_settlement`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/...`
- Implementation: `src/Cortex/Pulse/...`
- Tests: `test/Cortex/...`
- Theory/proof: link to the relevant `docs/Reference/proof-status.md` row(s)
```

There is **no release-note field** in the ADR. Release framing belongs to release tooling fed by the
current-state Reference matrix, not to append-only decision prose.

Whether the block is required follows the ADR's primary category:

- **Required** for feature/runtime/language/proof ADRs — Pulse runtime, Rewrite admission,
  Conditionals/selection, Wire language/elaboration/topology, Wire executor & node, CorePure,
  Capability & executors, Artifact & provenance, Packaging/CLI, and Proof-track _feature_ ADRs.
- **Omitted** for governance and meta ADRs — Boundary & governance, numbering/process policy, and
  the proof-track _ledger_.

### 2. Feature keys are the join primitive

The feature key is the stable identity that joins an ADR, a matrix row, source, tests, theory, and a
release line. Its grammar and lifecycle:

- **Grammar.** Lowercase dotted. The first segment is the subsystem / Stage-3 category prefix
  (`pulse`, `rewrite`, `wire`, `corepure`, `capability`, `cli`, `packaging`, `proof`). Remaining
  segments name the capability in `snake_case`.
- **One key per capability.** The key names the capability, not the ADR. An ADR may declare several
  keys; a key has exactly one governing ADR at a time.
- **Allocation.** A key is allocated when its `feature-status.md` row is created, and recorded in
  the governing ADR's Traceability block.
- **Stability.** Keys are never renamed or reused. A retired capability keeps its key with
  implementation status `retired`. ADR renumbering does not touch feature keys.

### 3. `feature-status.md` is the capability/status canon

[`feature-status.md`](../Reference/feature-status.md) is the current-truth matrix for governed
substrate capabilities. It is **capability/status canon, not marketing feature canon**: rows cover
substrate capabilities that may not be user-visible in any product sense. Columns:

`Feature key | Capability | Governing ADR | ADR status | Impl status | Tests | Theory | Reference`

Active issues, draft PRs, and checklist state do not live in the matrix. Proposed ADRs may carry
temporary tracker state in their `## Tracking` section under ADR 0001; accepted ADRs and the
feature-status matrix cite durable artifacts only.

### 4. Status dimensions stay separate

Never collapse these into one field:

- **ADR status** — `proposed` | `accepted` | `superseded` | `deprecated` (the decision).
- **Implementation status** — `planned` | `partial` | `implemented` | `verified` | `retired` (the
  code).
- **Proof status** — owned by `proof-status.md`. The matrix's `Theory` cell links to the
  proof-status row; it does not restate Lean/Haskell state, so there is one source of proof truth.

`partial` in `feature-status.md` is a conservative current-state label, not a synonym for "no code"
or "untested." A proposed ADR may govern implemented and tested substrate while remaining `partial`
until acceptance and all required matrix evidence are in place.

### 5. Evidence links are validated, never asserted blind

`just docs-lint` must confirm that every evidence link in a feature-status row — the `Tests`,
`Theory`, and `Reference` cells — resolves to an existing file or anchor. `Impl status` is a status
value, not a path; per-capability implementation paths live in the governing ADR's `## Traceability`
block, not the matrix. The matrix may **under-claim** (an empty cell is allowed and honest); it must
not **dangle** (a link to a path that does not exist fails the check). A row is seeded with its key
and status before its evidence links exist; the links are added as the capability is governed and
verified.

## Alternatives considered

- **Add a feature list to every ADR.** Rejected — it corrupts ADR semantics. Non-feature decisions
  have no features, and the list would rot inside an append-only decision record.
- **Use GitHub issues as the capability canon.** Rejected — issues are planning state and they
  close; canon must be durable.
- **Keep tracker IDs in `feature-status.md`.** Rejected — the matrix is Reference canon, so tracker
  IDs would mix temporary planning state into the current-truth capability view. Proposed ADRs may
  keep temporary tracker state under `## Tracking`; accepted ADRs and Reference matrices should not.
- **Extend `proof-status.md` to cover all features.** Rejected — proof-status is proof-specific and
  rich. The feature matrix links to it rather than absorbing it, avoiding a second proof-truth
  source.

## Consequences

### Positive

- Status drift becomes visible and auditable: a `proposed` ADR governing `implemented` code is now
  expressible, and the gap is a status row rather than a silent inconsistency.
- Releases and summaries can extract from a single current-state source.
- ADRs stay clean one-decision records; the canon gains a status story without changing ADR
  semantics.

### Negative

- One more Reference page to maintain. Its honesty depends on the docs-lint validator and on
  authoring discipline.
- Feature-key allocation is a new lightweight governance step.

### Obligations

- Add the `## Traceability` block to [`docs/Templates/adr.md`](../Templates/adr.md) with
  required-for-feature guidance.
- Create [`docs/Reference/feature-status.md`](../Reference/feature-status.md) and list it in the
  Reference index.
- Implement the docs-lint feature-status validator.
- Author every feature ADR with a Traceability block and a stable feature key; seed the matrix row
  first, then add evidence links as they become concrete.
- Backfill the `## Traceability` block and a feature-status row into pre-existing
  feature/runtime/language/proof ADRs. Governance/boundary/numbering/ledger ADRs remain exempt.
- Status drift is a structural concern owned by `feature-status.md`, not the ADR `status` field.

## Related

- [ADR 0001 — Canonical Documentation Contract](./0001-canonical-documentation-contract.md) — the
  broader documentation and ADR lifecycle contract.
- [Chapter 02 — Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — the
  precedent: decision in the ADR, current state in a Reference page.
- [Cortex Proof Status](../Reference/proof-status.md) — the proof-specific status matrix the
  `Theory` cell links to.
- [Cortex Feature Status](../Reference/feature-status.md) — the capability/status canon this ADR
  introduces.
- [ADR template](../Templates/adr.md)

## Amendment - feature-status validator implemented (2026-06-27)

The docs-lint feature-status validator obligation is discharged. The validator lives in
`scripts/docs-lint`, the Markdown lint gate run by `just docs-lint` in the pre-commit hook and in
CI.

### What it enforces

`check_feature_status` validates the `## Capabilities` matrix in
[`feature-status.md`](../Reference/feature-status.md) against this ADR:

- **Schema** — every capability table (one with eight columns, or one naming the `Feature key`
  column) must carry exactly the eight canonical columns, in order; a drifted header is reported,
  not silently skipped.
- **Feature-key grammar and uniqueness** — keys are lowercase-dotted with a known subsystem prefix
  (Decision rule 2), and no key has more than one row.
- **Status enums** — `ADR status` is one of `proposed`/`accepted`/`superseded`/`deprecated` and
  `Impl status` is one of `planned`/`partial`/`implemented`/`verified`/`retired` (Decision rule 4).
- **Governing-ADR resolution** — every ADR number in the `Governing ADR` cell, including the
  `NNNN (amend)` and `NNNN / NNNN (amend)` forms, resolves to an ADR file.
- **Evidence-cell shape** — the `Tests`, `Theory`, and `Reference` cells are either the empty marker
  `—` or local Markdown link(s), never a bare path and never an external URL; the `Theory` cell must
  point at `proof-status.md`, keeping one source of proof truth (Decision rule 4).
- **Bidirectional feature-key join** — every matrix key is declared in a cited ADR's Traceability
  block (`##` or `###`, so amendment blocks count; code fences and stray bullets elsewhere are
  ignored), and every key an ADR declares is bound to a matrix row whose governing cell sanctions
  that ADR. An `A / B (amend)` cell licenses a declaration in either. This consistency stops ADRs
  and the matrix from drifting apart.

Evidence-link _resolution_ — that the target file or anchor actually exists — is enforced for every
local Markdown link in the corpus by the existing `check_markdown_links`. That checker skips
URI-scheme targets, so `check_feature_status` rejects external evidence links outright; every
surviving evidence link is local and therefore resolved. Decision rule 5's resolution requirement is
met by the lint gate as a whole, and `check_feature_status` adds the matrix-specific structure and
the join on top.

### Scope limit

The validator does **not** mechanize the Required/Omitted-by-category rule — that a governance,
boundary, numbering, or proof-track _ledger_ ADR must carry no feature row. That rule needs per-ADR
category and ledger semantics that are not machine-readable, and its symmetric failure (an ADR that
wrongly grows _both_ a `## Traceability` block and a matching row) is internally consistent, so the
join cannot flag it. It stays an authoring-discipline obligation. The join does catch the asymmetric
form — a row with no declaration, or a declaration with no row.

Accepted ADRs and the feature-status matrix do not carry tracker state. Proposed ADRs may keep
temporary planning links in a final `## Tracking` section under ADR 0001, but that section is
deleted before acceptance.
