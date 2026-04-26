---
title: "Topology-Aware Artifact Projections Implementation Plan"
description: Next-phase plan for moving from coarse port contracts to typed artifacts, explicit projections, and topology-bounded retrieval in `.cr` workflows
---

# Topology-Aware Artifact Projections Implementation Plan

**Date:** 2026-04-14  
**Issues:** `DIG-488`, `DIG-490`  
**Status:** proposed  
**Scope:** typed artifact outputs, projected active context, topology-bounded retrieval, and migration of deep-report workflows away from whole-payload fanout

## Summary

The current typed-port system fixes one class of failure well: semantically
invalid graph wiring now fails at authoring compile time instead of at runtime.
That was enough to catch cases like wiring a `section_compiler` node behind a
`ReportFragment` producer when the runtime actually expected `AnalysisFragment`.

However, the current contracts are still too coarse. A port can say
`AnalysisFragment`, but downstream nodes still often receive the whole upstream
analysis blob. The result is valid topology with needlessly broad context
assembly.

The next phase should introduce a stronger split:

- a node emits one full typed artifact
- downstream nodes declare deterministic input bindings that inject only the
  needed slice into active context before the agent fires
- the rest of the artifact remains durably reachable through topology-bounded
  retrieval

This plan keeps the current port algebra and extends it into a real typed
artifact system. It does **not** introduce first-class typed edges, a general
type definition language in `.cr`, or model-driven semantic retrieval as the
default dataflow mechanism.

## Problem Statement

The latest mixed-model thesis runs made the limitation visible:

- the graph shape was valid
- the port contracts were valid
- but section compiler nodes still received large merged upstream payloads
- section latency was therefore dominated by remote model time on broad prompts,
  even when the section only needed one or two semantic slices

The current deep-report runtime still behaves roughly like this:

1. upstream analyst-family nodes emit typed JSON payloads
2. downstream nodes accept the right coarse contract, such as
   `AnalysisFragment`
3. runtime context assembly concatenates or merges the full upstream content
4. the model sees far more than the node actually needs

This is not a classical "memory bloat" problem. The main bulk is not coming
from long-lived durable memory. It is coming from naive assembly of current-run
upstream artifacts into active context.

The missing abstraction is not "more memory." It is:

- finer-grained artifact interfaces
- deterministic pre-agent input bindings from producer output to consumer
  context
- deterministic retrieval of additional upstream fields only when needed

## Design Goals

- Keep ports as the main algebra. Do not introduce a separate edge type system.
- Make graph dataflow more precise without requiring arbitrary schema
  declarations in `.cr`.
- Keep Haskell in control of payload codecs, versions, and validation.
- Let `.cr` reference semantic types, projections, and bindings declaratively.
- Preserve the full upstream artifact for observability, replay, and later
  retrieval.
- Make the default downstream context minimal and explicit.
- Bound retrieval by graph topology. A node should not rummage arbitrarily
  through the entire run state.
- Keep context-shaping deterministic and pre-agent. The model should not decide
  what part of an artifact becomes its default input.

## Non-Goals

- No user-defined type declarations in `.cr` in this phase
- No semantic vector search or snippet search as the default retrieval path
- No replacement of the current runtime with a fully generic typed VM
- No live query language for arbitrary JSON traversal authored directly by the
  model
- No first-class typed edges independent of ports
- No "everything is just Json" type system with untyped convention-based
  section names

## Core Vocabulary

### Port Contract

A compatibility label used at wiring time. The current system already has
examples such as:

- `PlannerOutput`
- `EvidenceBundle`
- `AnalysisFragment`
- `ReportFragment`
- `ReviewBundle`
- `ReportArtifactRef`

Port contracts answer:

- can these endpoints connect?

They do **not** answer:

- what exact structured fields are projected into downstream context?

### Artifact Type

A Haskell-owned structured payload definition emitted by a node output port.

Examples:

- `DeepReportPlannerOutput`
- `DeepReportGathererOutput`
- `DeepReportAnalysisBundle`
- `DeepReportSectionDraft`
- `DeepReportReviewerOutput`

