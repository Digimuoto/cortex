---
title: "ADR 0031 - Wire Binding Forms and Node Where Clauses"
description:
  "Restricts `let ... in` to expression position, retains module-level `let X = e;` as a
  declaration, and introduces node-local `where <record-expr>` clauses that open a record's fields
  into the node body's lexical scope."
sidebar:
  label: "0031. Binding forms and where"
  order: 31
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0031 - Wire Binding Forms and Node Where Clauses

## Status

Proposed - separates Wire's three binding surfaces (expression, module-level declaration,
node-local) into three distinct syntactic forms, and removes the node-local `let ... in` decoration
introduced in ADR 0022 and carried into ADR 0030.

## Context

Wire currently uses `let ... in` in three places that look like one construct but mean different
things:

1. As a CorePure expression form, exactly as in ADR 0023's expression surface.
2. As a module-level binding, written without `in` (`let analyst = @review.analyst { ... };`).
3. As a node-local block placed between input clauses and pure output equations, scoping
   intermediate CorePure bindings across every output equation in that node.

The third form is the smell. In `let bindings in <pure-output-equations>`, the body after `in` is
not an expression - it is a list of structural output declarations. The construct borrows
expression-level let-in syntax to decorate a structural form with locals. That mismatch is visible
in the grammar as `[ let <corepure_binding>+ in ]` sitting between the input clauses and the
equations of `node_decl` (Reference/Wire/grammar.md §6.1).

Once `let ... in` is recognized as an expression form, the tempting extension is to use it around
node declarations as well. That is the boundary this ADR draws: a top-level `node` is a declaration,
not an expression body. A top-level form `let bindings in <node-declaration>` would duplicate the
same scoping role as a node-local `where` clause while making declaration positions expression-like.
It adds no power and makes the grammar harder to reason about.

ADR 0030 introduces node-level executor bodies but keeps the historical node-local `let ... in`
between inputs and outputs for pure nodes. This ADR replaces that decoration with an honest
node-attached `where` clause and makes `let ... in` strictly an expression-level construct.

## Decision

Wire has three binding surfaces. Each has its own form.

### 1. Expression-level `let ... in`

`let ... in` is an expression form. The body after `in` is itself an expression of the same kind as
the surrounding context.

```ebnf
let_expr        ::= let <bindings> in <expr>
bindings        ::= (<name> = <expr> ;)+
```

Every binding is terminated by `;`, including the last binding before `in`. This matches the
terminator style used elsewhere in Wire (input clauses, output equations) and means the grammar is
not whitespace-sensitive: line breaks are just whitespace, and termination is determined by `;` and
reserved keywords.

The body is a CorePure expression in CorePure position and a Wire value expression in Wire-value
position. Bindings are non-recursive and evaluated in declaration order. This matches ADR 0023's
CorePure semantics and applies uniformly at the Wire-value level. `let ... in` may nest:

```text
let y = let x = 1 in x + 1 in y * 2
```

Legal positions are exactly the expression positions defined elsewhere: the right-hand side of any
CorePure output equation, the argument of an executor call, the right-hand side of a `where`
binding, and the body of another `let ... in`.

### 2. Module-level `let X = e;`

Module-level binding is a declaration without `in`. The bound name is in scope for the rest of the
module. The right-hand side is a graph expression, an ordinary Wire value expression, or a CorePure
helper expression.

```ebnf
let_decl        ::= let <name> = <let_rhs> ;
              |  export let <name> = <let_rhs> ;
let_rhs         ::= graph_expr | value_expr | corepure_helper_expr
```

This covers graph composition values, configured executors (ADR 0025), ordinary pure-data values,
records, and CorePure helpers. The declaration syntax is phase-neutral: graph values and ordinary
closed values elaborate at compile time; CorePure helpers are delayed until the pure evaluator has
node inputs available. Authority-free compile-time data values may be captured into delayed CorePure
evaluation as constants. Graph values and configured executor values may not be captured into
CorePure.

