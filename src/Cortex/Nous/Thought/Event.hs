{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Nous.Thought.Event
  ( CortexEventKind (..)
  , CortexEvent (..)
  , CortexEventEmitter
  , emitAgentDone
  , emitAgentStart
  , emitError
  , emitSummary
  , emitThinking
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)

import Cortex.Nous.Thought.Stage

data CortexEventKind
  = CortexEventAgentStart
  | CortexEventAgentDone
  | CortexEventThinking
  | CortexEventSummary
  | CortexEventError
  deriving stock (Eq, Show)

data CortexEvent = CortexEvent
  { cortexEventKind :: CortexEventKind
  , cortexEventAgentName :: Maybe Text
  , cortexEventStageName :: Maybe Text
  , cortexEventStep :: Maybe Int
  , cortexEventToolName :: Maybe Text
  , cortexEventTitle :: Text
  , cortexEventSummary :: Maybe Text
  , cortexEventPreview :: Maybe Aeson.Value
  , cortexEventDurationMs :: Maybe Int
  }
  deriving stock (Eq, Show)

type CortexEventEmitter = CortexEvent -> IO ()

emitAgentStart :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentStart emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventAgentStart
      , cortexEventAgentName = descriptor.cortexStageAgentName
      , cortexEventStageName = descriptor.cortexStageStageName
      , cortexEventStep = descriptor.cortexStageStep
      , cortexEventToolName = descriptor.cortexStageToolName
      , cortexEventTitle = title
      , cortexEventSummary = summary
      , cortexEventPreview = Nothing
      , cortexEventDurationMs = Nothing
      }

emitAgentDone :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentDone emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventAgentDone
      , cortexEventAgentName = descriptor.cortexStageAgentName
      , cortexEventStageName = descriptor.cortexStageStageName
      , cortexEventStep = descriptor.cortexStageStep
      , cortexEventToolName = descriptor.cortexStageToolName
      , cortexEventTitle = title
      , cortexEventSummary = summary
      , cortexEventPreview = Nothing
      , cortexEventDurationMs = Nothing
      }

emitThinking :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitThinking emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventThinking
      , cortexEventAgentName = descriptor.cortexStageAgentName
      , cortexEventStageName = descriptor.cortexStageStageName
      , cortexEventStep = descriptor.cortexStageStep
      , cortexEventToolName = descriptor.cortexStageToolName
      , cortexEventTitle = title
      , cortexEventSummary = summary
      , cortexEventPreview = Nothing
      , cortexEventDurationMs = Nothing
      }

emitSummary
  :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitSummary emit descriptor title summary preview =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventSummary
      , cortexEventAgentName = descriptor.cortexStageAgentName
      , cortexEventStageName = descriptor.cortexStageStageName
      , cortexEventStep = descriptor.cortexStageStep
      , cortexEventToolName = descriptor.cortexStageToolName
      , cortexEventTitle = title
      , cortexEventSummary = summary
      , cortexEventPreview = preview
      , cortexEventDurationMs = Nothing
      }

emitError :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitError emit descriptor title summary =
  emit $
    CortexEvent
      { cortexEventKind = CortexEventError
      , cortexEventAgentName = descriptor.cortexStageAgentName
      , cortexEventStageName = descriptor.cortexStageStageName
      , cortexEventStep = descriptor.cortexStageStep
      , cortexEventToolName = descriptor.cortexStageToolName
      , cortexEventTitle = title
      , cortexEventSummary = summary
      , cortexEventPreview = Nothing
      , cortexEventDurationMs = Nothing
      }
