{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Pulse scheduler: discovers due tasks, creates fresh runs, and manages
the poll loop. Startup reclaim happens before the poll loop; expired-run
recovery continues on every poll iteration.
-}
module Cortex.Pulse.Scheduler
  ( runSchedulerLoop
  , recoverExpiredRuns
  , withLeaseRenewal
  , finalizeTaskSchedule
  , computeExcludedTypes
  , RunMetadata (..)
  )
where

import Control.Concurrent.Async (Async, cancel, poll, race, waitCatch, withAsync)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Hasql.Transaction (Transaction)
import Rel8 (Result)

import Cortex.Pulse.Executor (TaskContext (..), TaskRegistry)
import Cortex.Pulse.Executor qualified as Executor
import Cortex.Pulse.Health (PulseHealthState (..))
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Types (PulseConfig (..))

import Platform.Database qualified as DB
import Platform.DurableTask.Error qualified as Err
import Platform.DurableTask.Polling qualified as Polling
import Platform.DurableTask.Pool qualified as Pool
import Platform.DurableTask.Schedule
  ( ExecutionOrigin (..)
  , ScheduleConfig (..)
  , ScheduleDecision (..)
  , ScheduleKind (..)
  , decideScheduleAction
  )
import Platform.DurableTask.Types
  ( RunOutcome (..)
  , RunStatus
  , TriggerSource (..)
  , runOutcomeToFinalStatus
  , runOutcomeToText
  , triggerSourceFromText
  , triggerSourceToText
  )
import Platform.Observability
  ( ObservabilityLogLevel (..)
  , SubsystemEmitter (..)
  , emitSubsystemEvent
  )

-- | Metadata for an active task execution, stored alongside the pool's Async.
data RunMetadata = RunMetadata
  { rmTask :: PulseTaskDefinitionRow Result
  , rmTriggerSource :: Maybe TriggerSource
  }

{- | Compute which task types are at their per-type concurrency limit.
Returns the list of type names that should be excluded from claiming.
Types not in the limits map have no per-type cap (only the global limit applies).
-}
computeExcludedTypes :: Map Text Int -> Map UUID RunMetadata -> [Text]
computeExcludedTypes limits meta
  | Map.null limits = []
  | otherwise =
      let activeCounts = Map.fromListWith (+) [(m.rmTask.taskType, 1 :: Int) | m <- Map.elems meta]
       in [ taskType
          | (taskType, maxN) <- Map.toList limits
          , Map.findWithDefault 0 taskType activeCounts >= maxN
          ]

