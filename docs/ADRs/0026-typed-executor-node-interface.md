---
title: "ADR 0026 - Typed Executor Node Interface"
description:
  "Requires every executor node, including LLM-backed executors, to expose typed input and output
  ports instead of treating incoming edges as untyped context."
sidebar:
  label: "0026. Typed executors"
  order: 26
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/09-nous-reasoning-library.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - docs/ADRs/0023-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-wire-node-clause-grammar.md
  - docs/ADRs/0025-corepure-expression-surface.md
---

# ADR 0026 - Typed Executor Node Interface

## Status

Proposed - this ADR states the topology-level executor interface that the next Wire phase should
apply to LLM-backed executors, pure executors, HTTP executors, artifact executors, and any other
registered executor family.

## Context

Historically, LLM executor nodes have often behaved as multi-input prompt sinks. Every incoming edge
was treated as "context" and the executor assembled that context into prose. That was workable while
model-mediated nodes were the only interesting computation primitive: the inconsistency was hidden
inside prompt construction.

Pure nodes expose the inconsistency. Once `pure (...)` has declared input ports and declared output
ports, the clean model is:

- nodes are functions;
- input ports are typed arguments;
- output ports are typed values;
- edges are wiring.

LLM nodes should fit that model. If they continue to swallow variadic incoming arrows as untyped
context, the topology layer says one thing for pure nodes and another for model nodes. That repeats
the same design smell as using `Directive` payloads to encode control structure: topology is being
hidden inside data because the node boundary is too loose.

ADR 0018 already separates contracts, ports, executor projections, host codecs, and authority. ADR
0021 already says Wire compiles against executor projections. This ADR makes the executor projection
discipline explicit for model-mediated executors.

## Decision

Every executor node has the same external topology shape:

- declared input ports, each with a contract;
- declared output ports, each with a contract;
- a registered executor implementation selected by the RHS;
- typed failure on admission, decode, execution, or output-validation failure.

The executor's internal mechanism may differ. `pure (...)` evaluates CorePure. `@llm.* (...)` calls
a model. `@http.* (...)` may make a network request. The topology layer does not get a separate
shape for those cases.

Edges carry typed values. They do not carry "context", prompt fragments, control flow, structural
fan-out, or implicit argument order. Those are jobs for nodes and for executor configuration.

The principle is:

- nodes are typed functions;
- edges are wiring, not communication;
- topology is the orchestration;
- executors are interchangeable behind their contracts.

### LLM Executors

An LLM executor is structurally identical to any other executor:

```wire
node analyze
  <- evidence: EvidenceSet ;
  -> analysis: AnalysisRecord = @llm.analyze (evidence) ;
```

The executor knows that it calls a model. The topology does not. From Wire's perspective, the node
takes an `EvidenceSet` value and produces an `AnalysisRecord` value or a typed executor failure.

Prompt construction belongs inside the executor binding or executor config. It may use a template
over typed input values, and CorePure string interpolation from ADR 0025 gives that template surface
a natural expression language. The model response must be decoded and validated against the declared
output contract, for example through strict JSON schema mode or an equivalent binding-layer
validator. A response that does not validate is an executor failure, not an untyped downstream blob.

Model calls are still external and may be nondeterministic or fail for provider reasons. The common
interface claim is structural: every executor consumes typed values and emits typed values or typed
failure. It is not a claim that LLM execution has pure-evaluator determinism.

### Structural Work Belongs In Pure Nodes

Projection, fan-in, fan-out, filtering, prompt-fragment construction, and record reshaping should be
expressed as `pure (...)` work rather than hidden in LLM context concatenation.

For example, an LLM can produce one typed structured output, and a downstream pure node can expose
fields as separate ports:

```wire
node analyze
  <- evidence: EvidenceSet ;
  -> analysis: AnalysisRecord = @llm.analyze (evidence) ;

node distribute
  <- analysis: AnalysisRecord ;
  -> summary: String = pure (analysis.summary) ;
  -> recommendations: List String = pure (analysis.recommendations) ;
  -> riskScore: Number = pure (analysis.riskScore) ;
```

