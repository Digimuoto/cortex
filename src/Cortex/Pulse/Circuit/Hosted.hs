{- |
Module      : Cortex.Pulse.Circuit.Hosted
Description : Pulse runtime host for generated fixed-topology Circuit engines.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The generated executable owns scheduling and validates circuit transitions.
Pulse retains runtime authority and the sole durable recovery snapshot.

Durable terminal semantics: the persisted @hosted_terminal_state@ records the
snapshot's resume disposition, not the complete Pulse outcome or merely the
engine session's last transition. An operator cancellation persists
@cancelled@; a graceful Pulse shutdown persists @active@, because from the
durable perspective the run is still in progress — a graceful shutdown must
leave exactly the state a crash would, so both resume identically. Worker
interruptions (shutdown, run cancel) are reported to the generic host as
'EffectInterrupted' and never reach the engine, so a node is never durably
recorded as failed because the host was stopping.
-}
module Cortex.Pulse.Circuit.Hosted
  ( executeHostedCircuit
  , resumeHostedCircuit

    -- * Internal (exposed for tests)
  , pulseStateFromEngine
  , engineStateFromPulse
  , effectResolution
  , HostedCancellation (..)
  , TerminalSettlement (..)
  , terminalSettlement
  , renderEngineTerminal
  , parseEngineTerminal
  )
where

import Control.Concurrent.MVar (newMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID, toText)
import Data.Word (Word32, Word64)
import Rel8 (Result)

import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.Executor (TaskContext (..))
import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Frontier (computeNodeInputs, executeNodeWorker)
import Cortex.Pulse.Executor.Outcome (handleSettled)
import Cortex.Pulse.Executor.Persistence (failRun, recordRunEvent, requireGraphStatePersistVar)
import Cortex.Pulse.Executor.Resume (resumeFromPersistedState)
import Cortex.Pulse.Executor.Types
  ( RewriteAdmissionState (..)
  , RunTVars (..)
  , StageEnv (..)
  , mkStageEnv
  )
import Cortex.Pulse.GraphRuntime
  ( FailureDetail (..)
  , GraphState (..)
  , NodeOutcome (..)
  , NodeResult (..)
  , NodeStatus (..)
  , initialGraphState
  )
