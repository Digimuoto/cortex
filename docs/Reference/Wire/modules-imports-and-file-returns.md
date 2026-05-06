---
title: "Wire Reference — Modules, Imports, and File Returns"
description:
  Scoped reference for the Wire module model. File structure, import forms, file-return expressions,
  declaration-only files.
sidebar:
  label: Modules and imports
  order: 2
status: draft
date: 2026-04-29
related:
  - docs/Reference/Wire/grammar.md
  - docs/Architecture/05-wire-language.md
---

# Wire Reference — Modules, Imports, and File Returns

The normative grammar lives in [grammar.md](grammar.md). This page summarizes the module-facing
rules.

## File Shape

A `.wire` file is a sequence of top-level forms: `contract`, `use`, `kind`, `form`, `node`,
`let`/`export let`, and `import`.

```wire
contract EvidenceSet;
export let acceptedItem = item: item.score >= 0.7;

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = evidence.items |> filter acceptedItem;

classify
```

The last expression without a trailing semicolon is the file-return value. If there is no
file-return expression, the file is declaration-only.

The CLI can compile a named graph-valued binding instead of the default file-return:

```sh
wire build --return exported_planner ./pipeline.wire
```

This is useful for files that serve as a catalog of exported graph values while still having a
default executable file-return.

## Imports

Registry namespace imports use `use`:

```wire
use std.io.{@stdin, @stdout, @command, @readFile, @writeFile, CommandSpec, CommandResult};
use std.io.{@command as @shell, CommandSpec as Spec};
```

`use` brings selected registry-catalog names into source scope. Executor selectors carry `@`;
contract selectors do not. Imported aliases lower to canonical executor and contract IDs in compiled
metadata.

`use` is source-local and explicit. It does not propagate across file imports, and wildcard imports
such as `use std.io.*;` are not part of v1.

File imports use `import`:

```wire
import pipeline from "./pipeline.wire";
import { acceptedItem, analyst } from "./helpers.wire";
```

The named file import form imports another file's file-return value. The explicit file import form
imports named `let` bindings. `export let` marks the intended importable surface; until import
visibility is fully enforced, it is documentation plus a forward-compatible commitment.

Contracts are ambient once a file is loaded. Node declarations are not directly importable; expose a
node by binding it:

```wire
node planner
  -> plan: PlannerOutput = @review.planner ({});

export let exported_planner = planner;
```

## Declaration-Only Files

Declaration-only files contribute:

- ambient `contract` assertions;
- source-local `kind` and `form` declarations used by bindings in the same file;
- importable `let` bindings.

They do not leak node names or ordinary local names into importing files.
