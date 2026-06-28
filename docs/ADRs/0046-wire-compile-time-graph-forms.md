---
title: "ADR 0046 - Wire Compile-Time Graph Forms"
description:
  "Adds hygienic compile-time graph forms that instantiate reusable graph fragments with stable
  scoped node identities."
sidebar:
  label: "0046. Graph forms"
  order: 46
status: proposed
date: 2026-05-04
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0045-wire-compile-time-node-body-kinds.md
---

# ADR 0046 - Wire Compile-Time Graph Forms

## Status

Proposed - this ADR defines the graph-fragment metaprogramming boundary that composes with ADR
0045's node-body kind slice. The motivating example is the repeated nine-circuit structure in
`examples/wire/quantum-eraser-experiment.wire`.

## Context

ADR 0045 adds node-body kinds. A kind abstracts the typed boundary and body of one node while
preserving the rule that every vertex is introduced by a `node <name>` declaration. This removes the
repeated `Qubit -> Qubit` authoring noise in quantum examples, but it does not solve the larger
repetition: whole graph arms, phase variants, marker overlays, and measurement tails are still
written repeatedly.

Wire already has graph values and graph composition:

```wire
let open_phase_0 =
  prepare
    => split
    => recombine;
```

Those bindings reuse graph values that have already been authored. They do not parameterize graph
construction and they do not manufacture fresh internal vertices. Parameterized quantum sweeps need
both: the same structural circuit shape should be instantiated several times with different static
phase values, and each instantiation should contain distinct graph vertices.

The missing feature is a compile-time abstraction over graph construction, not a runtime function
and not a textual macro.

## Decision

Wire should add **compile-time graph forms**.

A graph form is a source-level declaration that elaborates to a graph value. A form may accept
statically classified parameters, declare local nodes and local bindings, and end with a graph
expression that is the instantiated fragment's value. Form expansion happens before ordinary graph
lowering, file-return selection, admission, Pulse execution, or rewrite materialization.

Illustrative syntax:

```wire
let quantum_h = @quantum.h {};

kind qubit_gate(label: PortLabel, gate: ConfiguredExecutor) =
  <- label: Qubit;
  -> label: Qubit;
  = gate(label);

kind phase_gate(label: PortLabel, angle: Value) =
  <- label: Qubit;
  -> label: Qubit = @quantum.rz { angle = angle; } (label);

form open_arm(phase: Value) = {
  node split = qubit_gate(screen, quantum_h);
  node phase_shift = phase_gate(screen, phase);
  node recombine = qubit_gate(screen, quantum_h);

  split => phase_shift => recombine;
};

let open_phase_0 = open_arm(0.0);
let open_phase_1_4 = open_arm(1.5707963267948966);
let open_phase_1_2 = open_arm(3.141592653589793);
```

The exact grammar belongs in the Wire grammar reference and implementation patch. The semantic
commitment is the important part: each bound form instantiation elaborates to an ordinary graph
value made of ordinary nodes and ordinary graph composition.

### Form body

A form body is a local compile-time declaration block ending in one graph expression. The initial
body surface should admit:

- local `node` declarations, including `node <name> = <kind_application>;`;
- local `let` bindings for graph values, configured executor values, closed pure data, and CorePure
  helper expressions;
- a final graph expression, terminated by the closing form body, that becomes the form result.

The body does not admit runtime executor results, host IO, time, randomness, model calls, Pulse
state, or materialized artifacts during expansion. A form cannot inspect the runtime graph.

The initial parameter classes are `Value`, `Graph`, `PortLabel`, `Contract`, and
`ConfiguredExecutor`. A form may reference kind declarations in source scope, but kinds are not
first-class form parameters in the first slice.

### Application and identity

In the first slice, a form application must be bound by a graph binding. Module-level bindings are
the exported/user-facing surface:

```wire
let concrete_name = some_form(args);
export let exported_name = some_form(args);
```

The binding name supplies the stable identity prefix for all nodes declared inside the form body.
For example, `let open_phase_0 = open_arm(0.0);` scopes the local `split` node under the
`open_phase_0` instantiation. The concrete rendering of that scoped identity is an implementation
detail, but it must be deterministic, source-stable, and distinct from nodes produced by any other
form instantiation.

Inline, unbound form applications in graph position are rejected in v1 because they have no source
name from which to derive a stable identity prefix:

```text
# Rejected in v1.
open_arm(0.0) => measure;
```

Authors can bind the form first and then compose it normally:

```wire
let open_phase_0 = open_arm(0.0);

open_phase_0 => measure
```

Nested form instantiations inherit a hierarchical prefix from their containing instantiation and
local binding name:

```wire
form outer(phase: Value) = {
  let inner_graph = inner(phase);

  inner_graph;
};
```

Recursion is rejected in v1.

### Capture and sharing

Names declared inside a form are fresh per instantiation. Names captured from the surrounding module
scope are shared.

