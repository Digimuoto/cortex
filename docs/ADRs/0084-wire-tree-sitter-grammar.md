---
title: "ADR 0084 - tree-sitter-wire Grammar Governance"
description:
  "Govern tree-sitter-wire as maintained Wire substrate tooling, with the Wire grammar reference as
  normative syntax and the Haskell parser as the production compiler front-end."
sidebar:
  label: "0084. tree-sitter-wire"
  order: 84
status: proposed
date: 2026-06-30
superseded_by: null
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/style.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0076-wire-cli-proof-fixtures.md
---

# ADR 0084 - tree-sitter-wire Grammar Governance

## Status

Proposed. The tree-sitter grammar and generated artifacts are checked in and maintained today; this
ADR records the authority and regeneration policy for that second front-end.

## Context

`editors/tree-sitter-wire/` contains a grammar, generated parser artifacts, queries, tests, and
bindings used by editor integrations and grammar-drift checks. That makes it more than an example,
but it is still not the production compiler parser. The repository needs one authority rule so the
Wire grammar reference, Haskell parser, and tree-sitter grammar do not make competing claims.

## Decision

Maintain `tree-sitter-wire` as first-party Wire substrate tooling for editors and syntax-level drift
detection.

- `docs/Reference/Wire/grammar.md` is the normative syntax specification.
- `src/Cortex/Wire/Parser.hs` is the production compiler front-end.
- `editors/tree-sitter-wire/grammar.js` is the maintained editor/tooling grammar and should track
  the normative grammar closely enough for syntax highlighting, structural editor support, and
  parse-drift checks.
- Generated artifacts under `editors/tree-sitter-wire/src/` are checked in so consumers do not need
  the tree-sitter CLI at install time.
- Any grammar-affecting Wire change must update the grammar reference, production parser, formatter
  expectations where relevant, tree-sitter grammar/corpus, and generated tree-sitter artifacts in
  the same slice or explicitly record a deferred divergence.
- Semantic checks remain out of scope for tree-sitter: contract registries, executor admission,
  config validation, CorePure typing, and port linearity belong to the compiler.

## Consequences

### Positive

- Editor integrations have a governed first-party grammar.
- The authority order is explicit when parser and tree-sitter behavior diverge.
- Generated artifacts are treated as committed build outputs, not accidental churn.

### Negative

- Wire grammar changes must carry editor grammar maintenance cost.
- Tree-sitter may temporarily accept syntax that the compiler rejects semantically.

### Obligations

- Keep `editors/tree-sitter-wire/README.md` and editor integration READMEs aligned with this
  authority order.
- Regenerate and commit `parser.c`, `grammar.json`, `node-types.json`, and `tree_sitter/parser.h`
  after changing `grammar.js`.
- Keep tree-sitter corpus and fixture parsing checks current with accepted Wire syntax.

## Traceability

- Feature keys: `packaging.tree_sitter_wire`
- Public surface: `editors/tree-sitter-wire`, `docs/Reference/Wire/style.md`
- Implementation: `editors/tree-sitter-wire/grammar.js`, `editors/tree-sitter-wire/src/parser.c`
- Tests: `editors/tree-sitter-wire/test/parse-fixtures.sh`, `tree-sitter test`
- Theory/proof: none

## Related

- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0076 - Wire CLI Proof-Fixture and Grammar-Acceptance Subcommands](./0076-wire-cli-proof-fixtures.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
- [Wire Style Reference](../Reference/Wire/style.md)
