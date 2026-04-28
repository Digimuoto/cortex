---
title: Wire Language Reference
description:
  Normative reference for the Wire source language. Grammar, module model, ports and matching,
  partials and evaluation boundary.
sidebar:
  label: Wire
  order: 1
---

# Wire Language Reference

The Wire language reference is organized into a normative grammar specification plus topic-focused
pages that factor out specific rule areas for quick consultation.

## Contents

- **[grammar.md](grammar.md)** — the normative grammar specification. The authoritative document;
  other pages in this directory point into its sections.
- **[modules-imports-and-file-returns.md](modules-imports-and-file-returns.md)** — module model,
  `import` semantics, file-return expressions, declaration-only files. Corresponds to grammar §9.
- **[contracts-ports-and-matching.md](contracts-ports-and-matching.md)** — contract namespace, port
  declarations, sum groups, labels, `=>` port-key matching. Corresponds to grammar §4, §6.2–§6.5,
  §7.1, §7.6.
- **[partials-and-execution-boundary.md](partials-and-execution-boundary.md)** — partial nodes in
  graph position, port-determined rule, evaluation-boundary check. Corresponds to grammar §5.4, §11.
- **[executors-and-alphabet.md](executors-and-alphabet.md)** — executor registration,
  `@`-application, config merge, ambient identifiers in config values. Corresponds to grammar §5.1,
  §5.2, §5.3, §5.5.
- **[pure-execution.md](pure-execution.md)** — Wire-authored CorePure output equations, native pure
  evaluator lowering, input/output binding, builtins, and failure surface. Corresponds to grammar
  §6.1.1, §14.5.
- **[conditionality.md](conditionality.md)** — exclusive-output reduction with `select(...)`, latent
  continuations, arm keys, and current implementation status. Corresponds to grammar §7.7.

The rewrite algebra, admission, and materialization — a runtime concern — are in the separate
[Rewrites reference](../rewrites.md).

The grammar spec is self-contained. The topic pages exist to give readers a shorter, scope-limited
entry point when they are looking for specific rules without wanting to read the whole spec.

## Related

- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — Wire substrate
  architecture.
- [../terminology.md](../terminology.md) — accepted Wire terminology.
- [../../Research-notes/Wire/](../../Research-notes/Wire/) — dated design notes and synthesis.
