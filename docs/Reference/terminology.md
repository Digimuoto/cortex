---
title: Cortex Terminology
description:
  Normative definitions of Wire, Circuit, Graph, Pulse, and related Cortex terms. The source of
  truth for vocabulary used across the Cortex docs.
status: accepted
version: "v1"
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
---

# Cortex Terminology

Normative definitions for the vocabulary used throughout the Cortex docs. When a term appears in an
architecture chapter, spec, or research note, this page is where it is defined. Summaries in
[`glossary.md`](../glossary.md) are informal; this page is canonical.

Short rule for reading the docs:

```text
.wire source → Wire parser → Circuit → Graph topology → Pulse execution
```

Each layer owns a specific set of terms. This page groups them by layer.

## Substrate layers

| Term        | Definition                                                                                                                                                                          | Owner            |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| **Graph**   | The lowest pure algebraic topology layer: vertices, edges, `Empty`, `Overlay`, `Connect`, relation construction, and DAG validation. Pure; no evaluation semantics.                 | `Cortex.Graph`   |
| **Circuit** | The validated executable topology. Predeclared nodes plus compatible-port edges, ready for execution. A Wire source file compiles to a Circuit.                                     | `Cortex.Circuit` |
| **Wire**    | The source language and file format used to author Circuits. Composes registered authority (nodes and contracts) into a topology. Normative grammar: [grammar.md](Wire/grammar.md). | `Cortex.Wire`    |
| **Pulse**   | The durable runtime that schedules and executes a compiled Circuit. Standalone service `cortex-pulse`.                                                                              | `Cortex.Pulse`   |

## Wire language

### Core forms

| Term                          | Definition                                                                                                                             |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Contract**                  | A named typed interface that flows through a port. Ambient in a global namespace. Carries a payload kind.                              |
| **Node**                      | An explicit graph vertex with typed input/output ports and an implementation body. Has identity; reused references are the same node.  |
| **Port**                      | A slot on a node, typed by a contract. Input (`<-`) or output (`->`). May be labeled.                                                  |
| **Port key**                  | The identity tuple `(direction, contract, label)` that `=>` matches on. Absent-label is a distinct key, not a wildcard.                |
| **Label**                     | Part of a port's identity for routing, not a decoration. Labeled ports match only identically-labeled partners.                        |
| **Sum group**                 | Output port form `-> A \| B` with mutual-exclusion metadata: exactly one variant fires per evaluation.                                 |
| **Configured executor value** | Staged value `@executor { config }` with no ports or graph identity. `let`-bindable and executable only through an explicit node body. |
| **Wire value**                | Any graph-kind value: node, composed graph expression, or the empty wire `()`.                                                         |
| **Port-boundary**             | A wire's unconnected input and output ports. The surface `=>` operates on.                                                             |

### Composition algebra

| Term               | Definition                                                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| **`<>` overlay**   | Set union of nodes and edges across two wires. The primitive of the algebra.                                                          |
| **`=>` connect**   | Port-key-matched edge addition between boundary ports of two wires. Deterministic cross-product with filter.                          |
| **Mokhov algebra** | The algebraic basis for Wire's graph expressions: `Empty \| Vertex \| Overlay \| Connect` per Mokhov's _Algebraic Graphs with Class_. |

### Value operators

| Term                     | Definition                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------ |
| **`//` merge**           | Right-biased shallow record merge.                                                               |
| **`++` concat**          | String and list concatenation.                                                                   |
| **`\|` sum constructor** | Output-port mutual-exclusion form; distinct grammar construct, not pure sugar.                   |
| **`@` application**      | Executor authority plus config: `@qualified.name { ... }`. Produces a configured executor value. |

### File-level forms

| Term                       | Definition                                                                                                                                                |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **File-return expression** | A `.wire` file's last expression without trailing `;`. Becomes the file's value. A file is a wire iff it has a file-return.                               |
| **Declaration-only file**  | A file without a file-return expression. Contributes ambient contracts and importable `let` bindings; nothing else.                                       |
| **Program**                | A root `.wire` file plus the transitive closure of its imports. The unit over which ambient contract collection and cross-file reference resolution runs. |

## Executors and registry

