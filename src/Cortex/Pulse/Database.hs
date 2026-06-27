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
  ( -- * Pool construction (Pulse-owned surface)
    Pool
  , ConnectionConfig (..)
  , createPulsePool

    -- * Execution policy
  , pulseDbRetryBudget
  , withConnection
  , runTransaction
  , runTransactionAt

    -- * Schema provisioning (Pulse-owned, ADR 0003)
  , provisionPulseSchema
  )
where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement (..))
import Paths_cortex (getDataFileName)

import Platform.Database (ConnectionConfig (..), Pool)
import Platform.Database qualified as DB

{- | Construct a Pulse database pool. Re-exported (with 'Pool' and
'ConnectionConfig') so a downstream durable runner or provider-completion watcher
constructs and uses a pool through @Cortex.Pulse.Database@ without importing
@Platform.Database@ directly.
-}
createPulsePool :: ConnectionConfig -> IO (Either String Pool)
createPulsePool = DB.createPool

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

{- | Provision the Pulse schema into a database. Idempotent: if the @pulse@
schema already exists this is a no-op (so applying twice never errors); otherwise
the shipped @pulse-schema.sql@ data-file is applied through the simple query
protocol.

Pulse owns its schema (ADR 0003); this is the library surface a downstream uses
to provision its own Postgres without reaching into Cortex test SQL.
-}
provisionPulseSchema :: Pool -> IO (Either Text ())
provisionPulseSchema pool = do
  existing <- withConnection pool pulseSchemaExistsSession
  case existing of
    Left err -> pure (Left (T.pack err))
    Right True -> pure (Right ())
    Right False -> do
      schemaPath <- getDataFileName "pulse-schema.sql"
      script <- BS.readFile schemaPath
      result <- withConnection pool (Session.sql script)
      pure (either (Left . T.pack) Right result)

pulseSchemaExistsSession :: Session Bool
pulseSchemaExistsSession = Session.statement () pulseSchemaExistsStatement
  where
    pulseSchemaExistsStatement :: Statement () Bool
    pulseSchemaExistsStatement =
      Statement
        "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'pulse')"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))
        True
