---
title: "ADR 0054 - Downstream Wire Packages and Host Runtime Bindings"
description:
  "Defines Wire packages as the compile-time downstream package boundary and host runtime binding
  packs as the runtime authority that lowers admitted Circuit nodes to Pulse stage definitions."
sidebar:
  label: "0054. Wire packages and host bindings"
  order: 54
status: proposed
date: 2026-05-11
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Consumers/Logos/reasoning-library.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
  - docs/ADRs/0044-wire-namespace-use-imports.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - "GitHub #208"
---

# ADR 0054 - Downstream Wire Packages and Host Runtime Bindings

## Status

Proposed - defines the downstream package boundary needed to make ADR 0019 and ADR 0053 usable by
Logos and other Cortex consumers without moving downstream semantics into Cortex or runtime
authority into reusable downstream libraries. Runtime authority lives in host runtime binding packs
published by product hosts, not in Wire packages published by libraries.

## Context

Cortex already has the core layer split:

- Wire compiles against inert executor projections and contract registries.
- Capability owns authority-bearing executor registration and runtime binding.
- Pulse executes already-bound `StageAction`s and does not know downstream semantics.
- ADR 0053 splits executor admission projections, executor manifests, and runtime binding records.

That still leaves a practical downstream packaging gap. A reasoning library such as Logos needs to
publish reusable Wire workflows, executor profiles, contracts, and namespace exports. Today those
pieces are assembled by ad hoc Haskell code: downstream tests manually build `WireCompileEnv`
values, Wire module imports are parsed but not compiled, `use` namespaces are hard-coded around
`std.io`, and hosts have to connect `ExecutorSpec`, `WireExecutorProjection`, `CircuitPulseBinder`,
and `wrapWireStageDefinition` by convention.

The missing abstraction is not a Pulse plugin registry and not a Logos-specific runtime. It is two
distinct package boundaries: one that publishes static Wire vocabulary, and a separate one that
publishes host-owned runtime authority. Conflating them — for example, by giving a single
"downstream pack" both registry namespaces and binder hooks — implicitly grants runtime authority to
whichever library is imported. Reusable libraries must not be able to grant credentials, tools, DB
writes, or artifact persistence by existing.

## Decision

Cortex defines two separate downstream package boundaries:

- **Wire package** - compile-time vocabulary only. A Wire package is inert. Importing a Wire package
  never grants runtime authority.
- **Host runtime binding pack** - runtime authority only. A host runtime binding pack resolves
  declared executor requirements into concrete provider, tool, memory, and artifact bindings and
  produces ADR 0053 runtime binding records. Only hosts publish runtime binding packs.

A host runtime binding pack may depend on one or more Wire packages; a Wire package must not depend
on a host runtime binding pack. This dependency direction is what keeps Logos and other reusable
libraries from carrying runtime authority by existing.

### Wire package

A Wire package exposes only compile-time, inert material:

- contract registry fragments;
- executor admission projections (the ADR 0053 admission-projection artifact);
- registry namespace exports for `use`, such as `logos.deep_report.{@planner, PlannerOutput}`;
- source `.wire` modules with declared package identity;
- config-constructor and tool-name vocabulary that the executor's projected config schema accepts;
- declared executor requirements — model provider, named tools, host permissions, memory, artifact
  authority — using the existing `ExecutorRequirement` vocabulary. These are declared, not granted.

Tool names in a Wire package are opaque string literals admitted by executor config schemas, and
`ExecutorRequirement` labels are host-binding obligations. Neither is a Cortex tool registry, a
permission system, or a Wire/Pulse "tool" primitive — they are vocabulary the executor's admission
projection accepts and the host runtime binding pack resolves.

A Wire package can support `wire check`, namespace `use`, module `import`, and admitted Circuit
emission. It cannot mint runtime binding records, lower nodes to `StageDefinition`s, or supply
credentials. A Wire package that names a required tool or model declares an obligation for the host;
it does not satisfy that obligation.

### Host runtime binding pack

A host runtime binding pack carries the authority that an admitted Circuit needs to become a
runnable Pulse plan:

- binder hooks that lower admitted `CircuitTaskNode`s into Pulse `StageDefinition`s, layered on the
  existing `CircuitPulseBinder` surface;
- an explicit **manifest selection catalog** mapping `(executor id, admission projection version)`
  (optionally with a selector) to a manifest content address; first-run selection freezes into the
  ADR 0053 runtime binding record;
