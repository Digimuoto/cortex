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
  - docs/ADRs/0022-wire-pure-output-equations.md
---

# Wire Reference — Pure Execution

Wire pure execution is the deterministic, authority-free calculation layer inside Wire. Authors use
it for JSON-shaped transformations over upstream Wire values, not for model calls, tools, durable
state, artifact writes, or host callbacks.

The source form is:

```wire
let acceptedItem = item: item.score >= 0.7;

node classify :
  <- evidence: EvidenceSet
  let
    items = evidence.items;
    acceptedItems = filter acceptedItem items;
  in
  -> accepted: AcceptedSet = pure (acceptedItems)
  -> rejected: RejectedSet = pure (filter (item: !(acceptedItem item)) items);
```

`pure (...)` is not an `@` executor application. Authored `@pure { ... }` is rejected. The compiler
lowers pure output equations to an internal native pure task because Pulse executes materialized
tasks, but that lowering is not source-level authority.

## Rule Sources

- **[§6.1.1 Pure Output Equations](grammar.md#611-pure-output-equations)** - authored pure node
  syntax, local bindings, output equation rules, and CorePure surface.
- **[§14.5 CorePure Expressions](grammar.md#145-corepure-expressions)** - compact expression
  grammar.
- **[Executors and the Alphabet](executors-and-alphabet.md#native-pure-evaluator)** - relationship
  between CorePure and the internal native pure evaluator.
- **[ADR 0022](../../ADRs/0022-wire-pure-output-equations.md)** - design decision and proof
  obligations.

## Syntax

A pure node uses a separate node-body form:

```wire
node name :
  <input_port>*
  [ let <corepure_binding>+ in ]
  <pure_output_equation>+;
```

A pure output equation declares one output port and its value:

```wire
-> label: Contract = pure (<corepure_expr>)
-> label: Contract = pure { <corepure_expr>; }
```

The output label is the Wire routing label. The expression result is implicit; there is no `return`,
and there is no separate map from result names to ports in source.

Rules:

- Only input ports may appear before the optional node-local `let ... in` block.
- The node-local block, when present, is shared by all output equations.
- Each pure output equation declares exactly one output port.
- Sum-grouped outputs are not pure equation syntax.
- A pure node must declare at least one output equation.
- The equation set must match the declared output ports exactly.
- `pure (...)` and `pure { ... }` are equivalent except for delimiters.

Top-level CorePure helpers are written as `let` bindings whose right-hand side is a CorePure lambda
or CorePure `let` expression:

```wire
let acceptedItem = item: item.score >= 0.7;
```

These helpers are visible to later pure nodes. Ordinary top-level `let` bindings keep ordinary Wire
value semantics and are not executor authority.

## Lowering

The compiler lowers one source pure node to one internal native pure task. It does not lower one
task per output.

The internal task config has this shape:

```json
{
  "bindings": ["<top-level CorePure helper binding AST>"],
  "localBindings": ["<node-local CorePure binding AST>"],
  "outputs": {
    "accepted": "<CorePure accepted expression AST>",
    "rejected": "<CorePure rejected expression AST>"
  }
}
```

`bindings` and `localBindings` are distinct scopes:

- top-level helpers are evaluated after builtins and input variables are installed;
- node-local bindings are evaluated after top-level helpers;
- node-local bindings may shadow top-level helpers;
- duplicate binding names are rejected within one scope;
- lambda parameter names must be unique within one lambda.

The internal task metadata records the native pure evaluator, but Wire source never names it with
`@`.

The implemented config schema admits only `bindings`, `localBindings`, and `outputs`. There is no
source-authored CorePure budget field.

## Input Binding

CorePure evaluates over JSON `WireValue` payloads.

Input binding rules:

- Every pure input must accept exactly one contract.
- Every pure input must be cardinality-one; list-valued input ports are rejected.
- Repeated same-contract inputs must be explicitly labeled.
- A single unlabeled input is available as the variable `in`.
- Labeled inputs become variables with the same label.
- Input `WireValue`s must have payload kind `json`.

For example:

```wire
node score :
  <- evidence: EvidenceSet
  <- weights: WeightSet
  -> score: ScoreSet = pure ({
    total = sum (zipWith (s: w: s * w) evidence.scores weights.values);
  });
```

Here `evidence` and `weights` are CorePure variables containing the JSON payload values from the
matching input ports.

## Output Binding

Each output equation key in the lowered config is the declared output port name:

- `-> accepted: AcceptedSet = pure (...)` writes the `accepted` output.
- `-> ScoreSet = pure (...)` writes the default unlabeled output port, keyed as `out` in the lowered
  config.

CorePure produces JSON values. Runtime wrapping then validates and wraps each value through the
declared Wire output contract. In practice, pure outputs should target contracts whose payload kind
accepts JSON values.

Evaluation is all-or-nothing for the node: either every declared output is produced, or the pure
task fails with a typed evaluator error.

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
- unary `!` and `-`;
- arithmetic `+`, `-`, `*`, `/`;
- comparisons `==`, `!=`, `<`, `<=`, `>`, `>=`;
- boolean `&&`, `||`;
- non-recursive `let ... in`.

Disallowed:

- `@` executor applications;
- IO, time, randomness, model calls, tool calls, memory queries, durable-state reads, or host
  callbacks;
- loops, recursion, `fix`, imports, paths, modules, or package access;
- exceptions other than typed deterministic evaluator errors.

## Builtins

The implemented builtin environment is closed:

| Builtin   | Arity | Meaning                                                              |
| --------- | ----- | -------------------------------------------------------------------- |
| `map`     | 2     | Applies a function to every item in an array.                        |
| `fmap`    | 2     | Alias for `map`.                                                     |
| `filter`  | 2     | Keeps array items for which the predicate returns `true`.            |
| `zip`     | 2     | Pairs two arrays, truncating to the shorter length.                  |
| `zipWith` | 3     | Applies a binary function to paired items from two arrays.           |
| `length`  | 1     | Returns the size of an array or object.                              |
| `sum`     | 1     | Sums an array of numbers.                                            |
| `all`     | 2     | Returns whether a predicate is true for every array item.            |
| `any`     | 2     | Returns whether a predicate is true for at least one array item.     |
| `min`     | 2     | Numeric minimum.                                                     |
| `max`     | 2     | Numeric maximum.                                                     |
| `abs`     | 1     | Numeric absolute value.                                              |
| `clamp`   | 3     | `clamp min max value`, returning `value` bounded by `min` and `max`. |

Every builtin is ordinary CorePure function application. Builtins do not receive host authority.

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

These failures are runtime pure-task failures after the graph has been admitted. Source and binding
checks catch malformed pure tasks where possible, such as authored `@pure`, duplicate top-level
names, duplicate node-local pure bindings, unsupported pure ports, and output port mismatch.

## Boundary With Proofs

CorePure stays inside Wire's deterministic expression layer. It preserves the executor authority
boundary because the author cannot use it to name host capabilities or perform effects.

The proof-facing obligation is the lowering step:

- a source pure node lowers deterministically to one native pure task;
- the lowered output keys are exactly the declared Wire output ports;
- top-level and node-local bindings remain distinct scopes;
- evaluation depends only on input JSON values, closed builtins, and the CorePure AST;
- the result is wrapped through the declared Wire output contracts.

This keeps pure execution compatible with the theorem-side model while still giving authors a
legible expression surface.
