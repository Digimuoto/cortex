{- | Public epistemological reasoning surface.

Nous collects the reusable reasoning-mode machinery that sits above the
Wire/Circuit/Pulse substrate: canonical archetypes, model policy, task hosts,
structured task loops, report sections, and event emission.
-}
module Cortex.Nous
  ( CortexEvent (..)
  , CortexEventEmitter
  , CortexEventKind (..)
  , module Cortex.Nous.Archetypes
  , module Cortex.Nous.Memory
  , module Cortex.Nous.Patterns.DeepReport
  , module Cortex.Nous.Patterns.PlanReview
  , module Cortex.Nous.Thought
  , module Cortex.Nous.Types
  , emitRunAgentDone
  , emitRunAgentStart
  , emitRunError
  , emitRunSummary
  , emitRunThinking
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)

import Cortex.Nous.Archetypes
import Cortex.Nous.Memory
import Cortex.Nous.Patterns.DeepReport
import Cortex.Nous.Patterns.PlanReview
import Cortex.Nous.Thought
import Cortex.Nous.Thought.Event (CortexEvent (..), CortexEventEmitter, CortexEventKind (..))
import Cortex.Nous.Thought.Event qualified as RunEngine
import Cortex.Nous.Types

{- | Low-level run-event start emitter.

Task-level emitters remain exported from 'Cortex.Nous.Thought.Runtime' under their
existing names. The run-level emitters are prefixed here so the public Nous
facade can expose both surfaces without ambiguous names.
-}
emitRunAgentStart :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentStart = RunEngine.emitAgentStart

-- | Low-level run-event completion emitter.
emitRunAgentDone :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentDone = RunEngine.emitAgentDone

-- | Low-level run-event thinking emitter.
emitRunThinking :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunThinking = RunEngine.emitThinking

-- | Low-level run-event summary emitter.
emitRunSummary
  :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitRunSummary = RunEngine.emitSummary

-- | Low-level run-event error emitter.
emitRunError :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunError = RunEngine.emitError