- resolution of declared `ExecutorRequirement` slots into concrete provider credentials, tool
  implementations, artifact stores, memory handles, and host permission decisions, captured as
  resolved authority fingerprints on the binding record;
- isolation policy decisions (which ABI kinds and isolation profiles are admissible for which
  manifests) that satisfy the manifest's minimum isolation expectation;
- ADR 0053 runtime binding records minted from accepted executor manifests, host bindings, or
  capability adapters;
- a **compatibility predicate** (versioned with the pack) that decides whether a resumed stage may
  re-enter under the current pack state. The predicate body is host code; Cortex canon names the
  inputs the predicate must consider but does not specify its decisions.
- host policy on irreversible side-effect authority and on per-handle commit/abort semantics for
  external effects.

Host runtime binding packs are published by product hosts, not by reusable downstream libraries. A
Logos pack should be a Wire package. A product host bundles its own runtime binding pack on top of
one or more Logos Wire packages.

### Tools are executor config, not a Cortex authority

LLM tool access is not a Cortex-native concept. When an LLM-style executor wants tool access, the
tool list flows through the executor's ordinary static config, validated by the executor's admission
projection (ADR 0053):

```wire
let reviewer = @logos.deep_report.reviewer {
  model = "gpt-5.4";
  tools = ["web_search", "read_artifact"];
  memory = topological { preset = "reviewer"; };
};
```

Wire treats `tools` as inert config data. Pulse never sees a tool list as a first-class concept. The
host runtime binding pack resolves each named tool to a concrete implementation, records a
resolved-authority fingerprint on the runtime binding record, and lets the per-language ABI driver
inject the resolved value into the executor through whatever mechanism that driver uses. The
canonical Pulse-visible ABI (ADR 0053) is `inputs -> outputs`; tool implementations are never call
arguments at the Pulse boundary.

This is why Cortex does not need an LLM-tool registry, an LLM-tool permission system, or any notion
of "tool" in Wire or Pulse. The existing `ExecutorRequiresTool name` requirement is a declaration
that an executor's config may reference a tool by name; the host runtime binding pack decides
whether that tool name resolves and what implementation it resolves to. Tool selectors are
host-local — two hosts can resolve `"web_search"` to different providers and the difference appears
on the binding record, not on the Wire program.

## Layer ownership

### Cortex.Wire

`Cortex.Wire` owns Wire package composition and compile-time surfaces:

- Wire package metadata, dependencies, and exported fragments;
- contract registry composition;
- executor admission-projection registry composition;
- registry namespace lookup for `use`;
- Wire module resolver protocols;
- strict compile failures for missing contracts, executor projections, namespace exports, and
  package modules.

Wire does not own provider credentials, runnable native artifacts, host permissions, or downstream
semantics. A successful `wire check` may require only contracts, projections, namespaces, and module
sources.

### Cortex.Capability

`Cortex.Capability` owns host runtime binding pack composition and authority-bearing binding
surfaces:

- host runtime binding pack metadata, dependencies on Wire packages, and exported binder hooks;
- executor specs, `ExecutorRequirement` slot resolution, and manifest selection catalogs;
- isolation policy decisions per `(manifest, ABI kind)` that satisfy the manifest's minimum
  isolation expectation;
- deterministic binder composition over the `CircuitPulseBinder` surface;
- the existing profile-only versus host-bound `ExecutorBindingAuthority` distinction, applied at the
  pack layer;
- conversion from accepted host bindings or executor manifests into ADR 0053 runtime binding
  records, including resolved authority fingerprints and isolation policy digests;
- a versioned **compatibility predicate** evaluated on resume against the runtime binding record.

Composition fails when two packs export the same canonical namespace item, contract id, executor id,
or module id with incompatible definitions. If two packs intentionally provide the same definition,
they must share a stable identity or content digest so equality is mechanical rather than
conventional.

### Cortex.Pulse

Pulse remains unchanged. It receives ordinary `StagePlan`s and `StageDefinition`s. It does not load
Wire packages, inspect Logos modules, resolve Wire imports, choose provider bindings, or execute
package-manager logic.

### Downstream packages

Downstream reasoning libraries such as Logos publish Wire packages, not host runtime binding packs:

- reusable contracts, ports, executor profiles, and Wire modules;
- model/tool/provider-independent reasoning patterns;
- package namespaces such as `logos.deep_report`;
- declared `ExecutorRequirement`s identifying which executor ids require host authority.

