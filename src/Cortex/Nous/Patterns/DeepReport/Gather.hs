module Cortex.Nous.Patterns.DeepReport.Gather
  ( CortexGatherTaskConfig (..)
  , CortexGatherTaskResult (..)
  , CortexGatherRepairTaskConfig (..)
  , runGatherTask
  , runGatherRepairTask
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T

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
import Cortex.Nous.Thought.Host qualified as TaskHost
import Cortex.Nous.Thought.Runtime qualified as TaskRuntime
import Cortex.Nous.Thought.Stage (CortexStageDescriptor (..))
import Cortex.Nous.Thought.ToolHost qualified as TaskToolHost
import Cortex.Nous.Thought.ToolLoop
  ( CortexToolLoopConfig (..)
  , CortexToolLoopResult (..)
  , runToolLoop
  )

import Platform.Text (showText)

data CortexGatherTaskConfig = CortexGatherTaskConfig
  { cortexGatherTaskModelId :: Text
  , cortexGatherTaskGroundingMode :: CortexGroundingMode
  , cortexGatherTaskSystemPrompt :: Text
  , cortexGatherTaskUserInput :: Text
  , cortexGatherTaskTools :: [Aeson.Value]
  , cortexGatherTaskStageName :: Text
  , cortexGatherTaskTimeoutClass :: CortexChoiceTimeoutClass
  , cortexGatherTaskMaxOutputTokens :: !(Maybe Int)
  , cortexGatherTaskStepBudget :: Int
  , cortexGatherTaskBudgetExceededText :: Text
  }

data CortexGatherRepairTaskConfig = CortexGatherRepairTaskConfig
  { cortexGatherRepairTaskModelId :: Text
  , cortexGatherRepairTaskGroundingMode :: CortexGroundingMode
  , cortexGatherRepairTaskSystemPrompt :: Text
  , cortexGatherRepairTaskBuildInput :: Int -> [Text] -> Text
  , cortexGatherRepairTaskTools :: [Aeson.Value]
  , cortexGatherRepairTaskMissingToolNames :: [Text]
  , cortexGatherRepairTaskStageName :: Text
  , cortexGatherRepairTaskTimeoutClass :: CortexChoiceTimeoutClass
  , cortexGatherRepairTaskMaxOutputTokens :: !(Maybe Int)
  , cortexGatherRepairTaskMaxSteps :: Int
  }

data CortexGatherTaskResult = CortexGatherTaskResult
  { cortexGatherTaskResultSummary :: Text
  , cortexGatherTaskResultToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

runGatherTask
  :: MonadIO m
  => TaskToolHost.CortexTaskToolHost m
  -> CortexGatherTaskConfig
  -> m CortexGatherTaskResult
runGatherTask taskToolHost config = do
  let descriptor =
        CortexStageDescriptor
          { cortexStageAgentName = Just "Gatherer"
          , cortexStageStageName = Nothing
          , cortexStageStep = Just 1
          , cortexStageToolName = Nothing
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
      CortexToolLoopConfig
        { cortexToolLoopDescriptor = descriptor
        , cortexToolLoopChoiceRequest =
            CortexChoiceRequest
              { cortexChoiceModelId = config.cortexGatherTaskModelId
              , cortexChoiceGroundingMode = config.cortexGatherTaskGroundingMode
              , cortexChoiceMessages =
                  [ systemMessage config.cortexGatherTaskSystemPrompt
                  , userTextMessage config.cortexGatherTaskUserInput
                  ]
              , cortexChoiceTools = config.cortexGatherTaskTools
              , cortexChoiceResponseFormat = CortexResponseText
              , cortexChoiceMaxOutputTokens = config.cortexGatherTaskMaxOutputTokens
              , cortexChoiceStageName = config.cortexGatherTaskStageName
              , cortexChoiceAgentName = Just "Gatherer"
              , cortexChoiceStepIndex = Just 1
              , cortexChoiceSectionId = Nothing
              , cortexChoiceAttempt = Nothing
              , cortexChoiceTimeoutClass = config.cortexGatherTaskTimeoutClass
              , cortexChoiceReasoningEnabled = False
              }
        , cortexToolLoopStepBudget = max 1 config.cortexGatherTaskStepBudget
        , cortexToolLoopBudgetExceededText = config.cortexGatherTaskBudgetExceededText
        , cortexToolLoopThinkingTitle = \stepNumber -> "Gatherer step " <> showText stepNumber
        , cortexToolLoopThinkingSummary = const (Just "Selecting read tools for the evidence bundle.")
        }
  let result =
        CortexGatherTaskResult
          { cortexGatherTaskResultSummary = loopResult.cortexToolLoopResultText
          , cortexGatherTaskResultToolCallRecords = loopResult.cortexToolLoopResultRecords
          }
  TaskRuntime.emitAgentDone
    taskHost
    descriptor {cortexStageStep = Just (max 1 (length result.cortexGatherTaskResultToolCallRecords))}
    "Gatherer completed"
    Nothing
  pure result

runGatherRepairTask
  :: MonadIO m
  => TaskToolHost.CortexTaskToolHost m
  -> CortexGatherRepairTaskConfig
  -> m CortexGatherTaskResult
runGatherRepairTask taskToolHost config = do
  TaskHost.throwIfTaskCanceled taskHost
  let descriptor =
        CortexStageDescriptor
          { cortexStageAgentName = Just "Gatherer"
          , cortexStageStageName = Just "required_evidence_repair"
          , cortexStageStep = Just 1
          , cortexStageToolName = Nothing
          }
  TaskRuntime.emitSummary
    taskHost
    descriptor.cortexStageAgentName
    descriptor.cortexStageStageName
    descriptor.cortexStageStep
    "Gatherer repair pass"
    ( Just
        ( "Retrying only the missing required tools: "
            <> T.intercalate ", " config.cortexGatherRepairTaskMissingToolNames
            <> "."
        )
    )
    Nothing
  TaskRuntime.emitThinking
    taskHost
    descriptor
    "Gatherer repair thinking"
    (Just "Repairing missing deterministic evidence before analysis.")
  loop descriptor 0 [] config.cortexGatherRepairTaskMissingToolNames ""
  where
    taskHost = TaskToolHost.taskToolHostBase taskToolHost

    loop descriptor stepIndex accToolCallRecords remainingToolNames lastSummary
      | null remainingToolNames =
          pure (CortexGatherTaskResult lastSummary accToolCallRecords)
      | stepIndex >= max 1 config.cortexGatherRepairTaskMaxSteps =
          pure (CortexGatherTaskResult lastSummary accToolCallRecords)
      | otherwise = do
          TaskHost.throwIfTaskCanceled taskHost
          let attemptNumber = stepIndex + 1
              repairPrompt = config.cortexGatherRepairTaskBuildInput attemptNumber remainingToolNames
              allowedRepairTools = filterRepairTools remainingToolNames config.cortexGatherRepairTaskTools
          choice <-
            TaskHost.requestTaskChoice
              taskHost
              CortexChoiceRequest
                { cortexChoiceModelId = config.cortexGatherRepairTaskModelId
                , cortexChoiceGroundingMode = config.cortexGatherRepairTaskGroundingMode
                , cortexChoiceMessages =
                    [ systemMessage config.cortexGatherRepairTaskSystemPrompt
                    , userTextMessage repairPrompt
                    ]
                , cortexChoiceTools = allowedRepairTools
                , cortexChoiceResponseFormat = CortexResponseText
                , cortexChoiceMaxOutputTokens = config.cortexGatherRepairTaskMaxOutputTokens
                , cortexChoiceStageName = config.cortexGatherRepairTaskStageName
                , cortexChoiceAgentName = Just "Gatherer"
                , cortexChoiceStepIndex = Just attemptNumber
                , cortexChoiceSectionId = Just "required_evidence_repair"
                , cortexChoiceAttempt = Just attemptNumber
                , cortexChoiceTimeoutClass = config.cortexGatherRepairTaskTimeoutClass
                , cortexChoiceReasoningEnabled = False
                }
          if null choice.cortexChoiceToolCalls
            then
              let summaryText = renderChoiceContentWithSources config.cortexGatherRepairTaskGroundingMode choice
               in loop descriptor attemptNumber accToolCallRecords remainingToolNames summaryText
            else do
              executionResult <-
                TaskToolHost.executeTaskToolCalls taskToolHost attemptNumber choice.cortexChoiceToolCalls
              let stepRecords = executionResult.cortexToolExecutionRecords
                  mergedToolCallRecords = accToolCallRecords <> stepRecords
                  calledToolNames = nub (fmap (.cortexToolCallRecordName) mergedToolCallRecords)
                  stillMissing = filter (`notElem` calledToolNames) config.cortexGatherRepairTaskMissingToolNames
                  summaryText =
                    case executionResult.cortexToolExecutionTerminalError of
                      Just errText -> errText
                      Nothing ->
                        renderChoiceContentWithSources config.cortexGatherRepairTaskGroundingMode choice
                          <> "\n\nRepair tool calls completed."
              case executionResult.cortexToolExecutionTerminalError of
                Just _ ->
                  pure (CortexGatherTaskResult summaryText mergedToolCallRecords)
                Nothing ->
                  loop descriptor attemptNumber mergedToolCallRecords stillMissing summaryText

    filterRepairTools allowedNames =
      filter (maybe False (`elem` allowedNames) . toolDefinitionName)
