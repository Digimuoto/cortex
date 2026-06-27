{- |
Module      : Cortex.TestSupport.Pulse
Description : Ephemeral Pulse database + ready TaskContext for downstream tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Published test harness (GitHub #331): create a disposable Postgres database,
provision the Pulse schema into it via 'Cortex.Pulse.Database.provisionPulseSchema',
and yield a ready 'TaskContext' — so a downstream consumer's test suite exercises
compiled-circuit execution without replicating Cortex's database lifecycle.

Connection comes from the standard PG* environment variables (@PGHOST@, @PGPORT@,
@PGUSER@, @PGPASSWORD@). Requires a role with @CREATEDB@: the harness connects to
the @postgres@ maintenance database to @CREATE@ and @DROP@ the disposable one.
@CREATE@/@DROP DATABASE@ cannot run inside a transaction, so they are issued
through the simple query protocol (autocommit); teardown forces the drop so a
leaked connection cannot wedge it.
-}
module Cortex.TestSupport.Pulse
  ( withEphemeralPulseDb
  )
where

import Control.Concurrent.STM (newTVarIO)
import Control.Exception (bracket, onException, throwIO)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Data.Word (Word16)
import Hasql.Pool qualified as HP
import Hasql.Session qualified as Session
import System.Environment (getEnv, lookupEnv)
import Text.Read (readMaybe)

import Cortex.Pulse.Database (ConnectionConfig (..), Pool, createPulsePool, provisionPulseSchema)
import Cortex.Pulse.Executor (TaskContext (..))
import Cortex.Pulse.Types (PulseConfig (..))

{- | Provision a disposable Pulse database and run an action against a ready
'TaskContext', dropping the database afterwards.

The action receives a 'TaskContext' whose pool points at a freshly provisioned
database and whose 'PulseConfig' is wired to it (so a managed run facade can open
its own pool from @tcConfig@ if needed). Reads PG* env; requires @CREATEDB@.
-}
withEphemeralPulseDb :: (TaskContext -> IO a) -> IO a
withEphemeralPulseDb action = do
  env <- readPgEnv
  suffix <- T.filter (/= '-') . UUID.toText <$> UUIDv4.nextRandom
  let dbName = "cortex_eph_" <> suffix
  bracket (acquire env dbName) teardown (action . resourcesContext)

-- | PG* environment connection parameters.
data PgEnv = PgEnv
  { pgHost :: Text
  , pgPort :: Word16
  , pgUser :: Text
  , pgPassword :: Text
  }

-- | Live resources for one ephemeral database.
data Resources = Resources
  { resourcesContext :: TaskContext
  , resourcesPool :: Pool
  , resourcesEnv :: PgEnv
  , resourcesDbName :: Text
  }

acquire :: PgEnv -> Text -> IO Resources
acquire env dbName = do
  createDatabase env dbName
  -- CREATE DATABASE has committed, but 'bracket' has not yet armed teardown (it
  -- only does so once 'acquire' returns). Any failure while opening the pool or
  -- provisioning the schema must therefore drop the database here, or it leaks.
  provisionInto env dbName `onException` dropDatabase env dbName

-- | CREATE the disposable database through a bracketed maintenance connection.
createDatabase :: PgEnv -> Text -> IO ()
createDatabase env dbName =
  bracket (openPool (connectionConfigFor env "postgres")) HP.release $ \maintenancePool ->
    execSql maintenancePool ("CREATE DATABASE " <> quoteIdent dbName)

{- | Open a pool on the freshly created database and provision the Pulse schema.
Releases the pool if provisioning fails (the caller drops the database); on success
the pool lives on in the returned 'Resources' for 'teardown' to release.
-}
provisionInto :: PgEnv -> Text -> IO Resources
provisionInto env dbName = do
  pool <- openPool (connectionConfigFor env dbName)
  provision pool `onException` HP.release pool
  where
    provision pool = do
      provisioned <- provisionPulseSchema pool
      case provisioned of
        Left err -> throwIO (userError ("provisionPulseSchema failed: " <> T.unpack err))
        Right () -> do
          shutdownFlag <- newTVarIO False
          let context =
                TaskContext
                  { tcPool = pool
                  , tcConfig = testkitPulseConfig env dbName
                  , tcShutdownFlag = shutdownFlag
                  }
          pure
            Resources
              { resourcesContext = context
              , resourcesPool = pool
              , resourcesEnv = env
              , resourcesDbName = dbName
              }

teardown :: Resources -> IO ()
teardown resources = do
  HP.release (resourcesPool resources)
  dropDatabase (resourcesEnv resources) (resourcesDbName resources)

dropDatabase :: PgEnv -> Text -> IO ()
dropDatabase env dbName = do
  maintenancePool <- openPool (connectionConfigFor env "postgres")
  -- Best-effort: FORCE so a leaked connection cannot wedge teardown (pg13+).
  _ <-
    HP.use
      maintenancePool
      (Session.sql (TE.encodeUtf8 ("DROP DATABASE IF EXISTS " <> quoteIdent dbName <> " WITH (FORCE)")))
  HP.release maintenancePool

readPgEnv :: IO PgEnv
readPgEnv = do
  host <- T.pack <$> getEnv "PGHOST"
  portStr <- getEnv "PGPORT"
  port <- case readMaybe portStr of
    Just p -> pure p
    Nothing -> throwIO (userError ("Invalid PGPORT (not a port number): " <> portStr))
  user <- T.pack <$> getEnv "PGUSER"
  password <- maybe "" T.pack <$> lookupEnv "PGPASSWORD"
  pure PgEnv {pgHost = host, pgPort = port, pgUser = user, pgPassword = password}

connectionConfigFor :: PgEnv -> Text -> ConnectionConfig
connectionConfigFor env database =
  ConnectionConfig
    { dbHost = pgHost env
    , dbPort = pgPort env
    , dbUser = pgUser env
    , dbPassword = pgPassword env
    , dbDatabase = database
    , dbPoolSize = 4
    , dbPoolTimeout = 60
    }

{- | A 'PulseConfig' for a testkit-provisioned ephemeral database. JWT/API/lease
fields carry inert defaults; only the connection and frontier fields matter for
a single local run.
-}
testkitPulseConfig :: PgEnv -> Text -> PulseConfig
testkitPulseConfig env database =
  PulseConfig
    { pulseDbHost = pgHost env
    , pulseDbPort = pgPort env
    , pulseDbUser = pgUser env
    , pulseDbPassword = pgPassword env
    , pulseDbName = database
    , pulseDbPoolSize = 4
    , pulseApiUrl = ""
    , pulseJwtSecret = "cortex-testkit"
    , pulseJwtExpirationSeconds = 3600 :: Int64
    , pulseJwtIssuer = "cortex-testkit"
    , pulseJwtAudience = "cortex-testkit"
    , pulseAdminApiKey = Nothing
    , pulseServiceCredential = Nothing
    , pulseHealthPort = 0
    , pulseLeaseOwner = "cortex-testkit"
    , pulseLeaseDurationSeconds = 300
    , pulsePollIntervalSeconds = 5
    , pulseMaxConcurrentTasks = 1
    , pulseMaxFrontierConcurrency = 1
    , pulseTaskTypeLimits = Map.empty
    }

openPool :: ConnectionConfig -> IO Pool
openPool config = do
  result <- createPulsePool config
  either (throwIO . userError . ("createPulsePool failed: " <>)) pure result

execSql :: Pool -> Text -> IO ()
execSql pool sqlText = do
  result <- HP.use pool (Session.sql (TE.encodeUtf8 sqlText))
  either (throwIO . userError . show) pure result

-- | Double-quote a SQL identifier (the generated db name has no quotes, but be safe).
quoteIdent :: Text -> Text
quoteIdent ident = "\"" <> T.replace "\"" "\"\"" ident <> "\""
