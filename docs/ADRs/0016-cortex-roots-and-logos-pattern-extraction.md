---
title: "ADR 0016 — Cortex Roots and Logos Pattern Extraction"
description:
  "Cortex uses a small root taxonomy while Logos extracts reusable LLM-shaped reasoning programs
  with shared port contracts."
sidebar:
  label: "0016. Cortex roots"
  order: 16
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Logos/reasoning-library.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0015-canonical-logos-archetypes.md
  - "GitHub #14"
  - "GitHub #31"
  - "GitHub #32"
  - "GitHub #50"
---

# ADR 0016 — Cortex Roots and Logos Pattern Extraction

## Status

Proposed - records the canonical root namespace target, the intended extraction path for the current
DeepReport system, and the contract/executor model needed before that system can become a principled
`Logos.Patterns.DeepReport` library. These decisions are recorded together because Slice 0 root
alignment is the namespace prerequisite for extracting DeepReport without preserving
implementation-era roots. Implementation remains pending.

## Context

As of 2026-04-27, the current DeepReport implementation is split across Cortex and Portman:

- Cortex owns generic Wire contract registry mechanics, port metadata, compile-time port
  compatibility, runtime `WireValue` envelopes, and payload kind checks.
- Portman owns `portmanWorkflowWireContractRegistry`, `portmanWorkflowWireCompileEnv`, bundled
  `.wire` workflows, DB-backed workflow loading, DeepReport execution, product tools, user/workspace
  policy, portfolio context, and artifact emission.
- Some names in Portman's DeepReport catalog are generic reasoning contracts: `PlannerOutput`,
  `EvidenceBundle`, `AnalysisFragment`, `ReportFragment`, `ReviewBundle`, `ReviewConcerns`, and
  `WorkflowAudit`.
- Other pieces are downstream bindings: finance/portfolio tools, workspace destinations, workflow
  selection heuristics, DB persistence, user settings, model-provider configuration, and product
  artifact semantics.

This creates three problems:

- Generic reasoning vocabulary lives in a downstream product repository.
- Executor authority, port contract meaning, and pattern shape are not named as separate concepts.
- Shared contracts are copied as strings across executors, ports, workflows, and runtime config
  rather than being composed from a catalog.

The current Cortex root namespace also carries implementation-era roots: `Cortex.Graph`,
`Cortex.Circuit`, `Cortex.Event`, `Cortex.Document`, `Cortex.Memory`, `Cortex.Agent`, `Cortex.Task`,
`Cortex.Research`, `Cortex.Run`, and `Cortex.Provider`. Several of those roots describe the wrong
abstraction level. `Graph` is the law-bearing algebra, `Circuit` is the compiled form of Wire,
events are Pulse execution records, document-like outputs are artifacts, and the old memory root
mixes Pulse settled-state queries with Logos context construction. Agent/task/research/run modules
are mostly model-mediated reasoning machinery.

ADR 0015 establishes `Logos.Archetypes` and reserves `Logos.Thought`, `Logos.Memory`, and
`Logos.Patterns`. This ADR defines the root taxonomy target, the pending DeepReport extraction, and
the contract/executor model needed to make that extraction disciplined.

## Decision

The canonical public root taxonomy is:

```text
Cortex
|-- Algebra
|-- Wire
|-- Pulse
|-- Capability
`-- Artifact

Logos
|-- Archetypes
|-- Thought
|-- Memory
`-- Patterns
```

Root responsibilities:

