{- |
Module      : Cortex.Pulse.Query
Description : Database queries for Pulse-owned tables.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

All queries operate on the pulse.* schema.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Query
  ( -- * Task Discovery
    getNextDueTask

    -- * Run Management
  , claimAndCreateRun
  , claimAndCreateRunWithParent
  , claimAndCreateRunWithParentAndProfile
  , RunExecutionProfile (..)
  , RunExecutionProfileFreezeResult (..)
  , freezeRunExecutionProfile
  , readRunExecutionProfile
  , claimNextPendingRun
  , ManagedResumeClaim (..)
  , claimManagedRunForResume
  , expireManagedRunLease
  , createPendingRun
  , getRunStatusForUpdate
  , TerminalRunStatus (..)
  , terminalStatusText
  , parseTerminalStatus
  , isTerminalStatus
  , allTerminalStatuses
  , updateRunStarted
  , updateRunCompleted
  , updateRunFailed
  , updateRunCancelled
  , updateRunTimedOut
  , getRunStartedAt

    -- * Checkpoint
  , writeCheckpoint
  , readCheckpointPayload
  , readCheckpointPayloadValidated

    -- * Stage Log
  , findOpenStageLogId
  , getNextStageAttemptNumber
  , appendStageStarted
  , appendStageAttemptStarted
  , updateStageCompleted
  , updateStageAttemptCompleted

    -- * Scheduling
  , advanceTaskSchedule
  , completeOneOffTask
  , restoreTaskSchedule

    -- * Cancellation
  , requestCancellation
  , checkCancellation
  , disableTaskByRunId
  , releaseSchedulerClaimByRunId

    -- * Lease Management
  , renewRunLease

    -- * Recovery
  , PulseExpiredRunRecovery (..)
  , reclaimOwnedRuns
  , recoverExpiredRuns

    -- * Scheduling helpers
  , restoreOneOffTaskAt
  , restoreTaskForFailedRun

    -- * Admin views and writes
  , PulseTaskDefinitionInsert (..)
  , PulseRunAdminView (..)
  , PulseRunUserView (..)
  , PulseCheckpointDetail (..)
  , PulseStageLogDetail (..)
  , PulseStageAttemptLogDetail (..)
  , PulseGraphStateSnapshot (..)
  , PulseGraphStateAdminView (..)
  , PulseGraphRewriteAdminView (..)
  , RunFailureUpdate (..)
  , RunTimeoutUpdate (..)
  , RunEventSeverity (..)
  , RunEventInsert (..)
  , GraphStateWrite (..)
  , GraphStateWriteResult (..)
  , GraphRewriteInsert (..)
  , PulsePendingRunClaim (..)
  , createTaskDefinition
  , getRunAdminView
  , listRunsForTask
  , listRunsForUser
  , getRunUserId
  , getRunStatusReadOnly
  , getRunStatusReadOnlyForUser
  , getCheckpointDetail
  , listStageLogDetails
  , listStageAttemptLogDetails
  , updateTaskLastRun
  , updateTaskLastRunOnly

    -- * Listing
  , listTasks
  , getTaskForRun

    -- * Run event history
  , PulseRunEvent (..)
  , appendRunEvent
  , recordRunEvent
  , getLatestRunEvent
  , listRunEvents

    -- * Graph state
  , readGraphState
  , readGraphStateForAdmin
  , writeGraphState
  , readGraphRewrites
  , readGraphRewritesUpTo
  , readGraphRewritesForAdmin
  , writeGraphRewrite

    -- * Scheduler observability
  , BackpressureSnapshot (..)
  , readBackpressureSnapshot

    -- * Signals
  , registerSignalWait
  , SignalWaitInvalid (..)
  , SignalWaitPendingMode (..)
  , SignalWaitRegistration (..)
  , SignalWaitSettlement (..)
  , planSignalWaitSettlement
  , commitSignalWaitSettlement
  , registerSignalWaitOrResolve
  , orderWokenRunIdsForUpdate
  , deliverSignal
  , deliverRunTerminalSignals
  , deliverExternalCallSignal
  , consumeDeliveredSignal
  , lookupDeliveredSignal
  , lookupDeliveredSignalTx
  , lookupSignalStatus
  , updateRunWaiting
  , wakeRunFromWaiting

    -- * Test support
  , claimTestTaskDef
  , getTaskById
  , readRunStatus
  , countStageLogEntries
  , readNodeCompletionTimes
  )
where

import Control.Monad (when)
import Data.Aeson (ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32, Int64)
import Data.List (find, nub, sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID, toWords)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement (..))
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Rel8 hiding (Statement)
import System.IO qualified

import Cortex.Pulse.Checkpoint
  ( CheckpointReadExpectation
  , CheckpointReadResult (..)
  , StoredCheckpointPayload (..)
  , validateStoredCheckpointPayload
  )
import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.GraphStateRevision (GraphStateRevision (..))
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Query.ExternalCall
  ( ExternalCallAttempt (..)
  , ExternalCallAttemptKey (..)
  , externalCallSignalSuffix
  , externalCallStatusIsTerminal
  , loadExternalCallAttempt
  )
import Cortex.Pulse.Schema
import Cortex.Pulse.Signal
  ( SignalName (..)
  , externalCallSignalName
  , isExternalCallSignal
  , parseRunTerminalSignal
  , runTerminalSignalName
  )

import Platform.Database qualified as DB
import Platform.Database.Encode qualified as Enc
import Platform.DurableTask.Checkpoint (CheckpointEnvelope (..), parseCheckpointEnvelope)
import Platform.DurableTask.Types
  ( RunStatus
  , StageStatus
  , TriggerSource
  , runStatusToText
  , stageStatusToText
  , triggerSourceToText
  )