{- | Main scheduler poll loop. Runs until the shutdown flag is set and all
active runs have drained. Supports N concurrent task executions.
-}
runSchedulerLoop :: TaskRegistry -> TaskContext -> TVar PulseHealthState -> IO ()
runSchedulerLoop registry taskContext healthState = do
  now <- getCurrentTime
  runPool <- Pool.newTaskPool maxConcurrent
  runMeta <- newTVarIO (Map.empty :: Map UUID RunMetadata)
  -- Persists across poll ticks so round-robin works even when only 1 slot
  -- frees per tick. Contains the type of the last successfully launched task.
  lastClaimedTypeVar <- newTVarIO (Nothing :: Maybe Text)
  loop now runPool runMeta lastClaimedTypeVar
  where
    pool = taskContext.tcPool
    config = taskContext.tcConfig
    shutdownFlag = taskContext.tcShutdownFlag
    leaseOwner = pulseLeaseOwner config
    leaseDuration = fromIntegral (pulseLeaseDurationSeconds config)
    pollIntervalMicros = pulsePollIntervalSeconds config * 1_000_000
    maxConcurrent = pulseMaxConcurrentTasks config
    taskTypeLimits = pulseTaskTypeLimits config
    -- Run expired-run recovery on a fixed ~30s cadence regardless of poll interval
    recoveryIntervalSeconds = 30 :: NominalDiffTime

    loop lastRecoveryAt runPool runMeta lastClaimedTypeVar = do
      now <- getCurrentTime

      -- 1. Reap completed runs (finalize via metadata lookup)
      Pool.reapCompleted runPool $ \runId result -> do
        meta <- Map.lookup runId <$> readTVarIO runMeta
        atomically $ modifyTVar' runMeta (Map.delete runId)
        outcome <- case result of
          Right o -> pure o
          Left err -> markRunFailedForUnexpectedExit runId err
        endTime <- getCurrentTime
        let finalize = case meta of
              Just m -> finalizeTaskSchedule pool (Just runId) m.rmTask m.rmTriggerSource endTime outcome
              Nothing ->
                emitSchedulerEvent
                  ObsWarn
                  "pulse.scheduler.reap.meta_missing"
                  "Run metadata missing during reap"
                  [("run_id", Aeson.toJSON runId)]
        case outcome of
          OutcomeSuspended ->
            -- Run is suspended (waiting on signal), do NOT finalize the schedule.
            -- The run stays in 'waiting' status until a signal is delivered, at which
            -- point it transitions back to 'pending' and the scheduler re-claims it.
            emitSchedulerEvent
              ObsInfo
              "pulse.scheduler.reap.suspended"
              "Run suspended, awaiting signal"
              [("run_id", Aeson.toJSON runId)]
          OutcomeCompleted -> finalize
          OutcomeFailed -> finalize
          OutcomeCancelled -> finalize
          OutcomeTimedOut -> finalize
          OutcomeShutdown -> finalize

      -- 2. Recovery (time-based cadence)
      nextRecoveryAt <-
        if diffUTCTime now lastRecoveryAt >= recoveryIntervalSeconds
          then do
            Err.logDbFailure_
              ( \err ->
                  emitSchedulerEvent
                    ObsWarn
                    "pulse.scheduler.recovery.error"
                    ("Expired run recovery failed: " <> T.pack err)
                    []
              )
              (recoverExpiredRuns pool leaseOwner now)
            pure now
          else pure lastRecoveryAt

      -- 3. Fill available slots (unless shutting down)
      shouldStop <- readTVarIO shutdownFlag
      slots <- Pool.availableSlots runPool
      when (not shouldStop && slots > 0) $
        fillAvailableSlots runPool runMeta lastClaimedTypeVar slots now

      -- 4. Update health state after reap + fill for accurate reporting.
      -- Both total and per-type counts derive from runMeta so they are
      -- always consistent (sum of per-type == total).
      finalMeta <- readTVarIO runMeta
      let perTypeCounts = Map.fromListWith (+) [(m.rmTask.taskType, 1 :: Int) | m <- Map.elems finalMeta]
          finalCount = sum perTypeCounts
      atomically $ do
        hs <- readTVar healthState
        writeTVar
          healthState
          hs {phsHeartbeatAt = Just now, phsActiveRunCount = finalCount, phsActiveRunsByType = perTypeCounts}

      -- 5. Check shutdown: exit when draining is complete
      if shouldStop && finalCount == 0
        then
          emitSchedulerEvent
            ObsInfo
            "pulse.scheduler.shutdown"
            "Scheduler stopping (shutdown requested, all runs drained)"
            []
        else do
          -- During shutdown drain, poll more aggressively so the process exits
          -- promptly once active runs finish.
          let sleepMicros = if shouldStop then min pollIntervalMicros 100_000 else pollIntervalMicros
          Polling.threadDelayWithJitter sleepMicros 0.2
          loop nextRecoveryAt runPool runMeta lastClaimedTypeVar

    -- \| Try to claim and launch up to @slots@ tasks with round-robin fairness.
    -- Recomputes per-type exclusions after each launch so caps are enforced
    -- within a single fill cycle. Round-robin state (last claimed type) persists
    -- across poll ticks via @lastClaimedTypeVar@ so fairness works even when
    -- only one slot frees per tick.
    fillAvailableSlots
      :: Pool.TaskPool UUID RunOutcome
      -> TVar (Map UUID RunMetadata)
      -> TVar (Maybe Text)
      -> Int
      -> UTCTime
      -> IO ()
    fillAvailableSlots runPool runMeta lastClaimedTypeVar remaining now = do
      lastType <- readTVarIO lastClaimedTypeVar
      let initialDeprioritized = maybeToList lastType
      go initialDeprioritized remaining
      where
        go _ 0 = pure ()
        go deprioritizedTypes slotsLeft = do
          -- Recompute excluded types each iteration so per-type caps are
          -- enforced even when multiple runs launch in one fill cycle.
          meta <- readTVarIO runMeta
          let excluded = computeExcludedTypes taskTypeLimits meta
          claimed <- claimNextAvailableRun excluded deprioritizedTypes now
          case claimed of
            Nothing -> pure () -- no more work; CAS misses handled next poll tick
            Just (runId, task, triggerSource, runAction) -> do
              launchResult <- try (Pool.tryLaunch runPool runId runAction)
              case launchResult of
                Right Pool.LaunchAccepted -> atomically $ do
                  modifyTVar' runMeta (Map.insert runId (RunMetadata task triggerSource))
                  writeTVar lastClaimedTypeVar (Just task.taskType)
                Right other -> do
                  failAndDiscard pool runId now "launch_failed" "Pool rejected task launch after claim" True
                  finalizeTaskSchedule pool (Just runId) task triggerSource now OutcomeFailed
                  emitSchedulerEvent
                    ObsWarn
                    "pulse.scheduler.launch.rejected"
                    "Pool rejected task launch — run failed, schedule restored"
                    [("run_id", Aeson.toJSON runId), ("result", Aeson.toJSON (show other))]
                Left (e :: SomeException) -> do
                  failAndDiscard
                    pool
                    runId
                    now
                    "launch_spawn_failed"
                    ("Async spawn failed: " <> T.take 200 (T.pack (displayException e)))
                    True
                  finalizeTaskSchedule pool (Just runId) task triggerSource now OutcomeFailed
                  emitSchedulerEvent
                    ObsError
                    "pulse.scheduler.launch.spawn_failed"
                    "Spawn failed — run failed, schedule restored"
                    [("run_id", Aeson.toJSON runId), ("error", Aeson.toJSON (displayException e))]
              go (task.taskType : deprioritizedTypes) (slotsLeft - 1)

    claimNextAvailableRun
      :: [Text]
      -> [Text]
      -> UTCTime
      -> IO (Maybe (UUID, PulseTaskDefinitionRow Result, Maybe TriggerSource, IO RunOutcome))
    claimNextAvailableRun excluded deprioritized now = do
      pendingResult <-
        DB.runTransaction pool $ Q.claimNextPendingRun leaseOwner now leaseDuration excluded deprioritized
      case pendingResult of
        Left err -> do
          emitSchedulerEvent
            ObsError
            "pulse.scheduler.pending.claim"
            ("Failed to claim pending run: " <> T.pack err)
            []
          claimNextDueTask excluded deprioritized [] now
        Right (Just claimedRun) ->
          loadClaimedRun now claimedRun.pprcRunId claimedRun.pprcTriggerSource
        Right Nothing ->
          claimNextDueTask excluded deprioritized [] now

    -- \| Try to claim the next due task, skipping tasks in cooldown.
    -- Accumulates skipped task IDs so cooled-down tasks don't block others.
    -- The skip loop is bounded naturally by the number of enabled due tasks
    -- (typically single digits), not by an artificial cap.
    claimNextDueTask
      :: [Text]
      -> [Text]
      -> [UUID]
      -> UTCTime
      -> IO (Maybe (UUID, PulseTaskDefinitionRow Result, Maybe TriggerSource, IO RunOutcome))
    claimNextDueTask excluded deprioritized skippedTaskIds now = do
      taskResult <- DB.withConnection pool $ Q.getNextDueTask excluded deprioritized skippedTaskIds now
      case taskResult of
        Left err -> do
          emitSchedulerEvent
            ObsError
            "pulse.scheduler.fetch"
            ("Failed to fetch due task: " <> T.pack err)
            [("error", Aeson.toJSON err)]
          pure Nothing
        Right Nothing ->
          pure Nothing
        Right (Just task) -> do
          -- Cooldown check: skip this task and keep searching if still cooling down
          let inCooldown = case (task.minIntervalSeconds, task.lastRunAt) of
                (Just interval, Just lastRun) -> diffUTCTime now lastRun < fromIntegral interval
                _ -> False
          if inCooldown
            then claimNextDueTask excluded deprioritized (task.taskId : skippedTaskIds) now
            else do
              emitSchedulerEvent
                ObsInfo
                "pulse.scheduler.found"
                ("Found due task: " <> task.taskName)
                [ ("task_id", Aeson.toJSON task.taskId)
                , ("task_name", Aeson.toJSON task.taskName)
                , ("task_type", Aeson.toJSON task.taskType)
                ]
              claimResult <-
                DB.runTransaction pool $
                  Q.claimAndCreateRun
                    task.taskId
                    leaseOwner
                    TriggerSchedule
                    now
                    leaseDuration
              case claimResult of
                Left err -> do
                  emitSchedulerEvent
                    ObsError
                    "pulse.scheduler.claim"
                    ("Failed to claim task: " <> T.pack err)
                    [("task_id", Aeson.toJSON task.taskId)]
                  pure Nothing
                Right Nothing -> do
                  emitSchedulerEvent
                    ObsInfo
                    "pulse.scheduler.claimed"
                    "Task already claimed"
                    [("task_id", Aeson.toJSON task.taskId)]
                  pure Nothing
                Right (Just runId) -> do
                  launchRun task runId (Just TriggerSchedule)

    loadClaimedRun
      :: UTCTime
      -> UUID
      -> Text
      -> IO (Maybe (UUID, PulseTaskDefinitionRow Result, Maybe TriggerSource, IO RunOutcome))
    loadClaimedRun now runId triggerSource = do
      case triggerSourceFromText triggerSource of
        Nothing -> do
          emitSchedulerEvent
            ObsError
            "pulse.scheduler.pending.trigger_source"
            "Pending run has an unknown trigger source"
            [ ("run_id", Aeson.toJSON runId)
            , ("trigger_source", Aeson.toJSON triggerSource)
            ]
          failAndDiscard
            pool
            runId
            now
            "invalid_trigger_source"
            ("Unknown trigger source: " <> triggerSource)
            False
          pure Nothing
        Just parsedTriggerSource -> do
          taskResult <- DB.withConnection pool $ Q.getTaskForRun runId
          case taskResult of
            Left err -> do
              emitSchedulerEvent
                ObsError
                "pulse.scheduler.pending.task"
                ("Failed to load task for pending run: " <> T.pack err)
                [("run_id", Aeson.toJSON runId)]
              failAndDiscard pool runId now "task_load_error" (T.pack err) True
              pure Nothing
            Right Nothing -> do
              emitSchedulerEvent
                ObsError
                "pulse.scheduler.pending.task_missing"
                "Task definition missing for pending run"
                [("run_id", Aeson.toJSON runId)]
              failAndDiscard pool runId now "task_not_found" "Task definition missing for pending run" False
              pure Nothing
            Right (Just task) ->
              launchRun task runId (Just parsedTriggerSource)

    launchRun
      :: PulseTaskDefinitionRow Result
      -> UUID
      -> Maybe TriggerSource
      -> IO (Maybe (UUID, PulseTaskDefinitionRow Result, Maybe TriggerSource, IO RunOutcome))
    launchRun task runId triggerSource = do
      emitSchedulerEvent
        ObsInfo
        "pulse.scheduler.run.start"
        "Starting task execution"
        [ ("run_id", Aeson.toJSON runId)
        , ("task_id", Aeson.toJSON task.taskId)
        , ("trigger_source", Aeson.toJSON (renderTriggerSource triggerSource))
        ]
      let runAction = withLeaseRenewal pool runId leaseDuration (Executor.executeTask registry taskContext runId task)
      pure (Just (runId, task, triggerSource, runAction))

    markRunFailedForUnexpectedExit :: UUID -> SomeException -> IO RunOutcome
    markRunFailedForUnexpectedExit runId err = do
      now <- getCurrentTime
      let errText = T.take 200 (T.pack (displayException err))
      Err.logDbFailure_
        ( \dbErr ->
            emitSchedulerEvent
              ObsError
              "pulse.scheduler.run.exception.write"
              ("Failed to mark run as failed after executor exception: " <> T.pack dbErr)
              [("run_id", Aeson.toJSON runId)]
        )
        ( DB.runTransaction pool $
            Q.updateRunFailed
              Q.RunFailureUpdate
                { rfuRunId = runId
                , rfuCompletedAt = now
                , rfuErrType = "executor_exception"
                , rfuErrMsg = errText
                , rfuRetryable = True
                }
        )
      emitSchedulerEvent
        ObsError
        "pulse.scheduler.run.exception"
        ("Task execution exited with exception: " <> errText)
        [("run_id", Aeson.toJSON runId)]
      recordSchedulerRunEvent
        pool
        Q.RunEventInsert
          { reiRunId = runId
          , reiEventType = "run.failed"
          , reiSeverity = Q.RunEventError
          , reiMessage = "Task execution exited with exception: " <> errText
          , reiDetails = Just (Aeson.object ["error_type" Aeson..= ("executor_exception" :: T.Text)])
          }
      pure OutcomeFailed

