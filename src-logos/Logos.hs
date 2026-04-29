{- |
Module      : Logos
Description : Public epistemological reasoning surface.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Logos collects the reusable reasoning-mode machinery that sits above the
Wire/Circuit/Pulse substrate: canonical archetypes, model policy, task hosts,
structured task loops, report sections, and event emission.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos
  ( LogosEvent (..)
  , LogosEventEmitter
  , LogosEventKind (..)
  , module Logos.Archetypes
  , module Logos.Memory
  , module Logos.Patterns.DeepReport
  , module Logos.Patterns.PlanReview
  , module Logos.Thought
  , module Logos.Types
  , emitRunAgentDone
  , emitRunAgentStart
  , emitRunError
  , emitRunSummary
  , emitRunThinking
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Logos.Archetypes
import Logos.Memory
import Logos.Patterns.DeepReport
import Logos.Patterns.PlanReview
import Logos.Thought
import Logos.Thought.Event (LogosEvent (..), LogosEventEmitter, LogosEventKind (..))
import Logos.Thought.Event qualified as RunEngine
import Logos.Types

{- | Low-level run-event start emitter.

Task-level emitters remain exported from 'Logos.Thought.Runtime' under their
existing names. The run-level emitters are prefixed here so the public Logos
facade can expose both surfaces without ambiguous names.
-}
emitRunAgentStart :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentStart = RunEngine.emitAgentStart

-- | Low-level run-event completion emitter.
emitRunAgentDone :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentDone = RunEngine.emitAgentDone

-- | Low-level run-event thinking emitter.
emitRunThinking :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunThinking = RunEngine.emitThinking

-- | Low-level run-event summary emitter.
emitRunSummary
  :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitRunSummary = RunEngine.emitSummary

-- | Low-level run-event error emitter.
emitRunError :: LogosEventEmitter -> LogosStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunError = RunEngine.emitError
