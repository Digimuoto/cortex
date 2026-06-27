---
title: "ADR 0019 — Executor Registration and Binding"
description:
  "Wire compiles against executor projections, Capability owns host authority, and Pulse executes
  already-bound stage actions."
sidebar:
  label: "0019. Executor binding"
  order: 19
status: proposed
date: 2026-04-28
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Consumers/Logos/reasoning-library.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0018-canonical-haskell-module-tree.md
  - "GitHub #65"
---

# ADR 0019 — Executor Registration and Binding

## Status

Proposed - defines the concrete executor-registration boundary after the canonical Haskell module
tree landed. ADR 0017 split contracts, ports, projections, codecs, and host authority; this ADR
assigns those executor pieces to Haskell modules.

## Context

Wire source names executors with `@qualified.name { config }`, but source files do not grant
authority. Host code decides which executor ids exist, which config is valid, which tools and model
policies are admitted, and how Haskell values are encoded at Wire boundaries.

Before this decision, `WireCompileEnv` mixed temporary executor-port maps with the contract catalog,
and `Cortex.Wire.Executor` / `Cortex.Capability.Executor` were placeholders. That made it unclear
where the native pure evaluator projection, DeepReport profiles, provider policy, and Pulse stage
actions should be introduced.

## Decision

Executor meaning is split into three substrate layers. A fourth input — inert profiles published by
downstream consumers — feeds them but is not itself a substrate layer; it is admitted through
Capability like any other registration.

### Wire projection

`Cortex.Wire.Executor` owns source-level executor references and compile-time projections. A
projection is inert data:

- executor id
- port shape
- contract vocabulary
- purity/effect metadata
- config-shape metadata

`WireCompileEnv` carries an executor projection registry plus contract registry data. In permissive
mode, existing unregistered Wire programs continue to compile. In strict projection mode, every task
executor mentioned by Wire must exist in the projection registry, and the source-declared ports must
match the projected ports.

Wire projections do not contain runnable Haskell actions, provider credentials, tool handles,
database access, or product permissions.

### Capability authority

`Cortex.Capability.Executor` owns authority-bearing registration specs. These specs reference Wire
projections and add host-side facts:

- config decoder or schema
- required tools
- required providers or model policy
- host permission requirements
- application codec boundary
- whether the record is profile-only or host-bound

Capability specs are still inert. A host may turn a spec into runnable code, but the public spec
does not embed a Pulse `StageAction`.

### Pulse execution

`Cortex.Pulse.Executor` remains the durable runner for already-bound stage actions. Pulse schedules,
persists, retries, resumes, records events, and materializes rewrites. It does not own executor
registration, provider policy, product codecs, or application authority.

### Downstream profiles

Downstream libraries (such as `Logos.*`) may publish reusable reasoning profiles and adapters — for
example DeepReport executor profiles — but those values do not grant host authority. A downstream
host must register and bind them through Capability before they can run.

## Contract declarations

`contract X;` assertions in a Wire file populate the local compile contract namespace. With an
explicit `WireContractRegistry`, a contract is known when it appears in the registry, in the current
file's declarations, or in the vocabulary of a registered executor projection. Redeclaration is
idempotent.

When no contract registry is supplied, Wire remains permissive for compatibility with exploratory
programs and tests.

## Deferred Work

This ADR does not implement structural utility executors, Node algebra, gas, content-addressed
execution, or a new Pulse result channel. ADR 0020 defines the Wire-authored CorePure surface:
authors write pure output equations, and the compiler lowers them to the native pure evaluator
registered through the same Capability-to-Wire projection path.

## Consequences

Positive consequences:

- Wire's compile-time API no longer implies host authority.
- Consumers can export projection registries for static checking without exposing runnable actions.
- The `contract X;` docs and compiler behavior now agree.
- Capability has a concrete public home for executor registration records.

Costs and risks:

- Downstream consumers that built `WireCompileEnv` with the old temporary maps must migrate to
  executor projection registries.
- Strict projection mode currently requires exact port equality. More flexible profile compatibility
  can be added after concrete profile catalogs stabilize.

## Related

- [ADR 0017 — Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0020 — Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0018 — Canonical Haskell Module Tree](./0018-canonical-haskell-module-tree.md)
- GitHub #65