This means a form can deliberately reuse an outer graph value:

```wire
let hardware_config = ibm_runtime_config;

form run_with_config(phase: Value) = {
  node phase_shift = phase_gate(screen, phase);

  hardware_config => phase_shift;
};
```

If the author wants fresh nodes per instantiation, those nodes must be declared inside the form
body. This keeps sharing explicit and makes accidental cloning visible in source.

### Boundary

A form's boundary is the boundary of its final graph expression after expansion and graph
composition. This ADR does not add separate boundary/interface declarations such as `shape` or
`mold`; those may become useful later, but graph forms do not require them.

### Authority and provenance

Forms do not grant authority. They may reference only executor, contract, kind, value, and graph
names already available through normal Wire source scope, registry `use`, import, or configured
executor surfaces.

Expanded artifacts should record enough origin metadata to connect an expanded node back to:

- the form declaration;
- the bound form application;
- the local declaration inside the form body.

Diagnostics must point to both the application site and the form body span that produced the
expanded node or graph error.

## Alternatives considered

- **Fold graph forms into ADR 0045 node-body kinds.** Rejected because forms introduce multi-node
  expansion, fresh scoped identities, graph-valued results, and capture rules that node-body kinds
  deliberately avoid.
- **Use CorePure lambda syntax for graph construction.** Rejected because CorePure lambdas are
  runtime value functions, while forms are compile-time structural elaborations. Reusing `x: ...`
  would imply partial application, higher-order use, and runtime capture that this feature does not
  provide.
- **Use `frag` as the keyword.** Rejected because `frag` is clear but overly tied to the idea of a
  partial graph. `form` better communicates reusable structural construction while still avoiding
  the overloaded word `graph`.
- **Use `shape` or `mold` as the keyword.** Rejected for this feature because those words are better
  reserved for future boundary/interface constraints. A form constructs topology; a shape or mold
  would constrain an exposed boundary.
- **Allow unbound inline applications with an explicit prefix argument.** Rejected for v1 because
  identity is source structure, not ordinary data. Binding first is more explicit and keeps prefix
  allocation out of the value parameter list.
- **Add static graph conditionals and loops at the same time.** Rejected because conditionals and
  iteration add separate proof obligations: static discriminant checking, branch-boundary equality,
  and termination. Forms should land first as finite non-recursive instantiation.

## Consequences

### Positive

- Repeated multi-node graph fragments become compact without weakening admission.
- Quantum sweeps can express their repeated circuit shape directly in Wire instead of relying on
  external harnesses or duplicated files.
- Forms compose with existing graph values, `=>`, `<>`, file-return selection, and exported graph
  bindings after expansion.
- Freshness and sharing are visible in source: local declarations are fresh, captured declarations
  are shared.

### Negative

- Wire gains another declaration form and a second static elaboration surface after node-body kinds.
- Parser, formatter, tree-sitter, reference docs, and diagnostics must handle local form bodies.
- Artifact provenance becomes more complex because expanded nodes may come from nested form
  instantiations.
- V1 rejects inline form applications, which is slightly less terse but avoids unstable generated
  identities.

### Obligations

- Reserve `form` as a Wire keyword.
- Add parser and static elaboration support for form declarations and bound form applications.
- Reject form recursion and unbound inline form applications in v1.
- Require form arguments to be statically resolvable and class-compatible.
- Generate deterministic scoped identities for local nodes inside each bound instantiation.
- Preserve graph boundary, port matching, executor authority, and file-return semantics after form
  expansion.
- Add tests for fresh instantiations, deliberate outer capture, nested forms, duplicate local names,
  runtime-dependent argument rejection, file-return selection, and provenance.
- Update the Wire grammar reference, module/import reference, tree-sitter grammar, and quantum
  eraser example once the implementation lands.
- Prove or document the preservation claim: after form expansion, all existing Wire graph, port,
  authority, and runtime invariants apply unchanged to the expanded program.

## Traceability

- Feature keys: `wire.graph_forms`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/grammar.md`
- Implementation: `src/Cortex/Wire/Parser.hs` (`FormDecl`/`FormParam`/`FormItem`/`FormApplication`,
  the `formDecl` parser, and the `expandFormBinding` elaboration pass over the `esForms` scope that
  lowers a bound form application to ordinary scoped nodes and a graph value)
- Tests: `test/Cortex/Wire/ParserSpec.hs`, `test/Cortex/Wire/CompileSpec.hs`
- Theory/proof: none (graph-form expansion is not yet separately mechanized; the proof-status
  derived-form row covers `make`/`makeEach` only)

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0031 - Wire Binding Forms and Node Where Clauses](./0031-wire-binding-forms-and-where-clauses.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0045 - Wire Compile-Time Node-Body Kinds](./0045-wire-compile-time-node-body-kinds.md)
- [Chapter 04 - Graph and Circuit](../Architecture/04-graph-and-circuit.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
