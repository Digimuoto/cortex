---
title: "Wire Reference — Executors and the Alphabet"
description:
  Scoped reference for executor registration, configured executor values, `@` authority, and ambient
  identifiers in config values.
sidebar:
  label: Executors
  order: 5
status: draft
date: 2026-04-29
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/Reference/Wire/configured-executors-and-execution-boundary.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
---

# Wire Reference — Executors and the Alphabet

`@` is Wire's executor-authority marker. It references a registered executor from the closed
alphabet and pairs it with inert config data:

```wire
let analyst = @review.analyst {
  model = "gpt-5.4";
  temperature = 0.2;
  memory = topological { preset = "analyst"; };
};
```

This does not run the executor and does not create a graph vertex. It creates a configured executor
value that can be reused in explicit node implementation bodies.

Standard-pack executors are source-scoped through `use`:

```wire
use std.io.{@stdin, @stdout, @command, @readFile, @writeFile};

node read_mode
  -> answer: UserInput = @stdin { prompt = "Planning mode (high/safe): "; } (null);
```

The `use` form brings names into source scope; it does not bind host authority by itself. The host
registry still admits and binds the canonical executor ID, such as `std.io.stdin`.

The local `wire run` interpreter recognizes these standard IO executor leaves:

| Executor           | Boundary shape                        | Runtime behavior                                 |
| ------------------ | ------------------------------------- | ------------------------------------------------ |
| `std.io.stdin`     | zero inputs, exactly one output       | optionally prints a prompt and reads one line    |
| `std.io.stdout`    | exactly one input, zero outputs       | prints the input payload                         |
| `std.io.command`   | zero or one input, zero or one output | executes one argv vector and captures the result |
| `std.io.readFile`  | zero or one input, exactly one output | reads UTF-8 text from a configured/input `path`  |
| `std.io.writeFile` | exactly one input, zero outputs       | writes the input payload as UTF-8 text to `path` |

## Three Layers

| Layer              | Owned by                                          | Contains                                                                                  |
| ------------------ | ------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Pure config data   | Wire source language                              | Records, strings, lists, numbers, booleans, tool names, tagged config constructors        |
| Registry authority | Executor/Capability registries plus host bindings | Executor identity, config schema, port projections, contract vocabulary, effect class     |
| Runtime evaluation | Pulse plus host interpreters                      | Durable scheduling, input snapshots, executor invocation, output validation, failure data |

Wire stages authority. Pulse evaluates only after the compiler has materialized a node with a
concrete typed port boundary.

## Configured Executor Values

The application form is:

```wire
@qualified.name { field = value; }
```

The result has:

- an executor identity;
- config data;
- no node identity;
- no graph position;
- no ability to communicate with other nodes.

It becomes executable only through a node body:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = analyst (evidence);
```

Inline calls are equivalent when no reuse is needed:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = @review.analyst { temperature = 0.2; } (evidence);
```

In [ADR 0039](../../ADRs/0039-wire-node-boundary-transform-normal-form.md)'s normal form, the
executor-call argument is the node's ingress adapter: it translates typed input ports and local
CorePure helpers into the one value presented to the registered body. Output projection, validation,
and wrapping are the egress obligation before edges consume output ports.

## Registry Admission

Before an executor call becomes a materialized node, the registry and binding layer establish:

| Obligation              | Meaning                                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| Executor exists         | The qualified name is present in the loaded executor alphabet.                                   |
| Config validates        | The config record conforms to the executor schema.                                               |
| Ports are concrete      | The authored node boundary is checked against the executor projection or structural constraints. |
| Contracts are known     | Every input/output contract is declared by the program or registry.                              |
| Effect class is known   | The binding classifies the executor as model-mediated, host-effecting, pure, etc.                |
| Output validation known | The runtime knows how to validate every declared output contract.                                |
| Authority is explicit   | Tools, model providers, memory policies, artifact writes, and host APIs come from the registry.  |

Configured executor values are reusable configuration, not a second graph-authoring path. There is
no port-determined shortcut and no context inference from graph position.

## Config Purity

Config expressions are inert. They can name instructions, memory policies, provider choices, numeric
parameters, tools, and nested tagged records, but they cannot run executors.

```wire
let reviewer = @review.review {
  tools = [webSearch, readArtifact];
  memory = topological { preset = "reviewer"; };
};
```

`topological { ... }` is a config constructor. It may grant the executor a memory/retrieval policy
through the binding layer, but it is not hidden node-to-node communication and it is not part of
Wire's proven core.

## Native Pure Evaluator

CorePure is authored without `@`:

```wire
node score
  <- evidence: EvidenceSet;
  <- weights: WeightSet;
  let
    weighted = zipWith (score: weight: score * weight) weights.values evidence.scores
  in
  -> total: Score = pure (sum weighted);
```

`pure (...)` is inside Wire's deterministic expression layer. Authored `@pure` is rejected. The
compiler lowers pure output equations to the native pure evaluator internally after parsing.

## Runtime Evaluation

At runtime a materialized node carries:

- a stable node identity;
- an executor reference;
- validated config;
- concrete typed input and output ports;
- contract metadata;
- effect/purity metadata for the host interpreter.

The executor may still fail, time out, call a provider, write an artifact, or return invalid output.
Cortex's guarantee is that this authority was explicit and admitted before runtime.

## Summary

- `@qualified.name { ... }` creates a configured executor value.
- Configured executors are not graph vertices.
- Executors run only through explicit typed node bodies.
- Executor-call input expressions are ingress adapters from input ports to one body argument.
- Output projection, validation, and wrapping are egress obligations, not edge-local behavior.
- Every executor node has the same external shape: typed inputs, typed outputs, and deterministic
  failure on contract/config/output violations.
- `pure (...)` is not an executor-authority boundary and is never spelled `@pure`.
