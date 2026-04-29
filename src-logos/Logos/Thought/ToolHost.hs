{- |
Module      : Logos.Thought.ToolHost
Description : Logos reasoning-library support for tool host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.ToolHost
  ( LogosTaskToolHost (..)
  , LogosToolExecutionResult (..)
  , executeTaskToolCalls
  , taskToolHostBase
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Logos.Thought.Host
  ( LogosTaskHost
  )

import Cortex.Capability.Model.Types
  ( CortexToolCall
  )
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord
  )

data LogosToolExecutionResult = LogosToolExecutionResult
  { logosToolExecutionMessages :: [Aeson.Value]
  , logosToolExecutionRecords :: [CortexToolCallRecord]
  , logosToolExecutionTerminalError :: Maybe Text
  }
  deriving stock (Eq, Show)

data LogosTaskToolHost m = LogosTaskToolHost
  { logosTaskToolHostTaskHost :: LogosTaskHost m
  , logosTaskToolHostExecuteToolCalls :: Int -> [CortexToolCall] -> m LogosToolExecutionResult
  }

taskToolHostBase :: LogosTaskToolHost m -> LogosTaskHost m
taskToolHostBase = logosTaskToolHostTaskHost

executeTaskToolCalls
  :: LogosTaskToolHost m -> Int -> [CortexToolCall] -> m LogosToolExecutionResult
executeTaskToolCalls = logosTaskToolHostExecuteToolCalls
