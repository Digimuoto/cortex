{- |
Module      : Cortex.Nous.Patterns.DeepReport.LegacyReportTaskSpec
Description : Tests for Cortex.Nous.Patterns.DeepReport.LegacyReportTask.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Nous.Patterns.DeepReport.LegacyReportTaskSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
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
import Cortex.Nous.Patterns.DeepReport.LegacyReportTask
  ( CortexReportTaskConfig (..)
  , CortexReportTaskFailure (..)
  , CortexReportTaskResult (..)
  , CortexRequiredToolEvidenceStatus (..)
  , CortexToolCallResultStatus (..)
  , missingRequiredTools
  , requiredToolEvidenceStatus
  , runReportTask
  , toolCallResultStatus
  )
import Cortex.Nous.Thought.Host
  ( CortexTaskHost (..)
  )
import Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost (..)
  , CortexToolExecutionResult (..)
  )

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
        `shouldBe` CortexRequiredToolEvidenceMissing
      requiredToolEvidenceStatus "successTool" evidenceStatusRecords
        `shouldBe` CortexRequiredToolEvidenceSuccess
      requiredToolEvidenceStatus "noDataTool" evidenceStatusRecords
        `shouldBe` CortexRequiredToolEvidenceNoData
      requiredToolEvidenceStatus "errorTool" evidenceStatusRecords
        `shouldBe` CortexRequiredToolEvidenceError

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
            { cortexReportTaskFinalize = \reviewedDraft toolCallRecords -> do
                writeIORef finalizeInputs [(reviewedDraft, fmap (.cortexToolCallRecordName) toolCallRecords)]
                pure (Right ("compiled-artifact" :: Text))
            }

      result
        `shouldBe` Right
          CortexReportTaskResult
            { cortexReportTaskResultArtifact = "compiled-artifact"
            , cortexReportTaskResultToolCallRecords = []
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
                    CortexToolExecutionResult
                      { cortexToolExecutionMessages = []
                      , cortexToolExecutionRecords = [sampleToolCallRecord "requiredTool"]
                      , cortexToolExecutionTerminalError = Nothing
                      }
              )
          )
          sampleReportTaskConfig
            { cortexReportTaskRequiredToolNames = ["requiredTool"]
            , cortexReportTaskGatherTools = sampleToolDefinitions
            , cortexReportTaskGatherRepairMaxSteps = 5
            , cortexReportTaskFinalize = \reviewedDraft toolCallRecords -> do
                writeIORef finalizeInputs [(reviewedDraft, fmap (.cortexToolCallRecordName) toolCallRecords)]
                pure (Right ("compiled-artifact" :: Text))
            }

      result
        `shouldBe` Right
          CortexReportTaskResult
            { cortexReportTaskResultArtifact = "compiled-artifact"
            , cortexReportTaskResultToolCallRecords = [sampleToolCallRecord "requiredTool"]
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
              { cortexReportTaskBeforeAnalysis = \_ -> pure (Left "missing canonical evidence")
              , cortexReportTaskFinalize = \_ _ -> error "beforeAnalysis failure should not finalize"
              }
            :: IO (Either CortexReportTaskFailure (CortexReportTaskResult Text))
        )

      result
        `shouldBe` Left
          CortexReportTaskFailure
            { cortexReportTaskFailureText = "missing canonical evidence"
            , cortexReportTaskFailureToolCallRecords = []
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
              { cortexReportTaskFinalize = \_ _ -> pure (Left "finalization failed")
              }
            :: IO (Either CortexReportTaskFailure (CortexReportTaskResult Text))
        )

      result
        `shouldBe` Left
          CortexReportTaskFailure
            { cortexReportTaskFailureText = "finalization failed"
            , cortexReportTaskFailureToolCallRecords = []
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

sampleReportTaskConfig :: CortexReportTaskConfig IO Text
sampleReportTaskConfig =
  CortexReportTaskConfig
    { cortexReportTaskPlannerModelId = "anthropic/claude-sonnet-4.6"
    , cortexReportTaskPlannerSystemPrompt = "planner-system"
    , cortexReportTaskPlannerInput = "planner-input"
    , cortexReportTaskPlannerTimeoutClass = CortexChoiceTimeoutStandard
    , cortexReportTaskGatherModelId = "anthropic/claude-sonnet-4.6"
    , cortexReportTaskGatherGroundingMode = GroundingDisabled
    , cortexReportTaskGatherSystemPrompt = "gather-system"
    , cortexReportTaskBuildGatherInput = ("gather-input:" <>)
    , cortexReportTaskGatherTools = []
    , cortexReportTaskGatherStageName = "report_gatherer"
    , cortexReportTaskGatherTimeoutClass = CortexChoiceTimeoutHeavy
    , cortexReportTaskGatherStepBudget = 3
    , cortexReportTaskGatherBudgetExceededText = "Gatherer reached its step budget."
    , cortexReportTaskRequiredToolNames = []
    , cortexReportTaskBuildGatherRepairInput = \plannerNotes gatheredSummary attemptNumber toolNames ->
        "repair-input:"
          <> plannerNotes
          <> ":"
          <> gatheredSummary
          <> ":"
          <> showText attemptNumber
          <> ":"
          <> showText toolNames
    , cortexReportTaskGatherRepairStageName = "report_gatherer_repair"
    , cortexReportTaskGatherRepairMaxSteps = 2
    , cortexReportTaskAnalystModelId = "anthropic/claude-sonnet-4.6"
    , cortexReportTaskAnalystSystemPrompt = "analyst-system"
    , cortexReportTaskBuildAnalystInput = \plannerNotes gatheredSummary _ ->
        "analyst-input:" <> plannerNotes <> ":" <> gatheredSummary
    , cortexReportTaskAnalystTimeoutClass = CortexChoiceTimeoutHeavy
    , cortexReportTaskReviewerModelId = "anthropic/claude-sonnet-4.6"
    , cortexReportTaskReviewerSystemPrompt = "reviewer-system"
    , cortexReportTaskBuildReviewerInput = \plannerNotes gatheredSummary analysisDraft _ ->
        "reviewer-input:" <> plannerNotes <> ":" <> gatheredSummary <> ":" <> analysisDraft
    , cortexReportTaskReviewerTimeoutClass = CortexChoiceTimeoutHeavy
    , cortexReportTaskBeforeAnalysis = \_ -> pure (Right ())
    , cortexReportTaskFinalize = \_ _ -> pure (Right "compiled-artifact")
    }

sampleToolDefinitions :: [Aeson.Value]
sampleToolDefinitions =
  fmap
    (\toolName -> Aeson.object ["function" Aeson..= Aeson.object ["name" Aeson..= toolName]])
    ["requiredTool" :: Text]

mkTaskToolHost
  :: IORef [CortexChoice]
  -> IORef [CortexChoiceRequest]
  -> (Int -> [CortexToolCall] -> IO CortexToolExecutionResult)
  -> CortexTaskToolHost IO
mkTaskToolHost queuedChoices seenRequests executeTools =
  CortexTaskToolHost
    { cortexTaskToolHostTaskHost =
        CortexTaskHost
          { cortexTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in ReportSpec."
                      (choice : rest) -> writeIORef queuedChoices rest >> pure choice
                }
          , cortexTaskThrowIfCanceled = pure ()
          , cortexTaskEmitEvent = \_ -> pure ()
          }
    , cortexTaskToolHostExecuteToolCalls = executeTools
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