data PulseTaskDefinitionInsert = PulseTaskDefinitionInsert
  { ptdiTaskType :: Text
  , ptdiTaskName :: Text
  , ptdiConfig :: Value
  , ptdiCronExpression :: Text
  , ptdiEnabled :: Bool
  , ptdiNextRunAt :: Maybe UTCTime
  , ptdiTimeoutSeconds :: Int32
  , ptdiPriority :: Int32
  , ptdiMinIntervalSeconds :: Maybe Int32
  , ptdiCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data PulseRunAdminView = PulseRunAdminView
  { pravRunId :: UUID
  , pravTaskId :: UUID
  , pravStatus :: Text
  , pravTriggerSource :: Text
  , pravStartedAt :: Maybe UTCTime
  , pravCompletedAt :: Maybe UTCTime
  , pravLeaseOwner :: Maybe Text
  , pravLeaseExpiresAt :: Maybe UTCTime
  , pravCancelRequestedAt :: Maybe UTCTime
  , pravCancelReason :: Maybe Text
  , pravErrorType :: Maybe Text
  , pravErrorMessage :: Maybe Text
  , pravErrorRetryable :: Maybe Bool
  , pravSkipReason :: Maybe Text
  , pravParentRunId :: Maybe UUID
  , pravExecutionBackend :: Maybe Text
  , pravProgramIdentity :: Maybe Text
  , pravArtifactDigest :: Maybe Text
  , pravProtocolVersion :: Maybe Text
  , pravCreatedAt :: UTCTime
  , pravLatestStageName :: Maybe Text
  , pravLatestStageStatus :: Maybe Text
  , pravStageCount :: Int32
  }
  deriving stock (Eq, Show)

data PulseCheckpointDetail = PulseCheckpointDetail
  { pcdTaskType :: Text
  , pcdCheckpointName :: Text
  , pcdState :: Value
  , pcdSummary :: Maybe Value
  , pcdUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data PulseStageLogDetail = PulseStageLogDetail
  { psldId :: Int64
  , psldStageName :: Text
  , psldStatus :: Text
  , psldStateSummary :: Maybe Value
  , psldStartedAt :: UTCTime
  , psldCompletedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show)

data PulseStageAttemptLogDetail = PulseStageAttemptLogDetail
  { psaldAttemptId :: Int64
  , psaldStageLogId :: Int64
  , psaldAttemptNumber :: Int32
  , psaldStatus :: Text
  , psaldSummary :: Maybe Value
  , psaldStartedAt :: UTCTime
  , psaldCompletedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show)

data PulseGraphStateAdminView = PulseGraphStateAdminView
  { pgsavNodeStatuses :: Value
  , pgsavNodeOutputs :: Value
  , pgsavRemainingRewriteBudget :: Maybe Value
  , pgsavRuntimeVersion :: Maybe Int32
  , pgsavAppliedRewriteId :: Maybe Int64
  , pgsavNodeProvenance :: Maybe Value
  , pgsavTopologyHash :: Maybe Text
  , pgsavHostedCheckpointSequence :: Maybe Int64
  , pgsavHostedTerminalState :: Maybe Text
  , pgsavUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data PulseGraphStateSnapshot = PulseGraphStateSnapshot
  { pgssNodeStatuses :: Value
  , pgssNodeOutputs :: Value
  , pgssRemainingRewriteBudget :: Maybe Value
  , pgssRuntimeVersion :: Maybe Int32
  , pgssAppliedRewriteId :: Maybe Int64
  , pgssNodeProvenance :: Maybe Value
  , pgssTopologyHash :: Maybe Text
  , pgssHostedCheckpointSequence :: Maybe Int64
  , pgssHostedTerminalState :: Maybe Text
  , pgssRevision :: GraphStateRevision
  }
  deriving stock (Eq, Show)

data PulseGraphRewriteAdminView = PulseGraphRewriteAdminView
  { pgravRewriteId :: Int64
  , pgravSourceNodeId :: Text
  , pgravRewriteCost :: Maybe Value
  , pgravRewriteDelta :: Maybe Value
  , pgravBudgetBefore :: Maybe Value
  , pgravBudgetAfter :: Maybe Value
  , pgravRewriteSpec :: Value
  , pgravStatus :: Text
  , pgravRejectionReason :: Maybe Text
  , pgravExceededDimensions :: Maybe Value
  , pgravCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data GraphRewriteInsert = GraphRewriteInsert
  { griRunId :: UUID
  , griSourceNodeId :: Text
  , griSourceNodeOutput :: Maybe Value
  , griRewriteCost :: Maybe Value
  , griRewriteDelta :: Maybe Value
  , griBudgetBefore :: Maybe Value
  , griBudgetAfter :: Maybe Value
  , griRewriteSpec :: Value
  , griStatus :: Text
  , griRejectionReason :: Maybe Text
  , griExceededDimensions :: Maybe Value
  , griCreatedAt :: UTCTime
  , griAdmissionMode :: Text
  }
  deriving stock (Eq, Show)

data RunFailureUpdate = RunFailureUpdate
  { rfuRunId :: UUID
  , rfuCompletedAt :: UTCTime
  , rfuErrType :: Text
  , rfuErrMsg :: Text
  , rfuRetryable :: Bool
  }
  deriving stock (Eq, Show)

data RunTimeoutUpdate = RunTimeoutUpdate
  { rtuRunId :: UUID
  , rtuCompletedAt :: UTCTime
  , rtuErrType :: Text
  , rtuErrMsg :: Text
  }
  deriving stock (Eq, Show)

data RunEventSeverity
  = RunEventInfo
  | RunEventWarn
  | RunEventError
  deriving stock (Eq, Show)

data RunEventInsert = RunEventInsert
  { reiRunId :: UUID
  , reiEventType :: Text
  , reiSeverity :: RunEventSeverity
  , reiMessage :: Text
  , reiDetails :: Maybe Value
  }
  deriving stock (Eq, Show)

renderRunEventSeverity :: RunEventSeverity -> Text
renderRunEventSeverity = \case
  RunEventInfo -> "info"
  RunEventWarn -> "warn"
  RunEventError -> "error"

data GraphStateWrite = GraphStateWrite
  { gswRunId :: UUID
  , gswNodeStatuses :: Value
  , gswNodeOutputs :: Value
  , gswRemainingRewriteBudget :: Maybe Value
  , gswRuntimeVersion :: Maybe Int32
  , gswAppliedRewriteId :: Maybe Int64
  , gswNodeProvenance :: Maybe Value
  , gswTopologyHash :: Maybe Text
  , gswHostedCheckpointSequence :: Maybe Int64
  , gswHostedTerminalState :: Maybe Text
  , gswUpdatedAt :: UTCTime
  , gswExpectedRevision :: Maybe GraphStateRevision
  }
  deriving stock (Eq, Show)

data GraphStateWriteResult
  = GraphStateWriteApplied !GraphStateRevision
  | GraphStateWriteStale
  deriving stock (Eq, Show)

data PulsePendingRunClaim = PulsePendingRunClaim
  { pprcRunId :: UUID
  , pprcTriggerSource :: Text
  }
  deriving stock (Eq, Show)

data ManagedResumeClaim = ManagedResumeClaim
  { mrcStatus :: Text
  , mrcClaimed :: Bool
  }
  deriving stock (Eq, Show)

-- | Immutable identity of the whole-run executor selected for a compiled Circuit.
data RunExecutionProfile = RunExecutionProfile
  { repExecutionBackend :: !Text
  , repProgramIdentity :: !Text
  , repArtifactDigest :: !(Maybe Text)
  , repProtocolVersion :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data RunExecutionProfileFreezeResult
  = RunExecutionProfileFrozen
  | RunExecutionProfileMismatch !RunExecutionProfile
  | RunExecutionProfileRunMissing
  deriving stock (Eq, Show)

data ManagedRunClaimInput = ManagedRunClaimInput
  { mrciTaskId :: !UUID
  , mrciLeaseOwner :: !Text
  , mrciTriggerSource :: !TriggerSource
  , mrciParentRunId :: !(Maybe UUID)
  , mrciNow :: !UTCTime
  , mrciLeaseDurationSeconds :: !Int32
  , mrciExecutionProfile :: !(Maybe RunExecutionProfile)
  }

data PulseExpiredRunRecovery = PulseExpiredRunRecovery
  { perrRunId :: UUID
  , perrTaskId :: UUID
  , perrTriggerSource :: Text
  , perrTaskName :: Maybe Text
  , perrCronExpression :: Maybe Text
  }
  deriving stock (Eq, Show)

-- ============================================================================
-- Task Discovery
-- ============================================================================

{- | Get the next due task definition (enabled, next_run_at <= now).

Ordering: priority DESC, deprioritized types last, then next_run_at ASC.
@excludedTypes@: types at their per-type concurrency limit.
@deprioritized@: types already claimed this fill cycle (round-robin fairness).
@skippedTaskIds@: specific tasks to skip (e.g. in cooldown).
Cooldown filtering (min_interval_seconds) is handled at the scheduler level
after loading the task, because Rel8 lacks clean interval arithmetic.
-}
getNextDueTask
  :: [Text] -> [Text] -> [UUID] -> UTCTime -> Session (Maybe (PulseTaskDefinitionRow Result))
getNextDueTask excludedTypes deprioritized skippedTaskIds now =
  Session.statement () . runMaybe . select . limit 1 . orderBy taskOrder $ do
    task <- each pulseTaskDefinitionSchema
    where_
      ( task.enabled ==. lit True
          &&. task.schedulerClaimed ==. lit False
          &&. isNonNull task.nextRunAt
          &&. task.nextRunAt <=. lit (Just now)
      )
    case excludedTypes of
      [] -> pure ()
      _ -> where_ (not_ (task.taskType `in_` fmap lit excludedTypes))
    case skippedTaskIds of
      [] -> pure ()
      _ -> where_ (not_ (task.taskId `in_` fmap lit skippedTaskIds))
    pure task
  where
    taskOrder =
      mconcat
        [ (.priority) >$< desc
        , deprioritizeOrder
        , (\t -> unsafeCastExpr t.nextRunAt :: Expr UTCTime) >$< asc
        ]
    -- Round-robin: deprioritized types sort after non-deprioritized (0 < 1)
    deprioritizeOrder = case deprioritized of
      [] -> mempty
      _ -> (\t -> boolExpr (lit (0 :: Int32)) (lit 1) (t.taskType `in_` fmap lit deprioritized)) >$< asc

-- ============================================================================
-- Run Management
-- ============================================================================

-- | Atomically claim a task and create a run. Returns Nothing if already claimed.
claimAndCreateRun :: UUID -> Text -> TriggerSource -> UTCTime -> Int32 -> Transaction (Maybe UUID)
claimAndCreateRun tId leaseOwner triggerSource =
  claimAndCreateRunWithParent tId leaseOwner triggerSource Nothing

{- | 'claimAndCreateRun' with an optional predecessor link. A supplied parent is
written to @parent_run_id@ atomically with run creation, so lineage is never
observable half-set. The parent must exist ('pulse.runs' self-FK); a violation
surfaces as the transaction's error path, not a silent NULL.
-}
claimAndCreateRunWithParent
  :: UUID -> Text -> TriggerSource -> Maybe UUID -> UTCTime -> Int32 -> Transaction (Maybe UUID)
claimAndCreateRunWithParent tId leaseOwner triggerSource parentRunId now leaseDurationSec =
  claimAndCreateManagedRun
    ManagedRunClaimInput
      { mrciTaskId = tId
      , mrciLeaseOwner = leaseOwner
      , mrciTriggerSource = triggerSource
      , mrciParentRunId = parentRunId
      , mrciNow = now
      , mrciLeaseDurationSeconds = leaseDurationSec
      , mrciExecutionProfile = Nothing
      }

{- | Managed Circuit claim with the immutable execution profile written in the
same INSERT as the run identity.
-}
claimAndCreateRunWithParentAndProfile
  :: UUID
  -> Text
  -> TriggerSource
  -> Maybe UUID
  -> UTCTime
  -> Int32
  -> RunExecutionProfile
  -> Transaction (Maybe UUID)
claimAndCreateRunWithParentAndProfile tId leaseOwner triggerSource parentRunId now leaseDurationSec profile =
  claimAndCreateManagedRun
    ManagedRunClaimInput
      { mrciTaskId = tId
      , mrciLeaseOwner = leaseOwner
      , mrciTriggerSource = triggerSource
      , mrciParentRunId = parentRunId
      , mrciNow = now
      , mrciLeaseDurationSeconds = leaseDurationSec
      , mrciExecutionProfile = Just profile
      }

claimAndCreateManagedRun :: ManagedRunClaimInput -> Transaction (Maybe UUID)
claimAndCreateManagedRun input =
  Tx.statement input $
    Statement
      "WITH inserted AS ( \
      \  INSERT INTO pulse.runs \
      \    (task_id, status, trigger_source, started_at, lease_owner, lease_expires_at, user_id, parent_run_id, execution_backend, program_identity, artifact_digest, protocol_version, created_at) \
      \  SELECT \
      \    $1, 'running'::pulse.run_status, $3::pulse.trigger_source, $5, $2, $5 + make_interval(secs => $6::double precision), \
      \    COALESCE( \
      \      NULLIF(td.config #>> '{cortexTaskConfig,drwUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,sdcUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,lsdcUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,ppcUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,lppcUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,rerEvalUserId}', '')::uuid, \
      \      NULLIF(td.config #>> '{cortexTaskConfig,rawEvalUserId}', '')::uuid \
      \    ), \
      \    $4, $7, $8, $9, $10, $5 \
      \  FROM pulse.task_definitions td \
      \  WHERE task_id = $1 \
      \    AND next_run_at IS NOT NULL \
      \    AND scheduler_claimed = false \
      \  ON CONFLICT DO NOTHING \
      \  RETURNING run_id \
      \), claimed AS ( \
      \  UPDATE pulse.task_definitions SET \
      \    scheduler_claimed = true, \
      \    updated_at = $5 \
      \  WHERE task_id = $1 \
      \    AND EXISTS (SELECT 1 FROM inserted) \
      \  RETURNING task_id \
      \) \
      \SELECT run_id FROM inserted \
      \WHERE EXISTS (SELECT 1 FROM claimed)"
      ( Enc.encodeParams $
          Enc.col (.mrciTaskId) (Enc.nonNullable Enc.uuid)
            :| [ Enc.col (.mrciLeaseOwner) (Enc.nonNullable Enc.text)
               , Enc.col (triggerSourceToText . (.mrciTriggerSource)) (Enc.nonNullable Enc.text)
               , Enc.col (.mrciParentRunId) (Enc.nullable Enc.uuid)
               , Enc.col (.mrciNow) (Enc.nonNullable Enc.timestamptz)
               , Enc.col (.mrciLeaseDurationSeconds) (Enc.nonNullable Enc.int4)
               , Enc.col
                   (fmap (.repExecutionBackend) . (.mrciExecutionProfile))
                   (Enc.nullable Enc.text)
               , Enc.col
                   (fmap (.repProgramIdentity) . (.mrciExecutionProfile))
                   (Enc.nullable Enc.text)
               , Enc.col
                   (\claim -> claim.mrciExecutionProfile >>= (.repArtifactDigest))
                   (Enc.nullable Enc.text)
               , Enc.col
                   (\claim -> claim.mrciExecutionProfile >>= (.repProtocolVersion))
                   (Enc.nullable Enc.text)
               ]
      )
      (D.rowMaybe (D.column (D.nonNullable D.uuid)))
      False

freezeRunExecutionProfile
  :: UUID -> RunExecutionProfile -> Transaction RunExecutionProfileFreezeResult
freezeRunExecutionProfile runId expected = do
  actual <-
    Tx.statement (runId, expected) $
      Statement
        "WITH target AS ( \
        \  SELECT run_id, execution_backend, program_identity, artifact_digest, protocol_version \
        \  FROM pulse.runs WHERE run_id = $1 FOR UPDATE \
        \), frozen AS ( \
        \  UPDATE pulse.runs r SET \
        \    execution_backend = $2, program_identity = $3, artifact_digest = $4, protocol_version = $5 \
        \  FROM target t \
        \  WHERE r.run_id = t.run_id \
        \    AND t.execution_backend IS NULL AND t.program_identity IS NULL \
        \    AND t.artifact_digest IS NULL AND t.protocol_version IS NULL \
        \  RETURNING r.execution_backend, r.program_identity, r.artifact_digest, r.protocol_version \
        \) \
        \SELECT execution_backend, program_identity, artifact_digest, protocol_version FROM frozen \
        \UNION ALL \
        \SELECT execution_backend, program_identity, artifact_digest, protocol_version FROM target \
        \WHERE NOT EXISTS (SELECT 1 FROM frozen)"
        ( Enc.encode5
            (fst, Enc.nonNullable Enc.uuid)
            ((\(_, b) -> b.repExecutionBackend), Enc.nonNullable Enc.text)
            ((\(_, b) -> b.repProgramIdentity), Enc.nonNullable Enc.text)
            ((\(_, b) -> b.repArtifactDigest), Enc.nullable Enc.text)
            ((\(_, b) -> b.repProtocolVersion), Enc.nullable Enc.text)
        )
        (D.rowMaybe runExecutionProfileDecoder)
        False
  pure $ case actual of
    Nothing -> RunExecutionProfileRunMissing
    Just profile
      | profile == expected -> RunExecutionProfileFrozen
      | otherwise -> RunExecutionProfileMismatch profile

readRunExecutionProfile :: UUID -> Session (Maybe RunExecutionProfile)
readRunExecutionProfile runId =
  Session.statement runId $
    Statement
      "SELECT execution_backend, program_identity, artifact_digest, protocol_version \
      \FROM pulse.runs WHERE run_id = $1 AND execution_backend IS NOT NULL"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe runExecutionProfileDecoder)
      True

runExecutionProfileDecoder :: D.Row RunExecutionProfile
runExecutionProfileDecoder =
  RunExecutionProfile
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)

{- | Claim the next pending run, with scheduling controls:

* @excludedTypes@: types at their per-type concurrency limit (skipped)
* @deprioritized@: types already claimed this fill cycle (ordered last for round-robin)
* Priority: higher-priority tasks' runs are claimed first
Note: no cooldown filter here — pending runs are operator-triggered
(manual/retry) and should always execute immediately.
-}
claimNextPendingRun
  :: Text -> UTCTime -> Int32 -> [Text] -> [Text] -> Transaction (Maybe PulsePendingRunClaim)
claimNextPendingRun leaseOwner now leaseDurationSec excludedTypes deprioritized =
  Tx.statement (leaseOwner, now, leaseDurationSec, excludedTypes, deprioritized) $
    Statement
      -- The claim_event CTE reads the pre-update row (next_run), which is
      -- the only place a requeued run is distinguishable from a first claim:
      -- the claim itself overwrites started_at, and created_at is not the
      -- time a woken run became pending again. First claims record exact
      -- queue_seconds from created_at; requeued claims record requeued=true
      -- and omit queue_seconds until a pending_since column exists (#259).
      "WITH next_run AS ( \
      \  SELECT r.run_id, r.created_at, r.started_at \
      \  FROM pulse.runs r \
      \  INNER JOIN pulse.task_definitions td ON r.task_id = td.task_id \
      \  WHERE r.status = 'pending'::pulse.run_status \
      \    AND (CARDINALITY($4::text[]) = 0 OR td.task_type <> ALL($4::text[])) \
      \  ORDER BY \
      \    td.priority DESC, \
      \    CASE WHEN CARDINALITY($5::text[]) > 0 AND td.task_type = ANY($5::text[]) THEN 1 ELSE 0 END ASC, \
      \    r.created_at ASC \
      \  FOR UPDATE OF r SKIP LOCKED \
      \  LIMIT 1 \
      \), claimed AS ( \
      \  UPDATE pulse.runs r SET \
      \    status = 'running'::pulse.run_status, \
      \    started_at = $2, \
      \    lease_owner = $1, \
      \    lease_expires_at = $2 + make_interval(secs => $3::double precision) \
      \  FROM next_run nr \
      \  WHERE r.run_id = nr.run_id \
      \    AND r.status = 'pending'::pulse.run_status \
      \  RETURNING r.run_id, r.trigger_source \
      \), claim_event AS ( \
      \  INSERT INTO pulse.run_events (run_id, event_type, severity, message, details, created_at) \
      \  SELECT c.run_id, 'run.claimed', 'info', 'Run claimed by scheduler', \
      \    CASE WHEN nr.started_at IS NULL \
      \      THEN jsonb_build_object('queue_seconds', EXTRACT(EPOCH FROM ($2 - nr.created_at)), 'requeued', false) \
      \      ELSE jsonb_build_object('requeued', true) \
      \    END, $2 \
      \  FROM claimed c INNER JOIN next_run nr ON nr.run_id = c.run_id \
      \) \
      \SELECT run_id, trigger_source FROM claimed"
      ( Enc.encode5
          ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.text)
          ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.int4)
          ((\(_, _, _, d, _) -> d), Enc.nonNullable (Enc.foldableArray (Enc.nonNullable Enc.text)))
          ((\(_, _, _, _, e) -> e), Enc.nonNullable (Enc.foldableArray (Enc.nonNullable Enc.text)))
      )
      ( D.rowMaybe $
          PulsePendingRunClaim
            <$> D.column (D.nonNullable D.uuid) -- run_id
            <*> D.column (D.nonNullable D.text) -- trigger_source
      )
      False

{- | Claim an existing managed run before resuming it.

The managed facade is used by scheduler-less consumers, so resume must perform the
same ownership transition that the scheduler claim path provides. A run is claimed
only when it is pending, or when it is running with an expired lease. Terminal and
waiting runs are reported to the caller without changing ownership; a live running
run returns @mrcClaimed = False@ so the facade can reject split-brain execution.
-}
claimManagedRunForResume
  :: UUID -> Text -> UTCTime -> Int32 -> Transaction (Maybe ManagedResumeClaim)
claimManagedRunForResume runId leaseOwner now leaseDurationSec =
  Tx.statement (runId, leaseOwner, now, leaseDurationSec) $
    Statement
      "WITH target AS ( \
      \  SELECT run_id, status, lease_expires_at \
      \  FROM pulse.runs \
      \  WHERE run_id = $1 \
      \  FOR UPDATE \
      \), claimable AS ( \
      \  SELECT run_id \
      \  FROM target \
      \  WHERE status = 'pending'::pulse.run_status \
      \     OR ( \
      \       status = 'running'::pulse.run_status \
      \       AND lease_expires_at IS NOT NULL \
      \       AND lease_expires_at < $3 \
      \     ) \
      \), claimed AS ( \
      \  UPDATE pulse.runs r SET \
      \    status = 'running'::pulse.run_status, \
      \    started_at = COALESCE(r.started_at, $3), \
      \    lease_owner = $2, \
      \    lease_expires_at = $3 + make_interval(secs => $4::double precision) \
      \  FROM claimable c \
      \  WHERE r.run_id = c.run_id \
      \  RETURNING r.run_id \
      \) \
      \SELECT target.status, EXISTS (SELECT 1 FROM claimed) \
      \FROM target"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.int4)
      )
      ( D.rowMaybe $
          ManagedResumeClaim
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.bool)
      )
      False

