---
title: "ADR 0023 - CorePure Expression Surface"
description:
  "Defines the closed Nix-like CorePure expression language, pipe sugar, string interpolation, and
  data-last stdlib rules."
sidebar:
  label: "0023. CorePure surface"
  order: 23
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0022-wire-node-clause-grammar.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0024-typed-executor-node-interface.md
---

# ADR 0023 - CorePure Expression Surface

## Status

Proposed - this ADR defines the initial CorePure authoring language for both elaboration-time
reduction and delayed runtime output execution.

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
elaborator from ADR 0021 and by delayed runtime output equations from ADR 0050.

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

The initial language does not include tuple syntax. Pair-like values are represented as records.

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

### Duplicate Names

CorePure rejects duplicate names at parse/elaboration time across every authoring surface that
introduces names. No such surface uses silent right-biased or left-biased override. The only place
in CorePure where one record's keys may override another's is the explicit record merge operator
`//`, which is unaffected by this rule.

The duplicate-name rule applies to:

- record literals;
- `let` bindings within one scope;
- lambda parameters within one lambda;
- output equations within one node.

Within a record literal, two field declarations conflict when their paths are equal or when one path
is a strict prefix of the other. The following are parse errors:

```wire
{ a = 1 ; a = 2 ; }                        -- equal paths
{ a.b = 1 ; a.b = 2 ; }                    -- equal paths
{ a = 1 ; a.b = 2 ; }                      -- `a` is a strict prefix of `a.b`
{ a.b = 1 ; a = { b = 2 ; } ; }            -- `a` is a strict prefix of `a.b`
```

The following is permitted because neither path is a prefix of the other; the distinct leaves
combine into one nested record:

```wire
{ a.b = 1 ; a.c = 2 ; }                    -- equivalent to { a = { b = 1 ; c = 2 ; } ; }
```

The runtime evaluator never observes duplicate names within one scope, because the parser and
elaborator reject them upstream. Shadowing across distinct nested scopes is unaffected: an inner
`let` binding with the same name as an outer one shadows the outer per ADR 0023's non-recursive
scoping rules.

The decision follows Nix's attrset semantics. Nix rejects `{ a = 1; a = 2; }` and
`let x = 1; x = 2; in x` at parse time regardless of recursive scope, and Nix's `//` operator
performs explicit right-biased override on already-constructed attrsets. CorePure adopts the same
split for the same reason: a silent in-literal override would let one of two visibly distinct
authoring intents win without telling the reader, while explicit `//` makes the override visible at
the call site.

Authors who want override behavior write `defaults // { field = newValue ; }` rather than declaring
`field` twice in one record literal.

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
zip       : List U -> List T -> List { fst: T; snd: U }
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
joinWith  : String -> List String -> String
```

`Scalar` is the closed set `String | Number | Bool`. `toString` is identity on strings and
deterministic on numbers and booleans.

For `zip` and `zipWith`, the piped list is the rightmost operand:

```wire
scores |> zipWith (score: weight: score * weight) weights
```

`zip` returns records because tuples are not part of the first CorePure surface. For
`scores |> zip weights`, each result element has `fst = score` and `snd = weight`.

`clamp` is ordered as `clamp lo hi value`, preserving data-last use:

```wire
score |> clamp 0 1
```

Line joining is written with `joinWith "\n"` rather than a separate `joinLines` primitive. That
keeps the initial closed stdlib smaller while preserving the common prompt/report use case.

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

Double-quoted strings support only these escapes in the first slice:

- `\n`, `\t`, and `\r` for newline, tab, and carriage return;
- `\\` for a literal backslash;
- `\"` for a literal double quote;
- `\${` for a literal `${` without starting interpolation.

Indented strings use Nix-style `''...''` syntax. The parser strips the common leading whitespace
from all non-blank lines and ignores the first line if it is whitespace-only after the opening
delimiter. This allows prompt templates to align with surrounding Wire source without carrying that
indentation into the value.

Physical newlines inside an indented string are preserved after indentation stripping. A final
newline before the closing delimiter is preserved if it remains after the delimiter line is removed.

Indented strings support only these escapes in the first slice:

- `''${` for a literal `${` without starting interpolation;
- `'''` for a literal `''`;
- `''\n`, `''\t`, and `''\r` for newline, tab, and carriage return.

All other backslashes and single quotes inside indented strings are literal characters.

### Layer Boundary

Interpolation is a CorePure feature, not a topology feature. A string such as `"${node.output}"`
does not read a circuit port at elaboration time. Inside an input-dependent output equation, input
ports are bound to runtime values, so interpolation works normally over those concrete values.

## Worked example

```wire
let scoreThreshold = 0.7 ;

node classify
  <- evidence: EvidenceSet ;
  -> accepted: AcceptedSet = accepted ;
  -> rejected: RejectedSet = rejected ;
  -> summary: Report = ''
    Classification complete.
    Accepted: ${length accepted} items
    Rejected: ${length rejected} items
    Threshold: ${scoreThreshold}
  '' ;
  where let
    items = evidence.items ;
    accepted = items |> filter (x: x.score >= scoreThreshold) ;
    rejected = items |> filter (x: x.score < scoreThreshold) ;
  in
  { accepted = accepted ; rejected = rejected ; } ;
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
- **Silently right-merge or left-merge duplicate field declarations in record literals.** Rejected
  because it lets one of two visibly distinct authoring intents win without informing the reader,
  diverges from Nix's attrset semantics, and diverges from CorePure's existing duplicate-name
  discipline for `let` bindings, lambda parameters, and output equations. Override remains available
  through the explicit `//` operator.

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
- Reject duplicate field declarations in record literals at parse time, where two declarations
  conflict when their paths are equal or when one path is a strict prefix of the other. This matches
  the duplicate-name discipline already enforced for `let` bindings, lambda parameters, and output
  equations.

## Related

- [ADR 0020 - Wire Pure Output Equations](./0020-wire-pure-output-equations.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0022 - Wire Node Clause Grammar](./0022-wire-node-clause-grammar.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [Wire Pure Execution Reference](../Reference/Wire/pure-execution.md)
