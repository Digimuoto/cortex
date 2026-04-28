-- | Cortex Pulse public facade and daemon entry point.
module Cortex.Pulse
  ( runPulse
  , module Cortex.Pulse.Executor
  , module Cortex.Pulse.Hydrate
  , module Cortex.Pulse.Materialize
  , module Cortex.Pulse.Memory
  , module Cortex.Pulse.Memory.Tool
  , module Cortex.Pulse.Node
  , module Cortex.Pulse.Persistence
  , module Cortex.Pulse.Query
  , module Cortex.Pulse.Rewrite
  , module Cortex.Pulse.Runtime
  , module Cortex.Pulse.Schema
  , module Cortex.Pulse.Signal
  , module Cortex.Pulse.Types
  )
where

import Control.Concurrent.Async (link, mapConcurrently_, withAsync)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (SomeException, catch, displayException)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID (UUID)
import System.Exit (exitFailure)
import System.Posix.Signals (Handler (CatchOnce), installHandler, sigINT, sigTERM)

import Cortex.Pulse.Executor (TaskContext (..), TaskRegistry)
import Cortex.Pulse.Executor qualified as Executor
import Cortex.Pulse.Health (PulseHealthState (..), initialHealthState, runHealthServer)
import Cortex.Pulse.Hydrate
import Cortex.Pulse.Materialize
import Cortex.Pulse.Memory
import Cortex.Pulse.Memory.Tool
import Cortex.Pulse.Node
import Cortex.Pulse.Persistence
import Cortex.Pulse.Query hiding (recordRunEvent)
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite
import Cortex.Pulse.Runtime
import Cortex.Pulse.Scheduler qualified as Scheduler
import Cortex.Pulse.Schema
import Cortex.Pulse.Signal
import Cortex.Pulse.Types

import Platform.Database qualified as DB
import Platform.DurableTask.Error qualified as Err
import Platform.DurableTask.Types (triggerSourceFromText)
import Platform.Observability
  ( LogEventSpec (..)
  , ObservabilityLogLevel (..)
  , defaultLogEvent
  , defaultPortmanEnvConfig
  , emitEvent
  , emitGlobalEvent
  , initObservabilityRuntime
  , installGlobalObservabilityRuntime
  , loadObservabilityConfig
  )

