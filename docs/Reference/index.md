---
title: Cortex Reference
description: Consultable rules and contributor reference material for Cortex.
sidebar:
  label: Reference
  order: 2
---

# Cortex Reference

Consultable material. Designed to be jumped into for a specific rule or workflow rather than read
front-to-back. If you are trying to do a task rather than look up a rule, start with
[Usage/](../Usage/).

## Contents

- **[terminology.md](terminology.md)** — accepted Wire and Cortex terms. Canonical definitions; the
  source of truth for vocabulary.
- **[Wire/](Wire/)** — Wire language reference:
  - **[grammar.md](Wire/grammar.md)** — normative grammar specification.
  - **[style.md](Wire/style.md)** — formatting and layout conventions for Wire examples and source
    files.
  - **[modules-imports-and-file-returns.md](Wire/modules-imports-and-file-returns.md)** — module
    model, import semantics, file-return rules.
  - **[contracts-ports-and-matching.md](Wire/contracts-ports-and-matching.md)** — contract
    namespace, port declarations, `=>` port-key matching.
  - **[executor-authorities-and-execution-boundary.md](Wire/executor-authorities-and-execution-boundary.md)**
    — executor authority values, explicit node admission, evaluation-boundary check.
  - **[executors-and-alphabet.md](Wire/executors-and-alphabet.md)** — executor registration, `@`
    authority, executor authority values, ambient identifiers in config values.
- **[rewrites.md](rewrites.md)** — bounded dynamic rewrite algebra, budget, admission,
  materialization, hydration, provenance.
- **[proof-status.md](proof-status.md)** — human-readable matrix of Lean proof claims and Haskell
  correspondence status.
- **[feature-status.md](feature-status.md)** — capability/status canon: feature keys, governing
  ADRs, implementation/proof status, and evidence links. The release-note extraction source.
- **[development.md](development.md)** — build, test, formatting, docs, theory, and local validation
  commands.
- **[Pulse/](Pulse/)** — Pulse runtime reference:
  - **[schema.md](Pulse/schema.md)** — DB enums, task definitions, runs, checkpoints, stage log,
    stage attempt log.
  - **[types.md](Pulse/types.md)** — task envelope, checkpoint envelope, stage plan, retry policy,
    memory strategy.
  - **[service-api.md](Pulse/service-api.md)** — HTTP endpoints, authentication, idempotency,
    cancellation, error taxonomy.

Architecture chapters (`../Architecture/`) explain why the rules are what they are. References state
the rules. The architecture book quotes the references for precision; the references quote the
architecture book for context.

## Related

- [../Architecture/](../Architecture/) — canonical architecture chapters.
- [../Usage/](../Usage/) — practical user guide.
- [../glossary.md](../glossary.md) — quick-reference term lookup.
- [../taxonomy.md](../taxonomy.md) — conceptual classification.
