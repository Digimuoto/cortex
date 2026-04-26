# Testing Patterns

Property-based testing, golden tests, mock patterns, and algebraic law
verification for production Haskell.

## Algebraic laws for domain types

When defining a domain type with operations, state the algebraic laws it
must satisfy as comments or QuickCheck properties. Laws make the type's
contract explicit and catch regressions that unit tests miss.

### Examples of laws in Cortex

```haskell
-- ScheduleDecision composition is idempotent:
-- applying the same decision twice = applying once
prop_idempotent :: ScheduleConfig -> ExecutionOrigin -> ScheduleKind
                -> UTCTime -> RunOutcome -> Property
prop_idempotent cfg origin kind now outcome =
  let decision = decideScheduleAction cfg origin kind now outcome
  in applyDecision decision . applyDecision decision === applyDecision decision

-- Indicator degrade is monotonic:
-- if a <= b then degrade a <= degrade b
prop_degrade_monotonic :: Exact -> Exact -> Property
prop_degrade_monotonic a b =
  a <= b ==> degrade a <= degrade b

-- Signal evaluation is deterministic:
-- same inputs -> same output
prop_signal_deterministic :: SignalConfig -> [Exact] -> Property
prop_signal_deterministic cfg prices =
  evaluateSignal cfg prices === evaluateSignal cfg prices
```

### When defining a new type

For `computeIndicator` extensions and similar domain functions, require:
1. State the algebraic properties of the output
2. Write at least one property test per stated law
3. Document any intentional violations (e.g., floating-point approximation)

**[P2] Flag**: A domain type with operations but no stated algebraic
properties. This is not about coverage — it's about making the contract
explicit.

## Property-based testing for pure decision functions

Every pure decision function (layer 1 in the three-layer-cake) should
have property tests, not just example-based unit tests. Properties catch
edge cases that hand-picked examples miss.

### Pattern: identify the contract as properties

```haskell
-- Function: decideScheduleAction
-- Property: completed runs always produce Advance or Idle, never Retry
prop_completed_no_retry :: ScheduleConfig -> UTCTime -> Property
prop_completed_no_retry cfg now =
  forAll arbitrary $ \(origin, kind) ->
    let decision = decideScheduleAction cfg origin kind now OutcomeCompleted
    in decision /= RetryAfter  -- strengthened: completed never retries

-- Function: evaluateSignal (RSI)
-- Property: output is always in [0, 100]
prop_rsi_bounded :: NonEmptyList Exact -> Property
prop_rsi_bounded (NonEmpty prices) =
  let result = computeRSI 14 prices
  in counterexample ("RSI = " <> show result) $
       result >= 0 .&&. result <= 100

-- Function: degrade
-- Property: result is finite for all finite Scientific inputs
prop_degrade_finite :: Exact -> Property
prop_degrade_finite x =
  not (isNaN (unLossy (degrade x)))
    .&&. not (isInfinite (unLossy (degrade x)))
```

### When to require properties

- Pure function with >3 branches → property tests
- Decision function that drives system behavior → property tests
- Numeric function → bounded output property + edge case properties
- Parser → roundtrip property (see below)

**[P2] Flag**: A pure function with >3 branches and zero property tests.

## Golden test pattern for serialization boundaries

Any type that crosses a serialization boundary should have golden tests:
a known input, a known expected output, stored as files. Changes that
alter serialization break the golden test, forcing explicit acknowledgment.

### What needs golden tests

| Boundary | Test shape |
|---|---|
| `ToJSON`/`FromJSON` on public API types | JSON file → decode → re-encode → compare |
| Hasql encoder/decoder pairs | Known row → decode → compare to expected record |
| Report IR → markdown compilation | Known IR → compile → compare to expected markdown |
| Flex Query XML parsing | Known XML → parse → compare to expected domain type |

### Pattern

```haskell
-- Golden file: test/golden/portfolio-response-v1.json
-- Contains: the exact JSON shape the API serves

spec :: Spec
spec = describe "PortfolioResponse serialization" $ do
  it "matches golden file" $ do
    golden <- BSL.readFile "test/golden/portfolio-response-v1.json"
    let decoded = Aeson.decode golden :: Maybe PortfolioResponse
    decoded `shouldSatisfy` isJust
    Aeson.encode (fromJust decoded) `shouldBe` golden
```

