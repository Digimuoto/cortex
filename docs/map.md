---
title: Cortex Docs Map
description: At-a-glance map of what lives where in the Cortex docs and why.
sidebar:
  label: Map
  order: 3
---

# Cortex Docs Map

A one-page orientation to the documentation tree. When in doubt about where a
new doc belongs, start here.

## By Kind

| Kind | Where | Lifetime | Dated? |
|---|---|---|---|
| Canonical architecture chapter | [Architecture/](Architecture/) | Long-term canon | No |
| Normative specification | [Reference/](Reference/) | Long-term canon | No |
| Architecture decision record | [ADRs/](ADRs/) | Permanent | No |
| Downstream consumer binding | [Consumers/{consumer}.md](Consumers/) | Long-term per consumer | No |
| Active roadmap plan | [Roadmap/Plans/](Roadmap/Plans/) | Active until completed or superseded | No |
| Active roadmap epic | [Roadmap/Epics/](Roadmap/Epics/) | Active while retained | No |
| Completed initiative | [Roadmap/Completed/](Roadmap/Completed/) | Historical, retained selectively | No |
| Archived idea | [Roadmap/Archive/](Roadmap/Archive/) | Historical, retained selectively | No |
| Paper manuscript and figures | [Publications/paper-N-*/](Publications/) | Published-once | No |
| Paper notes and ideas | [Publications/Notes/](Publications/Notes/) | Working | No |
| Research or synthesis memo | [Research-notes/{scope}/](Research-notes/) | Historical, retained selectively | Yes |
| Experiment or smoke test | [Experiments/{scope}/](Experiments/) | Historical, retained selectively | Yes |
| Handoff note | [Handoffs/](Handoffs/) | Temporary historical record | Yes |
| Template | [Templates/](Templates/) | Long-term canon | No |

## By Question

**Where do I document a settled architecture decision?** Use `ADRs/` with the
next `NNNN-` number.

**Where do I write up the Wire grammar surface?** Use `Reference/Wire/`.
Canonical language rules live in reference docs, not research notes.

**Where do I document runtime architecture?** Use
`Architecture/06-pulse-runtime.md` for the stable model and
`Architecture/07-rewrites-and-materialization.md` for topology evolution.

**Where does downstream-specific design belong?** Start with
`Consumers/{consumer}.md`. Consumer docs may contain concrete product bindings;
Cortex architecture should stay consumer-independent. Create a consumer
subdirectory only when a public binding grows beyond one page.

**Where does an implementation plan go?** Use `Roadmap/Plans/` while it is
active. Move or delete it when it ships, is superseded, or stops explaining the
current plan.

**Where do dated synthesis notes go?** Use `Research-notes/` under the right
scope. Keep only notes that still explain the current canon or a live research
thread.

## Canonical Docs Versus Dated Artifacts

Canonical docs are edited to remain current. They should frame Cortex as an
independent upstream substrate and use downstream products only as examples.

Dated artifacts preserve reasoning from a point in time. They are retained only
when they still help explain the current system. Stale PR handoffs,
issue-specific migration plans, and superseded research snapshots should be
removed instead of preserved by default.

## Related

- [index.md](index.md) - docs landing and reading order.
- [taxonomy.md](taxonomy.md) - concept classification.
- [glossary.md](glossary.md) - term definitions.
- [Templates/](Templates/) - per-kind frontmatter and section shape.