Artifact types answer:

- what does the full emitted payload look like?

### Input Type

A semantic type representing the slice of data a downstream node receives as
its primary active input.

Examples:

- `deep_report.options_section`
- `deep_report.valuation_analysis`
- `deep_report.risk_analysis`
- `deep_report.reviewer_summary_input`

Input types answer:

- what shape should this node actually see in active context?

### Binding

A deterministic, pre-agent mapping from one or more connected upstream
artifacts into named context values for a node.

Examples:

- `main = from planner.out select .options`
- `refs = from planner.out select .evidenceRefs`
- `risk = from thesis_breakers.out select .risk`

Bindings answer:

- what exact slice enters the node's active context before the agent fires?

### Projection

A named, Haskell-defined reusable mapping from an artifact type to a smaller
semantic input shape.

Examples:

- `analysis_bundle -> valuation_analysis`
- `analysis_bundle -> risk_analysis`
- `analysis_bundle -> trigger_analysis`
- `review_bundle -> reviewer_summary_input`

Projection answers:

- what reusable slice can a binding or connection refer to without spelling out
  a raw selector path?

### Active Context

The exact data automatically inserted into the current model call because of
explicit graph wiring and declared projections.

### Reachable Memory

The set of durable upstream artifacts that remain accessible to a node through
topology-bounded retrieval, but are **not** automatically injected into active
context.

This distinction is central:

- active context should stay small and deterministic
- reachable memory is the escape hatch for additional detail

## Best-Fit Type Model

The recommended type model is:

- node outputs have semantic artifact types
- node inputs have semantic input types
- projections map artifact types to reusable input-oriented slices
- bindings determine what actually enters active context

Conceptually:

```txt
planner.out : DeepReport
planner.out[options] : OptionsSection
option_analyst : OptionsSection -> OptionsAnalysis
```

The important distinction is that `DeepReport.options` is **not** itself a
type. It is:

- a named projection
- or a selector path

The type is the semantic input type produced by that projection:

- `OptionsSection`

This avoids conflating:

- where a field happens to live inside one producer
- what semantic shape the downstream node actually consumes

## Recommended Algebra

The right near-term model is:

- node outputs are full typed artifacts
- input ports accept semantic input types
- edges connect output ports to input ports
- nodes declare deterministic bindings that project or select slices from
  connected upstream artifacts into active context
- edge validity is derived from:
  - the output artifact type
  - the available projection or selector result type
  - the sink input type

This means the edge is still not a first-class typed object. Instead:

- the source output port has a full artifact type
- the sink input port has a required semantic input type
- the node binding layer determines what slice is injected
- named projections may still exist as reusable sugar over common selectors

This keeps the current port algebra intact and avoids introducing a second
parallel typing system.

## Proposed Type Ownership Model

### Haskell Owns Types

In the first phase, ``.wire` should **not** define new types.

Haskell should own:

- artifact type definitions
- projection registries
- codecs
- versioning
- validation

``.wire` should only reference:

- contract names
- artifact type names
- input type names
- projection names
- binding expressions from a small deterministic selector language

This keeps migration, compatibility, and runtime decoding under code review and
test coverage.

### `.cr` References Types

The workflow file should remain declarative:

- which node emits which artifact
- which input accepts which semantic input types
- which bindings derive those inputs from connected artifacts
- which named projections are reused where helpful

## Syntax Proposal

## Phase 1 Syntax

Extend the current `ports` blocks with optional artifact and input type
metadata, and add a `bindings` block for deterministic pre-agent context
assembly.

```txt
node option_analyst {
  role = act;
  executor = llm("deepseek/deepseek-v3.2");
  ports = {
    inputs = {
      in = {
        accepts = ["PlannerOutput"];
        inputType = "deep_report.options_section";
        cardinality = "one";
        required = true;
      };
    };
    outputs = {
      out = {
        contract = "AnalysisFragment";
        artifact = "deep_report.options_analysis";
      };
    };
  };
  bindings = {
    main = from planner.out select .options;
    refs = from planner.out select .evidenceRefs;
  };
}
```

