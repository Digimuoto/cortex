module Cortex.Nous.Thought.ToolLoop
  ( CortexToolLoopConfig (..)
  , CortexToolLoopResult (..)
  , runToolLoop
  )
where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime)

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
import Cortex.Nous.Thought.Host qualified as TaskHost
import Cortex.Nous.Thought.Runtime qualified as TaskRuntime
import Cortex.Nous.Thought.Stage
  ( CortexStageDescriptor (..)
  )
import Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost
  , CortexToolExecutionResult (..)
  , executeTaskToolCalls
  , taskToolHostBase
  )

import Platform.Serde.Json.Preview (truncateText)
import Platform.Serde.Json.Text (decodeLazyUtf8)

data CortexToolLoopConfig = CortexToolLoopConfig
  { cortexToolLoopDescriptor :: CortexStageDescriptor
  , cortexToolLoopChoiceRequest :: CortexChoiceRequest
  , cortexToolLoopStepBudget :: Int
  , cortexToolLoopBudgetExceededText :: Text
  , cortexToolLoopThinkingTitle :: Int -> Text
  , cortexToolLoopThinkingSummary :: Int -> Maybe Text
  }

data CortexToolLoopResult = CortexToolLoopResult
  { cortexToolLoopResultText :: Text
  , cortexToolLoopResultRecords :: [CortexToolCallRecord]
  }
  deriving stock (Eq, Show)

runToolLoop
  :: MonadIO m
  => CortexTaskToolHost m
  -> CortexToolLoopConfig
  -> m CortexToolLoopResult
runToolLoop toolHost config =
  loop 0 config.cortexToolLoopChoiceRequest.cortexChoiceMessages []
  where
    loop stepIndex messages accToolCallRecords
      | stepIndex >= config.cortexToolLoopStepBudget =
          pure
            CortexToolLoopResult
              { cortexToolLoopResultText = config.cortexToolLoopBudgetExceededText
              , cortexToolLoopResultRecords = accToolCallRecords
              }
      | otherwise = do
          let stepNumber = stepIndex + 1
              descriptor = config.cortexToolLoopDescriptor {cortexStageStep = Just stepNumber}
          TaskHost.throwIfTaskCanceled (taskToolHostBase toolHost)
          TaskRuntime.emitThinking
            (taskToolHostBase toolHost)
            descriptor
            (config.cortexToolLoopThinkingTitle stepNumber)
            (config.cortexToolLoopThinkingSummary stepNumber)
          choice <-
            TaskHost.requestTaskChoice
              (taskToolHostBase toolHost)
              config.cortexToolLoopChoiceRequest
                { cortexChoiceMessages = messages
                , cortexChoiceStepIndex = Just stepNumber
                }
          if null choice.cortexChoiceToolCalls
            then
              pure
                CortexToolLoopResult
                  { cortexToolLoopResultText =
                      renderChoiceContentWithSources
                        config.cortexToolLoopChoiceRequest.cortexChoiceGroundingMode
                        choice
                  , cortexToolLoopResultRecords = accToolCallRecords
                  }
            else do
              executionResult <- executeTaskToolCalls toolHost stepNumber choice.cortexChoiceToolCalls
              let mergedRecords = accToolCallRecords <> executionResult.cortexToolExecutionRecords
              case executionResult.cortexToolExecutionTerminalError of
                Just errText ->
                  pure
                    CortexToolLoopResult
                      { cortexToolLoopResultText = errText
                      , cortexToolLoopResultRecords = mergedRecords
                      }
                Nothing ->
                  let nextMessages =
                        messages
                          <> [assistantToolCallsMessage choice.cortexChoiceContent choice.cortexChoiceToolCalls]
                          <> compactToolExecutionMessages executionResult
                   in loop stepNumber nextMessages mergedRecords

compactToolExecutionMessages :: CortexToolExecutionResult -> [Aeson.Value]
compactToolExecutionMessages executionResult =
  case fmap compactToolRecordMessage executionResult.cortexToolExecutionRecords of
    [] -> executionResult.cortexToolExecutionMessages
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
