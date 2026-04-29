{- |
Module      : Logos.Thought.ToolLoopSpec
Description : Tests for Logos.Thought.ToolLoop.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Thought.ToolLoopSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Logos.Thought.Host
  ( LogosTaskHost (..)
  )
import Logos.Thought.Stage (LogosStageDescriptor (..))
import Logos.Thought.ToolHost
  ( LogosTaskToolHost (..)
  , LogosToolExecutionResult (..)
  )
import Logos.Thought.ToolLoop
  ( LogosToolLoopConfig (..)
  , LogosToolLoopResult (..)
  , runToolLoop
  )
import Test.Hspec

import Cortex.Capability.Model.Client
  ( CortexModelClient (..)
  )
import Cortex.Capability.Model.Message
  ( assistantToolCallsMessage
  , toolMessage
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
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..)
  )

spec :: Spec
spec = do
  describe "runToolLoop" $ do
    it "executes tool calls and carries forward assistant/tool messages" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Need deterministic evidence." [sampleToolCall]
          , mkChoice "AMD still looks constructive." []
          ]
      seenRequests <- newIORef []
      toolSteps <- newIORef []
      let toolExecutionResult =
            LogosToolExecutionResult
              { logosToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."]
              , logosToolExecutionRecords = [sampleToolCallRecord]
              , logosToolExecutionTerminalError = Nothing
              }
      result <-
        runToolLoop
          ( mkToolHost
              queuedChoices
              seenRequests
              (\stepNumber _ -> modifyIORef' toolSteps (<> [stepNumber]) >> pure toolExecutionResult)
          )
          sampleToolLoopConfig

      result
        `shouldBe` LogosToolLoopResult
          { logosToolLoopResultText = "AMD still looks constructive."
          , logosToolLoopResultRecords = [sampleToolCallRecord]
          }
      readIORef toolSteps `shouldReturn` [1]
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStepIndex) requests `shouldBe` [Just 1, Just 2]
      fmap (.cortexChoiceMessages) requests
        `shouldBe` [ [userTextMessage "Analyze AMD."]
                   ,
                     [ userTextMessage "Analyze AMD."
                     , assistantToolCallsMessage "Need deterministic evidence." [sampleToolCall]
                     , toolMessage "call-1" "getAssetNews" compactToolPreviewText
                     ]
                   ]

    it "returns the configured budget text when the loop runs out of steps" $ do
      queuedChoices <- newIORef [mkChoice "Need more tools." [sampleToolCall]]
      seenRequests <- newIORef []
      let toolExecutionResult =
            LogosToolExecutionResult
              { logosToolExecutionMessages = [toolMessage "call-1" "getAssetNews" "Deterministic evidence bundle."]
              , logosToolExecutionRecords = [sampleToolCallRecord]
              , logosToolExecutionTerminalError = Nothing
              }
      result <-
        runToolLoop
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleToolLoopConfig
            { logosToolLoopStepBudget = 1
            , logosToolLoopBudgetExceededText = "Gatherer reached its step budget."
            }

      result
        `shouldBe` LogosToolLoopResult
          { logosToolLoopResultText = "Gatherer reached its step budget."
          , logosToolLoopResultRecords = [sampleToolCallRecord]
          }
      fmap (.cortexChoiceStepIndex) <$> readIORef seenRequests `shouldReturn` [Just 1]

    it "returns terminal tool execution errors without discarding records" $ do
      queuedChoices <- newIORef [mkChoice "Need deterministic evidence." [sampleToolCall]]
      seenRequests <- newIORef []
      let toolExecutionResult =
            LogosToolExecutionResult
              { logosToolExecutionMessages = []
              , logosToolExecutionRecords = [sampleToolCallRecord]
              , logosToolExecutionTerminalError = Just "Tool execution failed."
              }
      result <-
        runToolLoop
          (mkToolHost queuedChoices seenRequests (\_ _ -> pure toolExecutionResult))
          sampleToolLoopConfig

      result
        `shouldBe` LogosToolLoopResult
          { logosToolLoopResultText = "Tool execution failed."
          , logosToolLoopResultRecords = [sampleToolCallRecord]
          }
      fmap (.cortexChoiceStepIndex) <$> readIORef seenRequests `shouldReturn` [Just 1]

sampleToolLoopConfig :: LogosToolLoopConfig
sampleToolLoopConfig =
  LogosToolLoopConfig
    { logosToolLoopDescriptor =
        LogosStageDescriptor
          { logosStageAgentName = Just "Gatherer"
          , logosStageStageName = Nothing
          , logosStageStep = Nothing
          , logosStageToolName = Nothing
          }
    , logosToolLoopChoiceRequest =
        CortexChoiceRequest
          { cortexChoiceModelId = "anthropic/claude-sonnet-4.6"
          , cortexChoiceGroundingMode = GroundingDisabled
          , cortexChoiceMessages = [userTextMessage "Analyze AMD."]
          , cortexChoiceTools = []
          , cortexChoiceResponseFormat = CortexResponseText
          , cortexChoiceMaxOutputTokens = Nothing
          , cortexChoiceStageName = "report_gatherer"
          , cortexChoiceAgentName = Just "Gatherer"
          , cortexChoiceStepIndex = Nothing
          , cortexChoiceSectionId = Nothing
          , cortexChoiceAttempt = Nothing
          , cortexChoiceTimeoutClass = CortexChoiceTimeoutHeavy
          , cortexChoiceReasoningEnabled = False
          }
    , logosToolLoopStepBudget = 3
    , logosToolLoopBudgetExceededText = "Tool loop budget exceeded."
    , logosToolLoopThinkingTitle = \stepNumber -> "Gatherer step " <> showText stepNumber
    , logosToolLoopThinkingSummary = const (Just "Selecting read tools.")
    }

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
                      [] -> error "No queued CortexChoice values remained in ToolLoopSpec."
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

sampleToolCall :: CortexToolCall
sampleToolCall =
  CortexToolCall
    { cortexToolCallId = "call-1"
    , cortexToolCallName = "getAssetNews"
    , cortexToolCallArguments = "{\"ticker\":\"AMD\"}"
    }

sampleToolCallRecord :: CortexToolCallRecord
sampleToolCallRecord =
  CortexToolCallRecord
    { cortexToolCallRecordId = "call-1"
    , cortexToolCallRecordName = "getAssetNews"
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
