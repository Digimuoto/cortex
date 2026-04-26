# Code Review Rubric

Structured approach to reviewing Haskell modules. Score 1–10 on each axis,
weight by relevance to the module's role.

## Axes

### Correctness (weight: high)

**First-pass automated check** — before reviewing anything else, grep for
fire-and-forget DB writes. These are the highest-value findings:

```bash
grep -rn '_ <- .*runTransaction\|_ <- .*runQuery\|_ <- .*withConnection' src/
```

Every hit is a potential silent failure. Classify each as intentional
(best-effort with comment) or accidental (missing error path).

Then check:
- Exhaustive pattern matches on owned ADTs (no wildcards hiding variants)
- Async exceptions re-thrown, not swallowed
- Database transaction boundaries correct (atomicity where needed)
- Race conditions addressed (lease renewal, shutdown flags, cancellation)
- Error paths don't silently drop failures

### Architecture (weight: high)

- **Three Layer Cake**: Module classifiable as pure (layer 1), constrained
  effects (layer 2), or effectful wiring (layer 3). Flag functions that mix
  layers (see architecture.md "Three Layer Cake").
- Pure decision logic separated from effectful execution
- Functions operate at one abstraction level (not mixing orchestration with DB writes with logging)
- Return values rather than performing continuations
- Extension points are data (ADTs, records, registries), not code (callbacks, typeclasses)
- Typeclass vs record-of-functions: typeclass with exactly one instance → use record

### Readability (weight: medium)

- `where` nesting <= 3 levels
- No function exceeds ~80 lines (soft limit; 50 is better)
- **Cyclomatic complexity proxy**: count `case`, `if`, `when`, `unless`,
  and monadic bind points in a single function. Over 15 -> decompose.
- Happy path visually dominant; error handling doesn't obscure it
- Named types for API boundaries (not inline 30-line type signatures)
- Export list curated and intentional — every module has an explicit export list
- Re-exports only re-export curated public APIs, not internal types
- New code follows the module's existing import style (qualified vs unqualified)
- Comment conventions: `-- |` Haddock on exports, `-- TODO(ticket):` with
  ticket ref, no naked TODOs

### Parameter safety (weight: medium)

- No adjacent same-typed positional parameters in public functions
- Functions with >8 parameters use a record
- Environment records used instead of deep closure chains
- Tuple arity ≤ 8 for ad-hoc groupings

### Error handling (weight: medium)

- Every `IO (Either String a)` has an explicit handler
- "Must succeed" vs "best-effort" vs "last resort" distinction is clear
- Lease/timeout recovery paths exist for operations that can be interrupted
- Last-resort handlers log enough context to diagnose (run ID, error type, original error)
- Sequential Either chains use `ExceptT` instead of nested `case Left/Right`
- `Either String` from external sources is converted to domain errors at
  the boundary — not propagated through core layers
- Orchestration functions that need different recovery per failure keep
  explicit branching (not forced into `ExceptT`)

### Observability (weight: low-medium)

- Structured logging with consistent operation names
- Severity levels calibrated (not everything is Error)
- Extra fields include identifiers (run_id, task_id) for correlation
- No string interpolation in hot paths; use structured fields

### Upstream impact (weight: medium)

- Does the module's public API (exports, function signatures) make callers cleaner?
- Does the module force callers into awkward patterns (threading unused params,
  constructing large records for simple operations)?
- When reviewing a refactoring, check the call sites — a module that's internally
  clean but forces callers to pass 6 positional params is mis-abstracted
- An environment record is valuable not because it makes the module shorter, but
  because callers construct one record instead of passing 6 separate arguments

### Type safety (weight: medium)

- Smart constructors for types with invariants (no public data constructors)
- Phantom types for semantically distinct same-shaped values (2+ UUID params)
- `NonEmpty` for lists that must have at least one element
- No partial functions (`head`, `fromJust`, `read`, `!!`, `error`) in
  production code
- `DerivingStrategies` explicit on all `deriving` clauses
- No `Show` derived on types with sensitive fields
- No orphan instances
- Optics: `foo { bar = (bar foo) { baz = newBaz } }` appearing 3+ times
  is a candidate for a lens; otherwise plain record update suffices

### Style (weight: low)

- Language extensions justified (>15 per-module pragmas over cabal defaults is a smell)
- Imports qualified or explicit (no implicit Prelude pollution)
- Consistent qualified import names (see type-conventions.md)
- `OverloadedRecordDot` used consistently
- `LambdaCase` for simple dispatch, explicit `\x -> case x of` for complex
- Applicative style when sub-expressions are independent

## Scoring guide

- **9–10**: Production-grade. Clean separation, honest error handling, would trust
  in a system I operate at 3am.
- **7–8**: Solid with identifiable improvement areas. Working code that could be
  made more maintainable with targeted refactoring.
- **5–6**: Functional but accumulated structural debt. The kind of code that works
  until someone needs to modify it.
- **3–4**: Significant issues. Missing error paths, unclear control flow, or
  architectural problems that will cause bugs under maintenance.
- **1–2**: Needs rewrite. Fundamental structural problems.

## Review structure

1. **Overall score** with one-line justification
2. **Strengths**: 2–4 specific things done well, with code references
3. **Issues**: Ranked by severity, with concrete fixes (not vague suggestions)
4. **Style notes**: Minor observations that don't affect the score

Keep reviews concrete. "The error handling is good" is useless. "The `requireTx`
pattern ensures every critical DB write either succeeds or fails the run with
context" is useful.

### Severity classification

Findings must be classified by action required, not just importance:

- **[P1] Block merge** — Correctness bugs, silent error drops, data loss risk,
  non-exhaustive matches on owned ADTs. These must be fixed before shipping.
