---
title: Cortex Doc Templates
description: Frontmatter and section shape for each document kind in the Cortex docs.
sidebar:
  label: Templates
  order: 10
---

# Cortex Doc Templates

Start new docs from the closest template. Templates define expected
frontmatter, section shape, and placement discipline.

## Templates

| Doc kind | Template | Where the doc lives |
|---|---|---|
| Architecture chapter | [architecture-page.md](architecture-page.md) | `Architecture/NN-*.md` |
| Normative reference | [reference-spec.md](reference-spec.md) | `Reference/**/*.md` |
| ADR | [adr.md](adr.md) | `ADRs/NNNN-*.md` |
| Roadmap epic | [roadmap-epic.md](roadmap-epic.md) | `Roadmap/Epics/*.md` |
| Implementation plan | [implementation-plan.md](implementation-plan.md) | `Roadmap/Plans/*.md` |
| Research memo | [research-memo.md](research-memo.md) | `Research-notes/{scope}/YYYY-MM-DD-*.md` |
| Experiment | [experiment.md](experiment.md) | `Experiments/{scope}/YYYY-MM-DD-*.md` |
| Publication manuscript | [publication-manuscript.md](publication-manuscript.md) | `Publications/paper-N-*/manuscript.md` |
| Section index | [section-index.md](section-index.md) | any directory's `index.md` |

## Discipline

The structure, frontmatter, format, and Cortex-first policy these templates encode are governed by
[ADR 0001 — Canonical Documentation Contract](../ADRs/0001-canonical-documentation-contract.md);
`scripts/docs-lint` is the gate.

- Frontmatter is required (`title` and `description` always).
- Status values follow the canonical enum the contract pins (ADRs use `proposed`, `accepted`,
  `superseded`); `scripts/docs-lint` enforces it.
- Dates in frontmatter are ISO dates (`YYYY-MM-DD`), never in the future.
- Canonical docs should frame Cortex directly. Downstream consumers can appear
  as examples, not as the system boundary.
- Dated artifacts should be retained only while they explain current canon,
  active work, or a live research thread.

## Related

- [../map.md](../map.md) - where each doc kind belongs.
- [../taxonomy.md](../taxonomy.md) - how doc kinds cluster.
