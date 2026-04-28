{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Pulse.Executor.Persistence
  ( persistGraphState
  , requireGraphStatePersist
  , persistStageSuccess
  , persistStageRewrite
  , flushDeferredRejections
  , rejectedRewriteInsertValue
  , handleRewriteAdmissionFailure
  , handleSkip
  , handleTerminalFailure
  , buildCheckpointState
  , requireTx
  , failRun
  , timeoutRun
  , persistTerminalStageOutcome
  , failUnsupportedTaskType
  , retryDelayMicros
  , terminalStageOutcome
  , skipStageSummary
  , stageAttemptFailureSummary
  , stageFailureSummary
  , stageFailureType
  , stageFailureMessage
  , recordRunEvent
  , rewriteRejectionInfo
  )
where

import Control.Concurrent.MVar (withMVar)
import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO, writeTVar)
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID (UUID)

import Cortex.Pulse.Executor.Events
  ( ExecutorEvent (..)
  , FailrunInfo (..)
  , RewriteAdmissionInfo (..)
  , RewriteRejectionInfo (..)
  , StageFailureDetail (..)
  )
import Cortex.Pulse.Executor.Types
  ( RewriteAdmissionState (..)
  , RewriteRejection (..)
  , RunFailureSpec (..)
  , StageAttemptRef (..)
  , StageAttemptResult (..)
  , StageCall (..)
  , StageEnv (..)
  )
