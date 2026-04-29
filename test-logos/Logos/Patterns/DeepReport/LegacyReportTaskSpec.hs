{- |
Module      : Logos.Patterns.DeepReport.LegacyReportTaskSpec
Description : Tests for Logos.Patterns.DeepReport.LegacyReportTask.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Patterns.DeepReport.LegacyReportTaskSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Logos.Patterns.DeepReport.LegacyReportTask
  ( CortexToolCallResultStatus (..)
  , LogosReportTaskConfig (..)
  , LogosReportTaskFailure (..)
  , LogosReportTaskResult (..)
  , LogosRequiredToolEvidenceStatus (..)
  , missingRequiredTools
  , requiredToolEvidenceStatus
  , runReportTask
  , toolCallResultStatus
  )
import Logos.Thought.Host
  ( LogosTaskHost (..)
  )
import Logos.Thought.ToolHost
  ( LogosTaskToolHost (..)
  , LogosToolExecutionResult (..)
  )
import Test.Hspec

import Cortex.Capability.Model.Client
  ( CortexModelClient (..)
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexGroundingMode (..)
  , CortexToolCall (..)
  )
import Cortex.Capability.Tool.Record (CortexToolCallRecord (..))

spec :: Spec
spec = do
  describe "toolCallResultStatus" $ do
    it "treats structured tool errors as errors" $ do
      toolCallResultStatus
        (Aeson.object ["text" Aeson..= ("Error: Invalid portfolio ID: U16249659" :: Text)])
        `shouldBe` CortexToolCallResultError

    it "treats noData payloads as no_data" $ do
      toolCallResultStatus
        (Aeson.object ["noData" Aeson..= True, "message" Aeson..= ("No NAV history was found." :: Text)])
        `shouldBe` CortexToolCallResultNoData

  describe "missingRequiredTools" $ do
    it "keeps errors repairable but accepts deterministic noData evidence" $ do
      missingRequiredTools
        ["successTool", "noDataTool", "errorTool", "missingTool"]
        evidenceStatusRecords
        `shouldBe` ["errorTool", "missingTool"]

  describe "requiredToolEvidenceStatus" $ do
    it "distinguishes missing, success, no_data, and error evidence states" $ do
      requiredToolEvidenceStatus "missingTool" evidenceStatusRecords
        `shouldBe` LogosRequiredToolEvidenceMissing
      requiredToolEvidenceStatus "successTool" evidenceStatusRecords
        `shouldBe` LogosRequiredToolEvidenceSuccess
      requiredToolEvidenceStatus "noDataTool" evidenceStatusRecords
        `shouldBe` LogosRequiredToolEvidenceNoData
      requiredToolEvidenceStatus "errorTool" evidenceStatusRecords
        `shouldBe` LogosRequiredToolEvidenceError

  describe "runReportTask" $ do
    it "returns the finalized artifact on the happy path" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "planner-notes" []
          , mkChoice "gather-summary" []
          , mkChoice "analysis-draft" []
          , mkChoice "reviewed-draft" []
          ]
      seenRequests <- newIORef []
      finalizeInputs <- newIORef []

      result <-
        runReportTask
          (mkTaskToolHost queuedChoices seenRequests (\_ _ -> error "success path should not execute tools"))
          sampleReportTaskConfig
            { logosReportTaskFinalize = \reviewedDraft toolCallRecords -> do
                writeIORef finalizeInputs [(reviewedDraft, fmap (.cortexToolCallRecordName) toolCallRecords)]
                pure (Right ("compiled-artifact" :: Text))
            }

      result
        `shouldBe` Right
          LogosReportTaskResult
            { logosReportTaskResultArtifact = "compiled-artifact"
            , logosReportTaskResultToolCallRecords = []
            }
      readIORef finalizeInputs `shouldReturn` [("reviewed-draft", [])]
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStageName) requests
        `shouldBe` ["report_planner", "report_gatherer", "report_analyst", "report_reviewer"]

    it "repairs missing required evidence before finalization" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "planner-notes" []
          , mkChoice "initial gather summary" []
          , mkChoice "" [sampleToolCall "requiredTool"]
          , mkChoice "analysis-draft" []
          , mkChoice "reviewed-draft" []
          ]
      seenRequests <- newIORef []
      toolSteps <- newIORef []
      finalizeInputs <- newIORef []

      result <-
        runReportTask
          ( mkTaskToolHost
              queuedChoices
              seenRequests
              ( \stepNumber toolCalls -> do
                  modifyIORef' toolSteps (<> [(stepNumber, fmap (.cortexToolCallName) toolCalls)])
                  pure
                    LogosToolExecutionResult
                      { logosToolExecutionMessages = []
                      , logosToolExecutionRecords = [sampleToolCallRecord "requiredTool"]
                      , logosToolExecutionTerminalError = Nothing
                      }
              )
          )
          sampleReportTaskConfig
            { logosReportTaskRequiredToolNames = ["requiredTool"]
            , logosReportTaskGatherTools = sampleToolDefinitions
            , logosReportTaskGatherRepairMaxSteps = 5
            , logosReportTaskFinalize = \reviewedDraft toolCallRecords -> do
                writeIORef finalizeInputs [(reviewedDraft, fmap (.cortexToolCallRecordName) toolCallRecords)]
                pure (Right ("compiled-artifact" :: Text))
            }

      result
        `shouldBe` Right
          LogosReportTaskResult
            { logosReportTaskResultArtifact = "compiled-artifact"
            , logosReportTaskResultToolCallRecords = [sampleToolCallRecord "requiredTool"]
            }
      readIORef toolSteps `shouldReturn` [(1, ["requiredTool"])]
      readIORef finalizeInputs `shouldReturn` [("reviewed-draft", ["requiredTool"])]

    it "propagates beforeAnalysis failures without running later phases" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "planner-notes" []
          , mkChoice "gather-summary" []
          ]
      seenRequests <- newIORef []

      result <-
        ( runReportTask
            ( mkTaskToolHost
                queuedChoices
                seenRequests
                (\_ _ -> error "beforeAnalysis failure should not execute tools")
            )
            sampleReportTaskConfig
              { logosReportTaskBeforeAnalysis = \_ -> pure (Left "missing canonical evidence")
              , logosReportTaskFinalize = \_ _ -> error "beforeAnalysis failure should not finalize"
              }
            :: IO (Either LogosReportTaskFailure (LogosReportTaskResult Text))
        )

      result
        `shouldBe` Left
          LogosReportTaskFailure
            { logosReportTaskFailureText = "missing canonical evidence"
            , logosReportTaskFailureToolCallRecords = []
            }
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStageName) requests
        `shouldBe` ["report_planner", "report_gatherer"]

    it "propagates finalize failures after reviewer output" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "planner-notes" []
          , mkChoice "gather-summary" []
          , mkChoice "analysis-draft" []
          , mkChoice "reviewed-draft" []
          ]
      seenRequests <- newIORef []

      result <-
        ( runReportTask
            ( mkTaskToolHost
                queuedChoices
                seenRequests
                (\_ _ -> error "finalize failure should not execute tools")
            )
            sampleReportTaskConfig
              { logosReportTaskFinalize = \_ _ -> pure (Left "finalization failed")
              }
            :: IO (Either LogosReportTaskFailure (LogosReportTaskResult Text))
        )

      result
        `shouldBe` Left
          LogosReportTaskFailure
            { logosReportTaskFailureText = "finalization failed"
            , logosReportTaskFailureToolCallRecords = []
            }
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStageName) requests
        `shouldBe` ["report_planner", "report_gatherer", "report_analyst", "report_reviewer"]

