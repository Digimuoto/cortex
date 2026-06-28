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
  , runCompiledCircuitManagedOn
  , resumeCompiledCircuitManaged
  , resumeCompiledCircuitManagedOn
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
import Control.Exception
  ( SomeAsyncException
  , SomeException
  , displayException
  , finally
  , fromException
  , throwIO
  , try
  )
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
import Cortex.Pulse.Executor.Persistence (failRun)
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
  ( ManagedResumeClaim (..)
  , PulseTaskDefinitionInsert (..)
  , claimAndCreateRun
  , claimManagedRunForResume
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

import Platform.DurableTask.Types
  ( RunOutcome (..)
  , RunStatus (..)
  , TriggerSource (..)
  , runStatusFromText
  )

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
  | -- | Opening a managed database pool failed.
    CircuitRunPoolError Text
  | -- | Setup reached a database that does not look provisioned with the Pulse schema.
    CircuitRunSchemaMissing Text
  | -- | A managed run could not be claimed without violating its ownership contract.
    CircuitRunTaskClaimConflict Text
  | -- | A managed resume target exists but is not currently resumable by this caller.
    CircuitRunResumeRejected Text
  | -- | Circuit execution raised an exception after a durable run was claimed.
    CircuitRunExecutionError Text
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
renewed lease, and return the durable run id alongside the outcome. This is a
one-shot convenience facade; high-throughput consumers should use
'runCompiledCircuitManagedOn' with a caller-owned pool. The caller supplies only
config + binder + circuit; run/lease/'TaskContext' assembly is hidden by GitHub
issue 330. The circuit is lowered before any durable rows are created, so
validation failures are side-effect-free.

Each managed run creates a scheduler-inert task definition (@enabled = false@, so the
Pulse scheduler never auto-claims it), grouped under @task_type = workflowKey@ with a
unique @task_name@, then claims one run against it. The task-definition and run rows
are durable records and are not cleaned up; operators need a retention policy for
long-lived hosts that drive many one-off managed runs. The managed run assumes the
Pulse schema is already provisioned ('Cortex.Pulse.Database.provisionPulseSchema').

The returned run id is the durable handle: a consumer records it to correlate,
inspect, or 'resumeCompiledCircuitManaged' the run after a crash. Execution runs under
'withLeaseRenewal' with @pulseLeaseOwner@, so a run that outlives its lease duration
keeps its lease and a co-located scheduler does not reclaim it mid-flight. If
execution raises an exception after the run is claimed, the facade marks the run
failed and returns 'CircuitRunExecutionError' rather than leaking an IO exception.
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
    Right lowered ->
      withManagedPool pulseConfig $ \pool ->
        runLoweredCompiledCircuitManagedOn pool pulseConfig workflowKey lowered

{- | Pool-reuse variant of 'runCompiledCircuitManaged'. The caller owns schema
provisioning and pool lifetime; this function still owns the durable managed run
row lifecycle.
-}
runCompiledCircuitManagedOn
  :: Pool
  -> PulseConfig
  -> Text
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError (UUID, RunOutcome))
runCompiledCircuitManagedOn pool pulseConfig workflowKey circuitConfig binder circuit =
  case lowerRunnableCircuit circuitConfig binder circuit of
    Left err -> pure (Left err)
    Right lowered ->
      runLoweredCompiledCircuitManagedOn pool pulseConfig workflowKey lowered

runLoweredCompiledCircuitManagedOn
  :: Pool
  -> PulseConfig
  -> Text
  -> SomeStagePlan
  -> IO (Either CircuitRunError (UUID, RunOutcome))
runLoweredCompiledCircuitManagedOn pool pulseConfig workflowKey (SomeStagePlan stagePlan _latentConditions) =
  withManagedRun pool pulseConfig workflowKey $ \taskContext runId task ->
    runManagedExecution taskContext.tcPool runId $
      withLeaseRenewal
        taskContext.tcPool
        runId
        (pulseLeaseOwner pulseConfig)
        (leaseSecondsOf pulseConfig)
        (executeStagePlan taskContext runId task stagePlan)

{- | Resume a durable, *managed* run from persisted graph state, addressed by the run
id 'runCompiledCircuitManaged' returned. Opens a pool from the 'PulseConfig' and
atomically claims a resumable run before loading its task definition and re-driving
the plan under a renewed lease. Live running runs are rejected instead of being
co-owned; terminal/waiting runs return their stored outcome without re-driving the
plan. A committed-variant selector re-reads its persisted label and never re-invokes
the producer effect (ADR 0062); a stage that already completed is not re-run.

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
    Right lowered ->
      withManagedPool pulseConfig $ \pool ->
        resumeLoweredCompiledCircuitManagedOn pool pulseConfig runId lowered

{- | Pool-reuse variant of 'resumeCompiledCircuitManaged'. The caller owns schema
provisioning and pool lifetime. The resume path still atomically claims ownership
of a resumable run before driving the graph.
-}
resumeCompiledCircuitManagedOn
  :: Pool
  -> PulseConfig
  -> UUID
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError (UUID, RunOutcome))
resumeCompiledCircuitManagedOn pool pulseConfig runId circuitConfig binder circuit =
  case lowerRunnableCircuit circuitConfig binder circuit of
    Left err -> pure (Left err)
    Right lowered ->
      resumeLoweredCompiledCircuitManagedOn pool pulseConfig runId lowered

resumeLoweredCompiledCircuitManagedOn
  :: Pool
  -> PulseConfig
  -> UUID
  -> SomeStagePlan
  -> IO (Either CircuitRunError (UUID, RunOutcome))