This keeps the topology auditable:

- the model boundary is the `AnalysisRecord` contract;
- downstream consumers depend on typed fields, not prompt text;
- changing the prompt does not change graph structure;
- changing graph structure does not require prompt-string surgery.

Under ADR 0023, statically reducible pure projection can be folded during elaboration. Input-bound
projection remains an explicit pure executor invocation, still visible as structure rather than
buried in a model prompt.

### Heterogeneous Models

Heterogeneous model use is ordinary topology. A pure fan-out node can feed several typed LLM nodes,
each with its own executor id, model policy, input contracts, and output contracts:

```wire
node prepareReviews
  <- report: DraftReport ;
  -> valuationPrompt: ReviewInput = pure (makeReviewInput "valuation" report) ;
  -> legalPrompt: ReviewInput = pure (makeReviewInput "legal" report) ;

node valuationReview
  <- input: ReviewInput ;
  -> review: ReviewResult = @llm.gpt54-reviewer (input) ;

node legalReview
  <- input: ReviewInput ;
  -> review: ReviewResult = @llm.qwen3-reviewer (input) ;
```

No special model-selection syntax is needed at the Wire level. Model choice is executor
configuration and binding policy.

## Migration discussion

Existing LLM nodes that "swallow all arrows" should be decomposed.

For each representative downstream wire, audit every incoming edge to an LLM node:

- keep values that are genuine model inputs as declared typed input ports;
- move structural fan-in, projection, filtering, and prompt-fragment assembly into upstream
  `pure (...)` nodes;
- define typed output contracts for the LLM result;
- move fan-out and field projection into downstream `pure (...)` nodes;
- simplify the LLM executor to typed inputs, prompt template, output schema, model policy, and
  validation.

The implementation precedent for typed model output should be strict JSON mode or an equivalent
schema-constrained provider path. The exact provider mechanism is binding-layer policy, not Wire
semantics.

This migration is not syntax cleanup. It is what makes the formal story describe real model
workflows instead of a clean idealization where LLM nodes silently violate typed topology.

## Alternatives considered

- **Keep LLM nodes as variadic context sinks.** Rejected because it gives model executors a special
  topology shape and hides structure in prompt concatenation.
- **Treat "context" as a special edge kind.** Rejected because it reintroduces semantic edges. Wire
  edges should remain typed wiring between ports.
- **Let LLM executors return free-form blobs and parse downstream.** Rejected because downstream
  parsing makes output structure implicit and moves contract failure away from the executor
  boundary.
- **Add a model-selection layer to Wire syntax.** Rejected because heterogeneous model choice is
  already expressible as ordinary executor topology plus host binding policy.

## Consequences

### Positive

- Pure, LLM, HTTP, artifact, and future executor families share one topology interface.
- LLM calls become auditable as typed values in and typed values out.
- Prompt construction no longer doubles as hidden graph structure.
- Strict output validation gives downstream nodes stable contracts.
- Heterogeneous model workflows become ordinary graph composition.

### Negative

- Existing downstream LLM wires need migration work.
- Some prompt templates will move from free-form concatenation into typed config or pure helper
  expressions.
- LLM executor bindings must reject invalid output rather than passing weakly parsed blobs onward.

### Obligations

- Update executor projection docs so `@llm.*` projections declare typed input and output ports.
- Add examples that show LLM structured output followed by pure fan-out.
- Audit current downstream LLM wires and classify each incoming edge as model input or structural
  work.
- Define output contracts for current model-mediated nodes.
- Ensure runtime output validation reports typed executor failures.

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0014 - Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0021 - Executor Registration and Binding](./0021-executor-registration-and-binding.md)
- [ADR 0023 - Wire Source Elaborates to Circuits](./0023-wire-source-elaborates-to-circuits.md)
- [ADR 0024 - Wire Node Clause Grammar](./0024-wire-node-clause-grammar.md)
- [ADR 0025 - CorePure Expression Surface](./0025-corepure-expression-surface.md)
