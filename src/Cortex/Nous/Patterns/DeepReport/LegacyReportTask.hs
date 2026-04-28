{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Patterns.DeepReport.LegacyReportTask
  ( CortexReportTaskConfig (..)
  , CortexReportTaskFailure (..)
  , CortexReportTaskResult (..)
  , CortexRequiredToolEvidenceStatus (..)
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

import Cortex.Capability.Model.Types
  ( CortexChoiceTimeoutClass
  , CortexGroundingMode (..)
  )
import Cortex.Capability.Tool.Definition (toolDefinitionName)
import Cortex.Capability.Tool.Record (CortexToolCallRecord (..))
import Cortex.Nous.Patterns.DeepReport.Gather
  ( CortexGatherRepairTaskConfig (..)
  , CortexGatherTaskConfig (..)
  , CortexGatherTaskResult (..)
  , runGatherRepairTask
  , runGatherTask
  )
import Cortex.Nous.Thought.Runtime qualified as TaskRuntime
import Cortex.Nous.Thought.Stage (CortexStageDescriptor (..))
import Cortex.Nous.Thought.ToolHost qualified as TaskToolHost

import Platform.Serde.Json.Object
  ( hasObjectBool
  , lookupObjectText
  )

data CortexToolCallResultStatus
  = CortexToolCallResultSuccess
  | CortexToolCallResultNoData
  | CortexToolCallResultError
  deriving stock (Eq, Show)

data CortexRequiredToolEvidenceStatus
  = CortexRequiredToolEvidenceMissing
  | CortexRequiredToolEvidenceSuccess
  | CortexRequiredToolEvidenceNoData
  | CortexRequiredToolEvidenceError
  deriving stock (Eq, Show)

data CortexReportTaskFailure = CortexReportTaskFailure
  { cortexReportTaskFailureText :: Text
  , cortexReportTaskFailureToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

data CortexReportTaskResult artifact = CortexReportTaskResult
  { cortexReportTaskResultArtifact :: artifact
  , cortexReportTaskResultToolCallRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

data CortexReportTaskConfig m artifact = CortexReportTaskConfig
  { cortexReportTaskPlannerModelId :: Text
  , cortexReportTaskPlannerSystemPrompt :: Text
  , cortexReportTaskPlannerInput :: Text
  , cortexReportTaskPlannerTimeoutClass :: CortexChoiceTimeoutClass
  , cortexReportTaskGatherModelId :: Text
  , cortexReportTaskGatherGroundingMode :: CortexGroundingMode
  , cortexReportTaskGatherSystemPrompt :: Text
  , cortexReportTaskBuildGatherInput :: Text -> Text
  , cortexReportTaskGatherTools :: [Aeson.Value]
  , cortexReportTaskGatherStageName :: Text
  , cortexReportTaskGatherTimeoutClass :: CortexChoiceTimeoutClass
  , cortexReportTaskGatherStepBudget :: Int
  , cortexReportTaskGatherBudgetExceededText :: Text
  , cortexReportTaskRequiredToolNames :: [Text]
  , cortexReportTaskBuildGatherRepairInput :: Text -> Text -> Int -> [Text] -> Text
  , cortexReportTaskGatherRepairStageName :: Text
  , cortexReportTaskGatherRepairMaxSteps :: Int
  , cortexReportTaskAnalystModelId :: Text
  , cortexReportTaskAnalystSystemPrompt :: Text
  , cortexReportTaskBuildAnalystInput :: Text -> Text -> [CortexToolCallRecord] -> Text
  , cortexReportTaskAnalystTimeoutClass :: CortexChoiceTimeoutClass
  , cortexReportTaskReviewerModelId :: Text
  , cortexReportTaskReviewerSystemPrompt :: Text
  , cortexReportTaskBuildReviewerInput :: Text -> Text -> Text -> [CortexToolCallRecord] -> Text
  , cortexReportTaskReviewerTimeoutClass :: CortexChoiceTimeoutClass
  , cortexReportTaskBeforeAnalysis :: [CortexToolCallRecord] -> m (Either Text ())
  , cortexReportTaskFinalize :: Text -> [CortexToolCallRecord] -> m (Either Text artifact)
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
  requiredToolEvidenceStatus toolName toolCallRecords == CortexRequiredToolEvidenceSuccess

requiredToolEvidenceStatus :: Text -> [CortexToolCallRecord] -> CortexRequiredToolEvidenceStatus
requiredToolEvidenceStatus toolName toolCallRecords =
  case matchingRecords of
    [] -> CortexRequiredToolEvidenceMissing
    _
      | any
          ( (== CortexToolCallResultSuccess)
              . toolCallResultStatus
              . (.cortexToolCallRecordResult)
          )
          matchingRecords ->
          CortexRequiredToolEvidenceSuccess
    _
      | any
          ( (== CortexToolCallResultNoData)
              . toolCallResultStatus
              . (.cortexToolCallRecordResult)
          )
          matchingRecords ->
          CortexRequiredToolEvidenceNoData
    _ -> CortexRequiredToolEvidenceError
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
        CortexRequiredToolEvidenceMissing -> True
        CortexRequiredToolEvidenceError -> True
        CortexRequiredToolEvidenceSuccess -> False
        CortexRequiredToolEvidenceNoData -> False

runReportTask
  :: MonadIO m
  => TaskToolHost.CortexTaskToolHost m
  -> CortexReportTaskConfig m artifact
  -> m (Either CortexReportTaskFailure (CortexReportTaskResult artifact))
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
      config.cortexReportTaskPlannerTimeoutClass
      config.cortexReportTaskPlannerModelId
      GroundingDisabled
      "Planner"
      Nothing
      config.cortexReportTaskPlannerSystemPrompt
      config.cortexReportTaskPlannerInput
  gatheredInitial <-
    runGatherTask
      taskToolHost
      CortexGatherTaskConfig
        { cortexGatherTaskModelId = config.cortexReportTaskGatherModelId
        , cortexGatherTaskGroundingMode = config.cortexReportTaskGatherGroundingMode
        , cortexGatherTaskSystemPrompt = config.cortexReportTaskGatherSystemPrompt
        , cortexGatherTaskUserInput = config.cortexReportTaskBuildGatherInput plannerNotes
        , cortexGatherTaskTools = config.cortexReportTaskGatherTools
        , cortexGatherTaskStageName = config.cortexReportTaskGatherStageName
        , cortexGatherTaskTimeoutClass = config.cortexReportTaskGatherTimeoutClass
        , cortexGatherTaskMaxOutputTokens = Nothing
        , cortexGatherTaskStepBudget = config.cortexReportTaskGatherStepBudget
        , cortexGatherTaskBudgetExceededText = config.cortexReportTaskGatherBudgetExceededText
        }
  gatheredResult <- ensureRequiredEvidence taskToolHost config plannerNotes gatheredInitial
  case gatheredResult of
    Left err -> pure (Left err)
    Right gathered -> do
      config.cortexReportTaskBeforeAnalysis gathered.cortexGatherTaskResultToolCallRecords >>= \case
        Left errText -> do
          TaskRuntime.emitError
            taskHost
            CortexStageDescriptor
              { cortexStageAgentName = Just "Gatherer"
              , cortexStageStageName = Just "pre_analysis_validation"
              , cortexStageStep = Just 1
              , cortexStageToolName = Nothing
              }
            "Evidence validation failed"
            (Just errText)
          pure (Left (mkFailure errText gathered.cortexGatherTaskResultToolCallRecords))
        Right () -> do
          let analystInput =
                config.cortexReportTaskBuildAnalystInput
                  plannerNotes
                  gathered.cortexGatherTaskResultSummary
                  gathered.cortexGatherTaskResultToolCallRecords
          analysisDraft <-
            TaskRuntime.runTextTask
              taskHost
              "report_analyst"
              config.cortexReportTaskAnalystTimeoutClass
              config.cortexReportTaskAnalystModelId
              GroundingDisabled
              "Analyst"
              (Just 1)
              config.cortexReportTaskAnalystSystemPrompt
              analystInput
          let reviewerInput =
                config.cortexReportTaskBuildReviewerInput
                  plannerNotes
                  gathered.cortexGatherTaskResultSummary
                  analysisDraft
                  gathered.cortexGatherTaskResultToolCallRecords
          reviewedDraft <-
            TaskRuntime.runTextTask
              taskHost
              "report_reviewer"
              config.cortexReportTaskReviewerTimeoutClass
              config.cortexReportTaskReviewerModelId
              GroundingDisabled
              "Reviewer"
              (Just 1)
              config.cortexReportTaskReviewerSystemPrompt
              reviewerInput
          config.cortexReportTaskFinalize reviewedDraft gathered.cortexGatherTaskResultToolCallRecords >>= \case
            Left errText ->
              pure (Left (mkFailure errText gathered.cortexGatherTaskResultToolCallRecords))
            Right artifact ->
              pure
                ( Right
                    CortexReportTaskResult
                      { cortexReportTaskResultArtifact = artifact
                      , cortexReportTaskResultToolCallRecords = gathered.cortexGatherTaskResultToolCallRecords
                      }
                )
  where
    mkFailure errText toolCallRecords =
      CortexReportTaskFailure
        { cortexReportTaskFailureText = errText
        , cortexReportTaskFailureToolCallRecords = toolCallRecords
        }

ensureRequiredEvidence
  :: MonadIO m
  => TaskToolHost.CortexTaskToolHost m
  -> CortexReportTaskConfig m artifact
  -> Text
  -> CortexGatherTaskResult
  -> m (Either CortexReportTaskFailure CortexGatherTaskResult)
ensureRequiredEvidence taskToolHost config plannerNotes gathered =
  case missingRequiredTools
    config.cortexReportTaskRequiredToolNames
    gathered.cortexGatherTaskResultToolCallRecords of
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
      let repairTools = filterToolsByName missingTools config.cortexReportTaskGatherTools
      repairResult <-
        runGatherRepairTask
          taskToolHost
          CortexGatherRepairTaskConfig
            { cortexGatherRepairTaskModelId = config.cortexReportTaskGatherModelId
            , cortexGatherRepairTaskGroundingMode = config.cortexReportTaskGatherGroundingMode
            , cortexGatherRepairTaskSystemPrompt = config.cortexReportTaskGatherSystemPrompt
            , cortexGatherRepairTaskBuildInput =
                config.cortexReportTaskBuildGatherRepairInput
                  plannerNotes
                  gathered.cortexGatherTaskResultSummary
            , cortexGatherRepairTaskTools = repairTools
            , cortexGatherRepairTaskMissingToolNames = missingTools
            , cortexGatherRepairTaskStageName = config.cortexReportTaskGatherRepairStageName
            , cortexGatherRepairTaskTimeoutClass = config.cortexReportTaskGatherTimeoutClass
            , cortexGatherRepairTaskMaxOutputTokens = Nothing
            , cortexGatherRepairTaskMaxSteps =
                min
                  config.cortexReportTaskGatherRepairMaxSteps
                  (max 1 (length missingTools))
            }
      let mergedGathered =
            CortexGatherTaskResult
              { cortexGatherTaskResultSummary =
                  T.intercalate
                    "\n\n"
                    ( filter
                        (not . T.null . T.strip)
                        [ gathered.cortexGatherTaskResultSummary
                        , repairResult.cortexGatherTaskResultSummary
                        ]
                    )
              , cortexGatherTaskResultToolCallRecords =
                  gathered.cortexGatherTaskResultToolCallRecords
                    <> repairResult.cortexGatherTaskResultToolCallRecords
              }
          stillMissing =
            missingRequiredTools
              config.cortexReportTaskRequiredToolNames
              mergedGathered.cortexGatherTaskResultToolCallRecords
      if null stillMissing
        then pure (Right mergedGathered)
        else do
          TaskRuntime.emitError
            taskHost
            CortexStageDescriptor
              { cortexStageAgentName = Just "Gatherer"
              , cortexStageStageName = Just "required_evidence"
              , cortexStageStep = Just 1
              , cortexStageToolName = Nothing
              }
            "Required evidence missing"
            (Just ("Missing required tools after repair pass: " <> T.intercalate ", " stillMissing <> "."))
          pure
            ( Left
                CortexReportTaskFailure
                  { cortexReportTaskFailureText =
                      "Report gathering failed: missing required deterministic evidence after one repair pass: "
                        <> T.intercalate ", " stillMissing
                        <> "."
                  , cortexReportTaskFailureToolCallRecords =
                      mergedGathered.cortexGatherTaskResultToolCallRecords
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
