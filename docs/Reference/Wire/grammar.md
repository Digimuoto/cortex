---
title: "Wire Grammar Specification"
description:
  "Normative specification of the Wire grammar: declarations, typed ports, configured executors,
  CorePure output equations, and graph composition."
sidebar:
  label: Grammar
  order: 1
date: 2026-04-29
status: accepted
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
---

# The Wire Language — Specification

Wire is the Cortex source language for authoring typed dataflow topology over a closed executor
alphabet. A Wire file declares contracts, configured executor values, nodes, and graph composition.
The compiler elaborates the source to a fixed circuit before Pulse evaluates it.

The current grammar is intentionally explicit:

- every authored node has typed input and output clauses;
- every authored port has a label;
- `@` names registered executor authority, never CorePure;
- `pure (...)` output equations are inside Wire's deterministic expression layer;
- configured executor values are reusable values, not graph vertices;
- fan-in and fan-out transformations are authored as nodes, not implicit context concatenation or
  implicit list aggregation.

## 1. Lexical Structure

Whitespace is insignificant except as a separator. Line comments start with `#`. Block comments use
`/* ... */` and do not nest.

Identifiers match `[A-Za-z_][A-Za-z0-9_]*`. Qualified identifiers join identifiers with `.`.

Reserved words:

```text
as contract else export false from if import in let node null pure select then true use where
```

Literal forms:

- strings: `"..."` with `\n`, `\t`, `\r`, `\"`, `\\`, and escaped interpolation;
- indented strings: `''...''`, normalized by stripping common indentation;
- numbers: decimal integers and floats;
- booleans: `true`, `false`;
- null: `null`;
- records: `{ key = value; nested.key = value; inherit key; }`;
- lists: `[a, b, c]`;
- unit/empty wire: `()`.

## 2. File Shape

```ebnf
wire_file   ::= top_form* file_return?
top_form    ::= contract_decl | use_stmt | let_binding | import_stmt | node_decl
file_return ::= wire_expr

contract_decl ::= "contract" Name ";"
use_stmt      ::= "use" qualified_ident ".{" use_item ("," use_item)* ","? "}" ";"
use_item      ::= "@" ident ("as" "@" ident)? | ident ("as" ident)?
let_binding   ::= ("export")? "let" ident "=" let_rhs ";"
let_rhs       ::= graph_expr | value_expr | corepure_helper_expr
import_stmt   ::= "import" (ident | "{" ident ("," ident)* ","? "}") "from" string ";"
```

A file may end with one expression without a trailing semicolon. That expression is the file-return
value.

`export let` is accepted as the forward-compatible surface for imports. Until module imports grow a
visibility check, `export` does not change runtime behavior.

`use` imports selected names from a registry namespace into source scope. File imports and registry
namespace imports are distinct: `import` loads another `.wire` file; `use` selects registered
executor and contract names. The initial implemented namespace is `std.io`:

```wire
use std.io.{@stdin, @stdout, @command, CommandSpec, CommandResult};
```

Executor selectors carry `@` at the leaf because they import executor authority names. Contract
selectors do not. Aliases are allowed with the same marker discipline:

```wire
use std.io.{@command as @shell, CommandSpec as Spec};
```

Wildcard namespace imports are not part of v1.

Module-level `let` is one syntax, not separate "ordinary" and "pure" declarations. The compiler
classifies the right-hand side by phase:

- graph expressions are elaborated at compile time and bind graph values;
- configured executor values and ordinary scalar, record, list, or string expressions bind
  compile-time values;
- CorePure helper functions, such as `let pred = item: item.score >= 0.7 ;`, bind delayed helpers
  for pure evaluation.

Authority-free compile-time data values are also available to delayed CorePure expressions as
captured constants. Graph values and configured executor values are not.

## 3. Values

Wire has three relevant value classes.

**Graph values** are nodes, composed graph expressions, and `()`. Only graph values may appear in
file-return position or on either side of graph operators.

**Configured executor values** have the form:

```wire
@qualified.executor { field = value; }
```

They are inert values containing executor identity plus pure config data. They are `let`-bindable
and may be applied in node implementation bodies. They are not graph vertices and may not appear in
graph position.

**Ordinary values** are records, lists, strings, numbers, booleans, `null`, and tagged config
constructors. They may be used in config records. When an ordinary value is made only from
authority-free pure data, it may also be captured by delayed CorePure evaluation.

`//` is right-biased shallow record merge. It applies to records only. It does not merge configured
executors.

## 4. Contracts And Ports

Contracts are named typed interfaces. Contract names are equal iff their names are equal. A contract
is known if an executor registry declares it or the program asserts it with `contract Name ;`.

Port clauses:

```wire
<- label: Contract;
-> label: Contract;
-> label_a: ContractA | label_b: ContractB;
```

