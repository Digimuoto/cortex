{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cortex.Pulse.Executor.Frontier
  ( runFrontierSequential,
    runFrontierConcurrent,
    resolveDeliveredSignals,
  )
where

import Control.Concurrent.Async (Async, async, cancel, waitAnyCatch)
import Control.Concurrent.MVar (newMVar)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, bracket_, displayException, mask, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Cortex.Graph (Relation)
import Cortex.Pulse.Executor.Attempt
  ( attemptStage,
    withPreAttemptGuards,
  )
import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Persistence
  ( failRun,
    persistGraphState,
    recordRunEvent,
    requireGraphStatePersist,
  )
import Cortex.Pulse.Executor.Types
  ( RewriteAdmissionState (..),
    StageAttemptResult (..),
    StageCall (..),
    StageEnv (..),
    isWorkerCancellation,
  )
import Cortex.Pulse.GraphRuntime
  ( BlockedReason (..),
    FailureDetail (..),
    GraphState (..),
    NodeOutcome (..),
    NodeResult (..),
    NodeStatus (..),
    StepResult (..),
    applyFrontierResults,
    applyNodeFact,
    blockedReasons,
    classifyGraphState,
    markCompleted,
    markRunning,
    nodeInputsWithDefault,
    runOutcomeToNodeOutcome,
    runTerminal,
    stepResultState,
  )
import Cortex.Pulse.Materialization
  ( PersistedGraphState (..),
    PersistedRewrite (..),
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
import Cortex.Pulse.PlanHydration (toSerializableStageDefinition)
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite (RewriteBudget)
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Signal (unSignalName)
import Data.Aeson qualified as Aeson
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)
import Rel8 (Result)

-- | Use the materialized node identity as the durable stage identity for
-- graph execution. NodeId survives namespacing, rewrites, resume, stage logs,
-- audit writes, and replay-policy enforcement.
graphStageName :: NodeId -> T.Text
graphStageName = unNodeId

data WorkerHandle stageId = WorkerHandle
  { whNodeId :: !NodeId,
    whAsync :: !(Async (NodeResult, Maybe (PersistedRewrite stageId)))
  }

workerExceptionResult :: NodeId -> SomeException -> (NodeResult, Maybe (PersistedRewrite stageId))
workerExceptionResult nid e
  | isWorkerCancellation e = (NodeResult nid OutcomeNodeCancelled, Nothing)
  | otherwise =
      (NodeResult nid (OutcomeNodeFailed (FailureDetail "worker_exception" (T.pack (displayException e)) True)), Nothing)

markTerminalOutcome :: TVar Bool -> NodeOutcome -> IO ()
markTerminalOutcome terminalFlag = \case
  OutcomeNodeFailed _ -> atomically $ writeTVar terminalFlag True
  OutcomeNodeTimedOut -> atomically $ writeTVar terminalFlag True
  OutcomeNodeShutdown -> atomically $ writeTVar terminalFlag True
  OutcomeNodeRunCancelled -> atomically $ writeTVar terminalFlag True
  _ -> pure ()

takeCompletedWorker ::
  Async (NodeResult, Maybe (PersistedRewrite stageId)) ->
  [WorkerHandle stageId] ->
  (Maybe (WorkerHandle stageId), [WorkerHandle stageId])
takeCompletedWorker completed = go []
  where
    go acc [] = (Nothing, reverse acc)
    go acc (worker : rest)
      | whAsync worker == completed = (Just worker, reverse acc <> rest)
      | otherwise = go (worker : acc) rest

-- | Open or reuse a stage log, then delegate to 'attemptStage'.
executeStage ::
  (StableStageId stageId) =>
  StageEnv ->
  PulseTaskDefinitionRow Result ->
  StagePlan stageId ->
  RewriteAdmissionState ->
  RewriteBudget ->
  NodeId ->
  StageDefinition stageId ->
  T.Text ->
  Map NodeId Aeson.Value ->
  IO (StageAttemptResult stageId)
executeStage env task stagePlan rewriteAdmission remainingBudget nid stageDef stageName inputs = do
  now <- getCurrentTime
  stageAuditResult <-
    DB.runTransaction env.sePool $ do
      maybeLogId <- Q.findOpenStageLogId env.seRunId stageName
      logId <- maybe (Q.appendStageStarted env.seRunId stageName now) pure maybeLogId
      nextAttemptNumber <- Q.getNextStageAttemptNumber logId
      pure (logId, nextAttemptNumber, isJust maybeLogId)
  case stageAuditResult of
    Left err -> do
      emitObsEvent $ EvtStageLogFailed env.seRunId stageName (T.pack err)
      failRun env.sePool env.seRunId now "internal_error" ("Stage log failed: " <> T.pack err) False
      pure (StageTerminal OutcomeFailed)
    Right (logId, nextAttemptNumber, reusedOpenLog) -> do
      when reusedOpenLog . emitObsEvent $
        EvtStageResumed env.seRunId stageName logId (fromIntegral nextAttemptNumber)
      attemptStage
        env
        task
        stagePlan
        StageCall
          { scRemainingBudget = remainingBudget,
            scRewriteAdmission = rewriteAdmission,
            scNodeId = nid,
            scStageDef = stageDef,
            scStageName = stageName,
            scInputs = inputs,
            scLogId = logId,
            scAttempt = fromIntegral nextAttemptNumber,
            scRetryFailure = Nothing
          }

-- | Execute a single node and produce a NodeResult. The worker receives
-- immutable inputs (pre-computed from the graph state snapshot) and has
-- no access to the shared TVar. Side effects are limited to the stage
-- action itself and signal registration.
executeNodeWorker ::
  (StableStageId stageId) =>
  StageEnv ->
  PulseTaskDefinitionRow Result ->
  StagePlan stageId ->
  RewriteAdmissionState ->
  RewriteBudget ->
  NodeId ->
  Map NodeId Aeson.Value ->
  IO (NodeResult, Maybe (PersistedRewrite stageId))
executeNodeWorker env task stagePlan rewriteAdmission remainingBudget nid inputs = do
  case Map.lookup nid (spDefinitions stagePlan) of
    Nothing -> do
      now <- getCurrentTime
      failRun env.sePool env.seRunId now "internal_error" ("Node not found in graph: " <> unNodeId nid) False
      pure (NodeResult nid (OutcomeNodeFailed (FailureDetail "internal_error" ("Node not found: " <> unNodeId nid) False)), Nothing)
    Just stageDef -> do
      let stageName = graphStageName nid
      result <-
        withPreAttemptGuards env stageName $
          executeStage env task stagePlan rewriteAdmission remainingBudget nid stageDef stageName inputs
      case result of
        StageAdvance newOutput ->
          pure (NodeResult nid (OutcomeSucceeded newOutput), Nothing)
        StageAdvanceWithRewrite newOutput persistedRewrite -> do
          let serializableRewrite = fmap toSerializableStageDefinition persistedRewrite.prRewrite
          pure (NodeResult nid (OutcomeRewritten newOutput (Aeson.toJSON serializableRewrite)), Just persistedRewrite)
        StageSkip ->
          pure (NodeResult nid OutcomeSkipped, Nothing)
        StageSuspended signalName -> do
          now <- getCurrentTime
          suspendResult <-
            DB.runTransaction env.sePool $
              Q.registerSignalWait env.seRunId nid signalName now Nothing
          case suspendResult of
            Left err -> do
              emitObsEvent $ EvtSuspendWriteFailed env.seRunId (unSignalName signalName) (T.pack err)
              now' <- getCurrentTime
              failRun env.sePool env.seRunId now' "signal_registration_failed" ("Failed to register signal wait: " <> T.pack err) True
              pure (NodeResult nid (OutcomeNodeFailed (FailureDetail "signal_registration_failed" ("Failed to register signal wait: " <> T.pack err) True)), Nothing)
            Right () ->
              pure (NodeResult nid (OutcomeSuspendedOn (unSignalName signalName)), Nothing)
        StageTerminal outcome ->
          pure (NodeResult nid (runOutcomeToNodeOutcome outcome), Nothing)
        StageRewriteRejected {} -> do
          -- StageRewriteRejected should never propagate to the frontier level;
          -- attemptStage resolves it via the re-execution loop.
          now <- getCurrentTime
          failRun env.sePool env.seRunId now "internal_error" "StageRewriteRejected reached frontier (bug)" False
          pure (NodeResult nid (OutcomeNodeFailed (FailureDetail "internal_error" "StageRewriteRejected reached frontier" False)), Nothing)

computeNodeInputs :: StagePlan stageId -> GraphState Aeson.Value -> NodeId -> Map NodeId Aeson.Value
computeNodeInputs stagePlan gs =
  nodeInputsWithDefault stagePlan.spTopology gs stagePlan.spInitialState

runFrontierSequential ::
  (StableStageId stageId) =>
  StageEnv ->
  PulseTaskDefinitionRow Result ->
  StagePlan stageId ->
  TVar PersistedGraphState ->
  [NodeId] ->
  IO (Maybe (Either RunOutcome [PersistedRewrite stageId]))
runFrontierSequential _ _ _ _ [] = pure Nothing
runFrontierSequential env task stagePlan gsVar (nid : rest) = do
  persistedState <- readTVarIO gsVar
  let gs = persistedState.pgsGraphState
  case Map.lookup nid (gsNodeStatuses gs) of
    Just NodePending -> do
      let inputs = computeNodeInputs stagePlan gs nid
      let runningState =
            persistedState {pgsGraphState = markRunning nid persistedState.pgsGraphState}
      atomically $ writeTVar gsVar runningState
      -- Persist running state so the API can report it during execution.
      -- Abort on failure, matching the concurrent frontier pattern.
      markRunningFailed <- requireGraphStatePersist env runningState
      case markRunningFailed of
        Just outcome -> pure (Just (Left outcome))
        Nothing -> do
          budgetRef <- newTVarIO persistedState.pgsRemainingRewriteBudget
          admissionLock <- newMVar ()
          let rewriteAdmission =
                RewriteAdmissionState
                  { rasRemainingBudget = budgetRef,
                    rasAdmissionLock = admissionLock
                  }
          (nodeResult, mRewrite) <- executeNodeWorker env task stagePlan rewriteAdmission persistedState.pgsRemainingRewriteBudget nid inputs
          recordUnexpectedNodeFailure env nodeResult
          -- Re-read current state after worker completes so we apply results
          -- against the running-marked state, not the stale pre-mark snapshot.
          current <- readTVarIO gsVar
          let gsCurrent = current.pgsGraphState
          case runTerminal (nrOutcome nodeResult) of
            Just termOutcome -> do
              let stepResult = applyFrontierResults stagePlan.spTopology [nodeResult] gsCurrent
                  persistedState' = current {pgsGraphState = stepResultState stepResult}
              atomically $ writeTVar gsVar persistedState'
              persistFailed <- requireGraphStatePersist env persistedState'
              pure (Just (Left (fromMaybe termOutcome persistFailed)))
            Nothing -> do
              let stepResult = applyFrontierResults stagePlan.spTopology [nodeResult] gsCurrent
                  persistedState' = current {pgsGraphState = stepResultState stepResult}
              atomically $ writeTVar gsVar persistedState'
              persistFailed <- requireGraphStatePersist env persistedState'
              case persistFailed of
                Just outcome -> pure (Just (Left outcome))
                Nothing ->
                  case mRewrite of
                    Just rewrite ->
                      pure (Just (Right [rewrite]))
                    Nothing ->
                      case stepResult of
                        Progressing {} ->
                          runFrontierSequential env task stagePlan gsVar rest
                        Settled _ outcome ->
                          pure (Just (Left outcome))
                        Suspended _ ->
                          pure (Just (Left OutcomeSuspended))
                        Stuck {} ->
                          pure Nothing
    _ ->
      runFrontierSequential env task stagePlan gsVar rest

-- | Spawn a semaphore-bounded async worker for a single node.  The worker
-- checks the terminal flag before running and sets it when the node produces
-- a terminal outcome (failed, timed-out, shutdown, cancelled).
spawnNodeWorker ::
  (StableStageId stageId) =>
  StageEnv ->
  PulseTaskDefinitionRow Result ->
  StagePlan stageId ->
  RewriteAdmissionState ->
  RewriteBudget ->
  TVar Bool ->
  QSem ->
  Map NodeId (Map NodeId Aeson.Value) ->
  NodeId ->
  IO (WorkerHandle stageId)
spawnNodeWorker env task stagePlan rewriteAdmission budget terminalFlag sem inputsMap nid = do
  let nodeInputs' = Map.findWithDefault Map.empty nid inputsMap
  -- Mask startup so cancellation cannot land before the outer try is installed.
  -- That keeps worker exceptions reified as node results even when cancel races
  -- with a freshly spawned async.
  workerAsync <-
    async
      ( mask $ \restore -> do
          outerResult <-
            (try . restore)
              ( bracket_ (waitQSem sem) (signalQSem sem) $ do
                  cancelled <- readTVarIO terminalFlag
                  if cancelled
                    then pure (NodeResult nid OutcomeNodeCancelled, Nothing)
                    else do
                      result <- try (executeNodeWorker env task stagePlan rewriteAdmission budget nid nodeInputs')
                      pure $
                        case result of
                          Left (e :: SomeException) -> workerExceptionResult nid e
                          Right r -> r
              )
          let workerResult =
                case outerResult of
                  Right r -> r
                  Left (e :: SomeException) -> workerExceptionResult nid e
              (nr, _) = workerResult
          markTerminalOutcome terminalFlag nr.nrOutcome
          pure workerResult
      )
  pure WorkerHandle {whNodeId = nid, whAsync = workerAsync}

-- | Wait on all async handles, applying each completed node result to the
-- shared graph state and persisting incrementally.
--
-- 'spawnNodeWorker' masks startup so the outer 'try' is installed before
-- cancellation can arrive.  If an async still escapes, reify it into a node
-- result here so we never leave the frontier with a stale 'NodeRunning' fact.
collectWorkerResults ::
  StageEnv ->
  TVar PersistedGraphState ->
  TVar Bool ->
  TVar (Maybe T.Text) ->
  [WorkerHandle stageId] ->
  [(NodeResult, Maybe (PersistedRewrite stageId))] ->
  IO [(NodeResult, Maybe (PersistedRewrite stageId))]
collectWorkerResults _ _ _ _ [] acc = pure (reverse acc)
collectWorkerResults env gsVar terminalFlag persistFailRef remaining acc = do
  (completed, result) <- waitAnyCatch (fmap whAsync remaining)
  let (mCompletedWorker, remaining') = takeCompletedWorker completed remaining
  case result of
    Right (nr, mRewrite) -> do
      recordUnexpectedNodeFailure env nr
      atomically . modifyTVar' gsVar $
        \s -> s {pgsGraphState = applyNodeFact nr s.pgsGraphState}
      currentState <- readTVarIO gsVar
      persistResult <- persistGraphState env currentState
      case persistResult of
        Left err -> do
          atomically $ writeTVar persistFailRef (Just err)
          atomically $ writeTVar terminalFlag True
        Right () -> pure ()
      collectWorkerResults env gsVar terminalFlag persistFailRef remaining' ((nr, mRewrite) : acc)
    Left ex ->
      case mCompletedWorker of
        Just worker -> do
          let (nr, mRewrite) = workerExceptionResult worker.whNodeId ex
          recordRunEvent
            env
            "stage.worker_exception_reified"
            Q.RunEventError
            ( "Async worker exception escaped spawnNodeWorker; reifying node result for "
                <> graphStageName worker.whNodeId
                <> ": "
                <> T.pack (displayException ex)
            )
            Nothing
          markTerminalOutcome terminalFlag nr.nrOutcome
          atomically . modifyTVar' gsVar $
            \s -> s {pgsGraphState = applyNodeFact nr s.pgsGraphState}
          currentState <- readTVarIO gsVar
          persistResult <- persistGraphState env currentState
          case persistResult of
            Left err -> do
              atomically $ writeTVar persistFailRef (Just err)
              atomically $ writeTVar terminalFlag True
            Right () -> pure ()
          collectWorkerResults env gsVar terminalFlag persistFailRef remaining' ((nr, mRewrite) : acc)
        Nothing -> do
          recordRunEvent
            env
            "stage.worker_exception_unattributed"
            Q.RunEventError
            ("Async worker exception escaped spawnNodeWorker but no matching worker handle was found: " <> T.pack (displayException ex))
            Nothing
          atomically $ writeTVar terminalFlag True
          collectWorkerResults env gsVar terminalFlag persistFailRef remaining' acc

-- | Classify the graph after a concurrent frontier completes.  Persists the
-- classified state when it differs from the raw accumulated state, then
-- determines the overall frontier outcome.
classifyFrontierOutcome ::
  StageEnv ->
  Relation NodeId ->
  TVar PersistedGraphState ->
  [(NodeResult, Maybe (PersistedRewrite stageId))] ->
  IO (Maybe (Either RunOutcome [PersistedRewrite stageId]))
classifyFrontierOutcome env topology gsVar results = do
  currentState <- readTVarIO gsVar
  let gs1 = currentState.pgsGraphState
      stepResult = classifyGraphState topology gs1
      gs' = stepResultState stepResult
      failedNodeIds =
        [ unNodeId nid
        | (nid, NodeFailed) <- Map.toList gs'.gsNodeStatuses
        ]
      blockedOnFailedDetails =
        [ Aeson.object ["node" Aeson..= unNodeId nid, "blocked_by" Aeson..= fmap unNodeId failedPreds]
        | (nid, BlockedByFailed failedPreds) <- blockedReasons topology gs'
        ]
  atomically $ writeTVar gsVar (currentState {pgsGraphState = gs'})
  unless (null failedNodeIds) $
    recordRunEvent
      env
      "frontier.settled_failed"
      Q.RunEventError
      "Frontier classified failed nodes"
      ( Just
          ( Aeson.object
              [ "failed_nodes" Aeson..= failedNodeIds,
                "blocked_on_failed" Aeson..= blockedOnFailedDetails
              ]
          )
      )
  classifyPersistFailed <-
    if gs' /= gs1
      then requireGraphStatePersist env (currentState {pgsGraphState = gs'})
      else pure Nothing
  let nodeResults = fmap fst results
      rewriteResults = sortOn prRewriteId [rewrite | (_, Just rewrite) <- results]
      terminalOutcomes = [outcome | nr <- nodeResults, Just outcome <- [runTerminal nr.nrOutcome]]
      settledFailure =
        case stepResult of
          Settled _ OutcomeFailed -> Just OutcomeFailed
          _ -> Nothing
  pure $
    case classifyPersistFailed of
      Just outcome -> Just (Left outcome)
      Nothing ->
        case terminalOutcomes of
          outcome : _ -> Just (Left outcome)
          [] ->
            case settledFailure of
              Just outcome -> Just (Left outcome)
              Nothing ->
                case rewriteResults of
                  [] ->
                    case stepResult of
                      Progressing {} -> Nothing
                      Settled _ outcome -> Just (Left outcome)
                      Suspended _ -> Just (Left OutcomeSuspended)
                      Stuck {} -> Nothing
                  _ -> Just (Right rewriteResults)

runFrontierConcurrent ::
  (StableStageId stageId) =>
  StageEnv ->
  PulseTaskDefinitionRow Result ->
  StagePlan stageId ->
  TVar PersistedGraphState ->
  [NodeId] ->
  IO (Maybe (Either RunOutcome [PersistedRewrite stageId]))
runFrontierConcurrent env task stagePlan gsVar readyNodeIds = do
  let frontierSize = length readyNodeIds
      cap = max 1 env.seMaxFrontierConcurrency
      topology = stagePlan.spTopology
  frontierStart <- getCurrentTime
  emitObsEvent $ EvtFrontierStart env.seRunId frontierSize cap
  persistedState <- readTVarIO gsVar
  let gs = persistedState.pgsGraphState
      pendingNodeIds =
        filter
          (\nid -> Map.lookup nid gs.gsNodeStatuses == Just NodePending)
          readyNodeIds
      inputsMap = Map.fromList [(nid, computeNodeInputs stagePlan gs nid) | nid <- pendingNodeIds]
      markRunningState =
        persistedState
          { pgsGraphState =
              foldl' (flip markRunning) gs pendingNodeIds
          }
  atomically $ writeTVar gsVar markRunningState
  markRunningFailed <- requireGraphStatePersist env markRunningState
  case markRunningFailed of
    Just outcome -> pure (Just (Left outcome))
    Nothing -> do
      preCheckResult <- withPreAttemptGuards env "frontier" (pure (StageAdvance Aeson.Null))
      case preCheckResult of
        StageTerminal termOutcome -> do
          let cancelResults = [NodeResult nid OutcomeNodeCancelled | nid <- pendingNodeIds]
              persistedState' =
                persistedState
                  { pgsGraphState = stepResultState (applyFrontierResults topology cancelResults gs)
                  }
          atomically $ writeTVar gsVar persistedState'
          persistFailed <- requireGraphStatePersist env persistedState'
          pure (Just (Left (fromMaybe termOutcome persistFailed)))
        _ -> do
          sem <- newQSem cap
          budgetRef <- newTVarIO persistedState.pgsRemainingRewriteBudget
          admissionLock <- newMVar ()
          let rewriteAdmission =
                RewriteAdmissionState
                  { rasRemainingBudget = budgetRef,
                    rasAdmissionLock = admissionLock
                  }
          terminalFlag <- newTVarIO False
          asyncHandles <-
            forM pendingNodeIds $
              spawnNodeWorker env task stagePlan rewriteAdmission persistedState.pgsRemainingRewriteBudget terminalFlag sem inputsMap
          monitor <- async $ do
            atomically $ readTVar terminalFlag >>= check
            forM_ asyncHandles (cancel . whAsync)
          persistFailRef <- newTVarIO Nothing
          results <- collectWorkerResults env gsVar terminalFlag persistFailRef asyncHandles []
          cancel monitor
          mPersistFail <- readTVarIO persistFailRef
          case mPersistFail of
            Just err -> do
              now <- getCurrentTime
              recordRunEvent env "run.graph_state_persist_failed" Q.RunEventError ("Graph state persistence failed during frontier: " <> err) Nothing
              failRun env.sePool env.seRunId now "graph_state_persist_failed" ("Graph state persistence failed: " <> err) True
              pure (Just (Left OutcomeFailed))
            Nothing -> do
              frontierResult <- classifyFrontierOutcome env topology gsVar results
              frontierEnd <- getCurrentTime
              let durationMs = round (diffUTCTime frontierEnd frontierStart * 1000) :: Int
              emitObsEvent $ EvtFrontierComplete env.seRunId frontierSize durationMs (isJust frontierResult)
              pure frontierResult

recordUnexpectedNodeFailure :: StageEnv -> NodeResult -> IO ()
recordUnexpectedNodeFailure env nr =
  case nr.nrOutcome of
    OutcomeNodeFailed failureDetail
      | failureDetail.fdErrorType /= "stage_failed" ->
          recordRunEvent
            env
            "frontier.node_failed"
            Q.RunEventError
            ("Node failed in frontier: " <> graphStageName nr.nrNodeId)
            ( Just
                ( Aeson.object
                    [ "stage" Aeson..= graphStageName nr.nrNodeId,
                      "error_type" Aeson..= failureDetail.fdErrorType,
                      "error" Aeson..= failureDetail.fdErrorMessage,
                      "retryable" Aeson..= failureDetail.fdRetryable
                    ]
                )
            )
    _ -> pure ()

resolveDeliveredSignals :: DB.Pool -> UUID -> GraphState Aeson.Value -> IO (GraphState Aeson.Value)
resolveDeliveredSignals pool runId gs = do
  let waitingNodes =
        [ (nid, sigName)
        | (nid, NodeWaiting sigName) <- Map.toList (gsNodeStatuses gs)
        ]
  foldM resolveOne gs waitingNodes
  where
    resolveOne state (nid, sigName) = do
      result <- DB.withConnection pool $ Q.lookupDeliveredSignal runId sigName (unNodeId nid)
      case result of
        Right (Just mPayload) -> do
          let output = fromMaybe Aeson.Null mPayload
          emitObsEvent $ EvtSignalResolved runId sigName (unNodeId nid)
          pure (markCompleted nid output state)
        Right Nothing -> pure state
        Left err -> do
          emitObsEvent $ EvtSignalLookupFailed runId sigName (unNodeId nid) (T.pack err)
          pure state
