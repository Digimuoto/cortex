{- |
Module      : Cortex.Pulse.Executor
Description : Pulse graph executor.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Advances through typed graph-based stage plans with graph-state persistence,
checkpoint audit writes, cancellation checks, replay-safety warnings, signal suspension, and
stage-log audit entries.

A linear stage pipeline is a degenerate graph (chain of single dependencies).
The 'mkLinearStagePlan' constructor is a convenience for chain-shaped plans.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Executor
  ( executeTask
  , resumeTask
  , executeStagePlan
  , resumeStagePlan
  , retryDelayMicros
  , TaskContext (..)
  , TaskHandler (..)
  , TaskRegistry

    -- * Hydration/Serialization
  , SerializableStageDefinition (..)
  , toSerializableStageDefinition
  , hydrateRewrite
  , module Cortex.Pulse.Plan
  , applyRewrite
  , materializedTopologyForAdmin
  )
where

import Control.Concurrent.STM (TVar, newTVarIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Rel8 (Result)

import Cortex.Algebra.Graph
  ( ValidationError (..)
  , validateDAG
  )
import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Loop (runGraphPlan)
import Cortex.Pulse.Executor.Persistence
  ( failRun
  , failUnsupportedTaskType
  , requireGraphStatePersistVar
  , retryDelayMicros
  )
import Cortex.Pulse.Executor.ReplayPolicy (enforceGraphReplayPolicy)
import Cortex.Pulse.Executor.Resume
  ( materializedTopologyForAdmin
  , resumeFromPersistedState
  )
import Cortex.Pulse.Executor.Types (RunTVars (..), mkStageEnv)
import Cortex.Pulse.GraphRuntime (initialGraphState, readyNodes)
import Cortex.Pulse.Materialization
  ( PersistedGraphState (..)
  , applyPlannedRewrite
  , computeTopologyHash
  , initialProvenance
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
import Cortex.Pulse.PlanHydration
  ( RewriteValidationError (..)
  , SerializableStageDefinition (..)
  , hydrateRewrite
  , planRewriteDelta
  , toSerializableStageDefinition
  )
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite (GraphRewrite (..))
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Types (PulseConfig (..))

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

data TaskContext = TaskContext
  { tcPool :: DB.Pool
  , tcConfig :: PulseConfig
  , tcShutdownFlag :: TVar Bool
  }

data TaskHandler = TaskHandler
  { executeFresh :: TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
  , resumeExisting :: TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
  }

type TaskRegistry = Map Text TaskHandler

-- | Execute a task from scratch (fresh run).
executeTask :: TaskRegistry -> TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
executeTask registry taskContext runId task =
  case Map.lookup task.taskType registry of
    Just handler -> handler.executeFresh taskContext runId task
    Nothing ->
      failUnsupportedTaskType taskContext.tcPool runId task.taskType

-- | Resume a task from its persisted graph state (reclaimed run).
resumeTask :: TaskRegistry -> TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
resumeTask registry taskContext runId task =
  case Map.lookup task.taskType registry of
    Just handler -> handler.resumeExisting taskContext runId task
    Nothing ->
      failUnsupportedTaskType taskContext.tcPool runId task.taskType

executeStagePlan
  :: StableStageId stageId
  => TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> IO RunOutcome
executeStagePlan taskContext runId task stagePlan = do
  -- Validate topology is a DAG. mkLinearStagePlan validates at construction,
  -- but StagePlan(..) is exported and raw plans skip validation.
  case validateDAG stagePlan.spTopology of
    Left (GraphHasCycle cycle') -> do
      now <- getCurrentTime
      failRun
        taskContext.tcPool
        runId
        now
        "topology_cycle"
        ("Stage plan contains a cycle: " <> T.intercalate " → " (fmap unNodeId cycle'))
        False
      pure OutcomeFailed
    Right () -> do
      let initialPersistedState =
            PersistedGraphState
              { pgsGraphState = initialGraphState stagePlan.spTopology
              , pgsRemainingRewriteBudget = stagePlan.spInitialRewriteBudget
              , pgsAppliedRewriteId = Nothing
              , pgsNodeProvenance = initialProvenance stagePlan.spTopology
              , pgsTopologyHash = Just (computeTopologyHash stagePlan.spTopology)
              , pgsRevision = Nothing
              }
      gsVar <- newTVarIO initialPersistedState
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
          env =
            mkStageEnv
              taskContext.tcPool
              (tcConfig taskContext)
              taskContext.tcShutdownFlag
              runId
              task
              stagePlan
              tvars
      persistFailed <- requireGraphStatePersistVar env gsVar initialPersistedState
      case persistFailed of
        Left outcome -> pure outcome
        Right _ ->
          runGraphPlan
            taskContext.tcPool
            (tcConfig taskContext)
            taskContext.tcShutdownFlag
            runId
            task
            stagePlan
            tvars

resumeStagePlan
  :: StableStageId stageId
  => TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> IO RunOutcome
resumeStagePlan taskContext runId task stagePlan = do
  let pool = taskContext.tcPool
  graphStateResult <- PulseDB.withConnection pool $ Q.readGraphState runId
  case graphStateResult of
    Right (Just row) ->
      resumeFromPersistedState
        taskContext.tcPool
        (tcConfig taskContext)
        taskContext.tcShutdownFlag
        runId
        task
        stagePlan
        row
        ( \resumedPlan persistedState loopControls _frontier -> do
            gsVar <- newTVarIO persistedState
            -- Repopulate per-node completion timestamps from
            -- pulse.stage_log so the topological-memory temporal
            -- axis scores pre-restart matches consistently with how
            -- a fresh execution scored them.  Empty initial value is
            -- the fallback when the DB read fails — memory queries
            -- still work structurally; only the temporal weighting
            -- degrades gracefully to "no data".
            hydratedCompletedAt <- hydrateNodeCompletedAtVar taskContext.tcPool runId
            nodeCompletedAtVar <- newTVarIO hydratedCompletedAt
            topologyVar <- newTVarIO resumedPlan.spTopology
            loopControlsVar <- newTVarIO loopControls
            let tvars =
                  RunTVars
                    { rvGsVar = gsVar
                    , rvNodeCompletedAtVar = nodeCompletedAtVar
                    , rvTopologyVar = topologyVar
                    , rvLoopControlsVar = loopControlsVar
                    }
            runGraphPlan
              taskContext.tcPool
              (tcConfig taskContext)
              taskContext.tcShutdownFlag
              runId
              task
              resumedPlan
              tvars
        )
    Right Nothing -> do
      -- No graph state row: the run crashed before its first node completed
      -- (or this is a first-ever execution that was reclaimed before any
      -- progress). Safe to start from scratch with replay policy enforcement.
      emitObsEvent $ EvtResumeFresh runId
      let gs0 = initialGraphState (spTopology stagePlan)
          frontier = readyNodes (spTopology stagePlan) gs0
      blocked <- enforceGraphReplayPolicy pool runId stagePlan frontier
      case blocked of
        Just blockedOutcome -> pure blockedOutcome
        Nothing -> executeStagePlan taskContext runId task stagePlan
    Left err -> do
      -- DB read failure: transient error, not missing state.
      let errMsg = "Failed to read graph state: " <> T.pack err
      emitObsEvent $ EvtResumeGraphStateReadFailed runId errMsg
      now <- getCurrentTime
      failRun pool runId now "graph_state_read_failed" errMsg True
      pure OutcomeFailed

{- | Apply a graph rewrite to a stage plan, evolving both topology and definitions.

This function enforces deterministic NodeId namespacing ({parent}:{local})
and validates the resulting DAG structure.
-}
applyRewrite
  :: Eq stageId
  => GraphRewrite NodeId (StageDefinition stageId)
  -> StagePlan stageId
  -> Either [RewriteValidationError] (StagePlan stageId)
applyRewrite = applyRewriteChecked

applyRewriteChecked
  :: Eq stageId
  => GraphRewrite NodeId (StageDefinition stageId)
  -> StagePlan stageId
  -> Either [RewriteValidationError] (StagePlan stageId)
applyRewriteChecked rewrite plan =
  applyPlannedRewrite <$> planRewriteDelta rewrite plan <*> pure plan

{- | Read @(stage_name, completed_at)@ rows for a run from
@pulse.stage_log@ and turn them into the 'Map NodeId UTCTime' the
executor binds into 'RunTVars.rvNodeCompletedAtVar'.

Logs and returns 'Map.empty' on DB failure so resume still
proceeds — memory queries degrade to "no temporal weighting" for
pre-restart nodes rather than crashing the run.
-}
hydrateNodeCompletedAtVar :: DB.Pool -> UUID -> IO (Map NodeId UTCTime)
hydrateNodeCompletedAtVar pool runId = do
  result <- PulseDB.withConnection pool $ Q.readNodeCompletionTimes runId
  case result of
    Left err -> do
      emitObsEvent $
        EvtResumeGraphParseFailed runId ("node completion timestamps read failed: " <> T.pack err)
      pure Map.empty
    Right rows ->
      pure (Map.fromList [(NodeId stageName, completedAt) | (stageName, completedAt) <- rows])
