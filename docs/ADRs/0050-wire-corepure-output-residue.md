---
title: "ADR 0050 - Wire CorePure Output Residue"
description:
  "Removes the source-level pure(...) wrapper and treats input-dependent CorePure output equations
  as delayed residue over the same total static expression language."
sidebar:
  label: "0050. CorePure residue"
  order: 50
status: proposed
date: 2026-05-06
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0042-wire-standard-effect-executors.md
---

# ADR 0050 - Wire CorePure Output Residue

## Status

Proposed - this ADR amends the source spelling from ADR 0020 and sharpens ADR 0021's two-phase
CorePure model. It does not remove the internal native pure evaluator.

## Context

ADR 0020 introduced explicit `pure (...)` output equations to keep deterministic Wire-authored
calculation separate from executor authority. That split was useful for the first implementation,
but it now creates an unnecessary third-looking surface:

- static Wire expressions reduce during elaboration;
- runtime CorePure expressions inside `pure (...)` wait for input ports;
- executor calls behind `@` run authority-bearing work.

The middle item is not semantically different from static CorePure. It is the same deterministic,
authority-free expression language, delayed only because it depends on input values that are not
available until Pulse reaches the node. Keeping a `pure (...)` wrapper makes output equations look
like a special executor call even though `pure` is not authority and is not a registered executor.

At the same time, Wire must not make static evaluation Turing-complete. Static elaboration decides
graph shape, `make(...)` expansion, form instantiation, port matching, topology errors, and proof
witnesses. Those decisions must remain terminating and decidable. General loops and dynamic or JIT
languages belong at the executor boundary where Pulse can apply runtime policy.

## Decision

Wire output equations write CorePure expressions directly:

```wire
node classify
  <- evidence: EvidenceSet;
  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= 0.7);
  -> rejected: AcceptedSet = evidence.items |> filter (x: x.score < 0.7);
```

The compiler classifies each CorePure expression by dependency:

- if the expression is statically known, it is reduced during elaboration;
- if it depends on input ports, it is delayed as runtime residue and lowered to the internal native
  pure evaluator;
- if it names executor authority, host effects, time, randomness, model calls, tools, durable
  memory, scripts, imports, recursion, loops, or dynamic language execution, it is rejected from
  CorePure and must be expressed through an explicit `@` executor.

The old source wrapper `pure (...)` is no longer accepted. Authored `@pure` remains rejected.

Configured executor values stay available, but configured executor applications must remain in
executor-body position when they would otherwise be ambiguous with CorePure function calls:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = analyst (evidence);
```

Inline registered executor calls remain unambiguous because `@` marks authority:

```wire
node gather
  -> evidence: EvidenceSet = @review.gather ({});
```

## Alternatives considered

- **Make runtime `pure (...)` Turing-complete.** Rejected. It creates a second programming language
  boundary inside Wire and risks confusing runtime value computation with static topology
  elaboration. Loops are useful, but they belong behind `@` where they are ordinary runtime
  authority subject to Pulse policy.
- **Keep `pure (...)` as the required marker.** Rejected. The wrapper is syntactic noise once
  CorePure is understood as Wire's deterministic expression layer. It also makes examples look less
  like ordinary equations.
- **Keep `pure (...)` as a deprecated alias.** Rejected for the implementation slice. Accepting both
  spellings would prolong split canon and make formatter/linter output less decisive.
- **Allow configured executor value calls inline after `-> ... =`.** Rejected. The spelling
  `name(arg)` is also ordinary CorePure function application. Configured executor values remain
  explicit node bodies, while inline authority uses `@`.

## Consequences

### Positive

- Wire examples become shorter and read as equations rather than calls to a pseudo-executor.
- The source-level authority rule becomes simpler: `@` is the only host-authority marker.
- Static evaluation remains total and decidable; input-dependent residue is delayed, not a separate
  language.
- Runtime loops, shell commands, scripts, and JIT languages have one obvious home: registered
  executors.

### Negative

- This is a source-breaking syntax change for files that still spell `pure (...)`.
- Configured executor values can no longer use the single-output inline shape when that shape would
  be indistinguishable from CorePure function application; authors use node-level executor bodies
  instead.
- ADR 0020 examples and older prose need a forward pointer because the positive decision on pure
  output equations remains, while the wrapper spelling no longer does.

### Obligations

- Update the parser to accept direct CorePure output equations and reject retired `pure (...)`
  wrappers.
- Update canonical examples, reference docs, style docs, and runnable `.wire` files.
- Keep the internal native pure evaluator and lowering path: only source spelling changes.
- Add parser/compiler tests for direct output equations and for configured executor body position.
- Ensure formatters and syntax highlighting treat output RHS expressions as CorePure.

## Traceability

- Feature keys: `corepure.output_residue`
- Public surface: `Cortex.Wire`,
  [`docs/Reference/Wire/pure-execution.md`](../Reference/Wire/pure-execution.md)
- Implementation: `src/Cortex/Wire/Pure.hs` (`CorePureStaticContext`), `src/Cortex/Wire/Compile.hs`
  (`corePureStaticContextFromBindings`, the static-vs-delayed residue classification of output
  equations)
- Tests: `test/Cortex/Wire/PureSpec.hs` (static context from top-level record bindings, node-local
  `let` shadowing rejection, `where`-field delayed-binding scope)
- Theory/proof:
  [the CorePure static-context row — `proof-status.md`](../Reference/proof-status.md#matrix)
- Tracking: GitHub #304

## Related

- [ADR 0020 - Wire Pure Output Equations](0020-wire-pure-output-equations.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](0021-wire-source-elaborates-to-circuits.md)
- [ADR 0023 - CorePure Expression Surface](0023-corepure-expression-surface.md)
- [ADR 0025 - Configured Executor Values](0025-configured-executor-values.md)
- [ADR 0042 - Wire Standard Effect Executors](0042-wire-standard-effect-executors.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
- [Wire Pure Execution](../Reference/Wire/pure-execution.md)