The `export let` modifier from ADR 0022 is preserved unchanged: it remains a property of the
top-level binding and does not interact with where-clauses. Where-clauses are bound to a node value,
not to a top-level name; they cannot be exported on their own.

Nothing changes about the declaration form except that it is now the _only_ `let` form permitted at
top-level positions.

### 3. Node-local `where` clauses

A `node` declaration may carry an optional trailing `where` clause that brings the fields of a
CorePure record value into the lexical scope of the node body. This replaces the prior node-local
`let ... in` form.

```ebnf
node_decl       ::= node <name>
                    (input_clause ;)*
                    node_body
                    (where_clause)?
where_clause    ::= where <expr> ;
```

`<expr>` is any CorePure expression that evaluates to a record. Its fields become lexical names
visible to every output equation and executor argument expression in the node body. The trailing `;`
terminates the where-clause uniformly with every other node-internal clause (input, output, executor
body); the inner expression parses with the same rules used for any other expression position.
`node_body` is the per-form body grammar from ADR 0030: pure output equations, an executor body, or
the single-output executor shorthand.

The where-clause attaches to the node declaration itself. It is part of the node's authored body,
not a top-level binding modifier and not an exported value. Earlier sketches considered anonymous
node values (`let X = node ...`); this implementation slice keeps named `node X ...` as the only
node authoring form. If anonymous node values return later, they must reuse the same where-clause
semantics rather than inventing a second local-binding surface.

In ADR 0039's node-boundary normal form, `where` contributes authority-free local scope for ingress
and egress expressions. It is not graph topology, edge behavior, or hidden executor authority.

Parentheses around the where-expression are never required. CorePure expression forms terminate
themselves: a record literal at `}`, a `let ... in <body>` at the body's own end, a name at the end
of the identifier. The where-clause's trailing `;` then closes the clause.

#### Why a record, not a binding list