- **[P2] Track as debt** — Architecture issues, structural concerns, oversized
  functions, missing abstractions. These won't cause bugs today but accumulate
  friction. Create a follow-up issue or TODO, don't block the PR.
- **[style]** — Naming, formatting, import style. Note and move on.

A review that marks everything P1 is as useless as one that marks everything
P2. The distinction is: "would I page someone at 3am for this?" If yes, P1.
If no, P2.

## Review calibration

### Verify before flagging

A finding is not a finding until verified. Concretely:

- **Wildcard matches**: Only flag `_` on types *declared in this project's source*,
  not on `Text`, `Maybe`, `Int`, `Either`, `Value`, HTTP status codes, or other
  standard library types. The test: "if someone added a constructor to this type,
  would this wildcard hide a bug?" If the type is from `base`, `aeson`, or
  `servant`, the answer is no.

- **Parameter safety**: Check whether the handler already bundles positional params
  into a record on the first line. If it does, the positional signature is a Servant
  `QueryParam` constraint, not a code quality issue.

- **File size**: Check complexity *per function* before flagging total lines. A
  1200-line file of independent 30-line handlers is fine. A 400-line file with one
  200-line function is not.

### Net complexity principle

A refactoring should reduce total complexity, not just redistribute it. Signals
that an extraction is not worth it:

- It adds more lines than it removes
- The extracted function is called from exactly one site
- The extracted function requires passing 5+ parameters that were free closures before
- The abstraction is harder to understand than the original repetition

Three similar 10-line blocks are often better than one 30-line generic abstraction
with type parameters. Extract when there are 3+ call sites, real repetition risk
(bugs from forgetting to update one copy), or the function is independently testable.

## Anti-patterns to flag

### The Closure Trap

Deeply nested `where` blocks that close over many variables, making extraction
feel impossible. The fix is always: define a record, promote to top-level.

```haskell
-- Symptom: you can't extract `attemptStage` because it calls `go`
-- Fix: make attemptStage return a value, let go interpret it
```

### Fire-and-forget DB writes

```haskell
-- BAD: result of DB write is discarded
_ <- DB.runTransaction pool $ Q.updateRunFailed runId now errType errMsg True

-- GOOD: at minimum, log the failure
result <- DB.runTransaction pool $ Q.updateRunFailed runId now errType errMsg True
case result of
  Left dbErr -> logError "Failed to mark run as failed" dbErr
  Right ()   -> pure ()
```

### The God Context

A single record threaded through every function containing everything the
application needs. Every handler receives the admin pepper even if it only
needs the DB pool.

```haskell
-- Symptom: ServerContext has 13 fields, passed to 120 call sites
-- Fix: group by capability (HandlerEnv, AssistantContext, DeploymentInfo)
```

### Sequential Either ladders

Three or more chained `case result of Left err -> ...; Right val -> ...`
where every `Left` branch does the same thing (propagate, throw, return Left):

```haskell
-- BAD: 3+ sequential case-of with identical Left handling
result1 <- step1
case result1 of
  Left err -> pure (Left err)
  Right v1 -> do
    result2 <- step2 v1
    case result2 of
      Left err -> pure (Left err)
      Right v2 -> ...

-- GOOD: extract to ExceptT helper
pipeline :: ExceptT AppError IO Result
pipeline = do
  v1 <- ExceptT step1
  v2 <- ExceptT (step2 v1)
  ...
```

Only flag when the Left handling is uniform. If each Left triggers different
logging/recovery, explicit branching is correct.

### Same-shaped branches

Multiple case branches that do the same thing with different strings:

```haskell
-- BAD: 5 branches each doing: run tx, case on result, log error or success
-- with only the strings differing

-- GOOD: extract the common flow, make the per-branch differences data
logFinalization taskId decision applyResult = ...
```

### Exception-based domain outcomes

Using `fail`, `error`, or thrown exceptions to represent known business
outcomes (skip, timeout, cancel) rather than returning them as typed data.

```haskell
-- BAD: timeout is a domain outcome, not an exceptional condition
Nothing -> fail $ "Timed out after " <> show secs <> "s"

-- BAD: skip is a business decision encoded as an exception
throw (JobSkipped reason)
-- ... later caught with fromException in a SomeException handler

-- GOOD: return typed outcomes, let caller pattern-match
data JobResult = JobCompleted Int | JobSkipped Text | JobTimedOut Int
```

Flag when: `try`/`catch` on `SomeException` is followed by `fromException`
checks to classify 2+ domain-meaningful exception types. The classification
logic belongs in a return type, not exception dispatch.

### Orchestration blob

A single function (>80 lines) that interleaves: claim → execute → classify
→ persist → observe → finalize. Each concern reads differently and changes
for different reasons, but they are entangled in one control block.

Symptom: skip, failure, and success branches all repeat the same shape
(emit event → persist status → advance schedule) with only strings
differing. See refactoring-patterns.md Pattern 11.

### Premature abstraction

Creating a library for a pattern that appears twice. The threshold for
extraction is:

- **3+ call sites**: Extract a helper function
- **3+ modules**: Consider a shared module
- **Only within one module**: Keep it local

Don't build a "transaction logging framework" when a comment and a helper
function suffice.

### ADT completeness on new constructors

When a PR adds a constructor to an owned ADT, verify:

| Check | Where |
|---|---|
| All pattern matches updated | Compiler enforces if no wildcards |
| `ToJSON`/`FromJSON` | Serialization instance |
| DB enum value | If ADT maps to Postgres enum |
| `Arbitrary` instance | Property test generators |
| Golden tests | Any affected golden files |
| Documentation | Supported values lists, tool schemas |

**[P1] Flag**: PR adds an ADT constructor without updating serialization
instances or `Arbitrary` generators.
