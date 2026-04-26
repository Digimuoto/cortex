-- | Public reasoning/workflow surface.
--
-- Logoi collect the reusable reasoning-mode machinery that sits above the
-- Wire/Circuit/Pulse substrate: model policy, task hosts, structured task
-- loops, report sections, and event emission.
module Cortex.Logoi
  ( module Cortex.Agent.Config,
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
-- existing names. The run-level emitters are prefixed here so the public Logoi
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
