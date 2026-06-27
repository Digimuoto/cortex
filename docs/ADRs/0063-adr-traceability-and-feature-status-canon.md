---
title: "ADR 0063 — ADR Traceability and Feature Status Canon"
description:
  "ADRs stay one-decision records; feature ADRs carry a Traceability block keyed by a stable feature
  key, and a feature-status matrix is the capability/status canon."
sidebar:
  label: "0063. Traceability canon"
  order: 63
status: accepted
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Reference/proof-status.md
  - docs/Reference/feature-status.md
  - docs/Templates/adr.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - "GitHub #304"
---

# ADR 0063 — ADR Traceability and Feature Status Canon

## Status

Accepted — establishes the authoring contract for traceability in feature ADRs and the
capability/status canon. This is a docs-process governance decision, not a shipped substrate
capability, so it carries **no** Traceability block itself.

## Context

Cortex has a real ADR canon for decisions but no canon for current capability, verification, or
release truth.

- The ADR template is decision-shaped: frontmatter (`status`, `date`, `superseded_by`, `related`)
  and a body of Status / Context / Decision / Alternatives / Consequences / Related. The ADR index
  exposes only number, title, and ADR `status`.
- That single `status` field conflates three independent facts — whether the _decision_ is accepted,
  whether the _code_ is shipped, and whether the _proof_ has landed. The track currently reads 13
  accepted / 43 proposed / 1 superseded, yet much of the "proposed" pile is already shipped
  substrate. The drift is invisible because there is nowhere to record it.
- One good precedent already exists: [`proof-status.md`](../Reference/proof-status.md) separates the
  human claim, Lean status, Haskell correspondence, proof links, and remaining gap, and ADR 0038
  states that the ADR records the decision while the Reference page is the current-state view.
- Forcing a feature list into every ADR would make the canon worse. Many decisions are not features:
  ownership boundaries, proof obligations, numbering policy, the module tree, import direction.

## Decision

Adopt a layered canon with one responsibility per layer, and generalize the `proof-status.md`
pattern to all substrate capabilities.

| Layer                 | Owns                                                                |
| --------------------- | ------------------------------------------------------------------- |
| Architecture chapters | The narrative map of Cortex — why the substrate is shaped this way. |
| ADRs                  | Why a decision exists. One decision per ADR.                        |
| Reference docs        | What is currently true — the rules.                                 |
| `feature-status.md`   | What capabilities exist, where, and how verified.                   |
| Issues / PRs          | What is actively changing — planning state, never canon.            |
| Releases              | Generated from feature-status rows changed since the last tag.      |

Five rules govern the new surfaces. They are hard edges.

### 1. ADR Traceability block

A feature ADR carries a `## Traceability` block; a non-feature ADR does not.

```markdown
## Traceability

- Feature keys: `pulse.atomic_suspend_settlement`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/...`
- Implementation: `src/Cortex/Pulse/...`
- Tests: `test/Cortex/...`
- Theory/proof: link to the relevant `docs/Reference/proof-status.md` row(s)
- Tracking: `GitHub #...`
```

There is **no release-note field** in the ADR. Release framing belongs only to feature-status rows
and downstream release tooling.

Whether the block is required follows the **Stage-3 category** (this sweep's classification), not a
separate taxonomy:

- **Required** for ADRs in the feature/runtime/language/proof categories — Pulse runtime, Rewrite
  admission, Conditionals/selection, Wire language/elaboration/topology, Wire executor & node,
  CorePure, Capability & executors, Artifact & provenance, Packaging/CLI, and Proof-track _feature_
  ADRs.
- **Omitted** for governance and meta ADRs — Boundary & governance, numbering/process policy, and
  the proof-track _ledger_ (which already points at `proof-status.md`).

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
  implementation status `retired`. (ADR re-enumeration does not touch feature keys — they are
  number-independent.)

### 3. `feature-status.md` is the capability/status canon

[`feature-status.md`](../Reference/feature-status.md) is the current-truth matrix and the single
extraction source for release notes. It is **capability/status canon, not marketing feature canon**:
rows cover substrate capabilities that may not be user-visible in any product sense. Columns:

`Feature key | Capability | Governing ADR | ADR status | Impl status | Tests | Theory | Reference | Tracking`

### 4. Status dimensions stay separate

Never collapse these into one field:

- **ADR status** — `proposed` | `accepted` | `superseded` | `deprecated` (the decision).
- **Implementation status** — `planned` | `partial` | `implemented` | `verified` | `retired` (the
  code).
- **Proof status** — owned by `proof-status.md`. The matrix's `Theory` cell **links to the
  proof-status row**; it does not restate Lean/Haskell state, so there is one source of proof truth.

### 5. Evidence links are validated, never asserted blind

`just docs-check` must confirm that every evidence link in a feature-status row — the `Tests`,
`Theory`, and `Reference` cells — resolves to an existing file or anchor. (`Impl status` is a status
value, not a path; per-capability implementation paths live in the governing ADR's `## Traceability`
block, not the matrix.) The matrix may **under-claim** (an empty cell is allowed and honest); it
must not **dangle** (a link to a path that does not exist fails the check). A row is seeded with its
key and status before its evidence links exist; the links are added as the capability is governed
and verified.

## Alternatives considered

- **Add a feature list to every ADR.** Rejected — it corrupts ADR semantics. Non-feature decisions
  have no features, and the list would rot inside an append-only decision record.