{- | Hand back a resume claim this owner took but will not act on: expire the
lease immediately so another backend can claim the run without waiting out the
full lease duration. Scoped to the owner and the running status so a claim
that already moved on is untouched.
-}
expireManagedRunLease :: UUID -> Text -> UTCTime -> Transaction ()
expireManagedRunLease runId leaseOwner now =
  Tx.statement (runId, leaseOwner, now) $
    Statement
      "UPDATE pulse.runs \
      \SET lease_expires_at = $3 \
      \WHERE run_id = $1 \
      \  AND lease_owner = $2 \
      \  AND status = 'running'::pulse.run_status"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

createPendingRun
  :: UUID -> TriggerSource -> Maybe UUID -> Maybe UUID -> UTCTime -> Transaction (Maybe UUID)
createPendingRun taskId triggerSource parentRunId maybeUserId now =
  Tx.statement (taskId, triggerSource, parentRunId, maybeUserId, now) $
    Statement
      "INSERT INTO pulse.runs \
      \(task_id, status, trigger_source, parent_run_id, user_id, created_at) \
      \VALUES ($1, 'pending'::pulse.run_status, $2::pulse.trigger_source, $3, $4, $5) \
      \ON CONFLICT DO NOTHING \
      \RETURNING run_id"
      ( Enc.encode5
          ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _) -> triggerSourceToText b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _) -> c), Enc.nullable Enc.uuid)
          ((\(_, _, _, d, _) -> d), Enc.nullable Enc.uuid)
          ((\(_, _, _, _, e) -> e), Enc.nonNullable Enc.timestamptz)
      )
      (D.rowMaybe (D.column (D.nonNullable D.uuid)))
      False

getRunStatusForUpdate :: UUID -> Transaction (Maybe Text)
getRunStatusForUpdate runId =
  Tx.statement runId $
    Statement
      "SELECT status \
      \FROM pulse.runs \
      \WHERE run_id = $1 \
      \FOR UPDATE"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe (D.column (D.nonNullable D.text)))
      False

-- Note: run status updates use raw SQL to avoid GHC 9.10 ambiguous record
-- field issues (PulseRunRow and PulseStageLogRow share field names).

{- | The run-status values that end a run and trigger run-terminal signal
delivery. This is the single source of truth for "terminal": the terminal
status writers and the registration-time resolution set both derive their
status strings from here, so the two cannot drift (a drift between them is
exactly how a wait registered after a timeout previously parked forever).
-}
data TerminalRunStatus
  = RunCompleted
  | RunFailed
  | RunCancelled
  | RunTimedOut
  deriving stock (Eq, Show)

{- | All terminal statuses; the closed set delivery and resolution agree on.
Exhaustive by construction: every constructor must appear here, so adding a
terminal status is a single edit that both delivery and resolution inherit.
-}
allTerminalStatuses :: [TerminalRunStatus]
allTerminalStatuses = [RunCompleted, RunFailed, RunCancelled, RunTimedOut]

-- | The wire/SQL string for a terminal status (the @pulse.run_status@ value).
terminalStatusText :: TerminalRunStatus -> Text
terminalStatusText status = case status of
  RunCompleted -> "completed"
  RunFailed -> "failed"
  RunCancelled -> "cancelled"
  RunTimedOut -> "timeout"

-- | Parse a run-status string into a terminal status, if it is one.
parseTerminalStatus :: Text -> Maybe TerminalRunStatus
parseTerminalStatus t = find (\s -> terminalStatusText s == t) allTerminalStatuses

-- | Whether a run-status string is terminal (drives registration-time resolution).
isTerminalStatus :: Text -> Bool
isTerminalStatus = isJust . parseTerminalStatus

{- | Every terminal status writer delivers the run-terminal signal inside the
same transaction, so the terminal status and its waiters' wake-ups commit
together regardless of which code path wrote the status — executor
settlement, failure persistence, scheduler discard, timeout, cancellation,
and expired-lease recovery all funnel through these writers.
-}
deliverTerminalFor :: UUID -> TerminalRunStatus -> UTCTime -> Transaction ()
deliverTerminalFor rId status now = do
  _wokenRunIds <- deliverRunTerminalSignals rId status now
  pure ()

{- | Serialize the reserved run-terminal protocol inside the current
transaction.

Run-terminal settlement deliberately share-locks the awaited run row so a
terminal writer cannot pass between "observed as non-terminal" and "pending
wait row committed". Terminal writers also update their own run row and then
wake other runs. Mutual awaits therefore form cross-run row-lock cycles unless
all run-terminal wait planning and terminal delivery enter one common critical
section before touching run rows. The advisory lock is transaction-scoped, so
commit/rollback releases it with the same atomicity as the signal rows.
-}
lockRunTerminalProtocolTx :: Transaction ()
lockRunTerminalProtocolTx = do
  _ <-
    Tx.statement runTerminalProtocolLockKey $
      Statement
        "WITH locked AS (SELECT pg_advisory_xact_lock($1)) SELECT 1::int4 FROM locked"
        (E.param (E.nonNullable E.int8))
        (D.singleRow (D.column (D.nonNullable D.int4)))
        False
  pure ()

runTerminalProtocolLockKey :: Int64
runTerminalProtocolLockKey = 5600058

{- | Per-run advisory lock for the external-call wake protocol (ADR 0058/0059).
Unlike run-terminal -- where run A may wait on run B and vice versa, forming cross-run
cycles that require one global lock -- an external-call wake only ever wakes its own
run, so it serializes per run: 'deliverExternalCallSignal' and the external-call
branch of 'planSignalWaitSettlement' take this lock so a completion arriving between
the park's delivered-row check and its commit is not lost, without contending across
unrelated runs or against run-terminal delivery. The two-int advisory-lock space is
disjoint from the single-bigint run-terminal lock, and per-run keys partition it, so
the run-terminal lock is the only one ever shared across runs -- no deadlock cycle
can form.
-}
lockExternalCallProtocolTx :: UUID -> Transaction ()
lockExternalCallProtocolTx runId = do
  _ <-
    Tx.statement (externalCallProtocolLockClass, runAdvisoryLockKey runId) $
      Statement
        "WITH locked AS (SELECT pg_advisory_xact_lock($1, $2)) SELECT 1::int4 FROM locked"
        ( Enc.encode2
            (fst, Enc.nonNullable Enc.int4)
            (snd, Enc.nonNullable Enc.int4)
        )
        (D.singleRow (D.column (D.nonNullable D.int4)))
        False
  pure ()

-- | Advisory-lock class (the first int4 key) for the per-run external-call protocol.
externalCallProtocolLockClass :: Int32
externalCallProtocolLockClass = 5600059

{- | Fold a run id into an int4 advisory-lock key. A collision only makes two runs
share the external-call lock (extra serialization, never incorrect).
-}
runAdvisoryLockKey :: UUID -> Int32
runAdvisoryLockKey runId =
  let (w0, w1, w2, w3) = toWords runId
   in fromIntegral (w0 `xor` w1 `xor` w2 `xor` w3)

-- | Mark a run as started.
updateRunStarted :: UUID -> UTCTime -> Transaction ()
updateRunStarted rId now =
  Tx.statement (rId, now) $
    Statement
      "UPDATE pulse.runs SET status = 'running'::pulse.run_status, started_at = $2 WHERE run_id = $1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

-- | Mark a run as completed and wake its run-terminal waiters.
updateRunCompleted :: UUID -> UTCTime -> Transaction ()
updateRunCompleted rId now = do
  lockRunTerminalProtocolTx
  changed <-
    Tx.statement (rId, now) $
      Statement
        "WITH updated AS ( \
        \  UPDATE pulse.runs \
        \  SET status = 'completed'::pulse.run_status, completed_at = $2 \
        \  WHERE run_id = $1 \
        \    AND status NOT IN ('completed'::pulse.run_status, 'failed'::pulse.run_status, 'cancelled'::pulse.run_status, 'timeout'::pulse.run_status) \
        \  RETURNING run_id \
        \) SELECT EXISTS (SELECT 1 FROM updated)"
        (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
        (D.singleRow (D.column (D.nonNullable D.bool)))
        False
  when changed (deliverTerminalFor rId RunCompleted now)

-- | Mark a run as failed with error details and wake its run-terminal waiters.
updateRunFailed :: RunFailureUpdate -> Transaction ()
updateRunFailed input = do
  lockRunTerminalProtocolTx
  changed <-
    Tx.statement input $
      Statement
        "WITH updated AS ( \
        \  UPDATE pulse.runs \
        \  SET status = 'failed'::pulse.run_status, completed_at = $2, \
        \      error_type = $3, error_message = $4, error_retryable = $5 \
        \  WHERE run_id = $1 \
        \    AND status NOT IN ('completed'::pulse.run_status, 'failed'::pulse.run_status, 'cancelled'::pulse.run_status, 'timeout'::pulse.run_status) \
        \  RETURNING run_id \
        \) SELECT EXISTS (SELECT 1 FROM updated)"
        ( Enc.encodeParams
            ( Enc.col (.rfuRunId) (Enc.nonNullable Enc.uuid)
                :| [ Enc.col (.rfuCompletedAt) (Enc.nonNullable Enc.timestamptz)
                   , Enc.col (.rfuErrType) (Enc.nonNullable Enc.text)
                   , Enc.col (.rfuErrMsg) (Enc.nonNullable Enc.text)
                   , Enc.col (.rfuRetryable) (Enc.nonNullable Enc.bool)
                   ]
            )
        )
        (D.singleRow (D.column (D.nonNullable D.bool)))
        False
  when changed (deliverTerminalFor input.rfuRunId RunFailed input.rfuCompletedAt)

{- | Mark a run as cancelled. Preserves the operator-provided cancel_reason
from requestCancellation; only sets it if not already present. Wakes the
run's run-terminal waiters.
-}
updateRunCancelled :: UUID -> UTCTime -> Text -> Transaction ()
updateRunCancelled rId now reason = do
  lockRunTerminalProtocolTx
  changed <-
    Tx.statement (rId, now, reason) $
      Statement
        "WITH updated AS ( \
        \  UPDATE pulse.runs \
        \  SET status = 'cancelled'::pulse.run_status, completed_at = $2, \
        \      cancel_reason = COALESCE(cancel_reason, $3) \
        \  WHERE run_id = $1 \
        \    AND status NOT IN ('completed'::pulse.run_status, 'failed'::pulse.run_status, 'cancelled'::pulse.run_status, 'timeout'::pulse.run_status) \
        \  RETURNING run_id \
        \) SELECT EXISTS (SELECT 1 FROM updated)"
        ( Enc.encode3
            ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
            ((\(_, b, _) -> b), Enc.nonNullable Enc.timestamptz)
            ((\(_, _, c) -> c), Enc.nonNullable Enc.text)
        )
        (D.singleRow (D.column (D.nonNullable D.bool)))
        False
  when changed (deliverTerminalFor rId RunCancelled now)

{- | Mark a run as timed out and wake its run-terminal waiters. A retry, if
any, is a fresh run under a new run id (parent_run_id lineage), so timeout is
terminal for this run id.
-}
updateRunTimedOut :: RunTimeoutUpdate -> Transaction ()
updateRunTimedOut input = do
  lockRunTerminalProtocolTx
  changed <-
    Tx.statement input $
      Statement
        "WITH updated AS ( \
        \  UPDATE pulse.runs \
        \  SET status = 'timeout'::pulse.run_status, completed_at = $2, \
        \      error_type = $3, error_message = $4, error_retryable = false \
        \  WHERE run_id = $1 \
        \    AND status NOT IN ('completed'::pulse.run_status, 'failed'::pulse.run_status, 'cancelled'::pulse.run_status, 'timeout'::pulse.run_status) \
        \  RETURNING run_id \
        \) SELECT EXISTS (SELECT 1 FROM updated)"
        ( Enc.encodeParams
            ( Enc.col (.rtuRunId) (Enc.nonNullable Enc.uuid)
                :| [ Enc.col (.rtuCompletedAt) (Enc.nonNullable Enc.timestamptz)
                   , Enc.col (.rtuErrType) (Enc.nonNullable Enc.text)
                   , Enc.col (.rtuErrMsg) (Enc.nonNullable Enc.text)
                   ]
            )
        )
        (D.singleRow (D.column (D.nonNullable D.bool)))
        False
  when changed (deliverTerminalFor input.rtuRunId RunTimedOut input.rtuCompletedAt)

getRunStartedAt :: UUID -> Session (Maybe UTCTime)
getRunStartedAt rId =
  Session.statement rId $
    Statement
      "SELECT started_at FROM pulse.runs WHERE run_id = $1 AND started_at IS NOT NULL"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe (D.column (D.nonNullable D.timestamptz)))
      False

-- ============================================================================
-- Checkpoint
-- ============================================================================

