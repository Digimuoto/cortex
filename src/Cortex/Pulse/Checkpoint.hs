{- |
Module      : Cortex.Pulse.Checkpoint
Description : Pulse checkpoint compatibility validation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pulse-specific adapter around the generic Platform checkpoint envelope.

Current Pulse resume is graph-state driven. This module validates checkpoint
payloads for surfaces that read checkpoint rows directly, while graph-state
recovery remains the authoritative continuation path.
-}
module Cortex.Pulse.Checkpoint
  ( CheckpointReadExpectation (..)
  , StoredCheckpointPayload (..)
  , CheckpointReadResult (..)
  , PulseCheckpointValidationFailure (..)
  , validateStoredCheckpointPayload
  , checkpointValidationFailureErrorType
  , checkpointValidationFailureRetryable
  , renderCheckpointValidationFailure
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Text (Text)

import Platform.DurableTask.Checkpoint
  ( CheckpointCompatibilityFailure (..)
  , compatibilityFailureErrorType
  , compatibilityFailureIsRetryable
  , parseCheckpointEnvelope
  , renderCheckpointCompatibilityFailure
  , validateCheckpointEnvelope
  )

-- | Expected compatibility envelope for a checkpoint read.
data CheckpointReadExpectation = CheckpointReadExpectation
  { creTaskType :: !Text
  , creTaskVersion :: !Int
  , creRuntimeVersion :: !Int
  , creCheckpointName :: !(Maybe Text)
  {- ^ Optional concrete checkpoint name. When absent, the stored row's
  @checkpoint_name@ column is used and must match the embedded envelope name.
  -}
  }
  deriving stock (Eq, Show)

-- | Raw checkpoint payload as stored in @pulse.checkpoints@.
data StoredCheckpointPayload = StoredCheckpointPayload
  { scpTaskType :: !Text
  , scpCheckpointName :: !Text
  , scpState :: !Aeson.Value
  }
  deriving stock (Eq, Show)

-- | Result of reading and validating the latest checkpoint row.
data CheckpointReadResult
  = CheckpointMissing
  | CheckpointValidated !Aeson.Value
  | CheckpointRejected !PulseCheckpointValidationFailure
  deriving stock (Eq, Show)

-- | Pulse-level checkpoint validation failure.
data PulseCheckpointValidationFailure
  = CheckpointPayloadCorrupt !Text
  | CheckpointPayloadIncompatible !CheckpointCompatibilityFailure
  deriving stock (Eq, Show)

-- | Validate a stored checkpoint row against the expected Pulse runtime envelope.
validateStoredCheckpointPayload
  :: CheckpointReadExpectation
  -> StoredCheckpointPayload
  -> Either PulseCheckpointValidationFailure Aeson.Value
validateStoredCheckpointPayload expected stored
  | stored.scpTaskType /= expected.creTaskType =
      Left . CheckpointPayloadIncompatible $
        CheckpointTaskTypeMismatch expected.creTaskType stored.scpTaskType
  | otherwise =
      case expected.creCheckpointName of
        Just expectedName
          | stored.scpCheckpointName /= expectedName ->
              Left . CheckpointPayloadIncompatible $
                CheckpointNameMismatch expectedName stored.scpCheckpointName
          | otherwise ->
              validateEnvelope expectedName
        Nothing ->
          validateEnvelope stored.scpCheckpointName
  where
    validateEnvelope expectedCheckpointName = do
      envelope <-
        first CheckpointPayloadCorrupt $
          parseCheckpointEnvelope stored.scpState
      first CheckpointPayloadIncompatible $
        validateCheckpointEnvelope
          expected.creTaskType
          expected.creTaskVersion
          expected.creRuntimeVersion
          expectedCheckpointName
          envelope

-- | Machine-readable Pulse error type for a checkpoint validation failure.
checkpointValidationFailureErrorType :: PulseCheckpointValidationFailure -> Text
checkpointValidationFailureErrorType = \case
  CheckpointPayloadCorrupt _ -> "checkpoint_corruption"
  CheckpointPayloadIncompatible failure -> compatibilityFailureErrorType failure

-- | Whether a fresh run can recover from this failure.
checkpointValidationFailureRetryable :: PulseCheckpointValidationFailure -> Bool
checkpointValidationFailureRetryable = \case
  CheckpointPayloadCorrupt _ -> False
  CheckpointPayloadIncompatible failure -> compatibilityFailureIsRetryable failure

-- | Operator-facing description of a checkpoint validation failure.
renderCheckpointValidationFailure :: PulseCheckpointValidationFailure -> Text
renderCheckpointValidationFailure = \case
  CheckpointPayloadCorrupt err ->
    "Checkpoint payload could not be decoded: " <> err
  CheckpointPayloadIncompatible failure ->
    renderCheckpointCompatibilityFailure failure
