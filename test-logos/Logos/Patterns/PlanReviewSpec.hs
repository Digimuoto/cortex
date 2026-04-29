{- |
Module      : Logos.Patterns.PlanReviewSpec
Description : Tests for Logos.Patterns.PlanReview.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Patterns.PlanReviewSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Logos.Patterns.PlanReview
  ( LogosPlanTaskConfig (..)
  , runPlanTask
  )
import Logos.Thought.Host
  ( LogosTaskHost (..)
  )
import Logos.Thought.ToolHost
  ( LogosTaskToolHost (..)
  )
import Test.Hspec

import Cortex.Capability.Model.Client
  ( CortexModelClient (..)
  )
import Cortex.Capability.Model.Message
  ( systemMessage
  , userTextMessage
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexToolCall (..)
  )

spec :: Spec
spec = do
  describe "runPlanTask" $ do
    it "runs planner notes through a reviewer tool call and finalizes the result" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Planner notes." []
          , mkChoice "" [sampleToolCall]
          ]
      seenRequests <- newIORef []

      result <-
        runPlanTask
          (mkTaskToolHost queuedChoices seenRequests)
          (samplePlanTaskConfig (\toolCall -> pure (Right toolCall.cortexToolCallName)))

      result `shouldBe` Right "draftExecutionPlan"
      requests <- readIORef seenRequests
      fmap (.cortexChoiceStepIndex) requests `shouldBe` [Just 1, Just 2]
      fmap (.cortexChoiceMessages) requests
        `shouldBe` [ [systemMessage "planner-system", userTextMessage "planner-input"]
                   , [systemMessage "reviewer-system", userTextMessage "reviewer-input: Planner notes."]
                   ]

    it "returns the configured missing-tool text when the reviewer produces no tool call" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Planner notes." []
          , mkChoice "No structured action." []
          ]
      seenRequests <- newIORef []

      result <-
        runPlanTask
          (mkTaskToolHost queuedChoices seenRequests)
          (samplePlanTaskConfig (\_ -> pure (Right ("unused" :: Text))))

      result `shouldBe` Left "missing tool call"

    it "returns finalizer errors without wrapping them in downstream policy" $ do
      queuedChoices <-
        newIORef
          [ mkChoice "Planner notes." []
          , mkChoice "" [sampleToolCall]
          ]
      seenRequests <- newIORef []

      result <-
        runPlanTask
          (mkTaskToolHost queuedChoices seenRequests)
          (samplePlanTaskConfig (\_ -> pure (Left "finalizer failed")))

      result `shouldBe` (Left "finalizer failed" :: Either Text Text)

samplePlanTaskConfig
  :: (CortexToolCall -> IO (Either Text a))
  -> LogosPlanTaskConfig IO a
samplePlanTaskConfig finalizeToolCall =
  LogosPlanTaskConfig
    { logosPlanTaskModelId = "anthropic/claude-sonnet-4.6"
    , logosPlanTaskPlannerSystemPrompt = "planner-system"
    , logosPlanTaskPlannerInput = "planner-input"
    , logosPlanTaskReviewerSystemPrompt = "reviewer-system"
    , logosPlanTaskReviewerInput = ("reviewer-input: " <>)
    , logosPlanTaskReviewerTools = [Aeson.object ["name" Aeson..= ("draftExecutionPlan" :: Text)]]
    , logosPlanTaskMissingToolCallText = "missing tool call"
    , logosPlanTaskFinalizeToolCall = finalizeToolCall
    }

mkTaskToolHost
  :: IORef [CortexChoice]
  -> IORef [CortexChoiceRequest]
  -> LogosTaskToolHost IO
mkTaskToolHost queuedChoices seenRequests =
  LogosTaskToolHost
    { logosTaskToolHostTaskHost =
        LogosTaskHost
          { logosTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in PlanSpec."
                      (choice : rest) -> writeIORef queuedChoices rest >> pure choice
                }
          , logosTaskThrowIfCanceled = pure ()
          , logosTaskEmitEvent = \_ -> pure ()
          }
    , logosTaskToolHostExecuteToolCalls = \_ _ ->
        error "PlanSpec does not execute runtime tool loops via LogosTaskToolHost."
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
    , cortexToolCallName = "draftExecutionPlan"
    , cortexToolCallArguments = "{\"title\":\"Plan\"}"
    }
