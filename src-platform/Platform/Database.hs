{-# LANGUAGE OverloadedStrings #-}

-- | Database connection management
--
-- Provides connection pool configuration and management using Hasql.
module Platform.Database
  ( -- * Connection management
    ConnectionConfig (..),
    initConnectionPool,
    createPool,
    releasePool,
    withConnection,
    runTransaction,
    Session,
    Transaction,
    Pool,
  )
where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (secondsToDiffTime)
import Data.Word (Word16)
import Hasql.Connection.Setting qualified as ConnectionSetting
import Hasql.Connection.Setting.Connection qualified as Connection
import Hasql.Connection.Setting.Connection.Param qualified as Param
import Hasql.Pool (Pool, UsageError (..), acquire, release, use)
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session (Session)
import Hasql.Transaction (Transaction)
import Hasql.Transaction.Sessions (IsolationLevel (ReadCommitted), Mode (Write), transaction)

-- | Database connection configuration
-- NOTE: Does not derive Show to prevent accidental password logging in error messages
data ConnectionConfig = ConnectionConfig
  { dbHost :: Text,
    dbPort :: Word16,
    dbUser :: Text,
    -- | Never logged or displayed
    dbPassword :: Text,
    dbDatabase :: Text,
    dbPoolSize :: Int,
    dbPoolTimeout :: Int
  }

-- | Initialize connection pool
initConnectionPool :: ConnectionConfig -> IO (Either String Pool)
initConnectionPool config = do
  -- Validate configuration
  case validateConfig config of
    Just err -> pure $ Left err
    Nothing -> do
      -- Create connection settings using the new API
      let connectionSettings =
            [ ConnectionSetting.connection $
                Connection.params
                  [ Param.host (dbHost config),
                    Param.port (dbPort config),
                    Param.user (dbUser config),
                    Param.password (dbPassword config),
                    Param.dbname (dbDatabase config)
                  ]
            ]

      -- Create pool config using the new API
      let poolCfg =
            PoolConfig.settings
              [ PoolConfig.size (dbPoolSize config),
                PoolConfig.acquisitionTimeout . secondsToDiffTime . fromIntegral $
                  dbPoolTimeout config,
                PoolConfig.staticConnectionSettings connectionSettings
              ]

      -- Acquire the pool (wrap in exception handler)
      result <- try $ acquire poolCfg
      case result of
        Left (e :: SomeException) ->
          pure . Left $ "Failed to acquire connection pool: " <> show e
        Right pool ->
          pure $ Right pool

-- | Validate connection configuration
validateConfig :: ConnectionConfig -> Maybe String
validateConfig config
  | T.null (dbHost config) = Just "Database host cannot be empty"
  | dbPort config == 0 = Just "Database port must be greater than 0"
  | T.null (dbUser config) = Just "Database user cannot be empty"
  | T.null (dbDatabase config) = Just "Database name cannot be empty"
  | dbPoolSize config <= 0 = Just "Pool size must be greater than 0"
  | dbPoolTimeout config <= 0 = Just "Pool timeout must be greater than 0"
  | otherwise = Nothing

-- | Release all connections in the pool.
-- Call this when the server shuts down to avoid leaked connections.
releasePool :: Pool -> IO ()
releasePool = release

-- | Run a session with a connection from the pool
withConnection :: Pool -> Session a -> IO (Either String a)
withConnection pool session = do
  res <- use pool session
  case res of
    Right val -> pure $ Right val
    Left err -> pure . Left $ formatUsageError err

-- | Format UsageError into a human-readable error message
formatUsageError :: UsageError -> String
formatUsageError (ConnectionUsageError connErr) =
  "Connection error: " <> show connErr
formatUsageError (SessionUsageError sessionErr) =
  "Session error: " <> show sessionErr
formatUsageError AcquisitionTimeoutUsageError =
  "Connection acquisition timeout: Pool exhausted or connections taking too long to release"

-- | Alias for initConnectionPool (for convenience)
createPool :: ConnectionConfig -> IO Pool
createPool config = do
  result <- initConnectionPool config
  case result of
    Left err -> fail $ "Failed to create pool: " <> err
    Right pool -> pure pool

-- | Run a transaction with a connection from the pool
runTransaction :: Pool -> Transaction a -> IO (Either String a)
runTransaction pool tx = do
  res <- use pool (transaction ReadCommitted Write tx)
  case res of
    Right val -> pure $ Right val
    Left err -> pure . Left $ formatUsageError err
