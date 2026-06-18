---
title: "ADR 0039 - Wire Node Boundary Transform Normal Form"
description:
  "Defines the semantic normal form for admitted Wire nodes as ingress adapter, local body, and
  egress adapter between typed port environments."
sidebar:
  label: "0039. Node boundary normal form"
  order: 39
status: proposed
date: 2026-05-01
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/configured-executors-and-execution-boundary.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0039 - Wire Node Boundary Transform Normal Form

## Status

Proposed - this ADR names the semantic normal form implicit in the current typed-node surface. It
does not add new Wire syntax by itself.

## Context

Current Wire already has the pieces of a three-phase node model:

- typed input and output ports define the node boundary;
- an executor call takes one CorePure expression argument, so multi-input nodes already author
  ingress packing explicitly;
- `where <record-expr>;` opens node-local CorePure fields into the body scope;
- pure output equations bind declared output ports directly;
- executor nodes declare the full output boundary before a node-level body;
- contract validation and runtime wrapping decide whether produced values satisfy output ports.

The docs also already reject the dangerous alternatives. ADR 0010 and the Graph/Circuit architecture
keep semantic meaning on endpoints rather than edges. ADR 0024 rejects variadic executor context and
says typed ports are the executor interface. ADR 0032 treats boundary obligations, not node
identities, as the planning resource.

What remains implicit is the internal shape of a node. Diagrams usually show only "node with input
edges and output edges", which flattens three distinct obligations:

```text
incoming boundary adapter
  -> node-local computation
  -> outgoing boundary adapter
```

Leaving that shape implicit creates pressure to put adaptation in the wrong place: hidden executor
context, downstream-aware bodies, or programmable edges. It also gives proof work a blunt target
such as "the node is correct" instead of separate ingress, body, egress, and edge obligations.

## Decision

Wire should treat every admitted node as elaborating to **Node Boundary Transform Normal Form**:

```text
input port environment
  -> ingress adapter
  -> local body
  -> egress adapter
  -> output port environment
```

The normal form is semantic. Source syntax may stay compact, but the compiler, reference docs, and
proof model should preserve these phase boundaries when they matter.

### Ingress adapter

The ingress adapter sees the node's input port environment and node-local authority-free CorePure
scope. It prepares the value presented to the local body.

It may:

- pack several input ports into one record or list-valued argument;
- rename fields;
- project or normalize JSON-shaped values;
- compute prompt/config fragments from input values;
- validate deterministic preconditions expressible in CorePure.

The ingress adapter may not create graph topology, name executor authority, inspect downstream
consumers, or receive hidden edge context.

Current executor-call arguments already implement ingress:

```wire
node compare
  <- baseline: Report;
  <- candidate: Report;
  -> result: Comparison;
  = @review.compare ({
    baseline = baseline;
    candidate = candidate;
  });
```

The record expression is the boundary adapter from two typed input ports to one body argument.

### Local body

The local body is the node's computation behind the typed boundary.

Examples:

- a transparent CorePure body for pure computation;
- a registered executor body such as `@review.analyze (...)`;
- a zero-output host-effecting body such as `@artifact.log (...)`;
- a future verified or resource-transforming body.

The body may see:

- the ingress value;
- admitted static config;
- registered authority granted to that executor;
- the declared node boundary schema needed for validation and decoding.

The body must not see arbitrary successor identities, future graph context, or downstream consumer
state. A body that can branch on "who will consume my output" makes node behavior nonlocal and
breaks the endpoint-typed graph model.

### Egress adapter

The egress adapter maps the body result into the node's output port environment. It is responsible
for making declared output obligations explicit before edges consume them.

It may:

- project fields from a structured body result;
- compute derived output values when the computation is authority-free;
- validate that each output satisfies its declared contract;
- wrap runtime values in their contract/provenance envelope;
- split, copy, move, or seal resources according to the declared resource mode, producing fresh
  output port instances when a value is intentionally fanned out.

For current pure nodes, the egress adapter is visible as output equations:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = accepted;
  -> rejected: RejectedSet = rejected;
  where let
    items = evidence.items;
    accepted = items |> filter (x: x.score >= 0.7);
    rejected = items |> filter (x: x.score < 0.7);
  in
  { accepted = accepted; rejected = rejected; };
```

For current executor nodes, egress is implicit in the executor projection (the registered mapping
from executor result to declared output ports) plus runtime output validation: the executor must
produce the declared output set or fail with a typed error. Future syntax may make executor result
projection more explicit, but that is a separate decision.

### Edges

Edges operate only on output and input port environments:

```text
producer output port resource
  satisfies
consumer input port obligation
```

Edges do not run computation. If a shape requires post-processing "on an edge", it should elaborate
to one of:

- producer egress adaptation;
- consumer ingress adaptation;
- an explicit pure node between the producer and consumer.

This preserves the existing invariant that edge meaning lives at endpoints, not on the edge itself.
It also preserves actualized port linearity: one edge consumes one producer output port instance and
produces one consumer input port instance. A closed actualized graph must account for every input
port through exactly one producer edge and every output port through exactly one edge consumer or an
explicit terminal egress, sink, or exported boundary discharge.

## Proof decomposition

The normal form gives proof work sharper targets:

```text
ingress_sound:
  valid input port environment
  -> valid body argument

