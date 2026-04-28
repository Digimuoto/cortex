{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Thought.ToolLoopSpec (spec) where

import Cortex.Capability.Model.Client
  ( CortexModelClient (..),
  )
import Cortex.Capability.Model.Message
  ( assistantToolCallsMessage,
    toolMessage,
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
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..),
  )
import Cortex.Nous.Thought.Host
  ( CortexTaskHost (..),
  )
import Cortex.Nous.Thought.Stage (CortexStageDescriptor (..))
import Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost (..),
    CortexToolExecutionResult (..),
  )
import Cortex.Nous.Thought.ToolLoop
  ( CortexToolLoopConfig (..),
    CortexToolLoopResult (..),
    runToolLoop,
  )
import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

spec :: Spec
spec = do
  describe "runToolLoop" $ do
    it "executes tool calls and carries forward assistant/tool messages" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Need deterministic evidence." [sampleToolCall],
            mkChoice "AMD still looks constructive." []
          ]
      seenRequests <- newIORef []
      toolSteps <- newIORef []
      let toolExecutionResult =
            CortexToolExecutionResult
              { cortexToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."],
                cortexToolExecutionRecords = [sampleToolCallRecord],
                cortexToolExecutionTerminalError = Nothing
              }
      result <-
        runToolLoop
          (mkToolHost queuedChoices seenRequests (\stepNumber _ -> modifyIORef' toolSteps (<> [stepNumber]) >> pure toolExecutionResult))
          sampleToolLoopConfig

      result
        `shouldBe` CortexToolLoopResult
          { cortexToolLoopResultText = "AMD still looks constructive.",
            cortexToolLoopResultRecords = [sampleToolCallRecord]
          }
      readIORef toolSteps `shouldReturn` [1]
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStepIndex) requests `shouldBe` [Just 1, Just 2]
      fmap (.cortexChoiceMessages) requests
        `shouldBe` [ [userTextMessage "Analyze AMD."],
                     [ userTextMessage "Analyze AMD.",
                       assistantToolCallsMessage "Need deterministic evidence." [sampleToolCall],
                       toolMessage "call-1" "getAssetNews" compactToolPreviewText
                     ]
                   ]

    it "returns the configured budget text when the loop runs out of steps" $ do
      queuedChoices <- newIORef [mkChoice "Need more tools." [sampleToolCall]]
      seenRequests <- newIORef []
      let toolExecutionResult =
            CortexToolExecutionResult
              { cortexToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."],
                cortexToolExecutionRecords = [sampleToolCallRecord],
                cortexToolExecutionTerminalError = Nothing
              }
      result <-
        runToolLoop
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleToolLoopConfig
            { cortexToolLoopStepBudget = 1,
              cortexToolLoopBudgetExceededText = "Gatherer reached its step budget."
            }

      result
        `shouldBe` CortexToolLoopResult
          { cortexToolLoopResultText = "Gatherer reached its step budget.",
            cortexToolLoopResultRecords = [sampleToolCallRecord]
          }
      fmap (.cortexChoiceStepIndex) <$> readIORef seenRequests `shouldReturn` [Just 1]

    it "returns terminal tool execution errors without discarding records" $ do
      queuedChoices <- newIORef [mkChoice "Need deterministic evidence." [sampleToolCall]]
      seenRequests <- newIORef []
      let toolExecutionResult =
            CortexToolExecutionResult
              { cortexToolExecutionMessages = [],
                cortexToolExecutionRecords = [sampleToolCallRecord],
                cortexToolExecutionTerminalError = Just "Tool execution failed."
              }
      result <-
        runToolLoop
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleToolLoopConfig

      result
        `shouldBe` CortexToolLoopResult
          { cortexToolLoopResultText = "Tool execution failed.",
            cortexToolLoopResultRecords = [sampleToolCallRecord]
          }
      fmap (.cortexChoiceStepIndex) <$> readIORef seenRequests `shouldReturn` [Just 1]

sampleToolLoopConfig :: CortexToolLoopConfig
sampleToolLoopConfig =
  CortexToolLoopConfig
    { cortexToolLoopDescriptor =
        CortexStageDescriptor
          { cortexStageAgentName = Just "Gatherer",
            cortexStageStageName = Nothing,
            cortexStageStep = Nothing,
            cortexStageToolName = Nothing
          },
      cortexToolLoopChoiceRequest =
        CortexChoiceRequest
          { cortexChoiceModelId = "anthropic/claude-sonnet-4.6",
            cortexChoiceGroundingMode = GroundingDisabled,
            cortexChoiceMessages = [userTextMessage "Analyze AMD."],
            cortexChoiceTools = [],
            cortexChoiceResponseFormat = CortexResponseText,
            cortexChoiceMaxOutputTokens = Nothing,
            cortexChoiceStageName = "report_gatherer",
            cortexChoiceAgentName = Just "Gatherer",
            cortexChoiceStepIndex = Nothing,
            cortexChoiceSectionId = Nothing,
            cortexChoiceAttempt = Nothing,
            cortexChoiceTimeoutClass = CortexChoiceTimeoutHeavy,
            cortexChoiceReasoningEnabled = False
          },
      cortexToolLoopStepBudget = 3,
      cortexToolLoopBudgetExceededText = "Tool loop budget exceeded.",
      cortexToolLoopThinkingTitle = \stepNumber -> "Gatherer step " <> showText stepNumber,
      cortexToolLoopThinkingSummary = const (Just "Selecting read tools.")
    }

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
                      [] -> error "No queued CortexChoice values remained in ToolLoopSpec."
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

sampleToolCall :: CortexToolCall
sampleToolCall =
  CortexToolCall
    { cortexToolCallId = "call-1",
      cortexToolCallName = "getAssetNews",
      cortexToolCallArguments = "{\"ticker\":\"AMD\"}"
    }

sampleToolCallRecord :: CortexToolCallRecord
sampleToolCallRecord =
  CortexToolCallRecord
    { cortexToolCallRecordId = "call-1",
      cortexToolCallRecordName = "getAssetNews",
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
