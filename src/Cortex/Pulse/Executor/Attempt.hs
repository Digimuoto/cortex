{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cortex.Pulse.Executor.Attempt
  ( attemptStage
  , withPreAttemptGuards
  )
where

import Control.Concurrent.STM (TVar, atomically, check, readTVar, readTVarIO)
import Control.Exception (SomeException, displayException, fromException, throwIO, try)
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import GHC.Conc (registerDelay)
import Rel8 (Result)
import System.Timeout (Timeout)
import System.Timeout qualified as Timeout

import Cortex.Pulse.Executor.Events (ExecutorEvent (..), StageRetryInfo (..))
import Cortex.Pulse.Executor.Persistence
  ( failRun
  , flushDeferredRejections
  , handleRewriteAdmissionFailure
  , handleSkip
  , handleTerminalFailure
  , persistStageRewrite
  , persistStageSuccess
  , recordRunEvent
  , rejectedRewriteInsertValue
  , requireTx
  , retryDelayMicros
  , rewriteRejectionInfo
  , skipStageSummary
  , stageAttemptFailureSummary
  , stageFailureMessage
  , stageFailureType
  )
import Cortex.Pulse.Executor.Types
  ( RewriteAdmissionState (..)
  , RewriteRejection (..)
  , RunFailureSpec (..)
  , StageAttemptRef (..)
  , StageAttemptResult (..)
  , StageCall (..)
  , StageEnv (..)
  , StageFailureResolution (..)
  , isWorkerCancellation
  )
import Cortex.Pulse.Plan
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite (BudgetContext (..), RewriteBudget, RewriteRejectionContext (..))
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Signal (unSignalName)

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..), StageStatus (..))
import Platform.Observability (emitObsEvent)

attemptStage
  :: StableStageId stageId
  => StageEnv
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> StageCall stageId
  -> IO (StageAttemptResult stageId)
