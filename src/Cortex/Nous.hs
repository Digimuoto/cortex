-- | Public epistemological reasoning surface.
--
-- Nous collects the reusable reasoning-mode machinery that sits above the
-- Wire/Circuit/Pulse substrate: canonical archetypes, model policy, task hosts,
-- structured task loops, report sections, and event emission.
module Cortex.Nous
  ( module Cortex.Agent.Config,
    module Cortex.Nous.Episteme,
    module Cortex.Nous.Episteme.Capability,
    module Cortex.Nous.Kritikos,
    module Cortex.Nous.Kritikos.Capability,
    module Cortex.Nous.Logos,
    module Cortex.Nous.Logos.Capability,
    module Cortex.Nous.Poiesis,
    module Cortex.Nous.Poiesis.Capability,
    module Cortex.Nous.Sophia,
    module Cortex.Nous.Sophia.Capability,
    module Cortex.Nous.Techne,
    module Cortex.Nous.Techne.Capability,
    module Cortex.Nous.Themis,
    module Cortex.Nous.Themis.Capability,
    module Cortex.Nous.Types,
    module Cortex.Research.Runtime,
    module Cortex.Research.Section,
    module Cortex.Run.Types,
    module Cortex.Task.Gather,
    module Cortex.Task.Host,
    module Cortex.Task.Plan,
    module Cortex.Task.Report,
    module Cortex.Task.Runtime,
    module Cortex.Task.StructuredOutput,
    module Cortex.Task.ToolHost,
    module Cortex.Task.ToolLoop,
    emitRunAgentDone,
    emitRunAgentStart,
    emitRunError,
    emitRunSummary,
    emitRunThinking,
  )
where

import Cortex.Agent.Config
import Cortex.Events (CortexEventEmitter)
import Cortex.Nous.Episteme
import Cortex.Nous.Episteme.Capability
import Cortex.Nous.Kritikos
import Cortex.Nous.Kritikos.Capability
import Cortex.Nous.Logos
import Cortex.Nous.Logos.Capability
import Cortex.Nous.Poiesis
import Cortex.Nous.Poiesis.Capability
import Cortex.Nous.Sophia
import Cortex.Nous.Sophia.Capability
import Cortex.Nous.Techne
import Cortex.Nous.Techne.Capability
import Cortex.Nous.Themis
import Cortex.Nous.Themis.Capability
import Cortex.Nous.Types
import Cortex.Research.Runtime
import Cortex.Research.Section
import Cortex.Run.Engine qualified as RunEngine
import Cortex.Run.Types
import Cortex.Task.Gather
import Cortex.Task.Host
import Cortex.Task.Plan
import Cortex.Task.Report
import Cortex.Task.Runtime
import Cortex.Task.StructuredOutput
import Cortex.Task.ToolHost
import Cortex.Task.ToolLoop
import Data.Aeson qualified as Aeson
import Data.Text (Text)

-- | Low-level run-event start emitter.
--
-- Task-level emitters remain exported from 'Cortex.Task.Runtime' under their
-- existing names. The run-level emitters are prefixed here so the public Nous
-- facade can expose both surfaces without ambiguous names.
emitRunAgentStart :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentStart = RunEngine.emitAgentStart

-- | Low-level run-event completion emitter.
emitRunAgentDone :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunAgentDone = RunEngine.emitAgentDone

-- | Low-level run-event thinking emitter.
emitRunThinking :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunThinking = RunEngine.emitThinking

-- | Low-level run-event summary emitter.
emitRunSummary :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> Maybe Aeson.Value -> IO ()
emitRunSummary = RunEngine.emitSummary

-- | Low-level run-event error emitter.
emitRunError :: CortexEventEmitter -> CortexStageDescriptor -> Text -> Maybe Text -> IO ()
emitRunError = RunEngine.emitError