With ordinary graph wiring:

```txt
connect planner.out option_analyst.in;
```

Meaning:

- `planner.out` emits a full `deep_report` artifact
- `option_analyst` consumes a semantic `options_section` input
- only the selected bindings are injected into active context before the agent
  fires
- the rest of the planner artifact remains durably reachable

### Optional Named Projection Sugar

The binding layer should support reusable projection names as sugar:

```txt
bindings = {
  main = from planner.out use options;
  refs = from planner.out use evidenceRefs;
};
```

Here:

- `options` is a named Haskell-defined projection
- `evidenceRefs` is a named Haskell-defined projection
- `use` is preferred over embedding raw stringly selector paths everywhere

The system should still allow a small selector syntax for one-off bindings:

```txt
bindings = {
  main = from planner.out select .options;
  refs = from planner.out select .evidenceRefs;
};
```

### Selector Language

The selector language should be intentionally small and deterministic. It
should feel closer to a typed Nix binding language with jq-style selectors than
to full jq.

Recommended first-slice operators:

- field select: `.foo`
- nested field select: `.foo.bar`
- optional field: `.foo?`
- array element mapping
- simple list filtering by equality
- `orElse`
- `concat`
- `flatten`

Do **not** start with:

- arbitrary jq programs
- free-form user-defined functions
- semantic search over JSON

### Why Bindings Are Better Than Edge-Only Projections

If all slicing lives inside opaque node code, the graph stops telling us much.
Bindings keep the shaping logic declarative and compileable.

This gives us:

- visible dependencies
- pre-agent determinism
- better validation
- easier observability

The edge still says:

- who can feed whom

The bindings say:

- what that downstream node actually sees by default

### Phase 1 Input Port Shape

Input ports should accept a single semantic input type:

```txt
inputs = {
  in = {
    accepts = ["AnalysisFragment"];
    inputType = "deep_report.valuation_analysis";
    cardinality = "many";
    required = true;
  };
};
```

Compiler rule:

- the node's bindings into this port must resolve to
  `deep_report.valuation_analysis`
- named projections are one way to satisfy that requirement
- selector expressions must typecheck to that same semantic input type

## Runtime Semantics

### Producer Semantics

When a node completes, runtime persists the full output artifact:

- run id
- node id
- attempt id
- output port id
- artifact type
- artifact version
- encoded payload

This becomes the node's durable output record.

### Consumer Semantics

When a downstream node starts:

1. runtime inspects incoming edges
2. runtime evaluates the node's declared bindings against reachable upstream
   artifacts
3. runtime materializes the bound input values
4. only the bound values are inserted into active context

This is the core behavioral change. Today many consumers receive broad merged
payloads. Under the new system, they receive only the bound inputs implied by
the graph.

### Retrieval Semantics

The rest of the source artifact remains durably reachable, but not automatically
injected.

The first retrieval surface should be deterministic and topology-bounded:

- retrieve by upstream node id
- retrieve by artifact type
- retrieve by declared field path

Good first examples:

- `getNodeArtifact("analyst_core")`
- `getNodeArtifactField("analyst_core", "valuation.comps")`
- `getReachableArtifactsByType("deep_report.risk_analysis")`

Avoid semantic free-text snippet search in phase 1. For structured artifacts,
field/path retrieval is the right default.

Bindings should remain the primary dataflow mechanism. Retrieval is the escape
hatch, not the default substitute for explicit graph structure.

## Example: Thesis Mixed Workflow

The current mixed thesis workflow exposes the target use case clearly.

Today, several specialist nodes conceptually produce distinct outputs:

- `quant_valuation_gather`
- `quant_risk_gather`
- `quant_momentum_gather`
- `thesis_breakers`
- `valuation_referee`
- `evidence_auditor`

But downstream section compilers still effectively consume a large merged
analysis bundle.

### Proposed Artifact Family

Instead of generic `AnalysisFragment` everywhere, use one richer producer artifact
family and more specific semantic inputs:

```txt
deep_report.analysis_bundle = {
  valuation : deep_report.valuation_analysis;
  risk : deep_report.risk_analysis;
  momentum : deep_report.trigger_analysis;
  audit : deep_report.evidence_audit;
  breakers : deep_report.breaker_analysis;
}
```

Then bind sections like this:

```txt
connect quant_valuation_gather.out valuation_and_positioning.in;
connect valuation_referee.out valuation_and_positioning.in;

bindings valuation_and_positioning = {
  valuation = from quant_valuation_gather.out use valuation;
  referee = from valuation_referee.out use valuation;
};

connect quant_risk_gather.out failure_conditions.in;
connect thesis_breakers.out failure_conditions.in;
connect evidence_auditor.out failure_conditions.in;

bindings failure_conditions = {
  risk = from quant_risk_gather.out use risk;
  breakers = from thesis_breakers.out use breakers;
  audit = from evidence_auditor.out use audit;
};

connect quant_momentum_gather.out monitoring_triggers.in;
connect valuation_referee.out monitoring_triggers.in;

bindings monitoring_triggers = {
  triggers = from quant_momentum_gather.out use triggers;
  valuation = from valuation_referee.out use monitoring;
};
```

This gives each section compiler only the slices it needs by default, while the
full upstream artifacts remain reachable.

### Executive Summary Example

`executive_summary` is special because it often wants a cross-section view.

That should be modeled explicitly instead of by accidental whole-payload fanout.

Recommended options:

- feed it a dedicated `review_summary_input` projection from the reviewer bundle
- or feed it a curated set of projections from section outputs

Avoid:

- treating "executive summary needs broad context" as a reason to inject every
  upstream artifact wholesale

## Example: Producer Record Instead of Tuple

The right shape is a record, not a positional tuple.

Bad:

```txt
bcdOut = (b_in, c_in, d_in)
```

Good:

```txt
deep_report.specialist_bundle = {
  valuation : deep_report.valuation_analysis;
  risk : deep_report.risk_analysis;
  triggers : deep_report.trigger_analysis;
}
```

Then:

- `B.in` receives `valuation`
- `C.in` receives `risk`
- `D.in` receives `triggers`

This keeps the artifact semantic instead of encoding downstream consumer names
into the output shape.

## Edge Cases

### Multiple Downstream Projections From One Artifact

One producer can feed many downstream nodes via different projections:

```txt
connect analyst_core.out valuation_section.in;
connect analyst_core.out risk_section.in;
connect analyst_core.out trigger_section.in;

bindings valuation_section = {
  main = from analyst_core.out use valuation;
};

bindings risk_section = {
  main = from analyst_core.out use risk;
};

bindings trigger_section = {
  main = from analyst_core.out use triggers;
};
```

This should be normal and cheap because the full artifact is persisted once and
projected many times.

### Multiple Inputs To One Port

If `cardinality = "many"`, several compatible projections may flow into one
sink input port.

Compiler must still validate:

- every bound source slice matches the declared sink input type
- `cardinality = "one"` is not violated

Runtime must preserve deterministic ordering rules if the consumer relies on
order.

### Missing Projection

Compile error if:

- a binding references `use some_projection`
- but the source artifact type does not define that projection

### Projection Type Mismatch

Compile error if:

- `use valuation` produces `deep_report.valuation_analysis`
- but sink `in` expects `deep_report.trigger_analysis`

### Selector Type Mismatch

Compile error if:

- a raw selector path is valid structurally
- but its inferred output shape does not satisfy the declared semantic input
  type

### Required Inputs

Required input ports should stay a compile-time property:

- no inbound edge to a required input port is an authoring error

### Hidden Dependency Creep

Retrieval is useful, but too much retrieval turns the graph into hidden
dependency soup.

Rule:

- explicit bindings should remain the main dataflow mechanism
- retrieval is a bounded fallback, not the normal path

### Condition Nodes

Condition seams should also participate in binding validation.

For `if cond between A B { ... }`, compiler must validate:

- the binding from `A` into the condition node
- the condition node's pass-through or transformed output type
- the chosen branch exit type into `B`