{- | After execution, advance the cron schedule or complete a one-off task.
One-off tasks are only disabled on success; failures restore visibility for retry.
-}
finalizeTaskSchedule
  :: DB.Pool
  -> Maybe UUID
  -> PulseTaskDefinitionRow Result
  -> Maybe TriggerSource
  -> UTCTime
  -> RunOutcome
  -> IO ()
finalizeTaskSchedule pool maybeRunId task triggerSource endTime outcome = do
  let decision = taskScheduleDecision task triggerSource endTime outcome
      taskId = task.taskId
      -- Apply the schedule decision and log the DB write result.
      applyAndLog :: T.Text -> T.Text -> IO ()
      applyAndLog writeOp writeErrContext =
        Err.logDbFailure_
          ( \err ->
              emitSchedulerEvent
                ObsWarn
                writeOp
                (writeErrContext <> ": " <> T.pack err)
                [("task_id", Aeson.toJSON taskId)]
          )
          (DB.runTransaction pool $ applyScheduleDecisionTx taskId endTime outcome decision)
  case decision of
    NoScheduleChange -> pure ()
    RecordOutcomeOnly -> do
      applyAndLog "pulse.scheduler.manual.finalize.write" "Failed to record manual/retry run outcome"
      emitSchedulerEvent
        (outcomeLogLevel outcome)
        "pulse.scheduler.manual.finalize"
        "Manual/retry run finished without advancing cron schedule"
        [ ("task_id", Aeson.toJSON taskId)
        , ("trigger_source", Aeson.toJSON (renderTriggerSource triggerSource))
        , ("outcome", Aeson.toJSON (runOutcomeToText outcome))
        ]
    CompleteOneOff -> do
      applyAndLog
        "pulse.scheduler.complete.write"
        "Failed to mark one-off task as completed — task may re-execute"
      emitSchedulerEvent
        ObsInfo
        "pulse.scheduler.complete"
        "One-off task completed"
        [("task_id", Aeson.toJSON taskId)]
    RestoreOneOffAt backoffTime -> do
      applyAndLog "pulse.scheduler.backoff.write" "Failed to schedule one-off retry backoff"
      emitSchedulerEvent
        (outcomeLogLevel outcome)
        "pulse.scheduler.failed"
        (outcomeMessage "One-off task" outcome)
        [ ("task_id", Aeson.toJSON taskId)
        , ("next_run_at", Aeson.toJSON backoffTime)
        , ("outcome", Aeson.toJSON (runOutcomeToText outcome))
        ]
      for_ maybeRunId $ \runId ->
        recordSchedulerRunEvent
          pool
          Q.RunEventInsert
            { reiRunId = runId
            , reiEventType = "schedule.restored"
            , reiSeverity = Q.RunEventWarn
            , reiMessage = outcomeMessage "One-off task" outcome
            , reiDetails =
                Just
                  (Aeson.object ["next_run_at" Aeson..= backoffTime, "outcome" Aeson..= runOutcomeToText outcome])
            }
    AdvanceRecurringTo nextTime -> do
      applyAndLog
        "pulse.scheduler.advance.write"
        "Failed to advance task schedule — duplicate execution possible"
      emitSchedulerEvent
        (outcomeLogLevel outcome)
        "pulse.scheduler.advanced"
        (outcomeMessage "Task schedule" outcome)
        [ ("task_id", Aeson.toJSON taskId)
        , ("next_run_at", Aeson.toJSON nextTime)
        , ("outcome", Aeson.toJSON (runOutcomeToText outcome))
        ]
      for_ maybeRunId $ \runId ->
        recordSchedulerRunEvent
          pool
          Q.RunEventInsert
            { reiRunId = runId
            , reiEventType = "schedule.advanced"
            , reiSeverity = Q.RunEventInfo
            , reiMessage = outcomeMessage "Task schedule" outcome
            , reiDetails =
                Just (Aeson.object ["next_run_at" Aeson..= nextTime, "outcome" Aeson..= runOutcomeToText outcome])
            }
    RestoreRecurringAfterCronErrorAt _backoffTime -> do
      emitSchedulerEvent
        ObsWarn
        "pulse.scheduler.cron.error"
        "Failed to compute next cron time"
        [("task_id", Aeson.toJSON taskId), ("cron", Aeson.toJSON task.cronExpression)]
      applyAndLog "pulse.scheduler.restore.write" "Failed to restore task schedule after bad cron"

