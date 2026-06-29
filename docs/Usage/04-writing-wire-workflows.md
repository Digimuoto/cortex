---
title: Writing Wire Workflows
description: Practical first-pass guide to authoring Wire source before using the full reference.
sidebar:
  label: 04. Writing Wire
  order: 4
---

# Writing Wire Workflows

Wire describes typed graph topology. Each node says what it consumes, what it produces, and which
pure expression or registered executor implements the boundary.

## Source Shape

The smallest useful mental model is:

```text
contract declarations
node declarations
edges between node ports
```

A tiny workflow looks like this:

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
- `@workflow.plan` and `@workflow.execute` are executor references admitted by a registry.
- `plan => run` connects matching output and input ports.

## Contracts And Ports

Contracts name the payload boundary. Ports combine direction, label, and contract:

```text
<- topic: Topic;
-> outline: Outline;
```

`=>` connects an output port to an input port only when their labels and contracts match. It does
not transform values. If a value needs reshaping, author an explicit pure node.

## Pure Nodes

Use CorePure equations for deterministic, authority-free transformations:

```wire
contract Score;
contract Decision;

node decide
  <- score: Score;
  -> decision: Decision = if score >= 0.7 then "accept" else "review";
```

Pure nodes are for JSON-shaped calculation over values already in the graph. They are not for model
calls, scripts, tools, durable state, or host callbacks.

## Executor Nodes

The leading `@` is the authority boundary. Wire can name an executor, but the host or consumer
registry decides whether that executor exists and how it runs.

Local `wire run` recognizes standard `std.io` executor leaves. Other executor names are compile-time
or runtime authority supplied by the embedding environment.

## Common Authoring Failures

| Symptom                       | Usual cause                                                       |
| ----------------------------- | ----------------------------------------------------------------- |
| Executor name not found       | Missing `use` import, package manifest, or registry entry.        |
| Contract not found            | The contract is not declared or registered.                       |
| Input has no producer         | A required input port is not connected.                           |
| Port mismatch                 | The producer label or contract does not match the consumer input. |
| Local run rejects an executor | The graph needs a consumer runtime, not local `wire run`.         |

## Related

- [Wire grammar](../Reference/Wire/grammar.md)
- [Contracts, ports, and matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Pure execution](../Reference/Wire/pure-execution.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
