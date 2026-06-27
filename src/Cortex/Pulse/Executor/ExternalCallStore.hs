{- |
Module      : Cortex.Pulse.Executor.ExternalCallStore
Description : DB-backed 'AttemptStore' over the external-call attempt CRUD (ADR 0059).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Binds the abstract 'AttemptStore' the submit/park/resume protocol runs against
('Cortex.Pulse.Executor.ExternalCall') to the durable
'Cortex.Pulse.Query.ExternalCall' transactions. Each operation runs in its own
Pulse transaction; a database error becomes a thrown 'AttemptStoreError' so the
executor's failure path closes it like any other stage exception (no silent ignored
transaction result).
-}
module Cortex.Pulse.Executor.ExternalCallStore
  ( pulseAttemptStore
  , AttemptStoreError (..)
  )
where

import Control.Exception (Exception, throwIO)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.Executor.ExternalCall (AttemptStore (..), AttemptView (..))
import Cortex.Pulse.Query.ExternalCall
  ( ExternalCallAttempt (..)
  , failExternalCallAttempt
  , loadExternalCallAttempt
  , persistExternalCallHandle
  , reserveExternalCallAttempt
  , settleExternalCallAttempt
  )

import Platform.Database qualified as DB

-- | A Pulse database error surfaced from an attempt-store operation.
newtype AttemptStoreError = AttemptStoreError Text
  deriving stock (Show)

instance Exception AttemptStoreError

-- | A DB-backed 'AttemptStore' over the Pulse external-call CRUD, for a given pool.
pulseAttemptStore :: DB.Pool -> AttemptStore IO
pulseAttemptStore pool =
  AttemptStore
    { storeLoad = \key -> do
        attempt <- runOrThrow (loadExternalCallAttempt key)
        pure (toView <$> attempt)
    , storeReserve = \key idempotencyKey frozenPlan -> do
        now <- getCurrentTime
        runOrThrow (reserveExternalCallAttempt key idempotencyKey frozenPlan now)
    , storePersistHandle = \key jobHandle signalName -> do
        now <- getCurrentTime
        runOrThrow (persistExternalCallHandle key jobHandle signalName now)
    , storeSettle = \key -> do
        now <- getCurrentTime
        runOrThrow (settleExternalCallAttempt key now)
    , storeFail = \key reason -> do
        now <- getCurrentTime
        runOrThrow (failExternalCallAttempt key reason now)
    }
  where
    runOrThrow :: DB.Transaction a -> IO a
    runOrThrow tx =
      PulseDB.runTransaction pool tx
        >>= either (throwIO . AttemptStoreError . T.pack) pure

    toView attempt =
      AttemptView
        { avJobHandle = ecaJobHandle attempt
        , avStatus = ecaStatus attempt
        , avFailureReason = ecaFailureReason attempt
        }
