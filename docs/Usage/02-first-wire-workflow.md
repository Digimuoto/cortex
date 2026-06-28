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

## Run A Ready-Made Example

For local exploration the standalone `wire` CLI bundles compile-and-run: it compiles a source file
and drives the compiled circuit through the in-memory runner (ADR 0043) — no Postgres, task
registry, or deployment. The repository ships a catalog of `.wire` programs under `examples/wire/`;
each file's header comment gives its run command.

A pure CorePure example — `range` / `fold` and the string builtins, no executors:

```bash
nix run .#wire -- run examples/wire/pure-stdlib-report.wire
```

It prints a deterministic Markdown report:

```text
# Wire pure stdlib report

seed: demo
rows: 5

| n | square | cube | size |
| --- | --- | --- | --- |
| 1 | 1 | 1 | SMALL |
| 2 | 4 | 8 | SMALL |
| 5 | 25 | 125 | BIG |
```

What an example needs to run depends on its leaves:

- **Pure** (e.g. `pure-stdlib-report.wire`) — run directly with `wire run`; the body is all
  CorePure.
- **Interactive or effectful** (e.g. `mini-build-system.wire`, `interactive-priority-planner.wire`)
  — need the standard IO executors. See
  [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md).
- **Quantum** (`quantum-*.wire`) — need a hardware or simulator backend. See the
  [Quantum consumer](../Consumers/Quantum.md).
- **Durable** runs — persistence, resume, and signals are a Pulse concern, not the in-memory runner.
  See [Running Pulse](03-running-pulse.md).

## Loading Package Manifests With the CLI

The `wire` CLI can opt into compile-time package manifests when an example or extension uses names
outside Cortex's standard namespaces. Pass one or more explicit manifests with `--wire-package`:

```bash
nix run .#wire -- run \
  --wire-package extensions/quantum/packages/quantum-core/cortex.toml \
  examples/wire/quantum-bell-state.wire
```

If no `--wire-package` flags are present, the CLI reads `CORTEX_WIRE_PACKAGE_MANIFESTS` as a search
path. If neither is set, it loads no extension packages. Manifest loading selects compile-time
package data only; it does not grant runtime executor, provider, secret, or Pulse authority.

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