recoverExpiredRuns :: DB.Pool -> Text -> UTCTime -> IO (Either String Int64)
recoverExpiredRuns pool currentLeaseOwner now = do
  recoveryResult <- DB.runTransaction pool $ do
    recoveredRuns <- Q.recoverExpiredRuns currentLeaseOwner now
    for_ recoveredRuns $ \recoveredRun ->
      case recoveredRun.perrCronExpression of
        Nothing -> pure ()
        Just cronExpression ->
          applyScheduleDecisionTx
            recoveredRun.perrTaskId
            now
            OutcomeFailed
            (recoveryScheduleDecision recoveredRun.perrTriggerSource cronExpression now)
    pure recoveredRuns
  case recoveryResult of
    Left err -> pure (Left err)
    Right recoveredRuns -> do
      for_ recoveredRuns $ \recoveredRun ->
        case recoveredRun.perrCronExpression of
          Nothing ->
            emitSchedulerEvent
              ObsWarn
              "pulse.scheduler.recovery.task_missing"
              "Recovered expired run but task definition is missing; only the run status was updated"
              [ ("run_id", Aeson.toJSON recoveredRun.perrRunId)
              , ("task_id", Aeson.toJSON recoveredRun.perrTaskId)
              ]
          Just _ ->
            case triggerSourceFromText recoveredRun.perrTriggerSource of
              Nothing ->
                emitSchedulerEvent
                  ObsWarn
                  "pulse.scheduler.recovery.trigger_source"
                  "Recovered expired run with an unknown trigger source; treating it as a non-scheduled execution"
                  [ ("run_id", Aeson.toJSON recoveredRun.perrRunId)
                  , ("trigger_source", Aeson.toJSON recoveredRun.perrTriggerSource)
                  ]
              Just _ -> pure ()
      pure (Right (fromIntegral (length recoveredRuns)))

