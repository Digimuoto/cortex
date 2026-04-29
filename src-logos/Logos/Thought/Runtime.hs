{- |
Module      : Logos.Thought.Runtime
Description : Logos reasoning-library support for runtime.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Runtime
  ( emitAgentDone
  , emitAgentStart
  , emitError
  , emitSummary
  , emitThinking
  , runTextTask
  , runTextTaskWithMaxOutputTokens
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Logos.Thought.Event qualified as Engine
import Logos.Thought.Host
  ( LogosTaskHost
  , requestTaskChoice
  , taskEventEmitter
  , throwIfTaskCanceled
  )
import Logos.Thought.Stage (LogosStageDescriptor (..))

import Cortex.Capability.Model.Message
  ( systemMessage
  , userTextMessage
  )
import Cortex.Capability.Model.Output
  ( renderChoiceContentWithSources
  )
import Cortex.Capability.Model.Types
  ( CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass
  , CortexGroundingMode
  , CortexResponseFormat (..)
  )

runTextTask
  :: MonadIO m
  => LogosTaskHost m
  -> Text
  -> CortexChoiceTimeoutClass
  -> Text
  -> CortexGroundingMode
  -> Text
  -> Maybe Int
  -> Text
  -> Text
  -> m Text
runTextTask taskHost assistantPhase timeoutClass modelId groundingMode agentName maybeStep systemPrompt userInput = do
  runTextTaskWithMaxOutputTokens
    taskHost
    assistantPhase
    timeoutClass
    modelId
    groundingMode
    agentName
    maybeStep
    Nothing
    systemPrompt
    userInput

runTextTaskWithMaxOutputTokens
  :: MonadIO m
  => LogosTaskHost m
  -> Text
  -> CortexChoiceTimeoutClass
  -> Text
  -> CortexGroundingMode
  -> Text
  -> Maybe Int
  -> Maybe Int
  -> Text
  -> Text
  -> m Text
runTextTaskWithMaxOutputTokens taskHost assistantPhase timeoutClass modelId groundingMode agentName maybeStep maybeMaxOutputTokens systemPrompt userInput = do
  throwIfTaskCanceled taskHost
  let descriptor =
        LogosStageDescriptor
          { logosStageAgentName = Just agentName
          , logosStageStageName = Nothing
          , logosStageStep = maybeStep
          , logosStageToolName = Nothing
          }
  emitAgentStart taskHost descriptor (agentName <> " started") Nothing
  emitThinking taskHost descriptor (agentName <> " thinking") Nothing
  choice <-
    requestTaskChoice
      taskHost
      CortexChoiceRequest
        { cortexChoiceModelId = modelId
        , cortexChoiceGroundingMode = groundingMode
        , cortexChoiceMessages =
            [ systemMessage systemPrompt
            , userTextMessage userInput
            ]
        , cortexChoiceTools = []
        , cortexChoiceResponseFormat = CortexResponseText
        , cortexChoiceMaxOutputTokens = maybeMaxOutputTokens
        , cortexChoiceStageName = assistantPhase
        , cortexChoiceAgentName = Just agentName
        , cortexChoiceStepIndex = maybeStep
        , cortexChoiceSectionId = Nothing
        , cortexChoiceAttempt = Nothing
        , cortexChoiceTimeoutClass = timeoutClass
        , cortexChoiceReasoningEnabled = False
        }
  let resultText = renderChoiceContentWithSources groundingMode choice
  emitAgentDone taskHost descriptor (agentName <> " completed") Nothing
  pure resultText

emitAgentStart
  :: MonadIO m => LogosTaskHost m -> LogosStageDescriptor -> Text -> Maybe Text -> m ()
emitAgentStart taskHost descriptor title summary =
  liftIO $ Engine.emitAgentStart (taskEventEmitter taskHost) descriptor title summary

emitAgentDone
  :: MonadIO m => LogosTaskHost m -> LogosStageDescriptor -> Text -> Maybe Text -> m ()
emitAgentDone taskHost descriptor title summary =
  liftIO $ Engine.emitAgentDone (taskEventEmitter taskHost) descriptor title summary

emitThinking
  :: MonadIO m => LogosTaskHost m -> LogosStageDescriptor -> Text -> Maybe Text -> m ()
emitThinking taskHost descriptor title summary =
  liftIO $ Engine.emitThinking (taskEventEmitter taskHost) descriptor title summary

emitSummary
  :: MonadIO m
  => LogosTaskHost m
  -> Maybe Text
  -> Maybe Text
  -> Maybe Int
  -> Text
  -> Maybe Text
  -> Maybe Aeson.Value
  -> m ()
emitSummary taskHost agentName stageName step title summary preview =
  liftIO $
    Engine.emitSummary
      (taskEventEmitter taskHost)
      LogosStageDescriptor
        { logosStageAgentName = agentName
        , logosStageStageName = stageName
        , logosStageStep = step
        , logosStageToolName = Nothing
        }
      title
      summary
      preview

emitError :: MonadIO m => LogosTaskHost m -> LogosStageDescriptor -> Text -> Maybe Text -> m ()
emitError taskHost descriptor title summary =
  liftIO $ Engine.emitError (taskEventEmitter taskHost) descriptor title summary
