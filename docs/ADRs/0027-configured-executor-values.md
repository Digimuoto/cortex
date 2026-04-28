---
title: "ADR 0027 - Configured Executor Values"
description:
  "Defines reusable configured executor values as inert Wire source values that can be applied only
  inside explicit node RHSs."
sidebar:
  label: "0027. Configured executors"
  order: 27
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/partials-and-execution-boundary.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - docs/ADRs/0024-wire-node-clause-grammar.md
  - docs/ADRs/0026-typed-executor-node-interface.md
---

# ADR 0027 - Configured Executor Values

## Status

Proposed - fills the reusable-config gap left by ADR 0026 after configured executors stopped being
graph vertices.

## Context

ADR 0026 intentionally rejects the older partial-node model. A configured executor value may name
registered authority and carry reusable configuration, but it is not a graph vertex and cannot
derive a port boundary from surrounding topology.

That leaves a useful authoring question: what does this mean?

```wire
let analyst = @llm.analyst { temperature = 0.2 } ;
```

Without a source-level answer, authors must either repeat executor config at every call site or fall
back to the old partial-node intuition that ADR 0026 rejects.

## Decision

Wire should support configured executor values as inert source values.

```wire
let analyst = @llm.analyst {
  temperature = 0.2 ;
  model = "gpt-5.4" ;
} ;

node analyze
  <- evidence: EvidenceSet ;
  -> analysis: AnalysisRecord = analyst (evidence) ;
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

```wire
let <name> = @<executor> { <config> } ;
```

The direct call form is:

```wire
-> output: T = @<executor> { <config> } (<input-expr>) ;
```

The empty-config shorthand remains valid:

```wire
-> output: T = @<executor> (<input-expr>) ;
```

and is equivalent to:

```wire
-> output: T = @<executor> {} (<input-expr>) ;
```

Applying a configured executor value is valid only in an output RHS implementation position:

```wire
-> output: T = analyst (input) ;
```

It is not valid inside CorePure, so this output equation is rejected:

```wire
-> output: T = pure (analyst input) ;
```

### Scoping And Export

File-level `let` may bind configured executor values. The binding is private unless written with
`export let`.

```wire
export let analyst = @llm.analyst { temperature = 0.2 } ;
```

Exporting a configured executor value exports inert source data only. It does not grant authority.
An importing host still needs a registered projection and Capability binding for the referenced
executor id.

Node-local `let ... in` blocks remain CorePure-only. They may depend on input values and are subject
to the pure evaluator's determinism and authority-freedom rules. Allowing executor values there
would mix input-dependent pure computation with authority selection.

### Config Evaluation

Executor config must be statically elaborable. It may use file-level static CorePure helpers, but it
may not depend on node input ports, runtime values, memory, time, IO, imports with authority, or
host callbacks.

Config admission happens before the graph vertex is admitted. Invalid config is a Wire admission
failure, not a runtime executor failure.

### Port Matching

A configured executor value is applied to one input expression. If the registered projection has one
input port, the expression must validate against that port's contract. If the projection has several
input ports, the expression must be a record whose fields match the projected input port labels.

The result boundary must match the output clause that uses it. In the first implementation slice,
configured executor calls are single-output RHSs. Multi-output external executor calls should be
added only after the node grammar has an explicit way to bind one RHS to several output clauses.

## Alternatives considered

- **Keep configured executors as partial graph nodes.** Rejected because ADR 0026 requires every
  admitted vertex to have an explicit typed boundary from a node declaration.
- **Make executor config host-only.** Rejected because repeated inline config is poor authoring and
  hides useful reusable policy from Wire review.
- **Allow executor values inside CorePure.** Rejected because CorePure is authority-free and
  deterministic. Executor selection is a topology/binding concern, not pure computation.
- **Require inline config at every call site.** Rejected because it preserves the semantics but
  creates noisy source and encourages drift between nominally identical executor uses.

## Consequences

### Positive

- ADR 0026's reusable-config story gets a concrete syntax.
- Reusable executor policy can be reviewed, exported, and reused without becoming topology.
- Host authority remains in Capability binding rather than in Wire source.
- Node declarations remain the only authored graph vertices.

### Negative

- Wire needs kind checking for CorePure values, configured executor values, and circuit values.
- The parser must distinguish configured executor application from CorePure function application.
- Multi-output external executor application remains deferred.

### Obligations

- Add parser and kind-checker tests for configured executor bindings and applications.
- Reject configured executor calls inside `pure (...)`.
- Reject input-dependent executor config.
- Update executor reference docs to replace partial-node wording with configured executor values.
- Ensure imported configured executor values still require host projection and Capability binding.

## Related

- [ADR 0010 - Wire as Closed-Authority Language](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0021 - Executor Registration and Binding](./0021-executor-registration-and-binding.md)
- [ADR 0024 - Wire Node Clause Grammar](./0024-wire-node-clause-grammar.md)
- [ADR 0026 - Typed Executor Node Interface](./0026-typed-executor-node-interface.md)
- [Wire Executors and Alphabet Reference](../Reference/Wire/executors-and-alphabet.md)
