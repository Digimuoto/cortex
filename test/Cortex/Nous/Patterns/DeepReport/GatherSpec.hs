{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Patterns.DeepReport.GatherSpec (spec) where

import Cortex.Capability.Model.Client
  ( CortexModelClient (..),
  )
import Cortex.Capability.Model.Message
  ( assistantToolCallsMessage,
    systemMessage,
    toolMessage,
    userTextMessage,
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..),
    CortexChoiceRequest (..),
    CortexChoiceTimeoutClass (..),
    CortexGroundingMode (..),
    CortexToolCall (..),
  )
import Cortex.Capability.Tool.Definition (toolDefinitionName)
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..),
  )
import Cortex.Nous.Patterns.DeepReport.Gather
  ( CortexGatherRepairTaskConfig (..),
    CortexGatherTaskConfig (..),
    CortexGatherTaskResult (..),
    runGatherRepairTask,
    runGatherTask,
  )
import Cortex.Nous.Thought.Host
  ( CortexTaskHost (..),
  )
import Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost (..),
    CortexToolExecutionResult (..),
  )
import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

spec :: Spec
spec = do
  describe "runGatherTask" $ do
    it "runs the gather tool loop and returns the final summary with tool records" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Need deterministic evidence." [sampleToolCall "getAssetNews"],
            mkChoice "AMD still looks constructive." []
          ]
      seenRequests <- newIORef []
      let toolExecutionResult =
            CortexToolExecutionResult
              { cortexToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."],
                cortexToolExecutionRecords = [sampleToolCallRecord "getAssetNews"],
                cortexToolExecutionTerminalError = Nothing
              }
      result <-
        runGatherTask
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleGatherTaskConfig

      result
        `shouldBe` CortexGatherTaskResult
          { cortexGatherTaskResultSummary = "AMD still looks constructive.",
            cortexGatherTaskResultToolCallRecords = [sampleToolCallRecord "getAssetNews"]
          }
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStepIndex) requests `shouldBe` [Just 1, Just 2]
      fmap (.cortexChoiceMessages) requests
        `shouldBe` [ [systemMessage "gather-system", userTextMessage "gather-input"],
                     [ systemMessage "gather-system",
                       userTextMessage "gather-input",
                       assistantToolCallsMessage "Need deterministic evidence." [sampleToolCall "getAssetNews"],
                       toolMessage "call-1" "getAssetNews" compactToolPreviewText
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
            { cortexGatherRepairTaskMissingToolNames = ["getNav"],
              cortexGatherRepairTaskMaxSteps = 1
            }

      result
        `shouldBe` CortexGatherTaskResult
          { cortexGatherTaskResultSummary = "No deterministic repair needed.",
            cortexGatherTaskResultToolCallRecords = []
          }

    it "narrows the allowed repair tools to the remaining missing set across attempts" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "" [sampleToolCall "getNav"],
            mkChoice "" [sampleToolCall "getPortfolioSummary"]
          ]
      seenRequests <- newIORef []
      toolSteps <- newIORef []

      let executeTools stepNumber toolCalls = do
            modifyIORef' toolSteps (<> [(stepNumber, fmap (.cortexToolCallName) toolCalls)])
            pure
              CortexToolExecutionResult
                { cortexToolExecutionMessages =
                    fmap (\call -> toolMessage call.cortexToolCallId call.cortexToolCallName "repair-result") toolCalls,
                  cortexToolExecutionRecords = fmap (sampleToolCallRecord . (.cortexToolCallName)) toolCalls,
                  cortexToolExecutionTerminalError = Nothing
                }

      result <-
        runGatherRepairTask
          (mkToolHost queuedChoices seenRequests executeTools)
          sampleGatherRepairTaskConfig
            { cortexGatherRepairTaskMissingToolNames = ["getNav", "getPortfolioSummary"],
              cortexGatherRepairTaskMaxSteps = 2
            }

      fmap (.cortexToolCallRecordName) result.cortexGatherTaskResultToolCallRecords
        `shouldBe` ["getNav", "getPortfolioSummary"]
      readIORef toolSteps `shouldReturn` [(1, ["getNav"]), (2, ["getPortfolioSummary"])]
      requests <- readIORef seenRequests
      fmap (mapMaybe toolDefinitionName . (.cortexChoiceTools)) requests
        `shouldBe` [ ["getNav", "getPortfolioSummary"],
                     ["getPortfolioSummary"]
                   ]

sampleGatherTaskConfig :: CortexGatherTaskConfig
sampleGatherTaskConfig =
  CortexGatherTaskConfig
    { cortexGatherTaskModelId = "anthropic/claude-sonnet-4.6",
      cortexGatherTaskGroundingMode = GroundingDisabled,
      cortexGatherTaskSystemPrompt = "gather-system",
      cortexGatherTaskUserInput = "gather-input",
      cortexGatherTaskTools = sampleToolDefinitions,
      cortexGatherTaskStageName = "report_gatherer",
      cortexGatherTaskTimeoutClass = CortexChoiceTimeoutHeavy,
      cortexGatherTaskMaxOutputTokens = Nothing,
      cortexGatherTaskStepBudget = 3,
      cortexGatherTaskBudgetExceededText = "Gatherer reached its step budget."
    }

sampleGatherRepairTaskConfig :: CortexGatherRepairTaskConfig
sampleGatherRepairTaskConfig =
  CortexGatherRepairTaskConfig
    { cortexGatherRepairTaskModelId = "anthropic/claude-sonnet-4.6",
      cortexGatherRepairTaskGroundingMode = GroundingDisabled,
      cortexGatherRepairTaskSystemPrompt = "repair-system",
      cortexGatherRepairTaskBuildInput = \attemptNumber toolNames ->
        "repair-input:" <> showText attemptNumber <> ":" <> T.intercalate "," toolNames,
      cortexGatherRepairTaskTools = sampleToolDefinitions,
      cortexGatherRepairTaskMissingToolNames = [],
      cortexGatherRepairTaskStageName = "report_gatherer_repair",
      cortexGatherRepairTaskTimeoutClass = CortexChoiceTimeoutHeavy,
      cortexGatherRepairTaskMaxOutputTokens = Nothing,
      cortexGatherRepairTaskMaxSteps = 1
    }

sampleToolDefinitions :: [Aeson.Value]
sampleToolDefinitions =
  fmap
    (\toolName -> Aeson.object ["function" Aeson..= Aeson.object ["name" Aeson..= toolName]])
    ["getAssetNews" :: Text, "getNav", "getPortfolioSummary"]

mkToolHost ::
  IORef [CortexChoice] ->
  IORef [CortexChoiceRequest] ->
  (Int -> [CortexToolCall] -> IO CortexToolExecutionResult) ->
  CortexTaskToolHost IO
mkToolHost queuedChoices seenRequests executeTools =
  CortexTaskToolHost
    { cortexTaskToolHostTaskHost =
        CortexTaskHost
          { cortexTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in GatherSpec."
                      (choice : rest) -> writeIORef queuedChoices rest >> pure choice
                },
            cortexTaskThrowIfCanceled = pure (),
            cortexTaskEmitEvent = \_ -> pure ()
          },
      cortexTaskToolHostExecuteToolCalls = executeTools
    }

