{- |
Module      : Cortex.Pulse.Executor.Types
Description : Pulse runtime support for types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Executor.Types
  ( RunFailureSpec (..)
  , RewriteAdmissionState (..)
  , StageAttemptRef (..)
  , StageCall (..)
  , StageFailureResolution (..)
  , StageAttemptResult (..)
  , RewriteRejection (..)
  , StageEnv (..)
  , RunTVars (..)
  , mkStageEnv
  , isWorkerCancellation
  )
where

import Control.Concurrent.Async (AsyncCancelled)
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar)
import Control.Exception (AsyncException (..), SomeException, fromException)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Rel8 (Result)

import Cortex.Algebra.Graph (Relation)
import Cortex.Pulse.Materialization (PersistedGraphState, PersistedRewrite)
import Cortex.Pulse.Memory (captureMemorySnapshot, newMemoryHandle)
import Cortex.Pulse.Memory.Types (MemoryHandle)
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Plan (StageDefinition, StagePlan (..), StageRetryFailureContext)
import Cortex.Pulse.Query (GraphRewriteInsert)
import Cortex.Pulse.Rewrite (RewriteBudget, RewriteRejectionContext)
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Signal (SignalName)
import Cortex.Pulse.Types (PulseConfig (..), taskEnvelopeVersionOrDefault)

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome)

data RunFailureSpec = RunFailureSpec
  { rfsErrType :: Text
  , rfsErrMsg :: Text
  , rfsRetryable :: Bool
  }

data StageAttemptRef = StageAttemptRef
  { sarLogId :: Int64
  , sarAttemptLogId :: Int64
  , sarAttempt :: Int
  }

data RewriteAdmissionState = RewriteAdmissionState
  { rasRemainingBudget :: TVar RewriteBudget
  , rasAdmissionLock :: MVar ()
  }

data StageCall stageId = StageCall
  { scRemainingBudget :: RewriteBudget
  , scRewriteAdmission :: RewriteAdmissionState
  , scNodeId :: NodeId
  , scStageDef :: StageDefinition stageId
  , scStageName :: Text
  , scInputs :: Map NodeId Aeson.Value
  , scLogId :: Int64
  , scAttempt :: Int
  , scRetryFailure :: Maybe StageRetryFailureContext
  }

data StageFailureResolution
  = RetryStageAfter Int
  | SkipStageAfterExhaustion Aeson.Value
  | FailRunAfterExhaustion RunFailureSpec

data RewriteRejection = RewriteRejection
  { rrLastOutput :: Aeson.Value
  , rrContext :: RewriteRejectionContext
  , rrDeferredInsert :: GraphRewriteInsert
  }

data StageAttemptResult stageId
  = StageAdvance Aeson.Value
  | StageAdvanceWithRewrite Aeson.Value (PersistedRewrite stageId)
  | StageSkip
  | StageTerminal RunOutcome
  | StageSuspended SignalName
  | StageRewriteRejected RewriteRejection

{- | The three run-scoped TVars the executor maintains.  Bundled so
that 'mkStageEnv' / 'runGraphPlan' don't take three adjacent
'TVar' parameters that readers can't tell apart at the call site.
-}
data RunTVars = RunTVars
  { rvGsVar :: TVar PersistedGraphState
  {- ^ The live 'PersistedGraphState'.  Updated on every frontier
   step and every rewrite admission.
  -}
  , rvNodeCompletedAtVar :: TVar (Map NodeId UTCTime)
  {- ^ Per-node settlement timestamps.  Updated by
   'Cortex.Pulse.Executor.Persistence.persistStageSuccess' /
   'persistStageRewrite' when a node reaches a terminal outcome.
  -}
  , rvTopologyVar :: TVar (Relation NodeId)
  {- ^ Current topology.  Held separately from 'PersistedGraphState'
   because the latter only persists a topology hash, not the
   relation itself.  Updated by 'Cortex.Pulse.Executor.Loop' when
   a rewrite is admitted.
  -}
  }

data StageEnv = StageEnv
  { sePool :: DB.Pool
  , seRunId :: UUID
  , seTaskType :: Text
  , seTaskVersion :: Int
  , seCheckpointRuntimeVersion :: Int
  , seShutdownFlag :: TVar Bool
  , seMaxFrontierConcurrency :: Int
  , seMemoryFactory :: IO MemoryHandle
  {- ^ DIG-529 factory that builds a /stage-entry-bound/
   'MemoryHandle'.  'attemptStage' evaluates this once just before
   handing the stage action its 'StageContext', so every read
   during the attempt sees the same snapshot — no frontier-sibling
   bleed, no mid-attempt drift.  Built from
   'Cortex.Pulse.Memory.captureMemorySnapshot' over the run's
   TVars (see 'mkStageEnv').
  -}
  , seNodeCompletedAtVar :: TVar (Map NodeId UTCTime)
  {- ^ Projection of 'RunTVars.rvNodeCompletedAtVar' for the
   persistence layer.  Equal to @rvNodeCompletedAtVar (mkStageEnv
   … tvars).seNodeCompletedAtVar@; kept on 'StageEnv' so
   persistence code doesn't need to reach back into the bundle.
  -}
  , seTopologyVar :: TVar (Relation NodeId)
  -- ^ Projection of 'RunTVars.rvTopologyVar' for the loop layer.
  }

mkStageEnv
  :: DB.Pool
  -> PulseConfig
  -> TVar Bool
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> RunTVars
  -> StageEnv
mkStageEnv pool config shutdownFlag runId task stagePlan tvars =
  StageEnv
    { sePool = pool
    , seRunId = runId
    , seTaskType = task.taskType
    , seTaskVersion = taskEnvelopeVersionOrDefault task.config
    , seCheckpointRuntimeVersion = stagePlan.spCheckpointRuntimeVersion
    , seShutdownFlag = shutdownFlag
    , seMaxFrontierConcurrency = pulseMaxFrontierConcurrency config
    , seMemoryFactory =
        newMemoryHandle
          <$> captureMemorySnapshot tvars.rvGsVar tvars.rvNodeCompletedAtVar tvars.rvTopologyVar
    , seNodeCompletedAtVar = tvars.rvNodeCompletedAtVar
    , seTopologyVar = tvars.rvTopologyVar
    }

isWorkerCancellation :: SomeException -> Bool
isWorkerCancellation err =
  case fromException err of
    Just ThreadKilled -> True
    Just UserInterrupt -> True
    _ -> isJust (fromException err :: Maybe AsyncCancelled)