| Root                | Owns                                                                                                | Does not own                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Cortex.Algebra`    | Graph/relation algebra, Mokhov laws, validation, rewrite laws.                                      | Durable execution, language parsing, model cognition.                            |
| `Cortex.Wire`       | Wire source language, contracts, compiled circuit form, runtime envelopes.                          | Durable scheduling, host tool authority, reasoning patterns.                     |
| `Cortex.Pulse`      | Durable execution, frontier, checkpoints, persistence, signals, run events.                         | Cognitive memory shaping, model/tool loops, artifact semantics.                  |
| `Cortex.Capability` | External authority surfaces: model clients, tool definitions, tool-call records, provider adapters. | Archetype activations, prompt discipline, reasoning memory, patterns.            |
| `Cortex.Artifact`   | Generic durable outputs, artifact IR, metadata, provenance, rendering/host boundary.                | LLM report/research semantics.                                                   |
| `Logos`             | Model-mediated cognition: archetypes, thoughts, cognitive memory, reasoning patterns.               | Provider mechanics, Wire compiler, Pulse durability, generic artifact substrate. |

`Logos.Patterns` is the planned home for reusable LLM-shaped reasoning programs. A pattern may ship
contract catalogs, port catalogs, prompt families, memory presets, evaluation rules, and Wire
templates. A pattern does not introduce a new runtime registry and does not grant host, tool,
provider, or artifact authority by itself.

The first planned extraction target is `Logos.Patterns.DeepReport`.

## Settled decisions

### Thought

`Thought` replaces `Agent` as the canonical Logos execution word. An agent sounds like a durable
persona. Cortex's wavefront model is a runtime scheduling model: Pulse evaluates graph nodes as
bounded stage actions. Logos may interpret one such stage as a model-mediated thought with a frame,
policy, prompt/context, memory surface, tool surface, and output contract.

`Logos.Thought` should own the generic model-mediated task host, tool host, tool loop,
structured-output decoder, thought frame/policy, and thought event surface. Durable identity and
product persona remain downstream concepts.

### Memory

Memory is Logos when it shapes cognitive context. `Logos.Memory` should own retrieval, ranking,
packing, compaction, source selection, topological context, and memory tools. Pulse may store run
events, checkpoints, and settled node outputs, but an API that turns that state into model context
belongs to Logos memory.

This means `Cortex.Memory.*`, `Cortex.MemoryCompaction`, and the cognitive parts of
`Cortex.Pulse.Memory.*` are migration candidates for `Logos.Memory.*`. It is not a blanket rename:
persistence-shaped, schema-shaped, or host-bound submodules must be resolved individually during
Slice 0 and may stay under Pulse, move under Capability, or become internal helpers.

### Capability

`Cortex.Capability` means external authority available to execution. It covers provider-neutral
model calls, provider adapters, tool definitions, tool-call records, and generic host-side tool
execution interfaces. It does not cover Logos archetype activations, prompt discipline, memory
policy, or reasoning patterns.

The boundary with `Logos.Thought.ToolHost` is orchestration. Capability defines neutral tool
surfaces, authority checks, request/response records, and host execution interfaces. Logos Thought
binds those surfaces into one model-mediated thought's tool loop, prompt policy, and lifecycle
events.

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
- model/provider selection policy when model-mediated

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

Contract-level evaluation answers: "is this payload well-formed for the named contract?"
Archetype-activation evaluation answers: "did this thought produce the kind of reasoning its active
archetype promised?" Pattern-level evaluation answers: "did the composed reasoning program satisfy
its end-to-end obligations?"

Contracts are not archetypes, executors, tools, prompts, or product permissions. They are shared
data obligations that executors and patterns reference.

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
not the desired closed-authority semantics for Logos patterns. The behavior commitment is settled:
Logos patterns should compile against explicit registries. The pending decision is only the API
shape for expressing strict vs permissive mode without relying on `Maybe WireContractRegistry`.

### Sharing contracts between executors

Contracts are shared by composing catalog values, not by making one executor the owner of another
executor's vocabulary.

The intended sharing model is many-to-many:

- contract catalogs define named obligations
- executors declare which obligations they can accept and emit
- patterns declare which obligations their topology requires
- consumers compose the required catalogs into a `WireCompileEnv`
- downstream bindings may add domain-specific contracts without changing the generic pattern catalog

For DeepReport, a planner, gatherer, analyst, section compiler, reviewer, rewriter, auditor, and
artifact publisher can all reference the same shared contract IDs while retaining separate executor
behavior and authority.

## DeepReport extraction target

`Logos.Patterns.DeepReport` is the planned module target for extracting the generic reasoning shape
now scattered through Portman. The target structure is:

```text
Logos.Patterns.DeepReport
|-- Contracts
|-- Ports
|-- Templates
|-- Prompts          -- later
|-- Memory           -- later
|-- Evaluation       -- later
`-- PatternContract  -- later
```

`PatternContract` is the end-to-end contract for the reusable pattern. It is distinct from an
archetype activation's runtime contract, which constrains one thought operating under one archetype.
Its concrete fields and schema are deferred until DeepReport slices 5-7 produce the first real
template, artifact-ref, and evaluation candidates.

