---
title: "ADR 0025 - Configured Executor Values"
description:
  "Defines reusable configured executor values as inert Wire source values that can be applied only
  in explicit node executor-call positions."
sidebar:
  label: "0025. Configured executors"
  order: 25
status: superseded
date: 2026-04-29
superseded_by: docs/ADRs/0095-wire-single-record-executor-boundary.md
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/executor-authorities-and-execution-boundary.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0012-topological-memory-as-deterministic-graph-query.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
---

# ADR 0025 - Configured Executor Values

## Status

Superseded by ADR 0095, which removes configured-executor values in favor of bare executor authority
references and one explicit argument record.

## Context

ADR 0024 intentionally rejects the older partial-node model. A configured executor value may name
registered authority and carry reusable configuration, but it is not a graph vertex and cannot
derive a port boundary from surrounding topology.

That leaves a useful authoring question: what does this mean?

```wire
let analyst = @review.analyst { temperature = 0.2; };
```

Without a source-level answer, authors must either repeat executor config at every call site or fall
back to the old partial-node intuition that ADR 0024 rejects.

## Decision

Wire should support configured executor values as inert source values.

```wire
let analyst = @review.analyst {
  temperature = 0.2;
  model = "gpt-5.4";
};

node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = analyst (evidence);
```

A configured executor value has an executor kind, not a CorePure value type and not a circuit type.
Conceptually it carries:

- the executor id;
- a statically elaborated config value;
- the registered executor projection used for admission;
- effect and validation metadata from the projection registry.

It carries no runnable host action, provider credential, tool handle, or Pulse `StageAction`.

### Syntax

The reusable form is:

```text
let <name> = @<executor> { <config> };
```

The direct call form is:

```text
-> output: T = @<executor> { <config> } (<input-expr>);
```

The empty-config shorthand remains valid:

```text
-> output: T = @<executor> (<input-expr>);
```

and is equivalent to:

```text
-> output: T = @<executor> {} (<input-expr>);
```

Applying a configured executor value is valid only in the executor-call implementation positions
defined by ADR 0030: a node-level executor body after the output boundary has been declared.

```wire
node analyze
  <- input: AnalysisInput;
  -> output: AnalysisRecord;
  = analyst (input);
```

The single-output inline shorthand is reserved for registered executor authority with `@`. It is not
valid for configured executor values because `analyst (input)` is also ordinary CorePure function
application syntax after ADR 0050.

It is not valid inside CorePure, so this output equation is rejected:

```text
-> output: T = analyst input;
```

### Scoping And Export

File-level `let` may bind configured executor values. The binding is private unless written with
`export let`.

```wire
export let analyst = @review.analyst { temperature = 0.2; };
```

Exporting a configured executor value exports inert source data only. It does not grant authority.
An importing host still needs a registered projection and Capability binding for the referenced
executor id.

Node-local `where <record-expr>;` clauses remain CorePure-only. They may depend on input values and
are subject to the pure evaluator's determinism and authority-freedom rules. Allowing executor
values there would mix input-dependent pure computation with authority selection.

### Config Evaluation

Executor config must be statically elaborable. It may use file-level static pure-data values, but it
may not depend on node input ports, runtime values, memory, time, IO, imports with authority, or
host callbacks.

Config admission happens before the graph vertex is admitted. Invalid config is a Wire admission
failure, not a runtime executor failure.

### Runtime Options Boundary

Wire also admits a small set of node-local runtime metadata fields such as `timeout`, `retry`,
`stepBudget`, `toolLoopMinSteps`, `maxOutputTokens`, `reasoningEnabled`, and `memory`. These fields
are static executor metadata carried with the node; they are not additional graph edges and they do
not grant authority by themselves.

Their ownership is split:

- generic execution controls such as timeout, retry, and step budget are Cortex substrate metadata;
- `memory = classic` / `memory = topological { ... }` is the Cortex/Pulse topological-memory
  strategy governed by ADR 0012;
- model choice, tool policy, reasoning behavior, and product-specific memory presets remain
  executor/downstream policy under ADR 0040 and ADR 0054, even when historical field names such as
  `toolLoopMinSteps`, `maxOutputTokens`, or `reasoningEnabled` are serialized for compatibility.

The compiler may preserve these fields in circuit metadata for host binders and executors. The field
names are not a Cortex promise to implement model loops, provider selection, cognitive memory, or
product reasoning policy inside the substrate.

### Port Matching

A configured executor value is applied to one input expression. If the registered projection has one
input port, the expression must validate against that port's contract. If the projection has several
input ports, the expression must be a record whose fields match the projected input port labels.

The result boundary must match the node implementation form from ADR 0030. Single-output shorthand
is valid only when exactly one output is declared. Multi-output and zero-output configured executor
calls use node-level executor bodies.

## Alternatives considered

- **Keep configured executors as partial graph nodes.** Rejected because ADR 0024 requires every
  admitted vertex to have an explicit typed boundary from a node declaration.
- **Make executor config host-only.** Rejected because repeated inline config is poor authoring and
  hides useful reusable policy from Wire review.
- **Allow executor values inside CorePure.** Rejected because CorePure is authority-free and
  deterministic. Executor selection is a topology/binding concern, not pure computation.
- **Require inline config at every call site.** Rejected because it preserves the semantics but
  creates noisy source and encourages drift between nominally identical executor uses.

## Consequences

### Positive

- ADR 0024's reusable-config story gets a concrete syntax.
- Reusable executor policy can be reviewed, exported, and reused without becoming topology.
- Host authority remains in Capability binding rather than in Wire source.
- Node declarations remain the only authored graph vertices.

### Negative

- Wire needs kind checking for ordinary pure-data values, configured executor values, and graph
  values.
- The parser distinguishes configured executor application by node-level executor-body position;
  direct output equations are CorePure.
- Configured executor application depends on the node implementation-form checks from ADR 0030.

### Obligations

- Add parser and kind-checker tests for configured executor bindings and node-level body
  applications.
- Reject configured executor calls inside CorePure output equations.
- Reject input-dependent executor config.
- Update executor reference docs to replace partial-node wording with configured executor values.
- Ensure imported configured executor values still require host projection and Capability binding.
- Keep node runtime-options docs explicit about the split between Cortex substrate metadata and
  downstream/provider policy.

## Traceability

- Feature keys: `wire.configured_executor_values`
- Public surface: `Cortex.Wire`,
  [Wire Configured Executors and Execution Boundary](../Reference/Wire/executor-authorities-and-execution-boundary.md)
- Implementation: `src/Cortex/Wire/Syntax.hs` (`ExprConfiguredExecutor`, `ExecutorCallConfigured`),
  `src/Cortex/Wire/Parser.hs` (`configuredExecutorCall`, `ksConfiguredExecutors`),
  `src/Cortex/Wire/Compile.hs` (`ConfiguredExecutor`, `resolveExecutorCall`, CorePure rejection of
  configured-executor values)
- Tests: `test/Cortex/Wire/ParserSpec.hs` (`parses configured executor bindings`,
  `parses configured executor applications`), `test/Cortex/Wire/CompileSpec.hs`
  (`compiles a configured executor value applied in a node body`,
  `rejects configured executor values inside CorePure output equations`)
- Theory/proof: none

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0030 - Wire Node Implementation Forms](./0030-wire-node-implementation-forms.md)
- [Wire Executors and Alphabet Reference](../Reference/Wire/executors-and-alphabet.md)
