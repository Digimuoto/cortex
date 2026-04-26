---
title: "Wire V0 Implementation Plan"
description: Shipped v0 scope for same-file `.wire` workflow source, direct compilation to CompiledCircuit, and the next rewrite-proposal slice
---

# Wire V0 Implementation Plan

**Date:** 2026-04-13  
**Issue:** `DIG-483`  
**Status:** implemented v0, next-slice notes captured here  
**Scope:** same-file declarative Wire source, direct `CompiledCircuit` bridge, deep-report dogfood, and rejected-proposal retry semantics

## Summary

The shipped v0 Wire surface is intentionally narrow:

- one `.wire` file contains node declarations plus exactly one circuit
- supported node roles are `act`, `await`, and `emit`
- `connect` is the atomic primitive
- `path`, `fanout`, `fanin`, `between`, and `clique` are connection-list sugar
- basic `if cond between A B { ... } else { ... }` is supported as a circuit-level Decide construct
- Wire circuits compile directly to `CompiledCircuit`
- existing lowering and Pulse execution paths remain the runtime boundary

This proves the graph-native Wire model without bundling a host language,
evaluator, or Wire rewrite syntax into the first slice.

## Shipped Surface

The concrete parser lives in `Cortex.Wire.Parser`. The practical
grammar summary for prompts and docs is:

```txt
file          ::= top_decl*
top_decl      ::= node_decl | circuit_decl

node_decl     ::= "node" ident "{" node_field* "}"
circuit_decl  ::= "circuit" ident "{" circuit_stmt* "}"

node_field    ::= "role" "=" role ";"
                | "label" "=" string ";"
                | "executor" "=" executor ";"
                | "prompt" "=" string ";"
                | "tools" "=" "[" qualified_ref* "]" ";"
                | "timeout" "=" int ";"
                | "retry" "=" int ";"
                | "on" "=" "signal" "(" string ")" ";"
                | "kind" "=" string ";"
                | "to" "=" qualified_ref ";"

role          ::= "act" | "await" | "emit"
executor      ::= "llm" "(" string ")" | "native" "(" string ")"

circuit_stmt  ::= "connect" ref ref ";"
                | ref ";"
                | "path" "[" ref ("," ref)+ "]" ";"
                | "fanout" ref "[" ref ("," ref)+ "]" ";"
                | "fanin" "[" ref ("," ref)+ "]" ref ";"
                | "between" "[" ref ("," ref)+ "]" "[" ref ("," ref)+ "]" ";"
                | "clique" "[" ref ("," ref)+ "]" ";"
                | "if" ident "between" ref ref "{"
                    circuit_stmt*
                  "}" ("else" "{"
                    circuit_stmt*
                  "}")? ";"
```

Hard constraints:

- exactly one circuit per file
- all circuit refs must resolve to declared nodes
- the expanded graph must be a DAG
- the graph must be one weakly connected component
- every declared node must appear in the circuit
- condition refs are plain names, not `$` dereferences
- no `let`, lambdas, interpolation, ports, or Wire rewrites in v0

## Backend Shape

The important design choice is already implemented: Wire circuits do **not**
round-trip through `CircuitExpr`.

Instead:

1. `Cortex.Wire.Parser` parses and validates Wire declarations
2. `Cortex.Wire.Compiler` expands combinators and compiles basic latent `if` branches to `CircuitConditionNode`
3. the compiler emits `CompiledCircuit` directly
4. `Cortex.Circuit.Lowering` lowers that compiled artifact to a `StagePlan`

This keeps the Wire graph in graph form and avoids forcing it through the
tree-shaped integration IR.

## Dogfood Scope

Current dogfood is intentionally narrow:

- `config/cortex/workflows/deep-report.wire` is the Wire source for `deep_report_default`
- `config/cortex/workflows/thesis-stress-test.wire` is the Wire workflow for `thesis_stress_test`
- template loading prefers Wire compilation when `wireSource` is present
- fixed section fan-out still remains on the legacy IR path
- thesis required-evidence repair now uses Wire `if required_evidence_missing between gatherer analyst { ... }`

That keeps v0 inside the portion of Portman workflow behavior it can represent
faithfully today.

## Rewrite Proposal Semantics

The current runtime work on this branch extends the rewrite rejection path so a
proposed `.wire` rewrite that fails parse/compile/lower is treated as a rejected
proposal, not as an admitted rewrite.

The semantic rule is:

- rejected proposal: no topology change, same stage retries with rejection context
- admitted rewrite: topology changes, pruning/materialization semantics become real

That is why proposal compiler failures feed back through
`StageContext.scRewriteRejection` instead of forcing a synthetic “reconsider”
node into the graph.

## Next Slice

The next implementation slice should stay narrow:

- keep `.wire` rewrite proposals limited to Wire `act` nodes
- reuse the existing rejection/retry path for parse, compile, and lowering failures
- keep the short v0 grammar above as the prompt-facing source of truth

Still deferred:

- Wire rewrite/plasticity syntax
- typed contracts
- host-language features (`let`, lambdas, currying, interpolation)
- a dedicated `.circ` file type

If `.circ` appears later, it should desugar to the same connection algebra used
by `.wire` v0 rather than introducing a second semantic model.
