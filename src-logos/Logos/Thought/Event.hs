{- |
Module      : Logos.Thought.Event
Description : Logos reasoning-library support for event.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Event
  ( LogosEventKind (..)
  , LogosEvent (..)
  , LogosEventEmitter
  , emitAgentDone
  , emitAgentStart
  , emitError
  , emitSummary
  , emitThinking
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Logos.Thought.Stage

data LogosEventKind
  = LogosEventAgentStart
  | LogosEventAgentDone
  | LogosEventThinking
  | LogosEventSummary
  | LogosEventError
  deriving stock (Eq, Show)

data LogosEvent = LogosEvent
  { logosEventKind :: LogosEventKind
  , logosEventAgentName :: Maybe Text
  , logosEventStageName :: Maybe Text
  , logosEventStep :: Maybe Int
  , logosEventToolName :: Maybe Text
  , logosEventTitle :: Text
  , logosEventSummary :: Maybe Text
  , logosEventPreview :: Maybe Aeson.Value
  , logosEventDurationMs :: Maybe Int
  }
  deriving stock (Eq, Show)

type LogosEventEmitter = LogosEvent -> IO ()

emitAgentStart :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentStart emit descriptor title summary =
  emit $
    LogosEvent
      { logosEventKind = LogosEventAgentStart
      , logosEventAgentName = descriptor.logosStageAgentName
      , logosEventStageName = descriptor.logosStageStageName
      , logosEventStep = descriptor.logosStageStep
      , logosEventToolName = descriptor.logosStageToolName
      , logosEventTitle = title
      , logosEventSummary = summary
      , logosEventPreview = Nothing
      , logosEventDurationMs = Nothing
      }

emitAgentDone :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitAgentDone emit descriptor title summary =
  emit $
    LogosEvent
      { logosEventKind = LogosEventAgentDone
      , logosEventAgentName = descriptor.logosStageAgentName
      , logosEventStageName = descriptor.logosStageStageName
      , logosEventStep = descriptor.logosStageStep
      , logosEventToolName = descriptor.logosStageToolName
      , logosEventTitle = title
      , logosEventSummary = summary
      , logosEventPreview = Nothing
      , logosEventDurationMs = Nothing
      }

emitThinking :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitThinking emit descriptor title summary =
  emit $
    LogosEvent
      { logosEventKind = LogosEventThinking
      , logosEventAgentName = descriptor.logosStageAgentName
      , logosEventStageName = descriptor.logosStageStageName
      , logosEventStep = descriptor.logosStageStep
      , logosEventToolName = descriptor.logosStageToolName
      , logosEventTitle = title
      , logosEventSummary = summary
      , logosEventPreview = Nothing
      , logosEventDurationMs = Nothing
      }

emitSummary
  :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitSummary emit descriptor title summary preview =
  emit $
    LogosEvent
      { logosEventKind = LogosEventSummary
      , logosEventAgentName = descriptor.logosStageAgentName
      , logosEventStageName = descriptor.logosStageStageName
      , logosEventStep = descriptor.logosStageStep
      , logosEventToolName = descriptor.logosStageToolName
      , logosEventTitle = title
      , logosEventSummary = summary
      , logosEventPreview = preview
      , logosEventDurationMs = Nothing
      }

emitError :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitError emit descriptor title summary =
  emit $
    LogosEvent
      { logosEventKind = LogosEventError
      , logosEventAgentName = descriptor.logosStageAgentName
      , logosEventStageName = descriptor.logosStageStageName
      , logosEventStep = descriptor.logosStageStep
      , logosEventToolName = descriptor.logosStageToolName
      , logosEventTitle = title
      , logosEventSummary = summary
      , logosEventPreview = Nothing
      , logosEventDurationMs = Nothing
      }