### Artifact Versioning

Artifact types and projections must be versioned in Haskell.

If an artifact evolves:

- old persisted artifacts should remain decodable or explicitly migratable
- projection registries should be version-aware

This is another reason not to let `.cr` invent arbitrary inline schemas early.

## Interaction With DeepReport And Cortex

The split should be:

- **Cortex**
  - generic port algebra
  - typed artifact and input model
  - binding syntax and selector engine
  - contract registry abstraction
  - compile-time compatibility checking
  - durable artifact storage interface
  - topology-bounded retrieval API shape

- **DeepReport**
  - concrete artifact families
  - concrete projections
  - concrete semantic input types
  - native executor defaults
  - section compiler input types
  - condition pass-through shapes

In other words:

- generic typing machinery belongs in Cortex
- concrete workflow payload libraries remain domain libraries

DeepReport is the first serious contract library, but it should not be promoted
into raw Cortex simply because it is the first one.

## Migration Plan

### Phase 1: Explicit Artifact Metadata

- keep current port contracts
- add optional `artifact` and `inputType` metadata
- add `bindings` blocks for deterministic pre-agent context assembly
- support named projections and a small typed selector subset
- compile-time validate binding compatibility
- keep runtime behavior mostly unchanged except for bound context assembly

### Phase 2: Split Coarse Contracts And Inputs

Replace generic `AnalysisFragment` everywhere with more semantic families where
it clearly helps:

- `valuation_analysis`
- `risk_analysis`
- `trigger_analysis`
- `audit_analysis`
- `breaker_analysis`

This reduces accidental whole-payload reuse even before richer retrieval work.

### Phase 3: Durable Artifact Store

- persist full typed artifacts with versions
- make bound context assembly read from the store instead of ad hoc
  in-memory merges
- add deterministic field/path retrieval

### Phase 4: Topology-Bounded Retrieval

- expose retrieval to runtime nodes and, where appropriate, to model tools
- restrict reachable artifacts to graph ancestors or declared reachable scopes

### Phase 5: Optimize DeepReport Section Compiler

Use the new system to stop building section prompts from the entire merged
analyst corpus.

Target state:

- `failure_conditions` gets risk, breaker, and audit projections
- `valuation_and_positioning` gets valuation projections only
- `monitoring_triggers` gets trigger-oriented projections only

This should reduce repeated section prompt breadth without needing to redesign
section compilation itself.

## Open Questions

### Should `.cr` Ever Declare Types?

Not in the next phase. The right first move is Haskell-owned types with `.cr`
references only.

### Should Edges Become First-Class Typed Objects?

Probably not. Port typing plus explicit bindings and reusable projections is the
cleaner algebra unless edges later need their own transport or causal
semantics.

### Should Retrieval Be Model-Driven?

Eventually maybe, but not first.

First retrieval should be:

- deterministic
- typed
- field/path based
- topology bounded

### Should Projections Be Declared On The Producer Or The Edge?

The projection registry belongs to the producer artifact type. Bindings should
be the primary place that chooses which producer-defined slice is injected
downstream.

Named projections remain useful, but they should behave like reusable binding
helpers, not like a second edge-typing system.

### Should Everything Just Be `Json`?

No. A plain `Json -> Json` type system cuts off too early.

The right model is:

- semantic artifact type
- semantic input type
- binding or projection from one to the other

For example:

```txt
planner.out : DeepReport
planner.out[options] : OptionsSection
option_analyst : OptionsSection -> OptionsAnalysis
```

`DeepReport.options` is not itself the type. It is the projection. The type is
`OptionsSection`.

## Recommended Next Slice

If this plan is accepted, the first implementation slice should be:

1. add `artifact` and `inputType` metadata to authored ports
2. add `bindings` blocks and a small typed selector language
3. add a Haskell projection registry for deep-report artifact families
4. make binding-derived context assembly the default runtime behavior
5. migrate the thesis mixed workflow to section-local bindings

This is the smallest slice that turns the current typed ports into useful
context boundaries instead of compatibility labels only.
