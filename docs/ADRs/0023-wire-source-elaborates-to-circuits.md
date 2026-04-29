---
title: "ADR 0023 - Wire Source Elaborates to Circuits"
description:
  "Makes circuits the single semantic target for Wire source and relocates CorePure into the
  elaboration phase."
sidebar:
  label: "0023. Source elaboration"
  order: 23
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0022-wire-pure-output-equations.md
  - docs/ADRs/0024-wire-node-clause-grammar.md
  - docs/ADRs/0025-corepure-expression-surface.md
  - docs/ADRs/0026-typed-executor-node-interface.md
  - docs/ADRs/0030-wire-topology-composition-and-boundary-labels.md
---

# ADR 0023 - Wire Source Elaborates to Circuits

## Status

Proposed - this ADR scopes the next Wire phase after pure output equations. If accepted, it
supersedes ADR 0022's decision to defer full Wire-to-circuit unification.

## Context

ADR 0022 made pure output equations legible, but it still treats CorePure mostly as the language
inside `pure (...)`. That keeps the first implementation narrow, but Wire still has two nearby
authoring concepts:

- topology expressions that produce circuits;
- pure expressions that produce values inside a runtime pure executor.

The next phase should make that distinction semantic rather than syntactic. Authors should be able
to write constants, pure helpers, node bodies, and eventually composition expressions in one Wire
source language, while the compiler decides which parts can be reduced before runtime and which
parts must remain as runtime executor vertices.

This must not weaken the graph guarantees from ADR 0005 and ADR 0009. Admission witnesses,
predecessor hashes, and rewrite budgets must still attach to a fixed post-elaboration circuit, not
to runtime-discovered topology.

## Decision

Wire source should elaborate to circuits as its executable semantic target. Expressions in topology
position denote circuits:

- a literal denotes a constant circuit with no inputs and one typed output;
- a `node` declaration denotes a circuit with declared input and output ports;
- future composition expressions compose circuits at the topology layer.

File-level pure helpers remain CorePure value bindings. They do not denote standalone circuits at
the binding site. Instead, they are inlined at each use site and either reduced during elaboration
or embedded in runtime residue according to the dependencies at that use.

CorePure becomes an elaborator phase, not a separate language that exists only inside `pure (...)`.
The compiler uses one CorePure evaluator in two phases:

- **elaboration-time evaluation** for expressions whose dependencies are statically known;
- **runtime pure execution** for residue that depends on input port values.

The same evaluator semantics apply in both phases: deterministic results, typed errors, closed
stdlib, and explicit budget accounting.

### Maximal Static Reduction

The elaborator must reduce every sub-expression it can statically reduce. A binding is folded if and
only if its right-hand side is statically reducible. There is no compiler discretion to leave a
known pure value for runtime.

This rule keeps runtime budget a property of the source program rather than of implementation
choice. A statically reducible expression that fails, such as a bad index or division by zero, fails
during elaboration instead of being deferred.

For the first implementation, maximal static reduction is a compiler-discipline rule. A later
proof-oriented slice should state it formally and connect it to budget conservation.

### Static Graph Boundary

Topology elaboration completes before runtime evaluation begins. After elaboration, the executable
circuit has a fixed vertex set:

- constant outputs are baked into the circuit;
- runtime executor vertices are explicit executor invocations;
- predecessor hashes, rewrite admission witnesses, and budget annotations attach to the
  post-elaboration circuit.

Runtime pure execution may evaluate values, but it may not create new topology.

### Runtime Residue

The first slice should require explicit runtime RHS markers:

```wire
-> port: T = pure (<expr>)
-> port: T = @executor (<expr>)
```

An unmarked output RHS, such as `-> port: T = <expr>`, has a coherent meaning under the elaborator
model, but it introduces inference questions that should be deferred. Initially, authors must state
whether runtime residue is handled by the internal pure evaluator or by a registered external
executor.

### Follow-On Composition Decision

ADR 0030 resolves the file-level expression port-label and topology composition questions deferred
by this ADR. File-level helpers such as `let greeting = "Hello"` remain CorePure value bindings, not
circuits with anonymous or binding-named output ports. Topology composition uses the circuit
operators defined there.

## Alternatives considered

- **Keep CorePure only inside `pure (...)`.** Rejected for the next phase because it preserves an
  artificial split between ordinary Wire constants and pure runtime programs.
- **Infer all runtime pure execution immediately.** Rejected for the first slice because unmarked
  input-dependent RHS forms need syntax, diagnostics, and proof obligations that are separable from
  the explicit `pure (...)` surface.
- **Allow runtime topology creation.** Rejected because it would break the static graph property
  required by rewrite admission and predecessor hashing.

## Consequences

### Positive

- Wire gets one semantic target: source elaborates to circuits.
- Constant and helper expressions use the same evaluator as runtime pure expressions.
- Static reduction becomes visible and testable rather than an implementation convenience.
- Existing graph proofs can continue to quantify over the post-elaboration circuit.

### Negative

- The elaborator must distinguish static dependencies from input-dependent residue.
- Compiler tests must assert maximal static reduction, not just final runtime behavior.
- Some tempting authoring sugar remains deferred until the elaborator boundary is implemented.

### Obligations

- Implement Wire AST to circuit elaboration before runtime evaluation.
- Reject statically known typed CorePure failures during elaboration.
- Add tests that statically reducible bindings are folded.
- Add tests that input-dependent residue becomes explicit runtime executor vertices.
- Keep the runtime executor surface from creating topology.

## Implementation sequence

The immediate implementation slice is:

1. Parse the node and output grammar from ADR 0024.
2. Implement the CorePure expression surface from ADR 0025.
3. Elaborate Wire AST into a post-elaboration circuit, including maximal static reduction.
4. Route runtime `pure (...)` executor vertices through the existing pure executor path.
5. Add the closed stdlib needed by the first pure examples.

Topology composition primitives are specified separately by ADR 0030 and can be implemented after
the node/elaborator slice when multi-node examples require them.

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0022 - Wire Pure Output Equations](./0022-wire-pure-output-equations.md)
- [ADR 0024 - Wire Node Clause Grammar](./0024-wire-node-clause-grammar.md)
- [ADR 0025 - CorePure Expression Surface](./0025-corepure-expression-surface.md)
- [ADR 0026 - Typed Executor Node Interface](./0026-typed-executor-node-interface.md)
- [ADR 0030 - Wire Topology Composition and Boundary Labels](./0030-wire-topology-composition-and-boundary-labels.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
