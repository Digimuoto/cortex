{- |
Module      : Logos.Patterns.DeepReport.LegacyReportTask
Description : Logos reasoning-library support for legacy report task.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.DeepReport.LegacyReportTask
  ( LogosReportTaskConfig (..)
  , LogosReportTaskFailure (..)
  , LogosReportTaskResult (..)
  , LogosRequiredToolEvidenceStatus (..)
  , CortexToolCallResultStatus (..)
  , hasSuccessfulToolEvidence
  , latestSuccessfulToolResult
  , missingRequiredTools
  , requiredToolEvidenceStatus
  , runReportTask
  , toolCallResultStatus
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as T
import Logos.Patterns.DeepReport.Gather
  ( LogosGatherRepairTaskConfig (..)
  , LogosGatherTaskConfig (..)
  , LogosGatherTaskResult (..)
  , runGatherRepairTask
  , runGatherTask
  )
import Logos.Thought.Runtime qualified as TaskRuntime
import Logos.Thought.Stage (LogosStageDescriptor (..))
import Logos.Thought.ToolHost qualified as TaskToolHost

import Cortex.Capability.Model.Types
  ( CortexChoiceTimeoutClass
  , CortexGroundingMode (..)
  )
import Cortex.Capability.Tool.Definition (toolDefinitionName)
import Cortex.Capability.Tool.Record (CortexToolCallRecord (..))

import Platform.Serde.Json.Object
  ( hasObjectBool
  , lookupObjectText
  )

data CortexToolCallResultStatus
  = CortexToolCallResultSuccess
  | CortexToolCallResultNoData
  | CortexToolCallResultError
  deriving stock (Eq, Show)

data LogosRequiredToolEvidenceStatus
  = LogosRequiredToolEvidenceMissing
  | LogosRequiredToolEvidenceSuccess
  | LogosRequiredToolEvidenceNoData
  | LogosRequiredToolEvidenceError
  deriving stock (Eq, Show)

data LogosReportTaskFailure = LogosReportTaskFailure
  { logosReportTaskFailureText :: Text
  , logosReportTaskFailureToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

data LogosReportTaskResult artifact = LogosReportTaskResult
  { logosReportTaskResultArtifact :: artifact
  , logosReportTaskResultToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

data LogosReportTaskConfig m artifact = LogosReportTaskConfig
  { logosReportTaskPlannerModelId :: Text
  , logosReportTaskPlannerSystemPrompt :: Text
  , logosReportTaskPlannerInput :: Text
  , logosReportTaskPlannerTimeoutClass :: CortexChoiceTimeoutClass
  , logosReportTaskGatherModelId :: Text
  , logosReportTaskGatherGroundingMode :: CortexGroundingMode
  , logosReportTaskGatherSystemPrompt :: Text
  , logosReportTaskBuildGatherInput :: Text -> Text
  , logosReportTaskGatherTools :: [Aeson.Value]
  , logosReportTaskGatherStageName :: Text
  , logosReportTaskGatherTimeoutClass :: CortexChoiceTimeoutClass
  , logosReportTaskGatherStepBudget :: Int
  , logosReportTaskGatherBudgetExceededText :: Text
  , logosReportTaskRequiredToolNames :: [Text]
  , logosReportTaskBuildGatherRepairInput :: Text -> Text -> Int -> [Text] -> Text
  , logosReportTaskGatherRepairStageName :: Text
  , logosReportTaskGatherRepairMaxSteps :: Int
  , logosReportTaskAnalystModelId :: Text
  , logosReportTaskAnalystSystemPrompt :: Text
  , logosReportTaskBuildAnalystInput :: Text -> Text -> [CortexToolCallRecord] -> Text
  , logosReportTaskAnalystTimeoutClass :: CortexChoiceTimeoutClass
  , logosReportTaskReviewerModelId :: Text
  , logosReportTaskReviewerSystemPrompt :: Text
  , logosReportTaskBuildReviewerInput :: Text -> Text -> Text -> [CortexToolCallRecord] -> Text
  , logosReportTaskReviewerTimeoutClass :: CortexChoiceTimeoutClass
  , logosReportTaskBeforeAnalysis :: [CortexToolCallRecord] -> m (Either Text ())
  , logosReportTaskFinalize :: Text -> [CortexToolCallRecord] -> m (Either Text artifact)
  }

toolCallResultStatus :: Aeson.Value -> CortexToolCallResultStatus
toolCallResultStatus = \case
  Aeson.String textValue
    | isErrorText textValue -> CortexToolCallResultError
    | otherwise -> CortexToolCallResultSuccess
  Aeson.Object obj
    | hasObjectBool "error" obj || KeyMap.member "errorType" obj -> CortexToolCallResultError
    | hasObjectBool "noData" obj -> CortexToolCallResultNoData
    | maybe False isErrorText (lookupObjectText "text" obj) -> CortexToolCallResultError
    | otherwise -> CortexToolCallResultSuccess
  _ -> CortexToolCallResultSuccess

hasSuccessfulToolEvidence :: Text -> [CortexToolCallRecord] -> Bool
hasSuccessfulToolEvidence toolName toolCallRecords =
  requiredToolEvidenceStatus toolName toolCallRecords == LogosRequiredToolEvidenceSuccess

requiredToolEvidenceStatus :: Text -> [CortexToolCallRecord] -> LogosRequiredToolEvidenceStatus
requiredToolEvidenceStatus toolName toolCallRecords =
  case matchingRecords of
    [] -> LogosRequiredToolEvidenceMissing
    _
      | any
          ( (== CortexToolCallResultSuccess)
              . toolCallResultStatus
              . (.cortexToolCallRecordResult)
          )
          matchingRecords ->
          LogosRequiredToolEvidenceSuccess
    _
      | any
          ( (== CortexToolCallResultNoData)
              . toolCallResultStatus
              . (.cortexToolCallRecordResult)
          )
          matchingRecords ->
          LogosRequiredToolEvidenceNoData
    _ -> LogosRequiredToolEvidenceError
  where
    matchingRecords = filter ((== toolName) . (.cortexToolCallRecordName)) toolCallRecords

latestSuccessfulToolResult :: Text -> [CortexToolCallRecord] -> Maybe Aeson.Value
latestSuccessfulToolResult toolName toolCallRecords =
  case successfulToolResults toolName toolCallRecords of
    [] -> Nothing
    values -> Just (last values)

missingRequiredTools :: [Text] -> [CortexToolCallRecord] -> [Text]
missingRequiredTools requiredToolNames toolCallRecords =
  filter isRepairableGap requiredToolNames
  where
    isRepairableGap toolName =
      case requiredToolEvidenceStatus toolName toolCallRecords of
        LogosRequiredToolEvidenceMissing -> True
        LogosRequiredToolEvidenceError -> True
        LogosRequiredToolEvidenceSuccess -> False
        LogosRequiredToolEvidenceNoData -> False

runReportTask
  :: MonadIO m
  => TaskToolHost.LogosTaskToolHost m
  -> LogosReportTaskConfig m artifact
  -> m (Either LogosReportTaskFailure (LogosReportTaskResult artifact))
runReportTask taskToolHost config = do
  let taskHost = TaskToolHost.taskToolHostBase taskToolHost
  TaskRuntime.emitSummary
    taskHost
    Nothing
    (Just "multi_agent_runtime")
    Nothing
    "Report mode started"
    (Just "Running Planner, Gatherer, Analyst, Reviewer, and finalization phases.")
    Nothing
  plannerNotes <-
    TaskRuntime.runTextTask
      taskHost
      "report_planner"
      config.logosReportTaskPlannerTimeoutClass
      config.logosReportTaskPlannerModelId
      GroundingDisabled
      "Planner"
      Nothing
      config.logosReportTaskPlannerSystemPrompt
      config.logosReportTaskPlannerInput
  gatheredInitial <-
    runGatherTask
      taskToolHost
      LogosGatherTaskConfig
        { logosGatherTaskModelId = config.logosReportTaskGatherModelId
        , logosGatherTaskGroundingMode = config.logosReportTaskGatherGroundingMode
        , logosGatherTaskSystemPrompt = config.logosReportTaskGatherSystemPrompt
        , logosGatherTaskUserInput = config.logosReportTaskBuildGatherInput plannerNotes
        , logosGatherTaskTools = config.logosReportTaskGatherTools
        , logosGatherTaskStageName = config.logosReportTaskGatherStageName
        , logosGatherTaskTimeoutClass = config.logosReportTaskGatherTimeoutClass
        , logosGatherTaskMaxOutputTokens = Nothing
        , logosGatherTaskStepBudget = config.logosReportTaskGatherStepBudget
        , logosGatherTaskBudgetExceededText = config.logosReportTaskGatherBudgetExceededText
        }
  gatheredResult <- ensureRequiredEvidence taskToolHost config plannerNotes gatheredInitial
  case gatheredResult of
    Left err -> pure (Left err)
    Right gathered -> do
      config.logosReportTaskBeforeAnalysis gathered.logosGatherTaskResultToolCallRecords >>= \case
        Left errText -> do
          TaskRuntime.emitError
            taskHost
            LogosStageDescriptor
              { logosStageAgentName = Just "Gatherer"
              , logosStageStageName = Just "pre_analysis_validation"
              , logosStageStep = Just 1
              , logosStageToolName = Nothing
              }
            "Evidence validation failed"
            (Just errText)
          pure (Left (mkFailure errText gathered.logosGatherTaskResultToolCallRecords))
        Right () -> do
          let analystInput =
                config.logosReportTaskBuildAnalystInput
                  plannerNotes
                  gathered.logosGatherTaskResultSummary
                  gathered.logosGatherTaskResultToolCallRecords
          analysisDraft <-
            TaskRuntime.runTextTask
              taskHost
              "report_analyst"
              config.logosReportTaskAnalystTimeoutClass
              config.logosReportTaskAnalystModelId
              GroundingDisabled
              "Analyst"
              (Just 1)
              config.logosReportTaskAnalystSystemPrompt
              analystInput
          let reviewerInput =
                config.logosReportTaskBuildReviewerInput
                  plannerNotes
                  gathered.logosGatherTaskResultSummary
                  analysisDraft
                  gathered.logosGatherTaskResultToolCallRecords
          reviewedDraft <-
            TaskRuntime.runTextTask
              taskHost
              "report_reviewer"
              config.logosReportTaskReviewerTimeoutClass
              config.logosReportTaskReviewerModelId
              GroundingDisabled
              "Reviewer"
              (Just 1)
              config.logosReportTaskReviewerSystemPrompt
              reviewerInput
          config.logosReportTaskFinalize reviewedDraft gathered.logosGatherTaskResultToolCallRecords >>= \case
            Left errText ->
              pure (Left (mkFailure errText gathered.logosGatherTaskResultToolCallRecords))
            Right artifact ->
              pure
                ( Right
                    LogosReportTaskResult
                      { logosReportTaskResultArtifact = artifact
                      , logosReportTaskResultToolCallRecords = gathered.logosGatherTaskResultToolCallRecords
                      }
                )
  where
    mkFailure errText toolCallRecords =
      LogosReportTaskFailure
        { logosReportTaskFailureText = errText
        , logosReportTaskFailureToolCallRecords = toolCallRecords
        }

ensureRequiredEvidence
  :: MonadIO m
  => TaskToolHost.LogosTaskToolHost m
  -> LogosReportTaskConfig m artifact
  -> Text
  -> LogosGatherTaskResult
  -> m (Either LogosReportTaskFailure LogosGatherTaskResult)
ensureRequiredEvidence taskToolHost config plannerNotes gathered =
  case missingRequiredTools
    config.logosReportTaskRequiredToolNames
    gathered.logosGatherTaskResultToolCallRecords of
    [] -> pure (Right gathered)
    missingTools -> do
      TaskRuntime.emitSummary
        taskHost
        (Just "Gatherer")
        (Just "required_evidence")
        (Just 1)
        "Missing required evidence"
        ( Just
            ("Repairing missing deterministic tools before analysis: " <> T.intercalate ", " missingTools <> ".")
        )
        (Just (Aeson.object ["missingTools" Aeson..= missingTools]))
      let repairTools = filterToolsByName missingTools config.logosReportTaskGatherTools
      repairResult <-
        runGatherRepairTask
          taskToolHost
          LogosGatherRepairTaskConfig
            { logosGatherRepairTaskModelId = config.logosReportTaskGatherModelId
            , logosGatherRepairTaskGroundingMode = config.logosReportTaskGatherGroundingMode
            , logosGatherRepairTaskSystemPrompt = config.logosReportTaskGatherSystemPrompt
            , logosGatherRepairTaskBuildInput =
                config.logosReportTaskBuildGatherRepairInput
                  plannerNotes
                  gathered.logosGatherTaskResultSummary
            , logosGatherRepairTaskTools = repairTools
            , logosGatherRepairTaskMissingToolNames = missingTools
            , logosGatherRepairTaskStageName = config.logosReportTaskGatherRepairStageName
            , logosGatherRepairTaskTimeoutClass = config.logosReportTaskGatherTimeoutClass
            , logosGatherRepairTaskMaxOutputTokens = Nothing
            , logosGatherRepairTaskMaxSteps =
                min
                  config.logosReportTaskGatherRepairMaxSteps
                  (max 1 (length missingTools))
            }
      let mergedGathered =
            LogosGatherTaskResult
              { logosGatherTaskResultSummary =
                  T.intercalate
                    "\n\n"
                    ( filter
                        (not . T.null . T.strip)
                        [ gathered.logosGatherTaskResultSummary
                        , repairResult.logosGatherTaskResultSummary
                        ]
                    )
              , logosGatherTaskResultToolCallRecords =
                  gathered.logosGatherTaskResultToolCallRecords
                    <> repairResult.logosGatherTaskResultToolCallRecords
              }
          stillMissing =
            missingRequiredTools
              config.logosReportTaskRequiredToolNames
              mergedGathered.logosGatherTaskResultToolCallRecords
      if null stillMissing
        then pure (Right mergedGathered)
        else do
          TaskRuntime.emitError
            taskHost
            LogosStageDescriptor
              { logosStageAgentName = Just "Gatherer"
              , logosStageStageName = Just "required_evidence"
              , logosStageStep = Just 1
              , logosStageToolName = Nothing
              }
            "Required evidence missing"
            (Just ("Missing required tools after repair pass: " <> T.intercalate ", " stillMissing <> "."))
          pure
            ( Left
                LogosReportTaskFailure
                  { logosReportTaskFailureText =
                      "Report gathering failed: missing required deterministic evidence after one repair pass: "
                        <> T.intercalate ", " stillMissing
                        <> "."
                  , logosReportTaskFailureToolCallRecords =
                      mergedGathered.logosGatherTaskResultToolCallRecords
                  }
            )
  where
    taskHost = TaskToolHost.taskToolHostBase taskToolHost

successfulToolResults :: Text -> [CortexToolCallRecord] -> [Aeson.Value]
successfulToolResults toolName toolCallRecords =
  [ record.cortexToolCallRecordResult
  | record <- toolCallRecords
  , record.cortexToolCallRecordName == toolName
  , toolCallResultStatus record.cortexToolCallRecordResult == CortexToolCallResultSuccess
  ]

filterToolsByName :: [Text] -> [Aeson.Value] -> [Aeson.Value]
filterToolsByName allowedNames =
  filter (maybe False (`elem` allowedNames) . toolDefinitionName)

isErrorText :: Text -> Bool
isErrorText = T.isPrefixOf "Error:" . T.strip
