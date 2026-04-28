---
title: "ADR 0025 - CorePure Expression Surface"
description:
  "Defines the closed Nix-like CorePure expression language, pipe sugar, string interpolation, and
  data-last stdlib rules."
sidebar:
  label: "0025. CorePure surface"
  order: 25
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0019-wire-pure-nodes.md
  - docs/ADRs/0022-wire-pure-output-equations.md
  - docs/ADRs/0023-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-wire-node-clause-grammar.md
  - docs/ADRs/0026-typed-executor-node-interface.md
---

# ADR 0025 - CorePure Expression Surface

## Status

Proposed - this ADR defines the initial CorePure authoring language for both elaboration-time
reduction and runtime `pure (...)` execution.

## Context

Pure output equations need an expression language that is legible enough for real authoring but
small enough to preserve deterministic replay, budget accounting, and proof obligations. Reusing a
host language such as Haskell, JavaScript, or Nix would buy expressiveness but would also import IO,
large libraries, evaluation complexity, or implementation-defined behavior.

The desired surface is Nix-like because Nix gives Cortex useful authoring conventions: attrsets,
non-recursive `let ... in`, lambdas written as `x: ...`, and ergonomic string templates. CorePure is
not Nix. It is a closed expression language with a typed evaluator and deterministic failure modes.

## Decision

CorePure should use a closed Nix-like expression surface. The same AST and evaluator are used by the
elaborator from ADR 0023 and by runtime `pure (...)` output equations from ADR 0024.

The initial language includes:

- literals: numbers, strings, booleans, and null;
- records / attrsets;
- lists;
- field access, such as `item.score`;
- indexed access, such as `items[0]`;
- non-recursive `let ... in`;
- `if ... then ... else ...`;
- lambdas, written as `x: ...`;
- curried application and partial application;
- arithmetic, comparison, and boolean operators.

Evaluation failures are typed and deterministic. The required failure set includes missing fields,
type mismatches, divide by zero, bad indexes, arity mismatches, and budget exhaustion.

CorePure explicitly disallows:

- recursion and `fix`;
- imports, modules, filesystem access, or package access;
- IO, time, random values, model calls, tool calls, memory queries, durable-state reads, or host
  callbacks;
- unbounded `fold`;
- sort with user comparators;
- non-typed exceptions.

`fold` can be reconsidered only after budget accounting is solid enough to state its cost model.

### Pipe Sugar

`|>` is the canonical function-composition operator inside CorePure expressions. It is
left-associative and low precedence: above binding / assignment forms and below arithmetic,
comparison, and boolean operators.

The parser desugars:

```wire
lhs |> rhs
```

to:

```wire
rhs lhs
```

Pipes do not add a CorePure AST node and do not change evaluator semantics. For example:

```wire
xs |> filter pred |> map f |> sum
```

desugars to:

```wire
sum (map f (filter pred xs))
```

### Data-Last Stdlib

Stdlib functions intended for sequence processing must take their primary data argument last. This
is a CorePure stdlib invariant, not a recommendation.

The initial closed stdlib is:

```text
map       : (T -> U) -> List T -> List U
filter    : (T -> Bool) -> List T -> List T
zip       : List U -> List T -> List (T, U)
zipWith   : (T -> U -> V) -> List U -> List T -> List V
length    : List T -> Number
sum       : List Number -> Number
all       : (T -> Bool) -> List T -> Bool
any       : (T -> Bool) -> List T -> Bool
min       : Number -> Number -> Number
max       : Number -> Number -> Number
abs       : Number -> Number
clamp     : Number -> Number -> Number -> Number
concat    : List String -> String
toString  : Scalar -> String
joinLines : List String -> String
joinWith  : String -> List String -> String
```

`Scalar` is the closed set `String | Number | Bool`. `toString` is identity on strings and
deterministic on numbers and booleans.

For `zip` and `zipWith`, the piped list is the rightmost operand:

```wire
scores |> zipWith (score: weight: score * weight) weights
```

