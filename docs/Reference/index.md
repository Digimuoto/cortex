---
title: Cortex Reference
description: Consultable rules and contributor reference material for Cortex.
sidebar:
  label: Reference
  order: 2
---

# Cortex Reference

Consultable material. Designed to be jumped into for a specific rule or workflow rather than read
front-to-back.

## Contents

- **[terminology.md](terminology.md)** — accepted Wire and Cortex terms. Canonical definitions; the
  source of truth for vocabulary.
- **[Wire/](Wire/)** — Wire language reference:
  - **[grammar.md](Wire/grammar.md)** — normative grammar specification.
  - **[modules-imports-and-file-returns.md](Wire/modules-imports-and-file-returns.md)** — module
    model, import semantics, file-return rules.
  - **[contracts-ports-and-matching.md](Wire/contracts-ports-and-matching.md)** — contract
    namespace, port declarations, `=>` port-key matching.
  - **[configured-executors-and-execution-boundary.md](Wire/configured-executors-and-execution-boundary.md)**
    — configured executor values, explicit node admission, evaluation-boundary check.
  - **[executors-and-alphabet.md](Wire/executors-and-alphabet.md)** — executor registration, `@`
    authority, configured executor values, ambient identifiers in config values.
- **[rewrites.md](rewrites.md)** — bounded dynamic rewrite algebra, budget, admission,
  materialization, hydration, provenance.
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
- [../glossary.md](../glossary.md) — quick-reference term lookup.
- [../taxonomy.md](../taxonomy.md) — conceptual classification.