- **Use GitHub issues as the capability canon.** Rejected — issues are planning state and they
  close; canon must be durable. ADRs and the matrix link to issues, not the reverse.
- **Extend `proof-status.md` to cover all features.** Rejected — proof-status is proof-specific and
  rich. The feature matrix links to it rather than absorbing it, avoiding a second proof-truth
  source.

## Consequences

### Positive

- Status drift becomes visible and auditable: a `proposed` ADR governing `implemented` code is now
  expressible, and the gap is a tracked row rather than a silent inconsistency.
- Releases extract from a single source of truth.
- ADRs stay clean one-decision records; the canon gains a status story without changing ADR
  semantics.

### Negative

- One more Reference page to maintain. Its honesty depends on the docs-check validator and on
  authoring discipline.
- Feature-key allocation is a new lightweight governance step.

### Obligations

- Add the `## Traceability` block to [`docs/Templates/adr.md`](../Templates/adr.md) with
  required-for-feature guidance.
- Create [`docs/Reference/feature-status.md`](../Reference/feature-status.md) and list it in the
  Reference index.
- Implement the `docs-check` evidence-link validator for feature-status rows (follow-up tooling).
- Author every Stage-2 feature ADR with a Traceability block and a stable feature key; seed the
  matrix row first, then add evidence links as they become concrete.
- Backfill the `## Traceability` block and a feature-status row into the **pre-Stage-2**
  feature/runtime/language/proof ADRs — the requirement in Decision rule 1 applies to them too, but
  the backfill is a tracked follow-up rather than part of this opener. Until it lands, the matrix
  covers the Stage-2 set and grows as each pre-existing feature ADR is revisited; accepted + shipped
  ADRs are the priority. Governance/boundary/numbering/ledger ADRs remain exempt.
- Resolves issue #304 OQ10 (status hygiene): status drift is now a structural concern owned by
  `feature-status.md`, not the ADR `status` field.

## Related

- [Chapter 02 — Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — the
  precedent: decision in the ADR, current state in a Reference page.
- [Cortex Proof Status](../Reference/proof-status.md) — the proof-specific status matrix the
  `Theory` cell links to.
- [Cortex Feature Status](../Reference/feature-status.md) — the capability/status canon this ADR
  introduces.
- [ADR template](../Templates/adr.md)
- GitHub #304

## Amendment - feature-status validator implemented (2026-06-27, issue #304)

The Obligation "Implement the `docs-check` evidence-link validator for feature-status rows
(follow-up tooling)" is discharged. The validator lives in `scripts/docs-lint` — the mechanical
Markdown lint gate run by `just docs-lint` in the pre-commit hook and in CI — rather than in
`just docs-check` (the documentation site build). Decision rule 5 named `docs-check` loosely;
`docs-lint` is the correct home because it already owns the link, anchor, table, and frontmatter
checks and runs on every push.

### What it enforces

`check_feature_status` validates the `## Capabilities` matrix in
[`feature-status.md`](../Reference/feature-status.md) against this ADR:

- **Schema** — every capability table (one with nine columns, or one naming the `Feature key`
  column) must carry exactly the nine canonical columns, in order; a drifted header is reported, not
  silently skipped.
- **Feature-key grammar and uniqueness** — keys are lowercase-dotted with a known subsystem prefix
  (Decision rule 2), and no key has more than one row.
- **Status enums** — `ADR status` is one of `proposed`/`accepted`/`superseded`/`deprecated` and
  `Impl status` is one of `planned`/`partial`/`implemented`/`verified`/`retired` (Decision rule 4).
- **Governing-ADR resolution** — every ADR number in the `Governing ADR` cell, including the
  `NNNN (amend)` and `NNNN / NNNN (amend)` forms, resolves to an ADR file.
- **Evidence-cell shape** — the `Tests`, `Theory`, and `Reference` cells are either the empty marker
  `—` or local Markdown link(s) — never a bare path and never an external URL, since Decision rule 5
  wants a file or anchor; the `Theory` cell must point at `proof-status.md`, keeping one source of
  proof truth (Decision rule 4).
- **Bidirectional feature-key join** — every matrix key is declared in a cited ADR's Traceability
  block (`##` or `###`, so amendment blocks count; code fences and stray bullets elsewhere are
  ignored), and every key an ADR declares is bound to a matrix row whose governing cell sanctions
  that ADR — an `A / B (amend)` cell licenses a declaration in either. This is the consistency that
  stops ADRs and the matrix from drifting apart.

Evidence-link _resolution_ — that the target file or anchor actually exists — is enforced for every
local Markdown link in the corpus by the existing `check_markdown_links`. That checker skips
URI-scheme targets, so `check_feature_status` rejects external evidence links outright; every
surviving evidence link is local and therefore resolved. Decision rule 5's resolution requirement is
thus met by the lint gate as a whole, and `check_feature_status` adds the matrix-specific structure
and the join on top.

### Scope limit

The validator does **not** mechanize the Required/Omitted-by-category rule — that a governance,
boundary, numbering, or proof-track _ledger_ ADR must carry no feature row. That rule needs per-ADR
category and ledger semantics that are not machine-readable, and its symmetric failure (an ADR that
wrongly grows _both_ a `## Traceability` block and a matching row) is internally consistent, so the
join cannot flag it. It stays an authoring-discipline obligation. The join does catch the asymmetric
form — a row with no declaration, or a declaration with no row.

Tracking: GitHub #304.
