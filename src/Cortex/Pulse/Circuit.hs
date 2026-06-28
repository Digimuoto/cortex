{- |
Module      : Cortex.Pulse.Circuit
Description : Run a compiled Wire circuit through the durable Pulse executor.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Generic production entrypoint that lowers a compiled Wire circuit to a stage plan
and drives it through the durable Pulse executor — fresh run and resume —
including @select(...)@ over committed output variants (ADR 0062, GitHub #321).

Branch selection is by committed variant label: a producer commits exactly one
labelled variant ('Cortex.Wire.Value.wireValuePort'), and the lowered condition
stages route it to the matching arm via 'committedVariantConditionBinding'.
Downstream callers supply the task-node bindings (their effect resolution) through
'CircuitPulseBinder'; this module supplies only the lowering and the durable
execution glue, never effect or capability resolution.

A lowered plan embeds each condition as a runnable stage and additionally carries a
parallel 'StageLatentCondition' encoding for provenance/recovery. For every
condition this executor runs, that encoding is covered by an embedded stage. A
latent condition with no covering stage is a deferred control form this executor
cannot run, so it is rejected loudly ('CircuitRunUnsupportedLatentConditions')
rather than executed partially. With the current compiler this never fires; it
guards the public entrypoint against future deferred forms.
-}
module Cortex.Pulse.Circuit
  ( CircuitRunError (..)
  , runCompiledCircuit
  , resumeCompiledCircuit
  , runCompiledCircuitManaged
  , resumeCompiledCircuitManaged
  , lowerRunnableCircuit
  , ensureRunnable
  , committedVariantBinder
  , committedVariantBinderWith
  , signalStage
  , artifactStage
  , taskStage
  , StageReplaySafety (..)
  )
where

import Control.Concurrent.STM (newTVarIO)
import Control.Exception (finally)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Int (Int32)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID (UUID, toText)
import Data.UUID.V4 qualified as UUIDv4
import Hasql.Pool qualified as HP
import Rel8 (Result)

import Cortex.Pulse.Database
  ( ConnectionConfig (..)
  , Pool
  , createPulsePool
  , runTransaction
  , withConnection
  )
import Cortex.Pulse.Executor (TaskContext (..), executeStagePlan, resumeStagePlan)
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Plan
  ( SomeStagePlan (..)
  , StageLatentCondition (..)
  , StageReplaySafety (..)
  , slbNestedConditions
  , slbNodes
  , spDefinitions
  , taskStage
  )
import Cortex.Pulse.Query
  ( PulseTaskDefinitionInsert (..)
  , claimAndCreateRun
  , createTaskDefinition
  , getTaskById
  , getTaskForRun
  )
import Cortex.Pulse.Scheduler (withLeaseRenewal)
import Cortex.Pulse.Schema (PulseTaskDefinitionRow)
import Cortex.Pulse.Types (PulseConfig (..))
import Cortex.Wire.Circuit.Artifact (CompiledCircuit)
import Cortex.Wire.Circuit.Lowering
  ( CircuitLoweringError
  , CircuitPulseBinder
  , CircuitPulseConfig
  , artifactStage
  , committedVariantBinder
  , committedVariantBinderWith
  , lowerCompiledCircuitToSomeStagePlan
  , signalStage
  )

import Platform.DurableTask.Types (RunOutcome, TriggerSource (..))

-- | Why a compiled circuit could not be run through this entrypoint.
data CircuitRunError
  = -- | Lowering the compiled circuit to a stage plan failed.
    CircuitRunLoweringError CircuitLoweringError
  | {- | The lowered plan carries latent conditions with no covering executable
    stage — a deferred control form this executor cannot run. Carries the
    anchor node id of each uncovered condition. With the current compiler this
    never occurs (every @select(...)@ condition is embedded as a runnable
    stage); it guards the public entrypoint against future deferred forms.
    -}
    CircuitRunUnsupportedLatentConditions [NodeId]
  | {- | A run-setup step (pool, task definition, or run claim) failed before
    execution could begin (managed facade).
    -}
    CircuitRunSetupError Text
  deriving stock (Eq, Show)

{- | Reject a lowered plan this entrypoint cannot execute.

Committed-variant @select(...)@ embeds each condition as a runnable stage in the
plan definitions, so the parallel latent-condition encoding is redundant for
execution: every latent condition's anchor is also an embedded stage. A latent
condition whose anchor has no embedded stage is a genuinely deferred form, which
this executor cannot run; surface it loudly instead of dropping it silently.
-}
ensureRunnable :: SomeStagePlan -> Either CircuitRunError SomeStagePlan
ensureRunnable plan@(SomeStagePlan stagePlan latentConditions) =
  case uncoveredConditions (Map.keysSet (spDefinitions stagePlan)) latentConditions of
    [] -> Right plan
    uncovered ->
      Left (CircuitRunUnsupportedLatentConditions uncovered)

uncoveredConditions :: Set NodeId -> [StageLatentCondition] -> [NodeId]
uncoveredConditions coveringNodes =
  concatMap uncoveredCondition
  where
    uncoveredCondition condition =
      [slcAnchorNodeId condition | Set.notMember (slcAnchorNodeId condition) coveringNodes]
        <> foldMap uncoveredBranch condition.slcBranches

    uncoveredBranch branch =
      uncoveredConditions (Map.keysSet branch.slbNodes) branch.slbNestedConditions

{- | Lower a compiled circuit to a runnable stage plan, rejecting deferred forms
this entrypoint cannot execute. Pure; a caller may validate a circuit with this
before acquiring execution resources.
-}
lowerRunnableCircuit
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitRunError SomeStagePlan
lowerRunnableCircuit pulseConfig binder compiledCircuit =
  first
    CircuitRunLoweringError
    (lowerCompiledCircuitToSomeStagePlan pulseConfig binder compiledCircuit)
    >>= ensureRunnable

{- | Lower and execute a compiled Wire circuit as a fresh durable run, dispatching
@select(...)@ on committed variant labels. Returns 'Left' if lowering fails or the
plan carries an unsupported latent form; otherwise the executor 'RunOutcome'.
-}
runCompiledCircuit
  :: TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError RunOutcome)