| Term                                        | Definition                                                                                                                                                           |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Executor**                                | A registered external recipe for turning a node's inputs into outputs. Referenced by `@qualified.name`. LLM call, pure transform, shell-out, or subgraph evaluation. |
| **Executor alphabet**                       | The globally-ambient set of registered executor names. Closed: user code cannot define new executors, only compose them.                                             |
| **Vocabulary** (of an executor)             | The set of contract names the executor can produce or consume.                                                                                                       |
| **Structural constraints** (of an executor) | The rules a node's port signature must satisfy to apply the executor.                                                                                                |
| **Purity class**                            | `pure` or `impure`. Informational; does not affect static type-checking.                                                                                             |
| **Executor projection**                     | The registered typed port boundary or structural constraint checked against an authored node body.                                                                   |
| **Port-polymorphic executor**               | An executor whose accepted port signature has degrees of freedom. The authored node boundary supplies the concrete shape.                                            |
| **Tool registry**                           | A sibling ambient namespace to the executor alphabet. Holds named tool values (`getDate`, `searchAssets`, …) referenced inside config records.                       |
| **Config constructor**                      | A tagged-record value form inside a config: `qualified.name { ... }` (no leading `@`). Semantics determined by the consuming executor's schema.                      |

## Runtime vocabulary

| Term                          | Definition                                                                                                                                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Envelope**                  | The JSON-carrier shape every Wire value travels in at runtime: `{ contract, mediaType, producer, value, provenance }`.                                                                                      |
| **Payload kind**              | A contract's runtime category: `json`, `markdown`, `text`, `table`, `artifact_ref`. Selects validation and rendering.                                                                                       |
| **Contract registry**         | The Haskell-owned authoritative definitions of contracts: schema, codec, payload kind, examples, lint rules.                                                                                                |
| **Evaluation-boundary check** | The runnable-wire gate: every singular input connected to exactly one edge. Runs at evaluation-preparation, not type-checking.                                                                              |
| **Rewire**                    | A bounded runtime topology modification over a live Circuit. Subject to vocabulary, endpoint-compatibility, topology, and resource (gas) bounds. Modules: `Cortex.Pulse.Rewrite` plus the Wire compiler.    |
| **Realized circuit**          | The concrete Circuit topology that existed after admitted rewires during a run. A runtime artifact, not a grammar construct.                                                                                |
| **Gas**                       | The structural-change budget consumed by rewires: nodes added, edges added, depth, frontier breadth, rewrite operations.                                                                                    |
| **Proof contract**            | A mechanized safety surface whose terms lead runtime implementation. Haskell admission code must either construct values satisfying the proof contract or reject the input before it reaches that boundary. |
| **Topological memory**        | A node-addressable accumulated context from upstream evaluations. Declared on the node, consumed at evaluation time. Downstream home: `Logos.Memory.Topological`; Pulse supplies the settled event state.   |
| **Frontier**                  | The set of graph nodes ready to execute at a given point. Pulse schedules over the frontier.                                                                                                                |

## Ownership boundary

- **Wire composes registered authority.** Wire source references registered nodes, contract IDs,
  executor config, and wiring. It does not invent executors, tools, payload types, or domain
  authority.
- **Theory names safety obligations.** Where a mechanized proof contract exists, the proof-side
  vocabulary is normative. Runtime code enforces that shape at admission and persistence boundaries;
  it does not weaken the contract to fit convenient implementation types.
- **Haskell owns what the authority means.** Executors, contracts, codecs, payload kinds, and
  registry schemas are Haskell-defined and live outside Wire.
- **Product concepts stay downstream.** Launch fields, report sections, model-policy choices,
  user-facing workflow labels — these live in consumer bindings. They can wrap a Circuit; they are
  not part of the generic Cortex Circuit layer.

See [Architecture/01-overview.md](../Architecture/01-overview.md) and
[Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) for
the full ownership story.

## Doc-kind vocabulary

Terms used to classify docs in `docs/`. See [../map.md](../map.md) for how each doc kind is placed
and [../taxonomy.md](../taxonomy.md) for the organizing axes.

| Term                  | Where                                    |
| --------------------- | ---------------------------------------- |
| **Canonical chapter** | `Architecture/NN-*.md`                   |
| **Reference**         | `Reference/**/*.md`                      |
| **ADR**               | `ADRs/NNNN-*.md`                         |
| **Epic**              | `Roadmap/Epics/*.md`                     |
| **Plan**              | `Roadmap/Plans/*.md`                     |
| **Research note**     | `Research-notes/{scope}/YYYY-MM-DD-*.md` |
| **Experiment**        | `Experiments/{scope}/YYYY-MM-DD-*.md`    |
| **Manuscript**        | `Publications/paper-N-*/manuscript.md`   |

## Related

- [Wire/grammar.md](Wire/grammar.md) — normative Wire grammar.
- [../Architecture/01-overview.md](../Architecture/01-overview.md) — canonical overview.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) — Wire substrate
  architecture.
- [../glossary.md](../glossary.md) — informal quick-reference.
- [../taxonomy.md](../taxonomy.md) — conceptual classification.