The initial generic contract catalog should cover contracts whose meaning is not finance-specific.
This list is derived from Portman as of 2026-04-27 and should be revised during slices 1-4 as
schemas and port ownership are formalized:

- `PlannerOutput`
- `PlannerRewriteNeeded`
- `EvidenceBundle`
- `EvidenceReady`
- `EvidenceRepairNeeded`
- `ConditionPassthrough`
- `AnalysisFragment`
- `ReportFragment`
- `ReviewBundle`
- `ReviewConcerns`
- `WorkflowAudit`
- `AwaitSignal`

`ReportArtifactRef` is likely a substrate or artifact contract rather than a DeepReport-only
contract, but its final home remains pending. DeepReport may depend on or re-export it until a
generic artifact contract catalog exists.

Contract evolution policy for the extraction is conservative: existing contract ids are
additive-only. Breaking payload changes require a new contract id or an explicit versioned id such
as `EvidenceBundleV2`; compatibility adapters may live in the pattern or downstream binding. Future
registry metadata may record schema versions and migrations, but migration metadata does not make a
breaking change safe under the same id.

The initial generic port catalog should cover reusable reasoning slots:

- planner
- planner expansion gate and planner adjust
- gatherer
- required-evidence gate and repair
- analyst-like analysis
- report merge
- review and rewrite
- section compiler
- publish gate
- workflow audit

Portman should keep ownership of:

- finance, portfolio, watchlist, and IBKR tools
- product workflow selection
- user, strategy, portfolio, and workspace context resolution
- DB-backed workflow template loading and bundled-template sync
- artifact destinations such as `workspace.reports.latest`
- product-specific `.wire` workflow catalog
- OpenRouter API-key loading and product model defaults
- product report UX and permission policy

## Migration slices

The extraction should land in small slices. Slice 0 is namespace alignment: add new canonical
modules and compatibility shims before moving implementation.

### Slice 0: root namespace alignment

Target surfaces in this table are canonical planned homes. Some do not exist yet and should land
with compatibility shims before implementation is moved.

