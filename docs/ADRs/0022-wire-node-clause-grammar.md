---
title: "ADR 0022 - Wire Node Clause Grammar"
description:
  "Defines the next Wire node surface: clause-terminated inputs and per-output RHS forms. Node-local
  intermediates were originally specified here as a `let ... in` block; that surface is superseded
  by the where-clause introduced in ADR 0031."
sidebar:
  label: "0022. Node clause grammar"
  order: 22
status: superseded
date: 2026-04-29
superseded_by: docs/ADRs/0095-wire-single-record-executor-boundary.md
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0030-wire-node-implementation-forms.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0022 - Wire Node Clause Grammar

## Status

Superseded by ADR 0095. This ADR replaced the historical colon-led node body and string-config pure
examples with the clause grammar for the next Wire implementation phase. ADR 0020's decision on pure
output equations remains in force.

Forward note: ADR 0050 supersedes this ADR's explicit `pure (...)` output wrapper. CorePure output
expressions are now written directly after `=`.

Forward note: ADR 0030 extends this grammar with node-level executor bodies for zero-output and
multi-output external executors. This ADR's per-output equation grammar remains the pure-node
surface.

Forward note: ADR 0031 supersedes the node-local `let ... in` block originally defined here. The
`let_block` production and its scope rules are removed; node-local intermediates are now expressed
via the `where <record-expr>;` clause defined in 0031.

## Context

ADR 0020 accepted pure output equations, but the first implementation kept some transitional syntax
around the existing parser. The next phase can remove that legacy shape instead of preserving
compatibility:

- `node name :` should no longer be necessary;
- `@pure { expr = "..." }` should remain historical syntax;
- port labels should be declared exactly where routing happens;
- node-local shared work should have one obvious scope.

The syntax also needs to preserve the authority boundary from ADR 0010 and ADR 0017. Direct CorePure
output expressions are internal deterministic Wire evaluation. `@executor (...)` is the boundary to
registered external authority.

## Decision

Wire should adopt this node grammar:

```ebnf
wire_file   ::= (top_decl ;)*
top_decl    ::= let_binding | export let_binding | node_decl
let_binding ::= let <name> = <expr>
node_decl   ::= node <name>
                  (input_clause ;)*
                  (output_clause ;)+
                  (where_clause)?           -- per ADR 0031

input_clause  ::= <- <name> : <Type>
output_clause ::= -> <name> : <Type> = <rhs>
rhs           ::= <corepure-expr> | @<executor> (<expr>)
```

The `where_clause` production and its scope rules are defined in
[ADR 0031](./0031-wire-binding-forms-and-where-clauses.md). The earlier `let_block` production -
`let <bindings> in` between input clauses and output clauses - is removed.

ADR 0050 chooses the unmarked CorePure expression form for deterministic output equations. Runtime
external authority remains explicit through `@`.

### Node Clauses

Node declarations do not use a colon after `node <name>`. Legal continuations already begin with
`<-`, `->`, `=`, or trailing `where`, so the colon adds no disambiguation.

Each input and output clause is terminated by `;`. This keeps clauses symmetric and avoids a body
delimiter.

A node may carry at most one trailing `where <record-expr>;` clause for node-local intermediates.
Scope rules, the static-field-set invariant, the input-port collision rule, and the supported
where-expression shapes are specified in [ADR 0031](./0031-wire-binding-forms-and-where-clauses.md).
The original node-local `let ... in` block defined here has been superseded; this section is
retained only to record that supersession.

### File-Level Bindings

File-level `let` bindings are private by default:

```wire
let acceptedItem = x: x.score >= 0.7;
```

`export let` opts a binding into the future import surface:

```wire
export let scoreThreshold = 0.7;
```

Until imports land, `export` has no runtime effect. It is accepted to give the grammar the correct
migration path.

Earlier sketches said `let x = node ...` and `node x ...` would denote the same topology binding.
ADR 0031 narrows the first implementation slice: top-level `let` remains for value expressions, and
named node definitions use `node x ...`. A future ADR may reintroduce anonymous node values if a
composition use case needs them. Current style guidance is:

- use `node x ...` for named node definitions;
- reserve `let x = ...` for ordinary pure-data values, configured executor values, delayed CorePure
  helpers, and composition expressions once topology composition syntax lands.

### Output RHS Forms

Output equations bind routing labels directly:

```text
-> accepted: AcceptedSet = accepted;
-> rejected: RejectedSet = rejected;
-> report: Report = @review.summarize (prompt);
```

The declared output port name is the routing key. There is no `return accepted = ...` syntax and no
separate output-map block.

Binding must enforce a bijection between declared output ports and output equations:

- every declared output has exactly one equation;
- every equation names a declared output;
- repeated equations for the same port are compile errors;
- missing equations are compile errors;
- output payloads validate against their declared contract and payload kind.

### CorePure Versus `@`

CorePure output expressions do not use `@`. In Wire syntax, `@` marks the boundary to registered
external authority whose behavior is not defined by the Wire theorem layer. The pure evaluator is
internal, deterministic, closed, and subject to the CorePure semantics from ADR 0023.

Lowering may still represent CorePure residue as an internal executor task in the compiled circuit.
That is an implementation detail of the runtime substrate, not an authoring claim that pure
evaluation is unknown authority.

## Worked example

```wire
let scoreThreshold = 0.7;

node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = accepted;
  -> rejected: RejectedSet = rejected;
  -> summary:  Report      = ''
    Classification complete.
    Accepted: ${length accepted} items
    Rejected: ${length rejected} items
    Threshold: ${scoreThreshold}
  '';
  where let
    items    = evidence.items;
    accepted = items |> filter (x: x.score >= scoreThreshold);
    rejected = items |> filter (x: x.score <  scoreThreshold);
  in
  { accepted = accepted; rejected = rejected; };
```

## Alternatives considered

- **Keep `node name :`.** Rejected because clause starts are already unambiguous and the colon is
  legacy syntax.
- **Allow several node-local `let` blocks.** Rejected because it creates avoidable scope and order
  questions. One block provides shared input-dependent work without that footgun. ADR 0031 later
  removes the node-local `let ... in` block entirely in favor of a single trailing `where` clause;
  the multi-block question is moot under that decision.
- **Use `return port = ...`.** Rejected because it duplicates the routing label. The output clause
  already names the port and contract.
- **Spell pure runtime evaluation as `@pure`.** Rejected for the source surface because `@` means a
  registered external authority boundary. Pure evaluation is inside Wire's deterministic layer.

## Consequences

### Positive

- Node authoring becomes regular: input clauses, output clauses, an optional trailing `where` clause
  (per ADR 0031).
- Output labels, contracts, and expressions stay visibly tied together.
- The parser can reject legacy pure syntax instead of carrying compatibility branches.
- The `@` authority boundary remains meaningful.

### Negative

- Existing test fixtures and grammar docs that use `node name :` must be rewritten.
- The parser must enforce clause order and the single local `let` block rule.
- The future unmarked RHS form needs a later ADR or an amendment before implementation.

### Obligations

- Update parser tests to reject `node <name> :`.
- Update tree-sitter grammar and editor corpus examples.
- Update Wire reference docs and examples.
- Add compile-time tests for missing, duplicate, and undeclared output equations.
- Keep the lowered pure output config keyed by declared output port labels.

## Traceability

- Feature keys: `wire.node_clause_grammar`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/grammar.md`
- Implementation: `src/Cortex/Wire/Parser.hs` (node / input-clause / output-clause grammar),
  `src/Cortex/Wire/AST.hs` (`WireOutputPort`, output-equation bijection errors such as
  `WireMissingDefaultOutputPort`), `src/Cortex/Wire/Compile.hs` (output-equation admission)
- Tests: `test/Cortex/Wire/ParserSpec.hs` (parses pure output equations and clause forms),
  `test/Cortex/Wire/CompileSpec.hs` (output-port admission)
- Theory/proof: [CorePure output ports](../Reference/proof-status.md) (declared-output / equation
  bijection)

## Related

- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0020 - Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0023 - CorePure Expression Surface](./0023-corepure-expression-surface.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0030 - Wire Node Implementation Forms](./0030-wire-node-implementation-forms.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
