---
title: "ADR 0024 - Typed Executor Node Interface"
description:
  "Requires every executor node, including LLM-backed executors, to expose typed input and output
  ports instead of treating incoming edges as untyped context."
sidebar:
  label: "0024. Typed executors"
  order: 24
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Consumers/Logos/reasoning-library.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/configured-executors-and-execution-boundary.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0024 - Typed Executor Node Interface

## Status

Proposed - this ADR states the topology-level executor interface that the next Wire phase should
apply to LLM-backed executors, pure executors, HTTP executors, artifact executors, and any other
registered executor family.

## Context

Historically, LLM executor nodes have often behaved as multi-input prompt sinks. Every incoming edge
was treated as "context" and the executor assembled that context into prose. That was workable while
model-mediated nodes were the only interesting computation primitive: the inconsistency was hidden
inside prompt construction.

CorePure output nodes expose the inconsistency. Once a deterministic node has declared input ports
and declared output ports, the clean model is:

- nodes are functions;
- input ports are typed arguments;
- output ports are typed values;
- edges are wiring.

LLM nodes should fit that model. If they continue to swallow variadic incoming arrows as untyped
context, the topology layer says one thing for pure nodes and another for model nodes. That repeats
the same design smell as using `Directive` payloads to encode control structure: topology is being
hidden inside data because the node boundary is too loose.

ADR 0017 already separates contracts, ports, executor projections, host codecs, and authority. ADR
0021 already says Wire compiles against executor projections. This ADR makes the executor projection
discipline explicit for model-mediated executors.

## Decision

Every executor node has the same external topology shape:

- a declared input-port set, possibly empty, with a contract for each port;
- a declared output-port set, possibly empty, with a contract for each port;
- a registered executor implementation selected by the RHS;
- typed failure on admission, decode, execution, or output-validation failure.

The executor's internal mechanism may differ. CorePure output equations evaluate through the native
pure evaluator. `@review.* (...)` calls a model. `@http.* (...)` may make a network request. The
topology layer does not get a separate shape for those cases.

Edges carry typed values. They do not carry "context", prompt fragments, control flow, structural
fan-out, or implicit argument order. Those are jobs for nodes and for executor configuration.

The principle is:

- nodes are typed functions;
- edges are wiring, not communication;
- topology is the orchestration;
- executors are interchangeable behind their contracts.

### Empty Boundaries Are Not Roles

An empty input or output boundary is ordinary arity, not a special node kind. A node with no inputs
is still just an executor invocation with zero typed arguments. A node with no outputs is still just
an executor invocation whose declared result boundary is empty. Wire does not need explicit source
or sink roles to explain either case.

This matters because real graphs may start from several independent zero-input nodes, converge
through ordinary typed edges, branch again, or terminate through several zero-output nodes. They may
also expose multi-input and multi-output boundaries to a host. Those shapes are graph topology and
runtime admission policy, not executor categories.

The boundary rule is therefore: every admitted vertex has a concrete typed port boundary, and either
side of that boundary may be empty if the registered projection permits it. Empty arity does not
grant a node hidden context, implicit scheduling authority, or a distinguished workflow role.

`CircuitTaskNode` therefore carries no separate semantic node-kind field. Retiring the former
nullable `CircuitNodeKind` field deliberately changes serialized `CircuitIR` shape and its
compatibility digest; structural Circuit constructors and typed executor metadata remain
authoritative.

### Configured Executors Are Not Vertices

This is an intentional breaking change from the older partial-node model. A configured executor
value, such as a reusable `@review.analyst { ... }` value, is not itself a graph vertex. It may name
registered authority and carry reusable configuration, but it may not absorb a port boundary from
surrounding arrows, infer "context" from graph position, or become runnable merely by appearing in a
composition expression.

This overturns the earlier reference-doc model in
[`configured-executors-and-execution-boundary.md`](../Reference/Wire/configured-executors-and-execution-boundary.md),
where partial executor values could later become graph nodes by receiving ports from surrounding
syntax. Under this ADR, reusable configuration may still exist, but it is not a node and it is not
admitted into graph position on its own.

