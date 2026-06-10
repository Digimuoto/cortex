---
title: Cortex Publications
description:
  Formal write-ups and papers on Cortex's algebraic and semantic foundations. Each paper lives in
  its own folder with manuscript and figures alongside.
sidebar:
  label: Publications
  order: 6
---

# Cortex Publications

Publication-grade write-ups of Cortex's theoretical foundations and engineering results. This folder
now holds the active paper candidates. Companion theory and proof plans live under
[../Roadmap/Plans/](../Roadmap/Plans/).

## Papers

- **[Paper-1-staged-reduction/](Paper-1-staged-reduction/)** — fixed-topology staged reduction,
  structural recovery safety, the algebraic kernel, and the extension boundary (absorbed Paper 2).
- **[Paper-2-algebraic-foundations/](Paper-2-algebraic-foundations/)** — superseded; merged into
  Paper 1.
- **[Paper-3-graph-substitution-semantics/](Paper-3-graph-substitution-semantics/)** — compiled
  artifacts, graph substitution, and dynamic-topology semantics.
- **[Paper-4-wire-language/](Paper-4-wire-language/)** — authoring language for typed topology,
  registered authority, and bounded structural proposals.
- **[Paper-5-Causal-Programming/](Paper-5-Causal-Programming/)** — causal programming and temporal
  honesty: the paradigm umbrella over the other papers, with Wire and Pulse as the existence proof.
- **[Paper-6-executable-diagrams/](Paper-6-executable-diagrams/)** — executable causal diagrams,
  tying Wire source, durable replay, and proof-facing admission together.
- **[Paper-7-frontier-calculus/](Paper-7-frontier-calculus/)** — the flagship: the typed linear
  frontier calculus on paper, with mechanized metatheory and the compiler as implementation claim.

## Claims policy

Any manuscript that cites verification numbers (mechanized-claim counts, Haskell-correspondence
counts, axiom status) states the date it was checked against
[../Reference/proof-status.md](../Reference/proof-status.md). A manuscript is stale when the
proof-status page is newer than its stated as-of date; refresh the numbers before any submission
freeze.

## Supporting material

- **[roadmap.md](roadmap.md)** — publication portfolio and dependency sketch.
- **[../Roadmap/Plans/lean-mechanization.md](../Roadmap/Plans/lean-mechanization.md)** — supporting
  research plan for machine-checked fixed-topology results.
- **[../Roadmap/Plans/rewrite-materialization-and-recovery.md](../Roadmap/Plans/rewrite-materialization-and-recovery.md)**
  — supporting research plan for runtime-grounded rewrite recovery.
- **[Notes/](Notes/)** — working notes and idea memos that feed the papers.

## Per-paper structure

Each `paper-N-*/` folder contains:

- `index.md` — landing page with status, abstract, figures, and related material.
- `manuscript.md` — the manuscript itself.
- `typst/` — Nix-rendered PDF source when a paper has a typeset manuscript.
- `Figures/` — figure sources and export notes.

## Template

Use [../Templates/publication-manuscript.md](../Templates/publication-manuscript.md) for new
manuscripts.

## Related

- [../Research-notes/](../Research-notes/) — dated research synthesis that underlies the papers.
- [../Roadmap/Plans/](../Roadmap/Plans/) — companion research and implementation plans.
- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md) — architecture
  chapter that cites the papers.