-- | Write or update the latest checkpoint for a run.
writeCheckpoint :: UUID -> Text -> Text -> Value -> Maybe Value -> UTCTime -> Transaction ()
writeCheckpoint rId taskType cpName cpState cpSummary now =
  Tx.statement (rId, taskType, cpName, cpState, cpSummary, now) $
    Statement
      "INSERT INTO pulse.checkpoints (run_id, task_type, checkpoint_name, state, summary, updated_at) \
      \VALUES ($1, $2, $3, $4, $5, $6) \
      \ON CONFLICT (run_id) DO UPDATE SET \
      \  checkpoint_name = EXCLUDED.checkpoint_name, \
      \  state = EXCLUDED.state, \
      \  summary = EXCLUDED.summary, \
      \  updated_at = EXCLUDED.updated_at"
      ( Enc.encode6
          ((\(a, _, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d, _, _) -> d), Enc.nonNullable Enc.jsonb)
          ((\(_, _, _, _, e, _) -> e), Enc.nullable Enc.jsonb)
          ((\(_, _, _, _, _, f) -> f), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

{- | Read the latest inner checkpoint payload for a run, stripping the envelope.
Returns the @cePayload@ field from the 'CheckpointEnvelope', or 'Nothing'
if no checkpoint row exists or the envelope cannot be parsed.

This is a compatibility/raw reader: it parses the envelope shape but does not
validate task type, task version, runtime version, or checkpoint name. New
surfaces that need the compatibility contract should use
'readCheckpointPayloadValidated'.
-}
readCheckpointPayload :: UUID -> Session (Maybe Value)
readCheckpointPayload rId = do
  mRaw <-
    Session.statement rId $
      Statement
        "SELECT state FROM pulse.checkpoints WHERE run_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (D.column (D.nonNullable D.jsonb)))
        True
  pure $ do
    raw <- mRaw
    case parseCheckpointEnvelope raw of
      Left _ -> Nothing
      Right env -> Just (cePayload env)

-- | Read and validate the latest checkpoint payload for a run.
readCheckpointPayloadValidated :: CheckpointReadExpectation -> UUID -> Session CheckpointReadResult
readCheckpointPayloadValidated expectation runId = do
  mStored <-
    Session.statement runId $
      Statement
        "SELECT task_type, checkpoint_name, state FROM pulse.checkpoints WHERE run_id = $1"
        (E.param (E.nonNullable E.uuid))
        ( D.rowMaybe $
            StoredCheckpointPayload
              <$> D.column (D.nonNullable D.text)
              <*> D.column (D.nonNullable D.text)
              <*> D.column (D.nonNullable D.jsonb)
        )
        True
  pure $
    case mStored of
      Nothing -> CheckpointMissing
      Just stored ->
        case validateStoredCheckpointPayload expectation stored of
          Left failure -> CheckpointRejected failure
          Right payload -> CheckpointValidated payload

-- ============================================================================
-- Stage Log
-- ============================================================================

findOpenStageLogId :: UUID -> Text -> Transaction (Maybe Int64)
findOpenStageLogId rId stageName =
  Tx.statement (rId, stageName) $
    Statement
      "SELECT id \
      \FROM pulse.stage_log \
      \WHERE run_id = $1 \
      \  AND stage_name = $2 \
      \  AND completed_at IS NULL \
      \ORDER BY started_at DESC, id DESC \
      \LIMIT 1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.text))
      (D.rowMaybe (D.column (D.nonNullable D.int8)))
      True

getNextStageAttemptNumber :: Int64 -> Transaction Int32
getNextStageAttemptNumber stageLogId =
  Tx.statement stageLogId $
    Statement
      "SELECT (COALESCE(MAX(attempt_number), 0) + 1)::int4 \
      \FROM pulse.stage_attempt_log \
      \WHERE stage_log_id = $1"
      (E.param (E.nonNullable E.int8))
      (D.singleRow (D.column (D.nonNullable D.int4)))
      True

-- | Append a stage-started entry. Returns the stage log ID.
appendStageStarted :: UUID -> Text -> UTCTime -> Transaction Int64
appendStageStarted rId stageName now =
  Tx.statement (rId, stageName, now) $
    Statement
      "INSERT INTO pulse.stage_log (run_id, stage_name, status, started_at) \
      \VALUES ($1, $2, 'started'::pulse.stage_status, $3) \
      \RETURNING id"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.timestamptz)
      )
      (D.singleRow (D.column (D.nonNullable D.int8)))
      False

appendStageAttemptStarted :: Int64 -> UUID -> Int32 -> UTCTime -> Transaction Int64
appendStageAttemptStarted stageLogId rId attemptNumber now =
  Tx.statement (stageLogId, rId, attemptNumber, now) $
    Statement
      "INSERT INTO pulse.stage_attempt_log (stage_log_id, run_id, attempt_number, status, started_at) \
      \VALUES ($1, $2, $3, 'started'::pulse.stage_status, $4) \
      \RETURNING attempt_id"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.int8)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.uuid)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.int4)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.timestamptz)
      )
      (D.singleRow (D.column (D.nonNullable D.int8)))
      False

-- | Update a stage log entry as completed/failed/skipped.
updateStageCompleted :: Int64 -> StageStatus -> Maybe Value -> UTCTime -> Transaction ()
updateStageCompleted logId newStatus summary now =
  Tx.statement (logId, newStatus, summary, now) $
    Statement
      "UPDATE pulse.stage_log SET status = $2::pulse.stage_status, state_summary = $3, completed_at = $4 \
      \WHERE id = $1"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.int8)
          ((\(_, b, _, _) -> stageStatusToText b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nullable Enc.jsonb)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

updateStageAttemptCompleted :: Int64 -> StageStatus -> Maybe Value -> UTCTime -> Transaction ()
updateStageAttemptCompleted attemptId newStatus summary now =
  Tx.statement (attemptId, newStatus, summary, now) $
    Statement
      "UPDATE pulse.stage_attempt_log SET status = $2::pulse.stage_status, summary = $3, completed_at = $4 \
      \WHERE attempt_id = $1"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.int8)
          ((\(_, b, _, _) -> stageStatusToText b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nullable Enc.jsonb)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

-- ============================================================================
-- Scheduling
-- ============================================================================

-- | Advance a task's next_run_at and record last run status.
advanceTaskSchedule :: UUID -> UTCTime -> UTCTime -> RunStatus -> Transaction ()
advanceTaskSchedule tId nextTime now runStatus =
  Tx.statement (tId, nextTime, now, now, runStatus) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \scheduler_claimed = false, next_run_at = $2, last_run_at = $3, last_run_status = $5::pulse.run_status, updated_at = $4 \
      \WHERE task_id = $1"
      ( Enc.encode5
          ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, d, _) -> d), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, _, e) -> runStatusToText e), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

-- | Mark a one-off task as disabled after completion.
completeOneOffTask :: UUID -> UTCTime -> Transaction ()
completeOneOffTask tId now =
  Tx.statement (tId, now) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \enabled = false, scheduler_claimed = false, next_run_at = NULL, last_run_at = $2, \
      \last_run_status = 'completed'::pulse.run_status, updated_at = $2 \
      \WHERE task_id = $1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

restoreOneOffTaskAt :: UUID -> UTCTime -> UTCTime -> RunStatus -> Transaction ()
restoreOneOffTaskAt tId nextRunAt now runStatus =
  Tx.statement (tId, nextRunAt, now, runStatus) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \enabled = true, scheduler_claimed = false, next_run_at = $2, \
      \last_run_at = $3, last_run_status = $4::pulse.run_status, updated_at = $3 \
      \WHERE task_id = $1"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, d) -> runStatusToText d), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

updateTaskLastRun :: UUID -> UTCTime -> RunStatus -> Transaction ()
updateTaskLastRun tId now runStatus =
  Tx.statement (tId, now, runStatus) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \scheduler_claimed = false, last_run_at = $2, last_run_status = $3::pulse.run_status, updated_at = $2 \
      \WHERE task_id = $1"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c) -> runStatusToText c), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

{- | Record last-run outcome only, without clearing scheduler_claimed.
Used for manual/retry executions of recurring tasks (RecordOutcomeOnly).
-}
updateTaskLastRunOnly :: UUID -> UTCTime -> RunStatus -> Transaction ()
updateTaskLastRunOnly tId now runStatus =
  Tx.statement (tId, now, runStatus) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \last_run_at = $2, last_run_status = $3::pulse.run_status, updated_at = $2 \
      \WHERE task_id = $1"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c) -> runStatusToText c), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

{- | Restore a task's next_run_at by looking up the task_id from a failed run.
Used when startup recovery fails to load the task definition (transient error).
-}
restoreTaskForFailedRun :: UUID -> UTCTime -> UTCTime -> Session ()
restoreTaskForFailedRun rId nextTime now =
  Session.statement (rId, nextTime, now) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \  scheduler_claimed = false, next_run_at = $2, updated_at = $3 \
      \WHERE task_id = (SELECT task_id FROM pulse.runs WHERE run_id = $1) \
      \  AND enabled = true \
      \  AND scheduler_claimed = true"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

-- | Restore a task's next_run_at (e.g., after cron parse failure or recovery).
restoreTaskSchedule :: UUID -> UTCTime -> UTCTime -> Transaction ()
restoreTaskSchedule tId nextTime now =
  Tx.statement () . run_ . update $
    Update
      { target = pulseTaskDefinitionSchema
      , from = pure ()
      , set = \_ task ->
          task
            { schedulerClaimed = lit False
            , nextRunAt = lit (Just nextTime)
            , updatedAt = lit now
            }
      , updateWhere = \_ task -> task.taskId ==. lit tId
      , returning = NoReturning
      }

-- ============================================================================
-- Cancellation
-- ============================================================================

-- | Request cancellation of a run (set the cancel flag).
requestCancellation :: UUID -> Text -> UTCTime -> Transaction ()
requestCancellation rId reason now =
  Tx.statement () . run_ . update $
    Update
      { target = pulseRunSchema
      , from = pure ()
      , set = \_ row ->
          row
            { cancelRequestedAt = lit (Just now)
            , cancelReason = lit (Just reason)
            }
      , updateWhere = \_ row -> row.runId ==. lit rId
      , returning = NoReturning
      }

-- | Check if a run has been cancelled. Returns False if the run does not exist.
checkCancellation :: UUID -> Session Bool
checkCancellation rId = do
  result <-
    Session.statement rId $
      Statement
        "SELECT cancel_requested_at IS NOT NULL FROM pulse.runs WHERE run_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (D.column (D.nonNullable D.bool)))
        True
  pure (result == Just True)

{- | Disable the parent task of a run and clear any scheduled visibility.
Used for one-shot workflow tasks that should never be re-enqueued after
operator cancellation or force termination.
-}
disableTaskByRunId :: UUID -> UTCTime -> Transaction ()
disableTaskByRunId rId now =
  Tx.statement (rId, now) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \  enabled = false, scheduler_claimed = false, next_run_at = NULL, updated_at = $2 \
      \WHERE task_id = (SELECT task_id FROM pulse.runs WHERE run_id = $1)"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

{- | Release scheduler_claimed on the parent task of a run.
Used when a run is terminated outside the normal scheduler finalization path
(e.g., admin cancels a pending run directly).
-}
releaseSchedulerClaimByRunId :: UUID -> UTCTime -> Transaction ()
releaseSchedulerClaimByRunId rId now =
  Tx.statement (rId, now) $
    Statement
      "UPDATE pulse.task_definitions SET \
      \  scheduler_claimed = false, updated_at = $2 \
      \WHERE task_id = (SELECT task_id FROM pulse.runs WHERE run_id = $1) \
      \  AND scheduler_claimed = true"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.timestamptz))
      D.noResult
      False

-- ============================================================================
-- Lease Management
-- ============================================================================

{- | Renew lease for a specific run and owner.
Used by withLeaseRenewal during task execution. The owner predicate is part of the
fencing contract: once another process claims the run, stale workers can no longer
renew it.
-}
renewRunLease :: UUID -> Text -> UTCTime -> Int32 -> Session Bool
renewRunLease rId leaseOwner now leaseDurationSec =
  Session.statement (rId, leaseOwner, now, leaseDurationSec) $
    Statement
      "WITH renewed AS ( \
      \  UPDATE pulse.runs SET \
      \    lease_expires_at = $3 + make_interval(secs => $4::double precision) \
      \  WHERE run_id = $1 \
      \    AND status = 'running'::pulse.run_status \
      \    AND lease_owner = $2 \
      \  RETURNING run_id \
      \) SELECT EXISTS (SELECT 1 FROM renewed)"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.int4)
      )
      (D.singleRow (D.column (D.nonNullable D.bool)))
      False

-- ============================================================================
-- Recovery
-- ============================================================================

{- | Reclaim runs owned by this Pulse instance from a previous incarnation.
Refreshes the lease so the executor can resume from the existing checkpoint.
Returns the run IDs that were reclaimed.
-}
reclaimOwnedRuns :: Text -> UTCTime -> Int32 -> Session [UUID]
reclaimOwnedRuns leaseOwner now leaseDurationSec =
  Session.statement (leaseOwner, now, leaseDurationSec) $
    Statement
      "UPDATE pulse.runs SET \
      \  lease_expires_at = $2 + make_interval(secs => $3::double precision) \
      \WHERE status = 'running'::pulse.run_status \
      \  AND lease_owner = $1 \
      \RETURNING run_id"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.text)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.int4)
      )
      (D.rowList (D.column (D.nonNullable D.uuid)))
      False