{- | Run an action under run-scoped lease ownership.
Renews the specific run's lease every half the lease duration and cancels
the in-flight action if renewal becomes ambiguous.
-}
withLeaseRenewal :: DB.Pool -> UUID -> Int32 -> IO RunOutcome -> IO RunOutcome
withLeaseRenewal pool runId leaseDuration action = do
  let renewalInterval = max 1 (fromIntegral leaseDuration `div` 2) * 1_000_000 -- microseconds
      leaseMicros = fromIntegral leaseDuration * 1_000_000 :: Int
      -- Cap jitter so renewal + max jitter stays below the full lease duration.
      -- For short leases (< 10s), disable jitter entirely to avoid lease expiry.
      -- Math: max jittered delay = interval * (1 + fraction).
      -- We want interval * (1 + fraction) < leaseMicros, so:
      --   fraction < (leaseMicros - interval) / interval
      -- We use half that headroom (× 0.5) for safety, capped at 10%.
      jitterFraction
        | leaseDuration < 10 = 0.0
        | otherwise =
            min 0.1 (fromIntegral (leaseMicros - renewalInterval) / fromIntegral renewalInterval * 0.5)
  withAsync action $ \actionAsync ->
    renewLoop renewalInterval jitterFraction actionAsync
  where
    renewLoop :: Int -> Double -> Async RunOutcome -> IO RunOutcome
    renewLoop interval jitter actionAsync = do
      raceResult <- race (waitCatch actionAsync) (Polling.threadDelayWithJitter interval jitter)
      case raceResult of
        Left (Right outcome) -> pure outcome
        Left (Left err) -> throwIO err
        Right () -> do
          now <- getCurrentTime
          result <- DB.withConnection pool $ Q.renewRunLease runId now leaseDuration
          case result of
            Left err ->
              failRunForLeaseLoss
                actionAsync
                now
                "lease_renewal_failed"
                ("Run lease renewal failed, cancelling in-flight execution: " <> T.pack err)
                True
            Right True ->
              renewLoop interval jitter actionAsync
            Right False -> do
              asyncResult <- poll actionAsync
              case asyncResult of
                Just (Right outcome) -> do
                  emitSchedulerEvent
                    ObsInfo
                    "pulse.lease.completed_before_renewal"
                    "Run completed between lease renewal attempts — accepting outcome"
                    [ ("run_id", Aeson.toJSON runId)
                    , ("outcome", Aeson.toJSON (runOutcomeToText outcome))
                    ]
                  pure outcome
                Just (Left err) ->
                  throwIO err
                Nothing ->
                  failRunForLeaseLoss
                    actionAsync
                    now
                    "lease_lost"
                    "Run lease no longer belongs to this executor, cancelling in-flight execution"
                    True

    failRunForLeaseLoss :: Async RunOutcome -> UTCTime -> Text -> Text -> Bool -> IO RunOutcome
    failRunForLeaseLoss actionAsync now errType errMsg retryable = do
      cancel actionAsync
      waitCatch actionAsync >>= \case
        Right outcome -> do
          emitSchedulerEvent
            ObsWarn
            "pulse.lease.race"
            "Task completed between lease loss and cancellation — accepting outcome"
            [ ("run_id", Aeson.toJSON runId)
            , ("outcome", Aeson.toJSON (runOutcomeToText outcome))
            , ("lease_error", Aeson.toJSON errType)
            ]
          pure outcome
        Left _ -> do
          Err.logDbFailure_
            ( \dbErr ->
                emitSchedulerEvent
                  ObsError
                  "pulse.lease.fail.write"
                  ("Failed to mark run as failed after lease loss: " <> T.pack dbErr)
                  [("run_id", Aeson.toJSON runId), ("error_type", Aeson.toJSON errType)]
            )
            ( DB.runTransaction pool $
                Q.updateRunFailed
                  Q.RunFailureUpdate
                    { rfuRunId = runId
                    , rfuCompletedAt = now
                    , rfuErrType = errType
                    , rfuErrMsg = errMsg
                    , rfuRetryable = retryable
                    }
            )
          emitSchedulerEvent
            ObsError
            "pulse.lease.lost"
            errMsg
            [("run_id", Aeson.toJSON runId), ("error_type", Aeson.toJSON errType)]
          recordSchedulerRunEvent
            pool
            Q.RunEventInsert
              { reiRunId = runId
              , reiEventType = "lease.lost"
              , reiSeverity = Q.RunEventError
              , reiMessage = errMsg
              , reiDetails = Just (Aeson.object ["error_type" Aeson..= errType])
              }
          pure OutcomeFailed

