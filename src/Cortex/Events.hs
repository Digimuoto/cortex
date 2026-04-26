{-# LANGUAGE DerivingStrategies #-}

module Cortex.Events
  ( CortexEventKind (..),
    CortexEvent (..),
    CortexEventEmitter,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)

data CortexEventKind
  = CortexEventAgentStart
  | CortexEventAgentDone
  | CortexEventThinking
  | CortexEventSummary
  | CortexEventError
  deriving stock (Eq, Show)

data CortexEvent = CortexEvent
  { cortexEventKind :: CortexEventKind,
    cortexEventAgentName :: Maybe Text,
    cortexEventStageName :: Maybe Text,
    cortexEventStep :: Maybe Int,
    cortexEventToolName :: Maybe Text,
    cortexEventTitle :: Text,
    cortexEventSummary :: Maybe Text,
    cortexEventPreview :: Maybe Aeson.Value,
    cortexEventDurationMs :: Maybe Int
  }
  deriving stock (Eq, Show)

type CortexEventEmitter = CortexEvent -> IO ()
