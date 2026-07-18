{- |
Module      : Cortex.Pulse.Circuit.Hosted
Description : Pulse runtime host for generated fixed-topology Circuit engines.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The generated executable owns scheduling and validates circuit transitions.
Pulse retains runtime authority and the sole durable recovery snapshot.
-}
module Cortex.Pulse.Circuit.Hosted
  ( executeHostedCircuit
  , resumeHostedCircuit
  )
where

import Control.Applicative ((<|>))
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
import Cortex.Pulse.Executor.Frontier (computeNodeInputs, executeNodeWorker)
import Cortex.Pulse.Executor.Outcome (handleSettled)
import Cortex.Pulse.Executor.Persistence (failRun, requireGraphStatePersistVar)
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
  , InterruptReason (..)
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
  ( HostedRunError
  , HostedRuntimeHost (..)
  , renderHostedRunError
  , runHostedProgram
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.StaticProgram (StaticProgram (..), StaticProgramNode (..))

import Platform.DurableTask.Polling qualified as Polling
import Platform.DurableTask.Types (RunOutcome (..))

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
              commitEngineCheckpoint env gsVar completionOutcomes denseNodes
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
    Left err -> hostedRunFailure taskContext.tcPool runId err
    Right finalState -> do
      persistedFinal <- readTVarIO gsVar
      cancellationResult <- readTVarIO cancellationOutcome
      outcomes <- readTVarIO completionOutcomes
      let requestedOutcome =
            cancellationResult
              <|> deterministicTerminalOutcome denseNodes outcomes
      settleTerminal env persistedFinal.pgsGraphState finalState.esTerminal requestedOutcome

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
  -> IO EffectCompletion
executeEngineEffect env task stagePlan rewriteAdmission gsVar completionOutcomes denseNodes denseId =
  case Map.lookup denseId denseNodes of
    Nothing -> pure (EffectFailed "engine requested an unknown dense node")
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
      pure (effectCompletion denseId normalized)

deterministicTerminalOutcome :: Map Word32 NodeId -> Map NodeId NodeOutcome -> Maybe RunOutcome
deterministicTerminalOutcome denseNodes outcomes =
  listToMaybe
    [ outcome
    | nodeId <- Map.elems denseNodes
    , Just nodeOutcome <- [Map.lookup nodeId outcomes]
    , Just outcome <- [terminalOutcomeForNode nodeOutcome]
    ]

effectCompletion :: Word32 -> NodeOutcome -> EffectCompletion
effectCompletion denseId = \case
  OutcomeSucceeded _output -> EffectSucceeded (fromIntegral denseId + 1)
  OutcomeSkipped -> EffectSkipped
  OutcomeNodeFailed failure -> EffectFailed failure.fdErrorMessage
  OutcomeNodeTimedOut -> EffectFailed "stage timed out"
  OutcomeNodeCancelled -> EffectFailed "stage worker cancelled"
  OutcomeNodeShutdown -> EffectFailed "Pulse is shutting down"
  OutcomeNodeRunCancelled -> EffectFailed "run cancelled"
  OutcomeSuspendedOn _signal -> EffectFailed "hosted executable profile forbids suspension"
  OutcomeRewritten _output _rewrite -> EffectFailed "hosted executable profile forbids rewrites"

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
  -> Map Word32 NodeId
  -> EngineState
  -> IO (Either Text ())
commitEngineCheckpoint env gsVar completionOutcomes denseNodes snapshot = do
  current <- readTVarIO gsVar
  outcomes <- readTVarIO completionOutcomes
  case pulseStateFromEngine current outcomes denseNodes snapshot of
    Left message -> pure (Left message)
    Right nextState -> do
      persisted <- requireGraphStatePersistVar env gsVar nextState
      pure $ case persisted of
        Left outcome -> Left ("Pulse graph-state checkpoint failed: " <> T.pack (show outcome))
        Right _state -> Right ()

pulseStateFromEngine
  :: PersistedGraphState
  -> Map NodeId NodeOutcome
  -> Map Word32 NodeId
  -> EngineState
  -> Either Text PersistedGraphState
pulseStateFromEngine current outcomes denseNodes snapshot = do
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

pulseStatus :: EngineNodeStatus -> NodeStatus
pulseStatus = \case
  EnginePending -> NodePending
  EngineRunning -> NodeRunning
  EngineCompleted -> NodeCompleted
  EngineFailed -> NodeFailed
  EngineSkipped -> NodeSkipped

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
      terminal
        | all (`elem` [EngineCompleted, EngineSkipped]) statuses = EngineSucceeded
        | EngineRunning `notElem` statuses && EngineFailed `elem` statuses = EngineTerminalFailed
        | otherwise = EngineActive
  pure
    EngineState
      { esSchema = engineStateSchema
      , esProgramIdentity = staticProgram.staticProgramIdentity
      , esCheckpointSequence = checkpointSequence
      , esTerminal = terminal
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

    encodeStatus = \case
      NodePending -> Right EnginePending
      NodeRunning -> Left "Pulse replay normalization left a running node"
      NodeCompleted -> Right EngineCompleted
      NodeFailed -> Right EngineFailed
      NodeSkipped -> Right EngineSkipped
      NodeInterrupted InterruptedSiblingCancelled -> Right EngineFailed
      NodeInterrupted InterruptedShutdown -> Left "cannot restore a shutdown-interrupted hosted node"
      NodeInterrupted InterruptedRunCancelled -> Left "cannot restore a cancelled hosted node"
      NodeRewritten -> Left "hosted executable profile forbids rewritten nodes"
      NodeWaiting _signal -> Left "hosted executable profile forbids waiting nodes"

word64ToInt64 :: Word64 -> Either Text Int64
word64ToInt64 value
  | value <= fromIntegral (maxBound :: Int64) = Right (fromIntegral value)
  | otherwise = Left "hosted checkpoint sequence exceeds PostgreSQL bigint"

awaitCancellation :: TaskContext -> UUID -> TVar (Maybe RunOutcome) -> IO (Either Text Text)
awaitCancellation taskContext runId cancellationOutcome = loop
  where
    loop = do
      shuttingDown <- readTVarIO taskContext.tcShutdownFlag
      if shuttingDown
        then do
          atomically (writeTVar cancellationOutcome (Just OutcomeShutdown))
          pure (Right "Pulse host shutdown")
        else do
          cancelled <- PulseDB.withConnection taskContext.tcPool (Q.checkCancellation runId)
          case cancelled of
            Left err -> pure (Left ("Pulse cancellation check failed: " <> T.pack err))
            Right True -> do
              atomically (writeTVar cancellationOutcome (Just OutcomeCancelled))
              pure (Right "operator cancellation")
            Right False -> Polling.threadDelayWithJitter 250000 0.2 >> loop

settleTerminal
  :: StageEnv
  -> GraphState Aeson.Value
  -> EngineTerminalState
  -> Maybe RunOutcome
  -> IO RunOutcome
settleTerminal env graphState terminal requestedOutcome =
  case terminal of
    EngineSucceeded -> handleSettled env graphState OutcomeCompleted
    EngineTerminalFailed ->
      handleSettled env graphState (fromMaybe OutcomeFailed requestedOutcome)
    EngineCancelled -> do
      now <- getCurrentTime
      cancelled <-
        PulseDB.runTransaction env.sePool (Q.updateRunCancelled env.seRunId now "hosted engine cancelled")
      case cancelled of
        Left err ->
          hostedFailure
            env.sePool
            env.seRunId
            ("persisting hosted engine cancellation: " <> T.pack err)
        Right () -> pure (fromMaybe OutcomeCancelled requestedOutcome)
    EngineActive -> hostedFailure env.sePool env.seRunId "hosted engine returned an active terminal state"

hostedRunFailure :: PulseDB.Pool -> UUID -> HostedRunError -> IO RunOutcome
hostedRunFailure pool runId = hostedFailure pool runId . renderHostedRunError

hostedFailure :: PulseDB.Pool -> UUID -> Text -> IO RunOutcome
hostedFailure pool runId message = do
  now <- getCurrentTime
  failRun pool runId now "hosted_engine_error" (T.take 500 message) True
  pure OutcomeFailed