evidenceStatusRecords :: [CortexToolCallRecord]
evidenceStatusRecords =
  [ mkToolCallRecord "successTool" $
      Aeson.object
        [ "value" Aeson..= (42 :: Int)
        ]
  , mkToolCallRecord "noDataTool" $
      Aeson.object
        [ "noData" Aeson..= True
        , "message" Aeson..= ("No rows matched." :: Text)
        ]
  , mkToolCallRecord "errorTool" $
      Aeson.object
        [ "error" Aeson..= True
        , "message" Aeson..= ("Upstream failure." :: Text)
        ]
  ]

mkToolCallRecord :: Text -> Aeson.Value -> CortexToolCallRecord
mkToolCallRecord toolName resultValue =
  CortexToolCallRecord
    { cortexToolCallRecordId = toolName <> "-id"
    , cortexToolCallRecordName = toolName
    , cortexToolCallRecordArgs = Aeson.object []
    , cortexToolCallRecordResult = resultValue
    , cortexToolCallRecordTimestamp = sampleTime
    , cortexToolCallRecordDuration = 0
    }

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 0)

sampleReportTaskConfig :: LogosReportTaskConfig IO Text
sampleReportTaskConfig =
  LogosReportTaskConfig
    { logosReportTaskPlannerModelId = "anthropic/claude-sonnet-4.6"
    , logosReportTaskPlannerSystemPrompt = "planner-system"
    , logosReportTaskPlannerInput = "planner-input"
    , logosReportTaskPlannerTimeoutClass = CortexChoiceTimeoutStandard
    , logosReportTaskGatherModelId = "anthropic/claude-sonnet-4.6"
    , logosReportTaskGatherGroundingMode = GroundingDisabled
    , logosReportTaskGatherSystemPrompt = "gather-system"
    , logosReportTaskBuildGatherInput = ("gather-input:" <>)
    , logosReportTaskGatherTools = []
    , logosReportTaskGatherStageName = "report_gatherer"
    , logosReportTaskGatherTimeoutClass = CortexChoiceTimeoutHeavy
    , logosReportTaskGatherStepBudget = 3
    , logosReportTaskGatherBudgetExceededText = "Gatherer reached its step budget."
    , logosReportTaskRequiredToolNames = []
    , logosReportTaskBuildGatherRepairInput = \plannerNotes gatheredSummary attemptNumber toolNames ->
        "repair-input:"
          <> plannerNotes
          <> ":"
          <> gatheredSummary
          <> ":"
          <> showText attemptNumber
          <> ":"
          <> showText toolNames
    , logosReportTaskGatherRepairStageName = "report_gatherer_repair"
    , logosReportTaskGatherRepairMaxSteps = 2
    , logosReportTaskAnalystModelId = "anthropic/claude-sonnet-4.6"
    , logosReportTaskAnalystSystemPrompt = "analyst-system"
    , logosReportTaskBuildAnalystInput = \plannerNotes gatheredSummary _ ->
        "analyst-input:" <> plannerNotes <> ":" <> gatheredSummary
    , logosReportTaskAnalystTimeoutClass = CortexChoiceTimeoutHeavy
    , logosReportTaskReviewerModelId = "anthropic/claude-sonnet-4.6"
    , logosReportTaskReviewerSystemPrompt = "reviewer-system"
    , logosReportTaskBuildReviewerInput = \plannerNotes gatheredSummary analysisDraft _ ->
        "reviewer-input:" <> plannerNotes <> ":" <> gatheredSummary <> ":" <> analysisDraft
    , logosReportTaskReviewerTimeoutClass = CortexChoiceTimeoutHeavy
    , logosReportTaskBeforeAnalysis = \_ -> pure (Right ())
    , logosReportTaskFinalize = \_ _ -> pure (Right "compiled-artifact")
    }

