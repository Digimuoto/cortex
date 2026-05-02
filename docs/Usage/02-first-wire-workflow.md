---
title: Your First Wire Workflow
description: A gentle first-pass tour of Wire source shape without the full language reference.
sidebar:
  label: 02. First Wire workflow
  order: 2
---

# Your First Wire Workflow

Wire describes a graph of typed node boundaries. Each node says what it consumes, what it produces,
and which registered executor or pure body implements it.

The smallest useful mental model is:

```text
contract declarations
node declarations
edges between node ports
```

## A Tiny Workflow

```wire
contract Topic;
contract Outline;
contract Result;

node plan
  <- topic: Topic;
  -> outline: Outline = @workflow.plan (topic);

node run
  <- outline: Outline;
  -> result: Result = @workflow.execute (outline);

plan
  => run
```

This source says:

- `Topic`, `Outline`, and `Result` are named contracts.
- `plan` consumes a `Topic` and produces an `Outline`.
- `run` consumes an `Outline` and produces a `Result`.
- `@workflow.plan` and `@workflow.execute` are executor references supplied by a registry.
- `plan => run` connects compatible boundaries.

## What Wire Does Not Do

Wire does not invent executor implementations. The leading `@` is the authority boundary: the name
must be registered by the host or consumer library.

Wire also does not run the workflow directly. It compiles source into a circuit artifact. Pulse runs
the materialized circuit.

## Compiling From Haskell

The current public surface is the Haskell API:

```haskell
import Data.Text (Text)

import Cortex.Wire

compileExample :: Text -> Either WireError CompiledCircuit
compileExample =
  compileWireTextWithEnv emptyWireCompileEnv
```

The empty environment is useful for loose examples and early exploration. Most real consumers
construct a strict `WireCompileEnv` with their contract and executor registries before compiling:

```haskell
env :: WireCompileEnv
env =
  strictWireCompileEnv executorRegistry contractRegistry
```

The registries are consumer-owned values. A production environment should be strict about the
registered alphabet it accepts.

## Where To Look Up Syntax

This page is a teaching sketch. Use the reference pages when you need exact rules:

- [Wire grammar](../Reference/Wire/grammar.md)
- [Contracts, ports, and matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Pure execution](../Reference/Wire/pure-execution.md)
