module Cortex.Task.ToolHost
  ( CortexTaskToolHost (..),
    CortexToolExecutionResult (..),
    executeTaskToolCalls,
    taskToolHostBase,
  )
where

import Cortex.Capability.Model.Types
  ( CortexToolCall,
  )
import Cortex.Capability.Tool.Record
  ( CortexToolCallRecord,
  )
import Cortex.Task.Host
  ( CortexTaskHost,
  )
import Data.Aeson qualified as Aeson
import Data.Text (Text)

data CortexToolExecutionResult = CortexToolExecutionResult
  { cortexToolExecutionMessages :: [Aeson.Value],
    cortexToolExecutionRecords :: [CortexToolCallRecord],
    cortexToolExecutionTerminalError :: Maybe Text
  }
  deriving stock (Eq, Show)

data CortexTaskToolHost m = CortexTaskToolHost
  { cortexTaskToolHostTaskHost :: CortexTaskHost m,
    cortexTaskToolHostExecuteToolCalls :: Int -> [CortexToolCall] -> m CortexToolExecutionResult
  }

taskToolHostBase :: CortexTaskToolHost m -> CortexTaskHost m
taskToolHostBase = cortexTaskToolHostTaskHost

executeTaskToolCalls :: CortexTaskToolHost m -> Int -> [CortexToolCall] -> m CortexToolExecutionResult
executeTaskToolCalls = cortexTaskToolHostExecuteToolCalls
