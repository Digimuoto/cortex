---
title: "ADR 0044 - Wire Namespace Use Imports"
description:
  "Adds explicit `use` imports for registry namespaces so standard Wire packs can be brought into
  source scope without weakening registry-based authority."
sidebar:
  label: "0044. Namespace use imports"
  order: 44
status: proposed
date: 2026-05-02
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0042-wire-standard-effect-executors.md
---

# ADR 0044 - Wire Namespace Use Imports

## Status

Proposed - this ADR defines explicit namespace imports for registry-backed Wire packs, initially
scoped to `std.io`.

## Context

Wire already has file imports:

```wire
import { acceptedItem } from "./helpers.wire";
```

Those imports are about source files and exported `let` bindings. They are not the right mechanism
for names that come from a registered executor and contract catalog.

The standard IO pack needs a visible source dependency without turning standard host effects into
CorePure builtins or globally ambient names. At the same time, ADR 0010's closed-authority rule
should remain intact: runtime authority is admitted by the host registry, not by syntax alone.

## Decision

Wire gains a top-level registry-namespace import form:

```wire
use std.io.{@stdin, @stdout, @command, @readFile, @writeFile, CommandSpec, CommandResult};
```

Selectors are explicit. Executor leaves carry the `@` marker; contracts do not:

```wire
use std.io.{@command as @shell, CommandSpec as Spec};
```

The imported local names may then be used in executor and port positions:

```wire
node run_check
  <- spec: Spec;
  -> result: CommandResult = @shell {} (spec);
```

The `use` form is a source-scope dependency, not a replacement for registry authority. It decides
which standard-pack names are referenceable in a Wire file. The host still decides whether
`std.io.command` exists, what effect class it has, and whether it is bound at runtime.

For v1:

- `std.io` is the only implemented registry namespace.
- `@std.io.stdin`, `@std.io.stdout`, `@std.io.command`, `@std.io.readFile`, and `@std.io.writeFile`
  require an explicit `use std.io.{...};` in the same file before they can be referenced.
- Bare `@stdin`, `@stdout`, `@command`, `@readFile`, and `@writeFile` resolve only when imported by
  `use`.
- Imported aliases lower to canonical executor and contract IDs in compiled metadata.
- `use` does not propagate across file imports; each source file declares its own registry namespace
  dependencies.
- Wildcards are not admitted. `use std.io.*;` is intentionally invalid in v1.

This keeps source dependencies auditable while preserving the registry as the runtime authority
gate.

## Alternatives Considered

- **Make `std.io` globally ambient** - rejected because standard effects would become invisible
  dependencies in source.
- **Use file `import` for registry names** - rejected because file imports and registry catalogs
  have different identity, authority, and loading rules.
- **Gate every registered executor through `use` immediately** - deferred. Existing non-standard
  executor names remain fully qualified registry references so this change does not widen the
  migration blast radius.
- **Admit wildcard imports** - rejected for v1. The standard pack is small, and explicit selectors
  make host-effect dependencies easier to review.
- **Put `@` on namespace roots** - rejected. The authority marker belongs to executor leaves:
  `std.io.{@command}`, not `@std.io.{command}`.

## Consequences

### Positive

- Standard host effects are visible as source dependencies.
- Local aliases improve ergonomics without changing canonical compiled IDs.
- The pure core stays free of hidden IO names.
- File imports and registry namespace imports have separate syntax and separate semantics.

### Negative

- Wire now has two top-level import-like forms.
- Standard-pack names have stricter source-scope rules than existing non-standard executor names.
- Aliased source names require compiled metadata and diagnostics to preserve canonical IDs.

### Obligations

- Keep diagnostics clear when a `std.io` executor is referenced without `use`.
- Keep `use` selector lists explicit until a later ADR admits wildcard semantics.
- Keep canonical compiled executor IDs stable even when source uses aliases.
- Document std pack contracts and executor projections in Haskell library APIs so host authors do
  not copy string literals.

## Related

- [Wire grammar](../Reference/Wire/grammar.md)
- [Wire modules, imports, and file returns](../Reference/Wire/modules-imports-and-file-returns.md)
- [Wire executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [ADR 0010 - Wire Closed Authority and Three-Layer Stack](0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0017 - Wire Executor and Port Catalog Boundary](0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0042 - Wire Standard Effect Executors](0042-wire-standard-effect-executors.md)
