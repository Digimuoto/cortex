# Architecture Patterns

Module structure, ADT design, error handling, and IO organization for
production Haskell.

## Three Layer Cake

Every module in Cortex belongs to one of three layers:

| Layer | Characteristics | Examples |
|---|---|---|
| **Layer 1: Pure** | No IO, no monad constraints. Types, decision logic, parsers, validation, ADT definitions. Trivially testable. | `decideScheduleAction`, `selectCases`, `parseAccountData`, `totalExpectedResultCount` |
| **Layer 2: Constrained effects** | Uses `ReaderT`, `ExceptT`, `Transaction`, or env-record-passing. Business logic that needs controlled effects. Testable with mock environments. | `syncAccount`, `persistEvalBatch`, `claimAndCreateRun` |
| **Layer 3: Effectful wiring** | `main`, server setup, connection pools, thread management, concrete IO. Thin orchestration that composes layers 1 and 2. | `main`, `startServer`, `runPulseWorker` |

### Layer violations to flag

- **Layer 1+3 mixing**: Pure decision logic interleaved with DB writes in
  the same function. The decision should be a separate pure function; the
  DB write should interpret its result.

- **Layer 2 leaking to layer 3**: Business logic functions that take
  `Pool` directly instead of working through `Transaction` or an env record.
  This couples the business logic to the specific IO implementation.

- **Layer 3 growing logic**: `main` or server setup code that contains
  branching business logic instead of delegating to layer 2 functions.

**[P2] Flag**: A function that mixes pure decision logic (layer 1) with
direct IO operations (layer 3). The decision and the execution should be
separate functions.

## Module organization

### Export lists

Every module gets an explicit export list. Group by role:

```haskell
module Cortex.Pulse.Executor
  ( -- * Entry points
    executeTask,
    resumeTask,

    -- * Stage plan execution (for testing)
    executeStagePlan,
    resumeStagePlan,

    -- * Types
    TaskContext (..),
    TaskHandler (..),
    TaskRegistry,
    StagePlan (..),
    StageDefinition (..),

    -- * Stage types (for task authors)
    StableStageId (..),
    StageReplaySafety (..),
    StageRetryPolicy (..),
    StageRetryBackoff (..),
  )
```

**Rules**:
- Export constructors (`(..)`) for types that consumers pattern-match on
- Export only the smart constructor for types with invariants
- Never export internal helpers; if tests need them, create a `.Internal` module
- Group exports by audience: entry points first, then types, then utilities

### File size

**What matters is complexity per function, not total lines.** A 1200-line file
of independent 30-line handlers is healthier than a 400-line file with one
200-line function.

**When size is NOT the problem** (do not split mechanically):
- Query modules: each function is independent, sharing only imports
- Servant route wiring: mechanical dispatch, low complexity per line
- Type definition modules: one type per API endpoint, naturally long
- Handler registries: independent handlers sharing `ServerContext` + patterns
- Domain-coherent modules: all portfolio operations in one file is correct

**When size IS the problem** (consider splitting):
- Individual functions exceed 80 lines (the function is too big, not the file)
- Unrelated concerns mixed: auth + CRUD + reporting in one file with shared state
- Deep coupling between sections: helpers calling each other across domains
- Merge conflicts from multiple developers editing different domains

If you split, split by concern, not by arbitrary line count:
- Pure logic → `Foo.Core` or `Foo.Types`
- Effectful execution → `Foo` (main module)
- Database queries → `Foo.Query`
- Test helpers → `Foo.Internal` or `Foo.Test`

### Language extensions

Most extensions are set in `cabal` `default-extensions` and don't need
per-module pragmas. Per-module pragmas are only for extensions outside
the defaults. See `type-conventions.md` for the full extension policy.

Per-module pragmas should be grouped by category:

```haskell
{-# LANGUAGE TypeFamilies #-}          -- type system (not in defaults)
{-# LANGUAGE DuplicateRecordFields #-} -- record handling (not in defaults)
```

**Banned** (silently break type safety): `IncoherentInstances`,
`ImpredicativeTypes`, `Strict`, `OverlappingInstances`.

## ADT design

### Decision types

Use closed ADTs for decisions that the system interprets:

```haskell
data ScheduleDecision
  = NoScheduleChange
  | RecordOutcomeOnly
  | CompleteOneOff
  | RestoreOneOffAt UTCTime
  | AdvanceRecurringTo UTCTime
  | RestoreRecurringAfterCronErrorAt UTCTime
```

**Properties of good decision types**:
- Every variant is handled somewhere (exhaustive matches)
- The decision function is pure (`Config -> Input -> Decision`)
- The interpreter is thin (maps each variant to 1–3 effectful operations)
- Adding a variant forces updates at every interpretation site

### Stable identifiers

When values are persisted to a database or serialized to JSON, use a typeclass
for stable text conversion:

```haskell
class StableStageId stageId where
  stageIdToText :: stageId -> Text

-- The textual representation NEVER changes once deployed.
instance StableStageId PaperPortfolioCycleStage where
  stageIdToText = \case
    StrategyResolution -> "strategy_resolution"  -- frozen
    Planner            -> "planner"              -- frozen
```

This separates the Haskell `Show` instance (which can change) from the
wire format (which cannot).

### Existential wrapping

When you need a heterogeneous collection of typed plans:

```haskell
data SomeStagePlan where
  SomeStagePlan :: (StableStageId stageId) => StagePlan stageId -> SomeStagePlan
```

Use sparingly. The existential hides the type parameter, so the consumer
can only use the typeclass interface. If you find yourself pattern-matching
to recover the type, the existential is wrong.

### Enum-driven stage definitions

For ordered linear pipelines, use `Bounded + Enum`:

```haskell
data PaperPortfolioCycleStage
  = StrategyResolution
  | PreflightSnapshot
  | Planner
  | ...
  | ShadowComplete
  deriving stock (Bounded, Enum, Eq, Show)

-- All stages, in order:
allStages = [minBound .. maxBound]
```

This guarantees no stages are accidentally omitted and the order is
defined in one place.

### Typeclass vs record-of-functions

**Use a plain record of functions** when:
- There's exactly one implementation at any given call site
- The "interface" is module-internal or has <=3 consumers
- You want to swap implementations at runtime (test doubles via record
  construction)

```haskell
-- GOOD: record of functions — one impl, easy to mock
data StageRunner = StageRunner
  { srRunQuery :: forall a. Query a -> IO a
  , srLogEvent :: Event -> IO ()
  , srCheckShutdown :: IO Bool
  }
```

**Use a typeclass** when:
- Multiple distinct types need the same interface (serialization, numeric,
  comparison)
- The abstraction is used across 10+ modules and would cause
  record-threading pain
- Laws exist that instances must satisfy (e.g., `Monoid` laws)

**[P2] Flag**: A typeclass with exactly one instance in the codebase. This
is a record of functions in disguise — it adds orphan risk and global
namespace pollution for no benefit.

### Newtype-driven dispatch

Replace `Text`-keyed dispatch with ADT-keyed dispatch when the set of keys
is known at compile time:

```haskell
-- BAD: stringly-typed dispatch over a closed set
case taskType of
  "portfolio_cycle" -> handlePortfolioCycle
  "response_eval"   -> handleResponseEval
  "data_import"     -> handleDataImport
  _                 -> handleUnknown taskType

-- GOOD: ADT dispatch — compiler enforces exhaustiveness
data TaskType = PortfolioCycle | ResponseEval | DataImport
  deriving stock (Bounded, Enum, Eq, Show)

case taskType of
  PortfolioCycle -> handlePortfolioCycle
  ResponseEval   -> handleResponseEval
  DataImport     -> handleDataImport
```

The `Text` representation is only for DB/API serialization, parsed at the
boundary (see "Boundary discipline" below).

**[P2] Flag**: A `case someText of "literal" -> ...` with 3+ branches over
a closed set of values. The dispatch should be on an ADT, with the `Text`
parsing happening at the system boundary.

## Error handling architecture

### Canonical error model

Standard Haskell conventions — no custom aliases or renamings:

- `Either e a` — pure success/failure. `Left` is error, `Right` is success.
- `ExceptT e m a` — monad transformer for effectful computations that can fail.
- `MonadError e m` — typeclass for polymorphic error handling when reuse justifies it.

We use the standard ecosystem. No `Result`, `Ok`, `Err`, or project-specific
aliases for `Either`.

### When to use `ExceptT`

Prefer `ExceptT` when a function is a **linear sequence of steps** where each
step may fail and the intent is to follow the happy path, short-circuiting on
the first failure:

- parsing → validating → loading → transforming
- decoding chains
- service/database calls with one common error channel
- request handling pipelines with uniform failure propagation

```haskell
-- GOOD: linear pipeline, each step can fail the same way
syncAccount :: Manager -> SyncConfig -> ExceptT AppError IO AccountData
syncAccount manager cfg = do
  token   <- ExceptT $ fetchToken manager cfg.authUrl
  profile <- ExceptT $ fetchProfile manager token
  account <- except $ parseAccountData profile
  pure account
```

**Rule of thumb**: when you see this repeated pattern:

```haskell
result1 <- doStep1
val1 <- case result1 of
  Left err -> return (Left err)   -- or throwE
  Right v  -> pure v
result2 <- doStep2 val1
val2 <- case result2 of
  Left err -> return (Left err)
  Right v  -> pure v
```

...refactor to `ExceptT`. The `do`-notation handles the short-circuiting.

### When explicit `Either` / `case` is better

Keep explicit pattern matching when the function is doing **decision-tree
orchestration** rather than linear propagation:

- Different failure cases require different observability/logging
- Different failure cases trigger different recovery behavior
- `Nothing`, retry, skip, cancellation, timeout, and terminal failure all
  have distinct meanings
- Local handling is more important than propagation
- Forcing everything into one `ExceptT` stack would obscure control flow

```haskell
-- GOOD: explicit branching — each failure has different recovery semantics
case runTransaction pool (claimLease runId) of
  Left "lease_lost" -> do
    logWarn "Lease lost, checking race window"
    checkRaceWindow actionAsync
  Left "run_cancelled" -> do
    logInfo "Run cancelled by operator"
    pure OutcomeCancelled
  Left err -> do
    logError "Unexpected DB error" err
    failRun pool runId now "db_error" err True
    pure OutcomeFailed
  Right lease -> executeWithLease lease
```

`ExceptT` is for **sequential failure flow**, not for every function that
touches `Either`.

### Refactoring to `ExceptT` — practical rules

**Do:**
- Extract small sequential helpers and convert those helpers to `ExceptT`
- Keep top-level orchestration explicit where that improves clarity
- Prefer incremental refactors over rewriting large functions at once

**Don't:**
- Rewrite large orchestrator functions into giant transformer stacks all at once
- Use `ExceptT` only to immediately unpack everything with ad hoc branching
- Create monadic soup — if the `ExceptT` version is harder to follow, keep
  the explicit version

### `MonadError` guidance

Polymorphism over `MonadError` is welcome when it genuinely improves reuse:

- Concrete `ExceptT` is often simplest and best at module boundaries
- `MonadError` is useful in reusable internal logic shared across contexts
- Do not introduce large, heavily constrained signatures unless there is a
  clear benefit across multiple call sites

```haskell
-- GOOD: concrete ExceptT at a boundary
runSync :: SyncConfig -> ExceptT AppError IO SyncResult

-- GOOD: MonadError for a reusable validator used in multiple contexts
validateTicker :: (MonadError AppError m) => Text -> m Ticker

-- BAD: MonadError on a function called from exactly one site
processOneReport :: (MonadError AppError m, MonadIO m, MonadReader Env m) => ReportId -> m ()
```

### Boundary handling patterns

Common lifting patterns at module boundaries:

```haskell
-- Lift a pure Either into ExceptT
validated <- except (parseConfig rawText)

-- Wrap an IO action returning Either into ExceptT
account <- ExceptT (fetchAccount manager accountId)

-- Run ExceptT at a boundary, converting to the caller's error model
runExceptT pipeline >>= \case
  Left err -> handleDomainError err
  Right val -> pure val
```

**Convert external errors early.** Don't let `Either String` from external
libraries spread through the codebase:

```haskell
-- BAD: Either String leaking through multiple layers
fetchData :: Manager -> IO (Either String RawData)
parseData :: RawData -> Either String ParsedData
process :: Manager -> IO (Either String Result)  -- String errors everywhere

-- GOOD: convert at the boundary
fetchData :: Manager -> ExceptT AppError IO RawData
fetchData mgr = ExceptT $ do
  result <- Http.fetchRaw mgr url
  pure $ first (\msg -> externalError "EODHD" (T.pack msg)) result
```