attemptStage env task stagePlan stageCall = do
  attemptStartedAt <- getCurrentTime
  attemptLogIdResult <-
    DB.runTransaction env.sePool $
      Q.appendStageAttemptStarted
        stageCall.scLogId
        env.seRunId
        (fromIntegral stageCall.scAttempt)
        attemptStartedAt
  case attemptLogIdResult of
    Left err -> do
      emitObsEvent $ EvtStageAttemptLogFailed env.seRunId stageCall.scStageName (T.pack err)
      failRun
        env.sePool
        env.seRunId
        attemptStartedAt
        "internal_error"
        ("Stage attempt log failed: " <> T.pack err)
        False
      pure (StageTerminal OutcomeFailed)
    Right attemptLogId -> do
      currentBudget <- readTVarIO stageCall.scRewriteAdmission.rasRemainingBudget
      -- DIG-529: bind a fresh memory snapshot at stage entry.  Every
      -- read the stage makes during this attempt observes the same
      -- graph state, statuses, outputs, and timestamps; no
      -- frontier-sibling settling can bleed into the stage's view.
      initMemoryHandle <- env.seMemoryFactory
      let attemptRef =
            StageAttemptRef
              { sarLogId = stageCall.scLogId
              , sarAttemptLogId = attemptLogId
              , sarAttempt = stageCall.scAttempt
              }
          budgetCtx = budgetContextFromRemainingBudget stagePlan currentBudget
          initCtx =
            StageContext
              { scRunId = env.seRunId
              , scNodeId = stageCall.scNodeId
              , scInputs = stageCall.scInputs
              , scAttempt = stageCall.scAttempt
              , scBudgetContext = budgetCtx
              , scRewriteRejection = Nothing
              , scRetryFailure = stageCall.scRetryFailure
              , scMemory = initMemoryHandle
              , scMemoryStrategy = stageCall.scStageDef.sdMemoryStrategy
              }
      stageResult <- runStageAttempt task stageCall.scStageDef initCtx
      stageEnd <- getCurrentTime
      dispatchResult <- try $ dispatchStageResult attemptRef budgetCtx initCtx 0 [] stageEnd stageResult
      case dispatchResult of
        Right result -> pure result
        Left (e :: SomeException)
          | isWorkerCancellation e ->
              throwIO e
          | otherwise -> do
              dispatchFailedAt <- getCurrentTime
              let errText = T.pack (displayException e)
                  stageResultTag = renderStageResultTag stageResult
              recordRunEvent
                env
                "stage.dispatch_exception"
                Q.RunEventError
                ("Stage finalization threw after action returned: " <> stageCall.scStageName)
                ( Just
                    ( Aeson.object
                        [ "stage" Aeson..= stageCall.scStageName
                        , "attempt" Aeson..= stageCall.scAttempt
                        , "stage_result_tag" Aeson..= stageResultTag
                        , "error" Aeson..= errText
                        ]
                    )
                )
              handleTerminalFailure
                env
                stageCall.scStageDef
                attemptRef
                stageCall.scStageName
                (StageFailureException e)
                dispatchFailedAt
                RunFailureSpec
                  { rfsErrType = "stage_dispatch_exception"
                  , rfsErrMsg = "Stage finalization failed after action returned: " <> T.take 200 errText
                  , rfsRetryable = False
                  }
  where
    -- Dispatch stage results with an accumulator for deferred rejected-rewrite
    -- inserts.  Rejections are accumulated (newest-first via (:)) through
    -- re-execution iterations and flushed in chronological order (reverse)
    -- at the attempt resolution boundary.
    dispatchStageResult attemptRef budgetCtx ctx reExecCount deferredRejections stageEnd = \case
      Right (StageComplete newOutput) -> do
        flushDeferredRejections env (reverse deferredRejections)
        persistStageSuccess env attemptRef stageCall.scNodeId stageCall.scStageName stageEnd newOutput
      Right (StageRejectRewrite newOutput rejected) -> do
        let rejectionCtx =
              RewriteRejectionContext
                { rrcRejectionType = rejected.srrRejectionType
                , rrcMessage = rejected.srrMessage
                , rrcExceededDimensions = []
                , rrcBudgetContext = budgetCtx
                , rrcAttemptedCost = Nothing
                , rrcAttemptNumber = 0
                }
            rejection =
              RewriteRejection
                { rrLastOutput = newOutput
                , rrContext = rejectionCtx
                , rrDeferredInsert =
                    rejectedRewriteInsertValue
                      env
                      stageCall
                      budgetCtx.bcRemainingBudget
                      (fromMaybe Aeson.Null rejected.srrRejectedSpec)
                      stageEnd
                      rejectionCtx
                }
        handleRejectedRewrite attemptRef budgetCtx ctx reExecCount deferredRejections stageEnd rejection
      Right (StageRewrite newOutput rewrite) -> do
        result <- persistStageRewrite env stagePlan stageCall attemptRef stageEnd newOutput rewrite
        case result of
          StageRewriteRejected rejection ->
            handleRejectedRewrite attemptRef budgetCtx ctx reExecCount deferredRejections stageEnd rejection
          other -> do
            flushDeferredRejections env (reverse deferredRejections)
            pure other
      Right (StageSuspend signalName) -> do
        flushDeferredRejections env (reverse deferredRejections)
        attemptResult <-
          DB.runTransaction env.sePool $
            Q.updateStageAttemptCompleted
              attemptRef.sarAttemptLogId
              StageCompleted
              (Just (Aeson.object ["suspended_on" Aeson..= unSignalName signalName]))
              stageEnd
        case attemptResult of
          Left err ->
            emitObsEvent $ EvtStageAttemptSuspendWriteFailed env.seRunId stageCall.scStageName (T.pack err)
          Right () -> pure ()
        pure (StageSuspended signalName)
      Left failure -> do
        flushDeferredRejections env (reverse deferredRejections)
        case resolveStageFailure stageCall.scStageDef stageCall.scAttempt failure of
          RetryStageAfter delayMicros ->
            handleRetry env task stagePlan stageCall attemptRef failure delayMicros stageEnd
          SkipStageAfterExhaustion skipSummary ->
            handleSkip env attemptRef stageCall.scStageName stageCall.scInputs failure skipSummary stageEnd
          FailRunAfterExhaustion failureSpec ->
            handleTerminalFailure
              env
              stageCall.scStageDef
              attemptRef
              stageCall.scStageName
              failure
              stageEnd
              failureSpec

    handleRejectedRewrite attemptRef budgetCtx ctx reExecCount deferredRejections stageEnd rejection = do
      let rejectionCtx = rejection.rrContext {rrcBudgetContext = budgetCtx, rrcAttemptNumber = reExecCount + 1}
          rejection' = rejection {rrContext = rejectionCtx}
      emitObsEvent $
        EvtRewriteRejected
          env.seRunId
          stageCall.scStageName
          (rewriteRejectionInfo rejectionCtx (Just rejectionCtx.rrcAttemptNumber))
      if reExecCount < stagePlan.spMaxRewriteReExecutions
        then do
          let deferredRejections' = rejection'.rrDeferredInsert : deferredRejections
          guardCheck <- withPreAttemptGuards env stageCall.scStageName (pure (StageAdvance Aeson.Null))
          case guardCheck of
            StageTerminal outcome -> do
              flushDeferredRejections env (reverse deferredRejections')
              abortedAt <- getCurrentTime
              _ <-
                DB.runTransaction env.sePool $ do
                  Q.updateStageAttemptCompleted
                    attemptRef.sarAttemptLogId
                    StageFailed
                    (Just (Aeson.String "Aborted before rewrite re-execution"))
                    abortedAt
                  Q.updateStageCompleted
                    attemptRef.sarLogId
                    StageFailed
                    (Just (Aeson.String "Aborted before rewrite re-execution"))
                    abortedAt
              pure (StageTerminal outcome)
            _ -> do
              emitObsEvent $ EvtRewriteReExecution env.seRunId stageCall.scStageName rejectionCtx.rrcAttemptNumber
              reRemainingBudget <- readTVarIO stageCall.scRewriteAdmission.rasRemainingBudget
              -- Re-execution is a new stage entry: bind a fresh
              -- memory snapshot so the re-run sees state as of
              -- re-entry, not the original attempt.
              reMemoryHandle <- env.seMemoryFactory
              let reBudgetCtx = budgetContextFromRemainingBudget stagePlan reRemainingBudget
                  reCtx =
                    ctx
                      { scAttempt = stageCall.scAttempt
                      , scBudgetContext = reBudgetCtx
                      , scRewriteRejection = Just rejectionCtx
                      , scMemory = reMemoryHandle
                      }
              reResult <- runStageAttempt task stageCall.scStageDef reCtx
              reEnd <- getCurrentTime
              dispatchStageResult
                attemptRef
                reBudgetCtx
                reCtx
                (reExecCount + 1)
                deferredRejections'
                reEnd
                reResult
        else
          let allRejections = reverse (rejection'.rrDeferredInsert : deferredRejections)
           in applyExhaustionPolicy env stagePlan stageCall attemptRef stageEnd allRejections rejection'

    renderStageResultTag :: Either StageFailure (StageResult stageId) -> Text
    renderStageResultTag = \case
      Left (StageFailureException _) -> "failure_exception"
      Left (StageFailureTimeout _) -> "failure_timeout"
      Right (StageComplete _) -> "complete"
      Right (StageSuspend _) -> "suspend"
      Right (StageRewrite _ _) -> "rewrite"
      Right (StageRejectRewrite _ _) -> "reject_rewrite"

applyExhaustionPolicy
  :: StageEnv
  -> StagePlan stageId
  -> StageCall stageId
  -> StageAttemptRef
  -> UTCTime
  -> [Q.GraphRewriteInsert]
  -> RewriteRejection
  -> IO (StageAttemptResult stageId)
applyExhaustionPolicy env stagePlan stageCall attemptRef stageEnd deferredInserts rejection =
  case exhaustionPolicyForRejection stagePlan rejection of
    RewriteExhaustionFail ->
      -- Rejected rewrites commit atomically with the failure record.
      handleRewriteAdmissionFailure
        env
        attemptRef
        stageCall.scStageName
        stageEnd
        ( RunFailureSpec
            "rewrite_exhaustion"
            ( "Max re-executions reached after "
                <> rejection.rrContext.rrcRejectionType
                <> ": "
                <> rejection.rrContext.rrcMessage
            )
            False
        )
        ( Just
            ( Aeson.object
                [ "rejection_type" Aeson..= rejection.rrContext.rrcRejectionType
                , "rejection_message" Aeson..= rejection.rrContext.rrcMessage
                , "exceeded_dimensions" Aeson..= rejection.rrContext.rrcExceededDimensions
                , "attempted_cost" Aeson..= rejection.rrContext.rrcAttemptedCost
                , "max_re_executions" Aeson..= stagePlan.spMaxRewriteReExecutions
                ]
            )
        )
        deferredInserts
    RewriteExhaustionDegrade -> do
      -- Run succeeds with degraded output; rejections are best-effort history.
      flushDeferredRejections env deferredInserts
      recordRunEvent
        env
        "stage.rewrite_degraded"
        Q.RunEventWarn
        ("Stage accepted degraded output after rewrite exhaustion: " <> stageCall.scStageName)
        ( Just
            ( Aeson.object
                [ "stage" Aeson..= stageCall.scStageName
                , "rejection_type" Aeson..= rejection.rrContext.rrcRejectionType
                , "budget_context" Aeson..= rejection.rrContext.rrcBudgetContext
                ]
            )
        )
      persistStageSuccess
        env
        attemptRef
        stageCall.scNodeId
        stageCall.scStageName
        stageEnd
        rejection.rrLastOutput

budgetContextFromRemainingBudget :: StagePlan stageId -> RewriteBudget -> BudgetContext
budgetContextFromRemainingBudget stagePlan remainingBudget =
  BudgetContext
    { bcInitialBudget = stagePlan.spInitialRewriteBudget
    , bcRemainingBudget = remainingBudget
    }

exhaustionPolicyForRejection :: StagePlan stageId -> RewriteRejection -> RewriteExhaustionPolicy
exhaustionPolicyForRejection stagePlan rejection
  | rejection.rrContext.rrcRejectionType == "rewrite_budget_exceeded" =
      fromMaybe stagePlan.spRewriteExhaustionPolicy stagePlan.spBudgetExceededExhaustionPolicy
  | otherwise =
      stagePlan.spRewriteExhaustionPolicy

withPreAttemptGuards
  :: StageEnv -> Text -> IO (StageAttemptResult stageId) -> IO (StageAttemptResult stageId)
withPreAttemptGuards env stageName continue = do
  shouldStop <- readTVarIO env.seShutdownFlag
  if shouldStop
    then do
      emitObsEvent $ EvtShutdownRequested env.seRunId stageName
      recordRunEvent
        env
        "run.shutdown"
        Q.RunEventInfo
        "Shutdown requested, stopping at stage boundary"
        (Just (Aeson.object ["before_stage" Aeson..= stageName]))
      pure (StageTerminal OutcomeShutdown)
    else do
      cancelResult <- DB.withConnection env.sePool $ Q.checkCancellation env.seRunId
      case cancelResult of
        Right True -> do
          now <- getCurrentTime
          cancelWriteResult <-
            DB.runTransaction env.sePool $
              Q.updateRunCancelled env.seRunId now "cancel_requested_at was set"
          case cancelWriteResult of
            Left err ->
              emitObsEvent $ EvtCancelWriteFailed env.seRunId (T.pack err)
            Right () -> pure ()
          emitObsEvent $ EvtTaskCancelled env.seRunId stageName
          recordRunEvent
            env
            "run.cancelled"
            Q.RunEventInfo
            "Task cancelled by operator"
            (Just (Aeson.object ["before_stage" Aeson..= stageName]))
          pure (StageTerminal OutcomeCancelled)
        Left err -> do
          emitObsEvent $ EvtCancelCheckFailed env.seRunId stageName (T.pack err)
          continue
        Right False ->
          continue

handleRetry
  :: StableStageId stageId
  => StageEnv
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> StageCall stageId
  -> StageAttemptRef
  -> StageFailure
  -> Int
  -> UTCTime
  -> IO (StageAttemptResult stageId)
handleRetry env task stagePlan stageCall attemptRef failure delayMicros stageEnd = do
  attemptAuditResult <-
    requireTx env.sePool env.seRunId "update_stage_attempt_failed"
      . DB.runTransaction env.sePool
      $ Q.updateStageAttemptCompleted
        attemptRef.sarAttemptLogId
        StageFailed
        (Just (stageAttemptFailureSummary attemptRef.sarAttempt failure))
        stageEnd
  case attemptAuditResult of
    Nothing -> pure (StageTerminal OutcomeFailed)
    Just () -> do
      emitObsEvent $
        EvtStageRetry
          env.seRunId
          StageRetryInfo
            { sriStageName = stageCall.scStageName
            , sriAttempt = stageCall.scAttempt
            , sriNextAttempt = stageCall.scAttempt + 1
            , sriRetryDelayMicros = fromIntegral delayMicros
            , sriErrorType = stageFailureType failure
            , sriErrorMessage = stageFailureMessage failure
            }
      awaitDelayOrShutdown env.seShutdownFlag delayMicros
      let retryStageCall =
            StageCall
              { scRemainingBudget = stageCall.scRemainingBudget
              , scRewriteAdmission = stageCall.scRewriteAdmission
              , scNodeId = stageCall.scNodeId
              , scStageDef = stageCall.scStageDef
              , scStageName = stageCall.scStageName
              , scInputs = stageCall.scInputs
              , scLogId = stageCall.scLogId
              , scAttempt = stageCall.scAttempt + 1
              , scRetryFailure =
                  Just
                    StageRetryFailureContext
                      { srfcPreviousAttempt = stageCall.scAttempt
                      , srfcFailureType = stageFailureType failure
                      , srfcFailureMessage = stageFailureMessage failure
                      }
              }
      retryResult <-
        withPreAttemptGuards env stageCall.scStageName $
          attemptStage env task stagePlan retryStageCall
      case retryResult of
        StageTerminal OutcomeCancelled -> do
          cancelledAt <- getCurrentTime
          result <-
            DB.runTransaction env.sePool $
              Q.updateStageCompleted
                attemptRef.sarLogId
                StageFailed
                (Just (Aeson.String "Cancelled before retry attempt"))
                cancelledAt
          case result of
            Left err ->
              recordRunEvent
                env
                "stage.cancel_before_retry_persist_failed"
                Q.RunEventWarn
                ("Failed to persist cancel-before-retry: " <> T.pack err)
                Nothing
            Right _ -> pure ()
        _ -> pure ()
      pure retryResult

awaitDelayOrShutdown :: TVar Bool -> Int -> IO ()
awaitDelayOrShutdown shutdownFlag delayMicros =
  when (delayMicros > 0) $ do
    delayExpired <- registerDelay delayMicros
    atomically $ do
      expired <- readTVar delayExpired
      stopped <- readTVar shutdownFlag
      check (expired || stopped)

resolveStageFailure :: StageDefinition stageId -> Int -> StageFailure -> StageFailureResolution
resolveStageFailure stageDef attempt failure =
  case stageDef.sdRetryPolicy of
    Nothing ->
      FailRunAfterExhaustion
        (RunFailureSpec (stageFailureType failure) (stageFailureMessage failure) True)
    Just retryPolicy ->
      let maxAttempts = max 1 retryPolicy.srpMaxAttempts
          retryable = retryPolicy.srpRetryable failure
       in if retryable && attempt < maxAttempts
            then RetryStageAfter (retryDelayMicros retryPolicy.srpBackoff attempt)
            else case (retryable, retryPolicy.srpExhaustion) of
              (True, ExhaustionSkipsStage) ->
                SkipStageAfterExhaustion (skipStageSummary attempt failure)
              _ ->
                FailRunAfterExhaustion
                  (RunFailureSpec (stageFailureType failure) (stageFailureMessage failure) retryable)

runStageAttempt
  :: PulseTaskDefinitionRow Result
  -> StageDefinition stageId
  -> StageContext
  -> IO (Either StageFailure (StageResult stageId))
runStageAttempt task stageDef ctx =
  case effectiveStageTimeoutSeconds task stageDef of
    Nothing -> tryAction Nothing
    Just timeoutSeconds -> do
      timeoutResult <-
        Timeout.timeout (fromIntegral timeoutSeconds * 1_000_000) (tryAction (Just timeoutSeconds))
      case timeoutResult of
        Nothing -> pure (Left (StageFailureTimeout timeoutSeconds))
        Just result -> pure result
  where
    tryAction maybeTimeoutSeconds = do
      stageResult <- try (stageDef.sdAction ctx)
      case stageResult of
        Left (e :: SomeException)
          | Just (_ :: Timeout) <- fromException e
          , Just timeoutSeconds <- maybeTimeoutSeconds ->
              pure (Left (StageFailureTimeout timeoutSeconds))
          | isWorkerCancellation e ->
              throwIO e
          | otherwise ->
              pure (Left (StageFailureException e))
        Right sr ->
          pure (Right sr)

effectiveStageTimeoutSeconds
  :: PulseTaskDefinitionRow Result -> StageDefinition stageId -> Maybe Int32
effectiveStageTimeoutSeconds task stageDef =
  case stageDef.sdTimeoutSeconds of
    Just timeoutSeconds
      | timeoutSeconds > 0 -> Just timeoutSeconds
    _ | task.timeoutSeconds > 0 -> Just task.timeoutSeconds
    _ -> Nothing
