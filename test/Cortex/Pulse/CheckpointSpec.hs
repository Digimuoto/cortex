{- |
Module      : Cortex.Pulse.CheckpointSpec
Description : Pulse checkpoint compatibility tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Tests for Pulse's checkpoint validation adapter over Platform's generic
checkpoint envelope.
-}
module Cortex.Pulse.CheckpointSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, unless)
import Data.Aeson qualified as Aeson
import Data.Functor (($>))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Hasql.Pool (Pool)
import System.Environment (lookupEnv)
import Test.Hspec

import Cortex.Pulse.Checkpoint
  ( CheckpointReadExpectation (..)
  , CheckpointReadResult (..)
  , PulseCheckpointValidationFailure (..)
  , StoredCheckpointPayload (..)
  , checkpointValidationFailureErrorType
  , checkpointValidationFailureRetryable
  , validateStoredCheckpointPayload
  )
import Cortex.Pulse.Query qualified as Q
import Cortex.TestSupport.Database (createTestDB, runSession, runTx)

import Platform.DurableTask.Checkpoint
  ( CheckpointCompatibilityFailure (..)
  , buildCheckpointEnvelope
  )
import Platform.DurableTask.Types (TriggerSource (..))

spec :: Spec
spec = do
  describe "validateStoredCheckpointPayload" $ do
    it "accepts a matching checkpoint envelope and returns the payload" $ do
      validateStoredCheckpointPayload
        expectation
        (storedCheckpoint "test_alpha" (validEnvelope "test_alpha"))
        `shouldBe` Right checkpointPayload

    it "classifies malformed legacy payloads as checkpoint corruption" $ do
      case validateStoredCheckpointPayload
        expectation
        (storedCheckpoint "test_alpha" (Aeson.object ["legacy" Aeson..= True])) of
        Left (CheckpointPayloadCorrupt err) -> err `shouldSatisfy` (not . T.null)
        other -> expectationFailure ("expected checkpoint corruption, got " <> show other)

    it "maps row and envelope mismatches to upstream compatibility failures" $ do
      let cases =
            [
              ( "row task type"
              , StoredCheckpointPayload "other_task" "test_alpha" (validEnvelope "test_alpha")
              , CheckpointTaskTypeMismatch taskType "other_task"
              )
            ,
              ( "task version"
              , storedCheckpoint "test_alpha" (checkpointEnvelope taskType 2 runtimeVersion "test_alpha")
              , CheckpointTaskVersionMismatch taskVersion 2
              )
            ,
              ( "runtime version"
              , storedCheckpoint "test_alpha" (checkpointEnvelope taskType taskVersion 99 "test_alpha")
              , CheckpointRuntimeVersionMismatch runtimeVersion 99
              )
            ,
              ( "stored checkpoint name"
              , storedCheckpoint "test_beta" (checkpointEnvelope taskType taskVersion runtimeVersion "test_beta")
              , CheckpointNameMismatch "test_alpha" "test_beta"
              )
            ,
              ( "embedded checkpoint name"
              , storedCheckpoint "test_alpha" (checkpointEnvelope taskType taskVersion runtimeVersion "test_beta")
              , CheckpointNameMismatch "test_alpha" "test_beta"
              )
            ,
              ( "format version"
              , storedCheckpoint "test_alpha" (rawEnvelope 2 taskType taskVersion runtimeVersion "test_alpha")
              , UnsupportedCheckpointEnvelopeVersion 2
              )
            ]
      forM_ cases $ \(label, stored, expectedFailure) ->
        let expected = Left (CheckpointPayloadIncompatible expectedFailure)
            actual = validateStoredCheckpointPayload expectation stored
         in unless
              (actual == expected)
              (expectationFailure (label <> ": expected " <> show expected <> ", got " <> show actual))

    it "maps validation failures to Pulse error types and retryability" $ do
      checkpointValidationFailureErrorType (CheckpointPayloadCorrupt "bad")
        `shouldBe` "checkpoint_corruption"
      checkpointValidationFailureRetryable (CheckpointPayloadCorrupt "bad")
        `shouldBe` False
      checkpointValidationFailureErrorType
        (CheckpointPayloadIncompatible (CheckpointRuntimeVersionMismatch 1 2))
        `shouldBe` "checkpoint_runtime_version_mismatch"
      checkpointValidationFailureRetryable
        (CheckpointPayloadIncompatible (CheckpointRuntimeVersionMismatch 1 2))
        `shouldBe` True
      checkpointValidationFailureRetryable
        (CheckpointPayloadIncompatible (CheckpointNameMismatch "a" "b"))
        `shouldBe` False

  beforeAll setupTestDb . describe "readCheckpointPayloadValidated" $ do
    it "returns CheckpointMissing when no checkpoint row exists" $ \mPool ->
      withDb mPool $ \pool -> do
        taskId <- insertTestTaskDef pool "checkpoint-validation-missing"
        runId <- createTestRun pool taskId
        runSession pool (Q.readCheckpointPayloadValidated expectation runId)
          `shouldReturn` CheckpointMissing

    it "returns the payload for a matching checkpoint row" $ \mPool ->
      withDb mPool $ \pool -> do
        taskId <- insertTestTaskDef pool "checkpoint-validation-valid"
        runId <- createTestRun pool taskId
        writeCheckpoint pool runId "test_alpha" (validEnvelope "test_alpha")
        runSession pool (Q.readCheckpointPayloadValidated expectation runId)
          `shouldReturn` CheckpointValidated checkpointPayload

    it "rejects a row whose checkpoint column disagrees with the envelope" $ \mPool ->
      withDb mPool $ \pool -> do
        taskId <- insertTestTaskDef pool "checkpoint-validation-row-name"
        runId <- createTestRun pool taskId
        writeCheckpoint
          pool
          runId
          "test_alpha"
          (checkpointEnvelope taskType taskVersion runtimeVersion "test_beta")
        runSession pool (Q.readCheckpointPayloadValidated expectationWithoutName runId)
          `shouldReturn` CheckpointRejected
            (CheckpointPayloadIncompatible (CheckpointNameMismatch "test_alpha" "test_beta"))

    it "rejects a stored stage that differs from the expected checkpoint name" $ \mPool ->
      withDb mPool $ \pool -> do
        taskId <- insertTestTaskDef pool "checkpoint-validation-expected-name"
        runId <- createTestRun pool taskId
        writeCheckpoint
          pool
          runId
          "test_beta"
          (checkpointEnvelope taskType taskVersion runtimeVersion "test_beta")
        runSession pool (Q.readCheckpointPayloadValidated expectation runId)
          `shouldReturn` CheckpointRejected
            (CheckpointPayloadIncompatible (CheckpointNameMismatch "test_alpha" "test_beta"))