### Updating golden files

When a serialization change is intentional:
1. Update the golden file
2. Add a comment in the PR explaining why the format changed
3. If the API is versioned, add a new golden file for the new version

**[P2] Flag**: A public API type with `ToJSON`/`FromJSON` instances but
no golden test.

## Mock record pattern for IO testing

For any module that takes an environment record, define a `mockEnv` in
test support that replaces IO actions with pure stubs or IORef-based
recorders.

### Pattern

```haskell
-- Production code uses the environment record:
data StageEnv = StageEnv
  { sePool :: DB.Pool
  , seRunQuery :: forall a. Query a -> IO a
  , seLogEvent :: Event -> IO ()
  , seShutdownFlag :: TVar Bool
  }

-- Test code provides a mock:
mockStageEnv :: IO StageEnv
mockStageEnv = do
  logRef <- newIORef []
  shutdownFlag <- newTVarIO False
  pure StageEnv
    { sePool = error "mock: sePool not expected in this test"
    , seRunQuery = \_ -> pure mockQueryResult
    , seLogEvent = \e -> modifyIORef logRef (e :)
    , seShutdownFlag = shutdownFlag
    }
```

### Testing with mocks

```haskell
spec :: Spec
spec = describe "attemptStage" $ do
  it "logs the stage name on entry" $ do
    env <- mockStageEnv
    _ <- attemptStage env testStageDef testState
    logged <- readIORef (seLogRef env)
    logged `shouldSatisfy` any (\e -> "stage_started" `T.isInfixOf` eventOp e)
```

### When to apply

- Module takes an environment record (Pattern 2 from refactoring-patterns)
- The environment contains IO actions (DB, HTTP, logging)
- You want to test business logic without infrastructure

**[P2] Flag**: A module that's described as "hard to test" because it
calls concrete IO functions directly instead of going through an env record.
This is not a testing problem — it's a design problem.

## Decoder/encoder roundtrip testing

Every Hasql encode/decode pair should have a roundtrip property test:

```haskell
prop_roundtrip :: PulseRunAdminView -> Property
prop_roundtrip view =
  decode (encode view) === Right view
```

### What this catches

- Column reordering bugs (SQL column order doesn't match decoder order)
- NULL handling mismatches (encoder sends NULL, decoder expects non-NULL)
- Enum casting issues (Text vs Postgres enum)
- Silent truncation (Int64 value written, Int32 read)

### Practical approach

For raw Hasql statements where you can't easily unit-test the roundtrip
in-memory, use integration tests:

```haskell
spec :: Spec
spec = describe "PulseRunAdminView roundtrip" $ do
  it "write then read produces the same view" $ \pool -> do
    let original = testPulseRunAdminView
    runSession pool $ insertTestRun original
    result <- runSession pool $ getRunAdminView original.pravRunId
    result `shouldBe` Just original
```

**Why this matters especially for raw Hasql**: The compiler can't verify
that the SQL column order matches the decoder's `<*>` chain. A column
reorder in the SQL that isn't mirrored in the decoder silently maps
wrong values to wrong fields.

**[P2] Flag**: A raw Hasql decoder with 10+ columns and no roundtrip test.

## ADT completeness checklist for new constructors

When adding a constructor to an owned ADT, the PR must update all of these:

| Area | Check |
|---|---|
| Pattern matches | Compiler enforces if no wildcards (which the style guide requires) |
| `ToJSON`/`FromJSON` | New constructor serializes correctly |
| DB serialization | If the ADT maps to a Postgres enum, add the new value |
| Documentation | Supported values lists, tool schemas, API docs |
| Tests | Add to any `Arbitrary` instances and golden tests |
| `Bounded`/`Enum` | If derived, verify the new constructor is in the right position |

**[P1] Flag**: A PR that adds an ADT constructor but doesn't update the
`ToJSON`/`FromJSON` instance or `Arbitrary` instance.