Labels are required on authored ports. A port key is `(direction, contract, label)`. `=>` connects
only matching keys. Labels are semantic routing identity, not documentation.

All input ports are cardinality-one. Wire no longer has `<- [Contract]` list aggregation syntax.
When many values must be gathered, author an explicit node that receives distinct typed inputs and
constructs a list or record in its implementation body.

Output sum groups use `|` and are output-only. A sum group means exactly one variant fires per
evaluation. Each variant has its own label and contract.

Empty input and output port sets are legal on executor-body nodes when the registered executor
admits them. There is no special `source` or `sink` syntax; empty boundary sides are just ordinary
typed interface shapes.

## 5. Nodes

```ebnf
node_decl ::= "node" ident input_clause* node_body where_clause?

input_clause ::= "<-" ident ":" Contract ";"
where_clause ::= "where" corepure_expr ";"

node_body ::=
    pure_output_equation+
  | executor_output_clause* "=" executor_call ";"
  | "->" output_variant "=" executor_call ";"

pure_output_equation ::= "->" output_variant "=" "pure" "(" corepure_expr ")" ";"
executor_output_clause ::= "->" output_body ";"
output_body ::= output_variant ("|" output_variant)*
output_variant ::= ident ":" Contract
```

There is no colon after `node name`.

### 5.1 Pure Output Equations

Pure nodes compute deterministic JSON-shaped values:

```wire
let scoreThreshold = 0.7;

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = pure (accepted);
  -> summary: Report = pure (''
    Accepted: ${length accepted} items
    Threshold: ${scoreThreshold}
  '');
  where let
    items = evidence.items;
    accepted = items |> filter (item: item.score >= scoreThreshold);
  in
  { inherit items accepted; };
```

Rules:

- pure output equations use `pure (...)` only;
- `@pure`, `pure { ... }`, and string-valued `expr = ...` configs are rejected;
- every pure equation declares exactly one output port;
- pure equations do not declare sum groups;
- an optional trailing `where <record-expr> ;` clause opens statically known record fields into all
  equations in the node;
- node-local `let ... in` blocks before the body are rejected;
- top-level delayed bindings and captured pure-data constants are visible to later pure nodes.

The `where` expression must have a statically determinable record field set: record literals,
`let ... in { ... }`, references to let-bound records, and right-biased record merges with `//` are
admitted. Dynamic shapes such as conditionals are rejected at admission.

### 5.2 Executor Bodies

Executor nodes have the same external shape as pure nodes: typed inputs and typed outputs. The body
is an executor call:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  -> usage: UsageMetadata;
  = @review.analyzeWithUsage {
    model = "gpt-5.4";
  } (evidence);
```

Single-output executor nodes may use the shorthand:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord = @review.analyze (evidence);
```

Zero-output executor nodes use an executor body with no output clauses:

```wire
node log_event
  <- event: Event;
  = @artifact.log (event);
```

Configured executors are applied by name:

```wire
let analyst = @review.analyst {
  temperature = 0.2;
};

node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = analyst (evidence);
```

Semantically, the expression passed to the executor is the node's ingress adapter: it translates the
input port environment into the single body argument. The declared output clauses plus registry
projection and runtime output validation form the egress adapter back to output ports. See
[ADR 0039](../../ADRs/0039-wire-node-boundary-transform-normal-form.md).

## 6. Executor Calls And Config

```ebnf
executor_call ::= inline_executor_call | configured_executor_call

inline_executor_call     ::= "@" qname record? "(" corepure_expr ")"
configured_executor_call ::= ident "(" corepure_expr ")"
```

The expression inside `(...)` is the executor input value. For multiple typed inputs, pass an
explicit CorePure record:

```wire
node merge
  <- mechanism: AnalysisFragment;
  <- timing: AnalysisFragment;
  <- beneficiaries: AnalysisFragment;
  -> merged: AnalysisFragment;
  = @review.report_merge ({
    fragments = [mechanism, timing, beneficiaries];
  });
```

Executor config is inert data. It may contain records, lists, strings, numbers, booleans, configured
values admitted by the config schema, tool names, and tagged config constructors such as
`topological { preset = "analyst"; }`. The registry validates whether those fields are meaningful.
Record fields support Nix-style `inherit name;` sugar, which desugars to `name = name;`.

## 7. Graph Composition

```wire
wire_expr ::= atom
            | wire_expr "=>" wire_expr
            | wire_expr "<>" wire_expr
            | wire_expr "select" "(" arm ("," arm)* ","? ")"
```

`<>` overlays graph values. It is set union on nodes and edges.

`=>` connects every matching output boundary port on the left to every matching input boundary port
on the right. Matching is by `(contract, label)`. It does not choose one edge; it adds all matching
edges. Multiple edges into the same cardinality-one input are a compile error.