{- | Recover runs with expired leases from OTHER owners. These are genuinely
abandoned (the owning process died and didn't come back). Marks them failed
and returns enough task context for the caller to apply normal schedule
finalization semantics in the same transaction.
-}
recoverExpiredRuns :: Text -> UTCTime -> Transaction [PulseExpiredRunRecovery]
recoverExpiredRuns currentLeaseOwner now = do
  -- Recovery is also a terminal-status writer. It must enter the
  -- run-terminal protocol before the bulk status UPDATE owns any run rows;
  -- otherwise a recovered run waiting on another concurrently terminalizing
  -- run can recreate the mutual row-lock cycle closed for the ordinary
  -- terminal writers above.
  lockRunTerminalProtocolTx
  recoveredRuns <- recoverExpiredRunsStatement currentLeaseOwner now
  -- Expired-lease recovery marks runs failed outside the regular status
  -- writers; their run-terminal waiters wake in the same transaction.
  traverse_ (\recovered -> deliverTerminalFor recovered.perrRunId RunFailed now) recoveredRuns
  pure recoveredRuns

recoverExpiredRunsStatement :: Text -> UTCTime -> Transaction [PulseExpiredRunRecovery]
recoverExpiredRunsStatement currentLeaseOwner now =
  Tx.statement (now, currentLeaseOwner) $
    Statement
      "WITH recovered AS ( \
      \  UPDATE pulse.runs SET \
      \    status = 'failed'::pulse.run_status, \
      \    completed_at = $1, \
      \    error_type = 'stale_run_recovery', \
      \    error_message = 'stale_run_recovery: lease expired, owning process did not recover', \
      \    error_retryable = true \
      \  WHERE status = 'running'::pulse.run_status \
      \    AND lease_expires_at IS NOT NULL \
      \    AND lease_expires_at < $1 \
      \    AND lease_owner IS DISTINCT FROM $2 \
      \  RETURNING run_id, task_id, trigger_source \
      \) \
      \SELECT \
      \  r.run_id, \
      \  r.task_id, \
      \  r.trigger_source, \
      \  td.task_name, \
      \  td.cron_expression \
      \FROM recovered r \
      \LEFT JOIN pulse.task_definitions td ON td.task_id = r.task_id \
      \ORDER BY r.run_id"
      (Enc.encode2 (fst, Enc.nonNullable Enc.timestamptz) (snd, Enc.nonNullable Enc.text))
      ( D.rowList $
          PulseExpiredRunRecovery
            <$> D.column (D.nonNullable D.uuid) -- r.run_id
            <*> D.column (D.nonNullable D.uuid) -- r.task_id
            <*> D.column (D.nonNullable D.text) -- r.trigger_source
            <*> D.column (D.nullable D.text) -- td.task_name
            <*> D.column (D.nullable D.text) -- td.cron_expression
      )
      False

-- ============================================================================
-- Admin views and writes
-- ============================================================================

createTaskDefinition :: PulseTaskDefinitionInsert -> Transaction (Maybe UUID)
createTaskDefinition taskDef =
  Tx.statement taskDef $
    Statement
      "INSERT INTO pulse.task_definitions \
      \(task_type, task_name, config, cron_expression, enabled, next_run_at, timeout_seconds, priority, min_interval_seconds, created_at, updated_at) \
      \VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10) \
      \ON CONFLICT DO NOTHING \
      \RETURNING task_id"
      ( Enc.encodeParams $
          Enc.col (.ptdiTaskType) (Enc.nonNullable Enc.text)
            :| [ Enc.col (.ptdiTaskName) (Enc.nonNullable Enc.text)
               , Enc.col (.ptdiConfig) (Enc.nonNullable Enc.jsonb)
               , Enc.col (.ptdiCronExpression) (Enc.nonNullable Enc.text)
               , Enc.col (.ptdiEnabled) (Enc.nonNullable Enc.bool)
               , Enc.col (.ptdiNextRunAt) (Enc.nullable Enc.timestamptz)
               , Enc.col (.ptdiTimeoutSeconds) (Enc.nonNullable Enc.int4)
               , Enc.col (.ptdiPriority) (Enc.nonNullable Enc.int4)
               , Enc.col (.ptdiMinIntervalSeconds) (Enc.nullable Enc.int4)
               , Enc.col (.ptdiCreatedAt) (Enc.nonNullable Enc.timestamptz)
               ]
      )
      (D.rowMaybe (D.column (D.nonNullable D.uuid)))
      False

getRunAdminView :: UUID -> Session (Maybe PulseRunAdminView)
getRunAdminView runId =
  Session.statement runId $
    Statement
      (runAdminViewSelectSql <> " WHERE r.run_id = $1")
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe pulseRunAdminViewDecoder)
      True

listRunsForTask :: UUID -> Int -> Session [PulseRunAdminView]
listRunsForTask taskId limitValue =
  Session.statement (taskId, fromIntegral (Prelude.max 1 limitValue) :: Int32) $
    Statement
      (runAdminViewSelectSql <> " WHERE r.task_id = $1 ORDER BY r.created_at DESC LIMIT $2")
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.int4))
      (D.rowList pulseRunAdminViewDecoder)
      True

-- | A lightweight view of a run joined with its task, for user-facing endpoints.
data PulseRunUserView = PulseRunUserView
  { pruvRunId :: UUID
  , pruvTaskId :: UUID
  , pruvTaskType :: Text
  , pruvTaskName :: Text
  , pruvStatus :: Text
  , pruvStartedAt :: Maybe UTCTime
  , pruvCompletedAt :: Maybe UTCTime
  , pruvCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

-- | List runs for a specific user, joined with task_definitions.
listRunsForUser :: UUID -> Int -> Session [PulseRunUserView]
listRunsForUser userId limitValue =
  Session.statement (userId, fromIntegral (Prelude.max 1 limitValue) :: Int32) $
    Statement
      "SELECT \
      \r.run_id, \
      \r.task_id, \
      \t.task_type, \
      \t.task_name, \
      \r.status, \
      \r.started_at, \
      \r.completed_at, \
      \r.created_at \
      \FROM pulse.runs r \
      \JOIN pulse.task_definitions t ON r.task_id = t.task_id \
      \WHERE r.user_id = $1 \
      \ORDER BY r.created_at DESC \
      \LIMIT $2"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.int4))
      ( D.rowList $
          PulseRunUserView
            <$> D.column (D.nonNullable D.uuid)
            <*> D.column (D.nonNullable D.uuid)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.timestamptz)
            <*> D.column (D.nullable D.timestamptz)
            <*> D.column (D.nonNullable D.timestamptz)
      )
      True

-- | Read-only status check for a run (no lock). Returns (status, started_at, completed_at).
getRunStatusReadOnly :: UUID -> Session (Maybe (Text, Maybe UTCTime, Maybe UTCTime))
getRunStatusReadOnly runId =
  Session.statement runId $
    Statement
      "SELECT status, started_at, completed_at FROM pulse.runs WHERE run_id = $1"
      (E.param (E.nonNullable E.uuid))
      ( D.rowMaybe $
          (,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.timestamptz)
            <*> D.column (D.nullable D.timestamptz)
      )
      True

{- | Read-only status check for a run scoped to a specific user.
Parameter order matches the SQL bind order: @$1 = run_id@, @$2 = user_id@.
-}
getRunStatusReadOnlyForUser :: UUID -> UUID -> Session (Maybe (Text, Maybe UTCTime, Maybe UTCTime))
getRunStatusReadOnlyForUser runId userId =
  Session.statement (runId, userId) $
    Statement
      "SELECT status, started_at, completed_at FROM pulse.runs WHERE run_id = $1 AND user_id = $2"
      (Enc.encode2 (fst, E.nonNullable E.uuid) (snd, E.nonNullable E.uuid))
      ( D.rowMaybe $
          (,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.timestamptz)
            <*> D.column (D.nullable D.timestamptz)
      )
      True

-- | Get the user_id of a run (for ownership checks).
getRunUserId :: UUID -> Session (Maybe (Maybe UUID))
getRunUserId runId =
  Session.statement runId $
    Statement
      "SELECT user_id FROM pulse.runs WHERE run_id = $1"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe (D.column (D.nullable D.uuid)))
      True

getCheckpointDetail :: UUID -> Session (Maybe PulseCheckpointDetail)
getCheckpointDetail runId =
  Session.statement runId $
    Statement
      "SELECT task_type, checkpoint_name, state, summary, updated_at \
      \FROM pulse.checkpoints \
      \WHERE run_id = $1"
      (E.param (E.nonNullable E.uuid))
      ( D.rowMaybe $
          PulseCheckpointDetail
            <$> D.column (D.nonNullable D.text) -- task_type
            <*> D.column (D.nonNullable D.text) -- checkpoint_name
            <*> D.column (D.nonNullable D.jsonb) -- state
            <*> D.column (D.nullable D.jsonb) -- summary
            <*> D.column (D.nonNullable D.timestamptz) -- updated_at
      )
      True

listStageLogDetails :: UUID -> Session [PulseStageLogDetail]
listStageLogDetails runId =
  Session.statement runId $
    Statement
      "SELECT id, stage_name, status, state_summary, started_at, completed_at \
      \FROM pulse.stage_log \
      \WHERE run_id = $1 \
      \ORDER BY started_at ASC, id ASC"
      (E.param (E.nonNullable E.uuid))
      ( D.rowList $
          PulseStageLogDetail
            <$> D.column (D.nonNullable D.int8) -- id
            <*> D.column (D.nonNullable D.text) -- stage_name
            <*> D.column (D.nonNullable D.text) -- status
            <*> D.column (D.nullable D.jsonb) -- state_summary
            <*> D.column (D.nonNullable D.timestamptz) -- started_at
            <*> D.column (D.nullable D.timestamptz) -- completed_at
      )
      True

listStageAttemptLogDetails :: UUID -> Session [PulseStageAttemptLogDetail]
listStageAttemptLogDetails runId =
  Session.statement runId $
    Statement
      "SELECT attempt_id, stage_log_id, attempt_number, status, summary, started_at, completed_at \
      \FROM pulse.stage_attempt_log \
      \WHERE run_id = $1 \
      \ORDER BY stage_log_id ASC, started_at ASC, attempt_id ASC"
      (E.param (E.nonNullable E.uuid))
      ( D.rowList $
          PulseStageAttemptLogDetail
            <$> D.column (D.nonNullable D.int8) -- attempt_id
            <*> D.column (D.nonNullable D.int8) -- stage_log_id
            <*> D.column (D.nonNullable D.int4) -- attempt_number
            <*> D.column (D.nonNullable D.text) -- status
            <*> D.column (D.nullable D.jsonb) -- summary
            <*> D.column (D.nonNullable D.timestamptz) -- started_at
            <*> D.column (D.nullable D.timestamptz) -- completed_at
      )
      True

-- ============================================================================
-- Listing
-- ============================================================================

-- | List all task definitions.
listTasks :: Session [PulseTaskDefinitionRow Result]
listTasks =
  Session.statement () . run . select . orderBy sortByName $
    each pulseTaskDefinitionSchema
  where
    sortByName = (.taskName) >$< asc

-- | Get the task definition for a given run (join pulse.runs → pulse.task_definitions).
getTaskForRun :: UUID -> Session (Maybe (PulseTaskDefinitionRow Result))
getTaskForRun rId =
  Session.statement () . runMaybe . select . limit 1 $ do
    pulseRun <- each pulseRunSchema
    task <- each pulseTaskDefinitionSchema
    where_
      ( pulseRun.runId ==. lit rId
          &&. pulseRun.taskId ==. task.taskId
      )
    pure task

-- ============================================================================
-- Test support
-- ============================================================================

{- | Insert a task definition and return its ID.
Sets next_run_at = now so claimAndCreateRun's CAS succeeds.
-}
claimTestTaskDef :: Text -> Text -> UTCTime -> Transaction UUID
claimTestTaskDef taskType taskName now =
  Tx.statement (taskType, taskName, now) $
    Statement
      "INSERT INTO pulse.task_definitions \
      \(task_type, task_name, config, enabled, next_run_at, created_at, updated_at) \
      \VALUES ($1, $2, '{}'::jsonb, true, $3, $3, $3) \
      \RETURNING task_id"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.text)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.timestamptz)
      )
      (D.singleRow (D.column (D.nonNullable D.uuid)))
      False

-- | Get a task definition by ID.
getTaskById :: UUID -> Session (Maybe (PulseTaskDefinitionRow Result))
getTaskById tId =
  Session.statement () . runMaybe . select . limit 1 $ do
    task <- each pulseTaskDefinitionSchema
    where_ (task.taskId ==. lit tId)
    pure task

-- | Read the status of a run.
readRunStatus :: UUID -> Session (Maybe Text)
readRunStatus rId =
  Session.statement rId $
    Statement
      "SELECT status FROM pulse.runs WHERE run_id = $1"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe (D.column (D.nonNullable D.text)))
      True

-- | Count stage log entries for a run.
countStageLogEntries :: UUID -> Session Int32
countStageLogEntries rId =
  Session.statement rId $
    Statement
      "SELECT COUNT(*)::int FROM pulse.stage_log WHERE run_id = $1"
      (E.param (E.nonNullable E.uuid))
      (D.singleRow (D.column (D.nonNullable D.int4)))
      True

{- | Read @(stage_name, completed_at)@ pairs for every completed
stage of a run.  Used at resume time to repopulate the
Pulse memory subsystem's per-node completion-time TVar so
temporal scoring survives a worker restart.

Only rows with a non-null @completed_at@ are returned; running /
waiting stages contribute no temporal data.
-}
readNodeCompletionTimes :: UUID -> Session [(Text, UTCTime)]
readNodeCompletionTimes rId =
  Session.statement rId $
    Statement
      "SELECT stage_name, completed_at \
      \FROM pulse.stage_log \
      \WHERE run_id = $1 \
      \  AND completed_at IS NOT NULL \
      \ORDER BY completed_at ASC"
      (E.param (E.nonNullable E.uuid))
      ( D.rowList $
          (,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.timestamptz)
      )
      True

runAdminViewSelectSql :: ByteString
runAdminViewSelectSql =
  "SELECT \
  \r.run_id, \
  \r.task_id, \
  \r.status, \
  \r.trigger_source, \
  \r.started_at, \
  \r.completed_at, \
  \r.lease_owner, \
  \r.lease_expires_at, \
  \r.cancel_requested_at, \
  \r.cancel_reason, \
  \r.error_type, \
  \r.error_message, \
  \r.error_retryable, \
  \r.skip_reason, \
  \r.parent_run_id, \
  \r.execution_backend, \
  \r.program_identity, \
  \r.artifact_digest, \
  \r.protocol_version, \
  \r.created_at, \
  \latest.stage_name, \
  \latest.status, \
  \COALESCE(stage_counts.stage_count, 0)::int \
  \FROM pulse.runs r \
  \LEFT JOIN LATERAL ( \
  \  SELECT stage_name, status \
  \  FROM pulse.stage_log \
  \  WHERE run_id = r.run_id \
  \  ORDER BY started_at DESC, id DESC \
  \  LIMIT 1 \
  \) latest ON TRUE \
  \LEFT JOIN LATERAL ( \
  \  SELECT COUNT(*)::int AS stage_count \
  \  FROM pulse.stage_log \
  \  WHERE run_id = r.run_id \
  \) stage_counts ON TRUE"

