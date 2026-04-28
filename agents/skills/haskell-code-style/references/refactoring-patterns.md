# Refactoring Patterns

Concrete patterns for decomposing Haskell code. Each pattern includes the symptom, the principle,
and a before/after sketch.

## Pattern 1: Return a value, don't perform a continuation

### Symptom

A function inside a `where` block sometimes calls the enclosing loop's continuation
(`go rest newState`) and sometimes returns a terminal value (`pure OutcomeFailed`). The function has
two exit modes but they look identical syntactically.

### Principle

Split the decision from the continuation. The inner function returns a result type. The loop
interprets it.

### Technique

1. Define a result ADT with one variant per exit mode:

   ```haskell
   data StageAttemptResult
     = StageAdvance Aeson.Value  -- caller should continue with this state
     | StageSkip                 -- caller should continue with original state
     | StageTerminal RunOutcome  -- caller should stop
   ```

2. Change the inner function's return type from `IO RunOutcome` to `IO StageAttemptResult`.

3. Replace all `go rest newState` calls with `pure (StageAdvance newState)`.

4. In the loop, pattern match on the result:
   ```haskell
   go (stage : rest) state = do
     result <- attemptStage env stage state
     case result of
       StageAdvance s  -> go rest s
       StageSkip       -> go rest state
       StageTerminal o -> pure o
   ```

### When NOT to apply

If the function only ever returns (never calls the continuation), it's already returning a value.
Don't wrap it in a redundant ADT.

## Pattern 2: Extract environment records from closures

### Symptom

A `where` block defines 3+ helper functions. Each closes over 5+ bindings from the enclosing scope
(`pool`, `runId`, `taskType`, `config`, ...). The helpers can't be promoted to top-level because
they'd need too many parameters.

### Technique

1. Identify the shared bindings. Usually: a DB pool, an entity ID, some config values, and a
   shutdown/cancellation flag.

2. Define a record:

   ```haskell
   data StageEnv = StageEnv
     { sePool     :: DB.Pool
     , seRunId    :: UUID
     , seTaskType :: Text
     , ...
     }
   ```

3. Construct it once in the enclosing function:

   ```haskell
   runStagePlan taskContext runId taskType ... = do
     let env = StageEnv { ... }
     go env remaining initialState
   ```

4. Promote each `where`-bound helper to module scope, taking `env` as first argument.

### Naming convention

Use a two-letter prefix matching the record name: `sePool` for `StageEnv`, `acRunState` for
`AssistantContext`. Avoids record field clashes across the module.

### When it leads to ReaderT

If the environment is threaded through every function in a module, `ReaderT` is the natural next
step. But start with the plain record — it's simpler, explicit, and doesn't require monad
transformer knowledge to read.

## Pattern 3: Collapse same-shaped branches

### Symptom

A case expression with 5+ branches where each branch does:

1. Run a transaction
2. Case on the result (Left err / Right ())
3. Log an error or success

...with only the log severity, operation name, message, and fields differing.

### Technique

1. Factor out the common flow:

   ```haskell
   finalize :: Pool -> UUID -> Transaction () -> FinalizationLog -> IO ()
   finalize pool taskId tx logSpec = do
     result <- DB.runTransaction pool tx
     case result of
       Left err -> emitEvent logSpec.errorLevel logSpec.errorOp (logSpec.errorMsg <> T.pack err) logSpec.errorFields
       Right () -> for_ logSpec.successEvent $ \evt ->
                     emitEvent evt.level evt.op evt.msg evt.fields
   ```

2. Make the per-branch differences a data type:

   ```haskell
   data FinalizationLog = FinalizationLog
     { errorLevel  :: LogLevel
     , errorOp     :: Text
     , errorMsg    :: Text
     , errorFields :: [(Text, Value)]
     , successEvent :: Maybe LogEvent
     }
   ```

3. Each branch just constructs the data and calls the common flow.

### When NOT to apply

If the branches have genuinely different recovery semantics (one retries, one fails, one ignores),
they're not same-shaped — the differences are behavioral, not just textual. Keep them separate.

## Pattern 4: Split audit bookkeeping from business logic

### Symptom

A function interleaves "do the work" with "log that we started the work" and "log that we finished
the work" and "update the audit table".

### Technique

Separate into two functions:

```haskell
-- Audit setup: open log entry, get attempt number
executeStage :: StageEnv -> StageDefinition -> Text -> Value -> IO StageAttemptResult
executeStage env stageDef stageName state = do
  (logId, attemptNumber, reused) <- setupStageAudit env stageName
  attemptStage env stageDef stageName state logId attemptNumber

-- Business logic: run the action, checkpoint, handle failure
attemptStage :: StageEnv -> StageDefinition -> Text -> Value -> Int64 -> Int -> IO StageAttemptResult
```