### Error type guidance

- Prefer structured domain error ADTs (`AppError`, `MoneyError`) over raw
  `String` / `Text` in core and orchestration layers
- Textual errors are acceptable at leaf boundaries or very small internal
  helpers where the string is immediately converted
- `Either String a` should not cross module boundaries — convert to a domain
  error type at the point of origin

### Error type hierarchy

Define a per-layer error type that mirrors the three-layer-cake:

| Layer | Error type | Example |
|---|---|---|
| **Layer 1: Pure** | ADTs for validation/parse errors | `ValidationError`, `ParseError`, `ConfigError` |
| **Layer 2: Business** | Domain-specific error ADTs | `RunError`, `ScheduleError`, `EvalError` |
| **Layer 3: Operational** | Infrastructure errors | `DbError`, `NetworkError`, `TimeoutError` |

Each layer converts lower-layer errors at the boundary:

```haskell
-- Layer 1 → Layer 2: wrap validation errors into domain errors
case validateConfig rawConfig of
  Left validationErr -> throwE (ConfigInvalid validationErr)
  Right config -> proceed config

-- Layer 3 → Layer 2: wrap DB errors into domain errors
dbResult <- liftIO (DB.runTransaction pool query)
case dbResult of
  Left dbErr -> throwE (RunDbError "claim_lease" dbErr)
  Right val -> pure val
```

**[P2] Flag**: `Either String a` propagated through 3+ function calls
without conversion to a domain error type.

**[P2] Flag**: `show` used to convert a structured error into `String` for
an `Either String` return — preserve the structure.

### Subsystem error ADT pattern

When a subsystem has multiple internal error types that cross function
boundaries, define a single error ADT at the subsystem edge. Provide a
`renderError` function for human messages and an `errorType` function for
stable observability strings.

```haskell
data RewriteError
  = RewriteValidationFailed [RewriteValidationError]
  | RewriteBudgetExhausted RewriteBudgetError
  | RewriteHydrationFailed Text
  | RewriteReconciliationFailed Text

-- Human-readable rendering
renderRewriteError :: RewriteError -> Text

-- Stable error type string for dashboards (must not change without coordination)
rewriteErrorType :: RewriteError -> Text
rewriteErrorType = \case
  RewriteValidationFailed {} -> "invalid_rewrite"
  RewriteBudgetExhausted {} -> "rewrite_budget_exceeded"
  RewriteHydrationFailed {} -> "graph_rewrite_hydration_failed"
  RewriteReconciliationFailed {} -> "graph_state_parse_failed"
```

Internal functions return `Either RewriteError`. At the executor boundary,
pattern match on the error ADT to produce the right `RunFailureSpec`:

```haskell
-- GOOD: error category preserved through the pipeline
case materializeRewrite rewrite plan state of
  Left rewriteErr ->
    failRun pool runId now (rewriteErrorType rewriteErr) (renderRewriteError rewriteErr) False

-- BAD: all errors collapsed to one string, categories lost
case materializeRewrite rewrite plan state of
  Left errMsg ->
    failRun pool runId now "invalid_rewrite" errMsg False
```

Convert to `Text` only at API boundaries (admin handlers, external
responses) using `renderRewriteError`.

**[P2] Flag**: `Either Text` propagated through 3+ functions within a
subsystem where the errors come from distinct categories (validation,
budget, hydration, reconciliation). Replace with a subsystem error ADT.

### Three-tier error handling

1. **Must succeed** (critical path): Failure terminates the operation.
   Use `requireTx` or equivalent. Returns `Maybe a`.

2. **Best effort** (non-critical): Failure is logged and execution continues.
   Audit log updates, observability writes. Use `case result of Left -> log; Right -> pure ()`.

3. **Last resort** (recovery): If this fails, a higher-level mechanism
   (lease expiry, cron re-schedule) will eventually clean up. Log prominently.

```haskell
-- Tier 1: must succeed
cpResult <- requireTx pool runId "write_checkpoint" . DB.runTransaction pool $ ...
case cpResult of
  Nothing -> pure (StageTerminal OutcomeFailed)
  Just () -> ...

-- Tier 2: best effort
stageLogResult <- DB.runTransaction pool $ Q.updateStageCompleted ...
case stageLogResult of
  Left err -> logWarn "Non-critical: failed to update stage log" err
  Right () -> pure ()

-- Tier 3: last resort
failRun pool runId now errType errMsg retryable
-- If failRun itself fails, it logs "LAST RESORT" and the lease will expire
```

