module Cortex.Nous.Patterns.PlanReviewSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
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
import Cortex.Nous.Patterns.PlanReview
  ( CortexPlanTaskConfig (..)
  , runPlanTask
  )
import Cortex.Nous.Thought.Host
  ( CortexTaskHost (..)
  )
import Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost (..)
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
  -> CortexPlanTaskConfig IO a
samplePlanTaskConfig finalizeToolCall =
  CortexPlanTaskConfig
    { cortexPlanTaskModelId = "anthropic/claude-sonnet-4.6"
    , cortexPlanTaskPlannerSystemPrompt = "planner-system"
    , cortexPlanTaskPlannerInput = "planner-input"
    , cortexPlanTaskReviewerSystemPrompt = "reviewer-system"
    , cortexPlanTaskReviewerInput = ("reviewer-input: " <>)
    , cortexPlanTaskReviewerTools = [Aeson.object ["name" Aeson..= ("draftExecutionPlan" :: Text)]]
    , cortexPlanTaskMissingToolCallText = "missing tool call"
    , cortexPlanTaskFinalizeToolCall = finalizeToolCall
    }

mkTaskToolHost
  :: IORef [CortexChoice]
  -> IORef [CortexChoiceRequest]
  -> CortexTaskToolHost IO
mkTaskToolHost queuedChoices seenRequests =
  CortexTaskToolHost
    { cortexTaskToolHostTaskHost =
        CortexTaskHost
          { cortexTaskModelClient =
              CortexModelClient
                { requestCortexChoice = \request -> do
                    modifyIORef' seenRequests (<> [request])
                    remainingChoices <- readIORef queuedChoices
                    case remainingChoices of
                      [] -> error "No queued CortexChoice values remained in PlanSpec."
                      (choice : rest) -> writeIORef queuedChoices rest >> pure choice
                }
          , cortexTaskThrowIfCanceled = pure ()
          , cortexTaskEmitEvent = \_ -> pure ()
          }
    , cortexTaskToolHostExecuteToolCalls = \_ _ ->
        error "PlanSpec does not execute runtime tool loops via CortexTaskToolHost."
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
