---
title: "ADR 0095 — Wire Single-Record Executor Boundary"
description:
  "Simplifies node clauses and executor invocation around one normalized record argument, node-owned
  metadata, and registry-owned executor contracts."
sidebar:
  label: "0095. Wire executor boundary"
  order: 95
status: accepted
date: 2026-07-18
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

An executor invocation is an authority followed by zero or one bare CorePure expression:

```wire
node source -> result: Result = @read;
node log <- result: Result = @log result;
node act <- result: Result = @action { payload = result; cfg = { mode = "safe"; }; };
```

Before host invocation the compiler/runtime boundary normalizes the argument. Normalization is
decided from the authored argument expression, not from the evaluated value:

- no argument becomes `{}`;
- a record literal is passed unchanged;
- any other expression — including a reference whose value is a record — becomes
  `{ payload = value; }`.

Deciding on the authored expression keeps the host-visible record shape statically known at compile
time rather than dependent on runtime values.

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
- The executor argument is a CorePure expression evaluated at node ingress. It may reference the
  node's consumed input ports and `where` bindings. Only after that evaluation does the runtime
  normalize the value to one record, validate `argument_shape`, and invoke the host binding.

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

- All old parenthesized calls, split config/call syntax, semicolon-delimited port-only clauses,
  configured-executor parameter classes, and `config_shape` manifest fields are errors.
- Compiled executor metadata stores `argument`; pure-node internal evaluator metadata continues to
  use its separate `config` representation.
- Parser, formatter, tree-sitter, package manifests, capability projections, host bindings,
  examples, and documentation must move together in one release.

## Traceability

- Feature keys: `wire.single_record_executor_boundary`
- Production: `src/Cortex/Wire/{Syntax,Parser,Compile,Format,Executor,Runtime}.hs`
- Package/capability: `src/Cortex/Wire/Package/Manifest.hs`, `src/Cortex/Capability/Executor.hs`
- Editor grammar: `editors/tree-sitter-wire/`
- Tests: `test/Cortex/Wire/{Parser,Compile,Format,Runtime}Spec.hs`
