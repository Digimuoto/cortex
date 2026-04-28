---
title: "Wire Reference — Modules, Imports, and File Returns"
description:
  Scoped reference for the Wire module model. File structure, import forms, file-return expressions,
  declaration-only files.
sidebar:
  label: Modules and imports
  order: 2
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar.md
  - docs/Architecture/05-wire-language.md
---

# Wire Reference — Modules, Imports, and File Returns

> **Stub.** This page is a scoped entry point into the module-model rules in
> [grammar.md](grammar.md). Until it is fleshed out, jump directly to the grammar sections below.

> **Implementation warning.** Current compiler behavior parses `contract X;` but does not use it to
> populate registry membership. With an explicit `WireContractRegistry`, only Haskell-registered
> contracts are enforced. The reference grammar names the intended contract-assertion semantics; the
> compiler path still has a narrower registry-backed implementation.

## Where the rules live

- **[§9 Top-level forms](grammar.md#9-top-level-forms)** — the whole module model: `contract`,
  `node`, `let`, `import`, file-return expression, wire files vs declaration-only files, closed
  composition with open vocabulary.
- **[§9.4 `import`](grammar.md#94-import)** — import forms, what enters local scope, `let`-aliasing
  pattern for node exports, ambient contract side effects.
- **[§9.5 File-return expression](grammar.md#95-file-return-expression)** — last-expression
  semantics, what makes a file a wire file.
- **[§9.6 Wire files and declaration-only files](grammar.md#96-wire-files-and-declaration-only-files)**
  — what declaration-only files contribute.
- **[§9.7 Closed composition, open vocabulary](grammar.md#97-closed-composition-open-vocabulary)** —
  the compilation-unit definition: program = root file + transitive imports.

## Summary of the rules

- A `.wire` file is a sequence of top-level forms (`contract`, `node`, `let`, `import`), optionally
  terminated by a file-return expression without trailing `;`.
- `import name from "path";` brings the file's return value into scope as `name`.
- `import { x, y } from "path";` brings explicit `let` bindings into scope.
- Only `let` bindings are importable. `node` declarations are exposed across files by
  `let`-aliasing.
- Contract declarations are ambient — loading a file registers its `contract X;` assertions
  globally.
- The program is the root file plus the transitive closure of its imports.

See the grammar for the full definitions.
