{- |
Module      : Cortex.Pulse.Executor.ExternalCall
Description : The submit/park/resume external-call protocol (ADR 0059 §3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The crash-safe state machine a bound external-call stage runs (ADR 0059 §3),
parameterised over the host-supplied driver and an abstract attempt store so it is
testable without a database or the Pulse executor. The binding helper instantiates
the store with the 'Cortex.Pulse.Query.ExternalCall' CRUD and maps the outcome onto
Pulse's @StageResult@ (suspend ↔ @StageSuspend@, complete ↔ @StageComplete@, fail ↔
a typed @StageFail@ in the ADR 0026 closure).

Two await strategies (ADR 0053 binding metadata):

* __synchronous__ — run the fused plan inline and complete;
* __submit/park/resume__ — first entry reserves the attempt, submits to the
  provider, persists the job handle, and suspends on the reserved @external-call:@
  wake; resume (the attempt already carries a handle) fetches the provider result
  and completes, re-suspends if the job is not yet terminal, or fails typed.

Reserve is idempotent on the key, so a crash that re-enters before the handle is
recorded re-submits rather than creating a duplicate task. The Pulse-side
idempotency key is distinct from the driver's own provider submit/dedup token: the
driver derives the latter from the 'ExternalCallContext' and must keep it stable
across crash re-entry (ADR 0059), so Pulse never forces its key as the provider
token.
-}
module Cortex.Pulse.Executor.ExternalCall
  ( ExternalCallDriver (..)
  , ExternalCallContext (..)
  , FetchResult (..)
  , AttemptStore (..)
  , AttemptView (..)
  , ExternalCallOutcome (..)
  , runExternalCall
  )
where

import Data.Aeson (Value)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Pulse.Query.ExternalCall (ExternalCallAttemptKey, externalCallSignalSuffix)
import Cortex.Pulse.Signal (externalCallSignalName, unSignalName)

{- | The attempt context handed to the driver at submit time. The driver derives
its own provider submit/dedup token from this; Pulse does not force its key.
-}
data ExternalCallContext = ExternalCallContext
  { ecAttemptKey :: !ExternalCallAttemptKey
  , ecFrozenPlan :: !Value
  , ecIdempotencyKey :: !Text
  -- ^ The Pulse-side dedup anchor, NOT the provider token.
  }

{- | The result of fetching a submitted provider job (ADR 0059): terminal success,
not-yet-terminal (re-suspend), or a typed terminal failure.
-}
data FetchResult
  = -- | Terminal: named measurement outputs.
    FetchCompleted ![(Text, Value)]
  | -- | The provider job is not terminal yet; the stage re-suspends.
    FetchNotReady
  | -- | Typed terminal failure (provider error, identity/integrity mismatch, …).
    FetchFailed !Text
  deriving stock (Eq, Show)

-- | Host-supplied, backend-specific operations. Opaque to Pulse (ADR 0053).
data ExternalCallDriver m = ExternalCallDriver
  { driverRunSync :: Value -> m (Either Text [(Text, Value)])
  -- ^ Run the fused plan inline (synchronous strategy) → named measurement outputs.
  , driverSubmit :: ExternalCallContext -> m (Either Text Value)
  -- ^ Submit to the provider (driver derives its own dedup token) → opaque handle.
  , driverFetch :: Value -> m FetchResult
  {- ^ Fetch/validate a provider job: ready, not-ready, or typed failure. Must be
  idempotent and not-ready-tolerant (ADR 0059).
  -}
  , driverIdempotencyKey :: Value -> Text
  -- ^ Derive the deterministic Pulse-side idempotency key from the frozen plan.
  }

-- | What the executor reads back about an in-flight attempt.
data AttemptView = AttemptView
  { avJobHandle :: !(Maybe Value)
  , avStatus :: !Text
  , avFailureReason :: !(Maybe Text)
  -- ^ The typed reason when @avStatus == "failed"@, reproduced on resume.
  }
  deriving stock (Eq, Show)

{- | The durable attempt store, abstracted so the protocol is testable. The binding
helper binds it to the 'Cortex.Pulse.Query.ExternalCall' transactions (reserve and
link committed atomically with ADR 0058 suspend settlement).
-}
data AttemptStore m = AttemptStore
  { storeLoad :: ExternalCallAttemptKey -> m (Maybe AttemptView)
  , storeReserve :: ExternalCallAttemptKey -> Text -> Value -> m ()
  , storePersistHandle :: ExternalCallAttemptKey -> Value -> Text -> m ()
  , storeSettle :: ExternalCallAttemptKey -> m ()
  , storeFail :: ExternalCallAttemptKey -> Text -> m ()
  -- ^ Mark failed and persist the typed reason for durable reproduction on resume.
  }

-- | The outcome the executor maps onto a Pulse @StageResult@.
data ExternalCallOutcome
  = -- | Completed with named measurement outputs.
    ExternalCallCompleted ![(Text, Value)]
  | -- | Suspended; the run parks on this reserved external-call wake until completion.
    ExternalCallSuspended !Text
  | -- | Failed with a typed reason (routed through the ADR 0026 closure).
    ExternalCallFailed !Text
  deriving stock (Eq, Show)

{- | Run the external-call protocol for one stage entry. The same action runs on
first entry and on resume; it distinguishes them by the durable attempt state.
-}
runExternalCall
  :: Monad m
  => AwaitStrategy
  -> ExternalCallDriver m
  -> AttemptStore m
  -> ExternalCallAttemptKey
  -> Value
  -- ^ frozen fused plan
  -> m ExternalCallOutcome
runExternalCall Synchronous driver _ _ frozenPlan = do
  result <- driverRunSync driver frozenPlan
  pure (either ExternalCallFailed ExternalCallCompleted result)
runExternalCall SubmitParkResume driver store key frozenPlan = do
  existing <- storeLoad store key
  case existing of
    Just view
      -- A terminal failure is reproduced from the stored reason, never re-fetched,
      -- so a crash between storeFail and the node-failure graph write keeps the
      -- typed reason (ADR 0059 failure durability).
      | avStatus view == "failed" ->
          pure (ExternalCallFailed (fromMaybe "external call failed" (avFailureReason view)))
      -- A recorded handle (submitted/settled) means resume: fetch idempotently.
      | Just handle <- avJobHandle view -> resume handle
    -- No attempt, or reserved-without-handle: (re-)submit with the same key.
    _ -> firstEntry
  where
    signalName = unSignalName (externalCallSignalName (externalCallSignalSuffix key))

    resume handle = do
      fetched <- driverFetch driver handle
      case fetched of
        FetchCompleted outputs -> do
          storeSettle store key
          pure (ExternalCallCompleted outputs)
        FetchNotReady ->
          -- Re-park on the same wake; do not settle or fail. The attempt stays
          -- submitted with its handle, so the next wake re-fetches.
          pure (ExternalCallSuspended signalName)
        FetchFailed reason -> do
          storeFail store key reason
          pure (ExternalCallFailed reason)

    firstEntry = do
      let idempotencyKey = driverIdempotencyKey driver frozenPlan
      storeReserve store key idempotencyKey frozenPlan
      let ctx =
            ExternalCallContext
              { ecAttemptKey = key
              , ecFrozenPlan = frozenPlan
              , ecIdempotencyKey = idempotencyKey
              }
      submitted <- driverSubmit driver ctx
      case submitted of
        Right handle -> do
          storePersistHandle store key handle signalName
          pure (ExternalCallSuspended signalName)
        Left reason -> do
          storeFail store key reason
          pure (ExternalCallFailed reason)
