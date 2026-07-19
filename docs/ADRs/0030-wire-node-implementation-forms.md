---
title: "ADR 0030 - Wire Node Implementation Forms"
description:
  "Adds node-level executor bodies for zero-output and multi-output external executors while keeping
  pure computations as per-output equations."
sidebar:
  label: "0030. Node implementation forms"
  order: 30
status: superseded
date: 2026-04-29
superseded_by: docs/ADRs/0095-wire-single-record-executor-boundary.md
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0026-wire-failure-taxonomy.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
---

# ADR 0030 - Wire Node Implementation Forms

## Status

Proposed - extends ADR 0022's clause grammar so ADR 0024's empty output-boundary rule has an
authoring surface and external executors are not forced into per-output equations.

## Context

ADR 0022 defines the next node clause grammar around per-output RHS equations:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = accepted;
```

That is the right shape for CorePure residue, because each output port naturally owns the expression
that computes its value.

External executors have a different shape. An executor invocation is the implementation body behind
the whole node boundary. It may have:

- zero outputs, such as an artifact/logging sink;
- one output, such as an ordinary LLM classifier;
- several outputs, such as a provider call that returns a typed result plus metadata.

ADR 0024 already says empty output boundaries are valid arity, not source/sink roles. But ADR 0022's
grammar still requires at least one output equation, and executor invocation currently appears only
on an output RHS. That leaves no syntax for zero-output executors and gives multi-output external
executors no single place to attach their implementation.

## Decision

Wire should distinguish two node implementation forms:

1. **Output-equation nodes** for CorePure computations.
2. **Node-body executor nodes** for external executor invocations.

The target grammar is:

```ebnf
node_decl       ::= node <name>
                    (input_clause ;)*
                    (pure_equations | executor_body | single_output_executor_shorthand)
                    (where_clause)?           -- per ADR 0031

input_clause    ::= <- <name> : <Type>

pure_equations  ::= (pure_output_clause ;)+
pure_output_clause
                ::= -> <name> : <Type> = <corepure-expr>

executor_body   ::= (output_decl ;)* = <executor_call> ;
output_decl     ::= -> <name> : <Type>

single_output_executor_shorthand
                ::= -> <name> : <Type> = <executor_call> ;

executor_call   ::= @<executor> (<expr>)
                  | @<executor> { <config> } (<expr>)
                  | <configured_executor_name> (<expr>)
```

The earlier `let_block` production - `let <bindings> in` between input clauses and the body - is
removed. Node-local CorePure intermediates are introduced via the trailing `where <record-expr>;`
clause defined in [ADR 0031](./0031-wire-binding-forms-and-where-clauses.md).

In this form, output declarations state the node's typed output boundary, while the executor body
states the implementation behind that entire boundary.

ADR 0039 names the semantic normal form behind this syntax: the executor argument is ingress
adaptation from input ports to one body argument, the executor call is the local body, and output
projection/validation is egress adaptation back to declared output ports.

### Pure Output Equations

Pure computations remain per-output equations:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = accepted;
  -> rejected: RejectedSet = rejected;
  where let
    accepted = evidence.items |> filter (x: x.score >= 0.7);
    rejected = evidence.items |> filter (x: x.score < 0.7);
  in
  { accepted = accepted; rejected = rejected; };
```

The declared output label, contract, and expression stay visibly tied together. A pure node with no
outputs is not useful in the first slice and should be rejected. Side effects, logging, artifact
writes, and other no-output behavior belong to external executor bodies, not to CorePure.

### Node-Level Executor Bodies

External executors use a node-level body:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = @review.analyze (evidence);
```

The executor projection must match the declared input and output boundary. On success, the executor
emits a `WireValueSet` keyed by the declared output port labels. If the projection or runtime result
does not match those labels and contracts, the failure is classified by ADR 0026.

Configured executor values from ADR 0025 apply in the same body position:

```wire
let analyst = @review.analyst { temperature = 0.2; };

node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = analyst (evidence);
```

### Zero-Output Executors

A zero-output executor body has no output declarations:

```wire
node logEvent
  <- event: Event;
  = @artifact.log (event);
