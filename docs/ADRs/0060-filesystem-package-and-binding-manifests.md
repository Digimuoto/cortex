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
---

# ADR 0060 - Filesystem Package and Binding Manifests

## Status

Proposed. ADR 0054 defines the semantic split between inert Wire packages and host runtime binding
packs. This ADR defines the concrete filesystem manifest shape for loading those artifacts without
baking downstream package data into Cortex modules. The first implementation was driven by the
quantum extension, but the manifest mechanism is generic Cortex substrate.

## Context

ADR 0054 says downstream libraries publish Wire packages, while hosts publish runtime binding packs.
ADR 0053 says executors are registered through catalog data: Wire consumes inert admission
projections, while the host binding step mints runtime binding records. That is the right authority
boundary, but the first extension package was originally Haskell data in a Cortex module. That made
the quantum showcase useful, but blurred the intended dependency direction:

- Cortex core knew about a downstream package namespace.
- `wire build` could resolve an extension namespace because the compiler imported a bootstrap
  module.
- The package/binding-pack split was a Haskell convention rather than a loadable artifact boundary.

The filesystem manifest mechanism exists to remove that special case. Quantum is the first in-repo
extension used to test the mechanism, not the frame for the mechanism. The same manifest boundary
must serve Logos, quantum, and future consumer packages.

## Decision

Cortex defines `cortex.toml` filesystem manifests as the concrete author-facing loading format for
downstream Wire packages and host runtime binding packs.

The manifest system has two authority classes:

- a **Wire package manifest**, loaded by Wire compilation, which contributes only inert compile-time
  vocabulary;
- a **host runtime binding manifest**, loaded by a host runtime runner, which contributes the
  authority-bearing binding choices needed to run admitted executors.

The same filename is used because both are package metadata, but they are loaded by different
layers. A Wire compiler must never load a host runtime binding manifest as a side effect of `use`,
and Pulse never loads either manifest class (see the Pulse-blindness consequence below).

### Wire package manifest

A Wire package manifest is compile-time, inert data. The shape loaded today contains:

- package identity;
- exported `use` namespaces;
- namespace mappings from source leaves to canonical executor ids;
- namespace mappings from source contract names to canonical contract ids;
- executor projections — the inert `WireExecutorProjection` (identity, ports, vocabulary, effect,
  config shape, port policy);
- contract specs;
- package-owned Wire module sources.

Reserved for later slices, and not loaded by the current implementation: package dependencies and
executor capability requirement slots (the ADR 0053 `RequirementSlot` data). When they are added
they remain inert package data. The leaner `WireExecutorProjection` loaded today is deliberately
distinct from the richer ADR 0053 `AdmissionProjection`; only the latter carries projection version,
requirement slots, replay class, isolation expectation, and await strategy, and Wire compilation
never loads it.

Loading a Wire package manifest never grants runtime authority. It only extends the namespace,
contract, and executor-projection registries used by Wire compilation. Once requirement slots are
loadable, an executor projection that declares it requires a model provider, tool, quantum backend,
artifact store, filesystem permission, or other host capability records an obligation for a later
host binding step. It is not a permission grant.

The package manifest filename is `cortex.toml`. The format is intentionally author-facing TOML,
because package manifests are hand-maintained project metadata, closer to `Cargo.toml` or
`project.cabal` than to an internal JSON wire encoding. TOML is only the source format; the loaded
manifest still becomes ordinary typed package data inside Cortex.

The current implemented TOML shape is intentionally small:

```toml
[package]
id = "example.review"

[[namespace]]
name = "example.review"

[namespace.executors]
analyze = "example.review.analyze"

[namespace.contracts]
ReviewInput = "example.ReviewInput"
ReviewReport = "example.ReviewReport"

[[executor]]
id = "example.review.analyze"
vocabulary = ["example.ReviewInput", "example.ReviewReport"]
effect = "host_effect"
config_shape = "unchecked"
port_policy = "author_declared"

[[contract]]
id = "example.ReviewInput"
payload_kind = "json"
description = "Input accepted by the review analyzer."

[[contract]]
id = "example.ReviewReport"
payload_kind = "json"
description = "Report emitted by the review analyzer."

[[module]]
path = "example.review/helpers.wire"
source = '''
export let normalize = pure(x) { x };
'''
```

Future hardening slices may add manifest versioning, dependency declarations, conflict diagnostics,
and direct TOML syntax for ADR 0053 requirement slots. Those fields remain inert package data when
they are added.

### Capability registration model

Capabilities enter the manifest system through executor catalog metadata, not through Wire syntax.
There are two registrations with different authority:

1. The Wire package registers that an executor **requires** one or more capability slots. A
   requirement slot is the ADR 0053 `RequirementSlot`: a capability kind, a local binding name, an
   optional config selector path, and a permission class. Replay class, isolation expectation, and
   effect/await metadata are properties of the executor's ADR 0053 admission projection as a whole,
   not of an individual slot. The package may export that executor through a namespace so source can
   write `use example.review.{@analyze}`.