| Current surface                                                                                 | Target surface                                                                 | Notes                                                                                                                                         |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `Cortex.Graph.*`                                                                                | `Cortex.Algebra.Graph.*`                                                       | Root name should describe the law-bearing algebra.                                                                                            |
| `Cortex.Circuit.*`                                                                              | `Cortex.Wire.Circuit.*`                                                        | Circuit is Wire's compiled executable form. Keep shims while direct Circuit consumers migrate.                                                |
| `Logos.<Archetype>`                                                                             | `Logos.Archetypes.<Archetype>`                                                 | Archetypes live under the `Archetypes` catalog.                                                                                               |
| `Logos.<Archetype>.Capability`                                                                  | `Logos.Archetypes.<Archetype>.Activation`                                      | Avoid collision with root `Cortex.Capability`, which means external authority.                                                                |
| `Cortex.Event` and `Cortex.Events`                                                              | `Cortex.Pulse.Event` for run events; `Logos.Thought.Events` for thought events | Execution events are Pulse; model-mediated thought lifecycle events are Logos.                                                                |
| `Cortex.Document.IR`, `Metadata`, `Host`                                                        | `Cortex.Artifact.*`                                                            | Generic durable output/provenance substrate.                                                                                                  |
| `Cortex.Document.Report`, `Cortex.Document.Section`                                             | `Logos.Patterns.DeepReport.*`                                                  | LLM report/research semantics are Logos pattern semantics.                                                                                    |
| `Cortex.Memory.Score`, `Conflict`, `Source`, `Topological`, and other cognitive-context modules | `Logos.Memory.*`                                                               | Resolved per submodule during Slice 0; only context-shaping code moves here.                                                                  |
| `Cortex.Memory.Persist`, `Schema`, `Host`, and other persistence-shaped modules                 | `Cortex.Pulse.*`, `Cortex.Capability.*`, or internal helpers                   | Not a blanket move; final homes depend on whether the module stores Pulse state, defines host authority, or is merely implementation support. |
| `Cortex.MemoryCompaction`                                                                       | `Logos.Memory.Compact`                                                         | Keep compatibility shim only if needed.                                                                                                       |
| `Cortex.Pulse.Memory.*`                                                                         | `Logos.Memory.Topological.*` where it shapes model context                     | Pulse keeps persisted run state; Logos owns context construction.                                                                             |
| `Cortex.Agent.Config`                                                                           | `Logos.Thought.Frame`                                                          | Model/budget/prompt appendix are thought-frame concerns.                                                                                      |
| `Cortex.Agent.Policy`                                                                           | `Logos.Thought.Policy`                                                         | Tool scope and approval policy for thoughts.                                                                                                  |
| `Cortex.Agent.Definition`                                                                       | `Logos.Thought.Frame` or remove                                                | Avoid durable persona semantics unless a downstream product defines one.                                                                      |
| `Cortex.Task.Host`                                                                              | `Logos.Thought.Host`                                                           | Host for one model-mediated thought.                                                                                                          |
| `Cortex.Task.ToolHost`                                                                          | `Logos.Thought.ToolHost`                                                       | Host-side tool execution for a thought.                                                                                                       |
| `Cortex.Task.ToolLoop`                                                                          | `Logos.Thought.ToolLoop`                                                       | ReAct-style model/tool loop.                                                                                                                  |
| `Cortex.Task.Runtime`                                                                           | `Logos.Thought.Runtime`                                                        | Thin thought runner and lifecycle event helpers.                                                                                              |
| `Cortex.Task.StructuredOutput`                                                                  | `Logos.Thought.StructuredOutput`                                               | Structured model-output decoding and fallback policy.                                                                                         |
| `Cortex.Task.Plan`                                                                              | `Logos.Patterns.PlanReview`                                                    | Planner/reviewer pattern.                                                                                                                     |
| `Cortex.Task.Gather`                                                                            | `Logos.Patterns.DeepReport.Gather`                                             | DeepReport evidence-gathering stage.                                                                                                          |
| `Cortex.Task.Report`                                                                            | `Logos.Patterns.DeepReport.LegacyReportTask` initially                         | Decompose after contracts and ports stabilize.                                                                                                |
| `Cortex.Research.Section`                                                                       | `Logos.Patterns.DeepReport.Section`                                            | Section/chunk schema for model-generated research reports.                                                                                    |
| `Cortex.Research.Runtime`                                                                       | `Logos.Patterns.DeepReport.Section.Runtime`                                    | Section-output parsing and validation.                                                                                                        |
| `Cortex.Run.Types`                                                                              | split between `Cortex.Pulse.Run` and `Logos.Thought.Stage`                     | Durable run ids are Pulse; thought stage descriptors are Logos.                                                                               |
| `Cortex.Run.Engine`                                                                             | `Logos.Thought.Events`                                                         | Emits thought lifecycle events.                                                                                                               |
| `Cortex.Provider.OpenRouter.*`                                                                  | `Cortex.Capability.Provider.OpenRouter.*`                                      | Provider adapters belong under Capability; the target home is decided, deletion timing is deferred.                                           |
| `Cortex.Json.*`                                                                                 | `Platform.Serde.Json.*` or internal modules                                    | Generic serde helpers should not be canonical Cortex roots.                                                                                   |
| `Cortex.Text`                                                                                   | `Platform.Text` or internal module                                             | Generic text helpers should not be canonical Cortex roots.                                                                                    |

Compatibility modules may remain temporarily, but the canonical Cortex public root list is
`Algebra`, `Wire`, `Pulse`, `Capability`, and `Artifact`. Logos is the separate downstream
reasoning-library root.

### DeepReport extraction slices

1. Add `Logos.Patterns.DeepReport.Contracts` with the generic contract catalog and tests for
   registry contents.
2. Update Portman to import the Logos contract catalog instead of defining the generic contracts
   locally.
3. Add `Logos.Patterns.DeepReport.Ports` for generic port maps, leaving Portman to extend or
   override product-specific executor bindings.
4. Update Portman to compose the Logos port catalog with product-specific ports.
5. Add minimal generic DeepReport Wire templates only after contracts and ports have stable names.
6. Move reusable prompt, memory, and evaluation policy into Logos only after the product-specific
   finance instructions are separated.
7. Decide the final home for `ReportArtifactRef` and remove any temporary DeepReport re-export.
8. High-risk compiler slice: parameterize or replace the current `@cortex.deep_report` compiler
   special case so runtime wrappers are not hardcoded to one downstream workflow shape. This touches
   the Wire compiler hot path and should land separately with focused compiler/runtime regression
   tests.