resumeLoweredCompiledCircuitManagedOn pool pulseConfig runId (SomeStagePlan stagePlan _latentConditions) =
  withManagedResume pool pulseConfig runId $ \taskContext task ->
    runManagedExecution taskContext.tcPool runId $
      withLeaseRenewal
        taskContext.tcPool
        runId
        (pulseLeaseOwner pulseConfig)
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
    Left err -> pure (Left (CircuitRunPoolError (T.pack err)))
    Right pool -> use pool `finally` HP.release pool

{- | Assemble a fresh managed run (a scheduler-inert task definition, a claimed run,
and a 'TaskContext'), run the action, and pair its outcome with the run id. Setup
failures (task definition, task load, run claim) become 'CircuitRunSetupError'. The
task is loaded /before/ the run is claimed, so a load failure leaves no orphaned
@running@ run. The lease owner is taken from 'pulseLeaseOwner' — the same value the
action renews the lease under.
-}
withManagedRun
  :: Pool
  -> PulseConfig
  -> Text
  -> (TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO (Either CircuitRunError RunOutcome))
  -> IO (Either CircuitRunError (UUID, RunOutcome))
withManagedRun pool pulseConfig workflowKey run = do
  now <- getCurrentTime
  uniqueSuffix <- toText <$> UUIDv4.nextRandom
  let taskName = workflowKey <> "/" <> uniqueSuffix
  created <- runTransaction pool (createTaskDefinition (inertTaskDefInsert workflowKey taskName now))
  case created of
    Left err -> pure (setupError "create task definition" err)
    Right Nothing -> pure (Left (CircuitRunTaskClaimConflict "create task definition: unexpected conflict"))
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
            Right Nothing -> pure (Left (CircuitRunTaskClaimConflict "claim run: task could not be claimed"))
            Right (Just runId) -> do
              shutdownFlag <- newTVarIO False
              outcome <-
                run
                  TaskContext {tcPool = pool, tcConfig = pulseConfig, tcShutdownFlag = shutdownFlag}
                  runId
                  task
              pure (fmap (runId,) outcome)

{- | Load the task definition for an existing run, claim resumable ownership, assemble
a 'TaskContext', run the action, and pair its outcome with the run id. A missing run
or a load failure becomes a 'CircuitRunSetupError' before the claim is attempted.
-}
withManagedResume
  :: Pool
  -> PulseConfig
  -> UUID
  -> (TaskContext -> PulseTaskDefinitionRow Result -> IO (Either CircuitRunError RunOutcome))
  -> IO (Either CircuitRunError (UUID, RunOutcome))
withManagedResume pool pulseConfig runId run = do
  loaded <- withConnection pool (getTaskForRun runId)
  case loaded of
    Left err -> pure (setupError "load run task" err)
    Right Nothing -> pure (Left (CircuitRunSetupError "load run task: run not found"))
    Right (Just task) -> do
      now <- getCurrentTime
      claimed <-
        runTransaction
          pool
          (claimManagedRunForResume runId (pulseLeaseOwner pulseConfig) now (leaseSecondsOf pulseConfig))
      case claimed of
        Left err -> pure (setupError "claim resume run" err)
        Right Nothing -> pure (Left (CircuitRunSetupError "claim resume run: run not found"))
        Right (Just claim)
          | claim.mrcClaimed -> do
              shutdownFlag <- newTVarIO False
              outcome <-
                run
                  TaskContext {tcPool = pool, tcConfig = pulseConfig, tcShutdownFlag = shutdownFlag}
                  task
              pure (fmap (runId,) outcome)
          | otherwise ->
              case runOutcomeForStoredStatus claim.mrcStatus of
                Just outcome -> pure (Right (runId, outcome))
                Nothing ->
                  pure
                    ( Left
                        ( CircuitRunResumeRejected
                            ("run is not resumable while status is " <> claim.mrcStatus)
                        )
                    )

-- | Tag a setup-phase DB failure with the phase that produced it.
setupError :: Text -> String -> Either CircuitRunError a
setupError context err =
  let errText = T.pack err
      full = context <> ": " <> errText
   in Left $
        if looksLikeMissingPulseSchema errText
          then CircuitRunSchemaMissing full
          else CircuitRunSetupError full

looksLikeMissingPulseSchema :: Text -> Bool
looksLikeMissingPulseSchema err =
  let normalized = T.replace "\\\"" "\"" err
   in any
        (`T.isInfixOf` normalized)
        [ "3F000" -- invalid_schema_name
        , "42P01" -- undefined_table
        , "42704" -- undefined_object
        , "schema \"pulse\""
        , "relation \"pulse."
        , "type \"pulse."
        ]

runOutcomeForStoredStatus :: Text -> Maybe RunOutcome
runOutcomeForStoredStatus status =
  case runStatusFromText status of
    Just Completed -> Just OutcomeCompleted
    Just Failed -> Just OutcomeFailed
    Just Cancelled -> Just OutcomeCancelled
    Just Timeout -> Just OutcomeTimedOut
    Just Waiting -> Just OutcomeSuspended
    Just Pending -> Nothing
    Just Running -> Nothing
    Just Skipped -> Nothing
    Nothing -> Nothing

runManagedExecution :: Pool -> UUID -> IO RunOutcome -> IO (Either CircuitRunError RunOutcome)
runManagedExecution pool runId action = do
  result <- try action :: IO (Either SomeException RunOutcome)
  case result of
    Right outcome -> pure (Right outcome)
    Left err ->
      case fromException err :: Maybe SomeAsyncException of
        Just _ -> throwIO err
        Nothing -> do
          now <- getCurrentTime
          let errText = T.take 200 (T.pack (displayException err))
          failRun pool runId now "executor_exception" errText True
          pure (Left (CircuitRunExecutionError errText))

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