body_sound:
  valid body argument and admitted authority
  -> valid body result or typed failure

egress_sound:
  valid body result
  -> valid output port environment

edge_sound:
  valid producer output port environment
  -> successor input obligations are satisfied

port_linearity_sound:
  valid actualized port-use witness
  -> every actualized input port has exactly one edge producer
  -> every actualized output port has exactly one edge or terminal-discharge consumer
```

For pure nodes, ingress/body/egress may be transparent enough to prove together. For registered
executors, `body_sound` is registry, certificate, or host-binding territory; Wire can still prove
that the boundary adapters and output validation are the only structural interfaces.

## What this does not decide

This ADR does not add:

- arbitrary edge-local adapters;
- downstream-aware executor bodies;
- implicit fan-in, list aggregation, or context concatenation;
- implicit edge-level fan-out or hidden duplication of one output port instance;
- new executor egress syntax;
- a requirement that all compiler IR immediately use a new public `NodeCore` type.

Those may need later syntax or implementation ADRs. This ADR only fixes the semantic target those
future changes must preserve.

## Alternatives considered

- **Keep the phases implicit** - rejected because it lets hidden context and edge-local adaptation
  re-enter as implementation convenience, and it gives proofs only node-sized obligations.
- **Make edges programmable adapters** - rejected because it violates the Graph/Circuit invariant
  that edges are opaque wiring and endpoint contracts carry meaning.
- **Require all adaptation to be separate pure nodes** - rejected as too noisy for local packing and
  projection. The normal form allows local boundary adapters while keeping them inside the node
  boundary rather than on edges.
- **Let executor bodies inspect successor context** - rejected because it makes node behavior depend
  on graph neighborhood and weakens replay, rewrite, and validation reasoning.
- **Add explicit executor egress syntax immediately** - deferred. The semantic slot is real, but the
  syntax needs separate design around projection, validation, and linear or opaque resources.

## Consequences

### Positive

- Gives Wire one normal form for pure nodes, executor nodes, zero-output nodes, and future verified
  bodies.
- Explains fan-in as ingress adaptation and explicit fan-out as egress adaptation plus port-resource
  rules.
- Keeps edges simple and mechanically checkable.
- Gives Lean and Haskell correspondence work smaller obligations than "node correctness".
- Clarifies that executor authority lives in the local body, while structural adaptation remains at
  the typed boundary.

### Negative

- Adds another semantic layer that docs, compiler comments, and proof obligations must keep distinct
  from authored Wire source.
- Current executor egress remains partly implicit until a later syntax or IR pass exposes projection
  more directly.
- The model will surface cases where existing examples should become explicit pure nodes instead of
  hidden executor prompt or result handling.

### Obligations

- Reference docs should describe executor-call input expressions as ingress adapters.
- Reference docs should describe pure output equations and executor output validation as egress
  adapters.
- ADR 0030 and ADR 0031 should cite this normal form when explaining node bodies and `where`
  clauses.
- ADR 0032 and future resource proofs should place copy, move, and seal obligations in egress or
  port-resource rules, not in edge-local semantics.
- Compiler IR may introduce a private record shaped like
  `input ports + ingress + body + egress + output ports` when implementation work needs the
  distinction.
- ADR 0038 or a successor proof ledger should track theorem targets for ingress, egress, edge
  soundness, and actualized port-use linearity once the Haskell IR exposes suitable witnesses.

## Related

- [../Architecture/04-graph-and-circuit.md](../Architecture/04-graph-and-circuit.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Reference/Wire/grammar.md](../Reference/Wire/grammar.md)
- [../Reference/Wire/contracts-ports-and-matching.md](../Reference/Wire/contracts-ports-and-matching.md)
- [../Reference/Wire/configured-executors-and-execution-boundary.md](../Reference/Wire/configured-executors-and-execution-boundary.md)
- [../Reference/Wire/executors-and-alphabet.md](../Reference/Wire/executors-and-alphabet.md)
- [../Reference/Wire/pure-execution.md](../Reference/Wire/pure-execution.md)
- [0010-wire-closed-authority-and-three-layer-stack.md](0010-wire-closed-authority-and-three-layer-stack.md)
- [0020-wire-pure-output-equations.md](0020-wire-pure-output-equations.md)
- [0021-wire-source-elaborates-to-circuits.md](0021-wire-source-elaborates-to-circuits.md)
- [0024-typed-executor-node-interface.md](0024-typed-executor-node-interface.md)
- [0030-wire-node-implementation-forms.md](0030-wire-node-implementation-forms.md)
- [0031-wire-binding-forms-and-where-clauses.md](0031-wire-binding-forms-and-where-clauses.md)
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md)
- [0038-wire-proof-track-theorem-ledger.md](0038-wire-proof-track-theorem-ledger.md)