A graph vertex exists only after an explicit node declaration produces a concrete typed port
boundary. A registered fixed executor projection may supply the admission-time backing for an
`@executor (...)` RHS inside that declaration, but it is not an alternative authoring path that
skips the node declaration:

```wire
node analyst
  <- input: AnalysisInput;
  -> analysis: AnalysisRecord = @review.analyst (input);
```

The node declaration is the vertex. The executor RHS is the implementation body behind that typed
signature.

Distribution is therefore topology, not executor-context behavior: one node may expose several
distinct typed outputs for several downstream nodes, but one output port may not be implicitly
copied to several inputs. One typed output intended for several consumers must pass through an
explicit fan-out, sharing, persistence, broadcast, projection, or record↔ports adapter node that
consumes the source once and produces fresh output ports. Fan-in is not implicit aggregation. A
list-valued input receives one list-typed value, not a variadic set of incoming edges. If a shape
needs projection, packing, filtering, prompt assembly, list construction, record reshaping, or
multi-consumer distribution, that shape is expressed as a CorePure output-equation node or explicit
structural adapter rather than as contextual interpretation by an executor or hidden edge semantics.
Later Wire syntax may add sugar for common packing cases, but the admitted graph must still contain
the explicit transformation vertex.

### LLM Executors

An LLM executor is structurally identical to any other executor:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord = @review.analyze (evidence);
```

The executor knows that it calls a model. The topology does not. From Wire's perspective, the node
takes an `EvidenceSet` value and produces an `AnalysisRecord` value or a typed executor failure.

Prompt construction belongs inside the executor binding or executor config. It may use a template
over typed input values, and CorePure string interpolation from ADR 0023 gives that template surface
a natural expression language. The model response must be decoded and validated against the declared
output contract, for example through strict JSON schema mode or an equivalent binding-layer
validator. A response that does not validate is an executor failure, not an untyped downstream blob.

Model calls are still external and may be nondeterministic or fail for provider reasons. The common
interface claim is structural: every executor consumes typed values and emits typed values or typed
failure. It is not a claim that LLM execution has pure-evaluator determinism.

### Executor Capabilities And Topological Memory

The typed-port rule does not forbid executor capabilities. Topological memory and on-demand
retrieval are examples of native Cortex support that belongs to executor binding authority, not to
the proven graph core. Pulse may provide a snapshot-bound query substrate over settled materialized
outputs, and Logos or downstream bindings may expose that substrate as a model tool or
prompt-shaping capability.

That capability is not an extra Wire edge, not a variadic context input, and not node-to-node
message passing. A memory-enabled executor still enters the graph as a node with concrete typed
ports. Its memory policy is declared in registered executor projection or config, and the retrieval
handle observes only the stage-entry snapshot allowed by the Pulse memory contract. Sibling writes,
live frontier state, and hidden peer conversations are not part of the node's topology interface.

The proof-facing core therefore remains the admitted graph: vertices, typed ports, edges,
predecessor hashes, and executor invocations. Native memory support is an executor/downstream
context capability with its own runtime contract and provenance obligations.

### Structural Work Belongs In CorePure Nodes

Projection, packing, filtering, prompt-fragment construction, record reshaping, and multi-output
distribution should be expressed as CorePure output-equation work rather than hidden in LLM context
concatenation.

For example, an LLM can produce one typed structured output, and a downstream CorePure node can
expose fields as separate ports:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord = @review.analyze (evidence);

node distribute
  <- analysis: AnalysisRecord;
  -> summary: String = analysis.summary;
  -> recommendations: Recommendations = analysis.recommendations;
  -> riskScore: RiskScore = analysis.riskScore;
```

This keeps the topology auditable:

- the model boundary is the `AnalysisRecord` contract;
- downstream consumers depend on typed fields, not prompt text;
- changing the prompt does not change graph structure;
- changing graph structure does not require prompt-string surgery.

Under ADR 0021, statically reducible pure projection can be folded during elaboration. Input-bound
projection remains an explicit pure executor invocation, still visible as structure rather than
buried in a model prompt.

### Heterogeneous Models

Heterogeneous model use is ordinary topology. A CorePure distribution node can expose several
distinct typed outputs for several typed LLM nodes, each with its own executor id, model policy,
input contracts, and output contracts:

```wire
node prepareReviews
  <- report: DraftReport;
  -> valuationPrompt: ReviewInput = makeReviewInput "valuation" report;
  -> legalPrompt: ReviewInput = makeReviewInput "legal" report;

node valuationReview
  <- input: ReviewInput;
  -> review: ReviewResult = @review.gpt54_reviewer (input);

node legalReview
  <- input: ReviewInput;
  -> review: ReviewResult = @review.qwen3_reviewer (input);
```

No special model-selection syntax is needed at the Wire level. Model choice is executor
configuration and binding policy.

## Migration discussion

Existing LLM nodes that "swallow all arrows" should be decomposed.

For each representative downstream wire, audit every incoming edge to an LLM node:

- keep values that are genuine model inputs as declared typed input ports;
- move structural fan-in, projection, filtering, and prompt-fragment assembly into upstream CorePure
  output nodes;
- define typed output contracts for the LLM result;
- move field projection and multi-consumer distribution into downstream CorePure output nodes;
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
- **Keep context-determined partial nodes in graph position.** Rejected because surrounding topology
  would influence the executor boundary. Graph and Circuit reasoning require admitted vertices with
  concrete typed ports.
- **Allow list-valued inputs to aggregate multiple incoming edges.** Rejected because edge
  multiplicity would perform an implicit transformation. Packing values into a list is computation,
  so it must be represented by an explicit CorePure output node.
- **Introduce explicit source and sink executor roles.** Rejected because those names describe
  incidental boundary shapes in some workflows, not a topology-level executor category. Multi-entry,
  multi-exit, and multi-to-multi graphs should be ordinary graph structure.
- **Treat topological memory as hidden node awareness.** Rejected because memory/retrieval is
  executor authority over settled materialized outputs, not a topology channel between running
  nodes.
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
- Existing partial-node reuse examples must be rewritten as reusable config values, fixed executor
  projections, or explicit node declarations.
- Existing wires that rely on multi-edge fan-in into list-valued inputs need explicit pure packing
  nodes.
- Some prompt templates will move from free-form concatenation into typed config or pure helper
  expressions.
- LLM executor bindings must reject invalid output rather than passing weakly parsed blobs onward.

### Obligations

- Update executor projection docs so `@review.*` projections declare typed input and output ports.
- Update partial-node and executor reference docs to state that configured executor values are not
  graph vertices in the next Wire surface.
- Update grammar and matching docs so list-valued inputs are ordinary typed ports, not implicit edge
  collectors.
- Update grammar and reference docs to remove source/sink as semantic node categories. Empty input
  and output boundaries should be described as port-boundary arity only.
- Add examples that show LLM structured output followed by pure distribution.
- Move topological memory wording into executor/downstream-context docs and keep it outside the
  proven CorePure and graph-wiring semantics.
- Audit current downstream LLM wires and classify each incoming edge as model input or structural
  work.
- Define output contracts for current model-mediated nodes.
- Ensure runtime output validation reports typed executor failures.

## Traceability

- Feature keys: `wire.typed_executor_interface`
- Public surface: `Cortex.Wire`,
  [Wire Executors and Alphabet](../Reference/Wire/executors-and-alphabet.md)
- Implementation: `src/Cortex/Wire/Executor.hs` (`WireExecutorProjection` over typed `WirePorts`),
  `src/Cortex/Wire/NodeBoundary.hs` (`executorNodeBoundaryNormalForm`, `NodeBoundaryExecutorBody`),
  `src/Cortex/Wire/Compile.hs` (strict projection port admission, `WireExecutorPortsMismatch`)
- Tests: `test/Cortex/Wire/CompileSpec.hs`
  (`allows a strict registered executor projection with matching ports`),
  `test/Cortex/Wire/RuntimeSpec.hs` (declared output-port wrapping and validation)
- Theory/proof: none

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0014 - Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0023 - CorePure Expression Surface](./0023-corepure-expression-surface.md)
- [Wire Configured Executors and Execution Boundary Reference](../Reference/Wire/configured-executors-and-execution-boundary.md)
