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

A `.wire` file is a sequence of top-level forms:

```wire
contract EvidenceSet ;
export let acceptedItem = item: item.score >= 0.7 ;

node classify
  <- evidence: EvidenceSet ;
  -> accepted: AcceptedSet = pure (evidence.items |> filter acceptedItem) ;

classify
```

The last expression without a trailing semicolon is the file-return value. If there is no
file-return expression, the file is declaration-only.

## Imports

```wire
import pipeline from "./pipeline.wire" ;
import { acceptedItem, analyst } from "./helpers.wire" ;
```

The named import form imports another file's file-return value. The explicit import form imports
named `let` bindings. `export let` marks the intended importable surface; until import visibility is
fully enforced, it is documentation plus a forward-compatible commitment.

Contracts are ambient once a file is loaded. Node declarations are not directly importable; expose a
node by binding it:

```wire
node planner
  -> plan: PlannerOutput = @review.planner ({}) ;

export let exported_planner = planner ;
```

## Declaration-Only Files

Declaration-only files contribute:

- ambient `contract` assertions;
- importable `let` bindings.

They do not leak node names or ordinary local names into importing files.
