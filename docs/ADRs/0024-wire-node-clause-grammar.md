---
title: "ADR 0024 - Wire Node Clause Grammar"
description:
  "Defines the next Wire node surface: clause-terminated inputs, a single node-local let block, and
  per-output RHS forms."
sidebar:
  label: "0024. Node clause grammar"
  order: 24
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - docs/ADRs/0022-wire-pure-output-equations.md
  - docs/ADRs/0023-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0025-corepure-expression-surface.md
---

# ADR 0024 - Wire Node Clause Grammar

## Status

Proposed - this ADR replaces the historical colon-led node body and string-config pure examples with
the clause grammar for the next Wire implementation phase.

## Context

ADR 0022 accepted pure output equations, but the first implementation kept some transitional syntax
around the existing parser. The next phase can remove that legacy shape instead of preserving
compatibility:

- `node name :` should no longer be necessary;
- `@pure { expr = "..." }` should remain historical syntax;
- port labels should be declared exactly where routing happens;
- node-local shared work should have one obvious scope.

The syntax also needs to preserve the authority boundary from ADR 0010 and ADR 0018. `pure (...)` is
internal deterministic Wire evaluation. `@executor (...)` is the boundary to registered external
authority.

## Decision

Wire should adopt this node grammar:

```ebnf
wire_file   ::= (top_decl ;)*
top_decl    ::= let_binding | export let_binding | node_decl
let_binding ::= let <name> = <expr>
node_decl   ::= node <name>
                  (input_clause ;)*
                  (let_block)?
                  (output_clause ;)+

input_clause  ::= <- <name> : <Type>
let_block     ::= let <bindings> in
bindings      ::= <name> = <expr> (; <name> = <expr>)*
output_clause ::= -> <name> : <Type> = <rhs>
rhs           ::= pure (<expr>) | @<executor> (<expr>) | <expr>
```

The first implementation slice must accept explicit `pure (<expr>)` and `@executor (<expr>)` output
RHS forms. The unmarked `<expr>` form is reserved for the elaborator model from ADR 0023 and should
remain rejected until inference and diagnostics are specified.

### Node Clauses

Node declarations do not use a colon after `node <name>`. Legal continuations already begin with
`<-`, `let`, or `->`, so the colon adds no disambiguation.

Each input and output clause is terminated by `;`. This keeps clauses symmetric and avoids a body
delimiter.

A node may contain at most one `let ... in` block. The block appears after all inputs and before all
outputs:

- input ports are in scope for the local `let` RHSs;
- node-local bindings are in scope for all output RHSs;
- duplicate names within one scope are rejected;
- inner scopes may shadow outer scopes.

Multiple node-local `let` blocks are rejected. They make scope and evaluation order harder to read
without adding useful expressive power.

### File-Level Bindings

File-level `let` bindings are private by default:

```wire
let acceptedItem = x: x.score >= 0.7 ;
```

`export let` opts a binding into the future import surface:

```wire
export let scoreThreshold = 0.7 ;
```

Until imports land, `export` has no runtime effect. It is accepted to give the grammar the correct
migration path.

`let x = node ...` and `node x ...` denote the same topology binding. Style guidance is:

- use `node x ...` for named node definitions;
- reserve `let x = ...` for composition expressions once topology composition syntax lands.

### Output RHS Forms

Output equations bind routing labels directly:

```wire
-> accepted: AcceptedSet = pure (accepted) ;
-> rejected: RejectedSet = pure (rejected) ;
-> report: Report = @llm.summarize (prompt) ;
```

The declared output port name is the routing key. There is no `return accepted = ...` syntax and no
separate output-map block.

Binding must enforce a bijection between declared output ports and output equations:

- every declared output has exactly one equation;
- every equation names a declared output;
- repeated equations for the same port are compile errors;
- missing equations are compile errors;
- output payloads validate against their declared contract and payload kind.

### Pure Versus `@`

`pure (...)` does not use `@`. In Wire syntax, `@` marks the boundary to registered external
authority whose behavior is not defined by the Wire theorem layer. The pure evaluator is internal,
deterministic, closed, and subject to the CorePure semantics from ADR 0025.

Lowering may still represent `pure (...)` as an internal executor task in the compiled circuit. That
is an implementation detail of the runtime substrate, not an authoring claim that pure evaluation is
unknown authority.

## Worked example

```wire
let scoreThreshold = 0.7 ;

node classify
  <- evidence: EvidenceSet ;
  let
    items = evidence.items ;
    accepted = items |> filter (x: x.score >= scoreThreshold) ;
    rejected = items |> filter (x: x.score < scoreThreshold)
  in
  -> accepted: AcceptedSet = pure (accepted) ;
  -> rejected: RejectedSet = pure (rejected) ;
  -> summary: Report = pure (''
    Classification complete.
    Accepted: ${length accepted} items
    Rejected: ${length rejected} items
    Threshold: ${scoreThreshold}
  '') ;
```

## Alternatives considered

- **Keep `node name :`.** Rejected because clause starts are already unambiguous and the colon is
  legacy syntax.
- **Allow several node-local `let` blocks.** Rejected because it creates avoidable scope and order
  questions. One block provides shared input-dependent work without that footgun.
- **Use `return port = ...`.** Rejected because it duplicates the routing label. The output clause
  already names the port and contract.
- **Spell pure runtime evaluation as `@pure`.** Rejected for the source surface because `@` means a
  registered external authority boundary. Pure evaluation is inside Wire's deterministic layer.

## Consequences

### Positive

- Node authoring becomes regular: input clauses, one optional let block, output clauses.
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

## Related

- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0021 - Executor Registration and Binding](./0021-executor-registration-and-binding.md)
- [ADR 0022 - Wire Pure Output Equations](./0022-wire-pure-output-equations.md)
- [ADR 0023 - Wire Source Elaborates to Circuits](./0023-wire-source-elaborates-to-circuits.md)
- [ADR 0025 - CorePure Expression Surface](./0025-corepure-expression-surface.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
