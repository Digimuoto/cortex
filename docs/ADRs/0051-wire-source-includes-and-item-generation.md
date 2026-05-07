---
title: "ADR 0051 - Wire Source Includes and Item Generation"
description:
  "Adds Rust-style compile-time source includes and makeEach itemized node generation without
  granting runtime filesystem authority to CorePure."
sidebar:
  label: "0051. Source includes"
  order: 51
status: proposed
date: 2026-05-07
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0045-wire-compile-time-node-body-kinds.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
---

# ADR 0051 - Wire Source Includes and Item Generation

## Status

Proposed - extends ADR 0048 with itemized generation and records the source-elaboration include
surface.

## Context

Build-style Wire programs often need to derive graph shape from repository files: one command per
source file, one check per header, one generated frontier per discovered item. Modeling that as a
runtime executor hides graph structure inside shell strings and gives CorePure filesystem authority
it should not have.

The desired behavior is source-elaboration authority, similar to Rust's `include_str!`: if a file or
directory is absent, the Wire source does not compile. Once elaborated, runtime CorePure sees only
ordinary embedded values.

## Decision

Wire adds Rust-style source include forms:

- `include_str("path")` / `includeStr("path")` embeds a UTF-8 file as a string literal.
- `include_dir("path")` / `includeDir("path")` embeds a sorted list of directory-entry records.

Relative paths resolve against the containing Wire file. Directory entries expose `name`, `path`,
`stem`, `extension`, `label`, and `entryType`. `label` is sanitized for generated node identities.

Wire also adds `makeEach(items, K)`. `items` must be a static list literal or a preceding static
list binding whose elements are strings or records with a string `label` field. `K` must be a kind
reference with either:

- one `PortLabel` parameter; or
- `PortLabel, Value`, where the full item is passed as the value argument.

Generated nodes are named `<binding>_<item.label>`. `makeEach` remains a source macro: it is valid
only in the same binding positions as `make(N, K)`.

## Consequences

- File and directory discovery can shape a Wire graph without hiding dependencies inside one
  executor command.
- CorePure remains authority-free at runtime; there is no runtime `readFile` builtin.
- Adding a source file changes the generated graph frontier and therefore exposes any required
  contract amendment at the typed boundary.
- The include surface is intentionally small. Recursive directory traversal, globbing, binary
  includes, and host-specific ignore rules remain future decisions.
