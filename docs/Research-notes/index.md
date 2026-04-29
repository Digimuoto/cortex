---
title: Cortex Research Notes
description:
  Dated Cortex research synthesis retained when it still explains current canon or live research
  threads.
sidebar:
  label: Research notes
  order: 7
---

# Cortex Research Notes

Research notes are dated artifacts. They are not canonical specs, and they are not a permanent store
for every issue-era synthesis. Retain notes that still explain current Cortex architecture,
publication work, or active research questions.

## Scope Subdirectories

- **[Foundation/](Foundation/)** - formalism, algebraic structure, and coordination boundaries.
- **[Runtime/](Runtime/)** - Pulse runtime, graph execution, rewrites, and memory.
- **[Wire/](Wire/)** - Wire language design and source-language semantics.
- **[Applications/](Applications/)** - downstream use cases and workflow patterns.

## What Belongs Here

- Dated synthesis notes that still explain current architecture.
- Design thinking that feeds active publications or live research.
- Decision archaeology that is not already captured better by an ADR.

## What Does Not Belong Here

- Stale transition notes.
- Superseded grammar snapshots.
- Issue-specific migration notes whose surviving claims now live in canonical architecture,
  reference, or ADR docs.
- Consumer-specific product strategy that belongs under `Consumers/`.

## Template

Use [../Templates/research-memo.md](../Templates/research-memo.md) for new notes.

## Related

- [../Architecture/](../Architecture/) - canonical chapters the research notes feed into.
- [../Publications/](../Publications/) - formal write-ups the notes support.