A bare-binding form (`where x = e1; y = e2;`) forces a scope choice. Recursive scope is a known
footgun (Nix's `rec`). Non-recursive scope produces independent-fields semantics that already exist
in CorePure record literals. Taking a record value reuses what is already specified in ADR 0023 and
pushes any sequential intermediate computation into a `let ... in` that produces the record - an
explicit, well-understood form rather than a new binding rule.

#### Common case: record literal

When fields are independent (no shared intermediate computation), the where-expression is a record
literal:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = filtered_high;
  -> rejected: RejectedSet = filtered_low;
  where {
    filtered_high = evidence.items |> filter (x: x.score >= 0.7);
    filtered_low  = evidence.items |> filter (x: x.score <  0.7);
  };
```

#### Shared intermediates: `let ... in { ... }`

When several record fields share computation, the where-expression is a `let ... in` whose body is a
record literal:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = accepted;
  -> rejected: RejectedSet = rejected;
  where let
    items          = evidence.items;
    accepted_items = items |> filter (x: x.score >= 0.7);
    rejected_items = items |> filter (x: x.score <  0.7);
  in
  { accepted = accepted_items; rejected = rejected_items; };
```

The `let` is sequential CorePure (ADR 0023). The record literal exposes the public names. `where`
opens those names into the node body's scope. No parentheses are required: the record literal's `}`
ends the let-in body, and the where-clause's trailing `;` closes the clause.

#### Shared module-level config

Any authority-free pure-data record value works, including a let-bound one:

```wire
let defaults = { factor = 0.7; threshold = 100; };

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= factor);
  where defaults;

node strict
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= factor + 0.1);
  where defaults;
```

Both nodes see `factor` and `threshold` during delayed pure evaluation. No parameter threading, no
duplication. The same capture rule does not apply to graph values or configured executor values.

#### Executor and zero-output forms

The same `where <record-expr>` form attaches to executor nodes:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = @review.analyze (payload);
  where { payload = { items = evidence.items |> filter (x: x.score >= 0.5); }; };
```

```wire
node logEvent
  <- event: Event;
  = @artifact.log (decorated);
  where { decorated = { event = event; ts = event.timestamp; }; };
```

#### Invariant: where-records have a statically determinable field set

The where-record's field set must be resolvable at elaboration time. This is a normative admission
rule, not an idiom:

> **WHERE-STATIC-FIELDS** — for every `where <expr>;` clause, the elaborator must determine the set
> of field names produced by `<expr>` without runtime evaluation. Admission rejects any
> where-expression whose field set is not statically determinable, with a typed diagnostic naming
> the offending clause.

In practice the where-expression is one of:

- a record literal `{ a = …; b = …; }`,
- a `let ... in` whose body is a record literal,
- a bare reference to a let-bound record literal (or chain thereof),
- a record-merge `R1 // R2` whose constituents satisfy WHERE-STATIC-FIELDS.

Forms that violate the invariant - a function whose return type is a record but whose field set
depends on its input, a conditional that picks between records of different shapes, a record value
constructed by reduction over runtime data - are rejected at admission. Loosening this invariant is
out of scope for this ADR; revisit only if a concrete authoring need surfaces.

#### Edge cases

- **Input-port and where-field collision.** If a where-record introduces a field whose name matches
  an input port on the same node, admission rejects the node with a typed diagnostic. Input ports
  are the node's typed boundary; where-fields are local convenience. The static error is preferred
  over a shadowing rule because the silent rule would let one of two visibly distinct authoring
  surfaces win without informing the reader.

- **Forward references inside a where-record.** Record fields are independent (ADR 0023). A
  where-expression `where { x = y; y = 1; };` does not see `y` from inside `x`. Authors who need
  sequential dependency wrap in `let ... in { ... }` per the shared-intermediates pattern.

- **Multiple where-clauses on one node.** Forbidden by the grammar (`(where_clause)?` is optional
  but at most one). A second where-clause is a parse error.

- **Where-clauses on configured executor values.** Configured executors are inert values, not graph
  vertices and not node bodies. They do not accept `where`. A where-clause belongs only on an
  explicit `node` declaration after the node implementation body.

### Top-level positions accept only declarations

The grammar rule that closes the loop:

> Top-level positions accept declarations only: `contract`, `node`, and `let X = e;`. A `let ... in`
> cannot appear in a top-level position.

`let bindings in node X <- ...` is therefore a parse error at the module top level. Authors who want
a name shared across nodes use a module-level `let X = e;` declaration; authors who want a name
local to a single node use a `where` clause; authors who want a CorePure local inside a single
expression use expression-level `let ... in` in that expression.

This rule falls out of the kinds: `let ... in` produces an expression; a top-level `node X <- ...`
is a declaration, not an expression. Wrapping a declaration in an expression form is ill-kinded.

### Deprecation of node-local `let ... in`

The prior node-local `let ... in` form between input clauses and pure output equations
(Reference/Wire/grammar.md §6.1, ADR 0022 clause grammar) is removed. Existing examples that use it
are rewritten by moving the let-block inside a where-record. Mechanical rewrite:

```text
-- before
node score
  <- evidence: EvidenceSet;
  <- weights: WeightSet;
  let
    scores   = map (item: item.score) evidence.items;
    weighted = zipWith (s: w: s * w) scores weights.values;
  in
  -> score: ScoreSet = { total = sum weighted; count = length weighted; };

-- after
node score
  <- evidence: EvidenceSet;
  <- weights: WeightSet;
  -> score: ScoreSet = { total = sum weighted; count = length weighted; };
  where let
    scores   = map (item: item.score) evidence.items;
    weighted = zipWith (s: w: s * w) scores weights.values;
  in
  { scores = scores; weighted = weighted; };
```

The `let` preserves CorePure's sequential binding semantics; the record literal exposes the public
names; `where` brings those names into node-body scope. Same evaluation order, same shadowing rules
(record fields shadow module-level delayed bindings and captured constants), no rec.

## Alternatives considered

- **Keep node-local `let ... in` as a structural decoration.** Rejected because the body after `in`
  is a list of output equations, not an expression. The construct borrows expression-level syntax to
  do something that is structurally a `where`-style decoration. Authors and tooling have to learn
  that one specific `let ... in` does not behave like an expression-level `let ... in`.

- **Allow top-level `let ... in <node-decl>` and lint it.** Rejected. The form provides nothing that
  module-level `let X = e;` and node-local `where` together do not already cover. A lint rule lets
  the smell compile, get copied, and become cargo cult; making the form ungrammatical at the parse
  level removes the failure mode entirely. The cost is one extra "this position is a declaration,
  not an expression" sentence in the grammar reference.

- **Express node-local sharing only by promoting the shared computation to its own node.** Rejected
  for the first slice. Promotion is the most graph-native answer and remains a recommended pattern
  when the shared computation is non-trivial, but forcing it for every two-line CorePure
  intermediate produces excessive node boundaries for purely local readability concerns. `where`
  retains the option without forcing it.

- **Reintroduce anonymous node values in this slice (`let X = node ...`).** Deferred. The old sketch
  promised equivalence with `node X ...`, but the current grammar and implementation only need named
  node declarations. Keeping anonymous node values out of this slice prevents `let` from becoming
  declaration-shaped again, which is the ambiguity this ADR removes.

- **Make `where` a bare-binding form (`where x = e1; y = e2;`).** Rejected. A bare-binding form
  forces a scope choice between recursive and non-recursive bindings. Recursive scope is a known
  footgun (Nix's `rec`); non-recursive scope produces independent-fields semantics that already
  exist in CorePure record literals (ADR 0023). Treating the where-expression as a record value
  reuses what is already specified, makes sequential intermediates explicit via
  `let ... in { ... }`, and avoids defining a new binding form with new scope rules.

- **Add letrec records (or `rec { ... }`) to CorePure so `where rec { ... }` is recursively
  scoped.** Rejected. CorePure is deliberately non-recursive (ADR 0023). Recursive bindings require
  fixpoint semantics, termination analysis, and a larger evaluator surface. The cost is not
  justified by the marginal where-clause ergonomics that `let ... in { ... }` already covers
  explicitly.

## Consequences

### Positive

- Each binding surface has a syntactic form that matches what it actually does. Expression-level
  bindings use `let ... in`; module-level declarations use `let X = e;`; node-local intermediates
  use `where <record-expr>`.
- `where` introduces no new construct: it reuses CorePure's existing record literal, `let ... in`,
  and let-bound name forms. The new specification work is the lexical-scoping rule (open the
  record's fields into the node body), nothing else.
- Termination of the where clause falls out of the record expression's own termination - `}`, `)`,
  or end of a let-in body. No layout sensitivity, no per-binding lookahead rule, no special boundary
  detection.
- No rec semantics, no Nix-style scoping footgun. Independent fields are enforced by record
  semantics; sequential intermediates are explicit via `let ... in`.
- Composes with module-level pure-data records: `where defaults` opens any record into a node's
  scope, supporting parameter sharing across nodes without threading.
- The grammar shrinks: one `let ... in` rule with a single semantics, used uniformly wherever
  expressions appear.
- Top-level positions are unambiguously declaration positions. New authors cannot accidentally scope
  a name to a single node by writing `let x = ... in node Y ...` at module top.
- Multi-output pure nodes keep their port-local readability while sharing intermediate values
  cleanly.

### Negative

- The shared-intermediates case requires explicit `where let ... in { ... };` wrapping. A few extra
  tokens are the price of separating _computation_ (sequential `let`) from _exposed names_ (record
  fields).
- Existing `.wire` examples and tests that use node-local `let ... in` must be rewritten with the
  let-in-record form. The rewrite is mechanical.
- Authors must learn the three forms and which surface each lives on. The mapping is straightforward
  (expression / module / node) but is one more concept than the prior single keyword pretended to
  offer.
- Tree-sitter grammar, the parser, the elaborator, and any docs-site Wire snippets must be updated.

### Obligations

- Update `docs/Reference/Wire/grammar.md` §6.1 to remove the node-local `let ... in` block from
  `node_decl` and add the `where_clause` production.
- ADR 0022 (Wire Node Clause Grammar) is amended in place (proposed status): `let_block` is removed
  from the `node_decl` production, the node-local `let ... in` prose is replaced with a pointer to
  this ADR, the worked example is rewritten to use the where-clause, and a forward note is added in
  the Status section. The `related` list is updated to include this ADR.
- ADR 0030 (Wire Node Implementation Forms) is amended in place (proposed status): `let_block` is
  removed from the `node_decl` production, `(where_clause)?` is added per this ADR, and an inline
  forward pointer to this ADR is added.
- Rewrite the affected sections of `docs/Reference/Wire/pure-execution.md`: the grammar at `:60`,
  the scope rules at `:75-76`, the `localBindings` schema entry at `:104`, the evaluation-order
  rules at `:115-116`, the admission diagnostics at `:245-246`, and the scope-distinction note at
  `:257`. Replace node-local `let ... in` semantics with the where-record semantics from this ADR.
- Add a "binding surfaces" subsection to `docs/Architecture/05-wire-language.md` so the canonical
  chapter names the three-surface story (expression / module / node-local) rather than leaving it in
  ADRs and reference docs only.
- Add parser tests for: `where` on pure nodes, `where` on single-output executor nodes, `where` on
  multi-output executor nodes, `where` on zero-output executor nodes, where-expression as record
  literal, where-expression as `let ... in { ... }`, where-expression as bare reference to a
  let-bound record, expression-level `let ... in` in CorePure position, expression-level
  `let ... in` in Wire-value position, parse-error coverage for `let ... in` at top-level positions,
  admission-error coverage for input-port / where-field name collisions, and admission-error
  coverage for where-expressions whose field set is not statically determinable
  (WHERE-STATIC-FIELDS).
- Mechanically rewrite all in-tree Wire examples and editor corpus samples that use node-local
  `let ... in` to use `where`.
- Update tree-sitter-wire grammar and the tree-sitter corpus.
- Update admission-time diagnostics to point at the `where` rewrite when authors write `let ... in`
  in a position that is no longer accepted, and to surface WHERE-STATIC-FIELDS violations and
  input-port / where-field collisions with explicit messages.

## Traceability

- Feature keys: `wire.binding_forms`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/pure-execution.md`
- Implementation: `src/Cortex/Wire/Parser.hs` (expression `let ... in`, module-level `let`, and
  node-local `where` parsing), `src/Cortex/Wire/Pure.hs` (`corePureWhereStaticFields`,
  `PureStaticFieldSetUndeterminable` — the WHERE-STATIC-FIELDS admission invariant),
  `src/Cortex/Wire/AST.hs` (`WireDuplicateLetBinding`, `WireUnknownLetBinding`)
- Tests: `test/Cortex/Wire/PureSpec.hs` (`corePureWhereStaticFields`, static-field-set rejection,
  where-field shadowing), `test/Cortex/Wire/ParserSpec.hs` (pure output equations with a
  where-clause)
- Theory/proof: [CorePure `where` fields](../Reference/proof-status.md)

## Related

- [ADR 0020 - Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0023 - CorePure Expression Surface](./0023-corepure-expression-surface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0030 - Wire Node Implementation Forms](./0030-wire-node-implementation-forms.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
- [Pure Execution](../Reference/Wire/pure-execution.md)
