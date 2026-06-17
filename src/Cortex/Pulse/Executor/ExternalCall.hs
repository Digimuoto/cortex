{- |
Module      : Cortex.Pulse.Executor.ExternalCall
Description : The submit/park/resume external-call protocol (ADR 0059 §3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The crash-safe state machine a bound external-call stage runs (ADR 0059 §3),
parameterised over the host-supplied driver and an abstract attempt store so it is
testable without a database or the Pulse executor. P6 instantiates the store with
the 'Cortex.Pulse.Query.ExternalCall' CRUD and maps the outcome onto Pulse's
@StageResult@ (suspend ↔ @StageSuspend@, complete ↔ @StageComplete@, fail ↔ the
ADR 0026 failure closure).

Two await strategies (ADR 0053 binding metadata):

* __synchronous__ — run the fused plan inline and complete;
* __submit/park/resume__ — first entry reserves the attempt, submits to the
  provider under an idempotency key, persists the job handle, and suspends; resume
  (the attempt already carries a handle) fetches the provider result and completes.

Reserve is idempotent on the key, so a crash that re-enters before the handle is
recorded re-submits with the same key rather than creating a duplicate task.
-}
module Cortex.Pulse.Executor.ExternalCall
  ( ExternalCallDriver (..)
  , AttemptStore (..)
  , AttemptView (..)
  , ExternalCallOutcome (..)
  , runExternalCall
  )
where

import Data.Aeson (Value)
import Data.Text (Text)

import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Pulse.Query.ExternalCall (ExternalCallAttemptKey)

-- | Host-supplied, backend-specific operations. Opaque to Pulse (ADR 0053).
data ExternalCallDriver m = ExternalCallDriver
  { driverRunSync :: Value -> m (Either Text [(Text, Value)])
  -- ^ Run the fused plan inline (synchronous strategy) → named measurement outputs.
  , driverSubmit :: Text -> Value -> m (Either Text Value)
  -- ^ Submit under an idempotency key (arg 1) → an opaque provider job handle.
  , driverFetch :: Value -> m (Either Text [(Text, Value)])
  -- ^ Fetch/validate a completed provider job → named measurement outputs.
  , driverIdempotencyKey :: Value -> Text
  -- ^ Derive a deterministic idempotency key from the frozen plan.
  , driverSignalName :: ExternalCallAttemptKey -> Text
  -- ^ The ordinary durable signal woken on completion (never the run-terminal family).
  }

-- | What the executor reads back about an in-flight attempt.
data AttemptView = AttemptView
  { avJobHandle :: !(Maybe Value)
  , avStatus :: !Text
  }
  deriving stock (Eq, Show)

{- | The durable attempt store, abstracted so the protocol is testable. P6 binds it
to the 'Cortex.Pulse.Query.ExternalCall' transactions (reserve and link committed
atomically with ADR 0058 suspend settlement).
-}
data AttemptStore m = AttemptStore
  { storeLoad :: ExternalCallAttemptKey -> m (Maybe AttemptView)
  , storeReserve :: ExternalCallAttemptKey -> Text -> Value -> m ()
  , storePersistHandle :: ExternalCallAttemptKey -> Value -> Text -> m ()
  , storeSettle :: ExternalCallAttemptKey -> m ()
  , storeFail :: ExternalCallAttemptKey -> m ()
  }

-- | The outcome the executor maps onto a Pulse @StageResult@.
data ExternalCallOutcome
  = -- | Completed with named measurement outputs.
    ExternalCallCompleted ![(Text, Value)]
  | -- | Suspended; the run parks on this durable signal until the job completes.
    ExternalCallSuspended !Text
  | -- | Failed with a typed reason (routed through the ADR 0026 closure in P6).
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
    Just view | Just handle <- avJobHandle view -> resume handle
    _ -> firstEntry
  where
    resume handle = do
      fetched <- driverFetch driver handle
      case fetched of
        Right outputs -> do
          storeSettle store key
          pure (ExternalCallCompleted outputs)
        Left reason -> do
          storeFail store key
          pure (ExternalCallFailed reason)

    firstEntry = do
      let idempotencyKey = driverIdempotencyKey driver frozenPlan
      storeReserve store key idempotencyKey frozenPlan
      submitted <- driverSubmit driver idempotencyKey frozenPlan
      case submitted of
        Right handle -> do
          let signalName = driverSignalName driver key
          storePersistHandle store key handle signalName
          pure (ExternalCallSuspended signalName)
        Left reason -> do
          storeFail store key
          pure (ExternalCallFailed reason)
