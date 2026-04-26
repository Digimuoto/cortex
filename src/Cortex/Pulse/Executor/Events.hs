{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Cortex.Pulse.Executor.Events
-- Description : Typed observability events for the Pulse executor
--
-- A closed ADT of all executor-emitted observability events, with a
-- 'ToObsEvent' instance that derives level, code, component, message,
-- and structured fields from each constructor.
--
-- Call sites migrate from:
--
-- @
-- emitExecutorEvent ObsError (ObsEventCode "pulse.executor.stage.failed")
--   ("Stage failed: " <> stageName)
--   [("run_id", toJSON runId), ("stage", toJSON stageName)]
-- @
--
-- To:
--
-- @
-- emitObsEvent $ EvtStageFailed runId stageName attempt errorType errorMsg
-- @
module Cortex.Pulse.Executor.Events
  ( ExecutorEvent (..),
    StageRetryInfo (..),
    StageFailureDetail (..),
    FailrunInfo (..),
    RewriteAdmissionInfo (..),
    RewriteRejectionInfo (..),
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Platform.Observability.Fields
  ( ObsEventCode (ObsEventCode),
    ObsFields,
    ToObsEvent (..),
    field,
    noFields,
  )
import Platform.Observability.Types (ObservabilityLogLevel (..))

-- | All executor-emitted observability events.
--
-- Each constructor carries exactly the data needed to reconstruct the
-- message and structured fields.  The 'ToObsEvent' instance maps each
-- to its canonical level, event code, and field set.
data ExecutorEvent
  = -- Resume
    EvtResumeGraph UUID
  | EvtResumeGraphParseFailed UUID Text
  | EvtResumeFresh UUID
  | -- | Graph state runtime version mismatch.
    EvtResumeGraphVersionMismatch UUID Text
  | -- | Graph state has no runtime_version (pre-migration row).
    EvtResumeGraphNoVersion UUID
  | -- | Failed to read graph state from DB.
    EvtResumeGraphStateReadFailed UUID Text
  | -- | Topology hash mismatch between persisted state and lineage replay.
    EvtResumeIntegrityMismatch UUID Text Text
  | -- Stage lifecycle
    EvtStageLogFailed UUID Text Text
  | EvtStageResumed UUID Text Int64 Int
  | EvtStageCompleted UUID Text Int
  | EvtStageFailed UUID Text Int StageFailureDetail
  | EvtStageSkipped UUID Text Int Text
  | EvtStageLogWriteFailed UUID Text Text
  | -- Stage attempt
    EvtStageAttemptLogFailed UUID Text Text
  | EvtStageAttemptSuspendWriteFailed UUID Text Text
  | EvtStageRetry UUID StageRetryInfo
  | EvtStageTimeoutIrreversible UUID Text Int
  | -- Completion / cancellation
    EvtTaskCompleted UUID
  | EvtRunSuspended UUID
  | EvtShutdownRequested UUID Text
  | EvtCancelWriteFailed UUID Text
  | EvtTaskCancelled UUID Text
  | EvtCancelCheckFailed UUID Text Text
  | -- Signals
    EvtSuspendWriteFailed UUID Text Text
  | EvtSignalResolved UUID Text Text
  | EvtSignalLookupFailed UUID Text Text Text
  | -- Rewrite admission
    EvtRewriteAdmitted UUID Text RewriteAdmissionInfo
  | EvtRewriteRejected UUID Text RewriteRejectionInfo
  | EvtRewriteReExecution UUID Text Int
  | -- Frontier
    EvtFrontierStart UUID Int Int
  | EvtFrontierComplete UUID Int Int Bool
  | EvtGraphStateWriteFailed UUID Text
  | -- Replay policy
    EvtReplayCheckFailed UUID Text Text
  | EvtReplayCheckDbFailed UUID Text Text Text
  | EvtReplayIrreversibleWarn UUID Text [Text] Int Text
  | EvtReplayBlocked UUID Text [Text] Int Text
  | EvtReplayBlockedNeedsOverride UUID Text [Text] Int Text
  | -- DB errors
    EvtDbCritical UUID Text Text
  | EvtFailrunDb UUID FailrunInfo
  | EvtTimeoutrunDb UUID FailrunInfo
  | EvtUnsupportedTaskType UUID Text
  deriving stock (Show)

-- | Extra context for retry events.
data StageRetryInfo = StageRetryInfo
  { sriStageName :: Text,
    sriAttempt :: Int,
    sriNextAttempt :: Int,
    sriRetryDelayMicros :: Int64,
    sriErrorType :: Text,
    sriErrorMessage :: Text
  }
  deriving stock (Show)

-- | Error type and message for a terminal stage failure.
-- Bundled in a record to prevent the two adjacent 'Text' fields from being swapped.
data StageFailureDetail = StageFailureDetail
  { sfdErrType :: Text,
    sfdErrMsg :: Text
  }
  deriving stock (Show)

-- | Extra context for last-resort DB error events.
data FailrunInfo = FailrunInfo
  { friOriginalErrorType :: Text,
    friOriginalErrorMsg :: Text,
    friDbError :: Text
  }
  deriving stock (Show)

-- | Info for a successfully admitted rewrite.
data RewriteAdmissionInfo = RewriteAdmissionInfo
  { raiRewriteId :: Int64,
    raiCostNodes :: Int,
    raiCostEdges :: Int,
    raiRewriteOpsRemaining :: Int
  }
  deriving stock (Show)

-- | Info for a rejected rewrite (budget or validation).
data RewriteRejectionInfo = RewriteRejectionInfo
  { rrjRejectionType :: Text,
    rrjMessage :: Text,
    rrjAttemptNumber :: Maybe Int,
    rrjTopologyChanged :: Bool
  }
  deriving stock (Show)

instance ToObsEvent ExecutorEvent where
  obsLevel = executorEventLevel
  obsCode = executorEventCode
  obsComponent _ = "cortex-pulse"
  obsMessage = executorEventMessage
  obsFields = executorEventFields

-- ============================================================================
-- Level mapping
-- ============================================================================

executorEventLevel :: ExecutorEvent -> ObservabilityLogLevel
executorEventLevel = \case
  EvtResumeGraph {} -> ObsInfo
  EvtResumeGraphParseFailed {} -> ObsError
  EvtResumeFresh {} -> ObsInfo
  EvtResumeGraphVersionMismatch {} -> ObsError
  EvtResumeGraphNoVersion {} -> ObsWarn
  EvtResumeGraphStateReadFailed {} -> ObsError
  EvtResumeIntegrityMismatch {} -> ObsWarn
  EvtStageLogFailed {} -> ObsError
  EvtStageResumed {} -> ObsInfo
  EvtStageCompleted {} -> ObsInfo
  EvtStageFailed {} -> ObsError
  EvtStageSkipped {} -> ObsWarn
  EvtStageLogWriteFailed {} -> ObsWarn
  EvtStageAttemptLogFailed {} -> ObsError
  EvtStageAttemptSuspendWriteFailed {} -> ObsWarn
  EvtStageRetry {} -> ObsWarn
  EvtStageTimeoutIrreversible {} -> ObsError
  EvtTaskCompleted {} -> ObsInfo
  EvtRunSuspended {} -> ObsInfo
  EvtShutdownRequested {} -> ObsInfo
  EvtCancelWriteFailed {} -> ObsError
  EvtTaskCancelled {} -> ObsInfo
  EvtCancelCheckFailed {} -> ObsWarn
  EvtSuspendWriteFailed {} -> ObsError
  EvtSignalResolved {} -> ObsInfo
  EvtSignalLookupFailed {} -> ObsWarn
  EvtRewriteAdmitted {} -> ObsInfo
  EvtRewriteRejected {} -> ObsWarn
  EvtRewriteReExecution {} -> ObsInfo
  EvtFrontierStart {} -> ObsInfo
  EvtFrontierComplete {} -> ObsInfo
  EvtGraphStateWriteFailed {} -> ObsError
  EvtReplayCheckFailed {} -> ObsWarn
  EvtReplayCheckDbFailed {} -> ObsError
  EvtReplayIrreversibleWarn {} -> ObsWarn
  EvtReplayBlocked {} -> ObsError
  EvtReplayBlockedNeedsOverride {} -> ObsError
  EvtDbCritical {} -> ObsError
  EvtFailrunDb {} -> ObsError
  EvtTimeoutrunDb {} -> ObsError
  EvtUnsupportedTaskType {} -> ObsError

-- ============================================================================
-- Event code mapping
-- ============================================================================

executorEventCode :: ExecutorEvent -> ObsEventCode
executorEventCode = \case
  EvtResumeGraph {} -> ObsEventCode "pulse.executor.resume.graph"
  EvtResumeGraphParseFailed {} -> ObsEventCode "pulse.executor.resume.graph.parse"
  EvtResumeFresh {} -> ObsEventCode "pulse.executor.resume.fresh"
  EvtResumeGraphVersionMismatch {} -> ObsEventCode "pulse.executor.resume.graph.version_mismatch"
  EvtResumeGraphNoVersion {} -> ObsEventCode "pulse.executor.resume.graph.no_version"
  EvtResumeGraphStateReadFailed {} -> ObsEventCode "pulse.executor.resume.graph_state_read_failed"
  EvtResumeIntegrityMismatch {} -> ObsEventCode "pulse.executor.resume.integrity_mismatch"
  EvtStageLogFailed {} -> ObsEventCode "pulse.executor.stage.log"
  EvtStageResumed {} -> ObsEventCode "pulse.executor.stage.resume"
  EvtStageCompleted {} -> ObsEventCode "pulse.executor.stage.completed"
  EvtStageFailed {} -> ObsEventCode "pulse.executor.stage.failed"
  EvtStageSkipped {} -> ObsEventCode "pulse.executor.stage.skipped"
  EvtStageLogWriteFailed {} -> ObsEventCode "pulse.executor.stage.log.write"
  EvtStageAttemptLogFailed {} -> ObsEventCode "pulse.executor.stage_attempt.log"
  EvtStageAttemptSuspendWriteFailed {} -> ObsEventCode "pulse.executor.stage_attempt.suspend.write"
  EvtStageRetry {} -> ObsEventCode "pulse.executor.stage.retry"
  EvtStageTimeoutIrreversible {} -> ObsEventCode "pulse.executor.stage.timeout_irreversible"
  EvtTaskCompleted {} -> ObsEventCode "pulse.executor.completed"
  EvtRunSuspended {} -> ObsEventCode "pulse.executor.suspended"
  EvtShutdownRequested {} -> ObsEventCode "pulse.executor.shutdown"
  EvtCancelWriteFailed {} -> ObsEventCode "pulse.executor.cancel.write"
  EvtTaskCancelled {} -> ObsEventCode "pulse.executor.cancelled"
  EvtCancelCheckFailed {} -> ObsEventCode "pulse.executor.cancel.check"
  EvtSuspendWriteFailed {} -> ObsEventCode "pulse.executor.suspend.write"
  EvtSignalResolved {} -> ObsEventCode "pulse.executor.signal.resolved"
  EvtSignalLookupFailed {} -> ObsEventCode "pulse.executor.signal.lookup_failed"
  EvtRewriteAdmitted {} -> ObsEventCode "pulse.executor.rewrite.admitted"
  EvtRewriteRejected {} -> ObsEventCode "pulse.executor.rewrite.rejected"
  EvtRewriteReExecution {} -> ObsEventCode "pulse.executor.rewrite.re_execution"
  EvtFrontierStart {} -> ObsEventCode "pulse.executor.frontier.concurrent.start"
  EvtFrontierComplete {} -> ObsEventCode "pulse.executor.frontier.concurrent.complete"
  EvtGraphStateWriteFailed {} -> ObsEventCode "pulse.executor.graph_state.write"
  EvtReplayCheckFailed {} -> ObsEventCode "pulse.executor.resume.replay_check"
  EvtReplayCheckDbFailed {} -> ObsEventCode "pulse.executor.resume.replay_check_failed"
  EvtReplayIrreversibleWarn {} -> ObsEventCode "pulse.executor.resume.replay_irreversible"
  EvtReplayBlocked {} -> ObsEventCode "pulse.executor.resume.replay_blocked"
  EvtReplayBlockedNeedsOverride {} -> ObsEventCode "pulse.executor.resume.replay_blocked.operator_override"
  EvtDbCritical {} -> ObsEventCode "pulse.executor.db.critical"
  EvtFailrunDb {} -> ObsEventCode "pulse.executor.failrun.db"
  EvtTimeoutrunDb {} -> ObsEventCode "pulse.executor.timeoutrun.db"
  EvtUnsupportedTaskType {} -> ObsEventCode "pulse.executor.unsupported_task_type"

-- ============================================================================
-- Message reconstruction
-- ============================================================================

executorEventMessage :: ExecutorEvent -> Text
executorEventMessage = \case
  EvtResumeGraph {} ->
    "Resuming from persisted graph state"
  EvtResumeGraphParseFailed _ errMsg ->
    errMsg
  EvtResumeFresh {} ->
    "No graph state found, starting from scratch with replay check"
  EvtResumeGraphVersionMismatch _ errMsg ->
    errMsg
  EvtResumeGraphNoVersion {} ->
    "Graph state has no runtime_version (pre-migration row), proceeding"
  EvtResumeGraphStateReadFailed _ errMsg ->
    "Failed to read graph state: " <> errMsg
  EvtResumeIntegrityMismatch _ expected persisted ->
    "Topology hash mismatch: expected " <> expected <> " but persisted " <> persisted
  EvtStageLogFailed _ _ err ->
    "Failed to log stage start: " <> err
  EvtStageResumed {} ->
    "Reusing open stage log after resume"
  EvtStageCompleted _ stageName _ ->
    "Stage completed: " <> stageName
  EvtStageFailed _ _ _ detail ->
    "Stage failed: " <> detail.sfdErrMsg
  EvtStageSkipped _ stageName _ _ ->
    "Skipping stage after retry budget exhaustion: " <> stageName
  EvtStageLogWriteFailed _ _ err ->
    "Failed to update stage audit log for failed stage (non-critical): " <> err
  EvtStageAttemptLogFailed _ _ err ->
    "Failed to log stage attempt start: " <> err
  EvtStageAttemptSuspendWriteFailed _ _ err ->
    "Failed to update stage attempt for suspension (non-critical): " <> err
  EvtStageRetry _ info ->
    "Retrying stage after failure: " <> info.sriErrorMessage
  EvtStageTimeoutIrreversible {} ->
    "Irreversible stage timed out \x2014 side effects may have completed"
  EvtTaskCompleted {} ->
    "Task completed"
  EvtRunSuspended {} ->
    "Run suspended, waiting on signal"
  EvtShutdownRequested {} ->
    "Shutdown requested, stopping at stage boundary"
  EvtCancelWriteFailed _ err ->
    "Failed to write cancellation: " <> err
  EvtTaskCancelled {} ->
    "Task cancelled"
  EvtCancelCheckFailed _ _ err ->
    "Cancellation check failed, continuing: " <> err
  EvtSuspendWriteFailed _ _ err ->
    "Failed to persist signal wait, failing node: " <> err
  EvtSignalResolved _ _ node ->
    "Signal delivered, completing node: " <> node
  EvtSignalLookupFailed _ _ _ err ->
    "Failed to check signal delivery: " <> err
  EvtRewriteAdmitted _ stageName _ ->
    "Rewrite admitted: " <> stageName
  EvtRewriteRejected _ stageName info ->
    "Rewrite rejected (" <> info.rrjRejectionType <> ") for " <> stageName <> ": " <> info.rrjMessage
  EvtRewriteReExecution _ stageName attempt ->
    "Re-executing " <> stageName <> " with rejection context (attempt " <> T.pack (show attempt) <> ")"
  EvtFrontierStart _ size cap ->
    "Dispatching " <> T.pack (show size) <> " frontier nodes with concurrency cap " <> T.pack (show cap)
  EvtFrontierComplete _ _ durationMs _ ->
    "Frontier completed in " <> T.pack (show durationMs) <> "ms"
  EvtGraphStateWriteFailed _ err ->
    "Failed to persist graph state: " <> err
  EvtReplayCheckFailed {} ->
    "Failed to inspect prior stage log when resuming an irreversible stage"
  EvtReplayCheckDbFailed {} ->
    "Stage log lookup failed \x2014 failing closed for strict replay policy"
  EvtReplayIrreversibleWarn {} ->
    "Replaying irreversible stage after resume (policy: warn)"
  EvtReplayBlocked {} ->
    "Replay of irreversible stage blocked by policy"
  EvtReplayBlockedNeedsOverride {} ->
    "Replay of irreversible stage requires operator override \x2014 create a retry run"
  EvtDbCritical _ ctx err ->
    "Critical DB write failed (" <> ctx <> "): " <> err
  EvtFailrunDb _ info ->
    "LAST RESORT: failed to mark run as failed. "
      <> "Run will remain 'running' until lease expires. "
      <> "Original error: "
      <> info.friOriginalErrorType
      <> " / "
      <> info.friOriginalErrorMsg
      <> " \x2014 DB error: "
      <> info.friDbError
  EvtTimeoutrunDb _ info ->
    "LAST RESORT: failed to mark run as timed out. "
      <> "Run will remain 'running' until lease expires. "
      <> "Original error: "
      <> info.friOriginalErrorType
      <> " / "
      <> info.friOriginalErrorMsg
      <> " \x2014 DB error: "
      <> info.friDbError
  EvtUnsupportedTaskType _ taskType ->
    "Unsupported task type: " <> taskType

-- ============================================================================
-- Structured fields
-- ============================================================================

executorEventFields :: ExecutorEvent -> ObsFields
executorEventFields = \case
  EvtResumeGraph runId ->
    field "run_id" runId
  EvtResumeGraphParseFailed runId _ ->
    field "run_id" runId
  EvtResumeFresh runId ->
    field "run_id" runId
  EvtResumeGraphVersionMismatch runId _ ->
    field "run_id" runId
  EvtResumeGraphNoVersion runId ->
    field "run_id" runId
  EvtResumeGraphStateReadFailed runId _ ->
    field "run_id" runId
  EvtResumeIntegrityMismatch runId expected persisted ->
    field "run_id" runId <> field "expected_hash" expected <> field "persisted_hash" persisted
  EvtStageLogFailed runId stageName _ ->
    field "run_id" runId <> field "stage" stageName
  EvtStageResumed runId stageName logId nextAttempt ->
    field "run_id" runId <> field "stage" stageName <> field "stage_log_id" logId <> field "next_attempt" nextAttempt
  EvtStageCompleted runId stageName attempt ->
    field "run_id" runId <> field "stage" stageName <> attemptFieldIf attempt
  EvtStageFailed runId stageName attempt detail ->
    field "run_id" runId <> field "stage" stageName <> field "attempts" attempt <> field "error_type" detail.sfdErrType
  EvtStageSkipped runId stageName attempt errType ->
    field "run_id" runId <> field "stage" stageName <> field "attempts" attempt <> field "error_type" errType
  EvtStageLogWriteFailed runId stageName _ ->
    field "run_id" runId <> field "stage" stageName
  EvtStageAttemptLogFailed runId stageName _ ->
    field "run_id" runId <> field "stage" stageName
  EvtStageAttemptSuspendWriteFailed runId stageName _ ->
    field "run_id" runId <> field "stage" stageName
  EvtStageRetry runId info ->
    field "run_id" runId
      <> field "stage" info.sriStageName
      <> field "attempt" info.sriAttempt
      <> field "next_attempt" info.sriNextAttempt
      <> field "retry_delay_micros" info.sriRetryDelayMicros
      <> field "error_type" info.sriErrorType
  EvtStageTimeoutIrreversible runId stageName secs ->
    field "run_id" runId <> field "stage" stageName <> field "timeout_seconds" secs
  EvtTaskCompleted runId ->
    field "run_id" runId
  EvtRunSuspended runId ->
    field "run_id" runId
  EvtShutdownRequested runId beforeStage ->
    field "run_id" runId <> field "before_stage" beforeStage
  EvtCancelWriteFailed runId _ ->
    field "run_id" runId
  EvtTaskCancelled runId beforeStage ->
    field "run_id" runId <> field "before_stage" beforeStage
  EvtCancelCheckFailed runId stageName _ ->
    field "run_id" runId <> field "stage" stageName
  EvtSuspendWriteFailed runId signal _ ->
    field "run_id" runId <> field "signal" signal
  EvtSignalResolved runId signal node ->
    field "run_id" runId <> field "signal" signal <> field "node" node
  EvtSignalLookupFailed runId signal node _ ->
    field "run_id" runId <> field "signal" signal <> field "node" node
  EvtRewriteAdmitted runId stageName info ->
    field "run_id" runId <> field "stage" stageName <> field "rewrite_id" info.raiRewriteId <> field "cost_nodes" info.raiCostNodes <> field "cost_edges" info.raiCostEdges <> field "rewrite_ops_remaining" info.raiRewriteOpsRemaining
  EvtRewriteRejected runId stageName info ->
    field "run_id" runId
      <> field "stage" stageName
      <> field "rejection_type" info.rrjRejectionType
      <> field "rejection_message" info.rrjMessage
      <> field "topology_changed" info.rrjTopologyChanged
      <> maybe mempty (field "attempt_number") info.rrjAttemptNumber
  EvtRewriteReExecution runId stageName attempt ->
    field "run_id" runId <> field "stage" stageName <> field "re_execution_attempt" attempt
  EvtFrontierStart runId size cap ->
    field "run_id" runId <> field "frontier_size" size <> field "concurrency_cap" cap
  EvtFrontierComplete runId size durationMs terminal ->
    field "run_id" runId <> field "frontier_size" size <> field "duration_ms" durationMs <> field "terminal" terminal
  EvtGraphStateWriteFailed runId _ ->
    field "run_id" runId
  EvtReplayCheckFailed runId stageName err ->
    field "run_id" runId <> field "stage" stageName <> field "error" err
  EvtReplayCheckDbFailed runId stageName replayPolicy err ->
    field "run_id" runId <> field "stage" stageName <> field "replay_policy" replayPolicy <> field "error" err
  EvtReplayIrreversibleWarn runId stageName priorStatuses priorAttempts replayPolicy ->
    field "run_id" runId <> field "stage" stageName <> field "prior_statuses" priorStatuses <> field "prior_attempts" priorAttempts <> field "replay_policy" replayPolicy
  EvtReplayBlocked runId stageName priorStatuses priorAttempts replayPolicy ->
    field "run_id" runId <> field "stage" stageName <> field "prior_statuses" priorStatuses <> field "prior_attempts" priorAttempts <> field "replay_policy" replayPolicy
  EvtReplayBlockedNeedsOverride runId stageName priorStatuses priorAttempts replayPolicy ->
    field "run_id" runId <> field "stage" stageName <> field "prior_statuses" priorStatuses <> field "prior_attempts" priorAttempts <> field "replay_policy" replayPolicy
  EvtDbCritical runId ctx _ ->
    field "run_id" runId <> field "context" ctx
  EvtFailrunDb runId info ->
    field "run_id" runId <> field "original_error_type" info.friOriginalErrorType <> field "db_error" info.friDbError
  EvtTimeoutrunDb runId info ->
    field "run_id" runId <> field "original_error_type" info.friOriginalErrorType <> field "db_error" info.friDbError
  EvtUnsupportedTaskType runId taskType ->
    field "run_id" runId <> field "task_type" taskType

-- | Include attempts field only when attempt > 1 (matches original executor behavior).
attemptFieldIf :: Int -> ObsFields
attemptFieldIf attempt
  | attempt > 1 = field "attempts" attempt
  | otherwise = noFields