The implementation requires parentheses when `<>` and `=>` are mixed in one expression:

```wire
(a <> b)
  => c
a
  => (b <> c)
```

Unparenthesized `a => b <> c` is rejected.

`()` is the empty graph value and identity for overlay/connect.

`select(...)` is the conditional continuation form over an exclusive output boundary. Its detailed
semantics are specified in [conditionality.md](conditionality.md).

## 8. CorePure Expressions

CorePure is the deterministic expression language used by `pure (...)` and executor input arguments.
It has no IO, imports, recursion, host callbacks, model calls, tool calls, time, or randomness.
CorePure expressions evaluate when the node input ports they reference are available. They may also
reference module-level pure-data constants and CorePure helper functions declared earlier in the
file.

Expression forms:

- literals: strings, indented strings, numbers, booleans, `null`, records, lists;
- variables;
- field access: `item.score`;
- index access: `items[0]`;
- non-recursive `let ... in`;
- `if ... then ... else ...`;
- lambdas: `item: item.score`, `score: weight: score * weight`;
- application and partial application;
- unary `!` and `-`;
- arithmetic `+`, `-`, `*`, `/`;
- right-biased record merge `//`;
- comparisons `==`, `!=`, `<`, `<=`, `>`, `>=`;
- boolean `&&`, `||`;
- pipe sugar: `lhs |> f` desugars to `f lhs`.

The closed builtin environment is:

```text
map filter fmap zip zipWith length sum min max abs clamp all any
concat toString joinWith toJson fromJson
```

Stdlib functions intended for piping are data-last. `zip` and `zipWith` take the piped list as their
rightmost operand.

String interpolation is CorePure syntax:

```wire
"Score: ${item.score}"
''Threshold: ${threshold}''
```

Interpolation desugars to `concat [...]` with `toString` on each interpolated expression. Scalars
(`String`, `Number`, `Bool`) stringify directly. Structured values require explicit serialization,
usually `toJson`.

`toJson` emits canonical compact JSON with lexicographic object keys. `fromJson` parses a JSON
string back into a structured CorePure value. Both are deterministic and intended for text/config
construction, not host authority.

Division uses finite `Float64` semantics rather than exact rational or `Scientific` quotient
construction. Division by zero and non-finite float results are typed CorePure failures.

## 9. Imports And File Returns

`import name from "path.wire" ;` imports the file-return value from another file.
`import { a, b } from "path.wire" ;` imports exported names. Contract assertions are ambient once a
file is loaded.

A file without a file-return expression is declaration-only: it contributes contract assertions and
importable `let` names.

Node declarations bind names in the local graph namespace. To expose a node through imports, bind a
value:

```wire
node planner
  -> plan: PlannerOutput = @review.planner ({});

export let exported_planner = planner;
```

## 10. Type-Checking Summary

A program is well formed iff:

1. every referenced contract is known;
2. every executor reference names a registered executor;
3. every configured executor value validates against its config schema where required by the binding
   layer;
4. every executor call in graph position appears inside an explicit node declaration;
5. every node's authored port boundary satisfies the executor projection or structural constraints;
6. every graph expression contains only graph values;
7. `=>` produces no cardinality violations;
8. pure output equations match their declared output labels exactly;
9. CorePure expressions type-check against the closed builtin environment;
10. file-return position is either absent or a graph value.

Well-formed graph values may have open input boundaries. Preparing a wire for execution is stricter:
every required input boundary must be supplied before Pulse can run it.

## 11. Complete Example

```wire
let threshold = 0.7;

let analyst = @review.analyst {
  model = "gpt-5.4";
  temperature = 0.2;
};

node gather
  -> evidence: EvidenceSet = @review.gather ({});

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = pure (accepted);
  -> rejected: RejectedSet = pure (rejected);
  -> summary: Report = pure (''
    Classification complete.
    Accepted: ${length accepted}
    Rejected: ${length rejected}
    Threshold: ${threshold}
  '');
  where let
    items = evidence.items;
    accepted = items |> filter (x: x.score >= threshold);
    rejected = items |> filter (x: x.score < threshold);
  in
  { inherit items accepted rejected; };

node analyze
  <- accepted: AcceptedSet;
  -> analysis: AnalysisRecord;
  = analyst ({
    inherit accepted;
    instructions = "Analyze ${length accepted.items} accepted items.";
  });

gather
  => classify
  => analyze
```

## 12. Rejected Legacy Surface

The implementation rejects the previous authoring surface:

- `node name : ...`;
- unlabeled authored ports;
- `<- [Contract]` implicit list aggregation;
- `@executor { ... }` in graph position;
- `@pure`, `@pure { expr = ... }`, and `pure { ... }`;
- node-local `let ... in` blocks before node bodies;
- configured-executor config merge with `//`;
- comma overlay shorthand in file-return expressions.