The audit function does DB bookkeeping. The business function does the actual work. Neither knows
about the other's concerns.

## Pattern 5: Shutdown-aware delays

### Symptom

`threadDelay` in a retry loop blocks the entire duration even when shutdown is requested.

### Technique

Use `registerDelay` + STM to watch both the delay and the shutdown flag:

```haskell
awaitDelayOrShutdown :: TVar Bool -> Int -> IO ()
awaitDelayOrShutdown shutdownFlag delayMicros =
  when (delayMicros > 0) $ do
    expired <- registerDelay delayMicros
    atomically $ do
      e <- readTVar expired
      s <- readTVar shutdownFlag
      check (e || s)
```

This wakes immediately on shutdown instead of blocking the full backoff.

## Pattern 6: Lease renewal as a combinator

### Symptom

An action needs to run under a renewable lease. The lease renewal is interleaved with the action
execution using `race` or `withAsync`.

### Technique

Wrap the lease lifecycle in a combinator:

```haskell
withLeaseRenewal :: DB.Pool -> UUID -> Int32 -> IO a -> IO a
```

Inside:

1. `withAsync action` to run the action concurrently
2. `race (waitCatch actionAsync) (threadDelay interval)` to detect completion vs renewal time
3. On renewal time: attempt renewal, handle loss gracefully
4. On lease loss: cancel the action, but check if it completed in the race window before declaring
   failure

The key subtlety: after `cancel actionAsync`, always `waitCatch` and check if the action completed
naturally. The action might have finished between lease loss detection and cancellation.

## Pattern 7: Replace repetitive dispatch with a Map registry

### Symptom

A case expression with 30+ branches, each doing the same thing with different strings:

```haskell
case (name, value) of
  ("foo", Right v) -> case fromJSON v of Error e -> err e; Success a -> run (fooHandler a)
  ("bar", Right v) -> case fromJSON v of Error e -> err e; Success a -> run (barHandler a)
  -- ... 30 more identical branches
```

### Technique

1. Define a dispatch helper that wraps the common per-branch logic:

   ```haskell
   tool :: (FromJSON a) => (a -> Handler Text) -> Value -> Handler Text
   tool handler value = case fromJSON value of
     Error err -> invalidArgs (T.pack err)
     Success args -> runSafe (handler args)
   ```

2. Build a `Map Text (Value -> Handler Text)` registry:

   ```haskell
   registry = Map.fromList
     [ ("foo", tool fooHandler)
     , ("bar", tool barHandler)
     , ...
     ]
   ```

3. Replace the case with a lookup:
   ```haskell
   case Map.lookup name registry of
     Just dispatch -> dispatch value
     Nothing -> pure ("Unknown: " <> name)
   ```

### When to apply

- 5+ branches with identical structure differing only in strings and handler names
- The dispatch pattern is parse → validate → run (or similar)
- Handlers have varying signatures — use partial application to unify them

### When NOT to apply

- If branches have genuinely different structure (some parse JSON, some don't, some need extra
  context). Forcing them into a uniform shape hides differences.
- If there are only 3–4 branches — the case statement is more direct.

## Pattern 8: Mechanical repetition → combinator module

### Symptom

The same 3–5 line pattern appears 10+ times across multiple modules, with only types or field names
varying. Common in: Hasql encoder/decoder construction, event emission, error logging boilerplate.

```haskell
-- This exact shape appears 15 times across 5 query modules:
( ((\(a, _, _, _) -> a) >$< E.param (E.nonNullable E.uuid))
    <> ((\(_, b, _, _) -> b) >$< E.param (E.nonNullable E.text))
    <> ((\(_, _, c, _) -> c) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\(_, _, _, d) -> d) >$< E.param (E.nonNullable E.text))
)
```

### Technique

Build a small combinator module that captures the repeated shape:

```haskell
-- Platform.Database.Encode
encode4 ::
  (t -> a) -> NullableOrNot Value a ->
  (t -> b) -> NullableOrNot Value b ->
  (t -> c) -> NullableOrNot Value c ->
  (t -> d) -> NullableOrNot Value d ->
  Params t
```

Each call site shrinks from N lines of tuple destructors to 1 function call.

### When to apply

- **3+ modules** share the identical pattern shape (not just similar — identical)
- The pattern is **mechanical** (encoders, decoders, event structures), not business logic
- The combinator is **small** (<50 lines) and **stable** (unlikely to change)

