---
title: "Paper 6 Figures"
description:
  Figure inventory and export status for the Executable Causal Diagrams with Typed Linear Frontiers
  draft.
sidebar:
  label: Figures
  order: 2
status: draft
date: 2026-05-08
updated: 2026-05-13
related:
  - docs/Publications/Paper-6-executable-diagrams/manuscript.md
  - docs/Publications/Paper-6-executable-diagrams/index.md
---

# Paper 6 Figures

## Sources

- [dashboard-topology.mmd](dashboard-topology.mmd) - admitted dashboard topology with the carried
  `profile` dependency and the two branch-local fetch paths.
- [dashboard-topology-module.typ](dashboard-topology-module.typ) - reusable Typst figure body
  imported by the manuscript and standalone figure export.
- [dashboard-topology.typ](dashboard-topology.typ) - PDF-oriented Typst source for the dashboard
  topology figure.
- [executable-diagram-layers.mmd](executable-diagram-layers.mmd) - source diagram, admitted
  frontier, causal topology, circuit, runtime trace, and proof-facing IR as one layered view.
- [executable-diagram-layers-module.typ](executable-diagram-layers-module.typ) - reusable Typst
  figure body imported by the manuscript and standalone figure export.
- [executable-diagram-layers.typ](executable-diagram-layers.typ) - PDF-oriented Typst source for the
  same figure.

## Export Status

- Mermaid source is checked in.
- Typst source is checked in for standalone figures and manuscript figures.
- Publication renderings are produced through the Typst manuscript's Nix output.