import Cortex.Pulse.Materialization
  ( PersistedGraphState (..)
  , computeTopologyHash
  , initialProvenance
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan (StableStageId, StagePlan (..), initialLoopControls)
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Schema (PulseTaskDefinitionRow)
import Cortex.Wire.Circuit.Engine
  ( EffectCompletion (..)
  , EngineNodeStatus (..)
  , EngineState (..)
  , EngineTerminalState (..)
  , HostedProgramArtifact
  , engineStateSchema
  )
import Cortex.Wire.Circuit.Hosted
  ( CheckpointCommitResult (..)
  , EffectResolution (..)
  , HostedRunError (..)
  , HostedRunErrorKind (..)
  , HostedRuntimeHost (..)
  , renderHostedRunError
  , runHostedProgram
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.StaticProgram (StaticProgram (..), StaticProgramNode (..))

import Platform.DurableTask.Polling qualified as Polling
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

{- | Why Pulse requested a run-level engine cancellation. Keeping this
separate from 'RunOutcome' makes impossible states such as "completed
cancellation" unrepresentable and prevents a concurrent shutdown request
from overriding a genuine engine failure.
-}
data HostedCancellation
  = HostedShutdownCancellation
  | HostedOperatorCancellation
  deriving stock (Eq, Show)

{- | Pure terminal decision interpreted by 'settleTerminal'. The engine's
terminal class selects the branch; cancellation intent only refines an actual
cancelled terminal and can never replace a failed decision.
-}
data TerminalSettlement
  = SettleRunOutcome !RunOutcome
  | CommitOperatorCancellation
  | RejectActiveTerminal
  deriving stock (Eq, Show)

terminalSettlement
  :: EngineTerminalState
  -> Maybe HostedCancellation
  -> Maybe RunOutcome
  -> TerminalSettlement
terminalSettlement terminal cancellation nodeOutcome =
  case terminal of
    EngineSucceeded -> SettleRunOutcome OutcomeCompleted
    EngineTerminalFailed -> SettleRunOutcome (fromMaybe OutcomeFailed nodeOutcome)
    EngineCancelled ->
      case cancellation of
        Just HostedShutdownCancellation -> SettleRunOutcome OutcomeShutdown
        Just HostedOperatorCancellation -> CommitOperatorCancellation
        Nothing -> CommitOperatorCancellation
    EngineActive -> RejectActiveTerminal

executeHostedCircuit
  :: StableStageId stageId
  => TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> StaticProgram
  -> HostedProgramArtifact
  -> IO RunOutcome
executeHostedCircuit taskContext runId task stagePlan staticProgram artifact = do
  let persistedState =
        PersistedGraphState
          { pgsGraphState = initialGraphState stagePlan.spTopology
          , pgsRemainingRewriteBudget = stagePlan.spInitialRewriteBudget
          , pgsAppliedRewriteId = Nothing
          , pgsNodeProvenance = initialProvenance stagePlan.spTopology
          , pgsTopologyHash = Just (computeTopologyHash stagePlan.spTopology)
          , pgsHostedCheckpointSequence = Nothing
          , pgsHostedTerminalState = Nothing
          , pgsRevision = Nothing
          }
  runWithState taskContext runId task stagePlan staticProgram artifact persistedState Nothing

resumeHostedCircuit
  :: StableStageId stageId
  => TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> StaticProgram
  -> HostedProgramArtifact
  -> IO RunOutcome
resumeHostedCircuit taskContext runId task stagePlan staticProgram artifact = do
  graphStateResult <- PulseDB.withConnection taskContext.tcPool (Q.readGraphState runId)
  case graphStateResult of
    Left err -> hostedFailure taskContext.tcPool runId ("reading hosted graph state: " <> T.pack err)
    Right Nothing -> executeHostedCircuit taskContext runId task stagePlan staticProgram artifact
    Right (Just snapshot) ->
      resumeFromPersistedState
        taskContext.tcPool
        taskContext.tcConfig
        taskContext.tcShutdownFlag
        runId
        task
        stagePlan
        snapshot
        ( \resumedPlan persistedState _loopControls _frontier ->
            case persistedState.pgsHostedTerminalState of
              -- The engine's committed terminal decision is durable
              -- authority. A crash between the terminal checkpoint and the
              -- run-row settlement must settle here, without booting an
              -- engine just to have it re-announce a decision it already
              -- committed.
              Just stored
                | stored /= "active" ->
                    case parseEngineTerminal stored of
                      Left message -> hostedFailure taskContext.tcPool runId message
                      Right terminal -> do
                        env <- transientStageEnv taskContext runId task resumedPlan persistedState
                        settleTerminal env persistedState.pgsGraphState terminal Nothing Nothing
              _activeOrAbsent ->
                case engineStateFromPulse staticProgram persistedState of
                  Left message -> hostedFailure taskContext.tcPool runId message
                  Right engineState ->
                    runWithState
                      taskContext
                      runId
                      task
                      resumedPlan
                      staticProgram
                      artifact
                      persistedState
                      (Just engineState)
        )

{- | A stage environment for settlement paths that never execute a stage. The
memory factory inside is driven from transient TVars that never see stage
execution, mirroring the transient env 'resumeFromPersistedState' builds for
its own persistence needs.
-}
transientStageEnv
  :: TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> PersistedGraphState
  -> IO StageEnv
transientStageEnv taskContext runId task stagePlan persistedState = do
  gsVar <- newTVarIO persistedState
  nodeCompletedAtVar <- newTVarIO Map.empty
  topologyVar <- newTVarIO stagePlan.spTopology
  loopControlsVar <- newTVarIO (initialLoopControls stagePlan)
  let tvars =
        RunTVars
          { rvGsVar = gsVar
          , rvNodeCompletedAtVar = nodeCompletedAtVar
          , rvTopologyVar = topologyVar
          , rvLoopControlsVar = loopControlsVar
          }
  pure
    ( mkStageEnv
        taskContext.tcPool
        taskContext.tcConfig
        taskContext.tcShutdownFlag
        runId
        task
        stagePlan
        tvars
    )

runWithState
  :: StableStageId stageId
  => TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> StaticProgram
  -> HostedProgramArtifact
  -> PersistedGraphState
  -> Maybe EngineState
  -> IO RunOutcome
runWithState taskContext runId task stagePlan staticProgram artifact persistedState maybeRestore = do
  gsVar <- newTVarIO persistedState
  nodeCompletedAtVar <- newTVarIO Map.empty
  topologyVar <- newTVarIO stagePlan.spTopology
  loopControlsVar <- newTVarIO (initialLoopControls stagePlan)
  remainingBudgetVar <- newTVarIO persistedState.pgsRemainingRewriteBudget
  admissionLock <- newMVar ()
  completionOutcomes <- newTVarIO Map.empty
  cancellationOutcome <- newTVarIO Nothing
  abortOutcome <- newTVarIO Nothing
  let tvars =
        RunTVars
          { rvGsVar = gsVar
          , rvNodeCompletedAtVar = nodeCompletedAtVar
          , rvTopologyVar = topologyVar
          , rvLoopControlsVar = loopControlsVar
          }
      env =
        mkStageEnv
          taskContext.tcPool
          taskContext.tcConfig
          taskContext.tcShutdownFlag
          runId
          task
          stagePlan
          tvars
      rewriteAdmission =
        RewriteAdmissionState
          { rasRemainingBudget = remainingBudgetVar
          , rasAdmissionLock = admissionLock
          }
      denseNodes = denseNodeMap staticProgram
      runtimeHost =
        HostedRuntimeHost
          { hostedCommitCheckpoint =
              commitEngineCheckpoint env gsVar completionOutcomes cancellationOutcome abortOutcome denseNodes
          , hostedExecuteEffect =
              executeEngineEffect
                env
                task
                stagePlan
                rewriteAdmission
                gsVar
                completionOutcomes
                denseNodes
          , hostedAwaitCancellation =
              Just (awaitCancellation taskContext runId cancellationOutcome)
          }
  hostedResult <- runHostedProgram artifact (toText runId) runtimeHost maybeRestore
  case hostedResult of
    Left err
      | err.hostedRunErrorKind == HostedRunAborted -> do
          -- 'HostedRunAborted' is only constructed after the commit callback
          -- wrote the abort outcome, so the fallback is defensive.
          aborted <- readTVarIO abortOutcome
          pure (fromMaybe OutcomeFailed aborted)
    Left err -> do
      cancellationResult <- readTVarIO cancellationOutcome
      case cancellationResult of
        -- A fault while the host is shutting down (dying pipes, a child
        -- torn down mid-cancel) must not durably fail a resumable run: the
        -- run row stays 'running' and is reclaimed after restart, exactly
        -- like a crash. A genuine engine fault re-surfaces on the resume,
        -- where no shutdown is in progress to mask it.
        Just HostedShutdownCancellation -> do
          recordRunEvent
            env
            "run.hosted_shutdown_interrupted"
            Q.RunEventWarn
            ("hosted engine stopped during Pulse shutdown: " <> renderHostedRunError err)
            Nothing
          pure OutcomeShutdown
        -- The operator asked for cancellation and the cancellation is
        -- durable in the run row; a child that died mid-cancel fulfils it
        -- rather than converting the operator's intent into a failure.
        Just HostedOperatorCancellation -> do
          now <- getCurrentTime
          cancelled <-
            PulseDB.runTransaction
              taskContext.tcPool
              ( Q.updateRunCancelled
                  runId
                  now
                  ("operator cancellation (hosted engine stopped: " <> renderHostedRunError err <> ")")
              )
          case cancelled of
            Left cancelErr ->
              hostedFailure
                taskContext.tcPool
                runId
                ("persisting cancellation after hosted fault: " <> T.pack cancelErr)
            Right () -> pure OutcomeCancelled
        Nothing -> hostedRunFailure taskContext.tcPool runId err
    Right finalState -> do
      persistedFinal <- readTVarIO gsVar
      cancellationResult <- readTVarIO cancellationOutcome
      outcomes <- readTVarIO completionOutcomes
      let nodeOutcome = deterministicTerminalOutcome denseNodes outcomes
      settleTerminal
        env
        persistedFinal.pgsGraphState
        finalState.esTerminal
        cancellationResult
        nodeOutcome

denseNodeMap :: StaticProgram -> Map Word32 NodeId
denseNodeMap staticProgram =
  Map.fromList
    [ (node.staticProgramNodeId, NodeId node.staticProgramNodeRef.unCircuitNodeRef)
    | node <- staticProgram.staticProgramNodes
    ]

executeEngineEffect
  :: StableStageId stageId
  => StageEnv
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> RewriteAdmissionState
  -> TVar PersistedGraphState
  -> TVar (Map NodeId NodeOutcome)
  -> Map Word32 NodeId
  -> Word32
  -> IO EffectResolution
executeEngineEffect env task stagePlan rewriteAdmission gsVar completionOutcomes denseNodes denseId =
  case Map.lookup denseId denseNodes of
    Nothing -> pure (EffectResolved (EffectFailed "engine requested an unknown dense node"))
    Just nodeId -> do
      persistedState <- readTVarIO gsVar
      let inputs = computeNodeInputs stagePlan persistedState.pgsGraphState nodeId
      (NodeResult _ result, maybeRewrite) <-
        executeNodeWorker
          env
          task
          stagePlan
          rewriteAdmission
          persistedState.pgsRemainingRewriteBudget
          nodeId
          inputs
      let normalized = case maybeRewrite of
            Nothing -> result
            Just _rewrite ->
              OutcomeNodeFailed
                (FailureDetail "hosted_dynamic_rewrite" "hosted executable profile forbids rewrites" False)
      atomically (modifyTVar' completionOutcomes (Map.insert nodeId normalized))
      pure (effectResolution denseId normalized)

deterministicTerminalOutcome :: Map Word32 NodeId -> Map NodeId NodeOutcome -> Maybe RunOutcome
deterministicTerminalOutcome denseNodes outcomes =
  listToMaybe
    [ outcome
    | nodeId <- Map.elems denseNodes
    , Just nodeOutcome <- [Map.lookup nodeId outcomes]
    , Just outcome <- [terminalOutcomeForNode nodeOutcome]
    ]

{- | How one node outcome reaches the generic host. Interruptions caused by the
run being stopped (Pulse shutdown, operator cancellation) are not completions:
they are intercepted by the host, the engine keeps the node running, and the
imminent run-level cancel resets it to pending — so durable state never
records "Pulse is shutting down" as a node failure.
-}
effectResolution :: Word32 -> NodeOutcome -> EffectResolution
effectResolution denseId = \case
  OutcomeSucceeded _output -> EffectResolved (EffectSucceeded (fromIntegral denseId + 1))
  OutcomeSkipped -> EffectResolved EffectSkipped
  OutcomeNodeFailed failure -> EffectResolved (EffectFailed failure.fdErrorMessage)
  OutcomeNodeTimedOut -> EffectResolved (EffectFailed "stage timed out")
  OutcomeNodeCancelled -> EffectResolved (EffectFailed "stage worker cancelled")
  OutcomeNodeShutdown -> EffectInterrupted "Pulse is shutting down"
  OutcomeNodeRunCancelled -> EffectInterrupted "run cancelled"
  OutcomeSuspendedOn _signal -> EffectResolved (EffectFailed "hosted executable profile forbids suspension")
  OutcomeRewritten _output _rewrite -> EffectResolved (EffectFailed "hosted executable profile forbids rewrites")

terminalOutcomeForNode :: NodeOutcome -> Maybe RunOutcome
terminalOutcomeForNode = \case
  OutcomeNodeFailed _failure -> Just OutcomeFailed
  OutcomeNodeTimedOut -> Just OutcomeTimedOut
  OutcomeNodeCancelled -> Just OutcomeCancelled
  OutcomeNodeShutdown -> Just OutcomeShutdown
  OutcomeNodeRunCancelled -> Just OutcomeCancelled
  OutcomeSucceeded _output -> Nothing
  OutcomeSkipped -> Nothing
  OutcomeSuspendedOn _signal -> Just OutcomeFailed
  OutcomeRewritten _output _rewrite -> Just OutcomeFailed

commitEngineCheckpoint
  :: StageEnv
  -> TVar PersistedGraphState
  -> TVar (Map NodeId NodeOutcome)
  -> TVar (Maybe HostedCancellation)
  {- ^ Cancellation outcome recorded by the watcher before it requested the
  cancel; read to decide the durable terminal rendering.
  -}
  -> TVar (Maybe RunOutcome)
  {- ^ Abort outcome; written before every 'CheckpointCommitAbortRun' so the caller
  can read it whenever the host reports 'HostedRunAborted'.
  -}
  -> Map Word32 NodeId
  -> EngineState
  -> IO CheckpointCommitResult
commitEngineCheckpoint env gsVar completionOutcomes cancellationOutcome abortOutcome denseNodes snapshot = do
  current <- readTVarIO gsVar
  outcomes <- readTVarIO completionOutcomes
  cancellation <- readTVarIO cancellationOutcome
  case pulseStateFromEngine current outcomes denseNodes cancellation snapshot of
    Left message -> pure (CheckpointCommitRejected message)
    Right nextState -> do
      persisted <- requireGraphStatePersistVar env gsVar nextState
      case persisted of
        Left outcome -> do
          -- 'handleGraphStatePersistError' already recorded the consequence
          -- (failRun for a DB fault, an ownership-loss warning for a stale
          -- write). The host must stop without recording anything further —
          -- in the stale-write case the run now belongs to a newer claimant.
          atomically (writeTVar abortOutcome (Just outcome))
          pure (CheckpointCommitAbortRun (abortMessage outcome))
        Right _state -> pure CheckpointCommitAccepted
  where
    abortMessage = \case
      OutcomeShutdown -> "Pulse graph-state checkpoint lost run ownership"
      _alreadySettled -> "Pulse graph-state checkpoint failed; the run is already settled"

pulseStateFromEngine
  :: PersistedGraphState
  -> Map NodeId NodeOutcome
  -> Map Word32 NodeId
  -> Maybe HostedCancellation
  -- ^ The run-level cancellation outcome at commit time, if any.
  -> EngineState
  -> Either Text PersistedGraphState
pulseStateFromEngine current outcomes denseNodes cancellation snapshot = do
  checkpointSequence <- word64ToInt64 snapshot.esCheckpointSequence
  statusPairs <- traverse statusPair (zip [0 ..] snapshot.esNodeStatuses)
  outputPairs <- traverse completedOutput statusPairs
  pure
    current
      { pgsGraphState =
          GraphState
            { gsNodeStatuses = Map.fromList statusPairs
            , gsNodeOutputs = Map.fromList (catMaybes outputPairs)
            }
      , pgsHostedCheckpointSequence = Just checkpointSequence
      , pgsHostedTerminalState = Just (persistedTerminal cancellation snapshot.esTerminal)
      }
  where
    statusPair (denseId, engineStatus) = do
      nodeId <-
        maybe
          (Left "engine checkpoint references an unknown dense node")
          Right
          (Map.lookup denseId denseNodes)
      pure (nodeId, pulseStatus engineStatus)

    completedOutput (nodeId, NodeCompleted) =
      case Map.lookup nodeId outcomes of
        Just (OutcomeSucceeded output) -> Right (Just (nodeId, output))
        _other ->
          case Map.lookup nodeId current.pgsGraphState.gsNodeOutputs of
            Just output -> Right (Just (nodeId, output))
            Nothing -> Left ("completed engine node has no Pulse output: " <> nodeId.unNodeId)
    completedOutput _other = Right Nothing

{- | Interruptions never reach the engine (they are intercepted as
'EffectInterrupted'), so an engine-side failed node is always a genuine node
failure — no outcome-map reconstruction is needed or sound here.
-}
pulseStatus :: EngineNodeStatus -> NodeStatus
pulseStatus = \case
  EnginePending -> NodePending
  EngineRunning -> NodeRunning
  EngineCompleted -> NodeCompleted
  EngineFailed -> NodeFailed
  EngineSkipped -> NodeSkipped

{- | The durable rendering of an engine terminal. A cancellation the host
initiated because Pulse is shutting down persists as @active@: durably the run
is still in progress, and a graceful shutdown must leave exactly the state a
crash would so both resume identically. Only an operator cancellation persists
@cancelled@.
-}
persistedTerminal :: Maybe HostedCancellation -> EngineTerminalState -> Text
persistedTerminal cancellation = \case
  EngineCancelled ->
    case cancellation of
      Just HostedShutdownCancellation -> renderEngineTerminal EngineActive
      Just HostedOperatorCancellation -> renderEngineTerminal EngineCancelled
      Nothing -> renderEngineTerminal EngineCancelled
  EngineActive -> renderEngineTerminal EngineActive
  EngineSucceeded -> renderEngineTerminal EngineSucceeded
  EngineTerminalFailed -> renderEngineTerminal EngineTerminalFailed

engineStateFromPulse :: StaticProgram -> PersistedGraphState -> Either Text EngineState
engineStateFromPulse staticProgram persistedState = do
  checkpointSequence <-
    maybe
      (Left "hosted resume requires a persisted checkpoint sequence")
      (Right . fromIntegral)
      persistedState.pgsHostedCheckpointSequence
  encoded <- traverse encodeNode staticProgram.staticProgramNodes
  let statuses = fmap fst encoded
      handles = fmap snd encoded
  pure
    EngineState
      { esSchema = engineStateSchema
      , esProgramIdentity = staticProgram.staticProgramIdentity
      , esCheckpointSequence = checkpointSequence
      , -- A non-active persisted terminal is settled by the resume path
        -- without booting an engine, so a restored engine is always active.
        esTerminal = EngineActive
      , esNodeStatuses = statuses
      , esOutputHandles = handles
      }
  where
    encodeNode node = do
      let nodeId = NodeId node.staticProgramNodeRef.unCircuitNodeRef
      status <-
        maybe
          (Left ("Pulse snapshot is missing node " <> nodeId.unNodeId))
          encodeStatus
          (Map.lookup nodeId persistedState.pgsGraphState.gsNodeStatuses)
      let handle = if status == EngineCompleted then fromIntegral node.staticProgramNodeId + 1 else 0
      pure (status, handle)

    -- Resume normalization has already reset interrupted and running nodes
    -- to pending; these branches are defensive against being called outside
    -- that pipeline.
    encodeStatus = \case
      NodePending -> Right EnginePending
      NodeRunning -> Left "Pulse replay normalization left a running node"
      NodeCompleted -> Right EngineCompleted
      NodeFailed -> Right EngineFailed
      NodeSkipped -> Right EngineSkipped
      NodeInterrupted _reason -> Left "Pulse replay normalization left an interrupted node"
      NodeRewritten -> Left "hosted executable profile forbids rewritten nodes"
      NodeWaiting _signal -> Left "hosted executable profile forbids waiting nodes"

renderEngineTerminal :: EngineTerminalState -> Text
renderEngineTerminal = \case
  EngineActive -> "active"
  EngineSucceeded -> "completed"
  EngineTerminalFailed -> "failed"
  EngineCancelled -> "cancelled"

parseEngineTerminal :: Text -> Either Text EngineTerminalState
parseEngineTerminal = \case
  "active" -> Right EngineActive
  "completed" -> Right EngineSucceeded
  "failed" -> Right EngineTerminalFailed
  "cancelled" -> Right EngineCancelled
  other -> Left ("invalid persisted hosted terminal state: " <> other)

word64ToInt64 :: Word64 -> Either Text Int64
word64ToInt64 value
  | value <= fromIntegral (maxBound :: Int64) = Right (fromIntegral value)
  | otherwise = Left "hosted checkpoint sequence exceeds PostgreSQL bigint"

awaitCancellation :: TaskContext -> UUID -> TVar (Maybe HostedCancellation) -> IO (Either Text Text)
awaitCancellation taskContext runId cancellationOutcome = loop
  where
    loop = do
      shuttingDown <- readTVarIO taskContext.tcShutdownFlag
      if shuttingDown
        then do
          atomically (writeTVar cancellationOutcome (Just HostedShutdownCancellation))
          pure (Right "Pulse host shutdown")
        else do
          cancelled <- PulseDB.withConnection taskContext.tcPool (Q.checkCancellation runId)
          case cancelled of
            Left err -> do
              -- Cancellation polling is advisory; a transient DB fault must
              -- not fail a healthy run, but it must be visible — a
              -- persistent outage silently disabling cancellation is an
              -- operational incident.
              emitObsEvent (EvtCancelCheckFailed runId "hosted_cancellation_watcher" (T.pack err))
              Polling.threadDelayWithJitter 250000 0.2 >> loop
            Right True -> do
              atomically (writeTVar cancellationOutcome (Just HostedOperatorCancellation))
              pure (Right "operator cancellation")
            Right False -> Polling.threadDelayWithJitter 250000 0.2 >> loop

settleTerminal
  :: StageEnv
  -> GraphState Aeson.Value
  -> EngineTerminalState
  -> Maybe HostedCancellation
  -> Maybe RunOutcome
  -> IO RunOutcome
settleTerminal env graphState terminal cancellation nodeOutcome =
  case terminalSettlement terminal cancellation nodeOutcome of
    SettleRunOutcome outcome -> handleSettled env graphState outcome
    CommitOperatorCancellation -> do
      now <- getCurrentTime
      cancelled <-
        PulseDB.runTransaction env.sePool (Q.updateRunCancelled env.seRunId now "hosted engine cancelled")
      case cancelled of
        Left err ->
          hostedFailure
            env.sePool
            env.seRunId
            ("persisting hosted engine cancellation: " <> T.pack err)
        Right () -> pure OutcomeCancelled
    RejectActiveTerminal ->
      hostedFailure env.sePool env.seRunId "hosted engine returned an active terminal state"

hostedRunFailure :: PulseDB.Pool -> UUID -> HostedRunError -> IO RunOutcome
hostedRunFailure pool runId = hostedFailure pool runId . renderHostedRunError

hostedFailure :: PulseDB.Pool -> UUID -> Text -> IO RunOutcome
hostedFailure pool runId message = do
  now <- getCurrentTime
  failRun pool runId now "hosted_engine_error" (T.take 500 message) True
  pure OutcomeFailed
