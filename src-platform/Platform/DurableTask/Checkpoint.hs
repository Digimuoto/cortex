{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Platform.DurableTask.Checkpoint
  ( CheckpointEnvelope (..),
    CheckpointCompatibilityFailure (..),
    checkpointEnvelopeFormatVersion,
    buildCheckpointEnvelope,
    parseCheckpointEnvelope,
    validateCheckpointEnvelope,
    renderCheckpointCompatibilityFailure,
    compatibilityFailureErrorType,
    compatibilityFailureIsRetryable,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

checkpointEnvelopeFormatVersion :: Int
checkpointEnvelopeFormatVersion = 1

data CheckpointEnvelope = CheckpointEnvelope
  { ceFormatVersion :: Int,
    ceTaskType :: Text,
    ceTaskVersion :: Int,
    ceRuntimeVersion :: Int,
    ceCheckpointName :: Text,
    cePayload :: Aeson.Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CheckpointCompatibilityFailure
  = UnsupportedCheckpointEnvelopeVersion Int
  | CheckpointTaskTypeMismatch Text Text
  | CheckpointTaskVersionMismatch Int Int
  | CheckpointRuntimeVersionMismatch Int Int
  | CheckpointNameMismatch Text Text
  deriving stock (Eq, Show)

buildCheckpointEnvelope ::
  Text ->
  Int ->
  Int ->
  Text ->
  Aeson.Value ->
  CheckpointEnvelope
buildCheckpointEnvelope taskType taskVersion runtimeVersion checkpointName payload =
  CheckpointEnvelope
    { ceFormatVersion = checkpointEnvelopeFormatVersion,
      ceTaskType = taskType,
      ceTaskVersion = taskVersion,
      ceRuntimeVersion = runtimeVersion,
      ceCheckpointName = checkpointName,
      cePayload = payload
    }

parseCheckpointEnvelope :: Aeson.Value -> Either Text CheckpointEnvelope
parseCheckpointEnvelope rawValue =
  case Aeson.fromJSON rawValue of
    Aeson.Error err -> Left (T.pack err)
    Aeson.Success envelope -> Right envelope

validateCheckpointEnvelope ::
  Text ->
  Int ->
  Int ->
  Text ->
  CheckpointEnvelope ->
  Either CheckpointCompatibilityFailure Aeson.Value
validateCheckpointEnvelope expectedTaskType expectedTaskVersion expectedRuntimeVersion expectedCheckpointName envelope
  | envelope.ceFormatVersion /= checkpointEnvelopeFormatVersion =
      Left (UnsupportedCheckpointEnvelopeVersion envelope.ceFormatVersion)
  | envelope.ceTaskType /= expectedTaskType =
      Left (CheckpointTaskTypeMismatch expectedTaskType envelope.ceTaskType)
  | envelope.ceTaskVersion /= expectedTaskVersion =
      Left (CheckpointTaskVersionMismatch expectedTaskVersion envelope.ceTaskVersion)
  | envelope.ceRuntimeVersion /= expectedRuntimeVersion =
      Left (CheckpointRuntimeVersionMismatch expectedRuntimeVersion envelope.ceRuntimeVersion)
  | envelope.ceCheckpointName /= expectedCheckpointName =
      Left (CheckpointNameMismatch expectedCheckpointName envelope.ceCheckpointName)
  | otherwise =
      Right envelope.cePayload

renderCheckpointCompatibilityFailure :: CheckpointCompatibilityFailure -> Text
renderCheckpointCompatibilityFailure = \case
  UnsupportedCheckpointEnvelopeVersion actualVersion ->
    "Unsupported checkpoint envelope format version: " <> showText actualVersion
  CheckpointTaskTypeMismatch expectedTaskType actualTaskType ->
    "Checkpoint task_type mismatch. Expected "
      <> expectedTaskType
      <> ", got "
      <> actualTaskType
      <> "."
  CheckpointTaskVersionMismatch expectedTaskVersion actualTaskVersion ->
    "Checkpoint task_version mismatch. Expected "
      <> showText expectedTaskVersion
      <> ", got "
      <> showText actualTaskVersion
      <> "."
  CheckpointRuntimeVersionMismatch expectedRuntimeVersion actualRuntimeVersion ->
    "Checkpoint runtime_version mismatch. Expected "
      <> showText expectedRuntimeVersion
      <> ", got "
      <> showText actualRuntimeVersion
      <> "."
  CheckpointNameMismatch expectedCheckpointName actualCheckpointName ->
    "Checkpoint name mismatch. Expected "
      <> expectedCheckpointName
      <> ", got "
      <> actualCheckpointName
      <> "."

-- | Machine-readable error type for each compatibility failure.
-- These map to pulse.runs.error_type for operator-visible diagnosis.
compatibilityFailureErrorType :: CheckpointCompatibilityFailure -> Text
compatibilityFailureErrorType = \case
  UnsupportedCheckpointEnvelopeVersion _ -> "checkpoint_format_unsupported"
  CheckpointTaskTypeMismatch _ _ -> "checkpoint_task_type_mismatch"
  CheckpointTaskVersionMismatch _ _ -> "checkpoint_task_version_mismatch"
  CheckpointRuntimeVersionMismatch _ _ -> "checkpoint_runtime_version_mismatch"
  CheckpointNameMismatch _ _ -> "checkpoint_name_mismatch"

-- | Whether a restart-as-new can recover from this failure.
-- Version mismatches and unsupported envelope formats are recoverable
-- because a fresh run uses current code and discards the old checkpoint.
-- Task type and name mismatches indicate misconfiguration, not version
-- evolution — restart-as-new does not resolve them.
compatibilityFailureIsRetryable :: CheckpointCompatibilityFailure -> Bool
compatibilityFailureIsRetryable = \case
  CheckpointTaskVersionMismatch _ _ -> True
  CheckpointRuntimeVersionMismatch _ _ -> True
  UnsupportedCheckpointEnvelopeVersion _ -> True
  CheckpointTaskTypeMismatch _ _ -> False
  CheckpointNameMismatch _ _ -> False

showText :: (Show a) => a -> Text
showText = T.pack . show