mkChoice :: Text -> [CortexToolCall] -> CortexChoice
mkChoice content toolCalls =
  CortexChoice
    { cortexChoiceContent = content,
      cortexChoiceSourceLinks = [],
      cortexChoiceToolCalls = toolCalls,
      cortexChoiceFinishReason = Nothing,
      cortexChoiceUsage = Nothing,
      cortexChoiceReasoning = Nothing,
      cortexChoiceReasoningDetails = Nothing
    }

sampleToolCall :: Text -> CortexToolCall
sampleToolCall toolName =
  CortexToolCall
    { cortexToolCallId = "call-1",
      cortexToolCallName = toolName,
      cortexToolCallArguments = "{\"ticker\":\"AMD\"}"
    }

sampleToolCallRecord :: Text -> CortexToolCallRecord
sampleToolCallRecord toolName =
  CortexToolCallRecord
    { cortexToolCallRecordId = "call-1",
      cortexToolCallRecordName = toolName,
      cortexToolCallRecordArgs = Aeson.object ["ticker" Aeson..= ("AMD" :: Text)],
      cortexToolCallRecordResult = Aeson.object ["rows" Aeson..= [Aeson.object ["headline" Aeson..= ("AMD launch" :: Text)]]],
      cortexToolCallRecordTimestamp = fixedNow,
      cortexToolCallRecordDuration = 150
    }

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 3 21) (secondsToDiffTime 0)

showText :: (Show a) => a -> Text
showText = T.pack . show

compactToolPreviewText :: Text
compactToolPreviewText =
  T.unlines
    [ "Tool result preview (compact, not full raw payload).",
      "retrievedAt=2026-03-21T00:00:00Z durationMs=150",
      "{\"rows\":[{\"headline\":\"AMD launch\"}]}"
    ]