outcomeMessage :: Text -> RunOutcome -> Text
outcomeMessage subject = \case
  OutcomeCompleted -> subject <> " advanced after successful completion"
  OutcomeFailed -> subject <> " restored for retry after failure"
  OutcomeCancelled -> subject <> " restored for retry after cancellation"
  OutcomeTimedOut -> subject <> " restored for retry after timeout"
  OutcomeShutdown -> subject <> " not finalized because shutdown drained execution"
  OutcomeSuspended -> subject <> " suspended, waiting on external signal"

outcomeLogLevel :: RunOutcome -> ObservabilityLogLevel
outcomeLogLevel = \case
  OutcomeCompleted -> ObsInfo
  OutcomeFailed -> ObsWarn
  OutcomeCancelled -> ObsWarn
  OutcomeTimedOut -> ObsWarn
  OutcomeShutdown -> ObsInfo
  OutcomeSuspended -> ObsInfo

{- | Mark a run as failed, logging if the DB write itself fails.
Used for early-exit failures (invalid trigger, missing task) where the
run must be marked failed but the caller doesn't need the result.
-}
failAndDiscard :: DB.Pool -> UUID -> UTCTime -> T.Text -> T.Text -> Bool -> IO ()
failAndDiscard pool runId now errType errMsg retryable =
  Err.logDbFailure_
    ( \dbErr ->
        emitSchedulerEvent
          ObsWarn
          "pulse.scheduler.pending.fail.write"
          ("Failed to persist run failure status (best-effort): " <> T.pack dbErr)
          [("run_id", Aeson.toJSON runId), ("error_type", Aeson.toJSON errType)]
    )
    ( DB.runTransaction pool $
        Q.updateRunFailed
          Q.RunFailureUpdate
            { rfuRunId = runId
            , rfuCompletedAt = now
            , rfuErrType = errType
            , rfuErrMsg = errMsg
            , rfuRetryable = retryable
            }
    )

