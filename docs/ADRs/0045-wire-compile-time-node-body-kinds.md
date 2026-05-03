---
title: "ADR 0045 - Wire Compile-Time Node-Body Kinds"
description:
  "Adds hygienic compile-time node-body kinds that elaborate repeated typed node bodies into
  ordinary Wire node declarations before graph admission."
sidebar:
  label: "0045. Node-body kinds"
  order: 45
status: proposed
date: 2026-05-03
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
---

# ADR 0045 - Wire Compile-Time Node-Body Kinds

## Status

Proposed - this ADR records the intended Wire metaprogramming boundary before implementation. The
initial motivating example is the repeated quantum-gate node shape in
`examples/wire/quantum-eraser-experiment.wire`.

## Context

Wire currently has several reuse mechanisms:

- configured executor values reuse executor identity and static config;
- module-level `let` binds ordinary data, configured executors, graph values, and CorePure helpers;
- graph composition reuses already-authored graph fragments;
- file-return selection lets a host compile a chosen graph value from a multi-graph file.

Those mechanisms deliberately do not manufacture graph vertices. ADR 0024 and ADR 0025 require a
configured executor value to remain inert until it is placed behind an explicit typed node
declaration. The node declaration is where Wire records vertex identity, typed input and output
ports, provenance, and admission obligations.

This leaves real authoring noise in domains with many structurally identical nodes. Quantum circuit
authoring is the clearest current example:

```wire
node eraser0_screen_h
  <- screen: Qubit;
  -> screen: Qubit = @quantum.h {} (screen);

node eraser0_marker_h
  <- marker: Qubit;
  -> marker: Qubit = @quantum.h {} (marker);
```

The repeated `Qubit -> Qubit` boundary is not semantically wrong. It is also not just cosmetic:
removing it by making configured executors into partial graph nodes would erase the very boundary
that Wire uses for graph typing and runtime provenance. The missing feature is a compile-time way to
author the repeated declaration pattern once while preserving the expanded graph as ordinary nodes.

## Decision

Wire should add **compile-time node-body kinds**.

A node-body kind is a source-level declaration that supplies the typed boundary and body of one
node, but not the node head. It is instantiated only by an ordinary `node <name> = ... ;`
declaration. During elaboration, that declaration expands into one ordinary `node` declaration whose
name comes from the call site and whose boundary/body comes from the kind.

Kind expansion happens before graph composition, file-return selection, admission, Pulse execution,
or rewrite materialization. After expansion, the rest of Cortex sees the same explicit typed nodes
it would have seen if the author had written them by hand.

The initial feature is intentionally narrow:

- a kind body is a node-definition fragment: input clauses, output/body clauses, and an optional
  `where` clause, but no `node` head;
- every instantiated kind expands to exactly one node declaration;
- kind parameters are statically classified compile-time parameters only;
- the initial parameter classes are `PortLabel`, `Contract`, `Value`, and `ConfiguredExecutor`;
- kind applications are valid only in `node <name> = <kind_application>;` position;
- kind applications are not declarations by themselves, not CorePure expressions, and not graph
  expressions;
- a kind declaration is not a graph value and cannot appear in file-return position;
- kind expansion must be deterministic and finite.

Illustrative syntax:

```wire
let h_gate = @quantum.h {};

kind one_qubit_gate(label: PortLabel, gate: ConfiguredExecutor) =
  <- label: Qubit;
  -> label: Qubit = gate (label);

node eraser0_screen_h = one_qubit_gate(screen, h_gate);
node eraser0_marker_h = one_qubit_gate(marker, h_gate);
```

The exact token spelling belongs in the grammar reference and implementation patch. The semantic
commitment is the important part: a kind application elaborates to an ordinary node declaration with
an ordinary typed boundary.

### Expansion phase

Kind expansion is a static elaboration phase between parsing/import resolution and ordinary Wire
graph lowering. Expansion may use only source data already available at compile time:

- literal values;
- closed module-level pure data;
- configured executor values;
- imported or locally declared kind definitions;
- registry-known executor and contract names.

Expansion may not depend on runtime input ports, executor results, host IO, time, randomness, model
calls, Pulse state, or materialized artifacts. A kind cannot inspect or modify the runtime graph.

