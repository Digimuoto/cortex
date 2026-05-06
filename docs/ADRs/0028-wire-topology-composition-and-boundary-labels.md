---
title: "ADR 0028 - Wire Topology Composition and Boundary Labels"
description:
  "Defines overlay and connect composition for Wire circuits and resolves file-level expression
  port-label behavior."
sidebar:
  label: "0028. Topology composition"
  order: 28
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0028 - Wire Topology Composition and Boundary Labels

## Status

Proposed - resolves the composition and file-level boundary-label questions deferred by ADR 0021.

## Context

ADR 0021 makes post-elaboration circuits the executable target for Wire source, but deliberately
defers topology composition primitives. ADR 0022 reserves `let x = ...` for future composition
expressions.

The next non-trivial multi-node example needs a way to compose named node circuits without hiding
topology inside executor config or prompt text. The same decision must settle what happens to
file-level values such as:

```wire
let greeting = "Hello" ;
```

If such a binding implicitly creates a circuit with an inferred output label, composition becomes
harder to reason about. If it remains a value helper, authors need an explicit way to create
constant circuits.

## Decision

Wire should add two topology composition operators over graph values:

- `<>` for overlay, which places circuits side by side without adding edges;
- `=>` for connect, which overlays two circuits and connects compatible exposed outputs from the
  left circuit to compatible exposed inputs on the right circuit.

```wire
let review = (analystA <> analystB) => reviewer ;
```

Both operators are topology-only. They do not call executors, evaluate CorePure, or create runtime
topology. They lower during elaboration to the graph/circuit overlay and connect operations before
Pulse execution begins.

### Overlay

`lhs <> rhs` forms the parallel composition of two circuits:

- vertices and edges from both operands are retained;
- no new edges are added;
- exposed boundaries are the union of both operands' unconnected boundaries;
- node identity is preserved across references.
- reject the composition if the operands contain the same node identity.

Overlay is the way to express independent entry points, independent exits, and branches that should
coexist before a later connect. It is not a cloning operator. To make several nodes with the same
shape, use node-body kinds, graph forms, or static generation; do not reference the same node twice
in one graph expression.

### Connect

`lhs => rhs` forms directional composition:

- first overlay `lhs` and `rhs`;
- then connect each compatible exposed output/input pair only when both endpoint ports have exactly
  one compatible counterpart across the boundary;
- do not connect outputs from `rhs` back to inputs on `lhs`;
- leave unmatched exposed ports on the composed boundary.
- reject the composition if any output port on `lhs` has more than one compatible input on `rhs`;
- reject the composition if any input port on `rhs` has more than one compatible output on `lhs`.

Compatibility requires the same contract id and compatible payload kind. Labels are exact routing
constraints:

- unlabeled ports match only unlabeled ports;
- labeled ports match only ports with the identical label;
- there is no wildcard label.

Each endpoint port instance is a linear resource. During open composition, unmatched inputs and
outputs remain on the composed boundary. Once an output is connected, that concrete output port
instance may feed exactly one compatible input, and an input may receive exactly one compatible
output. Feeding the same output to multiple inputs or the same input from multiple outputs is a
static topology failure.

Closed actualized graphs must account for both directions exactly once: every input port instance
has one producer edge, and every output port instance has one consumer, either one downstream edge
or one explicit terminal egress, sink, or exported boundary discharge. Multi-consumer use is
expressed by an explicit fan-out, sharing, persistence, broadcast, projection, or record↔ports
adapter node that consumes the source output once and produces fresh output port instances. Packing
several values into one aggregate remains explicit CorePure work or an explicit structural adapter;
`=>` does not perform implicit fan-out, implicit fan-in, aggregation, or duplication.

### Associativity And Precedence

Each operator is left-associative when repeated with itself:

```wire
a => b => c
```

parses as:

```wire
(a => b) => c
```

ADR 0047 amends this ADR's original caution around mixed operators. Current Wire gives `<>` / `,`
tighter precedence than `=>` / `*`, so mixed expressions parse without mandatory parentheses.
Endpoint linearity still decides whether the parsed expression is admitted.

### File-Level Values And Labels

File-level `let` has kinded RHSs:

- ordinary pure-data value;
- delayed CorePure helper expression;
- configured executor value from ADR 0025;
- graph value produced by a node or composition expression.

The binding name is never automatically an output port label.

```wire
let greeting = "Hello" ;
```

binds an ordinary pure-data value. It does not create a circuit, an anonymous output, or an output
named `greeting`.

To create a constant circuit, authors use an explicit node with an explicit output port:

```wire
node greeting
  -> text: String = "Hello" ;
```

The circuit's boundary label is `text`, not the file-level binding name. This keeps labels tied to
ports rather than to source variable names.

## Alternatives considered

- **Use `>>>` as the primary composition operator.** Rejected for the first slice because Wire
  already needs both overlay and directional connect, and `=>` maps directly to port matching.
- **Let file-level literals become named constant circuits.** Rejected because it makes ordinary
  helper bindings create topology and gives binding names hidden port-label meaning.
- **Let connect perform fan-in aggregation.** Rejected because aggregation is computation and should
  be expressed by an explicit pure node.
- **Let connect duplicate output resources.** Rejected because it hides fan-out in topology matching
  and breaks actualized port-instance linearity. Duplication must be expressed by an explicit
  adapter or generated node family that consumes the source once and produces fresh output ports.
- **Define precedence between `<>` and `=>` immediately.** Rejected in this first slice because
  parentheses were cheaper than committing a precedence rule before composition-heavy examples
  existed. ADR 0047 later amends this decision.

## Consequences

### Positive

- Multi-entry, multi-exit, branch, merge, and review graphs become ordinary topology expressions.
- Composition lowers to existing graph/circuit operations before runtime.
- Port labels remain explicit boundary facts.
- Output-resource linearity aligns Wire composition with the Paper 5 actualized-port semantics.
- File-level ordinary value bindings stay value-level unless their RHS is explicitly a graph
  expression.

### Negative

- The parser and kind checker must distinguish ordinary pure-data, delayed CorePure helper,
  configured executor, and graph expression positions.
- Mixed composition expressions originally required parentheses in the first slice. ADR 0047 later
  replaces that rule with a fixed precedence ladder.
- Authors must write explicit constant nodes instead of relying on implicit literal circuits.
- Authors must write explicit fan-out nodes when one produced value is intended for multiple
  consumers.

### Obligations

- Add parser tests for overlay, connect, associativity, and ADR 0047 mixed-operator precedence.
- Add topology tests for label matching, unmatched boundaries, repeated-node overlay rejection,
  output fan-out rejection, input fan-in rejection, and explicit adapter/fresh-output cases.
- Add lowering tests that composition completes before runtime execution.
- Update grammar docs to remove any implicit file-level output-label behavior.
- Keep list construction and record packing as explicit pure nodes.

## Related

- [ADR 0009 - Rewrite Provenance and Topology Integrity](./0009-rewrite-provenance-and-topology-integrity.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [Chapter 04 - Graph and Circuit](../Architecture/04-graph-and-circuit.md)
- [Wire Contracts, Ports, and Matching Reference](../Reference/Wire/contracts-ports-and-matching.md)
