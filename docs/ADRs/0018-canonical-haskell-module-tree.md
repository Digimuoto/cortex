---
title: "ADR 0018 — Canonical Haskell Module Tree"
description:
  "Cortex organizes Haskell modules by canonical substrate layer — Algebra, Wire, Pulse, Capability
  — not implementation-era roots such as Agent, Task, Run, Provider, Json, or Document. The
  downstream Logos package is the separate reasoning-library home."
sidebar:
  label: "0018. Haskell tree"
  order: 18
status: proposed
date: 2026-04-28
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Consumers/Logos/reasoning-library.md
  - docs/ADRs/0016-cortex-roots-and-logos-pattern-extraction.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
  - "GitHub #62"
---

# ADR 0018 — Canonical Haskell Module Tree

## Status

Proposed — records the concrete Cortex Haskell module tree and substrate migration policy for the
final `src/Cortex` root refactor. ADR 0040 narrows this ADR after implementation: the current public
Cortex Haskell roots are substrate roots only, and concrete reasoning/provider/report surfaces live
in the downstream Logos package. The detailed Logos module tree and the cross-repo relocation of
those surfaces are owned in the Logos repository and governed by ADR 0040; this ADR keeps only the
substrate tree plus the boundary that separates it from Logos.

## Context

The implementation-era `src/Cortex` tree still exposes several roots that describe mechanisms at the
wrong architectural layer:

- `Cortex.Agent`, `Cortex.Task`, `Cortex.Run`, `Cortex.Research` — mostly model-mediated reasoning
  behavior, which belongs above the substrate in the downstream Logos package.
- `Cortex.Provider` — external authority, which belongs under `Cortex.Capability` or in Logos/host
  bindings.
- root `Cortex.Document` — mixes generic artifact substrate with report/research semantics.
- root `Cortex.Memory` and `Cortex.MemoryCompaction` — mix cognitive context construction with
  durable Pulse state.
- `Cortex.Json`, `Cortex.Text` — generic support utilities, not Cortex concepts.
- root `Cortex.Graph` — the law-bearing algebra; root `Cortex.Circuit` — Wire's compiled form.
- `Cortex.Event` and `Cortex.Events` — Pulse execution records.

ADR 0016 decides the canonical public root taxonomy: `Cortex.Algebra`, `Cortex.Wire`,
`Cortex.Pulse`, and `Cortex.Capability`, with the downstream Logos package owning the reasoning
library in its own repository. The remaining decision is how strict to make the Cortex Haskell tree
and how to migrate current consumers without preserving the old roots as first-class vocabulary.

## Decision

The canonical Cortex Haskell tree under `src/Cortex` is organized by substrate layer:

```text
Cortex
|-- Algebra        -- law-bearing graph/relation algebra
|-- Wire           -- source language, contracts, ports, compiled circuit form
|-- Pulse          -- durable execution runtime, run state, events, persistence
`-- Capability     -- executor registration and native pure-executor capability surfaces
```

Only these are canonical public Cortex roots. The downstream Logos reasoning library is public
through the separate `logos` package, not through a Cortex Cabal component. A root module such as
`Cortex.Wire` may be an umbrella module for its own component. Other root-level modules are either
temporary compatibility shims, test fixtures, or private implementation details that should move
under the nearest canonical root.

Compatibility shims may remain only when there is a concrete migration need. A shim must be shallow:
it re-exports the canonical module, contains no independent logic, and is documented in the
migration table or module header as temporary. New code must import the canonical path.

Generic support code that is not a Cortex concept belongs outside the public `Cortex` root. JSON,
text, HTTP, database, retry, observability, and durable-task support should live under `Platform.*`
when reusable, or under a canonical `Cortex.<Layer>.Internal.*` module when it is layer-specific.

## Canonical Module Ownership

### `Cortex.Algebra`

`Cortex.Algebra` owns pure graph and relation algebra:

- graph construction and validation
- relation operations
- Mokhov algebra laws
- rewrite laws and validation helpers that do not depend on Wire syntax or Pulse runtime state

Target examples:

- `Cortex.Algebra.Graph`
- `Cortex.Algebra.Graph.Mokhov`
- `Cortex.Algebra.Relation`

Root `Cortex.Graph` and `Cortex.Graph.*` are migration shims once the canonical modules exist.

### `Cortex.Wire`

`Cortex.Wire` owns the authoring and compiled-program layer:

- Wire syntax, parser, compiler, and reference grammar
- contracts, ports, payload kinds, and runtime envelopes
- executor references and compile-time executor projections
- compiled circuit form produced from Wire
- Wire rewrite/lowering rules that are language semantics rather than durable runtime behavior

The compiled circuit form moves under Wire because it is the executable shape of a Wire program, not
a separate architectural root.

The active Wire syntax implementation is canonical Wire syntax, not a versioned Haskell namespace.
Version labels may appear in reference grammar documents for spec history, but Haskell modules
should expose the accepted syntax through `Cortex.Wire.Syntax`, `Cortex.Wire.Parser`, and
`Cortex.Wire.Compile` rather than `Cortex.Wire.V1.*`.

Target examples:

- `Cortex.Wire.Syntax`
- `Cortex.Wire.Parser`
- `Cortex.Wire.Compile`
- `Cortex.Wire.Contract`
- `Cortex.Wire.Executor`
- `Cortex.Wire.Port`
- `Cortex.Wire.Value`
- `Cortex.Wire.Circuit.IR`
- `Cortex.Wire.Circuit.Lower`

Root `Cortex.Circuit` and `Cortex.Circuit.*` are migration shims once the canonical modules exist.

### `Cortex.Pulse`

`Cortex.Pulse` owns durable execution:

- run ids, attempts, checkpoints, replay, resume, scheduler, frontier, and persistence
- execution events and operator-visible runtime state
- durable graph-state ownership and materialization
- Pulse-specific memory state when it is persisted execution state

Target examples:

- `Cortex.Pulse.Run`
- `Cortex.Pulse.Event`
- `Cortex.Pulse.Executor.*`
- `Cortex.Pulse.Persistence`
- `Cortex.Pulse.Memory.*` for durable run-state queries only

`Cortex.Event`, `Cortex.Events`, and the durable parts of `Cortex.Run.Types` move or shim into
Pulse. Generic execution events are Pulse; model-mediated thought lifecycle events are a downstream
concern.

`Cortex.Pulse.Executor` is the durable execution engine, not the canonical home for Wire executor
identity or host executor registration. It runs already-bound `StageAction` values, persists state,
resumes runs, retries stages, and records execution events. It should not know that an action came
from `@native.deep_report`, `@pure`, or any future reasoning pattern except through generic stage
metadata needed for replay and operator visibility.

### `Cortex.Capability`

`Cortex.Capability` owns substrate authority surfaces:

- executor registration records
- native pure-executor configuration
- authority checks that are required before a bound action can enter Pulse

Target examples:

- `Cortex.Capability.Executor`
- `Cortex.Capability.Executor.Pure`

Model clients, provider adapters, tool-call records, and structured-output fallback policy are not
part of the Cortex public Haskell surface after ADR 0040. They live in Logos or in host bindings.
Capability does not own prompts, reasoning memory, archetype activations, or pattern-level
evaluation; those are downstream concerns that consume capabilities.

### `Cortex.Artifact`

`Cortex.Artifact` is not a current public Haskell root. Artifact and provenance remain Cortex
architecture concepts through Wire contracts, runtime envelopes, and Pulse provenance. The concrete
report/document IR and rendering surface moved to `Logos.Patterns.DeepReport.Artifact.*` in
ADR 0040.

A future substrate-shaped artifact API requires a separate ADR and a concrete reusable need. Until
then, do not add an empty `Cortex.Artifact` marker root.

## Downstream Logos package

`Logos` is the separate downstream reasoning library above the substrate: the canonical archetype
taxonomy and activation slots, one bounded model-mediated cognitive evaluation (a thought),
cognitive memory, and reusable reasoning patterns such as DeepReport, plus the prompt families,
memory presets, evaluation rules, and Wire templates those patterns interpret. Its Haskell module
tree (`Logos.*`) lives in the `Digimuoto/logos` repository, not in Cortex canon.

`Agent` is not a canonical Cortex word: Pulse evaluates graph nodes as bounded stage actions, and
durable personas or product agents remain downstream. `Task`, `Research`, and report-generation code
are likewise downstream reasoning surfaces. The relocation of these surfaces (and of provider
adapters and report/document IR) out of `src/Cortex` and into the Logos package is governed by ADR
0040 and detailed in the Logos repository.

## Executor Boundary

`Executor` is a boundary term used at several layers. It is not another canonical root beside the
Cortex substrate roots or the downstream Logos component.

The layers own different parts of executor meaning:

| Context                      | Owns                                                                                                                                                                                                                            | Does not own                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `Cortex.Wire.Executor`       | Source-level executor references such as `@native.deep_report`, lowered native evaluator ids such as `pure`, compile-time projections, port constraints, contract obligations, and inert purity/effect metadata needed by Wire. | Host authority, Haskell application codecs, provider keys, DB access, prompts, or Pulse scheduling.   |
| `Cortex.Capability.Executor` | Authority-bearing registration records: config decoders, native pure-executor configuration, application codecs, host interpreters, and runnable binding into substrate actions.                                                | Model provider policy, reasoning-pattern semantics, or durable scheduling.                            |
| `Cortex.Pulse.Executor`      | Durable execution of already-bound stage actions: scheduling, persistence, replay, resume, retry, cancellation, and execution events.                                                                                           | Wire executor registry, source-level executor ids, application semantics, or provider/tool admission. |
| Downstream (Logos)           | Reasoning-shaped executor profiles, model/provider adapters, prompts, tool-call records, pattern templates, report artifact IR, and reusable catalog values that consumers may opt into.                                        | Host authority, provider credentials, product tools, DB loading, or artifact destinations.            |

This makes `@native.deep_report` a Wire executor reference admitted by a host binding. The reusable
pattern pieces may live downstream, but the binding that grants runnable authority belongs to the
consumer or to a Capability-level registration surface. Pulse only sees the resulting bound
`StageAction` and its generic replay/runtime metadata.

CorePure follows the same split. Authors write pure output equations without `@`; the compiler
lowers them to a host-registered native evaluator id whose config is checked through Wire-level
syntax and contract/port rules, whose deterministic evaluator is admitted through the executor
registration surface, and whose resulting action is run by Pulse. A pure evaluator may be provided
upstream by Cortex, but it is not a special Pulse executor and it does not install new Pulse framing
codecs. It operates over Wire values and closed, deterministic functions rather than downstream
Haskell application types.

This ADR decides the namespace boundary: no top-level `Cortex.Executor` root, and no expansion of
`Cortex.Pulse.Executor` into the generic executor registry. A separate ADR is required before Cortex
introduces any of the following public semantics:

- a concrete `ExecutorSpec` or executor-registration API
- a revised `WireCompileEnv` shape for executor projections
- a pure-expression language or pure evaluator registry
- executor purity/effect/replay metadata with runtime consequences
- standard upstream executor packs such as structural primitives

ADR 0017 and ADR 0020 already set constraints for those future decisions: Wire gets compile-time
projections, host binding grants authority, Pulse persists closed `WireValue` framing, and pure
output equations lower to the native evaluator rather than introducing a third node executor kind.

## Migration Map

The migration proceeds by adding canonical modules first, then converting imports, then retiring old
exposed roots once no internal or known external consumer still requires them. This map covers the
substrate-internal moves; the relocation of reasoning/provider/report surfaces to the downstream
Logos package is governed by ADR 0040.

| Current surface                      | Canonical substrate target                                   | Policy                                                                            |
| ------------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| `Cortex.Graph`, `Cortex.Graph.*`     | `Cortex.Algebra.Graph.*`                                     | Move implementation under Algebra; keep shallow root shims during migration.      |
| `Cortex.Circuit`, `Cortex.Circuit.*` | `Cortex.Wire.Circuit.*`                                      | Move compiled-form modules under Wire; keep shallow root shims during migration.  |
| `Cortex.Event`, `Cortex.Events`      | `Cortex.Pulse.Event`                                         | Generic execution events are Pulse; thought lifecycle events relocate downstream. |
| `Cortex.Run.Types`                   | `Cortex.Pulse.Run` (durable run ids)                         | Durable run ids are Pulse; thought stage descriptors relocate downstream.         |
| `Cortex.Memory.*` (persistence)      | `Cortex.Pulse.*`, `Cortex.Capability.*`, or internal helpers | Classify per module; durable/persistence-shaped stays substrate.                  |
| `Cortex.Pulse.Memory.*`              | `Cortex.Pulse.Memory.*` (durable run-state queries)          | Durable execution state stays Pulse; cognitive context construction relocates.    |
| `Cortex.Json.*`                      | `Platform.Serde.Json.*` or layer-internal helpers            | Generic serde helpers are not Cortex roots.                                       |
| `Cortex.Text`                        | `Platform.Text` or layer-internal helpers                    | Generic text helpers are not Cortex roots.                                        |

The cognitive-context, reasoning, provider, and report/document surfaces in the old `Cortex.Agent`,
`Cortex.Task`, `Cortex.Research`, `Cortex.Run.Engine`, `Cortex.Provider`, `Cortex.Document`, and the
cognitive parts of `Cortex.Memory.*` relocate to the Logos package per ADR 0040; their cross-repo
targets are recorded there.

## Import Direction

The source tree enforces the vertical split:

- The downstream Logos package may import substrate modules.
- Substrate modules must not import Logos.
- `Cortex.Algebra` must not import Wire, Pulse, Capability, or Logos.
- `Cortex.Wire` may import Algebra, but not Pulse or Logos.
- `Cortex.Pulse` may import Algebra, Wire, and Capability where runtime execution requires those
  substrate surfaces, but not Logos.
- `Cortex.Capability` may import platform support and shared substrate value types when necessary,
  but it must not encode reasoning-pattern semantics.
- `Platform.*` must not import `Cortex.*`.

When a cycle appears, the type belongs in the lowest layer that can own the concept without
importing its consumers. Do not solve cycles by adding a new public root.

## Cabal Exposure Policy

`cortex.cabal` should expose canonical modules and temporary compatibility shims only. The main
`cortex` library exposes substrate modules. The downstream `logos` package exposes `Logos.*` modules
from its own repository. A compatibility shim should be removed from `exposed-modules` when Cortex,
Logos, and known consumers have migrated.

New public modules must be added under a canonical root. New internal helpers should prefer
`other-modules` or a `.Internal` subtree under the owning root.

## Migration Slices

The refactor should land in small buildable slices:

1. Add this ADR and update architecture/index links.
2. Add canonical namespace spines and shallow compatibility shims where missing.
3. Move graph algebra to `Cortex.Algebra.Graph.*`.
4. Move compiled circuit modules to `Cortex.Wire.Circuit.*`.
5. Move `Cortex.Event`/`Events` and durable `Run.Types` into `Cortex.Pulse.*`.
6. Classify `Cortex.Memory.*`: durable/persistence-shaped stays substrate; cognitive-context modules
   relocate to the Logos package.
7. Move generic JSON/text helpers to `Platform.*` or internal helpers.
8. Coordinate the relocation of reasoning/provider/report surfaces to the downstream Logos package
   (ADR 0040).
9. Remove obsolete exposed roots once compatibility windows close.

Each slice must keep the library buildable. A moved module and its tests should land together.
Generated or Cabal materialization changes must stay with the source change that requires them.

## Consequences

Positive consequences:

- The Haskell tree matches the architecture docs and ADR 0016.
- Reasoning-layer code becomes visibly separate from the runtime substrate.
- Provider authority, tool authority, artifact substrate, and reasoning patterns get distinct homes.
- New code has a clear import target and fewer ambiguous root names.

Costs and risks:

- Many imports and test module names will churn.
- Compatibility shims may temporarily make the tree look duplicated.
- Moving memory modules requires judgement because some functions are generic mechanics and others
  are reasoning policy.
- External consumers may need coordinated migration if they import old roots.

Mitigations:

- Keep shims shallow and temporary.
- Move one layer at a time.
- Add import-boundary checks once the canonical tree exists.
- Prefer deletion of unused compatibility roots over preserving them for hypothetical consumers.

## Alternatives Considered

### Keep current roots and document them as staging

Rejected. The current roots encode outdated concepts and continue to invite new code into the wrong
layer.

### Move everything in one large rename commit

Rejected. A single tree-wide rename would be difficult to review and would make it harder to
distinguish semantic boundary decisions from mechanical import updates.

### Preserve all old roots indefinitely as public compatibility modules

Rejected. Indefinite shims make the old vocabulary permanent. Compatibility must be justified by
concrete consumers and removed once migration is complete.

### Put all reasoning support under Capability

Rejected. Capability means external authority. Prompts, thought frames, cognitive memory, archetype
activations, and reasoning patterns consume authority but do not grant it.

### Keep Document as a canonical root

Rejected. `Document` currently mixes generic artifact substrate with report and research semantics.
`Artifact` is the substrate concept; report/research shape is downstream pattern semantics.

## Open Questions

- Which old root modules still have concrete external consumers that require temporary exposed
  shims?
- Should any provider-neutral model contract ever become substrate API, or should all model/provider
  surfaces stay in Logos and host bindings?
- Which `Cortex.Memory.*` modules are purely cognitive context construction, and which are generic
  enough to remain substrate/internal support?
- Does a future `Cortex.Artifact` root need a generic contract catalog for artifact references, or
  should artifact contracts remain in Wire until schemas mature?

## Related

- [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md)
- [ADR 0016 — Cortex Canonical Root Taxonomy](./0016-cortex-roots-and-logos-pattern-extraction.md)
- [ADR 0017 — Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 — Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0020 — Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0040 — Logos-Owned Reasoning Surfaces](./0040-logos-owned-reasoning-surfaces.md)
- [Logos Reasoning Library](../Consumers/Logos/reasoning-library.md)
- GitHub #62
