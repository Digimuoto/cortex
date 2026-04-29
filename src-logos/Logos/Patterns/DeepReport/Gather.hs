{- |
Module      : Logos.Patterns.DeepReport.Gather
Description : Logos reasoning-library support for gather.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.DeepReport.Gather
  ( LogosGatherTaskConfig (..)
  , LogosGatherTaskResult (..)
  , LogosGatherRepairTaskConfig (..)
  , runGatherTask
  , runGatherRepairTask
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Logos.Thought.Host qualified as TaskHost
import Logos.Thought.Runtime qualified as TaskRuntime
import Logos.Thought.Stage (LogosStageDescriptor (..))
import Logos.Thought.ToolHost qualified as TaskToolHost
import Logos.Thought.ToolLoop
  ( LogosToolLoopConfig (..)
  , LogosToolLoopResult (..)
  , runToolLoop
  )

import Cortex.Capability.Model.Message
  ( systemMessage
  , userTextMessage
  )
import Cortex.Capability.Model.Output
  ( renderChoiceContentWithSources
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass
  , CortexGroundingMode
  , CortexResponseFormat (..)
  )
import Cortex.Capability.Tool.Definition (toolDefinitionName)
import Cortex.Capability.Tool.Record (CortexToolCallRecord (..))

import Platform.Text (showText)

data LogosGatherTaskConfig = LogosGatherTaskConfig
  { logosGatherTaskModelId :: Text
  , logosGatherTaskGroundingMode :: CortexGroundingMode
  , logosGatherTaskSystemPrompt :: Text
  , logosGatherTaskUserInput :: Text
  , logosGatherTaskTools :: [Aeson.Value]
  , logosGatherTaskStageName :: Text
  , logosGatherTaskTimeoutClass :: CortexChoiceTimeoutClass
  , logosGatherTaskMaxOutputTokens :: !(Maybe Int)
  , logosGatherTaskStepBudget :: Int
  , logosGatherTaskBudgetExceededText :: Text
  }

data LogosGatherRepairTaskConfig = LogosGatherRepairTaskConfig
  { logosGatherRepairTaskModelId :: Text
  , logosGatherRepairTaskGroundingMode :: CortexGroundingMode
  , logosGatherRepairTaskSystemPrompt :: Text
  , logosGatherRepairTaskBuildInput :: Int -> [Text] -> Text
  , logosGatherRepairTaskTools :: [Aeson.Value]
  , logosGatherRepairTaskMissingToolNames :: [Text]
  , logosGatherRepairTaskStageName :: Text
  , logosGatherRepairTaskTimeoutClass :: CortexChoiceTimeoutClass
  , logosGatherRepairTaskMaxOutputTokens :: !(Maybe Int)
  , logosGatherRepairTaskMaxSteps :: Int
  }

data LogosGatherTaskResult = LogosGatherTaskResult
  { logosGatherTaskResultSummary :: Text
  , logosGatherTaskResultToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

runGatherTask
  :: MonadIO m
  => TaskToolHost.LogosTaskToolHost m
  -> LogosGatherTaskConfig
  -> m LogosGatherTaskResult
runGatherTask taskToolHost config = do
  let descriptor =
        LogosStageDescriptor
          { logosStageAgentName = Just "Gatherer"
          , logosStageStageName = Nothing
          , logosStageStep = Just 1
          , logosStageToolName = Nothing
          }
      taskHost = TaskToolHost.taskToolHostBase taskToolHost
  TaskRuntime.emitAgentStart
    taskHost
    descriptor
    "Gatherer started"
    (Just "Collecting deterministic evidence and context.")
  loopResult <-
    runToolLoop
      taskToolHost
      LogosToolLoopConfig
        { logosToolLoopDescriptor = descriptor
        , logosToolLoopChoiceRequest =
            CortexChoiceRequest
              { cortexChoiceModelId = config.logosGatherTaskModelId
              , cortexChoiceGroundingMode = config.logosGatherTaskGroundingMode
              , cortexChoiceMessages =
                  [ systemMessage config.logosGatherTaskSystemPrompt
                  , userTextMessage config.logosGatherTaskUserInput
                  ]
              , cortexChoiceTools = config.logosGatherTaskTools
              , cortexChoiceResponseFormat = CortexResponseText
              , cortexChoiceMaxOutputTokens = config.logosGatherTaskMaxOutputTokens
              , cortexChoiceStageName = config.logosGatherTaskStageName
              , cortexChoiceAgentName = Just "Gatherer"
              , cortexChoiceStepIndex = Just 1
              , cortexChoiceSectionId = Nothing
              , cortexChoiceAttempt = Nothing
              , cortexChoiceTimeoutClass = config.logosGatherTaskTimeoutClass
              , cortexChoiceReasoningEnabled = False
              }
        , logosToolLoopStepBudget = max 1 config.logosGatherTaskStepBudget
        , logosToolLoopBudgetExceededText = config.logosGatherTaskBudgetExceededText
        , logosToolLoopThinkingTitle = \stepNumber -> "Gatherer step " <> showText stepNumber
        , logosToolLoopThinkingSummary = const (Just "Selecting read tools for the evidence bundle.")
        }
  let result =
        LogosGatherTaskResult
          { logosGatherTaskResultSummary = loopResult.logosToolLoopResultText
          , logosGatherTaskResultToolCallRecords = loopResult.logosToolLoopResultRecords
          }
  TaskRuntime.emitAgentDone
    taskHost
    descriptor {logosStageStep = Just (max 1 (length result.logosGatherTaskResultToolCallRecords))}
    "Gatherer completed"
    Nothing
  pure result

runGatherRepairTask
  :: MonadIO m
  => TaskToolHost.LogosTaskToolHost m
  -> LogosGatherRepairTaskConfig
  -> m LogosGatherTaskResult
runGatherRepairTask taskToolHost config = do
  TaskHost.throwIfTaskCanceled taskHost
  let descriptor =
        LogosStageDescriptor
          { logosStageAgentName = Just "Gatherer"
          , logosStageStageName = Just "required_evidence_repair"
          , logosStageStep = Just 1
          , logosStageToolName = Nothing
          }
  TaskRuntime.emitSummary
    taskHost
    descriptor.logosStageAgentName
    descriptor.logosStageStageName
    descriptor.logosStageStep
    "Gatherer repair pass"
    ( Just
        ( "Retrying only the missing required tools: "
            <> T.intercalate ", " config.logosGatherRepairTaskMissingToolNames
            <> "."
        )
    )
    Nothing
  TaskRuntime.emitThinking
    taskHost
    descriptor
    "Gatherer repair thinking"
    (Just "Repairing missing deterministic evidence before analysis.")
  loop descriptor 0 [] config.logosGatherRepairTaskMissingToolNames ""
  where
    taskHost = TaskToolHost.taskToolHostBase taskToolHost

    loop descriptor stepIndex accToolCallRecords remainingToolNames lastSummary
      | null remainingToolNames =
          pure (LogosGatherTaskResult lastSummary accToolCallRecords)
      | stepIndex >= max 1 config.logosGatherRepairTaskMaxSteps =
          pure (LogosGatherTaskResult lastSummary accToolCallRecords)
      | otherwise = do
          TaskHost.throwIfTaskCanceled taskHost
          let attemptNumber = stepIndex + 1
              repairPrompt = config.logosGatherRepairTaskBuildInput attemptNumber remainingToolNames
              allowedRepairTools = filterRepairTools remainingToolNames config.logosGatherRepairTaskTools
          choice <-
            TaskHost.requestTaskChoice
              taskHost
              CortexChoiceRequest
                { cortexChoiceModelId = config.logosGatherRepairTaskModelId
                , cortexChoiceGroundingMode = config.logosGatherRepairTaskGroundingMode
                , cortexChoiceMessages =
                    [ systemMessage config.logosGatherRepairTaskSystemPrompt
                    , userTextMessage repairPrompt
                    ]
                , cortexChoiceTools = allowedRepairTools
                , cortexChoiceResponseFormat = CortexResponseText
                , cortexChoiceMaxOutputTokens = config.logosGatherRepairTaskMaxOutputTokens
                , cortexChoiceStageName = config.logosGatherRepairTaskStageName
                , cortexChoiceAgentName = Just "Gatherer"
                , cortexChoiceStepIndex = Just attemptNumber
                , cortexChoiceSectionId = Just "required_evidence_repair"
                , cortexChoiceAttempt = Just attemptNumber
                , cortexChoiceTimeoutClass = config.logosGatherRepairTaskTimeoutClass
                , cortexChoiceReasoningEnabled = False
                }
          if null choice.cortexChoiceToolCalls
            then
              let summaryText = renderChoiceContentWithSources config.logosGatherRepairTaskGroundingMode choice
               in loop descriptor attemptNumber accToolCallRecords remainingToolNames summaryText
            else do
              executionResult <-
                TaskToolHost.executeTaskToolCalls taskToolHost attemptNumber choice.cortexChoiceToolCalls
              let stepRecords = executionResult.logosToolExecutionRecords
                  mergedToolCallRecords = accToolCallRecords <> stepRecords
                  calledToolNames = nub (fmap (.cortexToolCallRecordName) mergedToolCallRecords)
                  stillMissing = filter (`notElem` calledToolNames) config.logosGatherRepairTaskMissingToolNames
                  summaryText =
                    case executionResult.logosToolExecutionTerminalError of
                      Just errText -> errText
                      Nothing ->
                        renderChoiceContentWithSources config.logosGatherRepairTaskGroundingMode choice
                          <> "\n\nRepair tool calls completed."
              case executionResult.logosToolExecutionTerminalError of
                Just _ ->
                  pure (LogosGatherTaskResult summaryText mergedToolCallRecords)
                Nothing ->
                  loop descriptor attemptNumber mergedToolCallRecords stillMissing summaryText

    filterRepairTools allowedNames =
      filter (maybe False (`elem` allowedNames) . toolDefinitionName)
