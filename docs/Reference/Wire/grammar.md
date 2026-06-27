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
  - docs/ADRs/0045-wire-compile-time-node-body-kinds.md
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
---

# The Wire Language — Specification

Wire is the Cortex source language for authoring typed dataflow topology over a closed executor
alphabet. A Wire file declares contracts, configured executor values, nodes, and graph composition.
The compiler elaborates the source to a fixed circuit before Pulse evaluates it.

The current grammar is intentionally explicit:

- every authored node has typed input and output clauses;
- every authored port has a label;
- `@` names registered executor authority, never CorePure;
- output equations are CorePure expressions inside Wire's deterministic expression layer;
- configured executor values are reusable values, not graph vertices;
- fan-in and fan-out transformations are authored as nodes, not implicit context concatenation or
  implicit list aggregation.

## 1. Lexical Structure

Whitespace is insignificant except as a separator. Line comments start with `#`. Block comments use
`/* ... */` and do not nest.

Identifiers match `[A-Za-z_][A-Za-z0-9_]*`. Qualified identifiers join identifiers with `.`.

Reserved words:

```text
as contract else export false form from if import in kind let make node null pure select then true use where
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
wire_file        ::= top_form* file_return?
top_form         ::= contract_decl | use_stmt | kind_decl | form_decl | let_binding | import_stmt | node_decl
file_return      ::= wire_expr

contract_ref     ::= Name | "[" Name ";" integer "]"
contract_decl    ::= "contract" Name contract_record? ";"
contract_record  ::= "{" contract_field* "}"
contract_field   ::= ident ":" contract_ref ";"
use_stmt         ::= "use" qualified_ident "." "{" use_item ("," use_item)* ","? "}" ";"
use_item         ::= "@" ident ("as" "@" ident)? | ident ("as" ident)?
kind_decl        ::= "kind" ident "(" kind_param_list? ")" "=" kind_body
kind_param_list ::= kind_param ("," kind_param)* ","?
kind_param       ::= ident ":" kind_param_class
kind_param_class ::= "PortLabel" | "Contract" | "Value" | "ConfiguredExecutor"
form_decl        ::= "form" ident "(" form_param_list? ")" "=" "{" form_item* graph_expr ";" "}" ";"
form_param_list ::= form_param ("," form_param)* ","?
form_param       ::= ident ":" form_param_class
form_param_class ::= "PortLabel" | "Contract" | "Value" | "Graph" | "ConfiguredExecutor"
form_item        ::= node_decl | "let" let_target "=" let_rhs ";"
let_binding      ::= ("export")? "let" let_target "=" let_rhs ";"
let_target       ::= ident "[]"?
let_rhs          ::= graph_expr | value_expr | corepure_helper_expr | form_application | make_application
form_application ::= ident "(" (wire_expr ("," wire_expr)* ","?)? ")"
make_application ::= "make" "(" make_count "," ident ","? ")"
make_count       ::= integer | ident
import_stmt      ::= "import" (ident | "{" ident ("," ident)* ","? "}") "from" string ";"
```

A file may end with one expression without a trailing semicolon. That expression is the file-return
value.

`export let` is accepted as the forward-compatible surface for imports. Until module imports grow a
visibility check, `export` does not change runtime behavior.

`use` imports selected names from a registry namespace into source scope. File imports and registry
namespace imports are distinct: `import` loads another `.wire` file; `use` selects registered
executor and contract names. The initial implemented namespace is `std.io`:

```wire
use std.io.{@stdin, @stdout, @command, @readFile, @writeFile, CommandSpec, CommandResult};
```

A `contract` declaration may optionally define a nominal record shape for `*`:

```wire
contract ExperimentResults {
  open0: CommandResult;
  open14: CommandResult;
  open12: CommandResult;
};
```