2. The host runtime binding pack registers how that executor is **resolved** in a specific host:
   manifest selection, ABI driver, `StageAction` identity, resolved authority fingerprints,
   compatibility predicate, runtime policies, and credential or provider selectors.

The invariant is:

> A package manifest can make a capability requirement visible to Wire admission, but only a host
> binding manifest can satisfy the requirement and mint a runtime binding record.

For an author, the target flow is:

1. Define contracts and an executor id in a Wire package manifest.
2. Attach the executor projection and (later slice) its declared requirement slots.
3. Export a namespace leaf that maps a source name to the canonical executor id.
4. Compile Wire against the package. `use` succeeds because vocabulary is present.
5. Lower/run through a host with a compatible binding pack. The binding pack resolves the declared
   requirements and records the chosen authorities on the runtime binding record.

Implementation status: the inert Wire-package half of this model is live — a `cortex.toml` loads an
executor projection (`WireExecutorProjection`) and `use` resolves its names, granting no authority.
The authority-bearing half is staged: requirement-slot TOML syntax, the richer ADR 0053 admission
projection over the Wire entry, and the host binding-pack resolver that mints runtime binding
records are later slices (see _Future hardening_ above and ADR 0053/0054). The `RequirementSlot`,
`AdmissionProjection`, and `RuntimeBindingRecord` types exist in the Capability layer today but are
not yet produced from manifests, and no executor manifest currently declares a requirement slot.

Failure points stay layer-specific:

- missing package or namespace: Wire `use` fails;
- missing contract or executor projection: strict Wire compilation fails;
- missing host binding pack: runnable Pulse lowering fails with a missing runtime binding;
- unresolved capability requirement: host binding fails before Pulse receives a runnable stage.

### Host runtime binding manifest

A host runtime binding manifest is authority-bearing host configuration. It may contain:

- binding-pack identity;
- dependency on one or more Wire packages;
- runtime binding records or manifest-selection catalogs keyed by executor id and projection
  version;
- ABI driver references;
- authority fingerprints and host policy selectors;
- compatibility predicate identity.

The host binding manifest is not loaded by Wire compilation. It is loaded by the host runtime runner
that has authority to execute provider calls — not by Pulse itself. A reusable Wire package must not
depend on a binding manifest.

An illustrative host binding manifest may eventually look like:

```toml
[binding_pack]
id = "example.host.review"
depends = ["example.review"]

[[binding]]
executor = "example.review.analyze"
projection_version = "v1"
stage_action = "example.review.analyze.v1"
manifest = "sha256:..."
compatibility = "example.review.compat.v1"

[[authority]]
kind = "model-provider"
name = "review_model"
selector = "gpt-5.4"
fingerprint = "sha256:..."
```

The exact field names belong to the binding-manifest implementation slice. The authority invariant
does not: this file is host material, not reusable Wire package material.

### In-repo downstream extensions

In-repo downstream extensions live under:

```text
extensions/<name>/
```

They are not Cortex ADRs and not Cortex core modules. They are colocated workbenches used to test
the extension mechanism and to provide runnable showcases. An extension may later move out of tree
without changing Cortex substrate semantics. The first extension is `extensions/quantum/`, split
into generic quantum core vocabulary and Braket vendor realization:

```text
extensions/quantum/
  src/                        -- the cortex-quantum library (host binding pack)
  packages/
    quantum-core/
    quantum-qec/
    quantum-braket/
  binding-packs/
    braket/
```

The Braket host binding pack is a separate `cortex-quantum` library component under
`extensions/quantum/src` that depends on Cortex core; it is not exposed by the Cortex core library.
The `binding-packs/` directory is reserved for the future `cortex.toml` binding manifest.

`plugins/` is rejected for this role because it suggests a runtime plugin loader or authority grant.
The correct boundary is package manifests plus host binding manifests.

### Compiler boundary

Pure Wire compilation receives a composed package registry through `WireCompileEnv`. The default
compile environment knows only Cortex's standard namespaces. Applications such as the `wire` CLI may
load manifests and pass the resulting package registry into compilation.

Cortex core must not expose consumer package bootstrap modules such as `Cortex.Wire.Quantum`, and it
must not expose vendor binding packs: the AWS Braket pack is the `cortex-quantum` library component,
not a Cortex core module. Quantum package definitions belong in
`extensions/quantum/packages/*/cortex.toml`, and other downstream packages should use the same
manifest mechanism rather than adding new Cortex modules.

## Consequences

- Downstream package data becomes reviewable data, not Haskell baked into Cortex core.
- `use` over any package namespace remains a normal registry import and grants no runtime authority.
- Capability-consuming executors can be published as inert catalog projections before any host
  agrees to run them.
