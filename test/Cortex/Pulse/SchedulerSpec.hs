{- |
Module      : Cortex.Pulse.SchedulerSpec
Description : Tests for Cortex.Pulse.Scheduler.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.SchedulerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (join)
import Data.Aeson qualified as Aeson
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time
  ( UTCTime (..)
  , addUTCTime
  , diffUTCTime
  , fromGregorian
  , getCurrentTime
  , secondsToDiffTime
  )
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement (..))
import Rel8 (Result)
import System.Environment (lookupEnv)
import Test.Hspec

import Cortex.Pulse.Executor
  ( ReplayPolicy (..)
  , StableStageId (..)
  , StageDefinition (..)
  , StageReplaySafety (..)
  , TaskContext (..)
  , TaskHandler (..)
  , executeStagePlan
  , liftChainAction
  , mkLinearStagePlan
  , resumeStagePlan
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Health (initialHealthState)
import Cortex.Pulse.Memory (defaultMemoryStrategy)
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Scheduler
  ( RunMetadata (..)
  , computeExcludedTypes
  , finalizeTaskSchedule
  , recoverExpiredRuns
  , runSchedulerLoop
  , withLeaseRenewal
  )
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Types (PulseConfig (..), defaultRewriteBudget)
import Cortex.TestSupport.Database (createTestDB, insertTestUser, runSession, runTx)

import Platform.Database.Encode qualified as Enc
import Platform.DurableTask.Types (RunOutcome (..), RunStatus (..), TriggerSource (..))

data TestStage
  = TestStageAlpha
  | TestStageBeta
  deriving stock (Bounded, Enum, Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId TestStage where
  stageIdToText = \case
    TestStageAlpha -> "test_alpha"
    TestStageBeta -> "test_beta"

withDb :: Maybe Pool -> (Pool -> IO ()) -> IO ()
withDb Nothing _ = pendingWith "PGHOST not set - database not available"
withDb (Just pool) action = action pool

setupTestDb :: IO (Maybe Pool)
setupTestDb = do
  mHost <- lookupEnv "PGHOST"
  case mHost of
    Nothing -> pure Nothing
    Just _ -> do
      result <- try createTestDB :: IO (Either SomeException Pool)
      case result of
        Left err -> error $ "PGHOST is set but database setup failed: " <> displayException err
        Right pool -> pure (Just pool)

insertTestTaskDef :: Pool -> Text -> Text -> IO UUID
insertTestTaskDef pool taskType taskName = do
  now <- getCurrentTime
  insertTaskDefAt pool taskType taskName "" (Just now) now

createTestRunWithLease :: Pool -> UUID -> Int -> IO UUID
createTestRunWithLease pool taskId leaseDurationSeconds = do
  now <- getCurrentTime
  result <-
    runTx pool $
      Q.claimAndCreateRun taskId "test-owner" TriggerManual now (fromIntegral leaseDurationSeconds)
  case result of
    Just runId -> pure runId
    Nothing -> fail "Failed to create test run (task already claimed?)"

readRunLeaseExpiry :: Pool -> UUID -> IO (Maybe UTCTime)
readRunLeaseExpiry pool runId = do
  result <-
    runSession pool . Session.statement runId $
      Statement
        "SELECT lease_expires_at FROM pulse.runs WHERE run_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (D.column (D.nullable D.timestamptz)))
        True
  pure (join result)

readRunUserId :: Pool -> UUID -> IO (Maybe UUID)
readRunUserId pool runId = do
  result <-
    runSession pool . Session.statement runId $
      Statement
        "SELECT user_id FROM pulse.runs WHERE run_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (D.column (D.nullable D.uuid)))
        True
  pure (join result)

-- | Build a minimal RunMetadata with just the task type set.
mkRunMeta :: Text -> RunMetadata
mkRunMeta taskType =
  RunMetadata
    { rmTask = dummyTaskDef
    , rmTriggerSource = Nothing
    }
  where
    dummyTaskDef :: PulseTaskDefinitionRow Result
    dummyTaskDef =
      PulseTaskDefinitionRow
        { taskId = nilUUID
        , taskType = taskType
        , taskName = "dummy"
        , config = Aeson.Null
        , cronExpression = ""
        , enabled = True
        , schedulerClaimed = False
        , nextRunAt = Nothing
        , lastRunAt = Nothing
        , lastRunStatus = Nothing
        , timeoutSeconds = 3600
        , priority = 0
        , minIntervalSeconds = Nothing
        , createdAt = testTime
        , updatedAt = testTime
        }
    nilUUID = read "00000000-0000-0000-0000-000000000000" :: UUID

spec :: Spec
spec = do
  describe "computeExcludedTypes" $ do
    it "returns empty when no per-type limits are configured" $ do
      let limits = Map.empty
          meta = Map.fromList [(read "00000000-0000-0000-0000-000000000001", mkRunMeta "response_eval_run")]
      computeExcludedTypes limits meta `shouldBe` []

    it "excludes types at their limit" $ do
      let limits = Map.fromList [("response_eval_run", 1)]
          meta = Map.fromList [(read "00000000-0000-0000-0000-000000000001", mkRunMeta "response_eval_run")]
      computeExcludedTypes limits meta `shouldBe` ["response_eval_run"]

    it "does not exclude types below their limit" $ do
      let limits = Map.fromList [("response_eval_run", 2)]
          meta = Map.fromList [(read "00000000-0000-0000-0000-000000000001", mkRunMeta "response_eval_run")]
      computeExcludedTypes limits meta `shouldBe` []

    it "does not exclude types without a configured limit" $ do
      let limits = Map.fromList [("response_eval_run", 1)]
          meta = Map.fromList [(read "00000000-0000-0000-0000-000000000001", mkRunMeta "paper_portfolio_cycle")]
      computeExcludedTypes limits meta `shouldBe` []

    it "handles multiple types with mixed limits" $ do
      let limits = Map.fromList [("response_eval_run", 1), ("paper_portfolio_cycle", 2)]
          meta =
            Map.fromList
              [ (read "00000000-0000-0000-0000-000000000001", mkRunMeta "response_eval_run")
              , (read "00000000-0000-0000-0000-000000000002", mkRunMeta "paper_portfolio_cycle")
              , (read "00000000-0000-0000-0000-000000000003", mkRunMeta "paper_portfolio_cycle")
              ]
      sort (computeExcludedTypes limits meta) `shouldBe` ["paper_portfolio_cycle", "response_eval_run"]

  dbSpec

dbSpec :: Spec
dbSpec = beforeAll setupTestDb $ do
  describe "withLeaseRenewal" $ do
    it "extends a run lease while work is still executing" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-lease-renewal"
      runId <- createTestRunWithLease pool taskId 2
      initialLeaseExpiry <- readRunLeaseExpiry pool runId
      initialLeaseExpiry `shouldSatisfy` isJust
      withAsync
        ( withLeaseRenewal pool runId 2 $ do
            threadDelay 2500000
            completedAt <- getCurrentTime
            runTx pool $ Q.updateRunCompleted runId completedAt
            pure OutcomeCompleted
        )
        $ \worker -> do
          threadDelay 1300000
          renewedLeaseExpiry <- readRunLeaseExpiry pool runId
          case (initialLeaseExpiry, renewedLeaseExpiry) of
            (Just initialExpiry, Just renewedExpiry) ->
              renewedExpiry `shouldSatisfy` (> initialExpiry)
            _ -> expectationFailure "Expected both initial and renewed lease expiries to be present"
          wait worker `shouldReturn` OutcomeCompleted
      runSession pool (Q.readRunStatus runId) `shouldReturn` Just "completed"

    it "fails closed when the run can no longer renew its lease" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-lease-loss"
      runId <- createTestRunWithLease pool taskId 2
      startTime <- getCurrentTime
      withAsync (withLeaseRenewal pool runId 2 (threadDelay 5000000 >> pure OutcomeCompleted)) $ \worker -> do
        threadDelay 1100000
        now <- getCurrentTime
        runTx pool $ Q.updateRunCancelled runId now "simulate lost lease owner"
        outcome <- wait worker
        outcome `shouldBe` OutcomeFailed
      endTime <- getCurrentTime
      diffUTCTime endTime startTime `shouldSatisfy` (< 3)
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravStatus runView `shouldBe` Just "failed"
      fmap Q.pravErrorType runView `shouldBe` Just (Just "lease_lost")

    it "accepts a completed outcome when run finishes just before lease renewal" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-lease-race-completed"
      runId <- createTestRunWithLease pool taskId 2
      outcome <- withLeaseRenewal pool runId 2 $ do
        completedAt <- getCurrentTime
        runTx pool $ Q.updateRunCompleted runId completedAt
        pure OutcomeCompleted
      outcome `shouldBe` OutcomeCompleted
      runSession pool (Q.readRunStatus runId) `shouldReturn` Just "completed"

  describe "pending run claiming" $ do
    it "claims the oldest pending run and leaves newer pending runs untouched" $ \mPool -> withDb mPool $ \pool -> do
      -- Drain leftover pending runs from other tests to avoid ordering interference
      let drainPending = do
            now <- getCurrentTime
            r <- runTx pool $ Q.claimNextPendingRun "drain" now 1 [] []
            case r of
              Just _ -> drainPending
              Nothing -> pure ()
      drainPending
      firstTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-pending-claim-first"
      secondTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-pending-claim-second"
      firstCreatedAt <- getCurrentTime
      firstRunId <-
        expectCreatedRun "create first pending run"
          =<< runTx pool (Q.createPendingRun firstTaskId TriggerManual Nothing Nothing firstCreatedAt)
      let secondCreatedAt = addUTCTime 1 firstCreatedAt
      secondRunId <-
        expectCreatedRun "create second pending run"
          =<< runTx pool (Q.createPendingRun secondTaskId TriggerRetry Nothing Nothing secondCreatedAt)
      claimTime <- getCurrentTime
      claimed <- runTx pool $ Q.claimNextPendingRun "scheduler-owner" claimTime 60 [] []
      case claimed of
        Nothing -> expectationFailure "Expected pending run claim to succeed"
        Just claimedRun -> do
          Q.pprcRunId claimedRun `shouldBe` firstRunId
          Q.pprcTriggerSource claimedRun `shouldBe` "manual"
      firstRunView <- runSession pool $ Q.getRunAdminView firstRunId
      secondRunView <- runSession pool $ Q.getRunAdminView secondRunId
      case (firstRunView, secondRunView) of
        (Just firstRun, Just secondRun) -> do
          Q.pravStatus firstRun `shouldBe` "running"
          Q.pravLeaseOwner firstRun `shouldBe` Just "scheduler-owner"
          Q.pravStatus secondRun `shouldBe` "pending"
          Q.pravLeaseOwner secondRun `shouldBe` Nothing
        _ -> expectationFailure "Expected both claimed and pending run views to be present"

    it "allows only one open run per task" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-open-run-uniqueness"
      createdAt <- getCurrentTime
      firstRunId <- runTx pool $ Q.createPendingRun taskId TriggerManual Nothing Nothing createdAt
      secondRunId <-
        runTx pool $ Q.createPendingRun taskId TriggerRetry Nothing Nothing (addUTCTime 1 createdAt)
      firstRunId `shouldSatisfy` isJust
      secondRunId `shouldBe` Nothing

    it "claims pending runs even when the backing task is disabled and unscheduled" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      -- Priority 999 ensures this run is claimed before any stale pending
      -- runs left behind by other tests (claimNextPendingRun orders by
      -- priority DESC).
      taskId <-
        insertTaskDefWithEnabled
          pool
          "paper_portfolio_cycle"
          "test-pending-claim-disabled-task"
          ""
          Nothing
          now
          999
          Nothing
          False
      pendingRunId <-
        expectCreatedRun "create workflow-style pending run"
          =<< runTx pool (Q.createPendingRun taskId TriggerManual Nothing Nothing now)
      claimTime <- getCurrentTime
      claimed <- runTx pool $ Q.claimNextPendingRun "scheduler-owner" claimTime 60 [] []
      case claimed of
        Nothing -> expectationFailure "Expected pending run on disabled task to be claimable"
        Just claimedRun -> do
          Q.pprcRunId claimedRun `shouldBe` pendingRunId
          Q.pprcTriggerSource claimedRun `shouldBe` "manual"
      task <- loadTaskDef pool taskId
      enabled task `shouldBe` False
      nextRunAt task `shouldBe` Nothing
      runView <- runSession pool $ Q.getRunAdminView pendingRunId
      fmap Q.pravStatus runView `shouldBe` Just "running"

    it "does not clear a due schedule when the task already has an open run" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-scheduled-claim-open-run"
      pendingRunId <-
        expectCreatedRun "create blocking pending run"
          =<< runTx pool (Q.createPendingRun taskId TriggerManual Nothing Nothing now)
      claimResult <- runTx pool $ Q.claimAndCreateRun taskId "test-owner" TriggerSchedule now 60
      claimResult `shouldBe` Nothing
      task <- loadTaskDef pool taskId
      nextRunAt task `shouldSatisfy` isJust
      pendingRunView <- runSession pool $ Q.getRunAdminView pendingRunId
      fmap Q.pravStatus pendingRunView `shouldBe` Just "pending"

    it "stamps scheduled runs with the workflow user id from task config" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      workflowUserId <- insertTestUser pool "scheduler-stamp-test" "scheduler-stamp@test.com" "hashed"
      let config =
            Aeson.object
              [ "cortexTaskType" Aeson..= ("deep_report_workflow" :: Text)
              , "cortexTaskVersion" Aeson..= (1 :: Int)
              , "cortexTaskConfig"
                  Aeson..= Aeson.object
                    [ "drwUserId" Aeson..= workflowUserId
                    ]
              ]
      maybeTaskId <-
        runTx pool $
          Q.createTaskDefinition
            Q.PulseTaskDefinitionInsert
              { ptdiTaskType = "deep_report_workflow"
              , ptdiTaskName = "test-scheduled-run-user-stamp"
              , ptdiConfig = config
              , ptdiCronExpression = ""
              , ptdiEnabled = True
              , ptdiNextRunAt = Just now
              , ptdiTimeoutSeconds = 300
              , ptdiPriority = 0
              , ptdiMinIntervalSeconds = Nothing
              , ptdiCreatedAt = now
              }
      taskId <- maybe (fail "Failed to create scheduled workflow task") pure maybeTaskId
      runId <-
        expectCreatedRun "create scheduled run with owner"
          =<< runTx pool (Q.claimAndCreateRun taskId "test-owner" TriggerSchedule now 60)
      readRunUserId pool runId `shouldReturn` Just workflowUserId

  describe "runSchedulerLoop" $ do
    it "enforces per-type caps within a single fill cycle" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      shutdownFlag <- newTVarIO False
      healthState <- newTVarIO (initialHealthState "scheduler-cap-test" 2)
      release <- newEmptyMVar
      let taskType = "cap_test"
          taskContext =
            TaskContext
              { tcPool = pool
              , tcConfig =
                  testPulseConfig
                    { pulseLeaseOwner = "scheduler-cap-test"
                    , pulsePollIntervalSeconds = 1
                    , pulseMaxConcurrentTasks = 2
                    , pulseTaskTypeLimits = Map.fromList [(taskType, 1)]
                    }
              , tcShutdownFlag = shutdownFlag
              }
          registry = Map.fromList [(taskType, mkBlockingHandler release)]
      firstTaskId <-
        insertTaskDefWithSettings
          pool
          taskType
          "test-cap-first"
          ""
          (Just (addUTCTime (-20) now))
          now
          0
          Nothing
      secondTaskId <-
        insertTaskDefWithSettings
          pool
          taskType
          "test-cap-second"
          ""
          (Just (addUTCTime (-10) now))
          now
          0
          Nothing
      withAsync (runSchedulerLoop registry taskContext healthState) $ \schedulerAsync -> do
        waitUntil "first capped task to be claimed" $ schedulerClaimed <$> loadTaskDef pool firstTaskId
        threadDelay 200000
        firstTask <- loadTaskDef pool firstTaskId
        secondTask <- loadTaskDef pool secondTaskId
        schedulerClaimed firstTask `shouldBe` True
        schedulerClaimed secondTask `shouldBe` False
        countRunningRunsForType pool taskType `shouldReturn` 1
        atomically $ writeTVar shutdownFlag True
        putMVar release ()
        wait schedulerAsync
      cleanupTestTasks pool [firstTaskId, secondTaskId]

    it "skips a cooled-down due task and claims the next runnable task" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      shutdownFlag <- newTVarIO False
      healthState <- newTVarIO (initialHealthState "scheduler-cooldown-test" 1)
      release <- newEmptyMVar
      let taskType = "cooldown_test"
          taskContext =
            TaskContext
              { tcPool = pool
              , tcConfig =
                  testPulseConfig
                    { pulseLeaseOwner = "scheduler-cooldown-test"
                    , pulsePollIntervalSeconds = 1
                    , pulseMaxConcurrentTasks = 1
                    }
              , tcShutdownFlag = shutdownFlag
              }
          registry = Map.fromList [(taskType, mkBlockingHandler release)]
          cooledDownRunAt = addUTCTime (-60) now
      cooledDownTaskId <-
        insertTaskDefWithSettings
          pool
          taskType
          "test-cooldown-first"
          ""
          (Just (addUTCTime (-20) now))
          now
          0
          (Just 300)
      runnableTaskId <-
        insertTaskDefWithSettings
          pool
          taskType
          "test-cooldown-second"
          ""
          (Just (addUTCTime (-10) now))
          now
          0
          Nothing
      setTaskLastRunAt pool cooledDownTaskId cooledDownRunAt
      withAsync (runSchedulerLoop registry taskContext healthState) $ \schedulerAsync -> do
        waitUntil "runnable task behind cooldown barrier to be claimed" $
          schedulerClaimed <$> loadTaskDef pool runnableTaskId
        threadDelay 200000
        cooledDownTask <- loadTaskDef pool cooledDownTaskId
        runnableTask <- loadTaskDef pool runnableTaskId
        schedulerClaimed cooledDownTask `shouldBe` False
        schedulerClaimed runnableTask `shouldBe` True
        countRunningRunsForType pool taskType `shouldReturn` 1
        atomically $ writeTVar shutdownFlag True
        putMVar release ()
        wait schedulerAsync
      cleanupTestTasks pool [cooledDownTaskId, runnableTaskId]

  describe "finalizeTaskSchedule" $ do
    it "records manual cron task outcomes without advancing next_run_at" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      let initialNextRunAt = addUTCTime 600 now
          completedAt = addUTCTime 120 now
      taskId <- insertCronTaskDef pool "test-manual-cron-finalize" "0 * * * *" initialNextRunAt
      task <- loadTaskDef pool taskId
      finalizeTaskSchedule pool Nothing task (Just TriggerManual) completedAt OutcomeCompleted
      updatedTask <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt updatedTask) (Just initialNextRunAt)
      expectMaybeTimeNear (lastRunAt updatedTask) (Just completedAt)
      lastRunStatus updatedTask `shouldBe` Just "completed"
      enabled updatedTask `shouldBe` True

    it "records one-off timeout outcomes as timeout while restoring retry visibility" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      let completedAt = addUTCTime 120 now
          expectedNextRunAt = addUTCTime 300 completedAt
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-one-off-timeout-finalize"
      task <- loadTaskDef pool taskId
      finalizeTaskSchedule pool Nothing task (Just TriggerSchedule) completedAt OutcomeTimedOut
      updatedTask <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt updatedTask) (Just expectedNextRunAt)
      expectMaybeTimeNear (lastRunAt updatedTask) (Just completedAt)
      lastRunStatus updatedTask `shouldBe` Just "timeout"
      enabled updatedTask `shouldBe` True

    it "restores one-off work at the exact requested timestamp" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      let completedAt = addUTCTime 120 now
          exactNextRunAt = addUTCTime 37 completedAt
      taskId <-
        insertTaskDefWithEnabled
          pool
          "paper_portfolio_cycle"
          "test-one-off-exact-restore"
          ""
          (Just now)
          now
          0
          Nothing
          False
      runTx pool $ Q.restoreOneOffTaskAt taskId exactNextRunAt completedAt Failed
      updatedTask <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt updatedTask) (Just exactNextRunAt)
      expectMaybeTimeNear (lastRunAt updatedTask) (Just completedAt)
      lastRunStatus updatedTask `shouldBe` Just "failed"
      enabled updatedTask `shouldBe` True

    it "does not clear scheduler_claimed when recording manual cron task outcome" $ \mPool -> withDb mPool $ \pool -> do
      now <- getCurrentTime
      let initialNextRunAt = addUTCTime 600 now
          completedAt = addUTCTime 120 now
      taskId <- insertCronTaskDef pool "test-manual-cron-keeps-claim" "0 * * * *" initialNextRunAt
      -- Simulate that the scheduler has independently claimed the next scheduled execution
      runSession pool . Session.statement (taskId, now) $
        Statement
          "UPDATE pulse.task_definitions SET scheduler_claimed = true, updated_at = $2 WHERE task_id = $1"
          (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
          D.noResult
          False
      task <- loadTaskDef pool taskId
      finalizeTaskSchedule pool Nothing task (Just TriggerManual) completedAt OutcomeCompleted
      updatedTask <- loadTaskDef pool taskId
      schedulerClaimed updatedTask `shouldBe` True
      expectMaybeTimeNear (nextRunAt updatedTask) (Just initialNextRunAt)
      lastRunStatus updatedTask `shouldBe` Just "completed"

  describe "recoverExpiredRuns" $ do
    it "restores scheduled one-off work using the failure backoff" $ \mPool -> withDb mPool $ \pool -> do
      let claimTime = testTime
          recoveryTime = testTimePlus60
          expectedNextRunAt = addUTCTime 300 recoveryTime
      taskId <-
        insertTaskDefAt pool "paper_portfolio_cycle" "test-recover-one-off" "" (Just claimTime) claimTime
      runId <-
        expectCreatedRun "create scheduled run"
          =<< runTx pool (Q.claimAndCreateRun taskId "expired-owner" TriggerSchedule claimTime 60)
      setRunLeaseExpiry pool runId (addUTCTime (-1) recoveryTime)
      recoverExpiredRuns pool "recovery-owner" recoveryTime `shouldReturn` Right 1
      task <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt task) (Just expectedNextRunAt)
      expectMaybeTimeNear (lastRunAt task) (Just recoveryTime)
      lastRunStatus task `shouldBe` Just "failed"
      schedulerClaimed task `shouldBe` False
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravStatus runView `shouldBe` Just "failed"
      fmap Q.pravErrorType runView `shouldBe` Just (Just "stale_run_recovery")

    it "advances scheduled recurring work to the next cron fire time during stale recovery" $ \mPool -> withDb mPool $ \pool -> do
      let claimTime = testTime
          recoveryTime = testTimePlus60
          expectedNextRunAt = testTimePlus300
      taskId <-
        insertTaskDefAt
          pool
          "paper_portfolio_cycle"
          "test-recover-recurring"
          "*/5 * * * *"
          (Just claimTime)
          claimTime
      runId <-
        expectCreatedRun "create scheduled recurring run"
          =<< runTx pool (Q.claimAndCreateRun taskId "expired-owner" TriggerSchedule claimTime 60)
      setRunLeaseExpiry pool runId (addUTCTime (-1) recoveryTime)
      recoverExpiredRuns pool "recovery-owner" recoveryTime `shouldReturn` Right 1
      task <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt task) (Just expectedNextRunAt)
      expectMaybeTimeNear (lastRunAt task) (Just recoveryTime)
      lastRunStatus task `shouldBe` Just "failed"
      schedulerClaimed task `shouldBe` False

    it "records manual recurring stale-run failures without advancing cron state" $ \mPool -> withDb mPool $ \pool -> do
      let initialNextRunAt = testTimePlus3600
          createdAt = testTime
          claimTime = testTimePlus60
          recoveryTime = testTimePlus120
      taskId <-
        insertTaskDefAt
          pool
          "paper_portfolio_cycle"
          "test-recover-manual-recurring"
          "0 * * * *"
          (Just initialNextRunAt)
          createdAt
      pendingRunId <-
        expectCreatedRun "create pending manual run"
          =<< runTx pool (Q.createPendingRun taskId TriggerManual Nothing Nothing createdAt)
      claimedRun <- runTx pool $ Q.claimNextPendingRun "expired-owner" claimTime 60 [] []
      fmap Q.pprcRunId claimedRun `shouldBe` Just pendingRunId
      setRunLeaseExpiry pool pendingRunId (addUTCTime (-1) recoveryTime)
      recoverExpiredRuns pool "recovery-owner" recoveryTime `shouldReturn` Right 1
      task <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt task) (Just initialNextRunAt)
      expectMaybeTimeNear (lastRunAt task) (Just recoveryTime)
      lastRunStatus task `shouldBe` Just "failed"
      schedulerClaimed task `shouldBe` False

    it "drains on shutdown, resumes exactly once, and advances a recurring schedule once" $ \mPool -> withDb mPool $ \pool -> do
      let claimTime = testTime
          reclaimTime = testTimePlus60
          finishedAt = testTimePlus120
          expectedNextRunAt = testTimePlus300
          leaseOwner = "test-owner-shutdown-reclaim"
      shutdownFlag <- newTVarIO False
      betaRuns <- newIORef (0 :: Int)
      let taskContext =
            TaskContext
              { tcPool = pool
              , tcConfig = testPulseConfig {pulseLeaseOwner = leaseOwner}
              , tcShutdownFlag = shutdownFlag
              }
          stagePlan =
            case mkLinearStagePlan
              [ simpleStage TestStageAlpha $ \_runId state -> do
                  atomically $ writeTVar shutdownFlag True
                  pure state
              , simpleStage TestStageBeta $ \_runId state -> do
                  atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                  pure state
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
              defaultRewriteBudget of
              Left err -> error ("mkLinearStagePlan: " <> show err)
              Right plan -> plan
      taskId <-
        insertTaskDefAt
          pool
          "paper_portfolio_cycle"
          "test-shutdown-reclaim-resume"
          "*/5 * * * *"
          (Just claimTime)
          claimTime
      runId <-
        expectCreatedRun "create scheduled run"
          =<< runTx pool (Q.claimAndCreateRun taskId leaseOwner TriggerSchedule claimTime 300)
      task <- loadTaskDef pool taskId
      firstOutcome <- withLeaseRenewal pool runId 300 (executeStagePlan taskContext runId task stagePlan)
      firstOutcome `shouldBe` OutcomeShutdown
      runSession pool (Q.readRunStatus runId) `shouldReturn` Just "running"
      betaAfterShutdown <- readIORef betaRuns
      betaAfterShutdown `shouldBe` 0
      reclaimedRunIds <- runSession pool $ Q.reclaimOwnedRuns leaseOwner reclaimTime 300
      reclaimedRunIds `shouldBe` [runId]
      atomically $ writeTVar shutdownFlag False
      secondOutcome <- withLeaseRenewal pool runId 300 (resumeStagePlan taskContext runId task stagePlan)
      secondOutcome `shouldBe` OutcomeCompleted
      finalizeTaskSchedule pool (Just runId) task (Just TriggerSchedule) finishedAt secondOutcome
      runSession pool (Q.readRunStatus runId) `shouldReturn` Just "completed"
      betaAfterResume <- readIORef betaRuns
      betaAfterResume `shouldBe` 1
      updatedTask <- loadTaskDef pool taskId
      expectMaybeTimeNear (nextRunAt updatedTask) (Just expectedNextRunAt)
      expectMaybeTimeNear (lastRunAt updatedTask) (Just finishedAt)
      lastRunStatus updatedTask `shouldBe` Just "completed"

insertCronTaskDef :: Pool -> Text -> Text -> UTCTime -> IO UUID
insertCronTaskDef pool taskName cronExpression nextRunAt = do
  now <- getCurrentTime
  insertTaskDefAt pool "paper_portfolio_cycle" taskName cronExpression (Just nextRunAt) now

insertTaskDefAt :: Pool -> Text -> Text -> Text -> Maybe UTCTime -> UTCTime -> IO UUID
insertTaskDefAt pool taskType taskName cronExpression nextRunAt createdAt = do
  insertTaskDefWithSettings pool taskType taskName cronExpression nextRunAt createdAt 0 Nothing

insertTaskDefWithSettings
  :: Pool -> Text -> Text -> Text -> Maybe UTCTime -> UTCTime -> Int32 -> Maybe Int32 -> IO UUID
insertTaskDefWithSettings pool taskType taskName cronExpression nextRunAt createdAt priority minIntervalSeconds = do
  insertTaskDefWithEnabled
    pool
    taskType
    taskName
    cronExpression
    nextRunAt
    createdAt
    priority
    minIntervalSeconds
    True

insertTaskDefWithEnabled
  :: Pool -> Text -> Text -> Text -> Maybe UTCTime -> UTCTime -> Int32 -> Maybe Int32 -> Bool -> IO UUID
insertTaskDefWithEnabled pool taskType taskName cronExpression nextRunAt createdAt priority minIntervalSeconds isEnabled = do
  maybeTaskId <-
    runTx pool $
      Q.createTaskDefinition
        Q.PulseTaskDefinitionInsert
          { ptdiTaskType = taskType
          , ptdiTaskName = taskName
          , ptdiConfig = Aeson.object []
          , ptdiCronExpression = cronExpression
          , ptdiEnabled = isEnabled
          , ptdiNextRunAt = nextRunAt
          , ptdiTimeoutSeconds = 300
          , ptdiPriority = priority
          , ptdiMinIntervalSeconds = minIntervalSeconds
          , ptdiCreatedAt = createdAt
          }
  case maybeTaskId of
    Just taskId -> pure taskId
    Nothing -> fail $ "Failed to create task definition: " <> show taskName

loadTaskDef :: Pool -> UUID -> IO (PulseTaskDefinitionRow Result)
loadTaskDef pool taskId = do
  result <- runSession pool $ Q.getTaskById taskId
  case result of
    Just task -> pure task
    Nothing -> fail $ "Task not found: " <> show taskId

setRunLeaseExpiry :: Pool -> UUID -> UTCTime -> IO ()
setRunLeaseExpiry pool runId leaseExpiry =
  runSession pool . Session.statement (runId, leaseExpiry) $
    Statement
      "UPDATE pulse.runs SET lease_expires_at = $2 WHERE run_id = $1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

-- | Delete test task definitions and their runs to avoid polluting other tests.
cleanupTestTasks :: Pool -> [UUID] -> IO ()
cleanupTestTasks pool =
  mapM_ cleanupOne
  where
    deleteStmt sql = Statement sql (E.param (E.nonNullable E.uuid)) D.noResult False
    cleanupOne taskId = do
      runSession pool $ Session.statement taskId (deleteStmt "DELETE FROM pulse.runs WHERE task_id = $1")
      runSession pool $
        Session.statement taskId (deleteStmt "DELETE FROM pulse.task_definitions WHERE task_id = $1")

setTaskLastRunAt :: Pool -> UUID -> UTCTime -> IO ()
setTaskLastRunAt pool taskId lastRunAt' =
  runSession pool . Session.statement (taskId, lastRunAt') $
    Statement
      "UPDATE pulse.task_definitions SET last_run_at = $2, updated_at = $2 WHERE task_id = $1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

countRunningRunsForType :: Pool -> Text -> IO Int32
countRunningRunsForType pool taskType =
  runSession pool . Session.statement taskType $
    Statement
      "SELECT COUNT(*)::int FROM pulse.runs r \
      \INNER JOIN pulse.task_definitions td ON r.task_id = td.task_id \
      \WHERE r.status = 'running'::pulse.run_status AND td.task_type = $1"
      (E.param (E.nonNullable E.text))
      (D.singleRow (D.column (D.nonNullable D.int4)))
      True

mkBlockingHandler :: MVar () -> TaskHandler
mkBlockingHandler release =
  TaskHandler
    { executeFresh = completeAfterRelease
    , resumeExisting = completeAfterRelease
    }
  where
    completeAfterRelease taskContext runId _task = do
      readMVar release
      completedAt <- getCurrentTime
      runTx (tcPool taskContext) $ Q.updateRunCompleted runId completedAt
      pure OutcomeCompleted

waitUntil :: String -> IO Bool -> IO ()
waitUntil label predicate = do
  satisfied <- go (500 :: Int)
  if satisfied
    then pure ()
    else expectationFailure ("Timed out waiting for " <> label)
  where
    go 0 = pure False
    go attemptsLeft = do
      ready <- predicate
      if ready
        then pure True
        else do
          threadDelay 20000
          go (attemptsLeft - 1)

simpleStage :: TestStage -> (UUID -> Aeson.Value -> IO Aeson.Value) -> StageDefinition TestStage
simpleStage stageId action =
  StageDefinition
    { sdStageId = stageId
    , sdTemplateId = stageTemplateId stageId
    , sdActionId = stageActionId stageId
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = liftChainAction action
    , sdMemoryStrategy = defaultMemoryStrategy
    }

expectMaybeTimeNear :: Maybe UTCTime -> Maybe UTCTime -> Expectation
expectMaybeTimeNear actual expected =
  case (actual, expected) of
    (Just actualTime, Just expectedTime) ->
      (abs (realToFrac (diffUTCTime actualTime expectedTime) :: Double) < 0.000001)
        `shouldBe` True
    _ -> actual `shouldBe` expected

expectCreatedRun :: String -> Maybe UUID -> IO UUID
expectCreatedRun label =
  maybe (fail $ label <> ": expected a created run") pure

testPulseConfig :: PulseConfig
testPulseConfig =
  PulseConfig
    { pulseDbHost = "localhost"
    , pulseDbPort = 5432
    , pulseDbUser = "cortex"
    , pulseDbPassword = ""
    , pulseDbName = "cortex"
    , pulseDbPoolSize = 1
    , pulseApiUrl = "http://127.0.0.1:8080"
    , pulseJwtSecret = "test-secret-key-for-unit-testing-only-32chars"
    , pulseJwtExpirationSeconds = 86400
    , pulseJwtIssuer = "cortex-pulse"
    , pulseJwtAudience = "cortex-host"
    , pulseAdminApiKey = Just "test-admin-api-key"
    , pulseServiceCredential = Just "test-pulse-credential"
    , pulseHealthPort = 9090
    , pulseLeaseOwner = "test-owner"
    , pulseLeaseDurationSeconds = 300
    , pulsePollIntervalSeconds = 5
    , pulseMaxConcurrentTasks = 4
    , pulseMaxFrontierConcurrency = 1
    , pulseTaskTypeLimits = mempty
    }

testTime :: UTCTime
testTime =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

testTimePlus60 :: UTCTime
testTimePlus60 =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 60)

testTimePlus120 :: UTCTime
testTimePlus120 =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 120)

testTimePlus300 :: UTCTime
testTimePlus300 =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 300)

testTimePlus3600 :: UTCTime
testTimePlus3600 =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 3600)