```

Successful execution materializes completion with an empty output set. It does not create a fake
unit output, and it does not make the node a special sink category. It is just an executor node with
an empty output boundary.

### Multi-Output Executors

A multi-output external executor declares every output port before the body:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  -> usage: UsageMetadata;
  = @review.analyzeWithUsage (evidence);
```

The executor must produce both declared outputs or fail with a typed executor/output-validation
failure. Partial success is not materialized as a valid node result.

### Input Argument Shape

The executor call takes one CorePure expression as its input argument:

- for one input port, authors usually pass that port value directly;
- for several input ports, authors pass a record whose fields match the input port labels;
- for zero input ports, authors pass an empty record.

```wire
node compare
  <- baseline: Report;
  <- candidate: Report;
  -> result: Comparison;
  = @review.compare ({ baseline = baseline; candidate = candidate; });

node seed
  -> request: Request;
  = @artifact.seed ({});
```

This keeps executor calls first-order and avoids inventing unit syntax in this slice.

### Single-Output Shorthand

The per-output external RHS from ADR 0022 remains a single-output shorthand:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord = @review.analyze (evidence);
```

It desugars to the node-level body:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = @review.analyze (evidence);
```

The shorthand is valid only when the node has exactly one output clause and that RHS is an external
executor call. Zero-output and multi-output external executors must use the node-level body form.

## Alternatives considered

- **Defer zero-output authoring syntax.** Rejected because ADR 0024 makes empty output boundaries a
  valid topology shape, and implementation will otherwise reintroduce fake outputs or special sink
  roles.
- **Use per-output executor RHSs for every external executor.** Rejected because it has no place for
  zero-output bodies and duplicates one executor invocation across multi-output nodes.
- **Represent zero-output executors with a unit output.** Rejected because it changes the typed
  boundary and creates a payload only to satisfy grammar.
- **Move all pure computations to node-level bodies.** Rejected because pure output equations are
  legible precisely because each output owns its expression.
- **Reject the single-output external shorthand.** Rejected for now because existing examples and
  the simple common case stay readable when the shorthand is defined as desugaring.

## Consequences

### Positive

- ADR 0024's empty-boundary rule has an authoring surface.
- External executor authority attaches to the node implementation body, matching the topology model.
- Multi-output external executors have one implementation site and one validation boundary.
- Pure output equations keep their port-local readability.

### Negative

- The parser needs two node implementation forms.
- Authors must distinguish pure output equations from external executor bodies.
- Multi-input executor calls need explicit record packing in the first slice.

### Obligations

- Amend ADR 0022 and Wire grammar docs to include node-level executor bodies.
- Add parser tests for zero-output, single-output shorthand, and multi-output executor bodies.
- Add admission tests that executor projections match the declared full node boundary.
- Add runtime tests that zero-output success materializes an empty output set.
- Add output-validation tests that multi-output external executors either produce every declared
  output or fail.
- Update tree-sitter grammar and editor corpus examples.

## Traceability

- Feature keys: `wire.node_implementation_forms`
- Public surface: `Cortex.Wire`, [Wire Grammar](../Reference/Wire/grammar.md)
- Implementation: `src/Cortex/Wire/Syntax.hs` (`NodeBody` = `NodeBodyPure` | `NodeBodyExecutor`,
  `ExecutorCall`), `src/Cortex/Wire/Parser.hs` (`nodeImplementationBody`, `pureImplementation`,
  `singleOutputExecutorShorthand`, `executorImplementation`), `src/Cortex/Wire/NodeBoundary.hs`
  (`CorePureBody`, `ExecutorBody`, zero-output `ArtifactBody` / `SignalBody`)
- Tests: `test/Cortex/Wire/ParserSpec.hs` (`parses single-output external shorthand`,
  `parses multi-output executor bodies`, `parses zero-output executor bodies`),
  `test/Cortex/Wire/CompileSpec.hs`
  (`compiles a zero-output executor body as a node with an empty output boundary`)
- Theory/proof: none

## Related

- [ADR 0014 - Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0026 - Wire Failure Taxonomy](./0026-wire-failure-taxonomy.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
