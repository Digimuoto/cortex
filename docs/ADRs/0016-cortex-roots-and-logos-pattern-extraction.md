---
title: "ADR 0016 — Cortex Canonical Root Taxonomy"
description:
  "Cortex uses a small public root taxonomy — Algebra, Wire, Pulse, Capability — and a generic
  contract/executor model that those roots share."
sidebar:
  label: "0016. Cortex roots"
  order: 16
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0018-canonical-haskell-module-tree.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
---

# ADR 0016 — Cortex Canonical Root Taxonomy

## Status

Proposed — records the canonical Cortex public root taxonomy (`Algebra`, `Wire`, `Pulse`,
`Capability`) and the generic contract/executor model those roots share.

The original ADR also defined a downstream reasoning-library extraction (a `Logos` root taxonomy,
the `Logos.Patterns.DeepReport` extraction target, and a cross-repo Portman migration map). That
half is a downstream concern and has been relocated to the Logos repository; Cortex names Logos here
only as an illustrative downstream consumer. ADR 0040 narrows this ADR: model/provider surfaces,
tool-call records, structured-output policy, and report/document artifact IR belong to Logos, not
Cortex. The substrate module-tree migration itself is owned by ADR 0018.

## Context

The implementation-era Cortex root namespace carried roots that describe the wrong abstraction
level: `Cortex.Graph`, `Cortex.Circuit`, `Cortex.Event`, `Cortex.Document`, `Cortex.Memory`,
`Cortex.Agent`, `Cortex.Task`, `Cortex.Research`, `Cortex.Run`, and `Cortex.Provider`. `Graph` is
the law-bearing algebra, `Circuit` is the compiled form of Wire, events are Pulse execution records,
document-like outputs are artifacts, the old memory root mixed Pulse settled-state queries with
cognitive context construction, and the agent/task/research/run/provider modules were mostly
model-mediated reasoning machinery that belongs to the downstream reasoning library.

Two further problems motivated naming a generic substrate model explicitly:

- Executor authority, port-contract meaning, and pattern shape were not named as separate concepts.
- Shared contracts were copied as strings across executors, ports, and runtime config rather than
  composed from a catalog.

## Decision

The canonical public Cortex root taxonomy is:

```text
Cortex
|-- Algebra
|-- Wire
|-- Pulse
`-- Capability
```

Root responsibilities:

| Root                | Owns                                                                        | Does not own                                                                  |
| ------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `Cortex.Algebra`    | Graph/relation algebra, Mokhov laws, validation, rewrite laws.              | Durable execution, language parsing, model cognition.                         |
| `Cortex.Wire`       | Wire source language, contracts, compiled circuit form, runtime envelopes.  | Durable scheduling, host tool authority, reasoning patterns.                  |
| `Cortex.Pulse`      | Durable execution, frontier, checkpoints, persistence, signals, run events. | Cognitive memory shaping, model/tool loops, artifact semantics.               |
| `Cortex.Capability` | Executor registration and native pure-executor capability surfaces.         | Model clients, provider adapters, tool-loop records, reasoning output policy. |

Logos is the separate downstream reasoning-library root — model-mediated cognition: archetypes,
thoughts, cognitive memory, and reasoning patterns. It depends on Cortex and is defined in the Logos
repository, not in Cortex canon.

Artifact and provenance remain Cortex architecture concepts expressed through Wire contracts,
runtime envelopes, and Pulse provenance (see
[ch.08](../Architecture/08-artifacts-and-provenance.md)); Cortex exposes no public `Cortex.Artifact`
Haskell root (ADR 0040).

## The generic contract/executor model

These concepts define what the `Wire` and `Capability` roots own. They are substrate vocabulary that
any consumer — downstream reasoning library or otherwise — composes against.

### Capability

`Cortex.Capability` means substrate authority available to execution. After ADR 0040, the public
Haskell surface is executor registration plus native pure-executor configuration. Model calls,
provider adapters, tool-call records, structured-output fallback policy, and model-mediated tool
loops are downstream reasoning-library surfaces or host bindings, not Capability APIs.

The boundary is ownership: Cortex defines how registered executors enter the runtime; a downstream
reasoning library binds model and tool surfaces into one model-mediated unit's prompt policy and
lifecycle events.

### Executor

An executor is registered runnable authority referenced from Wire as `@qualified.name`. It is not a
contract and it does not own the meaning of a contract.

An executor definition should eventually name:

- executor id
- config schema or decoder
- accepted input contract refs and emitted output contract refs, or explicit contract-polymorphic
  constraints
- structural constraints over ports, such as required arity or exclusive output groups
- purity or effect class
- tool-scope requirements
- binder or runtime interpreter
- model/provider selection policy when model-mediated (downstream binding metadata, not a
  `Cortex.Capability` API; ADR 0040)

Executors consume and emit contract references from shared contract catalogs. Many executors may use
the same contract. One executor may support multiple contracts. Executor registration is authority
over runnable behavior, not over contract semantics.

### Port contract

A port contract is a named catalog entry describing the semantic obligation of a value crossing a
Wire boundary.

The current Haskell shape is `WireContractSpec`:

- contract id
- payload kind
- description
- optional schema
- examples

The contract catalog is the owner of payload meaning. Future extensions may add codecs, JSON Schema
validation, content linting, rendering hints, evaluation criteria, and migration metadata, but those
remain contract-catalog concerns.

Contract-level evaluation answers a single substrate question: "is this payload well-formed for the
named contract?" Higher-level evaluation of whether a model-mediated reasoning program met its
end-to-end obligations is a downstream concern, not a substrate contract concern.

Contracts are not executors, tools, prompts, or product permissions. They are shared data
obligations that executors and patterns reference.

### Contract enforcement

Contract enforcement happens in layers:

- **Compile time.** `WireCompileEnv` supplies a contract registry. The compiler checks that
  referenced input and output contract names are known when a registry is present. Wire then
  enforces port compatibility, labels, arity, and graph topology through existing port-matching
  rules.
- **Lowering/binding time.** Executor bindings decide whether a compiled node can be interpreted by
  the host. This is where executor ids, config fields, tool scopes, and product-specific authority
  are admitted.
- **Runtime.** `wrapWireStageDefinition`, `wrapWireStageResult`, and `wrapWireStageOutput` wrap
  values in `WireValue` envelopes, validate that outputs match declared ports, apply the registered
  payload kind, and reject shape mismatches.
- **Future content validation.** Contract schemas, codecs, and lint/evaluation rules should run
  after payload-kind checks and before downstream artifacts rely on the payload.

Current permissive behavior when no registry is provided is a development and compatibility mode,
not the desired closed-authority semantics for downstream patterns. The behavior commitment is
settled: patterns should compile against explicit registries. The pending decision is only the API
shape for expressing strict vs permissive mode without relying on `Maybe WireContractRegistry`.

### Sharing contracts between executors

Contracts are shared by composing catalog values, not by making one executor the owner of another
executor's vocabulary.

The intended sharing model is many-to-many:

- contract catalogs define named obligations
- executors declare which obligations they can accept and emit
- patterns declare which obligations their topology requires
- consumers compose the required catalogs into a `WireCompileEnv`
- downstream bindings may add domain-specific contracts without changing the generic catalog

For example, multiple executors in one reasoning pattern — a planner, gatherer, analyst, reviewer —
can all reference the same shared contract IDs while retaining separate executor behavior and
authority.

## Pending decisions

- Whether `.wire` `contract X;` declarations should admit local contract names, remain
  documentation-only, or become importable declaration files. Current compiler behavior parses them
  but does not use them for registry membership. The declaration-semantics follow-up remains open.
- The API surface for explicit strict/permissive contract-registry mode. The behavior is settled:
  patterns compile against explicit registries.
- The concrete executor-definition data type and whether it belongs under `Cortex.Capability`,
  `Cortex.Wire`, or a downstream pattern library.
- Whether a future substrate-shaped artifact API should exist at all; ADR 0040 leaves no public
  `Cortex.Artifact` Haskell root.

## Alternatives considered

- **Keep current root names.** Rejected because `Graph`, `Circuit`, `Event`, `Document`, `Memory`,
  `Agent`, `Task`, `Research`, `Run`, and `Provider` mix substrate forms, implementation surfaces,
  and reasoning-layer concepts at the same level.
- **Keep `Graph` as the root instead of `Algebra`.** Rejected because the root should name the
  law-bearing substrate; graph is one algebraic representation.
- **Keep `Circuit` as a peer root beside Wire.** Rejected as the canonical target because Circuit is
  the compiled executable form produced by Wire. Compatibility shims may remain while direct Circuit
  consumers migrate.
- **Keep `Document` as the root.** Rejected because the generic substrate concept is
  artifact/provenance. LLM report and research-section semantics belong to downstream reasoning
  patterns.
- **Keep `Memory` as a root.** Rejected because the old root mixed Pulse settled-state queries with
  cognitive-context construction. Pulse durable state remains Pulse; model/context shaping belongs
  to the downstream reasoning library.
- **Keep `Agent` as a substrate root.** Rejected because agent implies durable persona identity.
  Cortex evaluates graph nodes as bounded stage actions; interpreting selected stages as
  model-mediated thoughts is a downstream concern.
- **Let executors own contract definitions.** Rejected because the same contract must be shared by
  multiple executors and patterns. Executors should reference contract ids, not define their
  meaning.

## Consequences

### Positive

- The Cortex public root becomes small enough to explain: algebra, language, durable execution, and
  external capability, with artifact/provenance expressed through Wire and Pulse.
- Executors, contracts, and patterns become separately nameable and testable.
- Contract sharing becomes explicit through catalog composition.

### Negative

- Root migration creates compatibility-shim work and downstream import churn (owned by ADR 0018).
- Existing `.wire` docs overstate `contract X;` behavior until the pending declaration semantics are
  resolved.

### Obligations

- Audit Architecture chapters 03–08 for stale top-level `Graph`, `Circuit`, `Document`, and `Memory`
  framing.
- Avoid moving provider or host authority into the substrate; provider adapters, response schemas,
  and structured-output policy are Logos-owned (ADR 0040).
- Replace stringly duplicated contract names with catalog exports where possible.
- Update Wire documentation once `.wire` contract declaration semantics are decided and implemented.

## Related

- [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) —
  the substrate/downstream ownership boundary.
- [ADR 0017 — Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
  — the executor/contract/port layering in detail.
- [ADR 0018 — Canonical Haskell Module Tree](./0018-canonical-haskell-module-tree.md) — the
  substrate module-tree migration.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) — Wire's
  closed-authority composition model.
- [../Architecture/08-artifacts-and-provenance.md](../Architecture/08-artifacts-and-provenance.md) —
  contract-owned meaning and runtime envelopes.

## Tracking

- #50 — `.wire` contract declaration semantics.
