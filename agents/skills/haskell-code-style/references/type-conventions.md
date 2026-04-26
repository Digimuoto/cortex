# Type & Language Conventions

Language extension policy, type-level safety patterns, and syntactic
conventions for production Haskell.

## Extension policy

The ban criterion: if it can silently break type safety or produce
order-dependent instance resolution, it's out. Everything else is a
judgment call on complexity vs utility.

### Cabal default-extensions (no per-module pragma needed)

These are load-bearing across the codebase. Requiring per-module pragmas
for them is just noise:

```
OverloadedStrings, OverloadedRecordDot, LambdaCase,
DerivingStrategies, DerivingVia, DeriveGeneric, DeriveAnyClass,
GeneralizedNewtypeDeriving, ScopedTypeVariables, TypeApplications,
StrictData, GADTs, DataKinds, RankNTypes,
MultiParamTypeClasses, FunctionalDependencies
```

**Why GADTs and DataKinds in defaults**: They're load-bearing for
phantom-tagged IDs (`Id "Run"` vs `Id "Task"`), typed workflow states,
GDPR annotations, and Cortex stage result types. Half the codebase uses
them; per-module pragmas are noise.

**Why RankNTypes in defaults**: Required for `forall a. Query a -> IO a`
in mock records, ST-based safe mutation, and higher-rank callback
patterns.

**Hard rule**: `DeriveAnyClass` is only valid in modules that also have
`DerivingStrategies` enabled, and every `deriving` clause must use an
explicit strategy keyword. This is enforced by the defaults above.

### Allowed per-module, no justification needed

```
TypeFamilies        -- closed type families only (see below)
DuplicateRecordFields  -- must follow the prefix convention
AllowAmbiguousTypes    -- when paired with TypeApplications for
                       -- intentional type-directed dispatch
UndecidableInstances   -- for mechanical passthrough instances only
```

**Closed vs open type families**: `type family Foo a where ...` (closed)
is fine — it's the cleanest way to compute types from promoted ADTs.
`type family Foo a` (open) requires justification because of injectivity
issues and confusing error messages. When reviewing, check whether the
type family is open or closed before accepting.

**UndecidableInstances**: Fine for MTL-style passthrough
(`instance (MonadReader r m) => MonadReader r (MyT m)`). Flag when
someone enables it for a creative type-level computation — that's usually
a sign the design should be simpler.

**AllowAmbiguousTypes**: The pattern `foo @Text` where
`foo :: forall a. (Show a) => String` is clean and readable. Flag when
it's enabling a function that callers find confusing to invoke.

### Allowed per-module, justification comment required

- `TypeFamilies` (open families) — injectivity issues, instance
  resolution surprises. Closed families don't need justification.
- `ExistentialQuantification` — hides type information. The question:
  is the existential hiding info callers genuinely don't need (good),
  or hiding info because the author couldn't thread the type parameter
  (bad)? Usually a GADT with a type index or a parameterized type is
  better.
- `TemplateHaskell` — slows compilation, obscures generated code.
  Discouraged for new code, prefer `Generic`/`DerivingVia`. Existing
  TH usage (Aeson TH, lens TH, persistent TH) doesn't need migration.
- `RecordWildCards` — brings all fields into scope invisibly. With
  `OverloadedRecordDot` the explicit field access is more grep-friendly.
  Largely redundant in this codebase.
- `OverloadedLists` — makes list literals polymorphic, causing confusing
  type inference failures. Use explicit `Set.fromList`, `Map.fromList`.

### Banned

These can silently break type safety or produce order-dependent behavior:

- `IncoherentInstances` — makes instance resolution non-deterministic.
  The compiler can pick different instances depending on how much type
  information is available at the call site. Two call sites with the same
  types can resolve differently.
- `ImpredicativeTypes` — historically buggy GHC support. Allows types
  that violate the predicativity assumption the rest of the type system
  relies on. Inference failures change between GHC versions.
- `Strict` (the module-level one, **not** `StrictData`) — changes
  `let x = expensive` from lazy to strict, silently altering evaluation
  order. Can introduce crashes in code that relied on laziness for
  termination. `StrictData` only affects record fields, which is what
  you actually want.
