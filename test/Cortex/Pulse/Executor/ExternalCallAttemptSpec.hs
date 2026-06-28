{- |
Module      : Cortex.Pulse.Executor.ExternalCallAttemptSpec
Description : DB tests for the ADR 0059 external-call attempt record + wake CRUD.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Reserve → persist-handle → settle/fail lifecycle (reserve idempotent on key; fail
records the typed reason); the submitted-attempts watcher list; and the trusted
external-call wake: an upsert-insert when the wake precedes the wait, idempotent
re-delivery, and consume-all on re-arm. Each test seeds a real run so the attempt's
@run_id@ foreign key is satisfied. Self-skips when PGHOST is unset.
-}
module Cortex.Pulse.Executor.ExternalCallAttemptSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import System.Environment (lookupEnv)
import Test.Hspec

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Query.ExternalCall
import Cortex.Pulse.Signal (externalCallSignalName, unSignalName)
import Cortex.TestSupport.Database (TestDB, createTestDB, runTx)

import Platform.DurableTask.Types (TriggerSource (..))

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

-- | Seed a task + run so an attempt's run_id foreign key resolves; returns the run id.
seedRun :: TestDB -> Text -> IO UUID
seedRun db name = do
  now <- getCurrentTime
  taskId <- runTx db (Q.claimTestTaskDef "paper_portfolio_cycle" name now)
  mRunId <- runTx db (Q.claimAndCreateRun taskId "test-owner" TriggerManual now 300)
  maybe (fail "seedRun: claimAndCreateRun returned Nothing") pure mRunId

mkKey :: UUID -> Text -> ExternalCallAttemptKey
mkKey runId frontier =
  ExternalCallAttemptKey
    { ecaRunId = runId
    , ecaNodeId = "realize"
    , ecaRuntimeBindingId = "braket-pack/quantum.realize"
    , ecaFrontierId = frontier
    }

payload :: Aeson.Value
payload = Aeson.object ["steps" Aeson..= [Aeson.object ["name" Aeson..= ("call" :: Text)]]]