sampleToolDefinitions :: [Aeson.Value]
sampleToolDefinitions =
  fmap
    (\toolName -> Aeson.object ["function" Aeson..= Aeson.object ["name" Aeson..= toolName]])
    ["requiredTool" :: Text]

mkTaskToolHost
  :: IORef [CortexChoice]
  -> IORef [CortexChoiceRequest]
  -> (Int -> [CortexToolCall] -> IO LogosToolExecutionResult)
  -> LogosTaskToolHost IO
mkTaskToolHost queuedChoices seenRequests executeTools =
  LogosTaskToolHost
    { logosTaskToolHostTaskHost =
        LogosTaskHost
          { logosTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in ReportSpec."
                      (choice : rest) -> writeIORef queuedChoices rest >> pure choice
                }
          , logosTaskThrowIfCanceled = pure ()
          , logosTaskEmitEvent = \_ -> pure ()
          }
    , logosTaskToolHostExecuteToolCalls = executeTools
    }

mkChoice :: Text -> [CortexToolCall] -> CortexChoice
mkChoice content toolCalls =
  CortexChoice
    { cortexChoiceContent = content
    , cortexChoiceSourceLinks = []
    , cortexChoiceToolCalls = toolCalls
    , cortexChoiceFinishReason = Nothing
    , cortexChoiceUsage = Nothing
    , cortexChoiceReasoning = Nothing
    , cortexChoiceReasoningDetails = Nothing
    }

sampleToolCall :: Text -> CortexToolCall
sampleToolCall toolName =
  CortexToolCall
    { cortexToolCallId = "call-1"
    , cortexToolCallName = toolName
    , cortexToolCallArguments = "{\"ticker\":\"AMD\"}"
    }

sampleToolCallRecord :: Text -> CortexToolCallRecord
sampleToolCallRecord toolName =
  CortexToolCallRecord
    { cortexToolCallRecordId = "call-1"
    , cortexToolCallRecordName = toolName
    , cortexToolCallRecordArgs = Aeson.object ["ticker" Aeson..= ("AMD" :: Text)]
    , cortexToolCallRecordResult =
        Aeson.object ["rows" Aeson..= [Aeson.object ["headline" Aeson..= ("AMD launch" :: Text)]]]
    , cortexToolCallRecordTimestamp = sampleTime
    , cortexToolCallRecordDuration = 150
    }

showText :: Show a => a -> Text
showText = T.pack . show