- Vendor or product bindings remain host extensions over generic package vocabulary, not part of
  Cortex core.
- Package composition and conflict detection can evolve over manifest data without changing Wire
  syntax.
- Pulse stays blind to packages: it receives already-bound `StageAction`s and runtime binding
  records, never loads or interprets a Wire package or host binding manifest, and does not
  understand downstream package semantics (ADR 0054). Manifest loading is a host/compiler concern;
  Pulse dispatch is not.
- Host runtime binding manifests still need a later implementation slice; this ADR only pins the
  boundary, authority model, and first package manifest format.

## Rejected Alternatives

### Keep Quantum as a Core Bootstrap Module

Rejected. It keeps the first downstream package inside Cortex core and makes the intended ADR 0054
boundary unenforceable.

### Name the Workbench `plugins/quantum`

Rejected. "Plugin" implies runtime loading and possible authority grant. The extension model is
compile-time Wire package data plus separately loaded host authority.

### Let Package Imports Grant Capabilities

Rejected. A package import should make names and executor projections visible, but it must not
resolve providers, secrets, tool implementations, external queues, stores, or Pulse actions. Those
are host binding-pack decisions recorded as runtime binding records.

### Put Vendor Realization in `quantum.core`

Rejected. Generic quantum circuit vocabulary and Braket realization have different portability and
authority properties. Braket belongs in a vendor package and binding pack.

## Traceability

- Feature keys: `packaging.filesystem_manifests`
- Public surface: `Cortex.Wire` (`Cortex.Wire.Package.Manifest` — the `cortex.toml` loader); loaded
  by the `wire` CLI (`app/wire/Main.hs`), never by Pulse
- Implementation: `src/Cortex/Wire/Package/Manifest.hs` (`loadWirePackageManifests`,
  `decodeWirePackageManifest`); first in-repo package manifests at
  `extensions/quantum/packages/quantum-core/cortex.toml`,
  `extensions/quantum/packages/quantum-qec/cortex.toml`, and
  `extensions/quantum/packages/quantum-braket/cortex.toml`
- Tests: `test/Cortex/Wire/QuantumPackageSpec.hs`, `test/Cortex/Wire/RealizeCompileSpec.hs` (both
  load `cortex.toml` manifests through `loadWirePackageManifests`)
- Theory/proof: none

## Amendment - CLI package manifest discovery precedence (2026-06-28)

_Proposed amendment. Append-only clarification of the accepted decision above; the original decision
text is unchanged._

The `wire` CLI's manifest discovery and precedence policy is a thin host/compiler selection rule
under this ADR, not a separate package-authority decision. The CLI composes manifests in this order:
explicit repeated `--wire-package PATH` flags first; if no explicit flags are present, the
`CORTEX_WIRE_PACKAGE_MANIFESTS` search path; if neither is set, no extension packages are loaded and
the compile environment knows only Cortex's standard namespaces.

Manifest discovery still grants no runtime authority. It only selects package data for
`WireCompileEnv`; Pulse receives already-bound stage actions and never loads package manifests.

## Amendment - Package composition conflict contract (2026-06-28)

_Proposed amendment. Append-only clarification of the accepted decision above; the original decision
text is unchanged._

Wire package composition is deterministic internally, but public manifest loading must not silently
choose a winner when independently loaded packages claim the same identity. The package layer uses
left-biased composition for registries so the operation is stable, and exposes `PackageConflict`
diagnostics for duplicate package ids, namespaces, executor ids, and contract ids. Callers that load
external manifests must reject a non-empty `packageConflicts` result before compilation.

This discharges the earlier "future hardening" note for conflict diagnostics. Manifest versioning,
dependency declarations, and direct TOML syntax for future binding requirements remain deferred.

Traceability: `PackageConflict`, `packageConflicts`, and `renderPackageConflict` live in
`src/Cortex/Wire/Package.hs`; the `wire` CLI rejects conflicts before constructing `WireCompileEnv`;
coverage includes `test/Cortex/Wire/PackageSpec.hs` and `test/Cortex/Wire/QuantumPackageSpec.hs`.

## Amendment - package-owned Wire modules (2026-06-30)

Wire package manifests may include `[[module]]` entries. Each entry gives a logical package module
`path` and a literal Wire `source` body. These modules are inert compile-time source: they do not
grant runtime authority, do not imply filesystem access, and are loaded only when the selected
compile environment contains the manifest. Because package modules do not imply filesystem access,
the loader rejects `include_str` and `include_dir` forms inside package-owned module source.

Package composition rejects duplicate module paths, matching the duplicate-package/namespace/id
conflict policy above. File imports still resolve existing filesystem paths first. If an import path
does not exist on disk and matches a package module path in the compile environment, the loader
reads the package-owned source and gives it a package-module identity in the dependency closure.
Missing package-style paths produce package-module diagnostics rather than pretending to be missing
local files.