spec :: Spec
spec = beforeAll setupTestDb . describe "external-call attempt CRUD + wake" $ do
  it "reserve then load yields a reserved attempt with the frozen payload" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-reserve"
    let key = mkKey runId "f-reserve"
    runTx db (reserveExternalCallAttempt key "idem-1" payload now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "reserved"
    fmap ecaIdempotencyKey loaded `shouldBe` Just "idem-1"
    fmap ecaFrozenPayload loaded `shouldBe` Just payload
    (ecaJobHandle =<< loaded) `shouldBe` Nothing
    (ecaFailureReason =<< loaded) `shouldBe` Nothing

  it "reserve is idempotent on the key (recovery re-entry does not overwrite)" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-idem"
    let key = mkKey runId "f-idem"
    runTx db (reserveExternalCallAttempt key "idem-first" payload now)
    runTx db (reserveExternalCallAttempt key "idem-second" (Aeson.object ["x" Aeson..= (1 :: Int)]) now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaIdempotencyKey loaded `shouldBe` Just "idem-first"
    fmap ecaFrozenPayload loaded `shouldBe` Just payload

  it "persist handle marks the attempt submitted with the job handle and signal" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-submit"
    let key = mkKey runId "f-submit"
        handle = Aeson.object ["jobArn" Aeson..= ("arn:aws:braket:job/abc" :: Text)]
    runTx db (reserveExternalCallAttempt key "idem-s" payload now)
    runTx db (persistExternalCallHandle key handle "external-call:job-abc" now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "submitted"
    (ecaJobHandle =<< loaded) `shouldBe` Just handle
    (ecaSignalName =<< loaded) `shouldBe` Just "external-call:job-abc"

  it "settle marks the attempt settled" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-settle"
    let key = mkKey runId "f-settle"
    runTx db (reserveExternalCallAttempt key "idem-x" payload now)
    runTx db (settleExternalCallAttempt key now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "settled"

  it "fail marks the attempt failed and records the typed reason" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-fail"
    let key = mkKey runId "f-fail"
    runTx db (reserveExternalCallAttempt key "idem-f" payload now)
    runTx db (failExternalCallAttempt key "device rejected" now)
    loaded <- runTx db (loadExternalCallAttempt key)
    fmap ecaStatus loaded `shouldBe` Just "failed"
    (ecaFailureReason =<< loaded) `shouldBe` Just "device rejected"

  it "lists only submitted attempts (for a DB-wide completion watcher)" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-list"
    let submittedKey = mkKey runId "f-list-submitted"
        reservedKey = mkKey runId "f-list-reserved"
    runTx db (reserveExternalCallAttempt submittedKey "i1" payload now)
    runTx db (persistExternalCallHandle submittedKey (Aeson.String "job1") "external-call:1" now)
    runTx db (reserveExternalCallAttempt reservedKey "i2" payload now)
    listed <- runTx db (listSubmittedExternalCallAttempts 100)
    let frontiersForRun = [ecaFrontierId (ecaKey a) | a <- listed, ecaRunId (ecaKey a) == runId]
    frontiersForRun `shouldBe` ["f-list-submitted"]

  it "trusted external-call delivery upserts a delivered wake; consume-all marks it consumed" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-wake"
    let key = mkKey runId "f-wake"
        sigText = unSignalName (externalCallSignalName (externalCallSignalSuffix key))
    runTx db (reserveExternalCallAttempt key "idem-wake" payload now)
    -- Delivery after attempt reservation but before any pending wait inserts a
    -- node-scoped delivered row for suspend settlement to observe.
    delivered <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "wake") now)
    delivered `shouldBe` True
    status1 <- runTx db (Q.lookupSignalStatus runId sigText)
    status1 `shouldBe` Just "delivered"
    -- Re-delivery is idempotent: a delivered row already exists, so no new row.
    redelivered <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "wake-2") now)
    redelivered `shouldBe` False
    -- Consume (on re-arm) flips the delivered row to consumed so it is not re-observed.
    runTx
      db
      ( Q.consumeDeliveredSignal
          runId
          (externalCallSignalName (externalCallSignalSuffix key))
          (NodeId (ecaNodeId key))
          now
      )
    status2 <- runTx db (Q.lookupSignalStatus runId sigText)
    status2 `shouldBe` Just "consumed"

  it "trusted external-call delivery is a no-op without a durable attempt" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-missing-wake"
    let key = mkKey runId "f-missing-wake"
        sigText = unSignalName (externalCallSignalName (externalCallSignalSuffix key))
    delivered <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "wake") now)
    delivered `shouldBe` False
    runTx db (Q.lookupSignalStatus runId sigText) `shouldReturn` Nothing

  it "a fresh wake after a prior wake was consumed is not suppressed (re-suspend backstop)" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-resuspend"
    let key = mkKey runId "f-resuspend"
        sig = externalCallSignalName (externalCallSignalSuffix key)
        sigText = unSignalName sig
    runTx db (reserveExternalCallAttempt key "idem-resuspend" payload now)
    -- Round 1: deliver, then consume (as a re-arm would). The signal name is reused
    -- across re-suspend rounds, so a leftover 'consumed' row must NOT suppress the next wake.
    _ <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "wake-1") now)
    runTx db (Q.consumeDeliveredSignal runId sig (NodeId (ecaNodeId key)) now)
    runTx db (Q.lookupSignalStatus runId sigText) `shouldReturn` Just "consumed"
    -- Round 2: a fresh completion must still deliver, not be dropped by the consumed row.
    redelivered <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "wake-2") now)
    redelivered `shouldBe` True
    runTx db (Q.lookupSignalStatus runId sigText) `shouldReturn` Just "delivered"

  it "delivery to a settled attempt is a no-op (terminality gate)" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-terminal"
    let key = mkKey runId "f-terminal"
        sigText = unSignalName (externalCallSignalName (externalCallSignalSuffix key))
    runTx db (reserveExternalCallAttempt key "idem-t" payload now)
    runTx db (settleExternalCallAttempt key now)
    -- A late/duplicate completion for an already-settled attempt must not re-arm it.
    delivered <- runTx db (Q.deliverExternalCallSignal key (Aeson.String "late") now)
    delivered `shouldBe` False
    runTx db (Q.lookupSignalStatus runId sigText) `shouldReturn` Nothing

  it "ordinary deliverSignal cannot forge the reserved external-call namespace" $ \mdb -> withDb mdb $ \db -> do
    now <- getCurrentTime
    runId <- seedRun db "ec-forge"
    let key = mkKey runId "f-forge"
        sigText = unSignalName (externalCallSignalName (externalCallSignalSuffix key))
    forged <- runTx db (Q.deliverSignal runId sigText (Aeson.String "forged") now)
    forged `shouldBe` False
    status <- runTx db (Q.lookupSignalStatus runId sigText)
    status `shouldBe` Nothing

  it "load of an absent key is Nothing" $ \mdb -> withDb mdb $ \db -> do
    runId <- seedRun db "ec-absent"
    loaded <- runTx db (loadExternalCallAttempt (mkKey runId "f-absent"))
    loaded `shouldBe` Nothing
