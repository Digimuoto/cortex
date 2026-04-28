# Platform.Database Raw Hasql Context

This guide covers raw Hasql `Statement` queries. Rel8-based queries should follow the local Rel8TH
conventions; this file only covers raw SQL.

## When To Use Raw Hasql

Use Rel8 by default. Raw `Statement` is appropriate when the query requires CTEs, window functions,
`FOR UPDATE SKIP LOCKED`, complex upserts, lateral joins, or other SQL constructs that Rel8 cannot
express. When using raw SQL, use `Platform.Database.Encode` combinators and follow this style guide.

## Encoder Rules

### Tuple Arity Cap

Use `encode1` through `encode8` for up to eight parameters. For nine or more parameters, use
`encodeParams` with a list of `col` calls. Do not chain `encodeN` combinators with `(<>)` in new
code.

### Swap-Risk Threshold

Queries with four or more parameters where two or more share the same Hasql type should use a named
record to prevent silent swap bugs. Two adjacent `Text` params in a flat tuple have no compile-time
guard.

### Use Platform.Database.Encode

Import `Platform.Database.Encode` instead of `Hasql.Encoders` directly. It re-exports the common
encoder primitives and provides `encode1` through `encode8`, `col`, and `encodeParams`. `E.param` is
intentionally not re-exported; seeing `Platform.Database.Encode` in an import list signals
combinator-style usage.

Each `encodeN` takes N `(accessor, encoder)` pairs:

```haskell
import Platform.Database.Encode qualified as Enc

data RunFailure = RunFailure
  { rfRunId :: UUID
  , rfNow :: UTCTime
  , rfErrType :: Text
  , rfErrMsg :: Text
  , rfRetryable :: Bool
  }

encoder =
  Enc.encode5
    (.rfRunId, Enc.nonNullable Enc.uuid)
    (.rfNow, Enc.nonNullable Enc.timestamptz)
    (.rfErrType, Enc.nonNullable Enc.text)
    (.rfErrMsg, Enc.nonNullable Enc.text)
    (.rfRetryable, Enc.nonNullable Enc.bool)
```

For queries with nine or more parameters, use `encodeParams` with a `NonEmpty` of `col` calls:

```haskell
encoder =
  Enc.encodeParams $
    Enc.col (.fieldA) (Enc.nonNullable Enc.text)
      :| [ Enc.col (.fieldB) (Enc.nonNullable Enc.int4)
         , Enc.col (.fieldC) (Enc.nullable Enc.timestamptz)
         ]
```

`encodeParams` takes a `NonEmpty (E.Params t)` so an empty list is a compile error rather than a
silent runtime mismatch.

### Named Parameter Records

Define parameter records next to the query in the same module, not in a shared types file. Use
`OverloadedRecordDot` accessors as `encodeN` field selectors. The record does not need to be
exported unless callers outside the module construct it.

## Decoder Rules

### Column Annotation Convention

Decoders with ten or more fields should annotate each `<*>` line with a comment matching the SQL
column name:

```haskell
MyRow
  <$> D.column (D.nonNullable D.uuid)        -- r.run_id
  <*> D.column (D.nonNullable D.text)        -- r.status
  <*> D.column (D.nullable D.timestamptz)    -- r.started_at
```

This makes column-order mismatches visible during review.

### No Decoder Abstraction

Do not wrap `Hasql.Decoders` in combinators. The `<$>` / `<*>` chain is idiomatic and grep-friendly.
Comments are sufficient for safety.

## Anti-Patterns

- Chaining `encodeN` with `(<>)` for nine or more fields in new code.
- Consecutive same-typed parameters without a record.
- `>$<` / `<>` chains without `encodeN` or `encodeParams` in new code.
- Large decoders without column comments.
- Query builder DSLs or `mkQuery` wrappers.
- Hiding `Session` vs `Transaction` behind a unified monad.
- Re-exporting `E.param` from `Platform.Database.Encode`.
