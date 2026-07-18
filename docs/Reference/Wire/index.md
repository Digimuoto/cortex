---
title: Wire Language Reference
description:
  Normative reference for the Wire source language. Grammar, module model, ports and matching,
  configured executors and evaluation boundary.
sidebar:
  label: Wire
  order: 1
---

# Wire Language Reference

The Wire language reference is organized into a normative grammar specification plus topic-focused
pages that factor out specific rule areas for quick consultation.

## Contents

- **[hosted-execution.md](hosted-execution.md)** — `x86_64-linux-v1` build bundle, validated
  artifact, engine state, JSONL protocol, runtime-host boundary, and Pulse backend selection.

- **[grammar.md](grammar.md)** — the normative grammar specification. The authoritative document;
  other pages in this directory point into its sections.
- **[style.md](style.md)** — canonical formatting and layout conventions for Wire source files,
  examples, and documentation snippets.
- **[modules-imports-and-file-returns.md](modules-imports-and-file-returns.md)** — module model,
  `import` semantics, file-return expressions, declaration-only files. Corresponds to grammar §9.
- **[contracts-ports-and-matching.md](contracts-ports-and-matching.md)** — contract namespace, port
  declarations, sum groups, labels, `=>` port-key matching. Corresponds to grammar §4, §6.2–§6.5,
  §7.1, §7.6.
- **[configured-executors-and-execution-boundary.md](configured-executors-and-execution-boundary.md)**
  — configured executor values, explicit node admission, and the execution boundary.
- **[executors-and-alphabet.md](executors-and-alphabet.md)** — executor registration, `@` authority,
  configured executor values, and ambient identifiers in config values.
- **[pure-execution.md](pure-execution.md)** — Wire-authored CorePure output equations, native pure
  evaluator lowering, input/output binding, builtins, and failure surface.
- **[conditionality.md](conditionality.md)** — exclusive-output reduction with `select(...)`, latent
  continuations, arm keys, and current implementation status. Corresponds to grammar §7.7.

The rewrite algebra, admission, and materialization — a runtime concern — are in the separate
[Rewrites reference](../rewrites.md).

The grammar spec is self-contained. The topic pages exist to give readers a shorter, scope-limited
entry point when they are looking for specific rules without wanting to read the whole spec.

## Proof Boundary

The Wire Reference describes the production source language. The current Lean proof boundary is
post-parse: Lean does not claim parser correctness for this surface. ADR 0078 records the Lean-owned
post-parse elaboration IR and primitive admission kernel; ADR 0079 records `WireAdmissionArtifact`
as the Haskell-to-Lean proof-witness exchange schema. The remaining compiler-authority decision is
open, and node-local egress projection remains open.

## Related

- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — Wire substrate
  architecture.
- [../../ADRs/0078-lean-wire-elaboration-kernel.md](../../ADRs/0078-lean-wire-elaboration-kernel.md)
  — post-parse Lean elaboration IR and primitive admission kernel.
- [../../ADRs/0079-wire-admission-witness-schema.md](../../ADRs/0079-wire-admission-witness-schema.md)
  — Wire admission artifact schema and validator authority direction.
- [../terminology.md](../terminology.md) — accepted Wire terminology.
- [../../Research-notes/Wire/](../../Research-notes/Wire/) — dated design notes and synthesis.
