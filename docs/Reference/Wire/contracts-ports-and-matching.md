---
title: "Wire Reference — Contracts, Ports, and Matching"
description: Scoped reference for Wire's type surface. Contracts, port declarations, sum groups, labels, and the port-key match rule `=>` uses.
sidebar:
  label: Contracts and ports
  order: 3
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar-v1.md
  - docs/Architecture/05-wire-language.md
---

# Wire Reference — Contracts, Ports, and Matching

> **Stub.** This page is a scoped entry point into the type-surface rules in [grammar-v1.md](grammar-v1.md). Until it is fleshed out, jump directly to the grammar sections below.

## Where the rules live

- **[§4 Contracts](grammar-v1.md#4-contracts)** — global ambient namespace, contract equality, what contracts are not.
- **[§6.2 Port declarations](grammar-v1.md#62-port-declarations)** — input and output port syntax, port keys `(direction, contract, label)`, label-required cases, label semantics.
- **[§6.3 Singular vs list-valued ports](grammar-v1.md#63-singular-vs-list-valued-ports)** — arity rules.
- **[§6.4 No output ports](grammar-v1.md#64-no-output-ports)** — zero-output nodes.
- **[§6.5 Sum-grouped output ports](grammar-v1.md#65-sum-grouped-output-ports)** — `-> A | B` with mutual-exclusion metadata.
- **[§7.1 The three operators](grammar-v1.md#71-the-three-operators)** — `=>` port-key matching rule.
- **[§7.6 What is and isn't a match](grammar-v1.md#76-what-is-and-isnt-a-match)** — cross-product-with-filter consequences.

## Summary of the rules

- A **contract** is a named typed interface. Contracts are ambient in a global namespace, populated by executor vocabulary declarations and by `contract X;` assertions.
- A **port** is a slot on a node with a **port key** `(direction, contract, label)` where label may be absent.
- **`=>` matches on port key.** Labeled output connects only to identically-labeled input of the same contract; unlabeled connects only to unlabeled. No wildcard.
- A **singular input** accepts at most one edge; a **list input** `<- [C]` accepts zero or more.
- A **sum-grouped output** `-> A | B` fires exactly one variant per evaluation; its mutual-exclusion metadata survives to runtime.
- **Labels are semantic commitments**, not decorations. Adding a label changes routing.

See the grammar for the full definitions.
