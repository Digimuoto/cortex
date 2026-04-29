{- |
Module      : Logos.Thought.Host
Description : Logos reasoning-library support for host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Host
  ( LogosTaskHost (..)
  , requestTaskChoice
  , taskEventEmitter
  , throwIfTaskCanceled
  )
where

import Logos.Thought.Event (LogosEventEmitter)

import Cortex.Capability.Model.Client (CortexModelClient (..))
import Cortex.Capability.Model.Types
  ( CortexChoice
  , CortexChoiceRequest
  )

data LogosTaskHost m = LogosTaskHost
  { logosTaskModelClient :: CortexModelClient m
  , logosTaskThrowIfCanceled :: m ()
  , logosTaskEmitEvent :: LogosEventEmitter
  }

requestTaskChoice :: LogosTaskHost m -> CortexChoiceRequest -> m CortexChoice
requestTaskChoice host = requestCortexChoice (logosTaskModelClient host)

throwIfTaskCanceled :: LogosTaskHost m -> m ()
throwIfTaskCanceled = logosTaskThrowIfCanceled

taskEventEmitter :: LogosTaskHost m -> LogosEventEmitter
taskEventEmitter = logosTaskEmitEvent
