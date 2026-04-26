{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Run.Engine
  ( emitAgentDone,
    emitAgentStart,
    emitError,
    emitSummary,
    emitThinking,
  )
where

import Cortex.Events
import Cortex.Run.Types
import Data.Aeson qualified as Aeson
import Data.Text (Text)

emitAgentStart :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentStart emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventAgentStart,
        cortexEventAgentName = descriptor.cortexStageAgentName,
        cortexEventStageName = descriptor.cortexStageStageName,
        cortexEventStep = descriptor.cortexStageStep,
        cortexEventToolName = descriptor.cortexStageToolName,
        cortexEventTitle = title,
        cortexEventSummary = summary,
        cortexEventPreview = Nothing,
        cortexEventDurationMs = Nothing
      }

emitAgentDone :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentDone emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventAgentDone,
        cortexEventAgentName = descriptor.cortexStageAgentName,
        cortexEventStageName = descriptor.cortexStageStageName,
        cortexEventStep = descriptor.cortexStageStep,
        cortexEventToolName = descriptor.cortexStageToolName,
        cortexEventTitle = title,
        cortexEventSummary = summary,
        cortexEventPreview = Nothing,
        cortexEventDurationMs = Nothing
      }

emitThinking :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitThinking emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventThinking,
        cortexEventAgentName = descriptor.cortexStageAgentName,
        cortexEventStageName = descriptor.cortexStageStageName,
        cortexEventStep = descriptor.cortexStageStep,
        cortexEventToolName = descriptor.cortexStageToolName,
        cortexEventTitle = title,
        cortexEventSummary = summary,
        cortexEventPreview = Nothing,
        cortexEventDurationMs = Nothing
      }

emitSummary :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitSummary emit descriptor title summary preview =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventSummary,
        cortexEventAgentName = descriptor.cortexStageAgentName,
        cortexEventStageName = descriptor.cortexStageStageName,
        cortexEventStep = descriptor.cortexStageStep,
        cortexEventToolName = descriptor.cortexStageToolName,
        cortexEventTitle = title,
        cortexEventSummary = summary,
        cortexEventPreview = preview,
        cortexEventDurationMs = Nothing
      }

emitError :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitError emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventError,
        cortexEventAgentName = descriptor.cortexStageAgentName,
        cortexEventStageName = descriptor.cortexStageStageName,
        cortexEventStep = descriptor.cortexStageStep,
        cortexEventToolName = descriptor.cortexStageToolName,
        cortexEventTitle = title,
        cortexEventSummary = summary,
        cortexEventPreview = Nothing,
        cortexEventDurationMs = Nothing
      }