pulseRunAdminViewDecoder :: D.Row PulseRunAdminView
pulseRunAdminViewDecoder =
  PulseRunAdminView
    <$> D.column (D.nonNullable D.uuid) -- r.run_id
    <*> D.column (D.nonNullable D.uuid) -- r.task_id
    <*> D.column (D.nonNullable D.text) -- r.status
    <*> D.column (D.nonNullable D.text) -- r.trigger_source
    <*> D.column (D.nullable D.timestamptz) -- r.started_at
    <*> D.column (D.nullable D.timestamptz) -- r.completed_at
    <*> D.column (D.nullable D.text) -- r.lease_owner
    <*> D.column (D.nullable D.timestamptz) -- r.lease_expires_at
    <*> D.column (D.nullable D.timestamptz) -- r.cancel_requested_at
    <*> D.column (D.nullable D.text) -- r.cancel_reason
    <*> D.column (D.nullable D.text) -- r.error_type
    <*> D.column (D.nullable D.text) -- r.error_message
    <*> D.column (D.nullable D.bool) -- r.error_retryable
    <*> D.column (D.nullable D.text) -- r.skip_reason
    <*> D.column (D.nullable D.uuid) -- r.parent_run_id
    <*> D.column (D.nullable D.text) -- r.execution_backend
    <*> D.column (D.nullable D.text) -- r.program_identity
    <*> D.column (D.nullable D.text) -- r.artifact_digest
    <*> D.column (D.nullable D.text) -- r.protocol_version
    <*> D.column (D.nonNullable D.timestamptz) -- r.created_at
    <*> D.column (D.nullable D.text) -- latest.stage_name
    <*> D.column (D.nullable D.text) -- latest.status
    <*> D.column (D.nonNullable D.int4) -- stage_counts.stage_count

-- ============================================================================
-- Run Event History
-- ============================================================================

data PulseRunEvent = PulseRunEvent
  { preEventId :: Int64
  , preEventType :: Text
  , preSeverity :: Text
  , preMessage :: Text
  , preDetails :: Maybe Value
  , preCreatedAt :: UTCTime
  }

-- | Append a lifecycle event to the run's event history (best-effort).
appendRunEvent :: RunEventInsert -> Transaction ()
appendRunEvent input =
  Tx.statement input $
    Statement
      "INSERT INTO pulse.run_events (run_id, event_type, severity, message, details) \
      \VALUES ($1, $2, $3, $4, $5)"
      ( Enc.encodeParams
          ( Enc.col (.reiRunId) (Enc.nonNullable Enc.uuid)
              :| [ Enc.col (.reiEventType) (Enc.nonNullable Enc.text)
                 , Enc.col (renderRunEventSeverity . (.reiSeverity)) (Enc.nonNullable Enc.text)
                 , Enc.col (.reiMessage) (Enc.nonNullable Enc.text)
                 , Enc.col (.reiDetails) (Enc.nullable Enc.jsonb)
                 ]
          )
      )
      D.noResult
      False

{- | Best-effort run event recording.  Performs a synchronous DB transaction
and logs write failures to stderr — the event history is supplementary
and must never block or fail a run.  Callers should be aware this adds
one round-trip of latency per event.
-}
recordRunEvent :: DB.Pool -> RunEventInsert -> IO ()
recordRunEvent pool input = do
  result <- PulseDB.runTransaction pool $ appendRunEvent input
  case result of
    Left err -> System.IO.hPutStrLn System.IO.stderr $ "recordRunEvent: best-effort write failed: " <> err
    Right () -> pure ()

-- | List all events for a run, oldest first.
listRunEvents :: UUID -> Session [PulseRunEvent]
listRunEvents runId =
  Session.statement runId $
    Statement
      "SELECT event_id, event_type, severity, message, details, created_at \
      \FROM pulse.run_events \
      \WHERE run_id = $1 \
      \ORDER BY created_at ASC, event_id ASC"
      (E.param (E.nonNullable E.uuid))
      (D.rowList pulseRunEventDecoder)
      True

getLatestRunEvent :: UUID -> Session (Maybe PulseRunEvent)
getLatestRunEvent runId =
  Session.statement runId $
    Statement
      "SELECT event_id, event_type, severity, message, details, created_at \
      \FROM pulse.run_events \
      \WHERE run_id = $1 \
      \ORDER BY created_at DESC, event_id DESC \
      \LIMIT 1"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe pulseRunEventDecoder)
      True

pulseRunEventDecoder :: D.Row PulseRunEvent
pulseRunEventDecoder =
  PulseRunEvent
    <$> D.column (D.nonNullable D.int8) -- event_id
    <*> D.column (D.nonNullable D.text) -- event_type
    <*> D.column (D.nonNullable D.text) -- severity
    <*> D.column (D.nonNullable D.text) -- message
    <*> D.column (D.nullable D.jsonb) -- details
    <*> D.column (D.nonNullable D.timestamptz) -- created_at

-- --------------------------------------------------------------------------
-- Graph state
-- --------------------------------------------------------------------------

{- | Read persisted graph state for a run.
runtime_version is Nothing for rows written before migration 044.
-}
readGraphState :: UUID -> Session (Maybe PulseGraphStateSnapshot)
readGraphState runId =
  Session.statement runId $
    Statement
      "SELECT node_statuses, node_outputs, remaining_rewrite_budget, runtime_version, \
      \applied_rewrite_id, node_provenance, topology_hash, hosted_checkpoint_sequence, hosted_terminal_state, updated_at \
      \FROM pulse.graph_state WHERE run_id = $1"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      (D.rowMaybe graphStateDecoder)
      True
  where
    graphStateDecoder =
      PulseGraphStateSnapshot
        <$> D.column (D.nonNullable D.jsonb) -- node_statuses
        <*> D.column (D.nonNullable D.jsonb) -- node_outputs
        <*> D.column (D.nullable D.jsonb) -- remaining_rewrite_budget
        <*> D.column (D.nullable D.int4) -- runtime_version
        <*> D.column (D.nullable D.int8) -- applied_rewrite_id
        <*> D.column (D.nullable D.jsonb) -- node_provenance
        <*> D.column (D.nullable D.text) -- topology_hash
        <*> D.column (D.nullable D.int8) -- hosted_checkpoint_sequence
        <*> D.column (D.nullable D.text) -- hosted_terminal_state
        <*> (GraphStateRevision <$> D.column (D.nonNullable D.timestamptz)) -- updated_at

-- | Read persisted graph state for admin display.
readGraphStateForAdmin :: UUID -> Session (Maybe PulseGraphStateAdminView)
readGraphStateForAdmin runId =
  Session.statement runId $
    Statement
      "SELECT node_statuses, node_outputs, remaining_rewrite_budget, runtime_version, \
      \applied_rewrite_id, node_provenance, topology_hash, hosted_checkpoint_sequence, hosted_terminal_state, updated_at \
      \FROM pulse.graph_state WHERE run_id = $1"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      (D.rowMaybe adminGraphStateDecoder)
      True
  where
    adminGraphStateDecoder =
      PulseGraphStateAdminView
        <$> D.column (D.nonNullable D.jsonb) -- node_statuses
        <*> D.column (D.nonNullable D.jsonb) -- node_outputs
        <*> D.column (D.nullable D.jsonb) -- remaining_rewrite_budget
        <*> D.column (D.nullable D.int4) -- runtime_version
        <*> D.column (D.nullable D.int8) -- applied_rewrite_id
        <*> D.column (D.nullable D.jsonb) -- node_provenance
        <*> D.column (D.nullable D.text) -- topology_hash
        <*> D.column (D.nullable D.int8) -- hosted_checkpoint_sequence
        <*> D.column (D.nullable D.text) -- hosted_terminal_state
        <*> D.column (D.nonNullable D.timestamptz) -- updated_at

{- | Persist graph state using optimistic compare-and-swap semantics.

A write with no expected revision is an insert-only first write. A write
with an expected revision updates only the row whose @updated_at@ still
matches that revision.  Production callers choose the replacement
@updated_at@ through
'Cortex.Pulse.Executor.Persistence.persistGraphState', which keeps revisions
strictly increasing even if the system clock returns an equal or older
timestamp.
-}
writeGraphState :: GraphStateWrite -> Transaction GraphStateWriteResult
writeGraphState input =
  fmap toWriteResult . Tx.statement input $
    Statement
      "WITH input AS ( \
      \  SELECT \
      \    $1::uuid AS run_id, \
      \    $2::jsonb AS node_statuses, \
      \    $3::jsonb AS node_outputs, \
      \    $4::jsonb AS remaining_rewrite_budget, \
      \    $5::int4 AS runtime_version, \
      \    $6::int8 AS applied_rewrite_id, \
      \    $7::jsonb AS node_provenance, \
      \    $8::text AS topology_hash, \
      \    $9::int8 AS hosted_checkpoint_sequence, \
      \    $10::text AS hosted_terminal_state, \
      \    $11::timestamptz AS updated_at, \
      \    $12::timestamptz AS expected_revision \
      \), inserted AS ( \
      \  INSERT INTO pulse.graph_state \
      \    (run_id, node_statuses, node_outputs, remaining_rewrite_budget, \
      \     runtime_version, applied_rewrite_id, node_provenance, topology_hash, hosted_checkpoint_sequence, hosted_terminal_state, updated_at) \
      \  SELECT run_id, node_statuses, node_outputs, remaining_rewrite_budget, \
      \         runtime_version, applied_rewrite_id, node_provenance, topology_hash, hosted_checkpoint_sequence, hosted_terminal_state, updated_at \
      \  FROM input \
      \  WHERE expected_revision IS NULL \
      \  ON CONFLICT (run_id) DO NOTHING \
      \  RETURNING updated_at \
      \), updated AS ( \
      \  UPDATE pulse.graph_state gs SET \
      \    node_statuses = input.node_statuses, \
      \    node_outputs = input.node_outputs, \
      \    remaining_rewrite_budget = input.remaining_rewrite_budget, \
      \    runtime_version = input.runtime_version, \
      \    applied_rewrite_id = input.applied_rewrite_id, \
      \    node_provenance = input.node_provenance, \
      \    topology_hash = input.topology_hash, \
      \    hosted_checkpoint_sequence = input.hosted_checkpoint_sequence, \
      \    hosted_terminal_state = input.hosted_terminal_state, \
      \    updated_at = input.updated_at \
      \  FROM input \
      \  WHERE input.expected_revision IS NOT NULL \
      \    AND gs.run_id = input.run_id \
      \    AND gs.updated_at = input.expected_revision \
      \  RETURNING gs.updated_at \
      \) \
      \SELECT updated_at FROM inserted \
      \UNION ALL \
      \SELECT updated_at FROM updated \
      \LIMIT 1"
      ( Enc.encodeParams
          ( Enc.col (.gswRunId) (Enc.nonNullable Enc.uuid)
              :| [ Enc.col (.gswNodeStatuses) (Enc.nonNullable Enc.jsonb)
                 , Enc.col (.gswNodeOutputs) (Enc.nonNullable Enc.jsonb)
                 , Enc.col (.gswRemainingRewriteBudget) (Enc.nullable Enc.jsonb)
                 , Enc.col (.gswRuntimeVersion) (Enc.nullable Enc.int4)
                 , Enc.col (.gswAppliedRewriteId) (Enc.nullable Enc.int8)
                 , Enc.col (.gswNodeProvenance) (Enc.nullable Enc.jsonb)
                 , Enc.col (.gswTopologyHash) (Enc.nullable Enc.text)
                 , Enc.col (.gswHostedCheckpointSequence) (Enc.nullable Enc.int8)
                 , Enc.col (.gswHostedTerminalState) (Enc.nullable Enc.text)
                 , Enc.col (.gswUpdatedAt) (Enc.nonNullable Enc.timestamptz)
                 , Enc.col
                     (fmap unGraphStateRevision . (.gswExpectedRevision))
                     (Enc.nullable Enc.timestamptz)
                 ]
          )
      )
      (D.rowMaybe (GraphStateRevision <$> D.column (D.nonNullable D.timestamptz)))
      False
  where
    toWriteResult = \case
      Just revision -> GraphStateWriteApplied revision
      Nothing -> GraphStateWriteStale

-- | Persist a graph rewrite event (append-only) and return its durable rewrite id.
writeGraphRewrite :: GraphRewriteInsert -> Transaction Int64
writeGraphRewrite input =
  Tx.statement input $
    Statement
      "INSERT INTO pulse.graph_rewrites \
      \(run_id, source_node_id, source_node_output, rewrite_cost, rewrite_delta, \
      \ budget_before, budget_after, rewrite_spec, status, rejection_reason, \
      \ exceeded_dimensions, created_at, admission_mode) \
      \VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) \
      \RETURNING rewrite_id"
      ( Enc.encodeParams
          ( Enc.col (.griRunId) (Enc.nonNullable Enc.uuid)
              :| [ Enc.col (.griSourceNodeId) (Enc.nonNullable Enc.text)
                 , Enc.col (.griSourceNodeOutput) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griRewriteCost) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griRewriteDelta) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griBudgetBefore) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griBudgetAfter) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griRewriteSpec) (Enc.nonNullable Enc.jsonb)
                 , Enc.col (.griStatus) (Enc.nonNullable Enc.text)
                 , Enc.col (.griRejectionReason) (Enc.nullable Enc.text)
                 , Enc.col (.griExceededDimensions) (Enc.nullable Enc.jsonb)
                 , Enc.col (.griCreatedAt) (Enc.nonNullable Enc.timestamptz)
                 , Enc.col (.griAdmissionMode) (Enc.nonNullable Enc.text)
                 ]
          )
      )
      (D.singleRow (D.column (D.nonNullable D.int8)))
      False