{- | Record a lifecycle event to the run's append-only event history.
Delegates to the shared best-effort writer in Query.
-}
recordSchedulerRunEvent :: DB.Pool -> Q.RunEventInsert -> IO ()
recordSchedulerRunEvent = Q.recordRunEvent

pulseEmitter :: SubsystemEmitter
pulseEmitter = SubsystemEmitter "cortex-pulse" Nothing Nothing

emitSchedulerEvent :: ObservabilityLogLevel -> T.Text -> T.Text -> [(T.Text, Aeson.Value)] -> IO ()
emitSchedulerEvent level operation message =
  emitSubsystemEvent pulseEmitter level operation message "success" Nothing

renderTriggerSource :: Maybe TriggerSource -> Text
renderTriggerSource = \case
  Just triggerSource -> triggerSourceToText triggerSource
  Nothing -> "unknown"

pulseScheduleConfig :: ScheduleConfig
pulseScheduleConfig =
  ScheduleConfig
    { scOneOffFailureBackoff = 300
    , scCronParseBackoff = 300
    }

pulseScheduleKind :: PulseTaskDefinitionRow Result -> ScheduleKind
pulseScheduleKind task
  | T.null task.cronExpression = OneOff
  | otherwise = Recurring task.cronExpression

pulseScheduleKindFromCronExpression :: Text -> ScheduleKind
pulseScheduleKindFromCronExpression cronExpression
  | T.null cronExpression = OneOff
  | otherwise = Recurring cronExpression