## Pending decisions

- Whether `.wire` `contract X;` declarations should admit local contract names, remain
  documentation-only, or become importable declaration files. Current compiler behavior parses them
  but does not use them for registry membership. Tracked by GitHub #50.
- The API surface for explicit strict/permissive contract-registry mode. The behavior is settled:
  Logos patterns compile against explicit registries.
- The exact schemas and content validation rules for generic DeepReport contracts.
- The concrete executor-definition data type and whether it belongs under `Cortex.Capability`,
  `Cortex.Wire`, or `Logos.Patterns`.
- The final home for generic artifact contracts such as `ReportArtifactRef`.
- Which compatibility shims should remain exposed after the root migration and for how many
  releases.
- How to delete or shim `Cortex.Provider.OpenRouter.*` after moving the canonical provider home to
  `Cortex.Capability.Provider.OpenRouter.*`.

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
  artifact/provenance. LLM report and research-section semantics belong under Logos patterns.
- **Keep `Memory` as a root.** Rejected because the old root mixed Pulse settled-state queries with
  Logos context construction. Pulse durable state remains Pulse; model/context shaping belongs in
  Logos memory.
- **Keep `Agent` as the Logos execution word.** Rejected because agent implies durable persona
  identity. Cortex evaluates graph nodes as bounded stage actions. Logos may interpret selected
  stages as thoughts when a model-mediated library needs that vocabulary.

- **Keep DeepReport entirely in Portman.** Rejected because generic reasoning contracts and workflow
  shape are reusable Logos assets, not finance-product assets.
- **Move the whole Portman DeepReport runtime into Cortex.** Rejected because it would pull user,
  portfolio, DB, workspace, tool-auth, and product-artifact policy into the substrate.
- **Let executors own contract definitions.** Rejected because the same contract must be shared by
  multiple executors and patterns. Executors should reference contract ids, not define their
  meaning.
- **Create a new Logos runtime registry.** Rejected because ADR 0015 preserves the existing
  authority boundaries. Logos publishes catalogs interpreted by Wire, Pulse, capability, memory, and
  artifact substrate APIs.
- **Ship `.wire` inline contract declarations as the sharing mechanism now.** Deferred because the
  current compiler ignores `TopContract`, imports are not compiled, and the registry-backed Haskell
  catalog is the safer first step.

## Consequences

### Positive

- Generic DeepReport reasoning vocabulary can be reused by other consumers.
- The Cortex public root becomes small enough to explain: algebra, language, durable execution,
  external capability, artifacts, and cognition.
- Executors, contracts, and patterns become separately nameable and testable.
- Portman keeps product authority while deleting duplicated generic contract definitions.
- Contract sharing becomes explicit through catalog composition.

### Negative

- The transition creates a temporary split between generic catalog modules and Portman runtime
  execution.
- Root migration creates compatibility-shim work and downstream import churn.
- Existing `.wire` docs overstate `contract X;` behavior until the pending declaration semantics are
  resolved.
- DeepReport schemas are currently broad object schemas; formalizing them will expose shape debt.

### Obligations

- Add tests proving the Logos DeepReport contract catalog is stable and complete.
- Add compatibility modules or migration notes for every moved root-level module.
- Audit Architecture chapters 03-08 for stale top-level Graph, Circuit, Document, and Memory framing
  during Slice 0.
- Update public-prelude drift assertions when archetype paths move from `Logos.<Archetype>` to
  `Logos.Archetypes.<Archetype>`.
- Keep Portman product tools and authorization downstream.
- Avoid moving provider or host authority into Logos pattern modules.
- Replace stringly duplicated contract names with catalog exports where possible.
- Update Wire documentation once `.wire` contract declaration semantics are decided and implemented.

## Related

- [0015-canonical-logos-archetypes.md](./0015-canonical-logos-archetypes.md) defines
  `Logos.Archetypes` and reserves `Logos.Thought`, `Logos.Memory`, and `Logos.Patterns`.
- [../Logos/reasoning-library.md](../Logos/reasoning-library.md) describes the Logos/runtime
  boundary.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) describes Wire's
  closed-authority composition model.
- [../Architecture/08-artifacts-and-provenance.md](../Architecture/08-artifacts-and-provenance.md)
  describes contract-owned meaning and runtime envelopes.
