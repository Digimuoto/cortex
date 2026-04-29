---
title: "ADR 0020 - Wire Pure Output Equations"
description:
  "Defines the pure-node authoring surface: output-port equations with a Nix-like CorePure
  expression language, lowered to the native pure evaluator."
sidebar:
  label: "0020. Pure output equations"
  order: 20
status: accepted
date: 2026-04-28
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
---

# ADR 0020 - Wire Pure Output Equations

## Status

Accepted. This ADR defines the CorePure output-equation surface. It is not a decision to make every
Wire expression a circuit, to infer executors implicitly, or to generalize all executor syntax.

Forward note: ADR 0021 proposes the broader Wire-to-circuit elaboration model that this ADR
deferred. ADR 0022 proposes the clause grammar used by the next implementation. This ADR's positive
decision on pure output equations remains in force.

Forward note: ADR 0031 supersedes this ADR's node-local `let ... in` block and `localBindings`
lowering detail. Pure output equations remain the accepted decision; node-local shared work now uses
the trailing `where <record-expr> ;` clause and lowers through the `where` config field.

## Context

Early pure-node sketches treated deterministic Wire-authored computation as a registered pure
evaluator and used the existing executor surface:

```wire
node score :
  <- evidence_score: Float
  <- recency_score: Float
  -> Float = @pure { expr = "0.7 * evidence_score + 0.3 * recency_score"; };
```

That form is now superseded and is not accepted Wire syntax. It was enough to validate the
registration and binding boundary, but it has three authoring problems once CorePure grows beyond
scalar arithmetic:

- the expression grammar is hidden inside a string;
- output routing is separate from the expression that produces the output;
- shared input-dependent work across several outputs has no natural home.

The replacement is a legible pure-expression surface that keeps Wire's authority boundary clear:
ordinary executor authority still uses `@`, while CorePure stays inside the deterministic Wire
layer.

## Decision

Wire should add **pure output equations** as the next pure-node authoring surface. A pure output
equation attaches a CorePure expression directly to an output port declaration:

```wire
let acceptedItem = x: x.score >= 0.7 ;

node classify
  <- evidence: EvidenceSet ;
  let
    items = evidence.items ;
    acceptedItems = filter acceptedItem items
  in
  -> accepted: AcceptedSet = pure (acceptedItems) ;
  -> rejected: RejectedSet = pure (filter (x: !(acceptedItem x)) items) ;
```

The output port label is the routing label. There is no separate `return accepted = ...` syntax:
`-> accepted: AcceptedSet = pure (...)` states the port name, contract, and computation in one
place.

### Node-Local Pure Bindings

A pure node may carry one node-local `let ... in` block between its inputs and outputs.

- Input port labels are in scope for the local `let` block.
- Local bindings are in scope for every pure output equation.
- A node has at most one local `let` block.
- Local bindings are non-recursive.
- Within a scope, duplicate binding names are rejected. Inner scopes may shadow outer scopes.

The block is for shared input-dependent work. It should lower into one CorePure program for the
node, not into repeated per-output evaluation.

Top-level delayed helper bindings, such as `let acceptedItem = x: x.score >= 0.7;`, are visible to
later pure nodes. Authority-free ordinary data lets may also be captured as constants. Neither form
is an executor definition or introduces new authority.

### Lowering

A node with pure output equations lowers to one internal native pure task, not one executor per
output. The lowered config carries a CorePure program whose result is keyed by output port:

```json
{
  "bindings": ["<top-level delayed binding or captured constant>"],
  "localBindings": ["<node-local CorePure binding>"],
  "outputs": {
    "accepted": "<CorePure accepted expression>",
    "rejected": "<CorePure rejected expression>"
  }
}
```

The exact serialized form may be an AST rather than strings. The semantic requirements are that the
program's outputs are keyed by declared Wire output port names, and that top-level delayed bindings,
captured constants, and node-local bindings remain distinct scopes.

Binding must check:

- every pure output equation names a declared output port;
- every declared output port has exactly one equation;
- all output expressions share the same input environment and local bindings;
- a pure node evaluation either produces every declared output or fails with a typed evaluator
  error;
