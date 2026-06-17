{- |
Module      : Cortex.Pulse.Executor.ExternalCallAttemptSpec
Description : DB tests for the ADR 0059 external-call attempt record CRUD.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Reserve → persist-handle → settle lifecycle, and the crash-safety property that
reserve is idempotent on the key (a recovery re-entry never overwrites the
authoritative first reservation). Self-skips when PGHOST is unset.
-}
module Cortex.Pulse.Executor.ExternalCallAttemptSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import System.Environment (lookupEnv)
import Test.Hspec

import Cortex.Pulse.Query.ExternalCall
import Cortex.TestSupport.Database (TestDB, createTestDB, runTx)

setupTestDb :: IO (Maybe TestDB)
setupTestDb = do
  mHost <- lookupEnv "PGHOST"
  case mHost of
    Nothing -> pure Nothing
    Just _ -> do
      result <- try createTestDB :: IO (Either SomeException TestDB)
      either (\e -> error ("PGHOST set but DB setup failed: " <> show e)) (pure . Just) result

withDb :: Maybe TestDB -> (TestDB -> IO ()) -> IO ()
withDb Nothing _ = pendingWith "PGHOST not set - database not available"
withDb (Just db) action = action db

mkKey :: Text -> ExternalCallAttemptKey
mkKey frontier =
  ExternalCallAttemptKey
    { ecaRunId = UUID.nil
    , ecaNodeId = "realize"
    , ecaRuntimeBindingId = "braket-pack/quantum.realize"
    , ecaFrontierId = frontier
    }

plan :: Aeson.Value
plan = Aeson.object ["operations" Aeson..= ([Aeson.object ["gate" Aeson..= ("cnot" :: Text)]])]

spec :: Spec
spec = beforeAll setupTestDb . describe "external-call attempt CRUD" $ do
  it "reserve then load yields a reserved attempt with the frozen plan" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    let key = mkKey "f-reserve"
    runTx db (reserveExternalCallAttempt key "idem-1" plan now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "reserved"
    fmap ecaIdempotencyKey loaded `shouldBe` Just "idem-1"
    fmap ecaFrozenPlan loaded `shouldBe` Just plan
    (ecaJobHandle =<< loaded) `shouldBe` Nothing

  it "reserve is idempotent on the key (recovery re-entry does not overwrite)" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    let key = mkKey "f-idem"
    runTx db (reserveExternalCallAttempt key "idem-first" plan now)
    runTx db (reserveExternalCallAttempt key "idem-second" (Aeson.object ["x" Aeson..= (1 :: Int)]) now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaIdempotencyKey loaded `shouldBe` Just "idem-first"
    fmap ecaFrozenPlan loaded `shouldBe` Just plan

  it "persist handle marks the attempt submitted with the job handle and signal" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    let key = mkKey "f-submit"
        handle = Aeson.object ["jobArn" Aeson..= ("arn:aws:braket:job/abc" :: Text)]
    runTx db (reserveExternalCallAttempt key "idem-s" plan now)
    runTx db (persistExternalCallHandle key handle "ext:job-abc" now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "submitted"
    (ecaJobHandle =<< loaded) `shouldBe` Just handle
    (ecaSignalName =<< loaded) `shouldBe` Just "ext:job-abc"

  it "settle marks the attempt settled" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    let key = mkKey "f-settle"
    runTx db (reserveExternalCallAttempt key "idem-x" plan now)
    runTx db (settleExternalCallAttempt key now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "settled"

  it "load of an absent key is Nothing" $ \mdb -> withDb mdb $ \db -> do
    loaded <- runTx db (loadExternalCallAttempt (mkKey "f-absent"))
    loaded `shouldBe` Nothing
