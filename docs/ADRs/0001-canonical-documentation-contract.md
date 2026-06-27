---
title: "ADR 0001 — Canonical Documentation Contract"
description:
  "The canonical documentation tree, doc-kind set, canonical-vs-dated boundary, per-kind frontmatter
  and format rules, and the Cortex-first policy — decided once; the mechanical subset gated by
  docs-lint."
sidebar:
  label: "0001. Documentation contract"
  order: 1
status: accepted
date: 2026-06-28
superseded_by: null
related:
  - docs/taxonomy.md
  - docs/map.md
  - docs/Templates/adr.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0063-adr-traceability-and-feature-status-canon.md
  - docs/ADRs/0018-canonical-haskell-module-tree.md
  - "GitHub #300"
  - "GitHub #320"
  - "GitHub #326"
  - "GitHub #147"
---

# ADR 0001 — Canonical Documentation Contract

## Status

Accepted — ratifies the documentation structure, format, and policy already described across
`docs/taxonomy.md`, `docs/map.md`, and `docs/Templates/`, and partly enforced by
`scripts/docs-lint`, by recording it as one governed decision and drawing the line between what is
gated and what is authoring guidance. This is a docs-process governance decision, not a shipped
substrate capability, so it carries **no** Traceability block and **no** feature-status row (ADR
0063, rule 1).

This ADR deliberately reclaims the `0001` slot vacated by the #304 sweep, placing the documentation
contract at the foundation of the canon. It is an intentional exception to the otherwise
allocation-order numbering the index notes — recorded here rather than deferred to the held Stage-5
renumber, because a foundational contract belongs at the floor.

## Context

Cortex governs the shapes it cares about with append-only decision records: ADR 0018 decides the
canonical Haskell module tree, and ADR 0063 decides the ADR-to-feature-status traceability slice.
The documentation system's own shape has no such record.

It is, however, already **described** and partly **enforced**:

- `docs/taxonomy.md` (`## Doc-kind taxonomy`) and `docs/map.md` (`## By Kind`,
  `## Canonical Docs Versus Dated Artifacts`) classify every doc and route a new one to its home.
- `docs/Templates/` carries a frontmatter and section skeleton for the doc-kinds that have a
  template (authoring convention; the templates are not themselves linted).
- `scripts/docs-lint` — the gate run by `just docs-lint` in the pre-commit hook and in CI — enforces
  a set of mechanical minima (common frontmatter, the status enum, table / whitespace / Mermaid /
  link structure, and the canonical-docs lexical policy on canonical paths). It does **not**
  validate per-kind skeletons; the line between what is gated and what is authoring guidance is
  exactly what this decision draws.

What is missing is the **decision**: the contract is convention plus a linter, with no canonical
rationale, no stated boundaries, and no supersession discipline. A change to the doc taxonomy or a
lint rule is currently an undecided edit. This ADR closes that gap; it ratifies current practice
rather than introducing new rules.

## Decision

The documentation system is a governed contract. As with ADR 0063, the ADR **decides**; the named
living surfaces **describe and enforce**. Two edges fix the taxonomy (what kinds exist and where
they live); the other two separate what `scripts/docs-lint` mechanically **enforces** from what is
**authoring guidance**.

### 1. Canonical documentation tree and doc-kinds

Every document has exactly one **doc-kind** with one home. The authoritative, living census of
kinds, homes, and per-kind lifetimes is `docs/map.md` (`## By Kind`) and `docs/taxonomy.md`
(`## Doc-kind taxonomy`); this ADR governs that census rather than restating it, so the two never
drift from a copy kept here. A new kind or a relocation is an amendment to this ADR, kept in step
with those pages. This is the documentation analog of ADR 0018's canonical module tree.

### 2. Canonical versus dated

One axis cuts across every kind: whether a doc is **edited to stay current** or **preserves a point
in time**. Canonical docs (the `Dated? = No` kinds in `docs/map.md`) are kept current and evolve by
append or supersession; dated artifacts (`Research-notes/`, `Experiments/` — the `Dated? = Yes`
kinds) preserve reasoning from a moment and are removed once they no longer explain the current
system. The full per-kind lifetime model (active / completed / archived / published / working) is
`docs/map.md`'s `Lifetime` column, not restated here. This canonical/dated split is the same
boundary `docs-lint`'s `is_canonical` draws for the lexical policy in rule 3.

### 3. What `scripts/docs-lint` enforces

The gate runs in the pre-commit hook and in CI over every Markdown and `.mmd` file except
`docs/Templates/` (which is not linted). It enforces, mechanically:

- **Frontmatter minima** — `title` and `description` on every doc; `status`, when present, is a
  member of one global enum (it is **not** dispatched per doc-kind); `date` / `updated`, when
  present, are ISO dates not in the future. Publication bundles: `manuscript.md` additionally
  requires `authors`, `kind`, `related`, `updated`; other bundle files require `date`,
  `description`, `related`, `status`, `title`.
- **Structure** — tables are well-formed (cell counts agree); no trailing whitespace or carriage
  returns; every local Markdown link, and any `#anchor`, resolves.
- **Mermaid hygiene** — diagram blocks carry no cosmetic styling (`classDef … fill:`, inline
  `style … fill:`, `linkStyle`) unless a line opts out with `lint: allow semantic`.
- **Cortex-first lexical policy**, on canonical paths only (`Architecture/`, `Reference/`,
  `Publications/`, and top-level `docs/*.md`): no internal `Track N`, no `GitHub` / `PR #N`, and the
  stable term "Pulse runtime" rather than "Cortex Pulse". `ADRs/` and dated artifacts sit outside
  these paths, so a `GitHub #...` reference there is legitimate provenance, not drift.
- **The feature-status matrix join** (ADR 0063) — one instance of this contract with its own
  validator.

### 4. Authoring guidance (not gated)

The rest of the contract is convention the gate does not check; it is honored by authoring
discipline and review:

- **Per-kind frontmatter and section shape** live in `docs/Templates/<kind>.md` for the kinds that
  have a template (currently nine; kinds without one follow the nearest template). The templates are
  guidance and are not themselves linted.
- **Per-kind status conventions** — ADRs use `proposed` / `accepted` / `superseded`; the gate checks
  only global enum membership, so per-kind discipline is authored, not enforced.
- **Cortex-first framing** — canonical docs treat Cortex as the independent upstream substrate;
  downstream product documentation belongs in `Consumers/`, not in the canonical trees. This is a
  human-judgment rule with no validator.

## Alternatives considered

- **Leave it to `docs-lint` and the templates.** Rejected — a linter encodes rules but decides
  nothing; the taxonomy and policy boundaries had no canonical home, no rationale, and no
  supersession path, so changes were undecided edits.
- **Fold it into ADR 0063.** Rejected — 0063 is one decision (the traceability/matrix slice). The
  documentation contract is the broader system 0063 sits within; bundling them would repeat the
  two-decisions-in-one-ADR drift seen in ADR 0062.
- **Split into a structure ADR and a format ADR.** Rejected for now — taxonomy, format, and policy
  are facets of one contract (the canonical documentation system) sharing one enforcement gate; one
  record keeps them coherent. If either facet later grows its own decision surface, supersede with a
  split.

## Consequences

### Positive

- The documentation system gains the governance the code tree (0018) and the traceability slice
  (0063) already have: a canonical rationale, stated boundaries, and supersession discipline.
- `docs-lint`'s rules become decisions with a recorded why, not unexplained gate behavior.
- The living surfaces (`taxonomy.md`, `map.md`, `Templates/`) gain a governing-decision anchor.

### Negative

- One more governance ADR to keep honest; its accuracy depends on the living surfaces and the linter
  staying in step with it.

### Obligations

- Anchor `docs/taxonomy.md`, `docs/map.md`, and the `docs/Templates/` set to this ADR as their
  governing decision.
- Reconcile `docs/Templates/index.md` with `docs/map.md`'s `## By Kind` set: add a template for each
  governed kind that lacks one, or record which kinds intentionally have none (the template set
  currently covers fewer kinds than `map.md` lists).
- A doc-kind or format-rule change lands as an amendment to this ADR (or a superseding ADR), kept in
  step with `docs/taxonomy.md` / `docs/map.md` and `scripts/docs-lint`.
- This push brings the adjacent doc work into conformance: the operator-meanings table and ADR
  0048/0049/0052 status reconciliation (GitHub #300); the ADR 0023 `//` ratification and ADR 0062
  split / cross-link notes (GitHub #320); the glossary frontier vocabulary (GitHub #326); and the
  standalone Wire usage docs (GitHub #147).

## Related

- [ADR 0018 — Canonical Haskell Module Tree](./0018-canonical-haskell-module-tree.md) — the
  code-tree analog; this ADR is the documentation counterpart.
- [ADR 0063 — ADR Traceability and Feature Status Canon](./0063-adr-traceability-and-feature-status-canon.md)
  — one instance of this contract (the feature-status join).
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — the
  decision-in-ADR / current-state-in-Reference precedent this contract generalizes.
- [Cortex Taxonomy](../taxonomy.md) — the living doc-kind taxonomy.
- [Cortex Docs Map](../map.md) — the living where-does-it-go index.
- [ADR template](../Templates/adr.md)