### Error handling anti-patterns

- **Deeply nested `case Left / Right` ladders** for purely sequential logic —
  use `ExceptT`
- **Giant `ExceptT` stacks** in orchestration-heavy functions — keep explicit
  branching where each failure has different recovery
- **Mixing exceptions and `Either`/`ExceptT` carelessly** — pick one error
  channel per function; don't catch IO exceptions into `Left` and then throw
  them again
- **`Either String` spreading through core layers** — convert to domain error
  types at the boundary
- **Using `ExceptT` only to immediately unpack** — if every `throwE` is
  followed by a `case` that branches differently, the transformer adds noise

### Practical error handling rules

These rules are derived from recurring patterns in integration and service code.

**1. Use `ExceptT` for linear boundary pipelines.**
If a function is mostly load → validate → fetch → transform → persist
and failures should short-circuit, prefer `ExceptT` over nested `case` chains.
Top-level workflow should read as business steps:

```haskell
runSync :: ExceptT AppError IO SyncResult
runSync = do
  acct  <- loadAccount pool userId acctId
  creds <- validateCredentials acct
  data' <- fetchRemoteData mgr creds
  persist pool data'
```

**2. Keep retry/recovery loops explicit.**
Do not force `ExceptT` into retry loops, recovery trees, or orchestration
code where different failure cases trigger different local behaviors (retry,
shrink range, skip, cancel, terminal failure). Explicit branching is clearer
when recovery semantics vary per case.

**3. Wrap noisy boundary APIs in domain helpers.**
When an external API or parser repeatedly requires `ExceptT` wrapping and
error translation, extract small domain helpers so call sites read in domain
language rather than transformer plumbing:

```haskell
-- BAD: repeated at every call site
withExceptT (\e -> externalError "IBKR" (T.pack e)) (ExceptT $ fetchFlexQuery mgr cfg)

-- GOOD: extract once
fetchFlexQueryE :: Manager -> FlexQueryConfig -> ExceptT AppError IO ByteString
fetchFlexQueryE mgr cfg = withExceptT (\e -> externalError "IBKR" (T.pack e)) $
  ExceptT (fetchFlexQuery mgr cfg)
```

**4. Convert external/string errors into domain errors early.**
At integration boundaries, convert raw `String`/`Text` errors into domain
error values as early as practical. Never let unstructured external errors
spread through core application logic.

**5. Extract policy helpers from busy functions.**
When a function mixes policy decisions with IO, parsing, persistence, and
observability, extract policy-sized helpers so the top-level function reads
as a workflow. Helper categories: fetch, parse, persist, fallback policy.

**6. Prefer named helpers over dense transformer expressions.**
When `ExceptT` expressions become visually dense due to repeated `ExceptT`,
`except`, `withExceptT`, and `catchE` composition, extract named helpers.
Optimize for readable workflows, not minimal line count.

**7. Use domain ADTs when `Either e (Maybe a)` accumulates meanings.**
When nested control meanings accumulate in types like
`Either String (Maybe FlexQueryResponse)`, consider a small domain ADT if
it improves readability and makes state distinctions explicit:

```haskell
data ChunkFetchResult
  = ChunkFetchFailed String
  | ChunkFetchEmpty
  | ChunkFetchSucceeded FlexQueryResponse
```

**8. Catch exceptions only at deliberate effect boundaries.**
Use `Either`/`ExceptT` for expected failures. Catch exceptions at explicit
effect boundaries where you interact with throwing APIs, then translate them
into domain errors immediately. Do not mix exception catching and
`Either`/`ExceptT` carelessly within the same function.

**9. At boundaries, prefer concrete stacks over premature polymorphism.**
At service and integration boundaries, prefer concrete monad stacks
(`ExceptT AppError IO`) and concrete error types over `MonadError`/`MonadIO`
constraints. Reach for polymorphism only when reuse clearly benefits
multiple call sites.

**10. Avoid speculative fields and dormant structure.**
Prefer deleting speculative or dormant fields until they are truly needed.
Data structures should reflect current semantics, not anticipated future
branches, unless the extension point is already active and justified.