Future stdlib additions must preserve data-last ordering. User-defined functions should follow the
same convention when intended for pipe use, but the evaluator does not enforce this for user code.

### String Interpolation

CorePure strings support Nix-style interpolation:

```wire
let name = "Julius" ;
let greeting = "Hello, ${name}!" ;
```

The parser desugars interpolation into ordinary string concatenation:

```wire
"foo${expr}bar"
```

becomes equivalent to:

```wire
concat ["foo", toString expr, "bar"]
```

Interpolation is parser sugar. It does not add a CorePure AST node and it has no distinct evaluator
semantics.

Interpolation auto-stringifies only scalar values:

- `String`, `Number`, and `Bool` interpolate directly through `toString`;
- records, lists, null, and lambdas are type errors unless explicitly converted by a later
  serialization function.

This gives prompt and report authors useful ergonomics without committing Cortex to a generic `Show`
mechanism for structured values.

Double-quoted strings use ordinary escapes such as `\n`, `\t`, `\\`, and `\"`.

Indented strings use Nix-style `''...''` syntax. The parser strips the common leading whitespace
from all non-blank lines and ignores the first line if it is whitespace-only after the opening
delimiter. This allows prompt templates to align with surrounding Wire source without carrying that
indentation into the value.

Escapes inside indented strings should follow Nix's conventions for `${`, `''`, and literal newlines
rather than inventing a Cortex-specific escape language.

### Layer Boundary

Interpolation is a CorePure feature, not a topology feature. A string such as `"${node.output}"`
does not read a circuit port at elaboration time. Inside `pure (...)`, input ports are bound to
runtime values, so interpolation works normally over those concrete values.

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

The `summary` output is the primary reason interpolation belongs in the first slice: typed values
can build text outputs without unreadable manual `concat` and `toString` calls.

## Alternatives considered

- **Execute Haskell directly.** Rejected because even "pure Haskell" imports a large language,
  partiality hazards, and a host compiler boundary. Allowing `IO` would turn Wire source into
  arbitrary host authority.
- **Embed Nix itself.** Rejected because Nix is dynamically typed, has its own import and path
  semantics, and would make Cortex depend on Nix language behavior rather than a small typed
  evaluator.
- **Require manual string concatenation.** Rejected because text outputs and prompt fragments are a
  core use case. Without interpolation, real examples become noisy immediately.
- **Stringify every value.** Rejected because records and lists need explicit serialization rules.
  Accidental structural stringification would become observable semantics.

## Consequences

### Positive

- CorePure is expressive enough for scoring, filtering, summaries, and prompt/report fragments.
- Pipes improve readability without changing the evaluator or proof surface.
- Data-last stdlib ordering makes pipeline style predictable.
- Interpolation is deterministic parser sugar over ordinary string primitives.

### Negative

- The parser must handle Nix-like strings and indentation normalization.
- The evaluator needs first-class lambdas and partial application.
- The stdlib must remain deliberately small; useful functions will need admission discipline.

### Obligations

- Desugar pipes and interpolation before CorePure AST construction.
- Add evaluator tests for every typed failure mode.
- Add budget tests for list operations and string concatenation.
- Add parser tests for double-quoted strings, indented strings, interpolation, and escapes.
- Keep `toString` constrained to scalar values until explicit structured serialization is designed.

## Related

- [ADR 0019 - Wire Pure Nodes](./0019-wire-pure-nodes.md)
- [ADR 0022 - Wire Pure Output Equations](./0022-wire-pure-output-equations.md)
- [ADR 0023 - Wire Source Elaborates to Circuits](./0023-wire-source-elaborates-to-circuits.md)
- [ADR 0024 - Wire Node Clause Grammar](./0024-wire-node-clause-grammar.md)
- [ADR 0026 - Typed Executor Node Interface](./0026-typed-executor-node-interface.md)
- [Wire Pure Execution Reference](../Reference/Wire/pure-execution.md)
