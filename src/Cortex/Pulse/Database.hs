{- |
Module      : Cortex.Pulse.Database
Description : Pulse database execution policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pulse-owned policy wrapper around generic Platform database helpers.

The retry policy here is deliberately narrow: it retries transient pool
acquisition timeouts, not SQL errors or connection-establishment failures.
-}
module Cortex.Pulse.Database
  ( pulseDbRetryBudget
  , withConnection
  , runTransaction
  , runTransactionAt
  )
where

import Platform.Database qualified as DB

-- | Default Pulse budget for transient pool acquisition retry.
pulseDbRetryBudget :: DB.PoolRetryBudget
pulseDbRetryBudget = DB.defaultPoolRetryBudget

-- | Run a read session with Pulse's transient acquisition retry policy.
withConnection :: DB.Pool -> DB.Session a -> IO (Either String a)
withConnection =
  DB.withConnectionRetry pulseDbRetryBudget

-- | Run a write transaction with Pulse's default isolation and retry policy.
runTransaction :: DB.Pool -> DB.Transaction a -> IO (Either String a)
runTransaction =
  DB.runTransactionWithRetry pulseDbRetryBudget DB.ReadCommitted DB.Write

-- | Run a transaction with explicit isolation and Pulse's retry policy.
runTransactionAt
  :: DB.IsolationLevel
  -> DB.Mode
  -> DB.Pool
  -> DB.Transaction a
  -> IO (Either String a)
runTransactionAt =
  DB.runTransactionWithRetry pulseDbRetryBudget
