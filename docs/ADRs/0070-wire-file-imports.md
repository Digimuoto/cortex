---
title: "ADR 0070 - Wire File Imports, File-Return Selection and Module Closure Semantics"
description:
  "Codifies Wire's file-module model: file-return values, named and explicit `import` forms, `export
  let` visibility, ambient contract merge, and the IO loader / pure compiler closure split with
  cycle and missing-file detection."
sidebar:
  label: "0070. Wire file imports"
  order: 70
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/Reference/Wire/grammar.md
  - docs/ADRs/0044-wire-namespace-use-imports.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
---

# ADR 0070 - Wire File Imports, File-Return Selection and Module Closure Semantics

## Status

Proposed - this ADR records the already-implemented Wire file-module model as a governed decision.
[ADR 0044](0044-wire-namespace-use-imports.md) introduced registry-namespace `use` imports and
referenced file `import` only as pre-existing background; the file-module rules themselves had no
governing ADR and lived only in a draft Reference page. This ADR closes that gap.

## Context

Wire is a closed-authority topology language
([ADR 0010](0010-wire-closed-authority-and-three-layer-stack.md)): a `.wire` file composes
registered executors and contracts into a graph. Once authors split a graph across files, the
substrate needs a precise answer to a set of coupled questions that the namespace `use` form
(ADR 0044) deliberately does not address:

- What does a `.wire` file _evaluate to_ when another file or the CLI loads it?
- Which of the two `import` syntaxes (`import name from "p"` vs `import { a, b } from "p"`) imports
  what — a whole graph, or named bindings?
- Which names a file defines are actually importable, and how is that visibility enforced?
- How do contracts declared in an imported file interact with the importer's contracts?
- Where do missing files, parse failures, and import cycles get detected, and with what diagnostics?

These rules already ship: the IO loader in `src/Cortex/Wire/Import.hs` and the pure compiler in
`src/Cortex/Wire/Compile.hs` implement them, and `test/Cortex/Wire/ImportSpec.hs` pins the
behaviour. ADR 0044 treated all of this as settled background while it added a _different_
import-like form for registry names. The asymmetry is the problem: the registry-import decision is
governed canon, while the older and more load-bearing file-import model is described only in a
`status: draft` Reference page. This ADR promotes the file-module model to governed canon so later
changes have a decision to amend.

The closed-authority constraint shapes every rule below: file imports move source-level bindings and
contract _shapes_ between files, never runtime authority. Whether an executor exists is still a host
registry question, and `use` scope stays source-local per file (ADR 0044) rather than travelling
across an `import`.

## Decision

A `.wire` file is a **module**. Adopt the following file-module model as Wire canon.

A module is a sequence of top-level forms (`contract`, `use`, `let` / `export let`, `node`,
`import`) optionally followed by a single **file-return** expression: the last expression with no
trailing semicolon. A module with no file-return expression is **declaration-only**. The file-return
must be a graph value; declaration-only modules contribute contracts and importable `let` bindings
but compile to no circuit on their own.

Two `import` forms select different surfaces of a target module, both resolved relative to the
importing file:

- **Named form** `import name from "./p.wire";` binds the target's _file-return graph value_ to
  `name`. A declaration-only target, or one whose file-return is not graph-valued, is rejected.
- **Explicit form** `import { a, b } from "./p.wire";` binds the target's _exported names_ —
  graph-valued `export let`, value `export let`, and exported CorePure bindings.

`export let` is the enforced importable surface. A private `let` is module-local; importing a name
that the target defines but does not export fails with a visibility error that names the binding and
suggests `export let`. Node declarations are never directly importable; an author exposes a node by
binding it (`export let p = some_node;`).

Contracts are **ambient on load**: every `import` merges the imported module's contract surface
(including record shapes) into the importer. Identical shapes merge silently; a same-name contract
with a different shape is an error; a local redeclaration of an ambient contract with an identical
shape is a readability no-op. This is the one surface where an import is implicit — authors do not
list contract names in an import selector.

The CLI may override the compiled return with **file-return selection**:
`wire build --return NAME FILE` compiles the root module's named graph binding `NAME` instead of its
default file-return. This lets a file serve as a catalog of exported graph values while keeping a
default executable file-return, and it relaxes the all-declared-nodes-used check for the selected
build.

Loading is split across the IO/pure boundary. The IO loader `loadWireModuleClosure` reads the root
file, expands its Rust-style `include_str` / `include_dir` forms, parses it, and recurses through
its `import` paths, returning a **dependency-ordered closure** (dependencies first, root last) keyed
by canonicalised file path. The pure compiler `compileWireModules` consumes that ordered closure and
never touches the filesystem. Missing files, per-module parse failures, and import cycles are
detected and reported by the loader, with the importing file and the full cycle chain in the
message.

## Boundary rules

- **Two error layers.** The IO loader reports `WireImportError` (`WireImportFileNotFound`,
  `WireImportReadError`, `WireImportIncludeError`, `WireImportModuleParseError`, `WireImportCycle`);
  the pure compiler reports `WireError` (visibility, duplicate-binding, missing-circuit,
  contract-shape conflicts). A cycle is a load-time error and never reaches the compiler.
- **Module identity is the canonical path.** Two import routes to the same file resolve to one
  module; the closure loads it once. The same module surface reached through two routes refers to
  the same bindings and merges silently, but graph values still consume their ports linearly
  regardless of how many routes imported them.
- **Imported names land in the importer's top-level namespace.** A collision with any local binding
  (let, graph, node, contract, or `use` selector) is an error. An exported CorePure binding travels
  with the in-module support closure its expression references, even private dependencies; a private
  dependency that collides in the importer is reported as a dependency of the imported name.
- **Cross-module node-name hygiene.** Node refs carried in through an imported graph are tracked so
  a locally declared node, or a node from a second imported graph, that reuses a node name is
  rejected with the originating module in the message.
- **Includes resolve at their own file.** `include_str` / `include_dir` inside an imported file
  resolve relative to that imported file, not the root, and are expanded before parsing.
- **`use` does not cross imports.** Per ADR 0044, registry-namespace `use` scope is source-local: a
  helper file's `use` does not leak through an `import`, and the importer needs its own `use` for
  any executor it names directly.

## Alternatives considered

- **Leave the model in the draft Reference page only.** Rejected. The behaviour is shipped and
  load-bearing, and ADR 0044 already cites it as settled. A governed decision is needed so the named
  vs explicit split, the visibility rule, and the ambient-contract rule have a canonical home that
  later ADRs can amend.
- **One unified `import` form that figures out graph-vs-name from the target.** Rejected. The named
  form imports exactly one thing — the file-return graph — and rejecting a declaration-only target
  is a clearer contract than silently importing nothing. Keeping two syntaxes makes the author's
  intent, and the failure mode, explicit.
- **Make imports re-export transitively (a name imported into B is visible to B's importers).**
  Rejected. Each module's importable surface is exactly its own `export let` bindings; transitive
  re-export would make a module's public surface depend on its private import graph and weaken the
  closed-authority review story.
- **Resolve and load inside the pure compiler.** Rejected. Path resolution, file reads, include
  expansion, and cycle detection are IO; folding them into the compiler would make graph compilation
  impure and untestable without a filesystem. The loader stays a thin effectful interpreter that
  hands the compiler an already-ordered closure.
- **Make contracts importable by explicit selector rather than ambient.** Rejected for now. Contract
  shapes are nominal and structural; merging identical shapes silently and erroring on conflict
  gives the safety of explicit imports without forcing authors to enumerate every contract a graph
  touches.

## Consequences

### Positive

- The file-module model is governed canon, not a draft page, so the named/explicit split,
  `export let` visibility, ambient contracts, and the loader's diagnostics are amendable decisions.
- The IO/pure split keeps graph compilation a pure function of an ordered closure; the loader is the
  only filesystem-touching component and is independently testable.
- Cycles, missing files, and unexported-name imports fail closed with diagnostics that name the
  importing file and the offending name or chain.
- File imports move bindings and contract shapes only; runtime authority stays a host-registry
  concern, preserving ADR 0010's closed-authority rule across module boundaries.

### Negative

- Wire now has two file-level `import` forms plus the separate `use` form, so authors must learn
  which surface each selects.
- Ambient contracts are an implicit import: a contract can become visible without appearing in any
  selector, which is convenient but less explicit than name imports.
- File-return selection (`--return`) is a second way to choose what a file compiles to, on top of
  the default trailing-expression file-return.

### Obligations

- Promote `docs/Reference/Wire/modules-imports-and-file-returns.md` from `draft` to a maintained
  status and keep it aligned with this decision.
- Keep loader diagnostics (missing file, cycle chain, parse failure) carrying the importing context.
- Keep the importable surface defined solely by `export let`; do not let future ergonomics introduce
  transitive re-export without a superseding ADR.
- Keep `include_str` / `include_dir` resolution anchored to the file that contains the call.

## Traceability

- Feature keys: `wire.file_imports`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/modules-imports-and-file-returns.md`
- Implementation: `src/Cortex/Wire/Import.hs`, `src/Cortex/Wire/Compile.hs`,
  `src/Cortex/Wire/Include.hs`, `src/Cortex/Wire/Syntax.hs`
- Tests: `test/Cortex/Wire/ImportSpec.hs`
- Theory/proof: none

## Related

- [Chapter 05 - The Wire Language](../Architecture/05-wire-language.md)
- [Wire modules, imports, and file returns](../Reference/Wire/modules-imports-and-file-returns.md)
- [Wire grammar](../Reference/Wire/grammar.md)
- [ADR 0044 - Wire Namespace Use Imports](0044-wire-namespace-use-imports.md)
- [ADR 0010 - Wire Closed Authority and Three-Layer Stack](0010-wire-closed-authority-and-three-layer-stack.md)