runCompiledCircuit taskContext runId task pulseConfig binder compiledCircuit =
  case lowerRunnableCircuit pulseConfig binder compiledCircuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      Right <$> executeStagePlan taskContext runId task stagePlan

{- | Lower a compiled Wire circuit and resume its durable run from persisted graph
state. Re-evaluating a committed-variant selector reads the persisted label and
never re-invokes the producer effect (ADR 0062).
-}
resumeCompiledCircuit
  :: TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError RunOutcome)
resumeCompiledCircuit taskContext runId task pulseConfig binder compiledCircuit =
  case lowerRunnableCircuit pulseConfig binder compiledCircuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      Right <$> resumeStagePlan taskContext runId task stagePlan

{- | Lower and execute a compiled Wire circuit as a fresh, durable, *managed* run:
open a pool from the 'PulseConfig', create a task definition + run, execute it under a
renewed lease, and return the durable run id alongside the outcome. The caller
supplies only config + binder + circuit; run/lease/'TaskContext' assembly is hidden
(GitHub #330). The circuit is lowered before any durable rows are created, so
validation failures are side-effect-free.

Each managed run creates a scheduler-inert task definition (@enabled = false@, so the
Pulse scheduler never auto-claims it), grouped under @task_type = workflowKey@ with a
unique @task_name@, then claims one run against it. The task-definition and run rows
are durable records and are not cleaned up. The managed run assumes the Pulse schema
is already provisioned ('Cortex.Pulse.Database.provisionPulseSchema').

The returned run id is the durable handle: a consumer records it to correlate,
inspect, or 'resumeCompiledCircuitManaged' the run after a crash. Execution runs under
'withLeaseRenewal' with @pulseLeaseOwner@, so a run that outlives its lease duration
keeps its lease and a co-located scheduler does not reclaim it mid-flight.
-}
runCompiledCircuitManaged
  :: PulseConfig
  -> Text
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError (UUID, RunOutcome))
runCompiledCircuitManaged pulseConfig workflowKey circuitConfig binder circuit =
  case lowerRunnableCircuit circuitConfig binder circuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      withManagedRun pulseConfig workflowKey $ \taskContext runId task ->
        Right
          <$> withLeaseRenewal
            taskContext.tcPool
            runId
            (leaseSecondsOf pulseConfig)
            (executeStagePlan taskContext runId task stagePlan)

{- | Resume a durable, *managed* run from persisted graph state, addressed by the run
id 'runCompiledCircuitManaged' returned. Opens a pool from the 'PulseConfig', loads the
run's task definition, and re-drives the plan under a renewed lease. A committed-variant
selector re-reads its persisted label and never re-invokes the producer effect (ADR
0062); a stage that already completed is not re-run.

The binder and 'CircuitPulseConfig' must match the original run's (persisted graph
state is keyed by node id). Returns the same run id alongside the outcome.
-}
resumeCompiledCircuitManaged
  :: PulseConfig
  -> UUID
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError (UUID, RunOutcome))
resumeCompiledCircuitManaged pulseConfig runId circuitConfig binder circuit =
  case lowerRunnableCircuit circuitConfig binder circuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      withManagedResume pulseConfig runId $ \taskContext task ->
        Right
          <$> withLeaseRenewal
            taskContext.tcPool
            runId
            (leaseSecondsOf pulseConfig)
            (resumeStagePlan taskContext runId task stagePlan)

-- | The configured lease duration as the 'Int32' seconds the run/claim API expects.
leaseSecondsOf :: PulseConfig -> Int32
leaseSecondsOf = fromIntegral . pulseLeaseDurationSeconds

{- | Open a pool from the 'PulseConfig', run an action against it, and release it on
every path (success, 'Left', or exception). A pool-open failure becomes a
'CircuitRunSetupError'.
-}
withManagedPool
  :: PulseConfig
  -> (Pool -> IO (Either CircuitRunError a))
  -> IO (Either CircuitRunError a)
