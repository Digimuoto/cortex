---
title: "ADR 0020 — Canonical Haskell Module Tree"
description:
  "Cortex's Haskell source tree is organized by canonical substrate and Nous layers, not
  implementation-era roots such as Agent, Task, Run, Provider, Json, or Document."
sidebar:
  label: "0020. Haskell tree"
  order: 20
status: proposed
date: 2026-04-28
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Architecture/09-nous-reasoning-library.md
  - docs/ADRs/0016-canonical-cortex-epistemological-archetypes.md
  - docs/ADRs/0017-cortex-roots-and-nous-pattern-extraction.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-wire-pure-nodes.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - "GitHub #62"
---

# ADR 0020 — Canonical Haskell Module Tree

## Status

Proposed - records the concrete Haskell module tree and migration policy for the final `src/Cortex`
root refactor. ADR 0017 defines the conceptual root taxonomy; this ADR decides how that taxonomy is
enforced in source modules, Cabal exposure, compatibility shims, and import direction.

## Context

The current `src/Cortex` tree still exposes several implementation-era roots:

- `Cortex.Agent`
- `Cortex.Provider`
- `Cortex.Run`
- `Cortex.Task`
- `Cortex.Research`
- `Cortex.Json`
- root `Cortex.Document`
- root `Cortex.Memory`
- `Cortex.MemoryCompaction`
- root `Cortex.Graph`
- root `Cortex.Circuit`
- `Cortex.Event` and `Cortex.Events`

Some of these names describe mechanisms at the wrong architectural layer. `Agent`, `Task`, `Run`,
and `Research` mostly describe model-mediated reasoning behavior, which belongs above the substrate
in `Cortex.Nous`. `Provider` is external authority, which belongs under `Cortex.Capability`.
`Document` mixes generic artifact substrate with report/research semantics. `Memory` mixes cognitive
context construction with durable Pulse state. `Json` and `Text` are generic support utilities
rather than Cortex concepts. `Graph` is the law-bearing algebra, and `Circuit` is Wire's compiled
form.

ADR 0017 already decides the canonical public root taxonomy:

```text
Cortex
|-- Algebra
|-- Wire
|-- Pulse
|-- Capability
|-- Artifact
`-- Nous
```

The remaining decision is how strict to make the Haskell tree and how to migrate current consumers
without preserving the old roots as first-class vocabulary.

## Decision

The canonical Haskell tree under `src/Cortex` is organized by layer:

```text
Cortex
|-- Algebra        -- law-bearing graph/relation algebra
|-- Wire           -- source language, contracts, ports, compiled circuit form
|-- Pulse          -- durable execution runtime, run state, events, persistence
|-- Capability     -- external authority: model clients, tools, providers
|-- Artifact       -- generic durable outputs, metadata, provenance, host boundary
`-- Nous           -- structured reasoning library above the substrate
```

Only these roots should be treated as canonical public Cortex roots. A root module such as
`Cortex.Wire` or `Cortex.Nous` may be an umbrella module for its layer. Other root-level modules are
either temporary compatibility shims, test fixtures, or private implementation details that should
move under the nearest canonical root.

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
Pulse. Thought lifecycle events do not belong in Pulse unless they are generic execution events;
model-mediated thought events belong in Nous.

`Cortex.Pulse.Executor` is the durable execution engine, not the canonical home for Wire executor
identity or host executor registration. It runs already-bound `StageAction` values, persists state,
resumes runs, retries stages, and records execution events. It should not know that an action came
from `@native.deep_report`, `@pure`, or any future reasoning pattern except through generic stage
metadata needed for replay and operator visibility.

### `Cortex.Capability`

`Cortex.Capability` owns external authority surfaces:

- provider-neutral model request/response types
- model clients and provider adapters
- tool definitions, tool-call records, host execution interfaces, and authority checks
- structured-output mechanics that are provider/tool capability rather than reasoning-pattern
  semantics

Target examples:

- `Cortex.Capability.Model.*`
- `Cortex.Capability.Tool.*`
- `Cortex.Capability.Executor`
- `Cortex.Capability.Provider.OpenRouter.*`
- `Cortex.Capability.StructuredOutput`

Root `Cortex.Provider.*` is not canonical. Existing `Cortex.Capability.Provider.OpenRouter.*`
modules are the canonical target; root provider modules should either move there or become shallow
shims while consumers migrate.

Capability does not own prompts, reasoning memory, archetype activations, or pattern-level
evaluation. Those are Nous concerns that consume capabilities.

### `Cortex.Artifact`

`Cortex.Artifact` owns generic durable outputs:

- artifact IR
- artifact metadata
- provenance and source references
- host/rendering boundary for generic artifacts
- artifact references usable by Wire, Pulse, and Nous without report-specific semantics

Target examples:

- `Cortex.Artifact.IR`
- `Cortex.Artifact.Metadata`
- `Cortex.Artifact.Provenance`
- `Cortex.Artifact.Host`

Root `Cortex.Document.IR`, `Cortex.Document.Metadata`, and `Cortex.Document.Host` move or shim here.
`Cortex.Document.Report`, `Cortex.Document.Section`, and research-report semantics do not belong in
Artifact unless they are reduced to generic artifact structure; LLM-shaped report semantics belong
in `Cortex.Nous.Patterns.DeepReport.*`.

### `Cortex.Nous`

`Cortex.Nous` owns the structured reasoning library above the substrate:

- canonical archetype taxonomy and activation slots
- one bounded model-mediated cognitive evaluation, named a thought
- cognitive memory: retrieval, ranking, packing, compaction, source selection, and topological
  context construction
- reusable reasoning patterns such as DeepReport
- prompt families, memory presets, evaluation rules, contract-entry conventions, and Wire templates
  that are interpreted by substrate mechanisms

Target examples:

- `Cortex.Nous.Archetypes.*`
- `Cortex.Nous.Thought.Frame`
- `Cortex.Nous.Thought.Policy`
- `Cortex.Nous.Thought.Host`
- `Cortex.Nous.Thought.ToolHost`
- `Cortex.Nous.Thought.ToolLoop`
- `Cortex.Nous.Thought.Runtime`
- `Cortex.Nous.Thought.StructuredOutput`
- `Cortex.Nous.Thought.Event`
- `Cortex.Nous.Memory.*`
- `Cortex.Nous.Patterns.DeepReport.*`
- `Cortex.Nous.Patterns.DeepReport.Executors` for inert profiles or adapters, if a later
  executor-definition ADR introduces them
- `Cortex.Nous.Patterns.PlanReview`

`Agent` is not a canonical Cortex word. A graph node performs one bounded model-mediated thought;
durable personas and product agents remain downstream. `Task` is likewise not a root. It either
becomes thought runtime machinery or a named Nous pattern. `Research` and report-generation code
become DeepReport or other Nous patterns when they are LLM-shaped reasoning semantics.

## Executor Boundary

`Executor` is a boundary term used at several layers. It is not a seventh canonical root beside
`Algebra`, `Wire`, `Pulse`, `Capability`, `Artifact`, and `Nous`.

The layers own different parts of executor meaning:

| Context                      | Owns                                                                                                                                                                                                         | Does not own                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `Cortex.Wire.Executor`       | Source-level executor references such as `@native.deep_report` and `@pure`, executor ids, compile-time projections, port constraints, contract obligations, and inert purity/effect metadata needed by Wire. | Host authority, Haskell application codecs, provider keys, DB access, prompts, or Pulse scheduling.   |
| `Cortex.Capability.Executor` | Authority-bearing registration records: config decoders, admitted tools, model/provider requirements, application codecs, host interpreters, and runnable binding into substrate actions.                    | Reasoning-pattern semantics or durable scheduling.                                                    |
| `Cortex.Pulse.Executor`      | Durable execution of already-bound stage actions: scheduling, persistence, replay, resume, retry, cancellation, and execution events.                                                                        | Wire executor registry, source-level executor ids, application semantics, or provider/tool admission. |
| `Cortex.Nous.*`              | Reasoning-shaped executor profiles, adapters, prompts, pattern templates, and reusable catalog values that consumers may opt into.                                                                           | Host authority, provider credentials, product tools, DB loading, or artifact destinations.            |

This makes `@native.deep_report` a Wire executor reference admitted by a host binding. The reusable
DeepReport pieces may live under `Cortex.Nous.Patterns.DeepReport.*`, but the binding that grants
runnable authority belongs to the consumer or to a Capability-level registration surface. Pulse only
sees the resulting bound `StageAction` and its generic replay/runtime metadata.

Pure executors follow the same split. `@pure` is a host-registered executor whose expression/config
is checked through Wire-level syntax and contract/port rules, whose deterministic evaluator is
admitted through the executor registration surface, and whose resulting action is run by Pulse. A
pure evaluator may be provided upstream by Cortex, but it is not a special Pulse executor and it
does not install new Pulse framing codecs. It operates over Wire values and closed, deterministic
functions rather than downstream Haskell application types.

This ADR decides the namespace boundary: no top-level `Cortex.Executor` root, and no expansion of
`Cortex.Pulse.Executor` into the generic executor registry. A separate ADR is required before Cortex
introduces any of the following public semantics:

- a concrete `ExecutorSpec` or executor-registration API
- a revised `WireCompileEnv` shape for executor projections
- a pure-expression language or pure evaluator registry
- executor purity/effect/replay metadata with runtime consequences
- standard upstream executor packs such as DeepReport executor profiles or structural primitives

