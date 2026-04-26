{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Platform.DurableTask.Types
  ( RunStatus (..),
    runStatusToText,
    runStatusFromText,
    StageStatus (..),
    stageStatusToText,
    stageStatusFromText,
    TriggerSource (..),
    triggerSourceToText,
    triggerSourceFromText,
    RunOutcome (..),
    runOutcomeToText,
    runOutcomeToFinalStatus,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import GHC.Generics (Generic)

data RunStatus
  = Pending
  | Running
  | Completed
  | Failed
  | Cancelled
  | Timeout
  | Skipped
  | Waiting
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

instance ToJSON RunStatus where
  toJSON = Aeson.String . runStatusToText

instance FromJSON RunStatus where
  parseJSON = Aeson.withText "RunStatus" $ \rawValue ->
    case runStatusFromText rawValue of
      Just value -> pure value
      Nothing -> fail $ "Unknown RunStatus: " <> show rawValue

runStatusToText :: RunStatus -> Text
runStatusToText = \case
  Pending -> "pending"
  Running -> "running"
  Completed -> "completed"
  Failed -> "failed"
  Cancelled -> "cancelled"
  Timeout -> "timeout"
  Skipped -> "skipped"
  Waiting -> "waiting"

runStatusFromText :: Text -> Maybe RunStatus
runStatusFromText = \case
  "pending" -> Just Pending
  "running" -> Just Running
  "completed" -> Just Completed
  "failed" -> Just Failed
  "cancelled" -> Just Cancelled
  "timeout" -> Just Timeout
  "skipped" -> Just Skipped
  "waiting" -> Just Waiting
  _ -> Nothing

data StageStatus
  = StageStarted
  | StageCompleted
  | StageFailed
  | StageSkipped
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

instance ToJSON StageStatus where
  toJSON = Aeson.String . stageStatusToText

instance FromJSON StageStatus where
  parseJSON = Aeson.withText "StageStatus" $ \rawValue ->
    case stageStatusFromText rawValue of
      Just value -> pure value
      Nothing -> fail $ "Unknown StageStatus: " <> show rawValue

stageStatusToText :: StageStatus -> Text
stageStatusToText = \case
  StageStarted -> "started"
  StageCompleted -> "completed"
  StageFailed -> "failed"
  StageSkipped -> "skipped"

stageStatusFromText :: Text -> Maybe StageStatus
stageStatusFromText = \case
  "started" -> Just StageStarted
  "completed" -> Just StageCompleted
  "failed" -> Just StageFailed
  "skipped" -> Just StageSkipped
  _ -> Nothing

data TriggerSource
  = TriggerSchedule
  | TriggerManual
  | TriggerRetry
  deriving stock (Eq, Show, Bounded, Enum, Generic)

instance ToJSON TriggerSource where
  toJSON = Aeson.String . triggerSourceToText

instance FromJSON TriggerSource where
  parseJSON = Aeson.withText "TriggerSource" $ \rawValue ->
    case triggerSourceFromText rawValue of
      Just value -> pure value
      Nothing -> fail $ "Unknown TriggerSource: " <> show rawValue

triggerSourceToText :: TriggerSource -> Text
triggerSourceToText = \case
  TriggerSchedule -> "schedule"
  TriggerManual -> "manual"
  TriggerRetry -> "retry"

triggerSourceFromText :: Text -> Maybe TriggerSource
triggerSourceFromText = \case
  "schedule" -> Just TriggerSchedule
  "manual" -> Just TriggerManual
  "retry" -> Just TriggerRetry
  _ -> Nothing

data RunOutcome
  = OutcomeCompleted
  | OutcomeFailed
  | OutcomeCancelled
  | OutcomeTimedOut
  | OutcomeShutdown
  | OutcomeSuspended
  deriving stock (Eq, Show, Generic)

runOutcomeToText :: RunOutcome -> Text
runOutcomeToText = \case
  OutcomeCompleted -> "completed"
  OutcomeFailed -> "failed"
  OutcomeCancelled -> "cancelled"
  OutcomeTimedOut -> "timeout"
  OutcomeShutdown -> "shutdown"
  OutcomeSuspended -> "suspended"

runOutcomeToFinalStatus :: RunOutcome -> Maybe RunStatus
runOutcomeToFinalStatus = \case
  OutcomeCompleted -> Just Completed
  OutcomeFailed -> Just Failed
  OutcomeCancelled -> Just Cancelled
  OutcomeTimedOut -> Just Timeout
  OutcomeShutdown -> Nothing
  OutcomeSuspended -> Just Waiting