- `OverlappingInstances` — instance resolution becomes order-dependent.
  Adding a more specific instance in a downstream module can silently
  change which instance gets picked upstream.

**[P2] Flag**: A pragma block with more than 15 per-module extensions when
the cabal defaults are already set. This suggests the module is doing
something unusual or the pragmas were copy-pasted.

## DerivingStrategies always

When `DerivingStrategies` is enabled (it should be), always specify the
strategy:

```haskell
-- GOOD: explicit strategy
data Foo = Foo { ... }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype Bar = Bar Text
  deriving newtype (FromJSON, ToJSON)

-- BAD: ambiguous — relies on GHC defaulting rules
data Foo = Foo { ... }
  deriving (Show, Eq, FromJSON, ToJSON)
```

**Why**: When both `DeriveAnyClass` and `GeneralizedNewtypeDeriving` are
enabled, GHC's defaulting rules determine which strategy to use. These
rules have changed across GHC versions. Explicit strategies eliminate
surprises.

**[style] Flag**: `deriving (SomeClass)` without a strategy keyword when
`DerivingStrategies` is enabled in the module.

## StrictData as module default

Enable `StrictData` for all modules that define record types used in
long-lived data structures (environments, state, config). This prevents
space leaks from unevaluated thunks in record fields.

```haskell
{-# LANGUAGE StrictData #-}

data StageEnv = StageEnv
  { sePool :: DB.Pool       -- strict by default with StrictData
  , seRunId :: UUID
  , seConfig :: PulseConfig
  }
```

For fields that genuinely need laziness (infinite structures, deferred
computation), use explicit `~` annotation:

```haskell
data LazyStream = LazyStream
  { lsHead :: Int
  , ~lsTail :: LazyStream  -- explicit laziness annotation
  }
```

**[P2] Flag**: A module without `StrictData` that defines record types
used in long-lived data structures (environments, state records, config).

## Avoid partial functions

Never use these in production code:

| Partial function | Safe alternative |
|---|---|
| `head` | Pattern match, `NonEmpty`, `listToMaybe` |
| `tail` | Pattern match, `NonEmpty` |
| `fromJust` | Pattern match, `maybe`, `fromMaybe` with default |
| `read` | `readMaybe` from `Text.Read` |
| `!!` | `atMay` from `safe`, or `Map`/`IntMap` lookup |
| `error` | Return `Either`/`Maybe`, use a domain error type |

```haskell
-- BAD
let first = head items
let parsed = read rawString :: Int

-- GOOD
case items of
  (first : _) -> useFirst first
  [] -> handleEmpty

case readMaybe rawString of
  Just n -> useNumber n
  Nothing -> handleParseError rawString
```

**[P1] Flag**: Any use of `head`, `tail`, `fromJust`, `read` (unqualified),
`!!`, or `error` in production code. Test code gets more latitude but should
still prefer safe alternatives.

## NonEmpty for invariant-carrying lists

When a list must have at least one element, use `NonEmpty` from
`Data.List.NonEmpty`. This eliminates an entire class of "what if the
list is empty?" runtime checks.

```haskell
-- BAD: runtime check for an invariant the type could enforce
buildStagePlan :: [StageDefinition] -> StagePlan
buildStagePlan stages =
  case stages of
    [] -> error "impossible: stage list must be non-empty"
    (first : _) -> ...

-- GOOD: the type makes empty impossible
buildStagePlan :: NonEmpty StageDefinition -> StagePlan
buildStagePlan (first :| rest) = ...
```

**When to use**:
- Stage definitions (a plan always has at least one stage)
- Signal rules (a suspended node always has at least one awaited signal)
- Rewrite proposals (a batch always has at least one proposed edit)
- Batch groups (each batch has at least one item)

**[P2] Flag**: A function that takes `[a]` and immediately `case xs of
[] -> error "..."` — the type should be `NonEmpty a`.

## Derived Show/Eq: when NOT to derive

### Show and sensitive data

Never derive `Show` on types containing passwords, tokens, API keys, or
other secrets. Use a manual instance that redacts:

```haskell
data Credentials = Credentials
  { credUsername :: Text
  , credPassword :: Text
  , credApiKey :: Text
  }

-- BAD: deriving stock (Show) -- exposes secrets in logs

-- GOOD: manual instance with redaction
instance Show Credentials where
  show c = "Credentials { credUsername = "
    <> show c.credUsername
    <> ", credPassword = <redacted>"
    <> ", credApiKey = <redacted>"
    <> " }"
```

**[P1] Flag**: `deriving (Show)` on a type with a field named `password`,
`secret`, `token`, `apiKey`, `pepper`, or `credential`.

### Eq and semantic equality

Don't derive `Eq` on types where structural equality isn't semantic equality:
- Floating-point containers (NaN /= NaN)
- Unordered collections where element order shouldn't matter
- Types with normalization requirements

## Orphan instance prohibition

Never define typeclass instances for types you don't own in modules that
don't define either the type or the class. Orphan instances cause
import-order-dependent behavior and are a maintenance hazard.

```haskell
-- BAD: orphan instance — neither Foo nor ToJSON defined here
module MyModule where
import External.Foo (Foo)
import Data.Aeson (ToJSON(..))

instance ToJSON Foo where  -- ORPHAN
  toJSON = ...

-- GOOD: wrap in a newtype
newtype WrappedFoo = WrappedFoo { unWrappedFoo :: Foo }

instance ToJSON WrappedFoo where
  toJSON (WrappedFoo f) = ...
```

**[P2] Flag**: Any `instance` declaration where neither the type nor
the class is defined in the current module.

## Smart constructor pattern

Export the type name but not its data constructor. Provide a smart
constructor that validates invariants. The export list is the enforcement
mechanism.

```haskell
module Cortex.Task.Type
  ( TaskType        -- type, no constructor
  , mkTaskType      -- smart constructor
  , unTaskType      -- accessor
  ) where

newtype TaskType = TaskType { unTaskType :: Text }
  deriving newtype (Eq, Ord, Show)

mkTaskType :: Text -> Either Text TaskType
mkTaskType t
  | T.null t = Left "TaskType cannot be empty"
  | T.any (== ' ') t = Left "TaskType cannot contain spaces"
  | otherwise = Right (TaskType t)
```

**Applicable to**: Validated IDs, bounded numeric ranges, non-empty text,
constrained collections, config values with invariants.

**[P2] Flag**: `newtype Foo = Foo { unFoo :: Text }` with `Foo(..)` in the
export list when the type has documented invariants that the constructor
doesn't enforce.

## Witness type pattern

When a multi-step pipeline requires that step N has completed before step
N+1 can proceed, use a witness type whose constructor is hidden. The only
way to obtain the witness is through the validating function.

```haskell
-- Module exports: AdmittedRewriteDelta (type only), admitRewriteDelta,
-- admittedDelta, admittedRemainingBudget
-- Constructor is NOT exported — cannot be constructed without validation.

data AdmittedRewriteDelta def = AdmittedRewriteDelta
  { ardDelta :: PlannedRewriteDelta def
  , ardRemainingBudget :: RewriteBudget
  }

admitRewriteDelta :: RewriteBudget -> PlannedRewriteDelta def
                  -> Either RewriteBudgetError (AdmittedRewriteDelta def)

-- Consumers must accept AdmittedRewriteDelta — the type proves budget
-- was checked before persistence.
persistStageRewrite :: ... -> AdmittedRewriteDelta stageId -> IO (...)
```

**Differs from smart constructors**: Smart constructors validate a value on
construction. Witness types prove that a *multi-value relationship* holds
(e.g., "this delta fits within this budget"). The witness bundles the
validated inputs with the computed result.

**Provide explicit accessor functions**: When the constructor is hidden,
`OverloadedRecordDot` field selectors are also hidden from external
modules. Export explicit accessor functions (`admittedDelta`,
`admittedRemainingBudget`) alongside the type.

**When to use**:
- Budget/quota admission before persistence
- Validation that must precede compilation (e.g., `ValidatedReportIR`)
- Authorization checks that gate downstream operations

**[P2] Flag**: A function that calls a validation step and then immediately
uses the result, where the validation could be skipped without a type
error. If 2+ call sites repeat the same validate-then-use pattern, extract
a witness type.

## Phantom type tagging

Use phantom types to distinguish same-shaped values at the type level:

```haskell
{-# LANGUAGE DataKinds #-}

newtype Id (entity :: Symbol) = Id UUID
  deriving newtype (Eq, Ord, Show, ToJSON, FromJSON)

type RunId = Id "Run"
type TaskId = Id "Task"
type StageLogId = Id "StageLog"

-- These are distinct types — swapping them is a compile error
claimRun :: TaskId -> IO RunId
```

**When to use**: When 2+ function parameters are the same underlying type
(typically UUID or Int64) and swapping them would compile but corrupt data.

**[P2] Flag**: Functions taking 2+ `UUID` parameters where the parameter
names are the only distinction between semantically incompatible IDs.

## Consistent record prefix convention

Follow the two-letter prefix convention for all record field names.
The prefix is the lowercase initials of the type name:

| Type | Prefix | Example field |
|---|---|---|
| `StageEnv` | `se` | `sePool`, `seRunId` |
| `PulseRunAdminView` | `prav` | `pravRunId`, `pravStatus` |
| `AttemptCtx` | `ac` | `acStageName`, `acLogId` |
| `RunFailure` | `rf` | `rfRunId`, `rfErrType` |

**Why**: Avoids record field name clashes across the module (important
before `DuplicateRecordFields` and `OverloadedRecordDot`). Also makes
grep-based navigation reliable.

**[style] Flag**: A new record type whose field names don't follow the
project prefix convention.

## Aeson instance discipline

### Public API types: explicit instances

Types that cross API boundaries (request/response bodies, webhook
payloads) must have explicit `ToJSON`/`FromJSON` instances, not
`Generic`-derived ones:

```haskell
-- BAD: renaming a field silently changes the API
data RunResponse = RunResponse
  { rrRunId :: UUID
  , rrName :: Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)  -- uses field names with prefix

-- GOOD: explicit instance with stable field names
instance ToJSON RunResponse where
  toJSON r = Aeson.object
    [ "run_id" .= r.rrRunId
    , "name" .= r.rrName
    ]
```

Alternatively, use `fieldLabelModifier` with prefix stripping:

```haskell
instance ToJSON PortfolioResponse where
  toJSON = genericToJSON defaultOptions
    { fieldLabelModifier = camelTo2 '_' . drop 2  -- strip "pr" prefix
    }
```

### Internal types: derived instances are fine

Types used only within the application (checkpoint state, internal config)
can use `Generic`-derived instances.

**[P2] Flag**: A `Generic`-derived JSON instance on a type used in a
public API endpoint without explicit field mapping.

## Applicative over Monad when possible

Use `Applicative` style (`<$>`, `<*>`) when operations are independent
and don't need sequencing. This communicates to the reader that there are
no data dependencies between sub-expressions.

```haskell
-- BAD: unnecessary monadic sequencing
do
  a <- pure (parseField x)
  b <- pure (parseField y)
  pure (Config a b)

-- GOOD: applicative — no data dependencies
Config <$> parseField x <*> parseField y

-- ALSO GOOD: just pure application
pure (Config (parseField x) (parseField y))
```

**When it matters most**: `Applicative` enables potential parallelism in
some contexts (e.g., `Concurrently`). More importantly, it signals to
the reader that the sub-expressions are independent.

**[style] Flag**: `do { a <- pure x; b <- pure y; pure (f a b) }` — should
be `f <$> pure x <*> pure y` or just `pure (f x y)`.

## Qualified import convention

Use consistent qualification for common modules across the codebase:

| Module | Qualification |
|---|---|
| `Data.Map.Strict` | `Map` |
| `Data.Text` | `T` |
| `Data.Text.Encoding` | `TE` |
| `Data.ByteString` | `BS` |
| `Data.ByteString.Lazy` | `BSL` |
| `Data.Aeson` | `Aeson` |
| `Hasql.Session` | `Session` |
| `Hasql.Transaction` | `Tx` |
| `Hasql.Decoders` | `D` |
| `Hasql.Encoders` | `E` |
| `Platform.Database` | `DB` |
| `Platform.Database.Encode` | `Enc` |

**[style] Flag**: Inconsistent qualification of the same module across
files (e.g., `Tx` in one file, `Trans` in another, unqualified in a third).
