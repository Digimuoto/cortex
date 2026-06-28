---
title: "ADR 0001 — Canonical Documentation Contract"
description:
  "The canonical documentation tree, doc-kind set, canonical-vs-dated boundary, per-kind frontmatter
  and format rules, ADR lifecycle policy, and the Cortex-first policy — decided once; the mechanical
  subset gated by docs-lint."
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
---

# ADR 0001 — Canonical Documentation Contract

## Status

Accepted — ratifies the documentation structure, format, and policy already described across
`docs/taxonomy.md`, `docs/map.md`, and `docs/Templates/`, and partly enforced by
`scripts/docs-lint`, by recording it as one governed decision and drawing the line between what is
gated and what is authoring guidance. This is a docs-process governance decision, not a shipped
substrate capability, so it carries **no** Traceability block and **no** feature-status row (ADR
0063, rule 1).

## Context

Cortex governs the shapes it cares about with append-only decision records: ADR 0018 decides the
canonical Haskell module tree, and ADR 0063 decides the feature-status matrix contract. The
documentation system's own shape has no such record.

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
rationale, no stated boundaries, and no supersession discipline. A change to the doc taxonomy, ADR
lifecycle, or lint rule is currently an undecided edit. This ADR closes that gap; it ratifies
current practice rather than introducing new rules.

## Decision

The documentation system is a governed contract. The ADR **decides**; the named living surfaces
**describe and enforce**. Two edges fix the taxonomy (what kinds exist and where they live); the
other edges separate what `scripts/docs-lint` mechanically **enforces** from what is **authoring
guidance**, and fix the ADR lifecycle that all other decisions rely on.

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
`docs/map.md`'s `Lifetime` column, not restated here. This lifecycle boundary is broader than the
current `docs-lint` lexical-policy scope; the linter enforces only the mechanically checkable subset
listed below.

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
- **Cortex-first lexical policy**, on selected canonical-public paths (`Architecture/`,
  `Reference/`, `Publications/`, and top-level `docs/*.md`): no internal `Track N`, no transient
  issue/PR IDs, and the stable term "Pulse runtime" rather than "Cortex Pulse".
- **ADR tracker hygiene** — `## Tracking` is allowed only on proposed ADRs; accepted ADRs cannot
  cite transient issue/PR IDs; proposed ADR tracker references must live under their `## Tracking`
  section.
- **The feature-status matrix join** (ADR 0063) — the capability/status matrix has its own
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

### 5. ADR lifecycle

ADRs are durable decision records, not project journals.

- **One decision per ADR.** Split drafts that combine independent decisions. A status matrix,
  roadmap, or issue can coordinate several decisions; an ADR should not.
- **ADR-first development.** A substantial design starts as a `proposed` ADR before implementation
  hardens. Issues, epics, and PRs are downstream execution surfaces derived from that proposed ADR;
  they do not replace the design decision.
- **Implementation feedback.** While an ADR is proposed, implementation work may refine the exact
  wording, obligations, traceability, and open questions. The ADR remains the design authority, but
  it is allowed to converge with the code before acceptance.
- **Frontmatter and Related.** `related:` and body links use durable references: other ADRs,
  Architecture/Reference pages, source paths, tests, proof-status rows, merged PRs, or commit hashes
  when permanent provenance is truly needed.
- **Feature ADRs.** A feature/runtime/language/proof ADR carries `## Traceability` and feature keys
  as required by ADR 0063. Governance, numbering/process, boundary, and ledger ADRs omit it.
- **Proposed tracking.** A proposed ADR may end with `## Tracking` for temporary issue/PR planning
  state. Tracker references do not belong elsewhere in the ADR body. This is the only place an ADR
  may point down to issue/epic/PR execution state.
- **Acceptance cleanup.** Before an ADR moves to `accepted`, delete `## Tracking` and remove or
  convert temporary issue/PR prose into durable references. Acceptance means the dependencies that
  made the design provisional are met, the implementation and tests are in place or explicitly
  scoped out, `feature-status.md` and proof-status evidence are current when applicable, and the
  rest of the documentation has been reconciled to the new canon or feature.
- **Accepted stability.** An accepted ADR is append-only decision canon. Add amendments or
  superseding ADRs for changed decisions; do not rewrite the original decision text except for
  status/supersession metadata. Accepted ADRs are stable upstream references for Architecture,
  Reference, Usage, Roadmap, issue, epic, and PR documentation.

## Alternatives considered

- **Leave it to `docs-lint` and the templates.** Rejected — a linter encodes rules but decides
  nothing; the taxonomy and policy boundaries had no canonical home, no rationale, and no
  supersession path, so changes were undecided edits.
- **Fold it into ADR 0063.** Rejected — 0063 is the feature-status matrix and feature-key contract.
  The documentation contract is the broader system 0063 sits within; bundling them would make one
  ADR govern unrelated documentation structure, ADR lifecycle, and capability status.
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
- Before accepting a proposed ADR, remove temporary tracker metadata and make sure all surviving
  references are durable canon, source, test, proof, merged-PR, or commit references.
- Keep the ADR template, ADR index writing rules, ADR canon skill, and `scripts/docs-lint` in step
  with this lifecycle.

## Related

- [ADR 0018 — Canonical Haskell Module Tree](./0018-canonical-haskell-module-tree.md) — the
  code-tree analog; this ADR is the documentation counterpart.
- [ADR 0063 — Feature Status Matrix and Feature Key Contract](./0063-adr-traceability-and-feature-status-canon.md)
  — the feature-status matrix and feature-key contract governed by this documentation lifecycle.
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — the
  decision-in-ADR / current-state-in-Reference precedent this contract generalizes.
- [Cortex Taxonomy](../taxonomy.md) — the living doc-kind taxonomy.
- [Cortex Docs Map](../map.md) — the living where-does-it-go index.
- [ADR template](../Templates/adr.md)