import Cortex.Pulse.GraphRuntime (GraphState (..))
import Cortex.Pulse.Materialization
  ( PersistedGraphState (..)
  , PersistedRewrite (..)
  , rewriteDeltaSummaryJson
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StableStageId
  , StageDefinition (..)
  , StageFailure (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , StageRetryBackoff (..)
  )
import Cortex.Pulse.PlanHydration
  ( RewriteError (..)
  , planRewriteDelta
  , renderRewriteError
  , rewriteErrorType
  , toSerializableStageDefinition
  )
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite
  ( BudgetContext (..)
  , GraphRewrite
  , PlannedRewriteDelta (..)
  , RewriteBudget (..)
  , RewriteCost (..)
  , RewriteRejectionContext (..)
  , admitRewriteDelta
  , admittedDelta
  , admittedRemainingBudget
  , exceededDimensions
  )

import Platform.Database qualified as DB
import Platform.DurableTask.Checkpoint (buildCheckpointEnvelope)
import Platform.DurableTask.Types (RunOutcome (..), StageStatus (..))
import Platform.Observability (emitObsEvent)

persistGraphState :: StageEnv -> PersistedGraphState -> IO (Either Text ())
persistGraphState env persistedState = do
  now <- getCurrentTime
  let input =
        Q.GraphStateWrite
          { gswRunId = env.seRunId
          , gswNodeStatuses = Aeson.toJSON persistedState.pgsGraphState.gsNodeStatuses
          , gswNodeOutputs = Aeson.toJSON persistedState.pgsGraphState.gsNodeOutputs
          , gswRemainingRewriteBudget = Just (Aeson.toJSON persistedState.pgsRemainingRewriteBudget)
          , gswRuntimeVersion = Just (fromIntegral env.seCheckpointRuntimeVersion)
          , gswAppliedRewriteId = persistedState.pgsAppliedRewriteId
          , gswNodeProvenance = Just (Aeson.toJSON persistedState.pgsNodeProvenance)
          , gswTopologyHash = persistedState.pgsTopologyHash
          , gswUpdatedAt = now
          }
  result <-
    DB.runTransaction env.sePool $
      Q.writeGraphState input
  pure (first T.pack result)

requireGraphStatePersist :: StageEnv -> PersistedGraphState -> IO (Maybe RunOutcome)
requireGraphStatePersist env persistedState = do
  result <- persistGraphState env persistedState
  case result of
    Right () -> pure Nothing
    Left err -> do
      now <- getCurrentTime
      recordRunEvent
        env
        "run.graph_state_persist_failed"
        Q.RunEventError
        ("Graph state persistence failed: " <> err)
        Nothing
      failRun env.sePool env.seRunId now "graph_state_persist_failed" err True
      pure (Just OutcomeFailed)

persistStageSuccess
  :: StageEnv
  -> StageAttemptRef
  -> NodeId
  -> Text
  -> UTCTime
  -> Aeson.Value
  -> IO (StageAttemptResult stageId)
persistStageSuccess env attemptRef nodeId stageName stageEnd newState = do
  let completionSummary = attemptSummary attemptRef.sarAttempt
      checkpointState = buildCheckpointState env stageName newState
  cpResult <-
    requireTx env.sePool env.seRunId "write_checkpoint"
      . DB.runTransaction env.sePool
      $ do
        Q.writeCheckpoint env.seRunId env.seTaskType stageName checkpointState completionSummary stageEnd
        Q.updateStageAttemptCompleted attemptRef.sarAttemptLogId StageCompleted Nothing stageEnd
        Q.updateStageCompleted attemptRef.sarLogId StageCompleted completionSummary stageEnd
  case cpResult of
    Nothing -> pure (StageTerminal OutcomeFailed)
    Just () -> do
      -- DIG-529: record per-node settlement timestamp for memory
      -- queries.  Updated after the checkpoint write succeeds so a
      -- failed persist doesn't surface a "completed" node to memory.
      atomically $ modifyTVar' env.seNodeCompletedAtVar (Map.insert nodeId stageEnd)
      emitObsEvent $ EvtStageCompleted env.seRunId stageName attemptRef.sarAttempt
      let stageDetails
            | attemptRef.sarAttempt > 1 =
                Aeson.object ["stage" Aeson..= stageName, "attempts" Aeson..= attemptRef.sarAttempt]
            | otherwise = Aeson.object ["stage" Aeson..= stageName]
      recordRunEvent
        env
        "stage.completed"
        Q.RunEventInfo
        ("Stage completed: " <> stageName)
        (Just stageDetails)
      pure (StageAdvance newState)

persistStageRewrite
  :: StableStageId stageId
  => StageEnv
  -> StagePlan stageId
  -> StageCall stageId
  -> StageAttemptRef
  -> UTCTime
  -> Aeson.Value
  -> GraphRewrite NodeId (StageDefinition stageId)
  -> IO (StageAttemptResult stageId)
persistStageRewrite env stagePlan stageCall attemptRef stageEnd newOutput rewrite = do
  let completionSummary = attemptSummary attemptRef.sarAttempt
      serializableRewrite = fmap toSerializableStageDefinition rewrite
      checkpointState = buildCheckpointState env stageCall.scStageName newOutput
  withMVar stageCall.scRewriteAdmission.rasAdmissionLock $ \_ -> do
    currentBudget <- readTVarIO stageCall.scRewriteAdmission.rasRemainingBudget
    let budgetCtx = budgetContextFromBudget stagePlan currentBudget
    case planRewriteDelta rewrite stagePlan of
      Left errs -> do
        let err = RewriteValidationFailed errs
            rejectionCtx =
              RewriteRejectionContext
                { rrcRejectionType = rewriteErrorType err
                , rrcMessage = renderRewriteError err
                , rrcExceededDimensions = []
                , rrcBudgetContext = budgetCtx
                , rrcAttemptedCost = Nothing
                , rrcAttemptNumber = 0
                }
            rejectedRewrite =
              rejectedRewriteInsertValue
                env
                stageCall
                currentBudget
                (Aeson.toJSON serializableRewrite)
                stageEnd
                rejectionCtx
        emitObsEvent $
          EvtRewriteRejected env.seRunId stageCall.scStageName (rewriteRejectionInfo rejectionCtx Nothing)
        handleRewriteAdmissionFailure
          env
          attemptRef
          stageCall.scStageName
          stageEnd
          (RunFailureSpec rejectionCtx.rrcRejectionType rejectionCtx.rrcMessage False)
          Nothing
          [rejectedRewrite]
      Right delta ->
        case admitRewriteDelta currentBudget delta of
          Left budgetErr -> do
            let err = RewriteBudgetExhausted budgetErr
                dims = exceededDimensions budgetErr
                rejectionCtx =
                  RewriteRejectionContext
                    { rrcRejectionType = rewriteErrorType err
                    , rrcMessage = renderRewriteError err
                    , rrcExceededDimensions = dims
                    , rrcBudgetContext = budgetCtx
                    , rrcAttemptedCost = Just delta.prdCost
                    , rrcAttemptNumber = 0
                    }
                rejectedRewrite =
                  rejectedRewriteInsertValue
                    env
                    stageCall
                    currentBudget
                    (Aeson.toJSON serializableRewrite)
                    stageEnd
                    rejectionCtx
            -- Do not persist the rejected rewrite here — the caller
            -- (attemptStage) accumulates rejections and flushes them
            -- atomically at the attempt resolution boundary.
            pure
              ( StageRewriteRejected
                  RewriteRejection
                    { rrLastOutput = newOutput
                    , rrContext = rejectionCtx
                    , rrDeferredInsert = rejectedRewrite
                    }
              )
          Right admitted -> do
            let admDelta = admittedDelta admitted
                remainingBudget = admittedRemainingBudget admitted
            cpResult <-
              requireTx env.sePool env.seRunId "write_checkpoint"
                . DB.runTransaction env.sePool
                $ do
                  rewriteId <-
                    Q.writeGraphRewrite
                      Q.GraphRewriteInsert
                        { griRunId = env.seRunId
                        , griSourceNodeId = unNodeId stageCall.scNodeId
                        , griSourceNodeOutput = Just newOutput
                        , griRewriteCost = Just (Aeson.toJSON admDelta.prdCost)
                        , griRewriteDelta = Just (rewriteDeltaSummaryJson admDelta)
                        , griBudgetBefore = Just (Aeson.toJSON currentBudget)
                        , griBudgetAfter = Just (Aeson.toJSON remainingBudget)
                        , griRewriteSpec = Aeson.toJSON serializableRewrite
                        , griStatus = "admitted"
                        , griRejectionReason = Nothing
                        , griExceededDimensions = Nothing
                        , griCreatedAt = stageEnd
                        }
                  Q.writeCheckpoint
                    env.seRunId
                    env.seTaskType
                    stageCall.scStageName
                    checkpointState
                    completionSummary
                    stageEnd
                  Q.updateStageAttemptCompleted
                    attemptRef.sarAttemptLogId
                    StageCompleted
                    (Just (Aeson.object ["rewritten" Aeson..= True]))
                    stageEnd
                  Q.updateStageCompleted attemptRef.sarLogId StageCompleted completionSummary stageEnd
                  pure rewriteId
            case cpResult of
              Nothing -> pure (StageTerminal OutcomeFailed)
              Just rewriteId -> do
                atomically $ do
                  writeTVar stageCall.scRewriteAdmission.rasRemainingBudget remainingBudget
                  -- DIG-529: record per-node settlement timestamp.
                  modifyTVar' env.seNodeCompletedAtVar (Map.insert stageCall.scNodeId stageEnd)
                emitObsEvent $ EvtStageCompleted env.seRunId stageCall.scStageName attemptRef.sarAttempt
                emitObsEvent $
                  EvtRewriteAdmitted
                    env.seRunId
                    stageCall.scStageName
                    RewriteAdmissionInfo
                      { raiRewriteId = rewriteId
                      , raiCostNodes = admDelta.prdCost.rcAddedNodes
                      , raiCostEdges = admDelta.prdCost.rcAddedEdges
                      , raiRewriteOpsRemaining = remainingBudget.rbRewriteOpsMax
                      }
                recordRunEvent
                  env
                  "stage.rewritten"
                  Q.RunEventInfo
                  ("Stage rewritten: " <> stageCall.scStageName)
                  (Just (Aeson.object ["stage" Aeson..= stageCall.scStageName]))
                pure
                  ( StageAdvanceWithRewrite
                      newOutput
                      PersistedRewrite
                        { prRewriteId = rewriteId
                        , prSourceNodeId = stageCall.scNodeId
                        , prSourceNodeOutput = Just newOutput
                        , prRewriteCost = Just admDelta.prdCost
                        , prRewrite = rewrite
                        }
                  )

handleRewriteAdmissionFailure
  :: StageEnv
  -> StageAttemptRef
  -> Text
  -> UTCTime
  -> RunFailureSpec
  -> Maybe Aeson.Value
  -> [Q.GraphRewriteInsert]
  -> IO (StageAttemptResult stageId)
handleRewriteAdmissionFailure env attemptRef stageName stageEnd failureSpec mDetails rejectedRewrites = do
  stageLogResult <-
    DB.runTransaction env.sePool $ do
      mapM_ Q.writeGraphRewrite rejectedRewrites
      Q.updateStageAttemptCompleted
        attemptRef.sarAttemptLogId
        StageFailed
        ( Just
            ( Aeson.object
                ["error_type" Aeson..= failureSpec.rfsErrType, "error_message" Aeson..= failureSpec.rfsErrMsg]
            )
        )
        stageEnd
      Q.updateStageCompleted
        attemptRef.sarLogId
        StageFailed
        (Just (Aeson.String failureSpec.rfsErrMsg))
        stageEnd
      Q.updateRunFailed
        Q.RunFailureUpdate
          { rfuRunId = env.seRunId
          , rfuCompletedAt = stageEnd
          , rfuErrType = failureSpec.rfsErrType
          , rfuErrMsg = failureSpec.rfsErrMsg
          , rfuRetryable = failureSpec.rfsRetryable
          }
  case stageLogResult of
    Left txErr -> do
      emitObsEvent $ EvtDbCritical env.seRunId "rewrite_failure_persist" (T.pack txErr)
      failRun
        env.sePool
        env.seRunId
        stageEnd
        failureSpec.rfsErrType
        failureSpec.rfsErrMsg
        failureSpec.rfsRetryable
    Right () -> pure ()
  emitObsEvent $
    EvtStageFailed
      env.seRunId
      stageName
      attemptRef.sarAttempt
      StageFailureDetail {sfdErrType = failureSpec.rfsErrType, sfdErrMsg = failureSpec.rfsErrMsg}
  recordRunEvent
    env
    "stage.failed"
    Q.RunEventError
    ("Stage failed: " <> failureSpec.rfsErrMsg)
    ( Just
        ( Aeson.object
            [ "stage" Aeson..= stageName
            , "error_type" Aeson..= failureSpec.rfsErrType
            , "details" Aeson..= mDetails
            ]
        )
    )
  pure (StageTerminal OutcomeFailed)

{- | Flush accumulated rejected-rewrite inserts to the database.
Used on non-failure resolution paths (StageComplete, Degrade,
StageSuspend) where the run outcome is success — the rejected
rewrite rows are informational history, not part of a failure
transaction.  Best-effort: a failure here does not abort the
enclosing resolution.

For the exhaustion-fail path, rejected rewrites are instead
passed to 'handleRewriteAdmissionFailure' which commits them
atomically with the run failure record.
-}
flushDeferredRejections :: StageEnv -> [Q.GraphRewriteInsert] -> IO ()
flushDeferredRejections _ [] = pure ()
flushDeferredRejections env inserts = do
  result <- DB.runTransaction env.sePool $ mapM_ Q.writeGraphRewrite inserts
  case result of
    Left txErr ->
      emitObsEvent $ EvtDbCritical env.seRunId "deferred_rejection_flush" (T.pack txErr)
    Right () -> pure ()

{- | Construct a rejected rewrite insert so the caller can persist it atomically
with the terminal failure state.
-}
rejectedRewriteInsertValue
  :: StageEnv
  -> StageCall stageId
  -> RewriteBudget
  -> Aeson.Value
  -> UTCTime
  -> RewriteRejectionContext
  -> Q.GraphRewriteInsert
rejectedRewriteInsertValue env stageCall remainingBudget rewriteSpec stageEnd rejectionCtx =
  Q.GraphRewriteInsert
    { griRunId = env.seRunId
    , griSourceNodeId = unNodeId stageCall.scNodeId
    , griSourceNodeOutput = Nothing
    , griRewriteCost = Nothing
    , griRewriteDelta = Nothing
    , griBudgetBefore = Just (Aeson.toJSON remainingBudget)
    , griBudgetAfter = Nothing
    , griRewriteSpec = rewriteSpec
    , griStatus = "rejected"
    , griRejectionReason = Just rejectionCtx.rrcMessage
    , griExceededDimensions =
        if null rejectionCtx.rrcExceededDimensions
          then Nothing
          else Just (Aeson.toJSON rejectionCtx.rrcExceededDimensions)
    , griCreatedAt = stageEnd
    }

budgetContextFromBudget :: StagePlan stageId -> RewriteBudget -> BudgetContext
budgetContextFromBudget stagePlan remainingBudget =
  BudgetContext
    { bcInitialBudget = stagePlan.spInitialRewriteBudget
    , bcRemainingBudget = remainingBudget
    }

rewriteRejectionInfo :: RewriteRejectionContext -> Maybe Int -> RewriteRejectionInfo
rewriteRejectionInfo rejectionCtx maybeAttemptNumber =
  RewriteRejectionInfo
    { rrjRejectionType = rejectionCtx.rrcRejectionType
    , rrjMessage = rejectionCtx.rrcMessage
    , rrjAttemptNumber = maybeAttemptNumber
    , rrjTopologyChanged = False
    }

handleSkip
  :: StageEnv
  -> StageAttemptRef
  -> Text
  -> Map NodeId Aeson.Value
  -> StageFailure
  -> Aeson.Value
  -> UTCTime
  -> IO (StageAttemptResult stageId)
handleSkip env attemptRef stageName inputs failure skipSummary stageEnd = do
  let inputState = case Map.elems inputs of
        [v] -> v
        [] -> Aeson.Null
        _ -> Aeson.toJSON inputs
      checkpointState = buildCheckpointState env stageName inputState
  cpResult <-
    requireTx env.sePool env.seRunId "write_checkpoint"
      . DB.runTransaction env.sePool
      $ do
        Q.writeCheckpoint env.seRunId env.seTaskType stageName checkpointState (Just skipSummary) stageEnd
        Q.updateStageAttemptCompleted
          attemptRef.sarAttemptLogId
          StageFailed
          (Just (stageAttemptFailureSummary attemptRef.sarAttempt failure))
          stageEnd
        Q.updateStageCompleted attemptRef.sarLogId StageSkipped (Just skipSummary) stageEnd
  case cpResult of
    Nothing -> pure (StageTerminal OutcomeFailed)
    Just () -> do
      emitObsEvent $
        EvtStageSkipped env.seRunId stageName attemptRef.sarAttempt (stageFailureType failure)
      recordRunEvent
        env
        "stage.skipped"
        Q.RunEventWarn
        ("Stage skipped after retry exhaustion: " <> stageName)
        (Just (Aeson.object ["stage" Aeson..= stageName, "attempts" Aeson..= attemptRef.sarAttempt]))
      pure StageSkip

handleTerminalFailure
  :: StageEnv
  -> StageDefinition stageId
  -> StageAttemptRef
  -> Text
  -> StageFailure
  -> UTCTime
  -> RunFailureSpec
  -> IO (StageAttemptResult stageId)
handleTerminalFailure env stageDef attemptRef stageName failure stageEnd failureSpec = do
  let failureSummary = stageFailureSummary attemptRef.sarAttempt failure
      outcome = terminalStageOutcome failure
  stageLogResult <-
    DB.runTransaction env.sePool $ do
      Q.updateStageAttemptCompleted
        attemptRef.sarAttemptLogId
        StageFailed
        (Just (stageAttemptFailureSummary attemptRef.sarAttempt failure))
        stageEnd
      Q.updateStageCompleted attemptRef.sarLogId StageFailed (Just failureSummary) stageEnd
  case stageLogResult of
    Left stageLogErr ->
      emitObsEvent $ EvtStageLogWriteFailed env.seRunId stageName (T.pack stageLogErr)
    Right () -> pure ()
  persistTerminalStageOutcome env.sePool env.seRunId stageEnd outcome failureSpec
  emitObsEvent $
    EvtStageFailed
      env.seRunId
      stageName
      attemptRef.sarAttempt
      StageFailureDetail {sfdErrType = failureSpec.rfsErrType, sfdErrMsg = failureSpec.rfsErrMsg}
  when (stageDef.sdReplaySafety == Irreversible) $
    case failure of
      StageFailureTimeout timeoutSeconds ->
        emitObsEvent $ EvtStageTimeoutIrreversible env.seRunId stageName (fromIntegral timeoutSeconds)
      _ -> pure ()
  recordRunEvent
    env
    "stage.failed"
    Q.RunEventError
    ("Stage failed: " <> failureSpec.rfsErrMsg)
    (Just (Aeson.object ["stage" Aeson..= stageName, "error_type" Aeson..= failureSpec.rfsErrType]))
  pure (StageTerminal outcome)

buildCheckpointState :: StageEnv -> Text -> Aeson.Value -> Aeson.Value
buildCheckpointState env stageName innerState =
  Aeson.toJSON $
    buildCheckpointEnvelope
      env.seTaskType
      env.seTaskVersion
      env.seCheckpointRuntimeVersion
      stageName
      innerState

requireTx :: DB.Pool -> UUID -> Text -> IO (Either String a) -> IO (Maybe a)
requireTx pool runId context action = do
  result <- action
  case result of
    Right val -> pure (Just val)
    Left err -> do
      now <- getCurrentTime
      emitObsEvent $ EvtDbCritical runId context (T.pack err)
      failRun pool runId now "db_error" (context <> ": " <> T.pack err) True
      pure Nothing

failRun :: DB.Pool -> UUID -> UTCTime -> Text -> Text -> Bool -> IO ()
failRun pool runId now errType errMsg retryable = do
  let update =
        Q.RunFailureUpdate
          { rfuRunId = runId
          , rfuCompletedAt = now
          , rfuErrType = errType
          , rfuErrMsg = errMsg
          , rfuRetryable = retryable
          }
  result <- DB.runTransaction pool $ Q.updateRunFailed update
  case result of
    Right () -> pure ()
    Left dbErr ->
      emitObsEvent $
        EvtFailrunDb
          runId
          FailrunInfo
            { friOriginalErrorType = errType
            , friOriginalErrorMsg = errMsg
            , friDbError = T.pack dbErr
            }

timeoutRun :: DB.Pool -> UUID -> UTCTime -> Text -> Text -> IO ()
timeoutRun pool runId now errType errMsg = do
  let update =
        Q.RunTimeoutUpdate
          { rtuRunId = runId
          , rtuCompletedAt = now
          , rtuErrType = errType
          , rtuErrMsg = errMsg
          }
  result <- DB.runTransaction pool $ Q.updateRunTimedOut update
  case result of
    Right () -> pure ()
    Left dbErr ->
      emitObsEvent $
        EvtTimeoutrunDb
          runId
          FailrunInfo
            { friOriginalErrorType = errType
            , friOriginalErrorMsg = errMsg
            , friDbError = T.pack dbErr
            }

persistTerminalStageOutcome :: DB.Pool -> UUID -> UTCTime -> RunOutcome -> RunFailureSpec -> IO ()
persistTerminalStageOutcome pool runId now outcome failureSpec =
  case outcome of
    OutcomeTimedOut -> timeoutRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg
    OutcomeFailed -> failRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg failureSpec.rfsRetryable
    OutcomeShutdown -> failRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg failureSpec.rfsRetryable
    OutcomeCancelled -> failRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg failureSpec.rfsRetryable
    OutcomeCompleted -> failRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg failureSpec.rfsRetryable
    OutcomeSuspended -> failRun pool runId now failureSpec.rfsErrType failureSpec.rfsErrMsg failureSpec.rfsRetryable

failUnsupportedTaskType :: DB.Pool -> UUID -> Text -> IO RunOutcome
failUnsupportedTaskType pool runId taskType = do
  now <- getCurrentTime
  emitObsEvent $ EvtUnsupportedTaskType runId taskType
  failRun pool runId now "unsupported_task_type" ("Unsupported task type: " <> taskType) False
  pure OutcomeFailed

retryDelayMicros :: StageRetryBackoff -> Int -> Int
retryDelayMicros backoff attempt =
  case backoff of
    FixedBackoffMicros delayMicros ->
      min maxRetryDelayMicros (max 0 delayMicros)
    ExponentialBackoffMicros baseDelayMicros ->
      fromInteger $
        min
          (toInteger maxRetryDelayMicros)
          (toInteger (max 0 baseDelayMicros) * (2 ^ min 30 (max 0 (attempt - 1)) :: Integer))

maxRetryDelayMicros :: Int
maxRetryDelayMicros = 300_000_000

terminalStageOutcome :: StageFailure -> RunOutcome
terminalStageOutcome = \case
  StageFailureTimeout _ -> OutcomeTimedOut
  StageFailureException _ -> OutcomeFailed

attemptSummary :: Int -> Maybe Aeson.Value
attemptSummary attempt
  | attempt > 1 = Just $ Aeson.object ["attempts" Aeson..= attempt]
  | otherwise = Nothing

skipStageSummary :: Int -> StageFailure -> Aeson.Value
skipStageSummary attempt failure =
  Aeson.object
    [ "attempts" Aeson..= attempt
    , "skip_reason" Aeson..= ("retry_budget_exhausted" :: Text)
    , "error_type" Aeson..= stageFailureType failure
    , "error" Aeson..= stageFailureMessage failure
    ]

stageAttemptFailureSummary :: Int -> StageFailure -> Aeson.Value
stageAttemptFailureSummary attempt failure =
  Aeson.object
    [ "attempt_number" Aeson..= attempt
    , "error_type" Aeson..= stageFailureType failure
    , "error" Aeson..= stageFailureMessage failure
    ]

stageFailureSummary :: Int -> StageFailure -> Aeson.Value
stageFailureSummary attempt failure =
  Aeson.object
    [ "attempts" Aeson..= attempt
    , "error_type" Aeson..= stageFailureType failure
    , "error" Aeson..= stageFailureMessage failure
    ]

stageFailureType :: StageFailure -> Text
stageFailureType = \case
  StageFailureException _ -> "stage_failure"
  StageFailureTimeout _ -> "stage_timeout"

stageFailureMessage :: StageFailure -> Text
stageFailureMessage = \case
  StageFailureException err -> T.take 200 (T.pack (show err))
  StageFailureTimeout timeoutSeconds -> "Stage timed out after " <> T.pack (show timeoutSeconds) <> " seconds"

recordRunEvent :: StageEnv -> Text -> Q.RunEventSeverity -> Text -> Maybe Aeson.Value -> IO ()
recordRunEvent env eventType severity message details =
  Q.recordRunEvent
    env.sePool
    Q.RunEventInsert
      { reiRunId = env.seRunId
      , reiEventType = eventType
      , reiSeverity = severity
      , reiMessage = message
      , reiDetails = details
      }
