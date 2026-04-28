{- |
Module      : Cortex.Nous.Thought.Host
Description : Nous reasoning-library support for host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Thought.Host
  ( CortexTaskHost (..)
  , requestTaskChoice
  , taskEventEmitter
  , throwIfTaskCanceled
  )
where

import Cortex.Capability.Model.Client (CortexModelClient (..))
import Cortex.Capability.Model.Types
  ( CortexChoice
  , CortexChoiceRequest
  )
import Cortex.Nous.Thought.Event (CortexEventEmitter)

data CortexTaskHost m = CortexTaskHost
  { cortexTaskModelClient :: CortexModelClient m
  , cortexTaskThrowIfCanceled :: m ()
  , cortexTaskEmitEvent :: CortexEventEmitter
  }

requestTaskChoice :: CortexTaskHost m -> CortexChoiceRequest -> m CortexChoice
requestTaskChoice host = requestCortexChoice (cortexTaskModelClient host)

throwIfTaskCanceled :: CortexTaskHost m -> m ()
throwIfTaskCanceled = cortexTaskThrowIfCanceled

taskEventEmitter :: CortexTaskHost m -> CortexEventEmitter
taskEventEmitter = cortexTaskEmitEvent