- outputs wrap as explicit `WireValueSet` values keyed by declared output port;
- each output payload validates against its declared contract and payload kind.

### CorePure Surface

CorePure should be a small Nix-like expression language, not Nix itself. The proposed initial
surface is:

- literals: numbers, strings, booleans, null;
- records/attrsets and lists;
- field access, such as `item.score`;
- deterministic index access, such as `items[0]`;
- non-recursive `let ... in`;
- `if ... then ... else ...`;
- lambdas used as arguments to bounded library primitives;
- arithmetic, comparison, and boolean operators;
- closed library primitives: `map`, `filter`, `zip`, `zipWith`, `length`, `sum`, `min`, `max`,
  `abs`, `clamp`, `all`, and `any`.

Disallowed in this slice:

- recursion or `fix`;
- imports, paths, modules, or package access;
- IO, time, random values, model calls, tool calls, memory queries, durable-state reads, or host
  callbacks;
- unbounded `fold`;
- sort with user comparators;
- exceptions other than typed deterministic evaluator errors.

Every CorePure evaluation runs with an explicit budget. Budget exhaustion is a typed evaluator
error, not a partial runtime failure.

### Explicit Runtime Deferral

Authors must write `pure (...)` explicitly. The compiler must not silently insert runtime pure tasks
from arbitrary input-dependent expressions.

Static CorePure reduction is allowed only when all inputs are statically known and the reduction is
deterministic. A statically reducible expression that produces a typed evaluator error, such as
division by zero, fails during elaboration instead of being deferred to runtime.

## What This Does Not Decide

This ADR deliberately does not adopt the broader proposal that every Wire expression denotes a
circuit. Existing Wire values and ordinary values remain distinct for this decision.

This ADR also does not generalize executor syntax. Other registered executors continue to use the
existing executor application form:

```wire
@qualified.name { config }
```

Future ADRs may revisit:

- implicit `pure` insertion when an RHS is input-dependent;
- top-level constant circuits;
- topology-level composition operators such as `>>>`;
- `@executor (...)` syntax for non-pure executors;
- bounded `fold` after budget accounting is tested.

## Consequences

Positive consequences:

- Pure-node authoring becomes legible without string-embedded source.
- Output port labels and contracts stay visibly tied to the expression that must satisfy them.
- Multi-output pure nodes have a natural shape.
- Shared input-dependent work can be written once and evaluated once.
- The executor authority boundary remains intact: `pure (...)` does not use `@`, and lowering to the
  native evaluator remains an internal compiler/runtime detail.

Costs and risks:

- The parser needs a new node-body form with local `let` bindings and per-output RHS equations.
- The native pure task config shape must use a port-keyed CorePure program rather than a single
  `expr` string.
- Existing `@pure { expr = ... }` examples are rejected and documented as historical syntax.
- CorePure budget accounting becomes part of the user-visible semantics.

Proof impact:

- Existing graph, rewrite, and admission proofs continue to quantify over the post-elaboration
  circuit.
- CorePure keeps the same evaluator obligations: determinism, authority-freeness, typed failures,
  and bounded termination.
- The new proof obligation is the lowering step: pure output equations must lower deterministically
  to a registered pure executor program whose output keys are exactly the declared output ports.

## Alternatives Considered

### Keep `expr` Strings

Rejected as the long-term surface. It avoids grammar work, but it hides syntax errors inside config,
does not scale cleanly to multiple outputs, and gives editor tooling little structure.

### Use `return port = ...`

Rejected for now. It works, but it duplicates the output port label in the node body. Port equations
make the declaration itself the routing rule.

### One Pure Executor Per Output

Rejected. It causes repeated evaluation of shared work and makes multi-output consistency harder to
state. A pure node should evaluate once and produce all declared outputs or one typed failure.

### Full Wire-To-Circuit Unification

Deferred. The idea is promising, but it changes the existing distinction between ordinary values and
wire values. Pure output equations deliver the authoring improvement without requiring that broader
semantic move.