-- | Read admitted rewrite events for a run, oldest first.
readGraphRewrites
  :: UUID -> Session [(Int64, Text, Maybe Value, Maybe Value, Maybe Value, Value, Text)]
readGraphRewrites runId =
  Session.statement runId $
    Statement
      "SELECT rewrite_id, source_node_id, source_node_output, rewrite_cost, rewrite_delta, rewrite_spec, admission_mode \
      \FROM pulse.graph_rewrites \
      \WHERE run_id = $1 AND status = 'admitted' \
      \ORDER BY rewrite_id ASC"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      ( D.rowList
          ( (,,,,,,)
              <$> D.column (D.nonNullable D.int8) -- rewrite_id
              <*> D.column (D.nonNullable D.text) -- source_node_id
              <*> D.column (D.nullable D.jsonb) -- source_node_output
              <*> D.column (D.nullable D.jsonb) -- rewrite_cost
              <*> D.column (D.nullable D.jsonb) -- rewrite_delta
              <*> D.column (D.nonNullable D.jsonb) -- rewrite_spec
              <*> D.column (D.nonNullable D.text) -- admission_mode
          )
      )
      True

-- | Read admitted rewrite events for a run up to the given watermark, oldest first.
readGraphRewritesUpTo
  :: UUID -> Int64 -> Session [(Int64, Text, Maybe Value, Maybe Value, Maybe Value, Value, Text)]
readGraphRewritesUpTo runId maxRewriteId =
  Session.statement (runId, maxRewriteId) $
    Statement
      "SELECT rewrite_id, source_node_id, source_node_output, rewrite_cost, rewrite_delta, rewrite_spec, admission_mode \
      \FROM pulse.graph_rewrites \
      \WHERE run_id = $1 AND rewrite_id <= $2 AND status = 'admitted' \
      \ORDER BY rewrite_id ASC"
      ( Enc.encode2
          (fst, Enc.nonNullable Enc.uuid)
          (snd, Enc.nonNullable Enc.int8)
      )
      ( D.rowList
          ( (,,,,,,)
              <$> D.column (D.nonNullable D.int8) -- rewrite_id
              <*> D.column (D.nonNullable D.text) -- source_node_id
              <*> D.column (D.nullable D.jsonb) -- source_node_output
              <*> D.column (D.nullable D.jsonb) -- rewrite_cost
              <*> D.column (D.nullable D.jsonb) -- rewrite_delta
              <*> D.column (D.nonNullable D.jsonb) -- rewrite_spec
              <*> D.column (D.nonNullable D.text) -- admission_mode
          )
      )
      True

-- | Read rewrite events for admin display, oldest first.
readGraphRewritesForAdmin :: UUID -> Session [PulseGraphRewriteAdminView]
readGraphRewritesForAdmin runId =
  Session.statement runId $
    Statement
      "SELECT rewrite_id, source_node_id, rewrite_cost, rewrite_delta, \
      \budget_before, budget_after, rewrite_spec, status, rejection_reason, \
      \exceeded_dimensions, created_at \
      \FROM pulse.graph_rewrites WHERE run_id = $1 ORDER BY rewrite_id ASC"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      ( D.rowList
          ( PulseGraphRewriteAdminView
              <$> D.column (D.nonNullable D.int8) -- rewrite_id
              <*> D.column (D.nonNullable D.text) -- source_node_id
              <*> D.column (D.nullable D.jsonb) -- rewrite_cost
              <*> D.column (D.nullable D.jsonb) -- rewrite_delta
              <*> D.column (D.nullable D.jsonb) -- budget_before
              <*> D.column (D.nullable D.jsonb) -- budget_after
              <*> D.column (D.nonNullable D.jsonb) -- rewrite_spec
              <*> D.column (D.nonNullable D.text) -- status
              <*> D.column (D.nullable D.text) -- rejection_reason
              <*> D.column (D.nullable D.jsonb) -- exceeded_dimensions
              <*> D.column (D.nonNullable D.timestamptz) -- created_at
          )
      )
      True

-- --------------------------------------------------------------------------
-- Signals
-- --------------------------------------------------------------------------

{- | Scheduler-facing queue pressure aggregate: how many runs are runnable
but unclaimed, how stale the oldest of them is, and how many are parked on
signals. One cheap aggregate per poll tick; the scheduler surfaces it on the
health endpoint and warns when saturation starves the pending queue.
-}
data BackpressureSnapshot = BackpressureSnapshot
  { bpsPendingRuns :: Int32
  , bpsOldestPendingAgeSeconds :: Maybe Double
  , bpsWaitingRuns :: Int32
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

readBackpressureSnapshot :: UTCTime -> Session BackpressureSnapshot
readBackpressureSnapshot now =
  Session.statement now $
    Statement
      -- Age is measured over never-started pending runs only: created_at is
      -- not the time a resumed run became pending again, so a woken waiter
      -- would otherwise report its full lifetime as queue age and trip false
      -- starvation warnings. Requeued-run queue age needs a pending_since
      -- column (tracked with the rest of #259).
      "SELECT count(*) FILTER (WHERE status = 'pending')::int4, \
      \  EXTRACT(EPOCH FROM ($1 - min(created_at) \
      \    FILTER (WHERE status = 'pending' AND started_at IS NULL)))::float8, \
      \  count(*) FILTER (WHERE status = 'waiting')::int4 \
      \FROM pulse.runs WHERE status IN ('pending', 'waiting')"
      (E.param (E.nonNullable E.timestamptz))
      ( D.singleRow
          ( BackpressureSnapshot
              <$> D.column (D.nonNullable D.int4)
              <*> D.column (D.nullable D.float8)
              <*> D.column (D.nonNullable D.int4)
          )
      )
      True

-- | Register a signal wait for a run/node.
registerSignalWait :: UUID -> NodeId -> SignalName -> UTCTime -> Maybe UTCTime -> Transaction ()
registerSignalWait runId (NodeId nodeId) (SignalName signalName) now expiresAt =
  Tx.statement (runId, nodeId, signalName, now, expiresAt) $
    Statement
      "INSERT INTO pulse.signals (run_id, node_id, signal_name, status, created_at, expires_at) \
      \VALUES ($1, $2, $3, 'pending', $4, $5)"
      ( Enc.encode5
          ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d, _) -> d), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, _, e) -> e), Enc.nullable Enc.timestamptz)
      )
      D.noResult
      False

-- | Invalid signal-wait shapes rejected before a run is parked.
data SignalWaitInvalid
  = -- | A run cannot wait on its own terminal signal; it would have no worker left to reach terminal status.
    SignalWaitInvalidSelfRunTerminal UUID
  | -- | Another node already owns the one pending row for this run/signal.
    SignalWaitInvalidDuplicatePending Text NodeId
  deriving stock (Eq, Show)

-- | How a pending settlement should be committed.
data SignalWaitPendingMode
  = -- | No pending row exists yet; settlement should insert one.
    SignalWaitPendingInsert
  | -- | The same node already owns the pending row; settlement is idempotent.
    SignalWaitPendingAlreadyRegistered
  deriving stock (Eq, Show)

-- | Result of registering a signal wait through the resolve-aware path.
data SignalWaitRegistration
  = -- | A pending wait row exists; the stage should suspend.
    SignalWaitRegistered
  | {- | The awaited condition already holds; the wait row was written as
    delivered and the stage should complete with this payload instead of
    suspending. Closes the lost-wakeup window for waits on runs that
    reached a terminal status before the wait was registered.
    -}
    SignalWaitAlreadyDelivered Value
  | -- | A runtime-owned run-terminal wait targeted a run that does not exist.
    SignalWaitMissingRun UUID
  | -- | The requested wait cannot be delivered correctly.
    SignalWaitRegistrationInvalid SignalWaitInvalid
  deriving stock (Eq, Show)

{- | Settlement-time decision for a waiting node. Planning is read/lock-only;
committing happens after graph-state CAS so stale owners do not leave signal
rows behind.
-}
data SignalWaitSettlement
  = SignalWaitSettlementPending SignalWaitPendingMode
  | SignalWaitSettlementAlreadyDelivered Value
  | SignalWaitSettlementResolveNow Value
  | SignalWaitSettlementMissingRun UUID
  | SignalWaitSettlementInvalid SignalWaitInvalid
  deriving stock (Eq, Show)

{- | Decide how a waiting node should settle without writing signal rows.

Delivered rows win first: this covers idempotent re-settlement and signals that
arrived while the run was executing after a mixed resolve/park settlement.
Run-terminal waits then lock the awaited run row and either resolve, park, or
fail on a missing target. Ordinary external signals remain pending.
-}
planSignalWaitSettlement :: UUID -> NodeId -> SignalName -> Transaction SignalWaitSettlement
planSignalWaitSettlement runId nodeId signalName@(SignalName signalNameText) = do
  -- Serialize the lookup -> register -> park span against the matching delivery, as
  -- the first action and strictly before lookupDeliveredSignalTx, so a completion
  -- arriving after the delivered-row check but before the park commits is not lost
  -- (ADR 0058). Run-terminal takes the global lock (cross-run mutual awaits form
  -- cycles); external-call takes a per-run lock (it only wakes its own run), so its
  -- park and delivery do not contend across unrelated runs. The two families are
  -- distinct prefixes, so a name is at most one of them.
  if isExternalCallSignal signalName
    then lockExternalCallProtocolTx runId
    else when (isJust (parseRunTerminalSignal signalName)) lockRunTerminalProtocolTx
  delivered <- lookupDeliveredSignalTx runId signalNameText (unNodeId nodeId)
  case delivered of
    Just mPayload -> pure (SignalWaitSettlementAlreadyDelivered (fromMaybe Aeson.Null mPayload))
    Nothing -> do
      pendingMode <- pendingSettlementMode
      case parseRunTerminalSignal signalName of
        Nothing -> pure pendingMode
        Just awaitedRunId
          | awaitedRunId == runId ->
              pure (SignalWaitSettlementInvalid (SignalWaitInvalidSelfRunTerminal awaitedRunId))
          | otherwise -> do
              awaitedStatus <- runStatusForShareTx awaitedRunId
              case awaitedStatus of
                Nothing -> pure (SignalWaitSettlementMissingRun awaitedRunId)
                Just status
                  | isTerminalStatus status ->
                      pure (SignalWaitSettlementResolveNow (runTerminalPayload awaitedRunId status))
                  | otherwise -> pure pendingMode
  where
    pendingSettlementMode = do
      pendingOwner <- lookupPendingSignalOwnerTx runId signalNameText
      pure $
        case pendingOwner of
          Nothing ->
            SignalWaitSettlementPending SignalWaitPendingInsert
          Just owner
            | owner == nodeId ->
                SignalWaitSettlementPending SignalWaitPendingAlreadyRegistered
            | otherwise ->
                SignalWaitSettlementInvalid (SignalWaitInvalidDuplicatePending signalNameText owner)

commitSignalWaitSettlement
  :: UUID
  -> NodeId
  -> SignalName
  -> UTCTime
  -> Maybe UTCTime
  -> SignalWaitSettlement
  -> Transaction ()
commitSignalWaitSettlement runId nodeId signalName now expiresAt = \case
  SignalWaitSettlementPending SignalWaitPendingInsert ->
    registerSignalWait runId nodeId signalName now expiresAt
  SignalWaitSettlementPending SignalWaitPendingAlreadyRegistered ->
    pure ()
  SignalWaitSettlementAlreadyDelivered {} ->
    pure ()
  SignalWaitSettlementResolveNow payload ->
    registerDeliveredSignal runId nodeId signalName payload now
  SignalWaitSettlementMissingRun {} ->
    pure ()
  SignalWaitSettlementInvalid {} ->
    pure ()

{- | Register a signal wait, resolving run-terminal waits against the awaited
run's current status in the same transaction. A wait on
'Cortex.Pulse.Signal.runTerminalSignalName' for a run that is already
completed, failed, cancelled, or timed out is written as delivered
immediately, so the waiting stage never parks on an event that has already
happened. The status set here must match the terminal writers that deliver
('updateRunCompleted'/'updateRunFailed'/'updateRunCancelled'/'updateRunTimedOut'):
'updateRunTimedOut' emits its only delivery before a late wait exists, so
omitting timeout here would park such a waiter forever.

If the run-terminal target is missing, no pending row is registered. Only the
runtime terminal writers may deliver this namespace, so a missing target would
otherwise create an undeliverable wait.
-}
registerSignalWaitOrResolve
  :: UUID -> NodeId -> SignalName -> UTCTime -> Maybe UTCTime -> Transaction SignalWaitRegistration
registerSignalWaitOrResolve runId nodeId signalName now expiresAt = do
  settlement <- planSignalWaitSettlement runId nodeId signalName
  case settlement of
    SignalWaitSettlementPending SignalWaitPendingInsert -> do
      registerSignalWait runId nodeId signalName now expiresAt
      pure SignalWaitRegistered
    SignalWaitSettlementPending SignalWaitPendingAlreadyRegistered ->
      pure SignalWaitRegistered
    SignalWaitSettlementAlreadyDelivered payload ->
      pure (SignalWaitAlreadyDelivered payload)
    SignalWaitSettlementResolveNow payload -> do
      registerDeliveredSignal runId nodeId signalName payload now
      pure (SignalWaitAlreadyDelivered payload)
    SignalWaitSettlementMissingRun missingRunId ->
      pure (SignalWaitMissingRun missingRunId)
    SignalWaitSettlementInvalid invalid ->
      pure (SignalWaitRegistrationInvalid invalid)

-- | Owner of the current pending wait row for a run/signal, if one exists.
lookupPendingSignalOwnerTx :: UUID -> Text -> Transaction (Maybe NodeId)
lookupPendingSignalOwnerTx runId signalName =
  fmap NodeId
    <$> Tx.statement
      (runId, signalName)
      ( Statement
          "SELECT node_id \
          \FROM pulse.signals \
          \WHERE run_id = $1 \
          \  AND signal_name = $2 \
          \  AND status = 'pending' \
          \  AND node_id IS NOT NULL \
          \ORDER BY signal_id DESC \
          \LIMIT 1"
          ( Enc.encode2
              (fst, Enc.nonNullable Enc.uuid)
              (snd, Enc.nonNullable Enc.text)
          )
          (D.rowMaybe (D.column (D.nonNullable D.text)))
          True
      )