ADR 0018 and ADR 0019 already set constraints for those future decisions: Wire gets compile-time
projections, host binding grants authority, Pulse persists closed `WireValue` framing, and pure
nodes are deterministic external-call executors rather than a third node executor kind.

## Migration Map

The migration proceeds by adding canonical modules first, then converting imports, then retiring old
exposed roots once no internal or known external consumer still requires them.

| Current surface                          | Canonical target                                                                     | Policy                                                                             |
| ---------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| `Cortex.Graph`, `Cortex.Graph.*`         | `Cortex.Algebra.Graph.*`                                                             | Move implementation under Algebra; keep shallow root shims during migration.       |
| `Cortex.Circuit`, `Cortex.Circuit.*`     | `Cortex.Wire.Circuit.*`                                                              | Move compiled-form modules under Wire; keep shallow root shims during migration.   |
| `Cortex.Event`, `Cortex.Events`          | `Cortex.Pulse.Event` or `Cortex.Nous.Thought.Event`                                  | Split execution events from thought lifecycle events.                              |
| `Cortex.Provider.OpenRouter.*`           | `Cortex.Capability.Provider.OpenRouter.*`                                            | Capability path is canonical; root provider path becomes a shim or is removed.     |
| `Cortex.Agent.Config`                    | `Cortex.Nous.Thought.Frame`                                                          | Model/budget/prompt appendix are thought-frame concerns.                           |
| `Cortex.Agent.Policy`                    | `Cortex.Nous.Thought.Policy`                                                         | Tool scope and approval policy belong to thought orchestration.                    |
| `Cortex.Agent.Definition`                | `Cortex.Nous.Thought.Frame` or removed                                               | Avoid durable persona semantics in Cortex.                                         |
| `Cortex.Task.Host`                       | `Cortex.Nous.Thought.Host`                                                           | Host for one model-mediated thought.                                               |
| `Cortex.Task.ToolHost`                   | `Cortex.Nous.Thought.ToolHost`                                                       | Host-side tool execution for a thought.                                            |
| `Cortex.Task.ToolLoop`                   | `Cortex.Nous.Thought.ToolLoop`                                                       | Model/tool loop is thought orchestration over capabilities.                        |
| `Cortex.Task.Runtime`                    | `Cortex.Nous.Thought.Runtime`                                                        | Thin thought runner and lifecycle helpers.                                         |
| `Cortex.Task.StructuredOutput`           | `Cortex.Nous.Thought.StructuredOutput` or `Cortex.Capability.StructuredOutput`       | Decode mechanics belong to Capability; fallback/prompt policy belongs to Nous.     |
| `Cortex.Task.Plan`                       | `Cortex.Nous.Patterns.PlanReview`                                                    | Planner/reviewer shape is a reusable reasoning pattern.                            |
| `Cortex.Task.Gather`                     | `Cortex.Nous.Patterns.DeepReport.Gather`                                             | Evidence gathering is DeepReport pattern semantics.                                |
| `Cortex.Task.Report`                     | `Cortex.Nous.Patterns.DeepReport.LegacyReportTask` initially                         | Decompose after contracts and ports stabilize.                                     |
| `Cortex.Research.Section`                | `Cortex.Nous.Patterns.DeepReport.Section`                                            | Section schema is report-pattern semantics.                                        |
| `Cortex.Research.Runtime`                | `Cortex.Nous.Patterns.DeepReport.Section.Runtime`                                    | Section-output parsing belongs with the pattern.                                   |
| `Cortex.Run.Types`                       | `Cortex.Pulse.Run` and `Cortex.Nous.Thought.Stage`                                   | Durable run ids are Pulse; thought stage descriptors are Nous.                     |
| `Cortex.Run.Engine`                      | `Cortex.Nous.Thought.Event` or `Cortex.Nous.Thought.Runtime`                         | Current event emission is thought lifecycle machinery.                             |
| `Cortex.Document.IR`, `Metadata`, `Host` | `Cortex.Artifact.*`                                                                  | Generic artifact substrate.                                                        |
| `Cortex.Document.Report`, `Section`      | `Cortex.Nous.Patterns.DeepReport.*`                                                  | Report/research semantics are Nous pattern semantics.                              |
| `Cortex.Memory.*`                        | `Cortex.Nous.Memory.*`, `Cortex.Pulse.*`, `Cortex.Capability.*`, or internal helpers | Classify per module; cognitive context moves to Nous, persistence stays substrate. |
| `Cortex.MemoryCompaction`                | `Cortex.Nous.Memory.Compact`                                                         | Keep root shim only if concrete consumers require it.                              |
| `Cortex.Pulse.Memory.*`                  | `Cortex.Pulse.Memory.*` or `Cortex.Nous.Memory.Topological.*`                        | Durable execution state stays Pulse; context construction moves to Nous.           |
| `Cortex.Json.*`                          | `Platform.Serde.Json.*` or layer-internal helpers                                    | Generic serde helpers are not Cortex roots.                                        |
| `Cortex.Text`                            | `Platform.Text` or layer-internal helpers                                            | Generic text helpers are not Cortex roots.                                         |
| `Cortex.Nous.<Archetype>`                | `Cortex.Nous.Archetypes.<Archetype>`                                                 | Archetypes live under the `Archetypes` catalog.                                    |
| `Cortex.Nous.<Archetype>.Capability`     | `Cortex.Nous.Archetypes.<Archetype>.Activation`                                      | Avoid collision with external-authority `Capability`.                              |
| `Cortex.Logoi.*`                         | `Cortex.Nous.*`                                                                      | `Logoi` is superseded staging vocabulary and should not remain public.             |

