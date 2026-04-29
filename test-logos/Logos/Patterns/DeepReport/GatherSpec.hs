{- |
Module      : Logos.Patterns.DeepReport.GatherSpec
Description : Tests for Logos.Patterns.DeepReport.Gather.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Patterns.DeepReport.GatherSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Logos.Patterns.DeepReport.Gather
  ( LogosGatherRepairTaskConfig (..)
  , LogosGatherTaskConfig (..)
  , LogosGatherTaskResult (..)
  , runGatherRepairTask
  , runGatherTask
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
import Cortex.Capability.Model.Message
  ( assistantToolCallsMessage
  , systemMessage
  , toolMessage
  , userTextMessage
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexGroundingMode (..)
  , CortexToolCall (..)
  )
import Cortex.Capability.Tool.Definition (toolDefinitionName)
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..)
  )

spec :: Spec
spec = do
  describe "runGatherTask" $ do
    it "runs the gather tool loop and returns the final summary with tool records" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Need deterministic evidence." [sampleToolCall "getAssetNews"]
          , mkChoice "AMD still looks constructive." []
          ]
      seenRequests <- newIORef []
      let toolExecutionResult =
            LogosToolExecutionResult
              { logosToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."]
              , logosToolExecutionRecords = [sampleToolCallRecord "getAssetNews"]
              , logosToolExecutionTerminalError = Nothing
              }
      result <-
        runGatherTask
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleGatherTaskConfig

      result
        `shouldBe` LogosGatherTaskResult
          { logosGatherTaskResultSummary = "AMD still looks constructive."
          , logosGatherTaskResultToolCallRecords = [sampleToolCallRecord "getAssetNews"]
          }
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStepIndex) requests `shouldBe` [Just 1, Just 2]
      fmap (.cortexChoiceMessages) requests
        `shouldBe` [ [systemMessage "gather-system", userTextMessage "gather-input"]
                   ,
                     [ systemMessage "gather-system"
                     , userTextMessage "gather-input"
                     , assistantToolCallsMessage "Need deterministic evidence." [sampleToolCall "getAssetNews"]
                     , toolMessage "call-1" "getAssetNews" compactToolPreviewText
                     ]
                   ]

  describe "runGatherRepairTask" $ do
    it "returns the model summary unchanged when no repair tool call is produced" $ do
      queuedChoices <- newIORef [mkChoice "No deterministic repair needed." []]
      seenRequests <- newIORef []

      result <-
        runGatherRepairTask
          (mkToolHost queuedChoices seenRequests (\_ _ -> error "repair task should not execute tools"))
          sampleGatherRepairTaskConfig
            { logosGatherRepairTaskMissingToolNames = ["getNav"]
            , logosGatherRepairTaskMaxSteps = 1
            }

      result
        `shouldBe` LogosGatherTaskResult
          { logosGatherTaskResultSummary = "No deterministic repair needed."
          , logosGatherTaskResultToolCallRecords = []
          }

    it "narrows the allowed repair tools to the remaining missing set across attempts" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "" [sampleToolCall "getNav"]
          , mkChoice "" [sampleToolCall "getPortfolioSummary"]
          ]
      seenRequests <- newIORef []
      toolSteps <- newIORef []

      let executeTools stepNumber toolCalls = do
            modifyIORef' toolSteps (<> [(stepNumber, fmap (.cortexToolCallName) toolCalls)])
            pure
              LogosToolExecutionResult
                { logosToolExecutionMessages =
                    fmap (\call -> toolMessage call.cortexToolCallId call.cortexToolCallName "repair-result") toolCalls
                , logosToolExecutionRecords = fmap (sampleToolCallRecord . (.cortexToolCallName)) toolCalls
                , logosToolExecutionTerminalError = Nothing
                }

      result <-
        runGatherRepairTask
          (mkToolHost queuedChoices seenRequests executeTools)
          sampleGatherRepairTaskConfig
            { logosGatherRepairTaskMissingToolNames = ["getNav", "getPortfolioSummary"]
            , logosGatherRepairTaskMaxSteps = 2
            }

      fmap (.cortexToolCallRecordName) result.logosGatherTaskResultToolCallRecords
        `shouldBe` ["getNav", "getPortfolioSummary"]
      readIORef toolSteps `shouldReturn` [(1, ["getNav"]), (2, ["getPortfolioSummary"])]
      requests <- readIORef seenRequests
      fmap (mapMaybe toolDefinitionName . (.cortexChoiceTools)) requests
        `shouldBe` [ ["getNav", "getPortfolioSummary"]
                   , ["getPortfolioSummary"]
                   ]

sampleGatherTaskConfig :: LogosGatherTaskConfig
sampleGatherTaskConfig =
  LogosGatherTaskConfig
    { logosGatherTaskModelId = "anthropic/claude-sonnet-4.6"
    , logosGatherTaskGroundingMode = GroundingDisabled
    , logosGatherTaskSystemPrompt = "gather-system"
    , logosGatherTaskUserInput = "gather-input"
    , logosGatherTaskTools = sampleToolDefinitions
    , logosGatherTaskStageName = "report_gatherer"
    , logosGatherTaskTimeoutClass = CortexChoiceTimeoutHeavy
    , logosGatherTaskMaxOutputTokens = Nothing
    , logosGatherTaskStepBudget = 3
    , logosGatherTaskBudgetExceededText = "Gatherer reached its step budget."
    }

sampleGatherRepairTaskConfig :: LogosGatherRepairTaskConfig
sampleGatherRepairTaskConfig =
  LogosGatherRepairTaskConfig
    { logosGatherRepairTaskModelId = "anthropic/claude-sonnet-4.6"
    , logosGatherRepairTaskGroundingMode = GroundingDisabled
    , logosGatherRepairTaskSystemPrompt = "repair-system"
    , logosGatherRepairTaskBuildInput = \attemptNumber toolNames ->
        "repair-input:" <> showText attemptNumber <> ":" <> T.intercalate "," toolNames
    , logosGatherRepairTaskTools = sampleToolDefinitions
    , logosGatherRepairTaskMissingToolNames = []
    , logosGatherRepairTaskStageName = "report_gatherer_repair"
    , logosGatherRepairTaskTimeoutClass = CortexChoiceTimeoutHeavy
    , logosGatherRepairTaskMaxOutputTokens = Nothing
    , logosGatherRepairTaskMaxSteps = 1
    }

sampleToolDefinitions :: [Aeson.Value]
sampleToolDefinitions =
  fmap
    (\toolName -> Aeson.object ["function" Aeson..= Aeson.object ["name" Aeson..= toolName]])
    ["getAssetNews" :: Text, "getNav", "getPortfolioSummary"]

mkToolHost
  :: IORef [CortexChoice]
  -> IORef [CortexChoiceRequest]
  -> (Int -> [CortexToolCall] -> IO LogosToolExecutionResult)
  -> LogosTaskToolHost IO
mkToolHost queuedChoices seenRequests executeTools =
  LogosTaskToolHost
    { logosTaskToolHostTaskHost =
        LogosTaskHost
          { logosTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in GatherSpec."
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
    , cortexToolCallRecordTimestamp = fixedNow
    , cortexToolCallRecordDuration = 150
    }

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 3 21) (secondsToDiffTime 0)

showText :: Show a => a -> Text
showText = T.pack . show

compactToolPreviewText :: Text
compactToolPreviewText =
  T.unlines
    [ "Tool result preview (compact, not full raw payload)."
    , "retrievedAt=2026-03-21T00:00:00Z durationMs=150"
    , "{\"rows\":[{\"headline\":\"AMD launch\"}]}"
    ]