taskScheduleDecision
  :: PulseTaskDefinitionRow Result -> Maybe TriggerSource -> UTCTime -> RunOutcome -> ScheduleDecision
taskScheduleDecision task triggerSource =
  decideScheduleAction
    pulseScheduleConfig
    (pulseExecutionOrigin triggerSource)
    (pulseScheduleKind task)

recoveryScheduleDecision :: Text -> Text -> UTCTime -> ScheduleDecision
recoveryScheduleDecision triggerSource cronExpression endTime =
  decideScheduleAction
    pulseScheduleConfig
    (pulseExecutionOrigin (triggerSourceFromText triggerSource))
    (pulseScheduleKindFromCronExpression cronExpression)
    endTime
    OutcomeFailed

applyScheduleDecisionTx :: UUID -> UTCTime -> RunOutcome -> ScheduleDecision -> Transaction ()
applyScheduleDecisionTx taskId endTime outcome = \case
  NoScheduleChange -> pure ()
  RecordOutcomeOnly ->
    for_ (finalStatusText outcome) (Q.updateTaskLastRunOnly taskId endTime)
  CompleteOneOff ->
    Q.completeOneOffTask taskId endTime
  RestoreOneOffAt backoffTime ->
    for_ (finalStatusText outcome) (Q.restoreOneOffTaskAt taskId backoffTime endTime)
  AdvanceRecurringTo nextTime ->
    for_ (finalStatusText outcome) (Q.advanceTaskSchedule taskId nextTime endTime)
  RestoreRecurringAfterCronErrorAt backoffTime ->
    Q.restoreTaskSchedule taskId backoffTime endTime

pulseExecutionOrigin :: Maybe TriggerSource -> ExecutionOrigin
pulseExecutionOrigin = \case
  Just TriggerSchedule -> ScheduledExecution
  Just TriggerManual -> OtherExecution
  Just TriggerRetry -> OtherExecution
  Nothing -> OtherExecution

finalStatusText :: RunOutcome -> Maybe RunStatus
finalStatusText = runOutcomeToFinalStatus
