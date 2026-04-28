{-# LANGUAGE OverloadedStrings #-}

module Cortex.TestSupport.Database
  ( TestDB
  , createTestDB
  , runTx
  , runSession
  , insertTestUser
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Pool (Pool, UsageError, use)
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement (..))
import Hasql.Transaction (Transaction)
import Hasql.Transaction.Sessions (IsolationLevel (..), Mode (..), transaction)
import System.Environment (getEnv, lookupEnv)
import Test.HUnit.Lang (assertFailure)
import Text.Read (readMaybe)

import Platform.Database (ConnectionConfig (..), initConnectionPool)
import Platform.Database.Encode qualified as Enc

type TestDB = Pool

formatDbError :: String -> UsageError -> String
formatDbError context err =
  "Database error in " <> context <> ": " <> show err

failTest :: String -> IO a
failTest = assertFailure

runTx :: TestDB -> Transaction a -> IO a
runTx pool tx = do
  result <- use pool (transaction ReadCommitted Write tx)
  case result of
    Left err -> failTest (formatDbError "runTx" err)
    Right val -> pure val

runSession :: TestDB -> Session a -> IO a
runSession pool sess = do
  result <- use pool sess
  case result of
    Left err -> failTest (formatDbError "runSession" err)
    Right val -> pure val

createTestDB :: IO TestDB
createTestDB = do
  dbHost <- T.pack <$> getEnv "PGHOST"
  portStr <- getEnv "PGPORT"
  dbPort <- case readMaybe portStr of
    Just p -> pure p
    Nothing ->
      failTest $
        "Invalid PGPORT value: '"
          <> portStr
          <> "'. PGPORT must be a valid integer."
  dbUser <- T.pack <$> getEnv "PGUSER"
  dbDatabase <- T.pack <$> getEnv "PGDATABASE"
  dbPassword <- maybe "" T.pack <$> lookupEnv "PGPASSWORD"
  let config =
        ConnectionConfig
          { dbHost = dbHost
          , dbPort = dbPort
          , dbUser = dbUser
          , dbPassword = dbPassword
          , dbDatabase = dbDatabase
          , dbPoolSize = 8
          , dbPoolTimeout = 60
          }
  poolResult <- initConnectionPool config
  case poolResult of
    Left err ->
      failTest $
        "Failed to create test database connection pool: "
          <> err
          <> "\nCheck that PostgreSQL is running and the test database exists."
    Right pool -> pure pool

insertTestUser :: TestDB -> Text -> Text -> Text -> IO UUID
insertTestUser pool username email passwordHash =
  runSession pool . Session.statement (username, email, passwordHash) $
    Statement
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING user_id"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.text)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.text)
      )
      (D.singleRow (D.column (D.nonNullable D.uuid)))
      True
