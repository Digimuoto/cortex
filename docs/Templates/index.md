---
title: Cortex Doc Templates
description: Frontmatter and section shape for each document kind in the Cortex docs.
sidebar:
  label: Templates
  order: 10
---

# Cortex Doc Templates

Start new docs from the closest template. Templates define expected frontmatter, section shape, and
placement discipline. ADR 0001 makes this directory the authoring guide for doc-kind shape; the
template set is guidance, while `scripts/docs-lint` enforces the mechanical subset.

## Template Coverage

Every doc kind from [../map.md](../map.md#by-kind) is accounted for here. Some narrow archive and
single-page kinds intentionally carry no bespoke file; authoring-heavy kinds have a dedicated
template or an explicit section-index shape.

| Doc kind | Template | Where the doc lives | Notes |
| --- | --- | --- | --- |
| Usage guide | [usage-guide.md](usage-guide.md); [section-index.md](section-index.md) for `Usage/index.md` | `Usage/index.md`, `Usage/NN-*.md` | Usage pages are task-oriented canon; keep commands runnable and routes explicit. |
| Canonical architecture chapter | [architecture-page.md](architecture-page.md) | `Architecture/NN-*.md` | Canonical synthesis, not decision history. |
| Normative specification | [reference-spec.md](reference-spec.md) | `Reference/**/*.md` | Stable contract and exact rules. |
| Code style guide | No dedicated template | `Style.md` | Single top-level canon page; follow existing page structure and ADR 0001 frontmatter rules. |
| Architecture decision record | [adr.md](adr.md) | `ADRs/NNNN-*.md` | One decision per ADR; proposed ADRs may carry temporary tracking. |
| Downstream consumer binding | [consumer-binding.md](consumer-binding.md) | `Consumers/{consumer}.md` | Consumer-specific substrate binding; keep Cortex rules in Architecture/Reference and product policy downstream. |
| Logos reasoning library | [section-index.md](section-index.md) | `Consumers/Logos/` | Larger downstream library canon; use section indexes plus focused reference pages. |
| Active roadmap plan | [implementation-plan.md](implementation-plan.md) | `Roadmap/Plans/*.md` | Active, supersedable work plan. |
| Active roadmap epic | [roadmap-epic.md](roadmap-epic.md) | `Roadmap/Epics/*.md` | Coordinated child work. |
| Completed initiative | No dedicated template | `Roadmap/Completed/` | Historical retained selectively; summarize what shipped and link durable canon. |
| Archived idea | No dedicated template | `Roadmap/Archive/` | Historical retained selectively; preserve only context still worth carrying. |
| Paper manuscript and figures | [publication-manuscript.md](publication-manuscript.md) | `Publications/Paper-N-*/manuscript.md` | Bundle files have publication-specific frontmatter rules in docs-lint. |
| Paper notes and ideas | [publication-notes.md](publication-notes.md) | `Publications/Notes/` | Working publication ideas and bundle seeds, not dated research memos. |
| Research or synthesis memo | [research-memo.md](research-memo.md) | `Research-notes/{scope}/YYYY-MM-DD-*.md` | Dated synthesis; retain only while useful. |
| Controlled experiment | [experiment.md](experiment.md) | `Experiments/{scope}/YYYY-MM-DD-*.md` | Dated experiment record tied to active work. |
| Template | No dedicated template | `Templates/*.md` | Template files are not linted (placeholder frontmatter and dates); this index is linted and `scripts/docs-lint` checks it against map.md's By-Kind list. |

## Discipline

The structure, frontmatter, format, and Cortex-first policy these templates encode are governed by
[ADR 0001 — Canonical Documentation Contract](../ADRs/0001-canonical-documentation-contract.md);
`scripts/docs-lint` is the gate.

- Frontmatter is required (`title` and `description` always).
- Status values follow the canonical enum the contract pins. ADR lifecycle status is narrower:
  ADRs use `proposed`, `accepted`, or `superseded`; other docs may use other lifecycle statuses
  admitted by `scripts/docs-lint`.
- Dates in frontmatter are ISO dates (`YYYY-MM-DD`), never in the future.
- Canonical docs should frame Cortex directly. Downstream consumers can appear
  as examples, not as the system boundary.
- Dated artifacts should be retained only while they explain current canon,
  active work, or a live research thread.
- Proposed ADRs may carry a `## Tracking` section for issue/PR state. Delete it before accepting
  the ADR; accepted ADRs cite durable canon, source, tests, proof rows, merged PRs, or commits.

## Related

- [../map.md](../map.md) - where each doc kind belongs.
- [../taxonomy.md](../taxonomy.md) - how doc kinds cluster.