They do not grant provider credentials, tool implementations, host permissions, or artifact
persistence. The dependency direction is one-way: hosts depend on Logos Wire packages, never the
reverse.

## Registry namespaces

ADR 0044 introduced `use` for registry-backed namespace imports and initially scoped implementation
to `std.io`. Wire packages generalize the backing registry.

For example, a Logos Wire package may export:

```wire
use logos.deep_report.{@planner, @section_writer, PlannerOutput, ReportFragment};
```

The selector rules remain the same:

- executor leaves carry `@`;
- contract and value/config names do not;
- aliases lower to canonical ids in compiled metadata;
- `use` is source-local and does not propagate through file imports;
- wildcard imports remain out of scope for v1.

The namespace registry is compile-time data derived from composed Wire packages. `use` makes a
source dependency visible; it does not grant runtime authority. If a host compiles a module with
`logos.deep_report.{@planner}` but no host runtime binding pack supplies a binder for that executor,
static checking may succeed and runnable bundle emission fails.

## Wire module resolver

Wire file imports should compile through an explicit module resolver rather than through Haskell
`Text` templates.

The resolver receives a module reference from `import`, locates a local file or package-owned Wire
module, parses it, checks export visibility, and contributes its declarations and exported bindings
under the normal Wire import rules. Package-owned modules are identified by package/module identity,
not by downstream Haskell module names.

The current source distinction remains:

- `use` imports registry names from composed Wire packages;
- `import` loads Wire source modules and exported `let` bindings.

This ADR does not require a full package manager, lockfile, external registry, or new import syntax.
It requires a resolver boundary so package-owned `.wire` files can replace Haskell string-template
assembly.

An illustrative package-backed module import can keep the existing string-reference shape while
resolving through a package-aware resolver:

```wire
import deep_report from "logos.deep_report/deep_report.wire";
```

The exact accepted module-reference grammar is an implementation detail for the resolver. The
semantic requirement is that a package module import has stable package/module identity and normal
Wire export checking.

## Compile, lower, run flow

A downstream host that wants to run a packaged workflow follows this path:

1. Select Wire packages, such as `Logos.Patterns.DeepReport`.
2. Select or compose a host runtime binding pack that supplies model providers, tool
   implementations, native executors, artifact persistence, isolation policy, a manifest selection
   catalog, a compatibility predicate, and permissions for the requirements declared by those Wire
   packages.
3. Compose contract registries, executor admission projections, namespace exports, and Wire module
   resolvers from the selected Wire packages.
4. Compile Wire in strict mode, including package-owned module imports.
5. Emit an admitted Circuit whose nodes carry executor ids, canonical admitted config, typed ports,
   admitted-config digests, and declared requirement selectors.
6. Compose host runtime binders deterministically from the host runtime binding pack, pinning
   manifest selection per node and resolving each declared requirement slot.
7. Lower each `CircuitTaskNode` through the composed binder to a Pulse `StageDefinition` carrying an
   ADR 0053 runtime binding record (manifest content address, ABI driver digest, resolved authority
   fingerprints, isolation policy digest, accepted replay class, compatibility predicate reference)
   and an opaque `StageAction`.
8. Run the resulting `StagePlan` through Pulse unchanged.
9. On resume, the binder reconstructs the `StageAction` from the durable binding record and the
   pack's compatibility predicate decides whether re-entry is admissible.

Binder composition must be deterministic. If no binder handles a node, lowering fails. If more than
one binder claims the same canonical executor id or runtime binding id without an explicit
composition rule, lowering fails. Lowering also fails when no manifest in the pack's selection
catalog matches `(executor id, admission projection version)` and the optional selector, or when the
chosen manifest's minimum isolation expectation cannot be satisfied by the pack's isolation policy.

Memory and retrieval authority remain executor config plus declared requirements that the host
runtime binding pack resolves. They are not hidden Wire edges, not node-to-node context, and not a
new Pulse plugin registry.

## Logos DeepReport proof point

`Logos.Patterns.DeepReport` should be expressible as a Wire package.

It can expose:

- DeepReport contracts such as planning, evidence, section, review, and report-fragment contracts;
- executor profiles such as `logos.deep_report.planner`, `section_writer`, and `reviewer`;
- namespace exports under `logos.deep_report`;
- reusable Wire modules for the DeepReport graph shape;
- declared `ExecutorRequirement`s naming the required model, tool, memory, and artifact authorities.

