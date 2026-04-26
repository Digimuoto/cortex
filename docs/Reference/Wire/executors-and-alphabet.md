---
title: "Wire Reference — Executors and the Alphabet"
description: Scoped reference for executor registration, the closed alphabet, `@`-application, partial nodes, and ambient identifiers in config values.
sidebar:
  label: Executors
  order: 5
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar-v1.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
---

# Wire Reference — Executors and the Alphabet

> **Stub.** This page is a scoped entry point into the executor rules in [grammar-v1.md](grammar-v1.md). Until it is fleshed out, jump directly to the grammar sections below.

## Where the rules live

- **[§5.1 Executor registration](grammar-v1.md#51-executor-registration)** — what an executor is, what each executor declares (config schema, vocabulary, structural constraints, purity class), and how the alphabet is global.
- **[§5.2 Executor application](grammar-v1.md#52-executor-application)** — `@executor { config }` produces a partial node; schema-checking timing.
- **[§5.3 Config merge on partial nodes](grammar-v1.md#53-config-merge-on-partial-nodes)** — how `partial // record` produces new partials for "base + delta" reuse.
- **[§5.5 Ambient identifiers in config values](grammar-v1.md#55-ambient-identifiers-in-config-values)** — tool references and tagged-record config constructors.

Executor *kinds* (model-mediated generation vs registered external call) and their backend sub-taxonomy are decided in [ADR 0014](../../ADRs/0014-executor-taxonomy-model-vs-external-call.md); this page covers the *grammar-level* surface that sits above that taxonomy.

## Summary of the rules

- **Executors are a closed alphabet registered outside Wire.** User code cannot define new executors; it composes them.
- **Each registered executor declares** a config schema, a contract vocabulary (or open-vocabulary for contract-polymorphic executors), structural constraints on port signatures, and a purity class.
- **Application form is `@qualified.name { ... }`.** The leading `@` distinguishes executor references from bare identifiers; qualified names (`@llm.analyst`, `@artifact.log`, `@cortex.report_run`) resolve against the global registry.
- **Application produces a partial node** — a staged value with no ports pinned. Partial nodes are `let`-bindable, mergeable with `//`, and pinnable via a `node` declaration.
- **Partial-node config merge is right-biased and shallow.** `base // { k = v; }` creates a new partial with the config record merged; the executor is unchanged.
- **Ambient identifiers inside config values** (tool references, config constructors like `topological { preset = "analyst" }`) are drawn from sibling registries. The grammar admits qualified identifiers and tagged records opaquely; the executor schema decides which are meaningful.

See the grammar for the full definitions.

## Related

- [Partials and execution boundary](./partials-and-execution-boundary.md) — when a partial node may appear directly in graph position.
- [Contracts, ports, and matching](./contracts-ports-and-matching.md) — the port-key rule that executor-declared port signatures participate in.
- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — substrate architecture.
