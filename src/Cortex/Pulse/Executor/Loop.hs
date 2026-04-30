{- |
Module      : Cortex.Pulse.Executor.Loop
Description : Pulse runtime support for loop.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Executor.Loop
  ( runGraphPlan
  )
where

import Control.Concurrent.STM (TVar, atomically, readTVarIO, writeTVar)
import Control.Monad (foldM)
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Rel8 (Result)

import Cortex.Pulse.Executor.Frontier
  ( runFrontierConcurrent
  , runFrontierSequential
  )
import Cortex.Pulse.Executor.Outcome
  ( handleGraphOutcome
  , handleSettled
  , handleStuck
  , handleSuspended
  )
import Cortex.Pulse.Executor.Persistence
  ( failRun
  , requireGraphStatePersist
  )
import Cortex.Pulse.Executor.Types
  ( RunTVars (..)
  , StageEnv (..)
  , mkStageEnv
  )
import Cortex.Pulse.GraphRuntime
  ( StepResult (..)
  , classifyGraphState
  )
import Cortex.Pulse.Materialization
  ( PersistedGraphState (..)
  , materializeRewrite
  )
import Cortex.Pulse.Plan (StableStageId, StagePlan (..))
import Cortex.Pulse.PlanHydration
  ( renderRewriteError
  , rewriteErrorType
  )
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Types (PulseConfig)

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))

runGraphPlan
  :: forall stageId
   . StableStageId stageId
  => DB.Pool
  -> PulseConfig
  -> TVar Bool
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> RunTVars
  -> IO RunOutcome
runGraphPlan pool config shutdownFlag runId task stagePlan tvars = do
  persistedState <- readTVarIO tvars.rvGsVar
  let graphState = persistedState.pgsGraphState
      topology = stagePlan.spTopology
      env = mkStageEnv pool config shutdownFlag runId task stagePlan tvars
  case classifyGraphState topology graphState of
    Progressing gs' readyNodeIds -> do
      atomically $ writeTVar tvars.rvGsVar persistedState {pgsGraphState = gs'}
      result <-
        if env.seMaxFrontierConcurrency > 1 && length readyNodeIds > 1
          then runFrontierConcurrent env task stagePlan tvars.rvGsVar readyNodeIds
          else runFrontierSequential env task stagePlan tvars.rvGsVar readyNodeIds
      case result of
        Just (Left outcome) -> do
          persistedState' <- readTVarIO tvars.rvGsVar
          handleGraphOutcome env persistedState'.pgsGraphState outcome
        Just (Right persistedRewrites) -> do
          currentState <- readTVarIO tvars.rvGsVar
          case foldM
            (\(plan, persisted) persistedRewrite -> materializeRewrite persistedRewrite plan persisted)
            (stagePlan, currentState)
            persistedRewrites of
            Left rewriteErr -> do
              now <- getCurrentTime
              failRun
                env.sePool
                env.seRunId
                now
                (rewriteErrorType rewriteErr)
                (renderRewriteError rewriteErr)
                False
              pure OutcomeFailed
            Right (stagePlan', gsWithRewrite) -> do
              persistFailed <- requireGraphStatePersist env gsWithRewrite
              case persistFailed of
                Left outcome -> pure outcome
                Right gsWithRewrite' -> do
                  atomically $ do
                    writeTVar tvars.rvGsVar gsWithRewrite'
                    writeTVar tvars.rvTopologyVar stagePlan'.spTopology
                  runGraphPlan pool config shutdownFlag runId task stagePlan' tvars
        Nothing -> runGraphPlan pool config shutdownFlag runId task stagePlan tvars
    Settled gs' outcome -> do
      atomically $ writeTVar tvars.rvGsVar persistedState {pgsGraphState = gs'}
      handleSettled env gs' outcome
    Suspended gs' -> do
      atomically $ writeTVar tvars.rvGsVar persistedState {pgsGraphState = gs'}
      handleSuspended env gs'
    Stuck gs' diag -> do
      atomically $ writeTVar tvars.rvGsVar persistedState {pgsGraphState = gs'}
      handleStuck env runId gs' diag