withManagedPool pulseConfig use = do
  poolResult <- createPulsePool (connectionConfigOf pulseConfig)
  case poolResult of
    Left err -> pure (setupError "pool" err)
    Right pool -> use pool `finally` HP.release pool

{- | Assemble a fresh managed run (a scheduler-inert task definition, a claimed run,
and a 'TaskContext'), run the action, and pair its outcome with the run id. Setup
failures (task definition, task load, run claim) become 'CircuitRunSetupError'. The
task is loaded /before/ the run is claimed, so a load failure leaves no orphaned
@running@ run. The lease owner is taken from 'pulseLeaseOwner' — the same value the
action renews the lease under.
-}
withManagedRun
  :: PulseConfig
  -> Text
  -> (TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO (Either CircuitRunError RunOutcome))
  -> IO (Either CircuitRunError (UUID, RunOutcome))
withManagedRun pulseConfig workflowKey run =
  withManagedPool pulseConfig $ \pool -> do
    now <- getCurrentTime
    uniqueSuffix <- toText <$> UUIDv4.nextRandom
    let taskName = workflowKey <> "/" <> uniqueSuffix
    created <- runTransaction pool (createTaskDefinition (inertTaskDefInsert workflowKey taskName now))
    case created of
      Left err -> pure (setupError "create task definition" err)
      Right Nothing -> pure (Left (CircuitRunSetupError "create task definition: unexpected conflict"))
      Right (Just taskId) -> do
        loaded <- withConnection pool (getTaskById taskId)
        case loaded of
          Left err -> pure (setupError "load task" err)
          Right Nothing -> pure (Left (CircuitRunSetupError "load task: definition not found"))
          Right (Just task) -> do
            claimed <-
              runTransaction
                pool
                ( claimAndCreateRun
                    taskId
                    (pulseLeaseOwner pulseConfig)
                    TriggerManual
                    now
                    (leaseSecondsOf pulseConfig)
                )
            case claimed of
              Left err -> pure (setupError "claim run" err)
              Right Nothing -> pure (Left (CircuitRunSetupError "claim run: task could not be claimed"))
              Right (Just runId) -> do
                shutdownFlag <- newTVarIO False
                outcome <-
                  run
                    TaskContext {tcPool = pool, tcConfig = pulseConfig, tcShutdownFlag = shutdownFlag}
                    runId
                    task
                pure (fmap (runId,) outcome)

{- | Load the task definition for an existing run, assemble a 'TaskContext', run the
action, and pair its outcome with the run id. A missing run or a load failure becomes
a 'CircuitRunSetupError'.
-}
withManagedResume
  :: PulseConfig
  -> UUID
  -> (TaskContext -> PulseTaskDefinitionRow Result -> IO (Either CircuitRunError RunOutcome))
  -> IO (Either CircuitRunError (UUID, RunOutcome))
withManagedResume pulseConfig runId run =
  withManagedPool pulseConfig $ \pool -> do
    loaded <- withConnection pool (getTaskForRun runId)
    case loaded of
      Left err -> pure (setupError "load run task" err)
      Right Nothing -> pure (Left (CircuitRunSetupError "load run task: run not found"))
      Right (Just task) -> do
        shutdownFlag <- newTVarIO False
        outcome <-
          run
            TaskContext {tcPool = pool, tcConfig = pulseConfig, tcShutdownFlag = shutdownFlag}
            task
        pure (fmap (runId,) outcome)

-- | Tag a setup-phase DB failure with the phase that produced it.
setupError :: Text -> String -> Either CircuitRunError a
setupError context err = Left (CircuitRunSetupError (context <> ": " <> T.pack err))

{- | A scheduler-inert task definition (enabled = false; next_run_at set so a direct
claim succeeds while the scheduler's due query, which requires enabled, skips it).
-}
inertTaskDefInsert :: Text -> Text -> UTCTime -> PulseTaskDefinitionInsert
inertTaskDefInsert workflowKey taskName now =
  PulseTaskDefinitionInsert
    { ptdiTaskType = workflowKey
    , ptdiTaskName = taskName
    , ptdiConfig = Aeson.Null
    , ptdiCronExpression = ""
    , ptdiEnabled = False
    , ptdiNextRunAt = Just now
    , ptdiTimeoutSeconds = 0
    , ptdiPriority = 0
    , ptdiMinIntervalSeconds = Nothing
    , ptdiCreatedAt = now
    }

connectionConfigOf :: PulseConfig -> ConnectionConfig
connectionConfigOf config =
  ConnectionConfig
    { dbHost = pulseDbHost config
    , dbPort = pulseDbPort config
    , dbUser = pulseDbUser config
    , dbPassword = pulseDbPassword config
    , dbDatabase = pulseDbName config
    , dbPoolSize = pulseDbPoolSize config
    , dbPoolTimeout = 30
    }
