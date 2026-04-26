---
title: Cortex Documentation
description: Cortex architecture, reference, ADRs, roadmap, consumer bindings, publications, and research artifacts for the Wire language, Circuit layer, Pulse runtime, and artifact substrate.
sidebar:
  label: Cortex
  order: 2
---

# Cortex Documentation

Cortex is a standalone Haskell AI substrate. It owns reusable authoring,
topology, runtime, capability, memory, provenance, and artifact mechanics.
Downstream products, including Portman, bind those mechanics to domain
semantics, product policy, tools, operators, transport, and persistence.

## System Layers

| Layer | Responsibility | Primary artifact |
|---|---|---|
| **Graph** | Pure topology: vertices, edges, overlay, connect, DAG validation. | Graph topology |
| **Circuit** | Validated executable topology: nodes plus compatible wires. | Circuit |
| **Wire** | Source language and rewrite notation that authors circuit topology. | `.wire` source |
| **Pulse** | Durable execution of compiled circuits. | Run state and events |

The core rule: **Wire composes registered authority; implementations own what
that authority means.** Wire references registered executors, contracts, tools,
prompts, memory strategies, and wiring. It does not invent host authority.

## Stable Canon

- **[Architecture/](Architecture/)** - canonical chapters. Start with the
  overview, then read ownership, formalism, graph/circuit, Wire, Pulse,
  rewrites, and artifacts.
- **[Reference/](Reference/)** - normative specifications for Wire, Pulse,
  rewrites, terminology, and contributor workflow.
- **[ADRs/](ADRs/)** - numbered architecture decisions.
- **[Consumers/](Consumers/)** - downstream bindings. Portman is the main
  concrete consumer documented here.
- **[Publications/](Publications/)** - formal paper drafts, figures, and
  publication roadmap.

## Working Artifacts

- **[Roadmap/](Roadmap/)** - active research and implementation plans.
- **[Research-notes/](Research-notes/)** - dated synthesis notes that are still
  useful as design archaeology.
- **[Experiments/](Experiments/)** - dated smoke tests and dogfood runs.
- **[Handoffs/](Handoffs/)** - contributor or work-phase handoffs when one is
  current enough to keep in the tree.
- **[Templates/](Templates/)** - frontmatter and section shapes for new docs.

## Start Here

1. [Architecture/01-overview.md](Architecture/01-overview.md) - system frame and
   ownership boundary.
2. [Architecture/05-wire-language.md](Architecture/05-wire-language.md) - Wire
   architecture and source-language model.
3. [Reference/Wire/grammar-v1.md](Reference/Wire/grammar-v1.md) - normative Wire
   grammar.
4. [Architecture/06-pulse-runtime.md](Architecture/06-pulse-runtime.md) - Pulse
   execution model.
5. [Architecture/08-artifacts-and-provenance.md](Architecture/08-artifacts-and-provenance.md) -
   artifact and provenance substrate.
6. [Reference/development.md](Reference/development.md) - contributor build,
   docs, theory, and validation commands.

## Consumer Examples

Portman appears in this tree as a downstream consumer, not as Cortex's
definition. Use [Consumers/Portman/](Consumers/Portman/) for concrete binding
examples such as report provenance, Pulse host actions, and report workflows.
Generic rules should live in architecture, reference, or ADR docs.

## Source Of Truth

When docs and implementation disagree, the implementation is authoritative until
the docs are reconciled. Canonical docs should still avoid repo-layout details
unless a page is specifically about migration or implementation planning.
