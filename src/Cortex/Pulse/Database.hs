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

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement (..))
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
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

{- | Provision the Pulse schema into a database. Idempotent for an already-current
schema: if @pulse@ exists, the current required shape is validated before returning
success; stale or partial schemas return 'Left' instead of failing later at runtime.
If @pulse@ is absent, the shipped @pulse-schema.sql@ data-file is applied through the
transaction simple-query protocol — a mid-script failure rolls back rather than
leaving a partial schema — and then the same shape check runs. The absent-schema
apply path takes a transaction-scoped advisory lock, so concurrent first
provisioners serialize and later callers see the completed schema instead of racing
the create-only dump; current-schema checks stay lock-free.
Schema presence is checked against @pg_catalog.pg_namespace@ rather than the
privilege-filtered @information_schema.schemata@ (a role without privileges on @pulse@
must still see it as present), and a missing or unreadable data-file is returned as
'Left' rather than thrown — the @IO (Either Text ())@ contract is total.

Pulse owns its schema (ADR 0003); this is the library surface a downstream uses to
provision its own Postgres without reaching into Cortex test SQL.
-}
provisionPulseSchema :: Pool -> IO (Either Text ())
provisionPulseSchema pool = do
  checked <- runTransaction pool provisionPulseSchemaCheckTx
  case checked of
    Left err -> pure (Left (T.pack err))
    Right PulseSchemaCurrent -> pure (Right ())
    Right (PulseSchemaStale missing) -> pure (staleSchemaError missing)
    Right PulseSchemaAbsent -> do
      scriptOrErr <- try (getDataFileName "pulse-schema.sql" >>= BS.readFile)
      case scriptOrErr of
        Left ioErr ->
          pure (Left ("reading pulse-schema.sql: " <> T.pack (show (ioErr :: IOException))))
        Right script -> do
          applied <- runTransaction pool (provisionPulseSchemaApplyTx script)
          pure $ case applied of
            Left err -> Left (T.pack err)
            Right PulseSchemaCurrent -> Right ()
            Right (PulseSchemaStale missing) -> staleSchemaError missing
            Right PulseSchemaAbsent ->
              Left "pulse schema provisioning did not create the pulse schema"

data PulseSchemaProvisionState
  = PulseSchemaCurrent
  | PulseSchemaAbsent
  | PulseSchemaStale [Text]
  deriving stock (Eq, Show)

staleSchemaError :: [Text] -> Either Text a
staleSchemaError names =
  Left
    ( "pulse schema exists but is stale or incomplete; missing: "
        <> T.intercalate ", " names
    )

provisionPulseSchemaCheckTx :: Transaction PulseSchemaProvisionState
provisionPulseSchemaCheckTx =
  pulseSchemaProvisionStateTx

provisionPulseSchemaApplyTx :: BS.ByteString -> Transaction PulseSchemaProvisionState
provisionPulseSchemaApplyTx script = do
  lockPulseSchemaProvisionTx
  exists <- pulseSchemaExistsTx
  unless exists (Tx.sql script)
  pulseSchemaProvisionStateTx

pulseSchemaProvisionStateTx :: Transaction PulseSchemaProvisionState
pulseSchemaProvisionStateTx = do
  exists <- pulseSchemaExistsTx
  if exists
    then do
      missing <- pulseSchemaMissingRequiredObjectsTx
      pure $
        case missing of
          [] -> PulseSchemaCurrent
          names -> PulseSchemaStale names
    else pure PulseSchemaAbsent

lockPulseSchemaProvisionTx :: Transaction ()
lockPulseSchemaProvisionTx = do
  _ <-
    Tx.statement pulseSchemaProvisionLockKey $
      Statement
        "WITH locked AS (SELECT pg_advisory_xact_lock($1)) SELECT 1::int4 FROM locked"
        (E.param (E.nonNullable E.int8))
        (D.singleRow (D.column (D.nonNullable D.int4)))
        False
  pure ()

pulseSchemaProvisionLockKey :: Int64
pulseSchemaProvisionLockKey = 5600060

pulseSchemaExistsTx :: Transaction Bool
pulseSchemaExistsTx = Tx.statement () pulseSchemaExistsStatement

pulseSchemaExistsStatement :: Statement () Bool
pulseSchemaExistsStatement =
  Statement
    "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'pulse')"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))
    True

pulseSchemaMissingRequiredObjectsTx :: Transaction [Text]
pulseSchemaMissingRequiredObjectsTx =
  Tx.statement () pulseSchemaMissingRequiredObjectsStatement

pulseSchemaMissingRequiredObjectsStatement :: Statement () [Text]
pulseSchemaMissingRequiredObjectsStatement =
  Statement
    pulseSchemaMissingRequiredObjectsSql
    E.noParams
    (D.rowList (D.column (D.nonNullable D.text)))
    True

pulseSchemaMissingRequiredObjectsSql :: BS.ByteString
pulseSchemaMissingRequiredObjectsSql =
  "SELECT required_name FROM ("
    <> BS.intercalate
      " UNION ALL "
      ( (tableProbe <$> pulseSchemaRequiredTables)
          <> (columnProbe <$> pulseSchemaRequiredColumns)
          <> (enumProbe <$> pulseSchemaRequiredRunStatusLabels)
      )
    <> ") missing ORDER BY required_name"

pulseSchemaRequiredTables :: [BS.ByteString]
pulseSchemaRequiredTables =
  [ "task_definitions"
  , "runs"
  , "graph_state"
  , "graph_rewrites"
  , "external_call_attempts"
  , "run_events"
  , "signals"
  ]

pulseSchemaRequiredColumns :: [(BS.ByteString, BS.ByteString)]
pulseSchemaRequiredColumns =
  [ ("task_definitions", "scheduler_claimed")
  , ("graph_rewrites", "admission_mode")
  , ("runs", "lease_owner")
  ]

pulseSchemaRequiredRunStatusLabels :: [BS.ByteString]
pulseSchemaRequiredRunStatusLabels =
  ["waiting"]

tableProbe :: BS.ByteString -> BS.ByteString
tableProbe tableName =
  "SELECT 'table pulse."
    <> tableName
    <> "'::text AS required_name WHERE NOT EXISTS ( \
       \SELECT 1 FROM pg_catalog.pg_class c \
       \JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
       \WHERE n.nspname = 'pulse' AND c.relname = '"
    <> tableName
    <> "' AND c.relkind IN ('r', 'p') \
       \)"

columnProbe :: (BS.ByteString, BS.ByteString) -> BS.ByteString
columnProbe (tableName, columnName) =
  "SELECT 'column pulse."
    <> tableName
    <> "."
    <> columnName
    <> "'::text AS required_name WHERE NOT EXISTS ( \
       \SELECT 1 FROM pg_catalog.pg_attribute a \
       \JOIN pg_catalog.pg_class c ON c.oid = a.attrelid \
       \JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
       \WHERE n.nspname = 'pulse' AND c.relname = '"
    <> tableName
    <> "' AND a.attname = '"
    <> columnName
    <> "' AND NOT a.attisdropped \
       \)"

enumProbe :: BS.ByteString -> BS.ByteString
enumProbe enumLabel =
  "SELECT 'enum pulse.run_status."
    <> enumLabel
    <> "'::text AS required_name WHERE NOT EXISTS ( \
       \SELECT 1 FROM pg_catalog.pg_type t \
       \JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace \
       \JOIN pg_catalog.pg_enum e ON e.enumtypid = t.oid \
       \WHERE n.nspname = 'pulse' AND t.typname = 'run_status' AND e.enumlabel = '"
    <> enumLabel
    <> "' \
       \)"