### When NOT to apply

- Only 1–2 modules use the pattern — keep it local
- The pattern involves business logic decisions — inline duplication is safer because each site may
  diverge as requirements change
- Building the combinator requires type-level machinery that makes it harder to understand than the
  repetition

## Pattern 9: Sequential Either chains → ExceptT

### Symptom

A function runs 3+ steps where each returns `Either e a` or `IO (Either e a)`, and each failure is
handled identically — propagate the error, stop the pipeline:

```haskell
-- BAD: repetitive case-of plumbing for purely sequential logic
syncAccount :: Manager -> SyncConfig -> IO (Either AppError AccountData)
syncAccount manager cfg = do
  tokenResult <- fetchToken manager cfg.authUrl
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      profileResult <- fetchProfile manager token
      case profileResult of
        Left err -> pure (Left err)
        Right profile ->
          case parseAccountData profile of
            Left err -> pure (Left err)
            Right account -> pure (Right account)
```

### Technique

Convert to `ExceptT`. The monad's bind handles the short-circuiting:

```haskell
-- GOOD: ExceptT eliminates the plumbing, happy path reads linearly
syncAccount :: Manager -> SyncConfig -> ExceptT AppError IO AccountData
syncAccount manager cfg = do
  token   <- ExceptT $ fetchToken manager cfg.authUrl
  profile <- ExceptT $ fetchProfile manager token
  except $ parseAccountData profile
```

Key lifting patterns:

- `ExceptT action` — wraps `m (Either e a)` into `ExceptT e m a`
- `except value` — lifts a pure `Either e a` into `ExceptT e m a`
- `liftIO action` — lifts `IO a` (infallible) into `ExceptT e IO a`
- `withExceptT f` — maps the error type (use to convert `String` → `AppError`)

Run at the call site boundary:

```haskell
result <- runExceptT (syncAccount manager cfg)
case result of
  Left err -> handleError err
  Right account -> proceed account
```

### Incremental migration

Don't rewrite a 200-line orchestrator into one giant `ExceptT do` block. Instead:

1. Identify the sequential sub-pipeline (the part that's just propagating)
2. Extract it into a helper function using `ExceptT`
3. Call the helper from the orchestrator with `runExceptT`
4. Keep the orchestrator's decision logic explicit

```haskell
-- Extract the sequential part
loadAndValidate :: Manager -> Config -> ExceptT AppError IO ValidatedData
loadAndValidate mgr cfg = do
  raw       <- ExceptT $ fetchRaw mgr cfg.endpoint
  decoded   <- except $ decodePayload raw
  validated <- except $ validateFields decoded
  pure validated

-- Orchestrator stays explicit — different failures, different handling
orchestrate :: Manager -> Config -> IO Outcome
orchestrate mgr cfg = do
  result <- runExceptT (loadAndValidate mgr cfg)
  case result of
    Left (ExternalServiceError _ _) -> do
      logWarn "External service down, will retry"
      scheduleRetry cfg
      pure OutcomeRetry
    Left err -> do
      logError "Validation failed" err
      pure OutcomeFailed
    Right validated -> do
      processValidated validated
      pure OutcomeCompleted
```

### When NOT to apply

- Each `Left` branch has materially different behavior (logging, retry, skip, cancel) — keep
  explicit pattern matching
- The function is primarily orchestration with occasional fallible steps — `ExceptT` would obscure
  the control flow
- Only 1–2 steps — the overhead of `runExceptT` isn't worth it
- The error types differ across steps and don't share a common type — don't force `withExceptT`
  gymnastics

## Pattern 10: Typed failure domains instead of exceptions

### Symptom

A function uses `try` to catch `SomeException`, then pattern-matches on specific exception types to
classify outcomes (skip, timeout, failure). The control flow relies on exception-shaped paths for
domain-level decisions.

```haskell
-- BAD: timeout and skip are domain outcomes, not exceptional conditions
result <- try $ do
  mResult <- timeout timeoutUs $ processJob env job
  case mResult of
    Nothing -> fail $ "Timed out after " <> show secs <> "s"  -- string-encoded timeout
    Just r -> pure r
case result of
  Left (e :: SomeException)
    | Just (JobSkipped reason) <- fromException e -> handleSkip ...
    | otherwise -> handleFailure ...
  Right count -> handleSuccess count
```

### Technique

Model the outcomes as a sum type. The business function returns the type; the caller pattern-matches
without exception machinery.

```haskell
-- GOOD: all outcomes are data, not exceptions
data JobResult
  = JobCompleted Int
  | JobSkipped Text
  | JobTimedOut Int  -- timeout seconds

runJobWithTimeout :: Int -> HydrationEnv -> Job -> IO JobResult
runJobWithTimeout timeoutUs env job = do
  mResult <- timeout timeoutUs $ processJob env job
  case mResult of
    Nothing -> pure (JobTimedOut (timeoutUs `div` 1_000_000))
    Just (Left reason) -> pure (JobSkipped reason)
    Just (Right count) -> pure (JobCompleted count)

-- Caller: clean pattern match, no exception classification
case runJobWithTimeout timeoutUs env job of
  JobCompleted n -> persistSuccess ...
  JobSkipped reason -> persistSkip ...
  JobTimedOut secs -> persistTimeout ...
```

### When to apply

- The function catches generic exceptions then immediately classifies by type
- Two or more exception types carry domain meaning (skip, timeout, cancel)
- `fail` or `error` is used to encode a known condition as a string

### When NOT to apply

- True unexpected exceptions (OOM, segfault, async cancel) — those stay as exceptions
- The leaf function is third-party and you can't change its return type
- Only one exception type matters — a simple `try`/`catch` is fine

## Pattern 11: Decompose large orchestration functions

### Symptom

A single function (>80 lines) does orchestration + timeout + exception classification + DB
persistence + observability + post-processing. Each concern is entangled with the others, making the
function hard to modify or test in isolation.

### Technique

Split into a pipeline of named helpers, each handling one concern:

```haskell
executeJob :: Pool -> Job -> IO JobPollResult
executeJob pool job = do
  claimResult <- claimJobRun pool job           -- CAS claim
  case claimResult of
    ClaimLost -> pure NoWork
    ClaimFailed -> pure FetchError
    ClaimSuccess runId -> do
      result <- runJobWithTimeout pool job runId  -- dispatch + timeout
      persistJobResult pool runId result           -- status + schedule
      pure DidWork

-- Each helper is independently readable and testable
claimJobRun :: Pool -> Job -> IO ClaimResult
runJobWithTimeout :: Pool -> Job -> UUID -> IO JobResult
persistJobResult :: Pool -> UUID -> JobResult -> IO ()
```

### Naming convention

Name helpers for **what they return or accomplish**, not the mechanical steps inside:

- `claimJobRun` (returns `ClaimResult`), not `doCASAndCreateRun`
- `runJobWithTimeout` (returns `JobResult`), not `executeAndHandleTimeout`
- `persistJobResult` (persists + advances schedule), not `doStatusUpdateAndSchedule`

### When to apply

- Function exceeds 80 lines
- Three or more concerns are interleaved (claim, execute, persist, observe)
- Same-shaped branches appear for different outcome types (skip/fail/success all do: emit event →
  persist status → advance schedule)

### When NOT to apply

- Function is already under 50 lines — decomposition adds indirection without reducing complexity
- Only one caller exists and the helpers would need 5+ threaded parameters — the function boundary
  is in the wrong place (try an environment record first)

## General refactoring heuristics

- **Extract when the function exceeds 50 lines** (hard limit: 80)
- **Extract when `where` nesting exceeds 3 levels**
- **Extract when a `where`-bound function is called from multiple branches**
- **Don't extract single-use helpers to module scope** unless they're independently testable
- **Name extracted functions for what they return**, not what they do: `persistStageSuccess`
  (returns `StageAttemptResult`), not `doCheckpointAndContinue`
- **Preserve identical behavior**: refactoring is structural, not behavioral. Same DB calls, same
  log events, same error semantics. Verify by diffing the observable effects.

### The net-complexity test

Before committing an extraction, check:

1. **Does it reduce total lines?** Adding lines is fine when adding error handling or separation of
   concerns. But an extraction that adds lines without adding testability, error coverage, or caller
   simplification is just indirection. The goal isn't fewer lines — it's less total complexity.

2. **How many call sites?** A function extracted from one call site is just indirection. Extract at
   2+ sites minimum, prefer 3+.

3. **Does it need the upstream context?** If extracting requires threading 5+ parameters that were
   free closures before, the function boundary is in the wrong place. Consider extracting an
   environment record first (Pattern 2), or leave the code inline.

4. **Is the abstraction simpler than the original?** If reading the extracted function requires
   jumping back to the call site to understand the context, the extraction made the code harder to
   follow, not easier.

5. **Does it improve the caller?** The best extractions make callers cleaner. An environment record
   is valuable not because the module got shorter, but because the caller passes one record instead
   of 6 positional params. Always check both sides of the boundary.