## Import Direction

The source tree enforces the vertical split:

- `Cortex.Nous` may import substrate modules.
- Substrate modules must not import `Cortex.Nous`.
- `Cortex.Algebra` must not import Wire, Pulse, Capability, Artifact, or Nous.
- `Cortex.Wire` may import Algebra, but not Pulse or Nous.
- `Cortex.Pulse` may import Algebra, Wire, Capability, and Artifact where runtime execution requires
  those substrate surfaces, but not Nous.
- `Cortex.Capability` may import platform support and shared substrate value types when necessary,
  but it must not encode reasoning-pattern semantics.
- `Cortex.Artifact` may define generic output/provenance types usable by Wire, Pulse, and Nous, but
  it must not depend on Nous patterns.
- `Platform.*` must not import `Cortex.*`.

When a cycle appears, the type belongs in the lowest layer that can own the concept without
importing its consumers. Do not solve cycles by adding a new public root.

## Cabal Exposure Policy

`cortex.cabal` should expose canonical modules and temporary compatibility shims only. A
compatibility shim should be removed from `exposed-modules` when Cortex and known consumers have
migrated.

New public modules must be added under a canonical root. New internal helpers should prefer
`other-modules` or a `.Internal` subtree under the owning root.

## Migration Slices

The refactor should land in small buildable slices:

1. Add this ADR and update architecture/index links.
2. Add canonical namespace spines and shallow compatibility shims where missing.
3. Move provider adapters to `Cortex.Capability.Provider.*` and retire root provider imports.
4. Move graph algebra to `Cortex.Algebra.Graph.*`.
5. Move compiled circuit modules to `Cortex.Wire.Circuit.*`.
6. Add `Cortex.Artifact.*` and move generic document substrate there.
7. Move thought runtime surfaces from `Agent`, `Task`, and `Run` into `Cortex.Nous.Thought.*`.
8. Move report/research surfaces into `Cortex.Nous.Patterns.DeepReport.*`.
9. Classify memory modules and move cognitive-context modules to `Cortex.Nous.Memory.*`.
10. Move generic JSON/text helpers to `Platform.*` or internal helpers.
11. Remove obsolete exposed roots once compatibility windows close.

Each slice must keep the library buildable. A moved module and its tests should land together.
Generated or Cabal materialization changes must stay with the source change that requires them.

## Consequences

Positive consequences:

- The Haskell tree matches the architecture docs and ADR 0017.
- LLM-shaped and reasoning-layer code becomes visibly separate from the runtime substrate.
- Provider authority, tool authority, artifact substrate, and reasoning patterns get distinct homes.
- New code has a clear import target and fewer ambiguous root names.

Costs and risks:

- Many imports and test module names will churn.
- Compatibility shims may temporarily make the tree look duplicated.
- Moving memory and structured-output modules requires judgement because some functions are generic
  mechanics and others are reasoning policy.
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
`Artifact` is the substrate concept; report/research shape is Nous pattern semantics.

## Open Questions

- Which old root modules still have concrete external consumers that require temporary exposed
  shims?
- Should `Cortex.Task.StructuredOutput` split between `Cortex.Capability.StructuredOutput` and
  `Cortex.Nous.Thought.StructuredOutput`, or should one canonical module own the whole current
  surface?
- Which `Cortex.Memory.*` modules are purely cognitive context construction, and which are generic
  enough to remain substrate/internal support?
- Does `Cortex.Artifact` need a generic contract catalog for artifact references, or should artifact
  contracts remain in Wire until schemas mature?

## Related

- [ADR 0016 — Canonical Cortex Nous Archetypes](./0016-canonical-cortex-epistemological-archetypes.md)
- [ADR 0017 — Cortex Roots and Nous Pattern Extraction](./0017-cortex-roots-and-nous-pattern-extraction.md)
- [ADR 0018 — Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 — Wire Pure Nodes](./0019-wire-pure-nodes.md)
- [Chapter 09 — Nous Reasoning Library](../Architecture/09-nous-reasoning-library.md)
- GitHub #62