-- | Main entry point for the Cortex Pulse daemon.
runPulse :: TaskRegistry -> PulseConfig -> IO ()
runPulse registry rawConfig = do
  -- 0. Validate config: clamp concurrency limits to at least 1
  let config =
        rawConfig
          { pulseMaxConcurrentTasks = max 1 (pulseMaxConcurrentTasks rawConfig)
          , pulseMaxFrontierConcurrency = min 16 (max 1 (pulseMaxFrontierConcurrency rawConfig))
          , pulseTaskTypeLimits = Map.map (max 1) (pulseTaskTypeLimits rawConfig)
          }

  -- 1. Observability
  obsConfig <- loadObservabilityConfig defaultPortmanEnvConfig "cortex-pulse"
  obsRuntime <- initObservabilityRuntime obsConfig
  installGlobalObservabilityRuntime obsRuntime

  emitEvent (Just obsRuntime) $
    (defaultLogEvent ObsInfo "cortex-pulse" "pulse.start" "Starting Cortex Pulse")
      { eventOutcome = "starting"
      , eventExtraFields =
          [ ("lease_owner", Aeson.toJSON (pulseLeaseOwner config))
          , ("health_port", Aeson.toJSON (pulseHealthPort config))
          , ("max_concurrent_tasks", Aeson.toJSON (pulseMaxConcurrentTasks config))
          , ("max_frontier_concurrency", Aeson.toJSON (pulseMaxFrontierConcurrency config))
          , ("task_type_limits", Aeson.toJSON (pulseTaskTypeLimits config))
          ]
      }

  -- 2. DB pool
  let dbConfig =
        DB.ConnectionConfig
          { DB.dbHost = pulseDbHost config
          , DB.dbPort = pulseDbPort config
          , DB.dbUser = pulseDbUser config
          , DB.dbPassword = pulseDbPassword config
          , DB.dbDatabase = pulseDbName config
          , DB.dbPoolSize = pulseDbPoolSize config
          , DB.dbPoolTimeout = 30
          }
  pool <- DB.createPool dbConfig

  -- 3. Shutdown flag + health state
  shutdownFlag <- newTVarIO False
  healthState <-
    newTVarIO (initialHealthState (pulseLeaseOwner config) (pulseMaxConcurrentTasks config))

  -- Install signal handlers that set the shutdown flag for graceful drain.
  -- The scheduler checks this flag each iteration and stops claiming new work.
  -- In-flight tasks continue to the next checkpoint before the process exits.
  let requestShutdown = atomically $ writeTVar shutdownFlag True
  _ <- installHandler sigINT (CatchOnce requestShutdown) Nothing
  _ <- installHandler sigTERM (CatchOnce requestShutdown) Nothing

  -- 4. Startup recovery
  now <- getCurrentTime
  let leaseOwner = pulseLeaseOwner config
      leaseDuration = fromIntegral (pulseLeaseDurationSeconds config)

  -- 4a. Reclaim owned runs (this instance's previous incarnation)
  reclaimResult <- DB.withConnection pool $ Q.reclaimOwnedRuns leaseOwner now leaseDuration
  reclaimedRunIds <- case reclaimResult of
    Left err -> do
      emitEvent (Just obsRuntime) $
        ( defaultLogEvent
            ObsWarn
            "cortex-pulse"
            "pulse.recovery.reclaim"
            ("Failed to reclaim runs: " <> T.pack err)
        )
          { eventOutcome = "error"
          }
      pure []
    Right ids -> do
      emitEvent (Just obsRuntime) $
        (defaultLogEvent ObsInfo "cortex-pulse" "pulse.recovery.reclaim" "Reclaimed owned runs")
          { eventOutcome = "success"
          , eventExtraFields =
              [ ("reclaimed_count", Aeson.toJSON (length ids))
              , ("run_ids", Aeson.toJSON ids)
              ]
          }
      pure ids

  -- 4b. Recover expired foreign-owner runs
  expiredResult <- Scheduler.recoverExpiredRuns pool leaseOwner now
  expiredCount <- case expiredResult of
    Left err -> do
      emitEvent (Just obsRuntime) $
        ( defaultLogEvent
            ObsWarn
            "cortex-pulse"
            "pulse.recovery.expired"
            ("Failed to recover expired runs: " <> T.pack err)
        )
          { eventOutcome = "error"
          }
      pure 0
    Right count -> do
      emitEvent (Just obsRuntime) $
        (defaultLogEvent ObsInfo "cortex-pulse" "pulse.recovery.expired" "Recovered expired runs")
          { eventOutcome = "success"
          , eventExtraFields = [("expired_count", Aeson.toJSON count)]
          }
      pure count

  -- Update health state with recovery outcome
  let runningHealth =
        (initialHealthState leaseOwner (pulseMaxConcurrentTasks config))
          { phsStatus = "running"
          , phsReclaimedRunCount = length reclaimedRunIds
          , phsExpiredRecoveryCount = fromIntegral expiredCount
          }
  atomically $ writeTVar healthState runningHealth

  -- 4c. Prepare task context used by both reclaimed execution and the scheduler.
  let taskContext =
        TaskContext
          { tcPool = pool
          , tcConfig = config
          , tcShutdownFlag = shutdownFlag
          }

  emitEvent (Just obsRuntime) $
    (defaultLogEvent ObsInfo "cortex-pulse" "pulse.ready" "Pulse ready, entering scheduler loop")
      { eventOutcome = "running"
      }

  -- 5. Start health server, resume reclaimed runs in the background, and enter
  -- the scheduler loop immediately so pending manual runs are not blocked
  -- behind a long-running reclaimed execution.
  let mainLoop =
        withAsync (runHealthServer (pulseHealthPort config) healthState) $ \healthAsync -> do
          link healthAsync
          withAsync (resumeReclaimedRuns registry taskContext leaseDuration reclaimedRunIds) $ \reclaimAsync -> do
            link reclaimAsync
            Scheduler.runSchedulerLoop registry taskContext healthState

  -- The scheduler loop exits when shutdownFlag is set (by signal handler).
  -- Catch unexpected exceptions only.
  mainLoop `catch` \(e :: SomeException) -> do
    emitEvent (Just obsRuntime) $
      (defaultLogEvent ObsError "cortex-pulse" "pulse.stop" "Pulse stopped with exception")
        { eventOutcome = "error"
        , eventExtraFields = [("error", Aeson.toJSON (displayException e))]
        }
    exitFailure

  -- Normal shutdown path (shutdownFlag was set, scheduler loop returned)
  emitEvent (Just obsRuntime) $
    (defaultLogEvent ObsInfo "cortex-pulse" "pulse.stop" "Pulse stopped gracefully")
      { eventOutcome = "success"
      }

{- | Resume reclaimed runs by loading their task definitions and calling the executor.
Processes in chunks bounded by the configured maxConcurrentTasks.
-}
resumeReclaimedRuns :: TaskRegistry -> TaskContext -> Int32 -> [UUID] -> IO ()
resumeReclaimedRuns _ _ _ [] = pure ()
resumeReclaimedRuns registry taskContext leaseDuration runIds =
  mapM_ resumeChunk (chunksOf maxConcurrent runIds)
  where
    maxConcurrent = pulseMaxConcurrentTasks (tcConfig taskContext)
    resumeChunk =
      mapConcurrently_ (resumeOneRun registry taskContext leaseDuration)

resumeOneRun :: TaskRegistry -> TaskContext -> Int32 -> UUID -> IO ()
resumeOneRun registry taskContext leaseDuration runId = do
  let pool = taskContext.tcPool
  taskResult <- DB.withConnection pool $ Q.getTaskForRun runId
  case taskResult of
    Left err -> do
      -- Fail the run AND restore the parent task's schedule so it can be
      -- retried on the next startup (transient DB errors shouldn't orphan tasks)
      now <- getCurrentTime
      Err.logDbFailure_
        ( \dbErr ->
            emitEvent'
              ObsError
              "pulse.recovery.resume.db"
              ( "Failed to mark run as failed during startup recovery — run will remain 'running' until lease expires: "
                  <> T.pack dbErr
              )
              [("run_id", Aeson.toJSON runId)]
        )
        ( DB.runTransaction pool $
            Q.updateRunFailed
              Q.RunFailureUpdate
                { rfuRunId = runId
                , rfuCompletedAt = now
                , rfuErrType = "startup_load_error"
                , rfuErrMsg = T.pack err
                , rfuRetryable = True
                }
        )
      -- Restore task schedule: set next_run_at so the task is discoverable again
      restoreResult <- DB.withConnection pool $ Q.restoreTaskForFailedRun runId (addUTCTime 60 now) now
      case restoreResult of
        Left dbErr ->
          emitEvent'
            ObsError
            "pulse.recovery.resume"
            ( "Failed to load task for run — run marked as failed but schedule restore FAILED. "
                <> "Task may be orphaned (next_run_at = NULL). Restore error: "
                <> T.pack dbErr
                <> " — Original error: "
                <> T.pack err
            )
            [("run_id", Aeson.toJSON runId)]
        Right () ->
          emitEvent'
            ObsError
            "pulse.recovery.resume"
            ("Failed to load task for run, marked as failed, schedule restored: " <> T.pack err)
            [("run_id", Aeson.toJSON runId)]
    Right Nothing -> do
      now <- getCurrentTime
      Err.logDbFailure_
        ( \dbErr ->
            emitEvent'
              ObsError
              "pulse.recovery.resume.db"
              ( "Failed to mark run as failed (task not found) — run will remain 'running' until lease expires: "
                  <> T.pack dbErr
              )
              [("run_id", Aeson.toJSON runId)]
        )
        ( DB.runTransaction pool $
            Q.updateRunFailed
              Q.RunFailureUpdate
                { rfuRunId = runId
                , rfuCompletedAt = now
                , rfuErrType = "task_not_found"
                , rfuErrMsg = "Task definition missing for reclaimed run"
                , rfuRetryable = False
                }
        )
      emitEvent'
        ObsWarn
        "pulse.recovery.resume"
        "Task not found for reclaimed run, marked as failed"
        [("run_id", Aeson.toJSON runId)]
    Right (Just task) -> do
      emitEvent'
        ObsInfo
        "pulse.recovery.resume"
        "Resuming reclaimed run"
        [("run_id", Aeson.toJSON runId), ("task_name", Aeson.toJSON (task.taskName))]
      triggerSourceResult <- DB.withConnection pool $ Q.getRunAdminView runId
      triggerSource <-
        case triggerSourceResult of
          Right (Just runView) ->
            pure (triggerSourceFromText runView.pravTriggerSource)
          Right Nothing -> do
            emitEvent'
              ObsWarn
              "pulse.recovery.resume.trigger_source"
              "Run admin view missing when resuming reclaimed run; defaulting trigger source to 'unknown' to avoid advancing schedules"
              [("run_id", Aeson.toJSON runId)]
            pure Nothing
          Left dbErr -> do
            emitEvent'
              ObsError
              "pulse.recovery.resume.trigger_source"
              "Failed to load run admin view when resuming reclaimed run; defaulting trigger source to 'unknown' to avoid advancing schedules"
              [ ("run_id", Aeson.toJSON runId)
              , ("error", Aeson.toJSON (T.pack dbErr))
              ]
            pure Nothing
      outcome <-
        Scheduler.withLeaseRenewal pool runId leaseDuration $
          Executor.resumeTask registry taskContext runId task
      endTime <- getCurrentTime
      Scheduler.finalizeTaskSchedule pool (Just runId) task triggerSource endTime outcome
  where
    emitEvent' level op msg extra =
      emitGlobalEvent $
        (defaultLogEvent level "cortex-pulse" op msg)
          { eventExtraFields = extra
          }

-- | Split a list into chunks of at most @n@ elements.
chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (chunk, rest) = splitAt n xs in chunk : chunksOf n rest
