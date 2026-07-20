---
title: "ADR 0095 — Wire Single-Record Executor Boundary"
description:
  "Simplifies node clauses and executor invocation around one normalized record argument, node-owned
  metadata, and registry-owned executor contracts."
sidebar:
  label: "0095. Wire executor boundary"
  order: 95
status: accepted
date: 2026-07-19
superseded_by: null
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/style.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
---

# ADR 0095 — Wire Single-Record Executor Boundary

## Status

Accepted and implemented as an immediate breaking grammar and ABI migration. This ADR supersedes the
node-clause and configured-executor surfaces in ADRs 0022, 0024, 0025, and 0030.

## Context

Wire previously split an executor invocation into a configuration record and a parenthesized input.
That made the executor boundary look like two parameter systems, encouraged compiler controls to
leak into executor data, and made reusable configured-executor values a second authority form.
Port-only clauses also required punctuation despite already having structural delimiters.

## Decision

`<-`, `->`, and `=` delimit node boundary clauses. Port-only declarations have no semicolon; pure
output equations and executor bodies retain their terminating semicolon.

The canonical authored executor boundary is one record. `payload` is the automatic scalar wrapper
field and `cfg` is the conventional location for executor-specific configuration. Normalization is a
compile-time structural decision. Binding time is then declared by the executor projection and
proved from expression dependencies; source position or literal syntax does not decide it.

An executor invocation is an authority followed by zero or one bare CorePure expression:

```wire
node source -> result: Result = @read;
node log <- result: Result = @log result;
node act <- result: Result = @action { payload = result; cfg = { mode = "safe"; }; };
```

The boundary has three phases. During module elaboration the compiler normalizes the authored
argument expression syntactically; at node ingress the runtime evaluates that already-normalized
expression; the host binding then receives the validated result. Normalization is decided from the
authored argument expression, not from the evaluated value:

- no argument becomes `{}`;
- a record literal is passed unchanged;
- any other expression — including a reference whose value is a record — becomes
  `{ payload = value; }`.

Deciding on the authored expression keeps the host-visible record shape statically known at compile
time rather than dependent on runtime values. The runtime never normalizes again.

One authoritative `argument_shape` owns both value shape and the total binding-time partition. A
top-level property may declare `x-cortex-binding-time = "admission"`; an absent annotation means
`ingress`. The compiler derives the closed admission schema and residual ingress schema, so a field
cannot occur in two independently maintained shapes or fall between them.

```toml
argument_shape = { schema = { type = "object", required = ["profile", "maxTokens", "payload"], additionalProperties = false, properties = { profile = { type = "string", x-cortex-binding-time = "admission" }, maxTokens = { type = "number", x-cortex-binding-time = "admission" }, payload = { type = "string" } } } }
```

Admission fields must be port-closed and executable by the deterministic static CorePure evaluator.
They are evaluated and validated during admission, recorded as `staticArgument`, and specialized out
of the residual record. Effects, host observations, secrets, nondeterminism, unsupported operations,
and deployment values do not become static merely because no port name occurs syntactically.

`let ... in`, module `let`, and node `where` remain ordinary stage-polymorphic lexical bindings. A
binding inherits the dependencies of its right-hand side and the consumer obligation is checked at
the field. Factoring an expression into a binding therefore cannot change its phase. A violation
reports the dependency chain, for example
`static field profile <- binding selected <- runtime port prompt`.

`payload` is reserved for automatic wrapping. `cfg` is an executor-schema convention, not a
language-wide field. Executor projections and package manifests expose `argument_shape`; the runtime
validates the evaluated record against that shape before invoking the binding and passes the same
value to it unchanged.

Executor authorities are bare `Executor` values. Configured-executor values and the
`ConfiguredExecutor` kind/form class are removed. Strict registries own the exact executor port and
contract projection; permissive compilation supplies no proof.

Compiler-owned settings move to a statically evaluable node metadata record:

```wire
node publish with { timeout = 30; artifactKind = "report"; to = reports; }
  <- report: Report
  = @artifact.store report;
```

Here, static and dynamic describe evaluation phases, not two different record types:

- The `with` record is evaluated during module elaboration, before graph admission. It may contain
  literals and references to module-level values that the compiler can fully evaluate. It may not
  reference node input ports, `where` locals, runtime results, or host state.
- These fields must be static because they can select the compiled node category and alter
  admission, scheduling, retry/timeout policy, budgets, memory strategy, artifact routing, or signal
  behavior. The runtime cannot discover or revise those facts after the graph has been admitted.
- Admission-marked executor fields are evaluated and specialized during admission. Every unmarked
  field remains a runtime ingress adapter and may reference consumed ports, module-level CorePure
  values, and `where` bindings. At ingress, the runtime evaluates the residual record, validates it
  against the derived ingress schema, and invokes the host binding with that exact value.

For example, `artifactKind` and `to` above are static compiler facts, while `report` is the dynamic
value consumed when the node runs. Only the documented compiler-control fields are accepted in
`with`. Executor-specific data belongs in the executor argument, conventionally below `cfg`.

This ADR keeps authored port labels and contracts explicit. Inferring them from strict executor
projections is deferred to the feature tracker rather than included in this ABI migration.

CorePure record inheritance accepts a source expression:

```wire
{ inherit (x) payload cfg; }
```

This lowers to `payload = x.payload; cfg = x.cfg;`.

`*` remains solely the finite-product scatter/gather adapter. Duplication is expressed by pure
output equations with fresh labels. The formatter emits eligible one-input/one-output nodes on one
line when they fit within 100 columns and otherwise keeps topology-first multiline layout.

## Consequences

- Static evaluation and PureWire runtime evaluation remain separate concepts. An unannotated
  constant field is still ingress data; an admission annotation is a consumer obligation, not node
  metadata or a claim that the executor node itself runs at compile time.
- All old parenthesized calls, split config/call syntax, semicolon-delimited port-only clauses,
  configured-executor parameter classes, and `config_shape` manifest fields are errors.
- Compiled executor metadata stores `argument`; pure-node internal evaluator metadata continues to
  use its separate `config` representation.
- Parser, formatter, tree-sitter, package manifests, capability projections, host bindings,
  examples, and documentation must move together in one release.

## Traceability

- Feature keys: `wire.single_record_executor_boundary`
- Production: `src/Cortex/Wire/{Syntax,Parser,Compile,Format,Executor,Runtime}.hs`
- Package/capability: `src/Cortex/Wire/Package/Manifest.hs`,
  `src/Cortex/Capability/{Executor,Catalog/AdmissionProjection}.hs`
- Editor grammar: `editors/tree-sitter-wire/`
- Tests: `test/Cortex/Wire/{Parser,Compile,Format,Package,Runtime}Spec.hs`,
  `test/Cortex/Capability/CatalogSpec.hs`
