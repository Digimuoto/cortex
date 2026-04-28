module Cortex.Nous.Thought.Host
  ( CortexTaskHost (..),
    requestTaskChoice,
    taskEventEmitter,
    throwIfTaskCanceled,
  )
where

import Cortex.Capability.Model.Client (CortexModelClient (..))
import Cortex.Capability.Model.Types
  ( CortexChoice,
    CortexChoiceRequest,
  )
import Cortex.Nous.Thought.Event (CortexEventEmitter)

data CortexTaskHost m = CortexTaskHost
  { cortexTaskModelClient :: CortexModelClient m,
    cortexTaskThrowIfCanceled :: m (),
    cortexTaskEmitEvent :: CortexEventEmitter
  }

requestTaskChoice :: CortexTaskHost m -> CortexChoiceRequest -> m CortexChoice
requestTaskChoice host = requestCortexChoice (cortexTaskModelClient host)

throwIfTaskCanceled :: CortexTaskHost m -> m ()
throwIfTaskCanceled = cortexTaskThrowIfCanceled

taskEventEmitter :: CortexTaskHost m -> CortexEventEmitter
taskEventEmitter = cortexTaskEmitEvent
