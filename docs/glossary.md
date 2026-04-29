---
title: Cortex Glossary
description:
  Definitions of Wire and Cortex terms readers will encounter across the docs. Normative definitions
  live in Reference/terminology.md; this page is a quick-reference pointer.
sidebar:
  label: Glossary
  order: 4
---

# Cortex Glossary

Quick-reference terms. Normative and complete definitions live in
[Reference/terminology.md](Reference/terminology.md); this page exists for casual lookup and
orientation.

## Core substrate

- **Cortex** — the standalone durable runtime substrate described in these docs.
- **Algebra** — the pure topology and relation layer: vertices, edges, overlay, connect, and
  law-bearing graph operations.
- **Wire** — the source language for authoring executable topology. Its compiled circuit form is the
  artifact Pulse executes. Grammar: [Reference/Wire/grammar.md](Reference/Wire/grammar.md).
- **Pulse** — the durable runtime that executes Circuits. See
  [Architecture/06-pulse-runtime.md](Architecture/06-pulse-runtime.md).
- **Capability** — external authority surfaces available to execution: models, tools, providers, and
  their neutral request/record types.
- **Artifact** — generic durable outputs, provenance, metadata, rendering, and artifact host
  boundaries.

## Downstream Logos

- **Logos library** — the downstream structured reasoning library above Cortex. It owns reusable
  LLM-shaped catalogs, not runtime authority.
- **Logos.Archetypes** — the canonical epistemological archetype catalog: Logos, Sophia, Techne,
  Episteme, Kritikos, Themis, and Poiesis.
- **Logos.Thought** — one bounded model-mediated cognitive evaluation bound to a graph node; not a
  durable persona.
- **Logos.Memory** — cognitive memory: retrieval, ranking, packing, compaction, source selection,
  topological context, and memory tools.
- **Logos.Patterns** — planned reusable reasoning-program catalogs such as the DeepReport extraction
  target.
- **Logos archetype** — the `Logos.Archetypes.Logos` archetype for discursive reason, argument, and
  symbolic reasoning.
- **Logos activation bundle** — the operational implementation of an archetype: prompt discipline,
  retrieval corpus, embedding spaces, tools, memory policy, evaluation criteria, and runtime
  contract.

## Wire language

- **Contract** — a named typed interface that flows through a port.
- **Port** — a slot on a node, typed by a contract. Input (`<-`) or output (`->`). May be labeled.
- **Port key** — `(direction, contract, label)`, the identity tuple `=>` matches on.
- **Label** — part of a port's routing identity, not a cosmetic name.
- **Node** — an explicit graph vertex with typed ports and an implementation body.
- **Executor** — a registered recipe that turns inputs into outputs.
- **Configured executor value** — executor authority plus inert config, reusable in node bodies.
- **Sum group** — output-port form `-> A | B` where exactly one variant fires.
- **Wire value** — a node, a composed graph expression, or the empty wire `()`.
- **Port-boundary** — a wire's currently unconnected input and output ports.
- **File-return expression** — the last expression in a `.wire` file, which becomes the file's
  value.
- **Evaluation-boundary check** — the runnable-wire gate: every singular input must be connected
  exactly once.

## Composition

- **`<>` overlay** — set union of nodes and edges.
- **`=>` connect** — port-key-matched edge addition over boundaries.
- **`//` merge** — right-biased shallow record merge.
- **`++` concat** — string and list concatenation.
- **`|` sum** — output-port mutual-exclusion constructor.
- **`@` application** — stages registered executor authority with config: `@qualified.name { ... }`.

## Runtime

- **Envelope** — the runtime carrier for a value:
  `{ contract, mediaType, producer, value, provenance }`.
- **Payload kind** — the runtime category of a contract's value: `json`, `markdown`, `text`,
  `table`, or `artifact_ref`.
- **Contract registry** — the authoritative contract definitions used for validation, decoding, and
  rendering.
- **Provenance** — the runtime record of where a value came from.
- **Rewrite** — a bounded topology edit admitted during runtime. See
  [Architecture/07-rewrites-and-materialization.md](Architecture/07-rewrites-and-materialization.md).
- **Gas** — structural-change budget consumed by rewrites.
- **Topological memory** — downstream `Logos.Memory` context built from settled upstream Pulse
  state.

## Doc kinds

- **Canonical chapter** — `NN-*` file under `Architecture/`. Part of the architecture book.
- **Reference** — normative spec under `Reference/`. Consultable, rule-precise.
- **ADR** — `NNNN-*` file under `ADRs/`. One committed design decision.
- **Epic** — long-running engineering initiative in `Roadmap/Epics/`.
- **Plan** — implementation plan under `Roadmap/Plans/`.
- **Research note** — dated synthesis/design memo under `Research-notes/{scope}/`.
- **Experiment** — dated smoke test or dogfood under `Experiments/{scope}/`.
- **Handoff** — dated transition note under `Handoffs/`.
- **Manuscript** — paper under `Publications/paper-N-*/manuscript.md`.

## See also

- [Reference/terminology.md](Reference/terminology.md) — normative definitions.
- [taxonomy.md](taxonomy.md) — how these terms cluster and relate.
- [Architecture/01-overview.md](Architecture/01-overview.md) — the canonical overview.
