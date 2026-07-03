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

## Contracts, Ports, And Labels

A node is a component with typed sockets. A **port** is one socket: a place where exactly one value
enters or leaves the node. Read a port clause left to right:

```text
<- topic: Topic;
│  │      │
│  │      └─ contract — what the value is (Wire's type)
│  └─ label — what the value is for at this node (the port's name)
└─ direction — input (<-) or output (->)
```

A port's full identity is the whole triple `(direction, contract, label)`. All three parts are
identity, not decoration: `<- draft: Draft;` and `-> draft: Draft;` are two different ports, and
Wire never confuses them.

### A contract is Wire's type

A contract is a named classifier for what flows through a port. To Wire it is a name with rules:

- Two contracts are the same iff their names are equal. There is no subtyping and no implicit
  conversion: an `Outline` never passes where a `Result` is expected, even if the payloads happen to
  look alike.
- Composition (`=>`) checks the names when the graph is admitted; the runtime boundary checks the
  payload's declared kind, and a contract that declares a schema has its payloads validated against
  it at the same boundary (ADR 0085).

What Wire deliberately does not know is what the value _means_ or how the host represents it. That
meaning is supplied by whichever executors realize the graph. In the workflow above, `Outline` means
whatever `@workflow.plan` promises to produce and `@workflow.execute` expects to receive: Wire holds
both ends to the same _name_; the executors hold themselves to the same _meaning_. Each consumer
registers its own contract vocabulary the same way — a document backend registers `Draft` and
`Review`, a finance backend registers `Position` and `Valuation` — and Wire routes all of them with
the same rules, never looking inside.

So the short answer to "are contracts types?" is yes: contracts are Wire's type system, and every
connection is type-checked against them. What they are not is host types. The same graph can be
realized by a stub executor in a test and a production service in deployment without changing a line
of Wire — precisely because Wire checks names and shapes, and the realizing side owns the meaning.

### Direction is part of the identity

Because direction is identity, a node may expose the _same_ label and contract on both sides without
any clash — the everyday shape of a pipeline stage:

```wire
contract Draft;

node polish
  <- draft: Draft;
  -> draft: Draft = @editor.polish (draft);
```

The input `(<-, Draft, draft)` and the output `(->, Draft, draft)` are distinct ports. This is
exactly what makes stages chain: in `write => polish => factcheck`, each `=>` matches the left
side's _output_ `draft` against the right side's _input_ `draft`. `=>` only ever matches outputs on
its left against inputs on its right — never input to input, never output to output — so direction
decides which side of the arrow a port can participate from, and a value always flows in at `<-` and
out at `->`.

### A label is the port's name

The label does three jobs:

1. **Binding name.** The node body refers to inputs by label: `@workflow.plan (topic)` receives
   whatever arrived on the port labeled `topic`.
2. **Half of the match key.** `=>` connects an output to an input only when _both_ the contract and
   the label match. A port's full identity is `(direction, contract, label)`.
3. **External name.** When a graph runs, unconnected inputs are supplied by the host _by label_, and
   node outputs are wrapped in runtime envelopes that carry their producing port.

When a node has one port per contract, "what the value is for" collapses into "what the value is" —
any label would do, which is why labels often look redundant, and why the convention is the
lowercase contract name (`topic: Topic`). The convention is not decoration: because `=>` requires
labels to agree _across_ nodes, independently authored nodes compose without adapters only when
their authors picked the same name — and lowercase-of-the-contract is the one name everyone derives
independently.

Labels earn their keep the moment a boundary carries two ports of the same contract, because then
the role and the type genuinely differ:

```wire
contract Draft;

node reconcile
  <- current: Draft;
  <- proposed: Draft;
  -> merged: Draft
  = @editor.reconcile ({ inherit current proposed; });
```

All three ports carry a `Draft`; only the labels say which draft is which. Without them the two
inputs would be indistinguishable and matching would be ambiguous — and Wire rejects ambiguity
rather than guessing. Swap `current` and `proposed` at a call site and you have written a different
program: the merge now favors the wrong draft. This is also where the lowercase-contract pun
naturally ends — when a label's job is to name the value's _role_, it stops echoing the type.

### Matching, Concretely

`plan => run` composes by scanning `plan`'s output ports against `run`'s input ports — only that
pairing; direction fixes which side contributes outputs and which contributes inputs:

- `plan` exposes the output `(outline, Outline)`; `run` expects the input `(outline, Outline)`.
  Exactly one compatible pair exists, so exactly one edge is created.
- If `run` had instead declared `<- input: Outline;`, nothing would match. Both ports would stay
  exposed on the composed boundary, and the graph would later fail with "input has no producer." Fix
  it by renaming one side, or by inserting an explicit pure node that re-exposes the value under the
  other label (`<- input: Outline; -> outline: Outline = input;`).
- An edge never transforms values — not their shape and not their name. All reshaping is a node.

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
- [Terminology — Wire core forms](../Reference/terminology.md#core-forms) (normative definitions of
  contract, port, port key, label, edge, and saturation)
