---
title: "ADR 0017 — Wire Executor and Port Catalog Boundary"
description:
  "Wire separates value-level contracts, id-referencing port profiles, compile-time projections,
  runtime payload validation, Pulse framing, and host codecs."
sidebar:
  label: "0017. Executor and ports"
  order: 17
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0016-cortex-roots-and-logos-pattern-extraction.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
  - "GitHub #55"
---

# ADR 0017 — Wire Executor and Port Catalog Boundary

## Status

Proposed — names the central seam in the Wire staging surface: `WireCompileEnv` currently conflates
executor-authority projection, executor-port projection, and contract-catalog projection. The target
architecture splits those responsibilities.

The concrete cross-repo extraction sequence that first exposed this seam (moving a downstream
reasoning pattern's port maps out of a product binding) is a downstream concern and lives in the
Logos repository; this ADR keeps only the substrate boundary. ADR 0040 governs the
model/provider/tool ownership referenced below.

## Context

In Wire discussions, "contract" and "port" are often used for three different things:

- value-level payload meaning
- structural boundary slots on nodes
- host/runtime code that marshals Haskell values and grants executor authority

Those are different architecture artifacts. Folding them together makes it hard to extract reusable
downstream pattern structure without accidentally moving product authority into the substrate or a
reasoning library.

The current Haskell staging surface also blurs the seam. `WireCompileEnv` carries at least three
distinct projections in one record:

- the set of known executor ids, which is an authority projection from the host
- the port shape each executor exposes, which is a catalog projection
- the contract registry, which is the value-level catalog

Wire does not need all host authority metadata to compile. It needs a projection: known contract ids
and port shapes for the executor ids that source mentions.

## Decision

Cortex separates value-level contracts, id-referencing port profiles, compile-time projections,
runtime payload validation, Pulse framing, and host application codecs.

### Contracts are values, not Haskell types

A Wire contract is a value-level descriptor of what a payload means at a Wire boundary. It is pure
data: enumerable, serializable, shippable as JSON, comparable by id, and usable across process and
language boundaries. It is not a Haskell type, and it is not parameterized over one.

Current Haskell shape:

```haskell
data WireContractSpec = WireContractSpec
  { wcsId :: ContractId
  , wcsPayloadKind :: WirePayloadKind
  , wcsSchema :: Maybe Aeson.Value
  , wcsDescription :: Text
  , wcsExamples :: [Aeson.Value]
  }

data WirePayloadKind
  = WirePayloadJson
  | WirePayloadMarkdown
  | WirePayloadText
  | WirePayloadTable
  | WirePayloadArtifactRef

data WireValue = WireValue
  { wireValueContract :: ContractId
  , wireValuePayloadKind :: WirePayloadKind
  , wireValueValue :: Aeson.Value
  }
```

`WirePayloadKind` is a closed Wire enum. Adding a payload kind is a Wire change, not a downstream
extension point. The current runtime is JSON-value centered: markdown and text payloads are JSON
strings, table payloads are JSON objects or arrays, and artifact refs are JSON objects. A contract
catalog must survive documentation generation, JSON export, Pulse replay logs, and future
cross-language clients. Making contracts phantom-typed Haskell values would make that catalog
property depend on every consumer sharing the same Haskell type definitions.

Haskell payload types are a binding-layer concern. A downstream binder may decide that a host type
corresponds to a contract id such as `cortex.example.research-plan/v1`, but the contract catalog
does not know that Haskell type exists.

### Ports reference contracts by id

A port is the structural shape of one boundary slot on a node. It references a contract by id and
adds positional metadata: local label, cardinality, requiredness, and exclusive-output grouping. A
port never carries the full contract spec inline.

Illustrative target shape:

```haskell
data Cardinality = One | ZeroOrOne | Many

data WireInputPort = WireInputPort
  { wipLabel :: PortLabel
  , wipContractId :: ContractId
  , wipCardinality :: Cardinality
  , wipRequired :: Bool
  }

data WireOutputPort = WireOutputPort
  { wopLabel :: PortLabel
  , wopContractId :: ContractId
  , wopCardinality :: Cardinality
  , wopGroup :: Maybe ExclusiveGroup
  }

data WirePorts = WirePorts
  { wpInputs :: [WireInputPort]
  , wpOutputs :: [WireOutputPort]
  }
```

A port profile is a named `WirePorts` value published in a catalog. The name is what makes it
shareable. Many executors can declare that they conform to a named profile, and Wire can check that
the executor's projected ports match the profile structurally. Port profiles carry no runnable
authority.

Labels become mandatory when a node needs distinct roles for the same contract — for example a
comparative rewriter with `previous: ReportSection` and `reference: ReportSection`, an analysis diff
with `baseline: Analysis` and `candidate: Analysis`, or a pure scoring node with several `Float`
inputs. Those cases motivate pure output equations and structural primitives; ADR 0020 owns that
sequencing. Where every node input already has a distinct contract, contract-only routing suffices
and no node needs two same-contract slots.

### Executors grant authority through bindings

An executor definition is not a contract and not merely a port shape. It names a runnable authority
and should eventually include executor id, production kind from ADR 0014, config schema or decoder,
port profile reference or explicit port constraints, replay and side-effect metadata, tool-scope
requirements, and the host binder or interpreter. Model/provider selection policy, when an executor
is model-mediated, is **downstream binding metadata carried by the host binding — not a
`Cortex.Capability` API** (ADR 0040).

The binder is where Haskell type identity matters. Executors are implemented over real application
types. The binder bridges those values into `WirePayload` and binds the Haskell type to a contract
id under host authority.

Illustrative downstream shape:

```haskell
class HasContract a where
  contractId :: ContractId

class HasContract a => WireCodec a where
  encodeWire :: a -> WirePayload
  decodeWire :: WirePayload -> Either DecodeError a
```

These instances live with the application type or downstream pattern binding, not inside the
value-level contract catalog. The catalog remains serializable and language-neutral.

## Layer Split

The architecture has two distinct serialization layers.

**Layer 1: Pulse wire framing.** Pulse owns deterministic framing from `WireValue` to bytes. The
framing table is closed and indexed by `WirePayloadKind`, but the current representation is
JSON-centered: JSON payloads are framed as canonical JSON, markdown and text payloads are JSON
strings, table payloads are JSON objects or arrays, and artifact refs are JSON objects. Downstream
consumers must not plug arbitrary codecs into this layer because durable replay depends on stable
framing.

**Layer 2: application codecs.** The host binder owns mappings between Haskell types and
`WireValue`. This is where an executor returning a host type is encoded into a JSON-valued payload
carrying that type's contract id. Replay decodes the persisted `WireValue` through the same host
codec when a runnable stage needs the application type again.

The enforcement responsibilities are also separate.

**Compile time.** Wire checks only structural facts: known contract ids, port shapes per mentioned
executor id, labels, cardinality, exclusive output groups, and graph topology. It does not need
schemas, codecs, or Haskell payload types.

**Wire runtime.** Wire runtime validates that emitted `WireValue` values match the declared output
contract's payload kind and coarse shape, and under strict projection rejects a declared typed
output whose contract or payload kind is incompatible with the node's declared output ports. That
strict check is contract- and port-structural and has **no provider or model-output awareness**:
typed model-output policy — validation modes, schema source, retry — is a downstream
reasoning-library concern (ADR 0040). Future schema and content validation belongs in this layer
after payload-kind checks; it still does not know Haskell application types.

**Pulse persistence.** Pulse persists framed `WireValue` bytes according to the closed
`WirePayloadKind` table. Contract schemas do not affect framing.

**Host binding.** The binder admits executor ids, config, tools, provider/model policy, artifact
destinations, product permissions, and application codecs. It is the place where authority and
Haskell type identity enter — all of it downstream of the substrate compile and runtime checks.

**Executor.** The executor is ordinary host code over host types. It is downstream of the binding
decision and does not define Wire contract semantics.

The dependency rule is: lower substrate layers know less. Contract catalogs do not know Haskell
types. Wire knows contract ids, port profiles, payload kinds, and schemas, but not application
codecs. Pulse knows payload kinds and framing, but not schemas or Haskell types. Host codecs know
Haskell types and contract ids, but do not define Pulse framing.

## `WireCompileEnv` Target Shape

`WireCompileEnv` should become an explicit compile-time projection rather than a mixed authority and
catalog record. This is the central seam: executor admission is a host decision, while executor port
shape is the structural projection Wire uses for checking.

Current staging shape:

- known executor ids are present because maps are keyed by executor id
- executor port shapes are present as `WirePorts`
- contract registry is present as catalog data

Target shape:

- richer `ExecutorSpec` or host registration records live outside Wire compile
- each executor spec references a port profile or declares explicit port constraints
- Wire receives only the projection it needs: `Map ExecutorId WirePorts` plus the contract registry,
  in strict or explicitly permissive mode
- host authority metadata no longer leaks into the compile-time API

Port catalogs can publish inert profile values now while leaving executor authority downstream. Pure
nodes and structural primitives should wait until same-contract labeled slots are tested as part of
their implementation, because those features actually require labels for expressiveness.

## Downstream pattern extraction

Concrete reusable reasoning patterns (for example a deep-report pattern) may publish named generic
port profiles and import them into a product binding that overrides or extends them for
product-specific executors, while keeping the runtime binder and payload records downstream. That
extraction preserves the existing graph language — it introduces no new port-label semantics,
pure-node syntax, or structural-primitive syntax — and it must not move product authority (executor
dispatch, prompts, provider keys, model defaults, tool authorization, DB-backed loading, workspace
artifact destinations) into the substrate. The concrete extraction sequence for any one pattern is a
downstream concern owned in the consuming repository, not Cortex canon.

## Alternatives considered

- **Make contracts phantom-typed Haskell values.** Rejected because contracts must be serializable
  catalog values usable by docs, logs, cross-process replay, and non-Haskell clients.
- **Let ports carry contract specs inline.** Rejected because ports are endpoint structure. Inlining
  specs would duplicate catalog data and make contract identity harder to compare.
- **Let executors own contracts.** Rejected because contracts are shared across many executors and
  future patterns.
- **Let downstream code plug Pulse framing codecs.** Rejected because durable replay requires a
  closed, deterministic, kind-indexed framing table.
- **Move the host runtime binder into a reasoning library.** Rejected because the binder grants
  tool, provider, artifact, DB, and product authority. Reasoning-library patterns may publish inert
  catalogs and templates, not host authority.
- **Delay port extraction until a full `ExecutorSpec` exists.** Rejected because duplicate
  `WirePorts` maps are already extractable as inert catalog values. A full executor-definition API
  can follow once the profile boundary is proven.

## Consequences

### Positive

- Contract catalogs remain portable data rather than Haskell-only type witnesses.
- Substrate-generic port profiles can move to Cortex without moving host runtime authority.
- Executors can share contract vocabulary and port profiles explicitly.
- Pulse replay has a closed framing story independent of application codecs.
- Future executor-definition work has a target shape rather than being inferred from
  `WireCompileEnv` maps.

### Negative

- The transition keeps a staged API where `WireCompileEnv` still mixes compile projection and
  temporary executor-port maps.
- Port catalogs introduce another named artifact that must be documented and kept in sync with
  templates.
- Broad object schemas in the current contract catalog still defer real content validation.
- Application codec ownership must be documented for each downstream binding.

### Obligations

- Add tests when extracting generic port profiles to prove the profile names, accepted contracts,
  output contracts, labels, and cardinalities.
- Keep generated or materialized build metadata with source changes that expose new Haskell modules.
- Keep Pulse framing closed and deterministic; do not make it a user codec hook.
- Add schema/content validation after the current payload-kind and coarse-shape runtime checks
  before relying on schemas as enforced contracts.
- Keep application `WireCodec` instances out of contract catalogs unless a future ADR deliberately
  introduces a language-specific binding package.
- Do not let a reasoning-library pattern module grant product authority or reopen model/provider
  ownership (ADR 0040).
- Replace `Maybe WireContractRegistry` with an explicit strict/permissive mode before claiming
  closed authority for imported templates.

## Traceability

- Feature keys: `wire.executor_port_catalog`
- Public surface: `Cortex.Wire`,
  [Wire Contracts, Ports, and Matching](../Reference/Wire/contracts-ports-and-matching.md)
- Implementation: `src/Cortex/Wire/Executor.hs` (`WireExecutorProjection`, `WirePorts`,
  `WireInputPort`, `WireOutputPort`, `WireExecutorRegistry`, `wireExecutorProjectionFromPorts`),
  `src/Cortex/Wire/Contracts.hs` (`WireContractSpec`, `WireContractRegistry`, `WireCompileEnv`,
  `WireProjectionMode`, `strictWireCompileEnv`), `src/Cortex/Wire/Value.hs` (`WirePayloadKind`
  closed framing enum)
- Tests: `test/Cortex/Wire/CompileSpec.hs`
  (`allows a strict registered executor projection with matching ports`,
  `WireExecutorPortsMismatch`)
- Theory/proof: none
- Tracking: GitHub #55

## Related

- [ADR 0010 — Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0014 — Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0016 — Cortex Canonical Root Taxonomy](./0016-cortex-roots-and-logos-pattern-extraction.md)
- [ADR 0019 — Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0020 — Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0040 — Logos-Owned Reasoning Surfaces](./0040-logos-owned-reasoning-surfaces.md)
- [Chapter 05 — Wire Language](../Architecture/05-wire-language.md)
- [Wire Reference — Contracts, Ports, and Matching](../Reference/Wire/contracts-ports-and-matching.md)
- GitHub #55
