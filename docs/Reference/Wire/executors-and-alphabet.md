---
title: "Wire Reference — Executors and the Alphabet"
description: Scoped reference for executor registration, the closed alphabet, `@`-application, partial nodes, and ambient identifiers in config values.
sidebar:
  label: Executors
  order: 5
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
---

# Wire Reference — Executors and the Alphabet

This page defines the semantic boundary behind Wire's executor application
form:

```wire
@qualified.name { config }
```

The short version: `@` is **pure staging of registered executor
authority**. The config record is ordinary Wire data. The executor is a
registered capability that may later perform effects, call external systems, or
fail. Applying `@` does not run the executor; it constructs a partial node that
can be checked, merged, pinned to ports, compiled into a graph, persisted, and
eventually evaluated by Pulse.

Executor *kinds* (model-mediated generation vs registered external call) and
their backend sub-taxonomy are decided in
[ADR 0014](../../ADRs/0014-executor-taxonomy-model-vs-external-call.md). This
page covers the grammar-level and registry-boundary surface above that
taxonomy.

## Rule Sources

- **[§5.1 Executor registration](grammar.md#51-executor-registration)** — what an executor is, what each executor declares (config schema, vocabulary, structural constraints, purity class), and how the alphabet is global.
- **[§5.2 Executor application](grammar.md#52-executor-application)** — `@executor { config }` produces a partial node; schema-checking timing.
- **[§5.3 Config merge on partial nodes](grammar.md#53-config-merge-on-partial-nodes)** — how `partial // record` produces new partials for "base + delta" reuse.
- **[§5.5 Ambient identifiers in config values](grammar.md#55-ambient-identifiers-in-config-values)** — tool references and tagged-record config constructors.

## Three Layers

`@` sits at a deliberately narrow boundary between three layers:

| Layer | Owned by | What it contains | What it does not do |
|---|---|---|---|
| Pure config data | Wire source language | Records, strings, numbers, booleans, lists, tagged config values, tool-name references | No executor call, host mutation, provider request, persistence side effect, or scheduling |
| Registry authority | Executor/Capability registries plus consumer bindings | Executor identity, config schema, port/profile declarations, contract vocabulary, purity/effect class, host permissions | No run-state transition; it only admits or rejects staged authority |
| Runtime evaluation | Pulse plus host interpreters | Durable node scheduling, input snapshots, executor invocation, output validation, retry/cancellation/failure recording | No new executor authority beyond what the compiled graph already materialized |

This separation is the reason Wire can treat executor applications as values.
The author can bind and transform a configured executor without performing the
operation:

```wire
let analyst_base = @llm.analyst {
  model = "gpt-5.2";
  temperature = 0.2;
  memory = topological { preset = "analyst" };
};

node analyst : <- EvidenceBundle -> AnalysisFragment | ExecutorError =
  analyst_base // { tools = [webSearch, readArtifact]; };
```

The `topological { ... }` value is a config constructor, not an executor. The
leading `@` is what marks a reference to the executor alphabet.

## Executor Applications

Executors are a closed alphabet registered outside Wire. User code cannot
define new executors; it composes them.

The application form is:

```wire
@qualified.name { field = value; }
```

It resolves `qualified.name` against the executor registry and pairs it with a
pure config record. The result is a **partial node**:

- it has an executor identity;
- it has config data;
- it has no authored node identity yet;
- it may or may not have enough registry-declared port information to stand in
  graph position;
- it is `let`-bindable;
- it can be shallowly, right-biased merged with `//`;
- it becomes an ordinary node only after a `node` declaration or an admissible
  port-determined graph use pins its boundary.

`@qualified.name { config }` therefore means "stage this registered executor
with this pure config", not "run this executor now".

## Registry Admission

Before a partial node may become a graph node, the registry boundary must
establish the following facts:

| Obligation | Meaning |
|---|---|
| Executor exists | The qualified name is present in the loaded executor alphabet. |
| Config validates | The config record conforms to the executor's schema, including any ambient tool or tagged-constructor references. |
| Port boundary is declared or derivable | The executor either declares fixed ports, accepts the author's `node` signature, or supplies enough structural constraints for direct graph-position use. |
| Contracts are known | Every input/output contract is in the executor vocabulary, declared by the loaded Wire program, or admitted by an open-vocabulary executor rule. |
| Purity/effect class is known | The registry classifies the executor as pure, impure, host-effecting, model-mediated, or another accepted effect category. |
| Output validation is known | The runtime knows which contract schema or payload-kind check applies to each produced output. |
| Host authority is explicit | Any external tool, model provider, artifact sink, durable mutation, or host API permission comes from the registry/binding layer, not from Wire syntax alone. |

These obligations are admission facts about a staged node. They do not prove
that the executor will terminate, succeed, or produce useful content. Runtime
execution remains fallible.

## Config Purity

Config expressions are pure. They can describe prompts, memory policies,
provider choices, numeric parameters, tool lists, and nested tagged records, but
they cannot execute an executor.

This matters for reuse:

```wire
let gatherer_base = @llm.gatherer {
  memory = topological { preset = "evidence" };
  tools = [webSearch];
};

node gatherer_news : <- PlannerOutput -> EvidenceBundle | ExecutorError =
  gatherer_base // { tools = [webSearch, getAssetNews]; };
```

The merge creates a new configured partial node. It does not mutate
`gatherer_base`, call `@llm.gatherer`, or contact any tool. Tool identifiers in
config are ordinary names whose meaning is checked by the executor schema and
host binding.

## Runtime Evaluation

Pulse evaluates materialized nodes after Wire has compiled and validated the
graph. At that point the node carries:

- a stable materialized identity;
- an executor reference;
- validated config;
- a port boundary;
- contract metadata for inputs and outputs;
- effect/purity metadata needed by the runtime and host interpreter.

The executor may still be unsafe or impure in the ordinary sense: it can call a
model, use a tool, write an artifact, fail, time out, or return invalid output.
The Cortex boundary is that this authority is explicit and staged before
runtime. Pulse owns durable scheduling and lifecycle state; the registry and
host binding own what the executor is allowed to do.

## Rewrites And Materialization

Runtime rewrites may transform topology, but they cannot invent executor
authority. Any rewrite that introduces or changes an `@` application must still
pass the same registry admission boundary:

- the executor must already be registered;
- the config must validate;
- the new ports/contracts must be compatible with the surrounding graph;
- the effect class and host permissions must remain explicit;
- output validation must remain known.

The Cortex theory enforces this as a rewrite-admissibility obligation
alongside graph acyclicity: an admitted rewrite must preserve the registry
boundary for every materialized executor node.

## Summary

- `@qualified.name { config }` is pure staging of registered executor
  authority.
- Config data is inert until Pulse evaluates a materialized node.
- `@` produces a partial node, not a running computation.
- Registry admission is what turns a staged executor into graph-authorable
  authority.
- Rewrites can change topology only inside the same registry boundary; they
  cannot create new authority by syntax alone.

## Related

- [Partials and execution boundary](./partials-and-execution-boundary.md) — when a partial node may appear directly in graph position.
- [Contracts, ports, and matching](./contracts-ports-and-matching.md) — the port-key rule that executor-declared port signatures participate in.
- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — substrate architecture.
