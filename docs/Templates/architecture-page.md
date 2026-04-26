---
title: "Chapter NN — {Title}"
description: "{One-sentence description of the chapter's scope.}"
sidebar:
  label: "NN. {Short label}"
  order: N
status: draft   # draft | active | superseded
---

# Chapter NN — {Title}

<!--
Opening: one paragraph that states what this chapter is about and why a reader
should invest the time. Avoid "this chapter will cover X"; instead state the
claim or framing the chapter establishes.
-->

## Core model

<!--
The central framing. One or two layered diagrams or tables. The shortest
statement that captures what this layer does and its relationships to the
layers above and below.
-->

## Detailed structure

<!--
Expand the core model with the pieces that compose it. Each piece gets a
subsection. For substrate chapters this is typically modules + types; for
runtime chapters this is typically service boundaries + state machines.
-->

## Boundaries and invariants

<!--
What this layer enforces, what it delegates upward or downward, and the
invariants that must hold for the layer to be correct.
-->

## Extensibility

<!--
How downstream consumers or future work extend this layer. Typically by
registering into a closed alphabet, not by modifying the layer itself.
-->

## Related

<!--
Cross-references. Other architecture chapters, relevant references, retained
roadmap work, foundational research notes, or publications.
-->

- [../Reference/...](../Reference/...)
- [./NN-related-chapter.md](./NN-related-chapter.md)
- `docs/Roadmap/Plans/...` or `docs/Roadmap/Epics/...` when active work is retained.