**11. Prefer standard combinators over local operator redefinitions.**
Do not locally redefine widely-recognized operators (`<|>`, `<>`, `>>=`).
Import the standard version. Local redefinitions increase surprise and reduce
readability.

**12. Name best-effort functions honestly.**
When a function is best-effort, partially tolerant of failure, or includes
fallback behavior, make that explicit in documentation and, when helpful,
in naming. Prevent misleadingly strict-sounding APIs.

### Async exception safety

Always re-throw async exceptions. Never catch them generically:

```haskell
stageResult <- try (stageDef.sdAction runId state)
case stageResult of
  Left (e :: SomeException)
    | Just (_ :: AsyncException) <- fromException e ->
        throwIO e          -- ALWAYS re-throw
    | otherwise ->
        handleSyncError e  -- only handle synchronous exceptions
  Right val -> ...
```

### Timeout handling

Timeouts manifest as both `System.Timeout.Timeout` exceptions (thrown by
the timeout mechanism) and `Nothing` returns (from `Timeout.timeout`).
Handle both:

```haskell
case effectiveTimeout of
  Nothing -> tryAction Nothing
  Just secs -> do
    result <- Timeout.timeout (fromIntegral secs * 1_000_000) (tryAction (Just secs))
    case result of
      Nothing     -> pure (Left (StageFailureTimeout secs))   -- timeout wrapper
      Just inner  -> pure inner                                 -- includes timeout exceptions
```

## Boundary discipline

### Parse at the boundary, use types internally

Parse unstructured data (`Text`, `Value`, `ByteString`) into domain types
at the system boundary. Internal functions never operate on raw text when
a parsed type exists.

```haskell
-- BAD: business logic parses text inline
processRun :: Text -> IO ()
processRun statusText =
  case statusText of
    "running"   -> handleRunning
    "completed" -> handleCompleted
    "failed"    -> handleFailed
    _           -> handleUnknown statusText

-- GOOD: parse at the boundary, pass the ADT inward
data RunStatus = Running | Completed | Failed

parseRunStatus :: Text -> Either Text RunStatus
parseRunStatus = \case
  "running"   -> Right Running
  "completed" -> Right Completed
  "failed"    -> Right Failed
  other       -> Left ("Unknown run status: " <> other)

-- Internal function takes the parsed type
processRun :: RunStatus -> IO ()
processRun = \case
  Running   -> handleRunning
  Completed -> handleCompleted
  Failed    -> handleFailed
```

**Pattern**: API handler parses request -> domain type -> business logic.
DB query returns raw row -> decoded to domain record in the query module.

**[P2] Flag**: A business logic function that takes `Text` and does
`case text of "running" -> ...` — the parsing should happen at the boundary.

### Monomorphic return types at module boundaries

Public functions should return concrete types, not polymorphic ones:

```haskell
-- GOOD: concrete, clear, no constraint noise
getUser :: Pool -> UserId -> IO (Maybe User)

-- BAD: polymorphic signature when all callers use the same concrete stack
getUser :: (MonadIO m, MonadReader env m, HasPool env) => UserId -> m (Maybe User)
```

Polymorphic signatures at module boundaries make error messages worse
and obscure what the function actually does. Use polymorphism only when
it's genuinely needed by 3+ callers with different monads.

**[P2] Flag**: A public function with 3+ typeclass constraints when all
callers use the same concrete stack.

## Concurrency patterns

### Lease-based ownership

For distributed work that must not be executed concurrently:

1. Claim a lease with a TTL in the database
2. Renew the lease at half the TTL interval
3. If renewal fails: check if the action completed (race window), then cancel
4. If the action completes naturally: stop renewing

The critical subtlety: after cancelling an action due to lease loss,
always check if it completed in the race window:

```haskell
cancel actionAsync
waitCatch actionAsync >>= \case
  Right outcome -> pure outcome   -- completed despite lease loss
  Left _        -> failRun ...    -- genuinely interrupted
```

### Shutdown coordination

Use a `TVar Bool` shutdown flag. Check it:
- Before starting each stage (checkpoint boundary)
- During retry delays (STM-aware delay)
- In the scheduler poll loop

Shutdown produces a specific outcome (`OutcomeShutdown`) that is handled
differently from failure — it doesn't trigger retries or schedule advances.

