---
title: Package Manifests And Extensions
description: Load non-standard Wire namespaces while keeping runtime authority separate.
sidebar:
  label: 06. Packages
  order: 6
---

# Package Manifests And Extensions

The `wire` CLI always knows Cortex standard namespaces. A Wire file that uses extension namespaces
needs package manifests at compile time.

## Explicit Manifests

Pass one or more manifests with `--wire-package`:

```bash
nix run .#wire -- \
  --wire-package extensions/quantum/packages/quantum-core/cortex.toml \
  --wire-package extensions/quantum/packages/quantum-braket/cortex.toml \
  build examples/wire/quantum-realize-collect.wire
```

Repeat the flag when an example needs more than one package.

## Package-Owned Modules

A package can also publish helper Wire source through `[[module]]` entries:

```toml
[package]
id = "example.review"

[[module]]
path = "example.review/helpers.wire"
source = '''
export let normalize = pure(x) { x };
'''
```

Wire files compiled with that manifest can import the package module by its manifest path:

```wire
import { normalize } from "example.review/helpers.wire";
```

Package modules are compile-time source only. Loading a manifest does not grant runtime authority or
filesystem access. Package-owned modules therefore cannot use `include_str` or `include_dir`.

## Environment Search Path

If no `--wire-package` flags are present, the CLI reads `CORTEX_WIRE_PACKAGE_MANIFESTS` as a search
path. Use it when a local shell or script should provide the same package set for several commands.

If neither explicit flags nor the environment variable are present, the CLI loads only Cortex
standard namespaces.

## What Manifests Do Not Grant

A package manifest selects compile-time package data. It does not grant:

- runtime executor authority
- provider credentials
- a simulator or hardware backend
- Pulse database access
- host policy or product tools

For example, a quantum Wire file can compile against quantum package manifests, but useful execution
still needs a quantum consumer binding and backend.

## Related

- [Running Wire examples](05-running-wire-examples.md)
- [Wire modules, imports, and file returns](../Reference/Wire/modules-imports-and-file-returns.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Quantum consumer](../Consumers/Quantum.md)