withDb :: Maybe Pool -> (Pool -> IO ()) -> IO ()
withDb Nothing _ = pendingWith "PGHOST not set - database not available"
withDb (Just pool) action = action pool

setupTestDb :: IO (Maybe Pool)
setupTestDb = do
  mHost <- lookupEnv "PGHOST"
  case mHost of
    Nothing -> pure Nothing
    Just _ -> do
      result <- try createTestDB :: IO (Either SomeException Pool)
      case result of
        Left err -> error $ "PGHOST is set but database setup failed: " <> displayException err
        Right pool -> pure (Just pool)

insertTestTaskDef :: Pool -> Text -> IO UUID
insertTestTaskDef pool taskName = do
  now <- getCurrentTime
  runTx pool $
    Q.claimTestTaskDef taskType taskName now

createTestRun :: Pool -> UUID -> IO UUID
createTestRun pool taskId = do
  now <- getCurrentTime
  result <-
    runTx pool $
      Q.claimAndCreateRun
        taskId
        "test-owner"
        TriggerManual
        now
        300
  case result of
    Just runId -> pure runId
    Nothing ->
      expectationFailure "failed to create test run" $> UUID.nil

writeCheckpoint :: Pool -> UUID -> Text -> Aeson.Value -> IO ()
writeCheckpoint pool runId checkpointName payload = do
  now <- getCurrentTime
  runTx pool $
    Q.writeCheckpoint runId taskType checkpointName payload Nothing now

expectation :: CheckpointReadExpectation
expectation =
  CheckpointReadExpectation
    { creTaskType = taskType
    , creTaskVersion = taskVersion
    , creRuntimeVersion = runtimeVersion
    , creCheckpointName = Just "test_alpha"
    }

expectationWithoutName :: CheckpointReadExpectation
expectationWithoutName =
  expectation {creCheckpointName = Nothing}

storedCheckpoint :: Text -> Aeson.Value -> StoredCheckpointPayload
storedCheckpoint =
  StoredCheckpointPayload taskType

validEnvelope :: Text -> Aeson.Value
validEnvelope =
  checkpointEnvelope taskType taskVersion runtimeVersion

checkpointEnvelope :: Text -> Int -> Int -> Text -> Aeson.Value
checkpointEnvelope taskType' taskVersion' runtimeVersion' checkpointName =
  Aeson.toJSON $
    buildCheckpointEnvelope
      taskType'
      taskVersion'
      runtimeVersion'
      checkpointName
      checkpointPayload

rawEnvelope :: Int -> Text -> Int -> Int -> Text -> Aeson.Value
rawEnvelope formatVersion taskType' taskVersion' runtimeVersion' checkpointName =
  Aeson.object
    [ "ceFormatVersion" Aeson..= formatVersion
    , "ceTaskType" Aeson..= taskType'
    , "ceTaskVersion" Aeson..= taskVersion'
    , "ceRuntimeVersion" Aeson..= runtimeVersion'
    , "ceCheckpointName" Aeson..= checkpointName
    , "cePayload" Aeson..= checkpointPayload
    ]

checkpointPayload :: Aeson.Value
checkpointPayload =
  Aeson.object ["ok" Aeson..= True]

taskType :: Text
taskType = "paper_portfolio_cycle"

taskVersion :: Int
taskVersion = 1

runtimeVersion :: Int
runtimeVersion = 7
