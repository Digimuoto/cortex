{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Task.Plan
  ( CortexPlanTaskConfig (..),
    runPlanTask,
  )
where

import Control.Monad.IO.Class (MonadIO)
import Cortex.Capability.Model.Message
  ( systemMessage,
    userTextMessage,
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..),
    CortexChoiceRequest (..),
    CortexChoiceTimeoutClass (..),
    CortexGroundingMode (..),
    CortexResponseFormat (..),
    CortexToolCall (..),
  )
import Cortex.Run.Types (CortexStageDescriptor (..))
import Cortex.Task.Host qualified as TaskHost
import Cortex.Task.Runtime qualified as TaskRuntime
import Cortex.Task.ToolHost
  ( CortexTaskToolHost,
    taskToolHostBase,
  )
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text (Text)

data CortexPlanTaskConfig m a = CortexPlanTaskConfig
  { cortexPlanTaskModelId :: Text,
    cortexPlanTaskPlannerSystemPrompt :: Text,
    cortexPlanTaskPlannerInput :: Text,
    cortexPlanTaskReviewerSystemPrompt :: Text,
    cortexPlanTaskReviewerInput :: Text -> Text,
    cortexPlanTaskReviewerTools :: [Aeson.Value],
    cortexPlanTaskMissingToolCallText :: Text,
    cortexPlanTaskFinalizeToolCall :: CortexToolCall -> m (Either Text a)
  }

runPlanTask ::
  (MonadIO m) =>
  CortexTaskToolHost m ->
  CortexPlanTaskConfig m a ->
  m (Either Text a)
runPlanTask taskToolHost config = do
  let taskHost = taskToolHostBase taskToolHost
  TaskRuntime.emitSummary
    taskHost
    Nothing
    (Just "multi_agent_runtime")
    Nothing
    "Plan task started"
    (Just "Running Planner and Reviewer phases before any expensive work begins.")
    Nothing
  plannerNotes <-
    TaskRuntime.runTextTask
      taskHost
      "plan_planner"
      CortexChoiceTimeoutStandard
      config.cortexPlanTaskModelId
      GroundingDisabled
      "Planner"
      (Just 1)
      config.cortexPlanTaskPlannerSystemPrompt
      config.cortexPlanTaskPlannerInput
  runPlanReviewerPhase taskHost config plannerNotes

runPlanReviewerPhase ::
  (MonadIO m) =>
  TaskHost.CortexTaskHost m ->
  CortexPlanTaskConfig m a ->
  Text ->
  m (Either Text a)
runPlanReviewerPhase taskHost config plannerNotes = do
  TaskHost.throwIfTaskCanceled taskHost
  let descriptor =
        CortexStageDescriptor
          { cortexStageAgentName = Just "Reviewer",
            cortexStageStageName = Nothing,
            cortexStageStep = Just 2,
            cortexStageToolName = Nothing
          }
  TaskRuntime.emitAgentStart taskHost descriptor "Reviewer started" (Just "Converting planner notes into a structured execution-plan draft.")
  choice <-
    TaskHost.requestTaskChoice
      taskHost
      CortexChoiceRequest
        { cortexChoiceModelId = config.cortexPlanTaskModelId,
          cortexChoiceGroundingMode = GroundingDisabled,
          cortexChoiceMessages =
            [ systemMessage config.cortexPlanTaskReviewerSystemPrompt,
              userTextMessage (config.cortexPlanTaskReviewerInput plannerNotes)
            ],
          cortexChoiceTools = config.cortexPlanTaskReviewerTools,
          cortexChoiceResponseFormat = CortexResponseText,
          cortexChoiceMaxOutputTokens = Nothing,
          cortexChoiceStageName = "plan_reviewer",
          cortexChoiceAgentName = Just "Reviewer",
          cortexChoiceStepIndex = Just 2,
          cortexChoiceSectionId = Nothing,
          cortexChoiceAttempt = Nothing,
          cortexChoiceTimeoutClass = CortexChoiceTimeoutStandard,
          cortexChoiceReasoningEnabled = False
        }
  case listToMaybe choice.cortexChoiceToolCalls of
    Nothing -> do
      TaskRuntime.emitError taskHost descriptor "Reviewer failed" (Just "No plan-finalization tool call was produced.")
      pure (Left config.cortexPlanTaskMissingToolCallText)
    Just call -> do
      config.cortexPlanTaskFinalizeToolCall call >>= \case
        Left errText -> do
          TaskRuntime.emitError taskHost descriptor "Reviewer failed" (Just errText)
          pure (Left errText)
        Right result -> do
          TaskRuntime.emitAgentDone
            taskHost
            descriptor {cortexStageToolName = Just call.cortexToolCallName}
            "Reviewer completed"
            Nothing
          pure (Right result)
