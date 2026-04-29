{- |
Module      : Logos.Thought.ToolLoop
Description : Logos reasoning-library support for tool loop.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.ToolLoop
  ( LogosToolLoopConfig (..)
  , LogosToolLoopResult (..)
  , runToolLoop
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime)
import Logos.Thought.Host qualified as TaskHost
import Logos.Thought.Runtime qualified as TaskRuntime
import Logos.Thought.Stage
  ( LogosStageDescriptor (..)
  )
import Logos.Thought.ToolHost
  ( LogosTaskToolHost
  , LogosToolExecutionResult (..)
  , executeTaskToolCalls
  , taskToolHostBase
  )

import Cortex.Capability.Model.Message
  ( assistantToolCallsMessage
  , toolMessage
  )
import Cortex.Capability.Model.Output
  ( renderChoiceContentWithSources
  )
import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  )
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..)
  )

import Platform.Serde.Json.Preview (truncateText)
import Platform.Serde.Json.Text (decodeLazyUtf8)

data LogosToolLoopConfig = LogosToolLoopConfig
  { logosToolLoopDescriptor :: LogosStageDescriptor
  , logosToolLoopChoiceRequest :: CortexChoiceRequest
  , logosToolLoopStepBudget :: Int
  , logosToolLoopBudgetExceededText :: Text
  , logosToolLoopThinkingTitle :: Int -> Text
  , logosToolLoopThinkingSummary :: Int -> Maybe Text
  }

data LogosToolLoopResult = LogosToolLoopResult
  { logosToolLoopResultText :: Text
  , logosToolLoopResultRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

runToolLoop
  :: MonadIO m
  => LogosTaskToolHost m
  -> LogosToolLoopConfig
  -> m LogosToolLoopResult
runToolLoop toolHost config =
  loop 0 config.logosToolLoopChoiceRequest.cortexChoiceMessages []
  where
    loop stepIndex messages accToolCallRecords
      | stepIndex >= config.logosToolLoopStepBudget =
          pure
            LogosToolLoopResult
              { logosToolLoopResultText = config.logosToolLoopBudgetExceededText
              , logosToolLoopResultRecords = accToolCallRecords
              }
      | otherwise = do
          let stepNumber = stepIndex + 1
              descriptor = config.logosToolLoopDescriptor {logosStageStep = Just stepNumber}
          TaskHost.throwIfTaskCanceled (taskToolHostBase toolHost)
          TaskRuntime.emitThinking
            (taskToolHostBase toolHost)
            descriptor
            (config.logosToolLoopThinkingTitle stepNumber)
            (config.logosToolLoopThinkingSummary stepNumber)
          choice <-
            TaskHost.requestTaskChoice
              (taskToolHostBase toolHost)
              config.logosToolLoopChoiceRequest
                { cortexChoiceMessages = messages
                , cortexChoiceStepIndex = Just stepNumber
                }
          if null choice.cortexChoiceToolCalls
            then
              pure
                LogosToolLoopResult
                  { logosToolLoopResultText =
                      renderChoiceContentWithSources
                        config.logosToolLoopChoiceRequest.cortexChoiceGroundingMode
                        choice
                  , logosToolLoopResultRecords = accToolCallRecords
                  }
            else do
              executionResult <- executeTaskToolCalls toolHost stepNumber choice.cortexChoiceToolCalls
              let mergedRecords = accToolCallRecords <> executionResult.logosToolExecutionRecords
              case executionResult.logosToolExecutionTerminalError of
                Just errText ->
                  pure
                    LogosToolLoopResult
                      { logosToolLoopResultText = errText
                      , logosToolLoopResultRecords = mergedRecords
                      }
                Nothing ->
                  let nextMessages =
                        messages
                          <> [assistantToolCallsMessage choice.cortexChoiceContent choice.cortexChoiceToolCalls]
                          <> compactToolExecutionMessages executionResult
                   in loop stepNumber nextMessages mergedRecords

compactToolExecutionMessages :: LogosToolExecutionResult -> [Aeson.Value]
compactToolExecutionMessages executionResult =
  case fmap compactToolRecordMessage executionResult.logosToolExecutionRecords of
    [] -> executionResult.logosToolExecutionMessages
    compactMessages -> compactMessages

compactToolRecordMessage :: CortexToolCallRecord -> Aeson.Value
compactToolRecordMessage record =
  toolMessage
    record.cortexToolCallRecordId
    record.cortexToolCallRecordName
    (renderCompactToolRecord record)

renderCompactToolRecord :: CortexToolCallRecord -> Text
renderCompactToolRecord record =
  T.unlines
    [ "Tool result preview (compact, not full raw payload)."
    , "retrievedAt="
        <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" record.cortexToolCallRecordTimestamp)
        <> " durationMs="
        <> T.pack (show record.cortexToolCallRecordDuration)
    , truncateText 900 (decodeLazyUtf8 (Aeson.encode record.cortexToolCallRecordResult))
    ]