### Identity and hygiene

Expanded nodes must have stable source identities. The node name is always supplied by the
instantiating `node <name> = ... ;` declaration, never by a kind parameter or generated-name rule. A
duplicate node name after kind expansion is the same compile-time error as a duplicate handwritten
node.

Kind holes are hygienic:

- a hole may bind only the syntactic class declared by the kind parameter;
- port-label holes cannot accidentally capture value names;
- configured-executor holes cannot be called from CorePure;
- node-local `where` names inside the kind body are scoped as if the expanded node had been
  handwritten at the call site.

Diagnostics must point to both the kind application and the kind body span that produced the
expanded form.

### Authority

Kinds do not grant authority. They may reference only executor and contract names already available
through the normal registry, `use`, import, or configured-executor surfaces. Passing a configured
executor value into a kind does not make that value a graph vertex; the expanded node declaration
remains the vertex.

This preserves ADR 0010's closed-authority rule and ADR 0024's typed executor-node interface.

### Relationship to graph forms

This ADR does not add general graph forms, loops, generators, or higher-order graph functions. Those
are plausible future features, especially for parameterized sweeps such as the quantum eraser phase
table, but they add another decision: how a source abstraction expands multiple nodes and returns a
graph value with a stable boundary. ADR 0046 handles that graph-valued structural abstraction
separately.

The first slice solves the repeated node-boundary problem without changing graph composition
semantics.

## Alternatives considered

- **Use configured executor values only.** Rejected because they remove repeated executor config but
  still require every typed node boundary to be handwritten.
- **Restore partial executor graph nodes.** Rejected because ADR 0024 and ADR 0025 intentionally
  make configured executor values inert. A graph vertex must have an explicit typed node boundary.
- **Add unrestricted textual macros.** Rejected because textual expansion would be hard to keep
  hygienic, authority-free, deterministic, and source-span aware.
- **Use CorePure lambda syntax for kinds.** Rejected because CorePure lambdas produce values, while
  kinds produce structural node-definition fragments. Reusing lambda syntax would imply partial
  application, expression-position use, and runtime value capture that v1 kinds do not have.
- **Use `template` as the declaration keyword.** Rejected because the settled surface is closer to a
  named structural kind than to a textual macro or value-level function.
- **Add graph kinds first.** Rejected for the initial slice because multi-node expansion also has to
  settle generated graph boundaries, name allocation, and import/export semantics.
- **Teach the quantum executor runner special gate shorthand.** Rejected because the repetition is a
  Wire authoring problem, not a quantum-backend problem.

## Consequences

### Positive

- Repeated typed node declarations become compact without weakening graph admission.
- Expanded artifacts still contain ordinary nodes with ordinary ports, edges, and executor bodies.
- Quantum examples can dogfood the feature while staying inside Cortex's general Wire semantics.
- Kind expansion gives future tooling a clear place to attach origin metadata.

### Negative

- Wire gains a new declaration form and a static elaboration pass.
- Parser, formatter, tree-sitter, and reference docs must learn kind declarations and applications.
- Diagnostics become more complex because errors may arise in generated nodes.
- The language must preserve separate syntactic classes for names, labels, contracts, values, and
  configured executors.

### Obligations

- Add parser and static elaboration support for kind declarations and kind applications.
- Reserve `kind` as a Wire keyword.
- Add the `node <name> = <kind_application>;` node-declaration form.
- Add a deterministic kind-expansion pass before ordinary graph lowering.
- Reject runtime-dependent kind arguments.
- Reject bare kind applications outside node-instantiation position.
- Reject duplicate expanded node names.
- Record kind-origin metadata in compiled artifacts or debug output.
- Add tests for hygiene, duplicate detection, source spans, configured-executor parameters, and
  selected file returns after expansion.
- Update the Wire grammar reference, module/import reference, and tree-sitter grammar.
- Prove or document the preservation claim: after kind expansion, all existing Wire graph, port,
  authority, and runtime invariants apply unchanged to the expanded program.

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0031 - Wire Binding Forms and Node Where Clauses](./0031-wire-binding-forms-and-where-clauses.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
