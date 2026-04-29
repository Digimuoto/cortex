{- |
Module      : Logos.Patterns.PlanReview
Description : Logos reasoning-library support for plan review.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.PlanReview
  ( LogosPlanTaskConfig (..)
  , runPlanTask
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Logos.Thought.Host qualified as TaskHost
import Logos.Thought.Runtime qualified as TaskRuntime
import Logos.Thought.Stage (LogosStageDescriptor (..))
import Logos.Thought.ToolHost
  ( LogosTaskToolHost
  , taskToolHostBase
  )

import Cortex.Capability.Model.Message
  ( systemMessage
  , userTextMessage
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexGroundingMode (..)
  , CortexResponseFormat (..)
  , CortexToolCall (..)
  )

data LogosPlanTaskConfig m a = LogosPlanTaskConfig
  { logosPlanTaskModelId :: Text
  , logosPlanTaskPlannerSystemPrompt :: Text
  , logosPlanTaskPlannerInput :: Text
  , logosPlanTaskReviewerSystemPrompt :: Text
  , logosPlanTaskReviewerInput :: Text -> Text
  , logosPlanTaskReviewerTools :: [Aeson.Value]
  , logosPlanTaskMissingToolCallText :: Text
  , logosPlanTaskFinalizeToolCall :: CortexToolCall -> m (Either Text a)
  }

runPlanTask
  :: MonadIO m
  => LogosTaskToolHost m
  -> LogosPlanTaskConfig m a
  -> m (Either Text a)
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
      config.logosPlanTaskModelId
      GroundingDisabled
      "Planner"
      (Just 1)
      config.logosPlanTaskPlannerSystemPrompt
      config.logosPlanTaskPlannerInput
  runPlanReviewerPhase taskHost config plannerNotes

runPlanReviewerPhase
  :: MonadIO m
  => TaskHost.LogosTaskHost m
  -> LogosPlanTaskConfig m a
  -> Text
  -> m (Either Text a)
runPlanReviewerPhase taskHost config plannerNotes = do
  TaskHost.throwIfTaskCanceled taskHost
  let descriptor =
        LogosStageDescriptor
          { logosStageAgentName = Just "Reviewer"
          , logosStageStageName = Nothing
          , logosStageStep = Just 2
          , logosStageToolName = Nothing
          }
  TaskRuntime.emitAgentStart
    taskHost
    descriptor
    "Reviewer started"
    (Just "Converting planner notes into a structured execution-plan draft.")
  choice <-
    TaskHost.requestTaskChoice
      taskHost
      CortexChoiceRequest
        { cortexChoiceModelId = config.logosPlanTaskModelId
        , cortexChoiceGroundingMode = GroundingDisabled
        , cortexChoiceMessages =
            [ systemMessage config.logosPlanTaskReviewerSystemPrompt
            , userTextMessage (config.logosPlanTaskReviewerInput plannerNotes)
            ]
        , cortexChoiceTools = config.logosPlanTaskReviewerTools
        , cortexChoiceResponseFormat = CortexResponseText
        , cortexChoiceMaxOutputTokens = Nothing
        , cortexChoiceStageName = "plan_reviewer"
        , cortexChoiceAgentName = Just "Reviewer"
        , cortexChoiceStepIndex = Just 2
        , cortexChoiceSectionId = Nothing
        , cortexChoiceAttempt = Nothing
        , cortexChoiceTimeoutClass = CortexChoiceTimeoutStandard
        , cortexChoiceReasoningEnabled = False
        }
  case listToMaybe choice.cortexChoiceToolCalls of
    Nothing -> do
      TaskRuntime.emitError
        taskHost
        descriptor
        "Reviewer failed"
        (Just "No plan-finalization tool call was produced.")
      pure (Left config.logosPlanTaskMissingToolCallText)
    Just call -> do
      config.logosPlanTaskFinalizeToolCall call >>= \case
        Left errText -> do
          TaskRuntime.emitError taskHost descriptor "Reviewer failed" (Just errText)
          pure (Left errText)
        Right result -> do
          TaskRuntime.emitAgentDone
            taskHost
            descriptor {logosStageToolName = Just call.cortexToolCallName}
            "Reviewer completed"
            Nothing
          pure (Right result)