{- | Run status lookup that share-locks the run row for the rest of the
transaction. Registration must serialize against the awaited run's terminal
status writer: with the share lock held, the terminal UPDATE (row-exclusive)
blocks until this transaction commits its pending wait row, so the
subsequent same-transaction delivery finds the row; conversely, a terminal
update that committed first is visible to this read and the wait resolves
immediately. Without the lock, a plain read can see 'running' while the
terminal commit and its delivery slip between the read and the wait insert —
a parked waiter no delivery will ever find.
-}
runStatusForShareTx :: UUID -> Transaction (Maybe Text)
runStatusForShareTx rId =
  Tx.statement rId $
    Statement
      "SELECT status FROM pulse.runs WHERE run_id = $1 FOR SHARE"
      (E.param (E.nonNullable E.uuid))
      (D.rowMaybe (D.column (D.nonNullable D.text)))
      False

-- | Payload carried by a run-terminal signal delivery.
runTerminalPayload :: UUID -> Text -> Value
runTerminalPayload terminalRunId status =
  Aeson.object
    [ "runId" Aeson..= terminalRunId
    , "outcome" Aeson..= status
    ]

-- | Insert a signal row that is already delivered, with payload.
registerDeliveredSignal :: UUID -> NodeId -> SignalName -> Value -> UTCTime -> Transaction ()
registerDeliveredSignal runId (NodeId nodeId) (SignalName signalName) payload now =
  Tx.statement (runId, nodeId, signalName, payload, now) $
    Statement
      "WITH updated AS ( \
      \  UPDATE pulse.signals SET \
      \    status = 'delivered', \
      \    payload = $4, \
      \    delivered_at = $5 \
      \  WHERE run_id = $1 AND node_id = $2 AND signal_name = $3 AND status = 'pending' \
      \  RETURNING signal_id \
      \) \
      \INSERT INTO pulse.signals \
      \  (run_id, node_id, signal_name, status, payload, created_at, delivered_at) \
      \SELECT $1, $2, $3, 'delivered', $4, $5, $5 \
      \WHERE NOT EXISTS (SELECT 1 FROM updated)"
      ( Enc.encode5
          ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d, _) -> d), Enc.nonNullable Enc.jsonb)
          ((\(_, _, _, _, e) -> e), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

{- | Deliver a run-terminal signal to every run waiting on it, across runs,
and wake each one. Called by the runtime when a run reaches a terminal
status; every database error path is the caller's to handle through the
transaction result.
-}
deliverRunTerminalSignals :: UUID -> TerminalRunStatus -> UTCTime -> Transaction [UUID]
deliverRunTerminalSignals terminalRunId status now = do
  lockRunTerminalProtocolTx
  let SignalName signalName = runTerminalSignalName terminalRunId
      payload = runTerminalPayload terminalRunId (terminalStatusText status)
  wokenRunIds <-
    Tx.statement (signalName, payload, now) $
      Statement
        "UPDATE pulse.signals SET \
        \  status = 'delivered', \
        \  payload = $2, \
        \  delivered_at = $3 \
        \WHERE signal_name = $1 AND status = 'pending' \
        \RETURNING run_id"
        ( Enc.encode3
            ((\(a, _, _) -> a), Enc.nonNullable Enc.text)
            ((\(_, b, _) -> b), Enc.nonNullable Enc.jsonb)
            ((\(_, _, c) -> c), Enc.nonNullable Enc.timestamptz)
        )
        (D.rowList (D.column (D.nonNullable D.uuid)))
        False
  traverse_ wakeRunFromWaiting (orderWokenRunIdsForUpdate wokenRunIds)
  pure wokenRunIds

-- | Deterministic run-row update order for terminal signal fanout.
orderWokenRunIdsForUpdate :: [UUID] -> [UUID]
orderWokenRunIdsForUpdate = sort . nub

{- | Deliver a signal and wake the run. Atomically:
 1. Mark the signal as delivered with payload
 2. Transition the run from 'waiting' → 'pending' so the scheduler reclaims it
Returns True if a pending signal was found and delivered.

Precondition: callers should deliver signals only when the run is in
'waiting' status (i.e., not during an active frontier wave). The wake-up
in step 2 is conditional on the run being 'waiting', so early delivery
is safe (the signal is recorded but the run is not woken), but the timing
guarantee that "delivery cannot arrive during a frontier wave" is an
assumption about callers, not enforced by this function.
-}
deliverSignal :: UUID -> Text -> Value -> UTCTime -> Transaction Bool
deliverSignal runId signalName payload now =
  -- The run-terminal:<uuid> namespace is reserved for the runtime's terminal
  -- status writers (deliverRunTerminalSignals, driven by the run's own terminal
  -- transition). External/host delivery must not be able to forge it: otherwise
  -- the await-a-run primitive is spoofable — a caller could deliver
  -- run-terminal:<child> with an arbitrary payload and wake/complete the waiter
  -- while the child is still running. The external-call:<digest> namespace is
  -- likewise reserved for the trusted external-call delivery path
  -- (deliverExternalCallSignal): forging it would re-arm a parked external-call
  -- stage with an attacker-chosen wake. Refuse both reserved families here;
  -- legitimate delivery for them never flows through this path.
  if isJust (parseRunTerminalSignal (SignalName signalName))
    || isExternalCallSignal (SignalName signalName)
    then pure False
    else do
      delivered <- deliverSignalOnly runId signalName payload now
      when delivered $ wakeRunFromWaiting runId
      pure delivered

-- | Mark a signal as delivered (without waking the run).
deliverSignalOnly :: UUID -> Text -> Value -> UTCTime -> Transaction Bool
deliverSignalOnly runId signalName payload now =
  Tx.statement (runId, signalName, payload, now) $
    Statement
      "UPDATE pulse.signals SET \
      \  status = 'delivered', \
      \  payload = $3, \
      \  delivered_at = $4 \
      \WHERE run_id = $1 AND signal_name = $2 AND status = 'pending'"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.jsonb)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.timestamptz)
      )
      ((/= 0) <$> D.rowsAffected)
      False

{- | Trusted delivery of a reserved @external-call:@ completion wake (ADR 0059).
Takes the durable attempt key and derives the reserved name internally, so an
internal caller cannot deliver an ordinary signal through this path.

Serialization: takes the per-run external-call advisory lock first, so it cannot
interleave with the suspend settlement that plans the same wait (which also takes
the lock). This closes the lost-wakeup window where a completion arriving after
settlement's delivered-row check but before its park commits would be missed.

Delivery first requires a durable non-terminal attempt row. It then upserts the
wake: mark a pending wait delivered, or — if the wake arrives before the stage
parks and registers its wait — insert a node-scoped @delivered@ row that suspend
settlement observes as already-delivered and re-arms. The insert is suppressed
only when an un-consumed @delivered@ row already exists for this wake (an
in-flight duplicate), so it stays idempotent; a @consumed@ row from a prior
re-suspend round does NOT suppress it, because the signal name is reused across
rounds and a fresh wake must still re-arm. A settled or failed attempt is
terminal, so delivery to it is a no-op (suppresses a post-settlement orphan wake
without ever dropping a live one). The payload is a wake marker only; completion
comes from the driver on resume, never from this payload.
-}
deliverExternalCallSignal :: ExternalCallAttemptKey -> Value -> UTCTime -> Transaction Bool
deliverExternalCallSignal key payload now = do
  lockExternalCallProtocolTx (ecaRunId key)
  attempt <- loadExternalCallAttempt key
  case attempt of
    Nothing -> pure False
    Just a
      | externalCallStatusIsTerminal (ecaStatus a) -> pure False
      | otherwise -> do
          let runId = ecaRunId key
              nodeIdText = ecaNodeId key
              SignalName signalNameText = externalCallSignalName (externalCallSignalSuffix key)
          updated <-
            Tx.statement (runId, signalNameText, nodeIdText, payload, now) $
              Statement
                "UPDATE pulse.signals SET \
                \  status = 'delivered', \
                \  payload = $4, \
                \  delivered_at = $5 \
                \WHERE run_id = $1 AND signal_name = $2 AND node_id = $3 AND status = 'pending'"
                externalCallWakeEncoder
                ((/= 0) <$> D.rowsAffected)
                False
          delivered <-
            if updated
              then pure True
              else
                Tx.statement (runId, signalNameText, nodeIdText, payload, now) $
                  Statement
                    "INSERT INTO pulse.signals \
                    \  (run_id, signal_name, node_id, status, payload, created_at, delivered_at) \
                    \SELECT $1, $2, $3, 'delivered', $4, $5, $5 \
                    \WHERE NOT EXISTS ( \
                    \  SELECT 1 FROM pulse.signals \
                    \  WHERE run_id = $1 AND signal_name = $2 AND node_id = $3 \
                    \    AND status = 'delivered' \
                    \)"
                    externalCallWakeEncoder
                    ((/= 0) <$> D.rowsAffected)
                    False
          when delivered $ wakeRunFromWaiting runId
          pure delivered
  where
    externalCallWakeEncoder =
      Enc.encode5
        ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
        ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.text)
        ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.text)
        ((\(_, _, _, d, _) -> d), Enc.nonNullable Enc.jsonb)
        ((\(_, _, _, _, e) -> e), Enc.nonNullable Enc.timestamptz)

{- | Consume **every** delivered reserved @external-call:@ wake row for a
node-scoped wait (status @delivered@ → @consumed@). Settlement calls this when it
re-arms the parked node, so the wake is not re-observed: 'lookupDeliveredSignalTx'
returns the latest @delivered@ row, so leaving any @delivered@ row behind would
re-trigger the re-arm in a loop. Consuming all of them closes that loop. Idempotent.
-}
consumeDeliveredSignal :: UUID -> SignalName -> NodeId -> UTCTime -> Transaction ()
consumeDeliveredSignal runId (SignalName signalNameText) (NodeId nodeIdText) now = do
  -- Bound row growth: drop consumed rows from prior re-poll rounds before marking
  -- this round's delivered rows consumed. The signal name is reused across rounds, so
  -- without this a long-polled external call would leave one dead 'consumed' row per
  -- round; this keeps at most the most recent for that (run, signal, node).
  Tx.statement (runId, signalNameText, nodeIdText) $
    Statement
      "DELETE FROM pulse.signals \
      \WHERE run_id = $1 AND signal_name = $2 AND node_id = $3 AND status = 'consumed'"
      ( Enc.encode3
          ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c) -> c), Enc.nonNullable Enc.text)
      )
      D.noResult
      False
  Tx.statement (runId, signalNameText, nodeIdText, now) $
    Statement
      "UPDATE pulse.signals SET \
      \  status = 'consumed', \
      \  delivered_at = COALESCE(delivered_at, $4) \
      \WHERE run_id = $1 AND signal_name = $2 AND node_id = $3 AND status = 'delivered'"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

{- | Transition a run from 'waiting' back to 'pending' so the scheduler
picks it up on the next poll cycle.
-}
wakeRunFromWaiting :: UUID -> Transaction ()
wakeRunFromWaiting rId =
  Tx.statement rId $
    Statement
      "UPDATE pulse.runs SET status = 'pending'::pulse.run_status \
      \WHERE run_id = $1 AND status = 'waiting'::pulse.run_status"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      D.noResult
      False

{- | Look up the status of any signal for a (run_id, signal_name) pair,
regardless of current status. Returns the most recent status.
Used to distinguish "no such signal" from "already delivered".
-}
lookupSignalStatus :: UUID -> Text -> Transaction (Maybe Text)
lookupSignalStatus runId signalName =
  Tx.statement (runId, signalName) $
    Statement
      "SELECT status FROM pulse.signals \
      \WHERE run_id = $1 AND signal_name = $2 \
      \ORDER BY signal_id DESC LIMIT 1"
      (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.text))
      (D.rowMaybe (D.column (D.nonNullable D.text)))
      True

{- | Look up a delivered signal for a specific node in a run.
Scoped to node_id to prevent a later wait on the same signal name
from consuming a stale delivery from an earlier stage.
-}

-- | Shared statement: the latest delivered signal for a (run, signal, node).
deliveredSignalStatement :: Statement (UUID, Text, Text) (Maybe (Maybe Value))
deliveredSignalStatement =
  Statement
    "SELECT payload FROM pulse.signals \
    \WHERE run_id = $1 AND signal_name = $2 AND node_id = $3 AND status = 'delivered' \
    \ORDER BY signal_id DESC \
    \LIMIT 1"
    ( Enc.encode3
        ((\(a, _, _) -> a), Enc.nonNullable Enc.uuid)
        ((\(_, b, _) -> b), Enc.nonNullable Enc.text)
        ((\(_, _, c) -> c), Enc.nonNullable Enc.text)
    )
    (D.rowMaybe (D.column (D.nullable D.jsonb)))
    True

lookupDeliveredSignal :: UUID -> Text -> Text -> Session (Maybe (Maybe Value))
lookupDeliveredSignal runId signalName nodeId =
  Session.statement (runId, signalName, nodeId) deliveredSignalStatement

{- | Transaction-level variant of 'lookupDeliveredSignal'. Suspend settlement
checks for an already-delivered row before it decides whether to park the run,
so a re-settlement or mixed pending/resolved suspend completes the node instead
of committing a waiter on an already-satisfied signal.
-}
lookupDeliveredSignalTx :: UUID -> Text -> Text -> Transaction (Maybe (Maybe Value))
lookupDeliveredSignalTx runId signalName nodeId =
  Tx.statement (runId, signalName, nodeId) deliveredSignalStatement

-- | Transition a run to 'waiting' status.
updateRunWaiting :: UUID -> Transaction ()
updateRunWaiting rId =
  Tx.statement rId $
    Statement
      "UPDATE pulse.runs SET status = 'waiting'::pulse.run_status \
      \WHERE run_id = $1 AND status = 'running'::pulse.run_status"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.uuid))
      D.noResult
      False