Record field contracts resolve through the `use` scope visible at the declaration point. The fields
do not create graph topology by themselves; they give `*` the nominal shape needed to synthesize a
record↔ports phantom adapter.

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
- CorePure helper functions, such as `let pred = item: item.score >= 0.7;`, bind delayed helpers for
  pure evaluation;
- bound form applications, such as `let open_phase_0 = open_arm(0.0);`, elaborate at compile time to
  graph values with scoped internal node identities. Form-local `let` bindings may also bind nested
  form applications.

Authority-free compile-time data values are also available to delayed CorePure expressions as
captured constants. Graph values and configured executor values are not.

## 3. Values

Wire has three relevant value classes.

**Graph values** are nodes, bound form applications, bound `make(...)` expansions, composed graph
expressions, and `()`. Only graph values may appear in file-return position or on either side of
graph operators.

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
is known if an executor registry declares it or the program asserts it with `contract Name;`.
`[T; N]` is a bounded indexed product contract with static non-negative count `N`; it is a
topology-shaping contract only when an explicit `*` adapter folds or unfolds it. `N = 0` is the
empty finite product and exposes no indexed leaves.

Port clauses:

```text
<- label: Contract;
-> label: Contract;
-> label_a: ContractA | label_b: ContractB;
```

Labels are required on authored ports. A port key is `(direction, contract, label)`. `=>` connects
only matching keys. Labels are semantic routing identity, not documentation.

All input ports are cardinality-one. Open fragments may expose unmatched input obligations; closed
actualized graphs require every input port instance to have exactly one producer edge. Wire no
longer has `<- [Contract]` list aggregation syntax. When many values must be gathered, author an
explicit node that receives distinct typed inputs and constructs a list or record in its
implementation body.

Output port instances are linear in closed actualized graphs. One output port instance may feed at
most one input edge; multi-consumer use must pass through an explicit fan-out, sharing, persistence,
or broadcast node that produces fresh output port instances.

Output sum groups use `|` and are output-only. A sum group means exactly one variant fires per
evaluation. Each variant has its own label and contract.

Empty input and output port sets are legal on executor-body nodes when the registered executor
admits them. There is no special `source` or `sink` syntax; empty boundary sides are just ordinary
typed interface shapes.

## 5. Nodes

```ebnf
node_decl ::= "node" ident (node_definition | node_kind_application)
node_definition ::= input_clause* node_body where_clause?
node_kind_application ::= "=" kind_application ";"
kind_application ::= ident "(" kind_arg_list? ")"
kind_arg_list ::= wire_expr ("," wire_expr)* ","?

kind_body ::= input_clause* node_body where_clause?

input_clause ::= "<-" ident ":" contract_ref ";"
where_clause ::= "where" corepure_expr ";"

node_body ::=
    pure_output_equation+
  | executor_output_clause* "=" executor_call ";"
  | "->" output_variant "=" executor_call ";"

pure_output_equation ::= "->" output_variant "=" corepure_expr ";"
executor_output_clause ::= "->" output_body ";"
output_body ::= output_variant ("|" output_variant)*
output_variant ::= ident ":" contract_ref
```

There is no colon after `node name`.

### 5.1 Node-Body Kinds

A `kind` declaration is a compile-time node-body abstraction. It supplies the typed boundary and
body of one node, but not the node head. The vertex is still introduced by `node <name>` at the
application site:

```wire
let h_gate = @quantum.h {};

kind one_qubit_gate(label: PortLabel, gate: ConfiguredExecutor) =
  <- label: Qubit;
  -> label: Qubit;
  = gate (label);

node screen_h = one_qubit_gate(screen, h_gate);
```

Kind applications elaborate before graph lowering. The expanded program is equivalent to the
ordinary node declaration:

```wire
node screen_h
  <- screen: Qubit;
  -> screen: Qubit;
  = h_gate (screen);
```

Rules:

- a kind body contains normal node input/output/body clauses plus an optional `where` clause;
- a kind body does not contain a `node` head;
- a kind application is valid only in `node <name> = kind_name(...);` position;
- kind applications are not graph expressions, CorePure expressions, or standalone declarations;
- parameter classes are syntactic classes: `PortLabel`, `Contract`, `Value`, and
  `ConfiguredExecutor`;
- `kind` declarations do not create graph values and cannot appear in file-return position.

### 5.2 Graph Forms

A `form` declaration is a compile-time graph abstraction. It may declare local nodes and local
bindings, then returns one final graph expression:

```wire
let h_gate = @quantum.h {};

kind one_qubit_gate(label: PortLabel, gate: ConfiguredExecutor) =
  <- label: Qubit;
  -> label: Qubit;
  = gate (label);

kind phase_gate(label: PortLabel, angle: Value) =
  <- label: Qubit;
  -> label: Qubit = @quantum.rz { inherit angle; } (label);

form open_arm(phase: Value) = {
  node split = one_qubit_gate(screen, h_gate);
  node phase_shift = phase_gate(screen, phase);
  node recombine = one_qubit_gate(screen, h_gate);

  split
    => phase_shift
    => recombine;
};

let open_phase_0 = open_arm(0.0);
```

Rules:

- form applications are valid when bound by module-level `let`, module-level `export let`, or a
  form-local `let` inside another form;
- the binding name supplies the stable identity prefix for local nodes;
- nested form applications inherit a hierarchical prefix from the containing form instantiation and
  local binding name;
- local nodes and local bindings are fresh per instantiation;
- names captured from surrounding source scope are shared;
- forms are non-recursive in v1;
- form applications are not valid inside `where` clauses or any other CorePure expression;
- inline form applications in graph position are rejected.

After expansion, a form instantiation is an ordinary graph value composed from ordinary nodes.

### Bounded Node Generation

`make(N, K)` is a compile-time graph form that expands to N fresh nodes from kind `K`. It is valid
only when bound by `let` / `export let` or by a form-local `let`; inline `make(...)` in graph
position is rejected because there is no source name to derive stable identities from.

`N` must be a static non-negative count: either an integer literal or the name of a preceding closed
numeric `let`. `K` is a kind reference, not a kind application and not a CorePure value. Generated
nodes get deterministic identities from the binding name and expose the generated port labels
specified by the kind.

An indexed binding marks the generated family as addressable by static source projection:

```text
let workers[] = make(3, sample);

workers[0]
workers[1]
workers[2]
```

The whole family name still denotes the overlay of all generated children in graph position.
Projection indices must be integer literals in range. Lowered node identities remain the stable
`<binding>_<i>` form.

`makeEach(items, K)` is the itemized form. `items` must be a static list literal or preceding static
list binding. Items may be strings or records with a string `label` field. Generated nodes use
`<binding>_<label>` identities. `K` must declare either one `PortLabel` parameter, or
`PortLabel, Value` when the full item record should be passed into the generated kind application.
When that `Value` parameter is used, each item payload must be representable as the proof-side
static-value subset: strings, booleans, natural numbers, lists, and records whose fields recursively
contain values from the same subset. Record keys are flat field labels; dotted field paths are
rejected and duplicate record fields are rejected before admission artifacts are emitted.

### Source Includes

`include_str("path")` / `includeStr("path")` and `include_dir("path")` / `includeDir("path")` are
source-elaboration forms, not runtime CorePure builtins. They are expanded before parsing the Wire
file; missing paths are compile-time errors.

Relative paths resolve against the containing Wire file. `include_str` embeds a UTF-8 file as a
string literal. `include_dir` embeds a sorted list of direct directory-entry records with `name`,
`path`, `stem`, `extension`, `label`, and `entryType` fields.

### 5.3 Pure Output Equations

Pure nodes compute deterministic JSON-shaped values:

```wire
let scoreThreshold = 0.7;

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = evidence.items |> filter (item: item.score >= scoreThreshold);
  -> rejected: RejectedSet = evidence.items |> filter (item: item.score < scoreThreshold);
```

Rules:

- pure output equations write the CorePure expression directly after `=`;
- `pure (...)`, `@pure`, `pure { ... }`, and string-valued `expr = ...` configs are rejected;
- every pure equation declares exactly one output port;
- pure equations do not declare sum groups;
- an optional trailing `where <record-expr>;` clause opens statically known record fields into all
  equations in the node;
- node-local `let ... in` blocks before the body are rejected;
- top-level delayed bindings and captured pure-data constants are visible to later pure nodes.

The `where` expression must have a statically determinable record field set: record literals,
`let ... in { ... }`, references to let-bound records, and right-biased record merges with `//` are
admitted. Dynamic shapes such as conditionals are rejected at admission.

### 5.4 Executor Bodies

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

```ebnf
wire_expr    ::= connect_expr
               | connect_expr "select" "(" arm ("," arm)* ","? ")"
connect_expr ::= overlay_expr (("=>" | "*") overlay_expr)*
overlay_expr ::= atom ("<>" atom)*
```

`<>` overlays graph values. It is set union on nodes and edges when the operands have disjoint node
identities. Repeating the same node identity in both operands is a static topology error; overlay
does not clone nodes.

`,` is not a graph operator. Use `<>` for overlay.

`=>` matches left-side output boundary ports against right-side input boundary ports by
`(contract, label)`. For each compatible output/input pair:

- if both endpoint ports have exactly one compatible counterpart across the boundary, `=>` creates
  one edge;
- if an endpoint port has no compatible counterpart, it remains exposed on the composed boundary;
- if an output has several compatible inputs, the composition is a static topology error;
- if an input has several compatible outputs, the composition is a static topology error.

Every endpoint port is linear in graph composition: one output feeds at most one input, and one
input receives at most one output. `=>` does not perform implicit fan-out or aggregation.

`*` inserts an explicit finite-product adapter node between its operands. It is not an exception to
the `=>` rule: both sides of the adapter connect through ordinary linear endpoint matching. Record
contracts fold/unfold by field label; bounded indexed contracts such as `[Sample; 3]` fold/unfold a
static ordered frontier without allowing unbounded list-shaped topology.

Topology operators have fixed precedence:

| Tightness | Operators  | Associativity |
| --------- | ---------- | ------------- |
| Tighter   | `<>`       | left          |
| Looser    | `=>` / `*` | left          |

Tighter binds first, so:

```wire
a
  => b
  => c <> d
```

parses as `a => b => (c <> d)`. The expression is still admitted only if the final connect obeys the
linear endpoint rule.

`()` is the empty graph value and identity for overlay/connect.

`select(...)` is the conditional continuation form over an exclusive output boundary. Its detailed
semantics are specified in [conditionality.md](conditionality.md).

## 8. CorePure Expressions

CorePure is the deterministic expression language used by output equations and executor input
arguments. It has no IO, imports, recursion, host callbacks, model calls, tool calls, time, or
randomness. CorePure expressions evaluate when the node input ports they reference are available.
They may also reference module-level pure-data constants and CorePure helper functions declared
earlier in the file.

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

```text
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

`import name from "path.wire";` imports the file-return value from another file.
`import { a, b } from "path.wire";` imports exported names. Contract assertions are ambient once a
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
  -> accepted: AcceptedSet = accepted;
  -> rejected: RejectedSet = rejected;
  -> summary: Report = ''
    Classification complete.
    Accepted: ${length accepted}
    Rejected: ${length rejected}
    Threshold: ${threshold}
  '';
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
- `pure (...)`, `@pure`, `@pure { expr = ... }`, and `pure { ... }`;
- node-local `let ... in` blocks before node bodies;
- configured-executor config merge with `//`;
- comma overlay shorthand in file-return expressions.
