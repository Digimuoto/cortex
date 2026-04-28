{- |
Module      : Cortex.Nous.Thought.ToolHost
Description : Nous reasoning-library support for tool host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Thought.ToolHost
  ( CortexTaskToolHost (..)
  , CortexToolExecutionResult (..)
  , executeTaskToolCalls
  , taskToolHostBase
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)

import Cortex.Capability.Model.Types
  ( CortexToolCall
  )
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord
  )
import Cortex.Nous.Thought.Host
  ( CortexTaskHost
  )

data CortexToolExecutionResult = CortexToolExecutionResult
  { cortexToolExecutionMessages :: [Aeson.Value]
  , cortexToolExecutionRecords :: [CortexToolCallRecord]
  , cortexToolExecutionTerminalError :: Maybe Text
  }
  deriving stock (Eq, Show)

data CortexTaskToolHost m = CortexTaskToolHost
  { cortexTaskToolHostTaskHost :: CortexTaskHost m
  , cortexTaskToolHostExecuteToolCalls :: Int -> [CortexToolCall] -> m CortexToolExecutionResult
  }

taskToolHostBase :: CortexTaskToolHost m -> CortexTaskHost m
taskToolHostBase = cortexTaskToolHostTaskHost

executeTaskToolCalls
  :: CortexTaskToolHost m -> Int -> [CortexToolCall] -> m CortexToolExecutionResult
executeTaskToolCalls = cortexTaskToolHostExecuteToolCalls