**[P2] Flag**: `threadDelay` in a loop without a shutdown check.
**[P2] Flag**: `forever` without a shutdown-aware break condition.

### Rewrite budget policy

The rewrite budget policy is **fail-fast**: any rewrite whose structural
cost exceeds the remaining budget in any single dimension is rejected
immediately, the stage fails, and the run terminates. There is no soft-cap,
deferred rejection, or configurable policy mode.

Budget enforcement is type-level via `AdmittedRewriteDelta` — the witness
type can only be constructed through `admitRewriteDelta`, which checks the
budget. Functions that persist or materialize rewrites accept
`AdmittedRewriteDelta`, making it impossible to skip the budget check.

Rejected rewrites are persisted to `pulse.graph_rewrites` with
`status = 'rejected'`, `rejection_reason`, and `exceeded_dimensions` for
operator visibility. The `EvtRewriteRejected` executor event carries the
rejection type and message for structured observability.

A zero-budget (`RewriteBudget 0 0 0 0 0`) disables rewrites entirely while
preserving graph-state execution for static plans. Tasks that never produce
rewrites can safely use any budget — budget is only consumed when a stage
returns `StageRewrite`.

### Retry policy as data

Represent retry policies as values, not inline code:

```haskell
data RetryPolicy = RetryPolicy
  { rpMaxAttempts :: Int
  , rpBaseDelayMicros :: Int
  , rpBackoff :: RetryBackoff
  }

data RetryBackoff
  = FixedBackoff
  | ExponentialBackoff { rbFactor :: Double, rbMaxDelayMicros :: Int }

withRetry :: RetryPolicy -> IO a -> IO (Either RetryExhausted a)
```

A single interpreter (`withRetry`) reads the policy. Individual retry
call sites construct the policy value; they don't embed retry logic.

**[P2] Flag**: Retry logic inlined in business code with hardcoded delays
and attempt counts. Different retry shapes (exponential, linear, with
jitter) scattered across modules without a shared abstraction.

### Resource acquisition bracket discipline

Every resource that needs cleanup must use `bracket`, `withAsync`,
`finally`, or equivalent RAII-style acquisition:

```haskell
-- GOOD: bracket ensures cleanup
bracket (acquireLease pool runId) (releaseLease pool) $ \lease ->
  executeWithLease lease

-- GOOD: withAsync ensures thread cleanup
withAsync (renewalLoop pool lease) $ \renewalAsync ->
  executeAction env >>= \result ->
    cancel renewalAsync >> pure result
```

**[P1] Flag**: `forkIO` without corresponding cleanup logic.
**[P2] Flag**: `openFile` / `createConnection` without a bracket.
**[P2] Flag**: `async` without `withAsync` or `link`.

## Servant server structure

### Context threading

Avoid god objects. Group `ServerContext` fields by capability:

```haskell
data ServerContext = ServerContext
  { dbPool              :: DB.Pool
  , httpManager         :: Manager
  , observabilityRuntime :: ObservabilityRuntime
  , orgConfig           :: OrgConfig
  , adminPepper         :: AdminPepper
  , deploymentInfo      :: DeploymentInfo       -- grouped metadata
  , assistantContext    :: AssistantContext      -- subsystem-scoped state
  }
```

When `ServerContext` or equivalent exceeds 10 fields, group by capability:

```haskell
data DbCapability = DbCapability
  { dcPool :: Pool
  , dcRetryPolicy :: RetryPolicy
  }

data AuthCapability = AuthCapability
  { acPepper :: ByteString
  , acTokenTTL :: Int
  }

data AppEnv = AppEnv
  { aeDb :: DbCapability
  , aeAuth :: AuthCapability
  , aeObservability :: ObservabilityRuntime
  }
```

Functions take only the capability they need: `handleLogin :: AuthCapability -> ...`
not `handleLogin :: AppEnv -> ...`.

**[P2] Flag**: A function that receives the full `AppEnv`/`ServerContext`
but only accesses 1-2 fields — it should take the specific sub-record.

### Has-class for shared capabilities

When 3+ environment records share a common field (e.g., pool, logger),
define a `Has` class so functions can be polymorphic over which env they
receive:

```haskell
class HasPool env where
  getPool :: env -> Pool

instance HasPool ServerContext where getPool = (.dbPool)
instance HasPool StageEnv where getPool = (.sePool)
instance HasPool WorkerEnv where getPool = (.wePool)

-- Function works with any env that has a pool
runQuery :: (HasPool env) => env -> Query a -> IO a
runQuery env query = DB.withConnection (getPool env) query
```

**When to introduce**: 3+ env types share the same field. Premature
Has-classes on a single env type add noise.

### Route type naming

All by-ID sub-routes get named types in the API module:

```haskell
-- In API module:
type PortfolioByIdAPI = Get '[JSON] PortfolioResponse :<|> ...

-- In Server module:
portfolioByIdRoutes :: ServerContext -> AuthenticatedUser -> PortfolioId
                    -> Server PortfolioByIdAPI
```

Never inline a multi-line type signature in the server wiring module.

### Authentication consistency

Pass `AuthenticatedUser` to all protected handlers. Let handlers unwrap
to `UUID` if they need only the ID. Don't unwrap at the routing layer —
handlers may eventually need role information.

### QueryParam positional parameters

Servant's `QueryParam` produces one handler parameter per query param.
This is a framework constraint — you cannot bundle them into a record at
the API type level without custom combinators.

**The right fix**: immediately construct a named record on the first line of
the handler. This is what well-written handlers already do:

```haskell
listCostsHandler ctx maybeFrom maybeTo maybeUserId maybeProvider maybeModel maybeLimit = do
  let filterParams = AssistantUsageFilter { aufFrom = ..., aufTo = ..., ... }
  -- rest of handler uses filterParams, never the positional names
```

**Do NOT flag** QueryParam positional parameters as a parameter safety issue
when the handler already bundles them. The positional signature is forced by
Servant, and the code handles it correctly.

## Observability

### Event emitter pattern

Define one emitter per subsystem, not per module:

```haskell
type EventEmitter = ObservabilityLogLevel -> Text -> Text -> [(Text, Value)] -> IO ()

mkEventEmitter :: Text -> EventEmitter
mkEventEmitter component level operation message fields =
  emitGlobalEvent $
    (defaultLogEvent level component operation message)
      { eventExtraFields = fields }

-- Usage:
emitEvent = mkEventEmitter "cortex-pulse"
```

### Severity calibration

- **Error**: Something is wrong that may require operator attention. Duplicate
  execution possible. Data loss possible.
- **Warn**: Something unexpected happened but the system recovered or will
  recover automatically. Failed non-critical write. Retrying a stage.
- **Info**: Normal lifecycle events. Task started. Stage completed. Scheduler
  stopping.

If it wakes someone up at 3am, it's Error. If it shows up in a daily
review, it's Warn. If it's noise in normal operation, it's Info.

### Structured fields

Always include correlation IDs:

```haskell
emitEvent ObsInfo "pulse.executor.stage.completed" "Stage completed"
  [ ("run_id", Aeson.toJSON env.seRunId)
  , ("stage", Aeson.toJSON stageName)
  , ("attempts", Aeson.toJSON attempt)  -- only if > 1
  ]
```

Convention: include `run_id` on all run-scoped events, `task_id` on all
task-scoped events. Add context-specific fields only when they aid debugging.

### Required fields per domain

Codify the minimum structured fields per log domain:

| Domain | Required fields |
|---|---|
| **Pulse operations** | `run_id`, `task_id`, `stage_name`, `attempt` |
| **Finance operations** | `portfolio_id`, `symbol`, `operation` |
| **API handlers** | `request_id`, `handler_name`, `user_id` |

Define a `LogContext` record per domain and a helper that attaches all
fields at once, so individual log calls can't accidentally omit fields:

```haskell
data PulseLogContext = PulseLogContext
  { plcRunId :: UUID
  , plcTaskId :: UUID
  , plcStageName :: Text
  , plcAttempt :: Int
  }

emitPulseEvent :: PulseLogContext -> ObservabilityLogLevel -> Text -> Text -> IO ()
emitPulseEvent ctx level op msg =
  emitEvent level op msg
    [ ("run_id", Aeson.toJSON ctx.plcRunId)
    , ("task_id", Aeson.toJSON ctx.plcTaskId)
    , ("stage", Aeson.toJSON ctx.plcStageName)
    , ("attempt", Aeson.toJSON ctx.plcAttempt)
    ]
```

**[P2] Flag**: A log call in Pulse code that omits `run_id`.