It must not expose provider credentials, product-specific tool implementations, product artifact
persistence, or host permissions. A host imports the Logos Wire package, adds a host runtime binding
pack that resolves the declared requirements into concrete model/tool/provider/artifact bindings,
compiles a DeepReport Wire module, lowers the admitted Circuit through the composed host runtime
binders, and runs the resulting ordinary Pulse plan.

This keeps ADR 0040 intact: Logos owns reasoning-library surfaces and publishes Wire packages, while
Cortex owns the substrate package and binding mechanics, and the host owns runtime authority.

## Alternatives considered

- **Continue assembling downstream Wire as Haskell `Text` templates** - rejected because source
  modules, export visibility, and compile errors should be Wire concepts, not string-concatenation
  side effects.
- **Hard-code every downstream namespace into Cortex** - rejected because `std.io` is a standard
  Wire-package precedent, not a reason for Cortex to know `logos.deep_report` or any product
  namespace.
- **Make Pulse load packs or plugins** - rejected because Pulse receives `StageDefinition`s and owns
  durable execution mechanics, not downstream package semantics.
- **Single "downstream pack" combining vocabulary and runtime authority** - rejected because a
  reusable library that can also grant runtime authority gains credentials, tools, DB writes, or
  artifact persistence by being imported. Splitting Wire packages from host runtime binding packs
  forces the host to publish authority explicitly.
- **Model LLM tools as a first-class Cortex concept** - rejected because tools are already ordinary
  static executor config validated by the executor's admission projection, and the host-bound
  executor runs its tool loop internally. Cortex does not need a tool registry, permission system,
  or Wire/Pulse tool primitive.
- **Let `use` grant runtime authority** - rejected because `use` is source-scope selection over
  already-registered names. Runtime authority still comes from the host runtime binding pack.

## Consequences

### Positive

- Downstream libraries can publish reusable Wire vocabulary without granting any runtime authority
  by existing.
- Static checking can consume Wire packages without exposing runnable authority.
- Registry namespaces become package-extensible instead of hard-coded to `std.io`.
- Host runtime binding packs become the explicit, host-owned path from admitted Circuit nodes to
  Pulse `StageDefinition`s.
- LLM tools, provider choice, and artifact authority stay where they belong: in executor config
  declared by the library and resolved by the host. Cortex acquires no LLM-tool concept.
- Pulse stays generic: packaged workflows lower to ordinary stage plans.

### Negative

- Wire-package and host-runtime-binding-pack composition each become compatibility surfaces with
  conflict detection and versioning.
- Module resolution must become an explicit compiler input.
- Hosts must publish their runtime binding packs explicitly rather than relying on a single combined
  pack from a library.
- Diagnostics must explain whether a failure came from missing source module, missing registry
  namespace item, missing projection, missing requirement resolution, or missing runtime binder.

### Obligations

- Define `WirePackage`, its metadata, and deterministic Wire-package composition.
- Define `HostBindingPack`, its dependency on `WirePackage`s, its manifest selection catalog, its
  isolation policy, its compatibility predicate, and deterministic binder composition over the
  existing `CircuitPulseBinder` surface.
- Define namespace-export data and use it to replace `std.io`-only `use` lookup.
- Define a Wire module resolver interface and compile package-owned imports.
- Extend strict compile environments so composed Wire packages provide contracts and executor
  projections.
- Document that LLM tools flow through executor config and `ExecutorRequirement` resolution, not
  through a new Cortex primitive, and that resolved tool implementations appear as authority
  fingerprints on the ADR 0053 runtime binding record.
- Add tests for package module import, downstream namespace `use`, strict missing-projection
  failures, requirement-resolution failures, manifest-selection failures, isolation-policy failures,
  binder lowering, resume admissibility, and unchanged Pulse execution.
- Document the Logos DeepReport Wire package as the first downstream proof point.

## Related

- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0040 - Logos-Owned Reasoning Surfaces](./0040-logos-owned-reasoning-surfaces.md)
- [ADR 0044 - Wire Namespace Use Imports](./0044-wire-namespace-use-imports.md)
- [ADR 0053 - Executor Catalog Manifests and Pulse Runtime Bindings](./0053-executor-catalog-manifests-and-pulse-bindings.md)
- [Wire modules, imports, and file returns](../Reference/Wire/modules-imports-and-file-returns.md)
- [Wire executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- GitHub #208
