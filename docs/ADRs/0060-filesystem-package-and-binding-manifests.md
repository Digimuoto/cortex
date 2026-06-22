---
title: "ADR 0060 - Filesystem Package and Binding Manifests"
description:
  "Defines filesystem manifests as the concrete loading format for downstream Wire packages and host
  runtime binding packs, keeping package imports inert and runtime authority host-owned."
sidebar:
  label: "0060. Package and binding manifests"
  order: 60
status: proposed
date: 2026-06-22
superseded_by: null
related:
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
  - docs/Architecture/02-ownership-and-boundaries.md
  - "GitHub #287"
---

# ADR 0060 - Filesystem Package and Binding Manifests

## Status

Proposed. ADR 0054 defines the semantic split between inert Wire packages and host runtime binding
packs. This ADR defines the first concrete filesystem manifest shape for loading those artifacts
without baking downstream package data into Cortex modules.

## Context

ADR 0054 says downstream libraries publish Wire packages, while hosts publish runtime binding packs.
That is the right authority boundary, but the first quantum package implementation still lived as
Haskell data in `Cortex.Wire.Quantum`. That made the example useful but blurred the intended
dependency direction:

- Cortex core knew about a downstream package namespace.
- `wire build` could resolve `quantum.*` because the compiler imported a quantum bootstrap module.
- The package/binding-pack split was a Haskell convention rather than a loadable artifact boundary.

The quantum backend should become an in-repo downstream extension while it is developed, then be
movable out of tree without changing the Cortex substrate. The same mechanism should also serve
Logos and future consumer packages.

## Decision

Cortex defines filesystem manifests as the concrete loading format for downstream Wire packages and
host runtime binding packs.

### Wire package manifest

A Wire package manifest is compile-time, inert data. It may contain:

- package identity;
- exported `use` namespaces;
- namespace mappings from source leaves to canonical executor ids;
- namespace mappings from source contract names to canonical contract ids;
- executor admission projections;
- contract specs;
- optional package-owned Wire module paths in a later slice.

Loading a Wire package manifest never grants runtime authority. It only extends the namespace,
contract, and executor-projection registries used by Wire compilation.

The package manifest filename is `cortex.toml`. The format is intentionally author-facing TOML,
because package manifests are hand-maintained project metadata, closer to `Cargo.toml` or
`project.cabal` than to an internal JSON wire encoding. TOML is only the source format; the loaded
manifest still becomes ordinary typed package data inside Cortex.

The initial TOML shape is intentionally small:

```toml
[package]
id = "quantum.core"

[[namespace]]
name = "quantum.core"

[namespace.executors]
prepare_zero = "quantum.prepare_zero"

[namespace.contracts]
Qubit = "quantum.Qubit"

[[executor]]
id = "quantum.prepare_zero"
vocabulary = ["quantum.Qubit"]
effect = "host_effect"
config_shape = "unchecked"
port_policy = "author_declared"

[[contract]]
id = "quantum.Qubit"
payload_kind = "json"
description = "Quantum qubit token"
```

### Host runtime binding manifest

A host runtime binding manifest is authority-bearing host configuration. It may contain:

- binding-pack identity;
- dependency on one or more Wire packages;
- runtime binding records or manifest-selection catalogs;
- ABI driver references;
- authority fingerprints and host policy selectors;
- compatibility predicate identity.

The host binding manifest is not loaded by Wire compilation. It is loaded by the host/Pulse runner
that has authority to execute provider calls. A reusable Wire package must not depend on a binding
manifest.

### In-repo downstream extensions

In-repo downstream extensions live under:

```text
extensions/<name>/
```

They are not Cortex ADRs and not Cortex core modules. They are colocated workbenches used to test
the extension mechanism and to provide runnable showcases. The first extension is
`extensions/quantum/`, split into generic quantum core vocabulary and Braket vendor realization:

```text
extensions/quantum/
  packages/
    quantum-core/
    quantum-qec/
    quantum-braket/
  binding-packs/
    braket/
```

`plugins/` is rejected for this role because it suggests a runtime plugin loader or authority grant.
The correct boundary is package manifests plus host binding manifests.

### Compiler boundary

Pure Wire compilation receives a composed package registry through `WireCompileEnv`. The default
compile environment knows only Cortex's standard namespaces. Applications such as the `wire` CLI may
load manifests and pass the resulting package registry into compilation.

Cortex core must not expose consumer package bootstrap modules such as `Cortex.Wire.Quantum`.
Quantum package definitions belong in `extensions/quantum/packages/*/cortex.toml`.

## Consequences

- Downstream package data becomes reviewable data, not Haskell baked into Cortex core.
- `use quantum.core.{...}` remains a normal registry import and grants no AWS or Braket authority.
- Braket remains a vendor extension over `quantum.core`, not part of the generic quantum package.
- Package composition and conflict detection can evolve over manifest data without changing Wire
  syntax.
- Host runtime binding manifests still need a later implementation slice; this ADR only pins the
  boundary and first package manifest format.

## Rejected Alternatives

### Keep Quantum as a Core Bootstrap Module

Rejected. It keeps the first downstream package inside Cortex core and makes the intended ADR 0054
boundary unenforceable.

### Name the Workbench `plugins/quantum`

Rejected. "Plugin" implies runtime loading and possible authority grant. The extension model is
compile-time Wire package data plus separately loaded host authority.

### Put Vendor Realization in `quantum.core`

Rejected. Generic quantum circuit vocabulary and Braket realization have different portability and
authority properties. Braket belongs in a vendor package and binding pack.
