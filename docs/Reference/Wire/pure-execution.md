---
title: "Wire Reference — Pure Execution"
description:
  Reference for Wire-authored CorePure output equations, their input/output binding rules, native
  pure evaluator lowering, builtins, and failure surface.
sidebar:
  label: Pure execution
  order: 6
status: draft
date: 2026-04-29
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
---

# Wire Reference — Pure Execution

Wire pure execution is the deterministic, authority-free calculation layer inside Wire. Authors use
it for JSON-shaped transformations over upstream Wire values, not for model calls, tools, durable
state, artifact writes, or host callbacks.

The source form is:

```wire
let acceptedItem = item: item.score >= 0.7;

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = pure (acceptedItems);
  -> rejected: RejectedSet = pure (filter (item: !(acceptedItem item)) items);
  where let
    items = evidence.items;
    acceptedItems = filter acceptedItem items;
  in
  { inherit items acceptedItems; };
```

`pure (...)` is not an `@` executor application. Authored `@pure { ... }` is rejected. The compiler
lowers pure output equations to an internal native pure task because Pulse executes materialized
tasks, but that lowering is not source-level authority.

## Rule Sources

- **[§5.1 Pure Output Equations](grammar.md#51-pure-output-equations)** - authored pure node syntax,
  local bindings, output equation rules, and CorePure surface.
- **[§8 CorePure Expressions](grammar.md#8-corepure-expressions)** - compact expression grammar.
- **[Executors and the Alphabet](executors-and-alphabet.md#native-pure-evaluator)** - relationship
  between CorePure and the internal native pure evaluator.
- **[ADR 0020](../../ADRs/0020-wire-pure-output-equations.md)** - design decision and proof
  obligations.
- **[ADR 0031](../../ADRs/0031-wire-binding-forms-and-where-clauses.md)** - node-local
  `where <record-expr> ;` binding surface.

## Syntax

A pure node uses the clause form from the Wire grammar:

```text
node <name>
  (<- <input-name> : <Contract>;)*
  (-> <output-name> : <Contract> = pure (<corepure-expr>);)+
  (where <corepure-record-expr>;)?
```

A pure output equation declares one output port and its value:

```wire
-> label: Contract = pure (<corepure_expr>);
```

The output label is the Wire routing label. The expression result is implicit; there is no `return`,
and there is no separate map from result names to ports in source.

Rules:

- Only input ports may appear before pure output equations.
- The optional trailing `where <record-expr> ;` clause opens its record fields into all output
  equations.
- The `where` field set must be statically determinable: record literals, `let ... in { ... }`,
  references to let-bound records, and `//` merges of those shapes are admitted. Dynamic record
  shapes are rejected at admission.
- Each pure output equation declares exactly one output port.
- Sum-grouped outputs are not pure equation syntax.
- A pure node must declare at least one output equation.
- The equation set must match the declared output ports exactly.
- `pure (...)` is the only accepted source form.

Top-level delayed helpers are written as ordinary module `let` bindings whose right-hand side is a
CorePure helper expression:

```wire
let acceptedItem = item: item.score >= 0.7;
let scoreThreshold = 0.7;
```

Module `let` is phase-neutral syntax. `acceptedItem` is a delayed CorePure helper function.
`scoreThreshold` is an ordinary compile-time scalar, but because it is authority-free pure data, the
compiler captures it into later delayed CorePure evaluation as a constant. Configured executor
values and graph values are not capturable into CorePure.

## Lowering

The compiler lowers one source pure node to one internal native pure task. It does not lower one
task per output.

The internal task config has this shape:

```json
{
  "bindings": ["<top-level delayed binding or captured constant AST>"],
  "where": "<optional node-local CorePure record expression AST>",
  "outputs": {
    "accepted": "<CorePure accepted expression AST>",
    "rejected": "<CorePure rejected expression AST>"
  }
}
```

Top-level `bindings` and the node-local `where` record are distinct scopes:

- top-level delayed helpers and captured pure-data constants are evaluated after builtins and input
  variables are installed;
- the `where` record is evaluated after top-level delayed bindings and captured constants;
- fields from the `where` record are opened into the output-evaluation environment;
- where fields may shadow top-level delayed bindings and captured constants;
- where fields may not collide with input port names;
- duplicate binding names are rejected within one scope;
- lambda parameter names must be unique within one lambda.

The internal task metadata records the native pure evaluator, but Wire source never names it with
`@`.

The implemented config schema admits only `bindings`, `where`, and `outputs`. There is no
source-authored CorePure budget field. `where` is omitted when the source node has no where-clause.

## Input Binding

CorePure evaluates over JSON `WireValue` payloads.

Input binding rules:

- Every pure input must accept exactly one contract.
- Every pure input is cardinality-one; list-input aggregation is not part of the authored syntax.
- Repeated same-contract inputs must be explicitly labeled.
- A single unlabeled input is available as the variable `in`.
- Labeled inputs become variables with the same label.
- Input `WireValue`s must have payload kind `json`.

For example:

```wire
node score
  <- evidence: EvidenceSet;
  <- weights: WeightSet;
  -> score: ScoreSet = pure ({
    total = sum (zipWith (s: w: s * w) evidence.scores weights.values);
  });
```

Here `evidence` and `weights` are CorePure variables containing the JSON payload values from the
matching input ports.

## Output Binding

Each output equation key in the lowered config is the declared output port name:

- `-> accepted: AcceptedSet = pure (...)` writes the `accepted` output.
- every output equation writes the declared output label with the same name in the lowered config.

CorePure produces JSON values. Runtime wrapping then validates and wraps each value through the
declared Wire output contract. In practice, pure outputs should target contracts whose payload kind
accepts JSON values.

Evaluation is all-or-nothing for the node: either every declared output is produced, or the pure
task fails with a typed evaluator error.

In the node boundary normal form from
[ADR 0039](../../ADRs/0039-wire-node-boundary-transform-normal-form.md), pure output equations are
the visible egress adapter from the node-local CorePure environment to the declared output port
environment.

## CorePure Expressions

CorePure is a small Nix-like expression language over JSON values. It is not Nix, Haskell, or a host
callback surface.

Implemented expression forms:

- literals: strings, numbers, booleans, `null`;
- lists and records;
- variables;
- field access: `item.score`;
- array/object indexing: `items[0]`, `record["field"]`;
- lambdas: `item: item.score`, `score: weight: score * weight`;
- function application: `map f xs`, `zipWith f xs ys`;
- partial application and pipes: `items |> filter acceptedItem |> map scoreOf`;
- unary `!` and `-`;
- arithmetic `+`, `-`, `*`, `/`;
- comparisons `==`, `!=`, `<`, `<=`, `>`, `>=`;
- boolean `&&`, `||`;
- right-biased record merge `//`;
- non-recursive `let ... in`;
- `if ... then ... else ...`;
- string interpolation: `"Score: ${item.score}"`.

Disallowed:

- `@` executor applications;
- IO, time, randomness, model calls, tool calls, memory queries, durable-state reads, or host
  callbacks;
- loops, recursion, `fix`, imports, paths, modules, or package access;
- exceptions other than typed deterministic evaluator errors.

## Builtins

The implemented builtin environment is closed:

| Builtin    | Arity | Meaning                                                              |
| ---------- | ----- | -------------------------------------------------------------------- |
| `map`      | 2     | Applies a function to every item in an array.                        |
| `fmap`     | 2     | Alias for `map`.                                                     |
| `filter`   | 2     | Keeps array items for which the predicate returns `true`.            |
| `zip`      | 2     | Pairs two arrays, truncating to the shorter length.                  |
| `zipWith`  | 3     | Applies a binary function to paired items from two arrays.           |
| `length`   | 1     | Returns the size of an array or object.                              |
| `sum`      | 1     | Sums an array of numbers.                                            |
| `all`      | 2     | Returns whether a predicate is true for every array item.            |
| `any`      | 2     | Returns whether a predicate is true for at least one array item.     |
| `min`      | 2     | Numeric minimum.                                                     |
| `max`      | 2     | Numeric maximum.                                                     |
| `abs`      | 1     | Numeric absolute value.                                              |
| `clamp`    | 3     | `clamp min max value`, returning `value` bounded by `min` and `max`. |
| `concat`   | 1     | Concatenates an array of strings.                                    |
| `toString` | 1     | Converts strings, numbers, and booleans to strings.                  |
| `joinWith` | 2     | Joins an array of strings with a separator; separator first.         |
| `toJson`   | 1     | Canonical compact JSON serialization for structured values.          |

Every builtin is ordinary CorePure function application. Builtins do not receive host authority.
Functions intended for pipe use are data-last.

## Failure Surface

Pure execution fails deterministically. The evaluator reports typed failures, including:

- missing variables;
- division by zero;
- unsupported pure input ports;
- repeated same-contract input ports without explicit labels;
- missing or ambiguous input values;
- non-JSON input payloads;
- output equations that do not match declared output ports;
- type mismatches;
- missing fields;
- out-of-bounds array indexes;
- calling a non-function;
- function arity mismatches;
- duplicate binding names within one scope;
- duplicate lambda parameters.
- `where` expressions that do not evaluate to records.

These failures are runtime pure-task failures after the graph has been admitted. Source and binding
checks catch malformed pure tasks where possible, such as authored `@pure`, duplicate top-level
names, unsupported pure ports, output port mismatch, `where` field/input-port collisions, and
where-expressions whose field set is not statically determinable.

## Benchmarking

The repository includes an opt-in Criterion benchmark for the implemented pure evaluator:

```bash
just bench-pure-wire
```

The benchmark is a scaffolding surface, not a normative language rule. It compares descriptive
CorePure workloads, such as weighted scoring, eligibility filtering, risk adjustment, and label
rollup, against direct Haskell implementations over the same pre-built JSON values. The Wire case
does not parse JSON text inside the benchmark loop, but it does traverse JSON-shaped `Aeson.Value`s
through the CorePure interpreter. Ordinary benchmark runs print a compact Wire/Haskell comparison
summary to stdout before Criterion's detailed rows.

Hosts that repeatedly evaluate the same lowered pure task may prepare it once and then evaluate the
prepared task against different input bundles. Preparation performs the static task checks; prepared
evaluation still binds and validates runtime Wire inputs. The evaluator may use semantics-preserving
fast paths for common collection closures, such as field projection and simple numeric `zipWith`,
but those paths must preserve the same JSON output equality and pure error taxonomy as generic
CorePure evaluation.

## Boundary With Proofs

CorePure stays inside Wire's deterministic expression layer. It preserves the executor authority
boundary because the author cannot use it to name host capabilities or perform effects.

The proof-facing obligation is the lowering step:

- a source pure node lowers deterministically to one native pure task;
- the lowered output keys are exactly the declared Wire output ports;
- top-level delayed bindings, captured constants, and node-local `where` fields remain distinct
  scopes;
- evaluation depends only on input JSON values, closed builtins, and the CorePure AST;
- the result is wrapped through the declared Wire output contracts.

This keeps pure execution compatible with the theorem-side model while still giving authors a
legible expression surface.
