{- |
Module      : Cortex.Pulse.ExecutorSpec
Description : Pulse executor integration tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Tests require a running PostgreSQL database with migrations applied.
Skipped if PGHOST environment variable is not set.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.ExecutorSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , displayException
  , finally
  , throwIO
  , try
  )
import Control.Monad (forM_, void, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Pool (Pool)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement (..))
import Rel8 (Result)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Graph (..)
  , Relation (..)
  , edge
  , path
  , successors
  , toRelation
  , topSort
  , validateDAG
  , vertices
  )
import Cortex.Capability.Catalog.AdmissionProjection (ContentDigest (..), ProjectionVersion (..))
import Cortex.Capability.Catalog.AwaitStrategy
  ( AwaitStrategy (..)
  , IsolationExpectation (..)
  , ReplayClass (..)
  )
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..), ContentAddress (..))
import Cortex.Capability.Catalog.RuntimeBindingRecord
  ( RuntimeBindingRecord (..)
  , RuntimeStageActionRef (..)
  )
import Cortex.Pulse.Executor
  ( LoopInstanceKey (..)
  , ReplayPolicy (..)
  , RewriteExhaustionPolicy (..)
  , SomeStagePlan (..)
  , StableStageId (..)
  , StageContext (..)
  , StageDefinition (..)
  , StageFailure (..)
  , StagePlan (..)
  , StageRejectedRewrite (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , StageRetryBackoff (..)
  , StageRetryExhaustion (..)
  , StageRetryFailureContext (..)
  , StageRetryPolicy (..)
  , StageTemplateId (..)
  , TaskContext (..)
  , TaskHandler (..)
  , TaskRegistry
  , buildStageTemplateRegistry
  , executeStagePlan
  , executeTask
  , initialLoopControls
  , liftChainAction
  , loopRegistrationForStage
  , resumeStagePlan
  , resumeTask
  , retryDelayMicros
  , stageActionId
  , stageTemplateId
  , toSerializableStageDefinition
  )
import Cortex.Pulse.Executor qualified as Executor
import Cortex.Pulse.Executor.ExternalCall
  ( ExternalCallContext (..)
  , ExternalCallDriver (..)
  , FetchResult (..)
  )
import Cortex.Pulse.Executor.ExternalCallStore (pulseAttemptStore)
import Cortex.Pulse.Executor.Persistence (requireGraphStatePersist)
import Cortex.Pulse.Executor.Types (RunTVars (..), mkStageEnv)
import Cortex.Pulse.GraphStateRevision (GraphStateRevision (..))
import Cortex.Pulse.Iteration
  ( EffectiveBound (..)
  , EmittedAggregationPolicy (..)
  , FrontierShapeWitness (..)
  , FrontierStateRole (..)
  , FrontierWitnessAlgorithm (..)
  , IterationExhaustionPolicy (..)
  , KernelBoundary (..)
  , LoopKernelWitness
  , LoopOutcome (..)
  , LoopPolicy (..)
  , LoopRegistration (..)
  , LoopRewriteInteraction (..)
  , LoopStepWitness (..)
  , kernelWitnessForLocalSpec
  )
import Cortex.Pulse.Lowering.ExternalCallStage (bindExternalCallStage)
import Cortex.Pulse.Materialize
  ( NodeProvenanceEntry (..)
  , PersistedGraphState (..)
  , computeTopologyHash
  , initialProvenance
  )
import Cortex.Pulse.Memory (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Query
  ( PulseRunEvent (..)
  , PulseStageAttemptLogDetail (..)
  , PulseStageLogDetail (..)
  )
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Query.ExternalCall
  ( ExternalCallAttempt (..)
  , externalCallSignalSuffix
  , loadExternalCallAttempt
  )
import Cortex.Pulse.Rewrite
  ( BudgetContext (..)
  , BudgetDimension (..)
  , ExpansionMode (..)
  , GraphRewrite (..)
  , RewriteBudget (..)
  , RewriteRejectionContext (..)
  , SubgraphSpec (..)
  , budgetFraction
  )
import Cortex.Pulse.Runtime
  ( GraphState (..)
  , InterruptReason (..)
  , NodeStatus (..)
  , initialGraphState
  , markCompleted
  , markFailed
  )
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Signal
  ( SignalName (..)
  , externalCallSignalName
  , runTerminalSignalName
  , unSignalName
  )
import Cortex.Pulse.Types (PulseConfig (..), defaultRewriteBudget, taskEnvelopeVersionOrDefault)
import Cortex.TestSupport.Database (createTestDB, runSession, runTx)
import Cortex.Wire
  ( WireAppendHole (..)
  , WireCompileEnv (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , WireValue (..)
  , compileWireAppendProposalWithEnv
  , defaultOutputPortName
  , emptyWireCompileEnv
  , mkWireValue
  , wireExecutorProjectionFromPorts
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.Circuit.Artifact (CompiledCircuit (..))
import Cortex.Wire.Circuit.IR
  ( CircuitNodeRef (..)
  , CircuitTaskNode (..)
  )
import Cortex.Wire.Circuit.Lower
  ( CircuitLoweringError (..)
  , CircuitPulseBinder (..)
  , CircuitPulseConfig (..)
  , committedVariantConditionBinding
  , lowerCompiledCircuitToStagePlan
  )
import Cortex.Wire.Compile (compileWireText)

import Platform.Database qualified as DB
import Platform.Database.Encode qualified as Enc
import Platform.DurableTask.Checkpoint (buildCheckpointEnvelope)
import Platform.DurableTask.Types (RunOutcome (..), StageStatus (..), TriggerSource (..))

data TestStage
  = TestStageAlpha
  | TestStageBeta
  | TestStageGamma
  | TestStageDelta
  deriving stock (Bounded, Enum, Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId TestStage where
  stageIdToText = \case
    TestStageAlpha -> "test_alpha"
    TestStageBeta -> "test_beta"
    TestStageGamma -> "test_gamma"
    TestStageDelta -> "test_delta"

-- | Dynamic stage ID for stress tests with variable node counts.
newtype DynStageId = DynStageId Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId DynStageId where
  stageIdToText (DynStageId t) = t

-- | Helper to run a test only if database is available
withDb :: Maybe Pool -> (Pool -> IO ()) -> IO ()
withDb Nothing _ = pendingWith "PGHOST not set - database not available"
withDb (Just pool) action = action pool

-- | Set up test DB pool (returns Nothing if PGHOST unset)
setupTestDb :: IO (Maybe Pool)
setupTestDb = do
  mHost <- lookupEnv "PGHOST"
  case mHost of
    Nothing -> pure Nothing
    Just _ -> do
      result <- try createTestDB :: IO (Either SomeException Pool)
      case result of
        Left err -> error $ "PGHOST is set but database setup failed: " <> displayException err
        Right pool -> pure (Just pool)

-- | Insert a task definition for testing. Returns the task_id.
insertTestTaskDef :: Pool -> Text -> Text -> IO UUID
insertTestTaskDef pool taskType taskName = do
  now <- getCurrentTime
  runTx pool $
    Q.claimTestTaskDef taskType taskName now

-- | Create a run for a task. Returns the run_id.
createTestRun :: Pool -> UUID -> IO UUID
createTestRun pool taskId = do
  now <- getCurrentTime
  result <- runTx pool $ Q.claimAndCreateRun taskId "test-owner" TriggerManual now 300
  case result of
    Just runId -> pure runId
    Nothing -> fail "Failed to create test run (task already claimed?)"

-- | Read the run status from the database.
readRunStatus :: Pool -> UUID -> IO (Maybe Text)
readRunStatus pool runId =
  runSession pool $ Q.readRunStatus runId

{- | Read persisted graph state and decode node statuses.
Fails the test with a descriptive message if the JSON cannot be decoded.
-}
readGraphNodeStatuses :: Pool -> UUID -> IO (Maybe (Map.Map NodeId NodeStatus))
readGraphNodeStatuses pool runId = do
  result <- runSession pool $ Q.readGraphState runId
  case result of
    Nothing -> pure Nothing
    Just snapshot ->
      case Aeson.fromJSON snapshot.pgssNodeStatuses of
        Aeson.Success m -> pure (Just m)
        Aeson.Error err ->
          fail $
            "Failed to decode persisted graph state for run "
              <> show runId
              <> ": "
              <> err

readGraphNodeOutputs :: Pool -> UUID -> IO (Maybe (Map.Map NodeId Aeson.Value, Maybe Int64))
readGraphNodeOutputs pool runId = do
  result <- runSession pool $ Q.readGraphState runId
  case result of
    Nothing -> pure Nothing
    Just snapshot ->
      case Aeson.fromJSON snapshot.pgssNodeOutputs of
        Aeson.Success m -> pure (Just (m, snapshot.pgssAppliedRewriteId))
        Aeson.Error err ->
          fail $
            "Failed to decode persisted graph outputs for run "
              <> show runId
              <> ": "
              <> err

expectGraphStateSnapshot :: Pool -> UUID -> IO Q.PulseGraphStateSnapshot
expectGraphStateSnapshot pool runId = do
  result <- runSession pool $ Q.readGraphState runId
  case result of
    Nothing -> expectationFailure "Expected persisted graph state snapshot" >> fail "missing graph state"
    Just snapshot -> pure snapshot

-- | Count stage log entries for a run.
countStageLogs :: Pool -> UUID -> IO Int32
countStageLogs pool runId =
  runSession pool $ Q.countStageLogEntries runId

readStageLogs :: Pool -> UUID -> IO [PulseStageLogDetail]
readStageLogs pool runId =
  runSession pool $ Q.listStageLogDetails runId

readStageAttemptLogs :: Pool -> UUID -> IO [PulseStageAttemptLogDetail]
readStageAttemptLogs pool runId =
  runSession pool $ Q.listStageAttemptLogDetails runId

readRunEvents :: Pool -> UUID -> IO [PulseRunEvent]
readRunEvents pool runId =
  runSession pool $ Q.listRunEvents runId

mkTaskContext :: Pool -> IO (TVar Bool, TaskContext)
mkTaskContext pool = do
  shutdownFlag <- newTVarIO False
  let taskContext =
        TaskContext
          { tcPool = pool
          , tcConfig = testPulseConfig
          , tcShutdownFlag = shutdownFlag
          }
  pure (shutdownFlag, taskContext)

mkTaskContextWith :: Pool -> Int -> IO (TVar Bool, TaskContext)
mkTaskContextWith pool frontierConcurrency = do
  shutdownFlag <- newTVarIO False
  let taskContext =
        TaskContext
          { tcPool = pool
          , tcConfig = testPulseConfig {pulseMaxFrontierConcurrency = frontierConcurrency}
          , tcShutdownFlag = shutdownFlag
          }
  pure (shutdownFlag, taskContext)

stubPlanTaskRegistry :: TaskRegistry
stubPlanTaskRegistry =
  Map.fromList
    [
      ( "paper_portfolio_cycle"
      , TaskHandler
          { executeFresh = executeStubPlanTask
          , resumeExisting = resumeStubPlanTask
          }
      )
    ]

executeStubPlanTask :: TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
executeStubPlanTask taskContext runId task =
  case stubStagePlanForTaskType task.taskType of
    Just (SomeStagePlan stagePlan _) -> executeStagePlan taskContext runId task stagePlan
    Nothing -> error $ "Missing stub stage plan for task type: " <> T.unpack task.taskType

resumeStubPlanTask :: TaskContext -> UUID -> PulseTaskDefinitionRow Result -> IO RunOutcome
resumeStubPlanTask taskContext runId task =
  case stubStagePlanForTaskType task.taskType of
    Just (SomeStagePlan stagePlan _) -> resumeStagePlan taskContext runId task stagePlan
    Nothing -> error $ "Missing stub stage plan for task type: " <> T.unpack task.taskType

stubStagePlanForTaskType :: Text -> Maybe SomeStagePlan
stubStagePlanForTaskType = \case
  "paper_portfolio_cycle" -> Just (SomeStagePlan paperPortfolioCycleStagePlan [])
  _ -> Nothing

paperPortfolioCycleStagePlan :: StagePlan NodeId
paperPortfolioCycleStagePlan =
  mkLinearStagePlan
    [ nodeStage (NodeId stageName) (const (pure (StageComplete Aeson.Null)))
    | stageName <- paperPortfolioCycleNodeNames
    ]
    Aeson.Null
    4
    ReplayPolicyWarn

loadTaskDef :: Pool -> UUID -> IO (PulseTaskDefinitionRow Result)
loadTaskDef pool taskId = do
  result <- runSession pool $ Q.getTaskById taskId
  case result of
    Just task -> pure task
    Nothing -> fail $ "Task not found: " <> show taskId

testPulseConfig :: PulseConfig
testPulseConfig =
  PulseConfig
    { pulseDbHost = "localhost"
    , pulseDbPort = 5432
    , pulseDbUser = "cortex"
    , pulseDbPassword = ""
    , pulseDbName = "cortex"
    , pulseDbPoolSize = 1
    , pulseApiUrl = "http://127.0.0.1:8080"
    , pulseJwtSecret = "test-secret-key-for-unit-testing-only-32chars"
    , pulseJwtExpirationSeconds = 86400
    , pulseJwtIssuer = "cortex-pulse"
    , pulseJwtAudience = "cortex-host"
    , pulseAdminApiKey = Just "test-admin-api-key"
    , pulseServiceCredential = Just "test-pulse-credential"
    , pulseHealthPort = 9090
    , pulseLeaseOwner = "test-owner"
    , pulseLeaseDurationSeconds = 300
    , pulsePollIntervalSeconds = 5
    , pulseMaxConcurrentTasks = 4
    , pulseMaxFrontierConcurrency = 1
    , pulseTaskTypeLimits = mempty
    }

simpleStage :: TestStage -> (UUID -> Aeson.Value -> IO Aeson.Value) -> StageDefinition TestStage
simpleStage stageId action =
  StageDefinition
    { sdStageId = stageId
    , sdTemplateId = stageTemplateId stageId
    , sdActionId = stageActionId stageId
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = liftChainAction action
    , sdMemoryStrategy = defaultMemoryStrategy
    }

mkTemplateRegistry
  :: Eq stageId
  => Map.Map NodeId (StageDefinition stageId)
  -> Map.Map Executor.StageTemplateId (StageDefinition stageId)
mkTemplateRegistry defs =
  either (error . T.unpack) id (buildStageTemplateRegistry defs)

nodeStage :: NodeId -> (StageContext -> IO (StageResult NodeId)) -> StageDefinition NodeId
nodeStage nodeId action =
  StageDefinition
    { sdStageId = nodeId
    , sdTemplateId = stageTemplateId nodeId
    , sdActionId = stageActionId nodeId
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = action
    , sdMemoryStrategy = defaultMemoryStrategy
    }

runtimeIterationPolicy :: Int -> FrontierShapeWitness -> LoopKernelWitness -> LoopPolicy
runtimeIterationPolicy cap frontierWitness kernelWitness =
  LoopPolicy
    { lpMaxIterations = fromIntegral cap
    , lpExhaustion = IterationExhaustionFail
    , lpCheckpointCadence = 1
    , lpCancellationPoints = Set.empty
    , lpNamespaceRoot = NodeId "loop"
    , lpMaxSegmentLen = 64
    , lpMaxKernelNodes = 8
    , lpMaxKernelEdges = 8
    , lpMaxKernelDepth = 8
    , lpAggregation = AggregateDiscard
    , lpMaxAggregatedItems = Nothing
    , lpRewriteInteraction = LoopKernelRewriteClosed
    , lpKernelBoundary =
        KernelBoundary
          { kbWitness = frontierWitness
          , kbStateInRole = FrontierStateRole "state"
          , kbStateOutRole = FrontierStateRole "state"
          }
    , lpKernelWitness = kernelWitness
    , lpPolicyVersion = 1
    }

runtimeIterationRegistration :: LoopPolicy -> LoopRegistration
runtimeIterationRegistration policy =
  LoopRegistration policy (EffectiveBound policy.lpMaxIterations)

runtimeIterationInstance :: StageTemplateId -> LoopPolicy -> LoopInstanceKey
runtimeIterationInstance templateId policy =
  LoopInstanceKey
    { likTemplateId = templateId
    , likNamespaceRoot = policy.lpNamespaceRoot
    }

singleStageKernelWitness :: StageDefinition NodeId -> LoopKernelWitness
singleStageKernelWitness stageDef =
  let localId = stageDef.sdStageId
      localSpec =
        SubgraphSpec
          { sgsTopology = toRelation (path [localId])
          , sgsDefinitions = Map.singleton localId (toSerializableStageDefinition stageDef)
          , sgsEntryNodes = [localId]
          , sgsExitNodes = [localId]
          }
   in kernelWitnessForLocalSpec localSpec

signalStage :: TestStage -> SignalName -> StageDefinition TestStage
signalStage stageId signalName =
  StageDefinition
    { sdStageId = stageId
    , sdTemplateId = stageTemplateId stageId
    , sdActionId = stageActionId stageId
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = \_ctx -> pure (StageSuspend signalName)
    , sdMemoryStrategy = defaultMemoryStrategy
    }

singleSignalWaitPlan :: SignalName -> StagePlan TestStage
singleSignalWaitPlan signalName =
  mkLinearStagePlan
    [signalStage TestStageAlpha signalName]
    Aeson.Null
    1
    ReplayPolicyWarn

dynSignalStage :: Text -> SignalName -> StageDefinition DynStageId
dynSignalStage stageName signalName =
  let stageId = DynStageId stageName
   in StageDefinition
        { sdStageId = stageId
        , sdTemplateId = stageTemplateId stageId
        , sdActionId = stageActionId stageId
        , sdReplaySafety = SafeToReplay
        , sdReplayPolicyOverride = Nothing
        , sdTimeoutSeconds = Nothing
        , sdRetryPolicy = Nothing
        , sdAction = \_ctx -> pure (StageSuspend signalName)
        , sdMemoryStrategy = defaultMemoryStrategy
        }

parallelSignalWaitPlan :: [(Text, SignalName)] -> StagePlan DynStageId
parallelSignalWaitPlan waits =
  let definitions =
        Map.fromList
          [ (NodeId stageName, dynSignalStage stageName signalName)
          | (stageName, signalName) <- waits
          ]
      topology = toRelation (vertices (Map.keys definitions))
   in StagePlan
        { spInitialState = Aeson.Null
        , spCheckpointRuntimeVersion = 1
        , spReplayPolicy = ReplayPolicyWarn
        , spInitialRewriteBudget = defaultRewriteBudget
        , spRewriteExhaustionPolicy = RewriteExhaustionFail
        , spBudgetExceededExhaustionPolicy = Nothing
        , spMaxRewriteReExecutions = 2
        , spTopology = topology
        , spDefinitions = definitions
        , spTemplateRegistry = mkTemplateRegistry definitions
        , spLoopRegistrations = Map.empty
        }

nodeIdFromCircuitRef :: CircuitNodeRef -> NodeId
nodeIdFromCircuitRef =
  NodeId . (.unCircuitNodeRef)

wireSmokeCompileEnv :: WireCompileEnv
wireSmokeCompileEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry =
        wireExecutorRegistryFromList
          [ wireExecutorProjectionFromPorts
              (WireExecutorId "stress_dimension")
              analysisFragmentInOutPorts
              WireExecutorModel
          ]
    }

wireSmokeAppendHole :: WireAppendHole
wireSmokeAppendHole =
  WireAppendHole
    { wireAppendHoleAnchor = CircuitNodeRef "analyst"
    , wireAppendHoleAnchorPorts = outputOnlyAnalysisFragmentPort
    , wireAppendHoleSuccessors = Map.singleton (CircuitNodeRef "reviewer") inputOnlyAnalysisFragmentPort
    }

wireSmokeProposalSource :: Text
wireSmokeProposalSource =
  T.unlines
    [ "node stress_alpha"
    , "  <- src: AnalysisFragment ;"
    , "  -> out: AnalysisFragment ;"
    , "= @stress_dimension {"
    , "  instructions = \"Stress-test alpha fragility.\";"
    , "} (src) ;"
    , ""
    , "node stress_beta"
    , "  <- src: AnalysisFragment ;"
    , "  -> out: AnalysisFragment ;"
    , "= @stress_dimension {"
    , "  instructions = \"Stress-test beta fragility.\";"
    , "} (src) ;"
    , ""
    , "(stress_alpha) <> (stress_beta)"
    ]

wireSmokePulseConfig :: CircuitPulseConfig
wireSmokePulseConfig =
  CircuitPulseConfig
    { circuitPulseInitialState = Aeson.object []
    , circuitPulseRuntimeVersion = 1
    , circuitPulseReplayPolicy = ReplayPolicyWarn
    , circuitPulseInitialRewriteBudget = defaultRewriteBudget
    , circuitPulseRewriteExhaustionPolicy = RewriteExhaustionFail
    , circuitPulseBudgetExceededExhaustionPolicy = Nothing
    , circuitPulseMaxRewriteReExecutions = 2
    }

wireSmokeBinder :: CircuitPulseBinder
wireSmokeBinder =
  CircuitPulseBinder
    { bindCircuitTaskNode = \taskNode ->
        let nodeId = nodeIdFromCircuitRef taskNode.circuitTaskNodeRef
         in Right
              ( nodeStage nodeId $ \ctx ->
                  pure
                    ( StageComplete
                        ( Aeson.object
                            [ "nodeId" Aeson..= unNodeId nodeId
                            , "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                            ]
                        )
                    )
              )
    , bindCircuitSignalBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "Wire smoke does not support signal nodes")
    , bindCircuitArtifactBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "Wire smoke does not support artifact nodes")
    , bindCircuitRewriteBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "Wire smoke does not support nested rewrite boundaries")
    , bindCircuitConditionNode = \_ -> Left (CircuitTemplateRegistryInvalid "Wire smoke does not support condition nodes")
    }

-- | A select over a producer that emits one of two output variants (ADR 0062 #314).
selectVariantSource :: Text
selectVariantSource =
  T.unlines
    [ "node produce"
    , "  -> ok: P | err: P ;"
    , "  = @test.produce ({}) ;"
    , "node handle_ok"
    , "  <- ok: P ;"
    , "  -> done: P"
    , "  = @test.handle_ok (ok) ;"
    , "node handle_err"
    , "  <- err: P ;"
    , "  -> done: P"
    , "  = @test.handle_err (err) ;"
    , "produce select("
    , "  ok: handle_ok,"
    , "  err: handle_err"
    , ")"
    ]

selectVariantPulseConfig :: CircuitPulseConfig
selectVariantPulseConfig =
  CircuitPulseConfig
    { circuitPulseInitialState = Aeson.Null
    , circuitPulseRuntimeVersion = 1
    , circuitPulseReplayPolicy = ReplayPolicyWarn
    , circuitPulseInitialRewriteBudget = defaultRewriteBudget
    , circuitPulseRewriteExhaustionPolicy = RewriteExhaustionFail
    , circuitPulseBudgetExceededExhaustionPolicy = Nothing
    , circuitPulseMaxRewriteReExecutions = 2
    }

{- | A binder where the producer emits the committed @err@ variant (incrementing an
invocation counter), and each arm increments its own counter so the test can assert
the recovery arm ran exactly once and the non-selected arm never ran. The condition
uses the production 'committedVariantConditionBinding'.
-}
selectVariantBinder :: IORef Int -> IORef Int -> IORef Int -> CircuitPulseBinder
selectVariantBinder produceCount recoverCount okCount =
  CircuitPulseBinder
    { bindCircuitTaskNode = \taskNode ->
        let nodeId = nodeIdFromCircuitRef taskNode.circuitTaskNodeRef
         in Right $ case unNodeId nodeId of
              "produce" ->
                nodeStage nodeId $ \_ -> do
                  atomicModifyIORef' produceCount (\c -> (c + 1, ()))
                  pure
                    ( StageComplete
                        ( Aeson.toJSON
                            ( ( mkWireValue
                                  "P"
                                  WirePayloadJson
                                  Nothing
                                  (Aeson.object ["issue" Aeson..= ("backend rejected" :: Text)])
                              )
                                { wireValuePort = Just "err"
                                }
                            )
                        )
                    )
              "handle_err" ->
                nodeStage nodeId $ \_ -> do
                  atomicModifyIORef' recoverCount (\c -> (c + 1, ()))
                  pure (StageComplete (Aeson.String "recovered"))
              "handle_ok" ->
                nodeStage nodeId $ \_ -> do
                  atomicModifyIORef' okCount (\c -> (c + 1, ()))
                  pure (StageComplete (Aeson.String "ok"))
              other ->
                nodeStage nodeId $ \_ -> pure (StageComplete (Aeson.String ("passthrough:" <> other)))
    , bindCircuitSignalBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "select-variant test: no signal nodes")
    , bindCircuitArtifactBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "select-variant test: no artifact nodes")
    , bindCircuitRewriteBoundary = \_ -> Left (CircuitTemplateRegistryInvalid "select-variant test: no rewrite boundaries")
    , bindCircuitConditionNode = committedVariantConditionBinding
    }

analysisFragmentInOutPorts :: WirePorts
analysisFragmentInOutPorts =
  WirePorts
    { wirePortsInputs = inputOnlyAnalysisFragmentPort.wirePortsInputs
    , wirePortsOutputs = outputOnlyAnalysisFragmentPort.wirePortsOutputs
    }

inputOnlyAnalysisFragmentPort :: WirePorts
inputOnlyAnalysisFragmentPort =
  WirePorts
    { wirePortsInputs =
        -- Named input port (not the default "in": that name is a reserved Wire
        -- keyword and cannot be authored in a fragment — tracked in #265).
        Map.singleton
          "src"
          (WireInputPort ["AnalysisFragment"] WireInputCardinalityMany False)
    , wirePortsOutputs = Map.empty
    }

outputOnlyAnalysisFragmentPort :: WirePorts
outputOnlyAnalysisFragmentPort =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.singleton
          defaultOutputPortName
          (WireOutputPort "AnalysisFragment" Nothing)
    }

mkLinearStagePlan
  :: StableStageId stageId
  => [StageDefinition stageId]
  -> Aeson.Value
  -> Int
  -> ReplayPolicy
  -> StagePlan stageId
mkLinearStagePlan stages initialState runtimeVersion replayPolicy =
  case Executor.mkLinearStagePlan stages initialState runtimeVersion replayPolicy defaultRewriteBudget of
    Left err -> error ("mkLinearStagePlan: " <> show err)
    Right plan -> plan

checkpointEnvelopeState :: PulseTaskDefinitionRow Result -> Text -> Aeson.Value -> Aeson.Value
checkpointEnvelopeState task checkpointName payload =
  Aeson.toJSON $
    buildCheckpointEnvelope
      task.taskType
      (taskEnvelopeVersionOrDefault task.config)
      1
      checkpointName
      payload

{- | Write graph state for the PaperPortfolioCycle 12-stage plan.
completedNames: which stage names should be marked completed.
-}
writeGraphStateCompleted :: Pool -> UUID -> Int -> [Text] -> Aeson.Value -> IO ()
writeGraphStateCompleted pool runId runtimeVersion completedNames outputValue = do
  let allNames = paperPortfolioCycleNodeNames
      allNodeIds = fmap NodeId allNames
      topology = toRelation (path allNodeIds)
      completedNodeIds = fmap NodeId completedNames
      gs0 = initialGraphState topology
      gs = foldl' (\s nid -> markCompleted nid outputValue s) gs0 completedNodeIds
  writeGraphStateCompat
    pool
    runId
    (Aeson.toJSON (gsNodeStatuses gs))
    (Aeson.toJSON (gsNodeOutputs gs))
    (Just (fromIntegral runtimeVersion :: Int32))
    Nothing

{- | The 12 stage node names of PaperPortfolioCycle in order.
Must match the StableStageId instance and buildStagePlan order.
-}
paperPortfolioCycleNodeNames :: [Text]
paperPortfolioCycleNodeNames =
  [ "strategy_resolution"
  , "preflight_snapshot"
  , "planner"
  , "gatherer"
  , "required_evidence_repair"
  , "analyst"
  , "reviewer"
  , "guardrails"
  , "execution_preflight"
  , "persist_decision"
  , "finalize_report"
  , "shadow_complete"
  ]

{- | Write graph state for a custom stage plan with the first N nodes completed.
Uses topological order to determine the prefix of completed nodes.
-}
writeGraphStateForPlan
  :: Pool
  -> UUID
  -> StagePlan stageId
  -> Int -- number of completed nodes (prefix in topological order)
  -> Aeson.Value
  -> IO ()
writeGraphStateForPlan pool runId stagePlan completedCount outputValue = do
  let topology = spTopology stagePlan
      nodeIds = case topSort topology of
        Just order -> order
        Nothing -> error "writeGraphStateForPlan: topology has cycles"
      completedNodeIds = take completedCount nodeIds
      gs0 = initialGraphState topology
      gs = foldl' (\s nid -> markCompleted nid outputValue s) gs0 completedNodeIds
  writeGraphStateCompat
    pool
    runId
    (Aeson.toJSON (gsNodeStatuses gs))
    (Aeson.toJSON (gsNodeOutputs gs))
    (Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32))
    Nothing

writeRawGraphStateForPlan
  :: Pool
  -> UUID
  -> StagePlan stageId
  -> GraphState Aeson.Value
  -> IO ()
writeRawGraphStateForPlan pool runId stagePlan gs =
  writeGraphStateCompat
    pool
    runId
    (Aeson.toJSON gs.gsNodeStatuses)
    (Aeson.toJSON gs.gsNodeOutputs)
    (Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32))
    Nothing

writeGraphStateCompat
  :: Pool
  -> UUID
  -> Aeson.Value
  -> Aeson.Value
  -> Maybe Int32
  -> Maybe Int64
  -> IO ()
writeGraphStateCompat pool runId statuses outputs runtimeVersion appliedRewriteId = do
  snapshot <- runSession pool $ Q.readGraphState runId
  now <- getCurrentTime
  result <-
    runTx pool $
      Q.writeGraphState
        Q.GraphStateWrite
          { gswRunId = runId
          , gswNodeStatuses = statuses
          , gswNodeOutputs = outputs
          , gswRemainingRewriteBudget = Nothing
          , gswRuntimeVersion = runtimeVersion
          , gswAppliedRewriteId = appliedRewriteId
          , gswNodeProvenance = Nothing
          , gswTopologyHash = Nothing
          , gswUpdatedAt = now
          , gswExpectedRevision = fmap Q.pgssRevision snapshot
          }
  case result of
    Q.GraphStateWriteApplied {} -> pure ()
    Q.GraphStateWriteStale -> expectationFailure "expected graph_state compatibility write to apply"

expectRecoveryPreconditionFailure :: Pool -> UUID -> Text -> IO ()
expectRecoveryPreconditionFailure pool runId expectedMessageSnippet = do
  runView <- runSession pool $ Q.getRunAdminView runId
  case runView of
    Nothing -> expectationFailure "Expected run admin view"
    Just view -> do
      Q.pravErrorType view `shouldBe` Just "graph_state_recovery_preconditions_failed"
      case Q.pravErrorMessage view of
        Nothing -> expectationFailure "Expected recovery precondition error message"
        Just errMsg -> errMsg `shouldSatisfy` T.isInfixOf expectedMessageSnippet

installGraphStateWriteFailureInjector :: Pool -> IO ()
installGraphStateWriteFailureInjector pool =
  runSession pool $ do
    Session.sql
      "CREATE TABLE IF NOT EXISTS pulse.test_graph_state_write_failures (\
      \  run_id UUID PRIMARY KEY,\
      \  fail_on_write INT NOT NULL,\
      \  write_count INT NOT NULL DEFAULT 0\
      \)"
    Session.sql
      "CREATE OR REPLACE FUNCTION pulse.test_fail_graph_state_write() RETURNS trigger AS $$\
      \DECLARE\
      \  cfg RECORD;\
      \BEGIN\
      \  SELECT * INTO cfg FROM pulse.test_graph_state_write_failures WHERE run_id = NEW.run_id;\
      \  IF cfg.run_id IS NULL THEN\
      \    RETURN NEW;\
      \  END IF;\
      \  UPDATE pulse.test_graph_state_write_failures\
      \     SET write_count = write_count + 1\
      \   WHERE run_id = NEW.run_id\
      \   RETURNING write_count, fail_on_write INTO cfg.write_count, cfg.fail_on_write;\
      \  IF cfg.write_count >= cfg.fail_on_write THEN\
      \    RAISE EXCEPTION 'injected graph_state write failure for run %', NEW.run_id;\
      \  END IF;\
      \  RETURN NEW;\
      \END;\
      \$$ LANGUAGE plpgsql"
    Session.sql
      "DO $$\
      \BEGIN\
      \  IF NOT EXISTS (\
      \    SELECT 1 FROM pg_trigger\
      \    WHERE tgname = 'pulse_test_fail_graph_state_write'\
      \      AND tgrelid = 'pulse.graph_state'::regclass\
      \  ) THEN\
      \    CREATE TRIGGER pulse_test_fail_graph_state_write \
      \    BEFORE INSERT OR UPDATE ON pulse.graph_state \
      \    FOR EACH ROW \
      \    EXECUTE FUNCTION pulse.test_fail_graph_state_write();\
      \  END IF;\
      \END;\
      \$$"

installRunFailedWriteFailureInjector :: Pool -> IO ()
installRunFailedWriteFailureInjector pool =
  runSession pool $ do
    Session.sql
      "CREATE TABLE IF NOT EXISTS pulse.test_run_failed_write_failures (\
      \  run_id UUID PRIMARY KEY\
      \)"
    Session.sql
      "CREATE OR REPLACE FUNCTION pulse.test_fail_run_failed_write() RETURNS trigger AS $$\
      \BEGIN\
      \  IF NEW.status = 'failed'::pulse.run_status\
      \     AND EXISTS (SELECT 1 FROM pulse.test_run_failed_write_failures WHERE run_id = NEW.run_id) THEN\
      \    RAISE EXCEPTION 'injected run failed write failure for run %', NEW.run_id;\
      \  END IF;\
      \  RETURN NEW;\
      \END;\
      \$$ LANGUAGE plpgsql"
    Session.sql
      "DO $$\
      \BEGIN\
      \  IF NOT EXISTS (\
      \    SELECT 1 FROM pg_trigger\
      \    WHERE tgname = 'pulse_test_fail_run_failed_write'\
      \      AND tgrelid = 'pulse.runs'::regclass\
      \  ) THEN\
      \    CREATE TRIGGER pulse_test_fail_run_failed_write \
      \    BEFORE UPDATE ON pulse.runs \
      \    FOR EACH ROW \
      \    EXECUTE FUNCTION pulse.test_fail_run_failed_write();\
      \  END IF;\
      \END;\
      \$$"

withInjectedGraphStateWriteFailure :: Pool -> UUID -> Int -> IO a -> IO a
withInjectedGraphStateWriteFailure pool runId failOnWrite action = do
  installGraphStateWriteFailureInjector pool
  let deleteStmt =
        Statement
          "DELETE FROM pulse.test_graph_state_write_failures WHERE run_id = $1"
          (Enc.encode1 (id, Enc.nonNullable Enc.uuid))
          D.noResult
          False
      insertStmt =
        Statement
          "INSERT INTO pulse.test_graph_state_write_failures (run_id, fail_on_write, write_count) VALUES ($1, $2, 0)"
          (Enc.encode2 (fst, Enc.nonNullable Enc.uuid) (snd, Enc.nonNullable Enc.int4))
          D.noResult
          False
  runSession pool $ Session.statement runId deleteStmt
  runSession pool $ Session.statement (runId, fromIntegral failOnWrite :: Int32) insertStmt
  action `finally` runSession pool (Session.statement runId deleteStmt)

withInjectedRunFailedWriteFailure :: Pool -> UUID -> IO a -> IO a
withInjectedRunFailedWriteFailure pool runId action = do
  installRunFailedWriteFailureInjector pool
  let deleteStmt =
        Statement
          "DELETE FROM pulse.test_run_failed_write_failures WHERE run_id = $1"
          (Enc.encode1 (id, Enc.nonNullable Enc.uuid))
          D.noResult
          False
      insertStmt =
        Statement
          "INSERT INTO pulse.test_run_failed_write_failures (run_id) VALUES ($1)"
          (Enc.encode1 (id, Enc.nonNullable Enc.uuid))
          D.noResult
          False
  runSession pool $ Session.statement runId deleteStmt
  runSession pool $ Session.statement runId insertStmt
  action `finally` runSession pool (Session.statement runId deleteStmt)

waitForGraphStatuses
  :: Pool
  -> UUID
  -> (Map.Map NodeId NodeStatus -> Bool)
  -> IO (Map.Map NodeId NodeStatus)
waitForGraphStatuses pool runId predicate =
  go (80 :: Int)
  where
    go 0 =
      expectationFailure "Timed out waiting for persisted graph state"
        >> pure Map.empty
    go attemptsLeft = do
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Just m | predicate m -> pure m
        _ -> do
          threadDelay 50_000
          go (attemptsLeft - 1)

-- | A submit/park/resume runtime binding record for the external-call stage tests.
externalCallBinding :: RuntimeBindingRecord
externalCallBinding =
  RuntimeBindingRecord
    { rbrBindingId = "braket-pack/quantum.realize"
    , rbrBindingVersion = "1"
    , rbrExecutorId = WireExecutorId "quantum.realize"
    , rbrProjectionVersion = ProjectionVersion "1"
    , rbrStageActionRef = RuntimeStageActionRef "quantum.realize.braket"
    , rbrManifestContentAddress = ContentAddress "sha256:m"
    , rbrArtifactDigest = ContentDigest "d"
    , rbrAbiKind = AbiSubprocessJsonl
    , rbrAbiVersion = "1"
    , rbrAbiDriverDigest = ContentDigest "dd"
    , rbrBindingPackIdentity = "braket-pack"
    , rbrResolvedAuthorities = []
    , rbrIsolation = SubprocessSandbox
    , rbrAcceptedReplayClass = IdempotentWithKey
    , rbrAcceptedAwaitStrategy = SubmitParkResume
    , rbrCompatibilityDigest = ContentDigest "c"
    }

externalCallPorts :: WirePorts
externalCallPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.fromList [("s01", WireOutputPort "MeasurementBit" Nothing)]
    }

externalCallOutputs :: [(Text, Aeson.Value)]
externalCallOutputs = [("s01", Aeson.toJSON (1 :: Int))]

externalCallPlan :: Aeson.Value
externalCallPlan = Aeson.object ["operations" Aeson..= [Aeson.object ["gate" Aeson..= ("cnot" :: Text)]]]

spec :: Spec
spec = beforeAll setupTestDb $ do
  describe "select on a committed output variant (ADR 0062, #314)" $ do
    it "routes the committed err variant to the recovery arm and resumes without re-running the effect" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-select-committed-variant"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      produceCount <- newIORef (0 :: Int)
      recoverCount <- newIORef (0 :: Int)
      okCount <- newIORef (0 :: Int)
      compiled <-
        case compileWireText selectVariantSource of
          Right circuit -> pure circuit
          Left err -> expectationFailure ("compile failed: " <> show err) >> fail "unreachable"
      stagePlan <-
        case lowerCompiledCircuitToStagePlan
          selectVariantPulseConfig
          (selectVariantBinder produceCount recoverCount okCount)
          compiled of
          Right plan -> pure plan
          Left err -> expectationFailure ("lowering failed: " <> show err) >> fail "unreachable"
      -- Execute: the producer emits the err variant; select routes to the recovery arm.
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeCompleted
      readIORef produceCount `shouldReturn` 1
      readIORef recoverCount `shouldReturn` 1
      readIORef okCount `shouldReturn` 0
      statuses <-
        readGraphNodeStatuses pool runId
          >>= maybe (expectationFailure "expected persisted graph state" >> fail "unreachable") pure
      -- The recovery arm materialized and ran; the non-selected ok arm never materialized.
      let completedNodes = [nid | (nid, NodeCompleted) <- Map.toList statuses]
      any (T.isInfixOf "handle_err" . unNodeId) completedNodes `shouldBe` True
      any (T.isInfixOf "handle_ok" . unNodeId) (Map.keys statuses) `shouldBe` False
      -- Simulate a crash/resume: re-running the executor on the persisted run must not
      -- re-run the producer effect or the recovery arm.
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      readIORef produceCount `shouldReturn` 1
      readIORef recoverCount `shouldReturn` 1

  describe "durable external-call stages (ADR 0059)" $ do
    it "submits, parks, refuses forged wakes, then completes from the driver on resume" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-ec-stage-happy"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      fetchCount <- newIORef (0 :: Int)
      capturedKey <- newIORef Nothing
      let driver =
            ExternalCallDriver
              { driverRunSync = \_ -> pure (Right externalCallOutputs)
              , driverSubmit = \ctx ->
                  writeIORef capturedKey (Just (ecAttemptKey ctx)) >> pure (Right (Aeson.String "job-1"))
              , driverFetch = \_ -> modifyIORef' fetchCount (+ 1) >> pure (FetchCompleted externalCallOutputs)
              , driverIdempotencyKey = const "idem-fixed"
              }
          stage =
            bindExternalCallStage
              driver
              (pulseAttemptStore pool)
              externalCallBinding
              (NodeId "realize")
              "frontier-happy"
              externalCallPlan
              externalCallPorts
              Nothing
          stagePlan = mkLinearStagePlan [stage] Aeson.Null 1 ReplayPolicyWarn
      -- Phase 1: submit + park.
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeSuspended
      readRunStatus pool runId `shouldReturn` Just "waiting"
      readIORef fetchCount `shouldReturn` 0
      Just key <- readIORef capturedKey
      attempt <- runTx pool (loadExternalCallAttempt key)
      fmap ecaStatus attempt `shouldBe` Just "submitted"
      let sigText = unSignalName (externalCallSignalName (externalCallSignalSuffix key))
      (ecaSignalName =<< attempt) `shouldBe` Just sigText
      -- Anti-forgery: ordinary deliverSignal of the reserved name is refused, run still parked.
      now0 <- getCurrentTime
      forged <- runTx pool (Q.deliverSignal runId sigText (Aeson.String "forged") now0)
      forged `shouldBe` False
      readRunStatus pool runId `shouldReturn` Just "waiting"
      readIORef fetchCount `shouldReturn` 0
      -- Phase 2: trusted wake.
      now <- getCurrentTime
      woke <- runTx pool (Q.deliverExternalCallSignal key (Aeson.String "wake-marker") now)
      woke `shouldBe` True
      readRunStatus pool runId `shouldReturn` Just "pending"
      -- Phase 3: resume -> re-arm -> driverFetch -> complete from the driver result.
      runTx pool (Q.updateRunStarted runId now)
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      readRunStatus pool runId `shouldReturn` Just "completed"
      readIORef fetchCount `shouldReturn` 1
      settled <- runTx pool (loadExternalCallAttempt key)
      fmap ecaStatus settled `shouldBe` Just "settled"
      -- The node output is the driver's result (one wrapped value per measurement port).
      outputs <- readGraphNodeOutputs pool runId
      case outputs of
        Just (nodeOutputs, _) -> Map.size nodeOutputs `shouldBe` 1
        Nothing -> expectationFailure "Expected persisted node outputs after completion"

    it "re-suspends when the provider job is not yet terminal, then completes on a later wake" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-ec-stage-not-ready"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      fetchCount <- newIORef (0 :: Int)
      capturedKey <- newIORef Nothing
      let driver =
            ExternalCallDriver
              { driverRunSync = \_ -> pure (Right externalCallOutputs)
              , driverSubmit = \ctx ->
                  writeIORef capturedKey (Just (ecAttemptKey ctx)) >> pure (Right (Aeson.String "job-2"))
              , -- First fetch: not ready (re-suspend). Second fetch: ready.
                driverFetch = \_ -> do
                  n <- atomicModifyIORef' fetchCount (\c -> (c + 1, c + 1))
                  if n == 1 then pure FetchNotReady else pure (FetchCompleted externalCallOutputs)
              , driverIdempotencyKey = const "idem-fixed"
              }
          stage =
            bindExternalCallStage
              driver
              (pulseAttemptStore pool)
              externalCallBinding
              (NodeId "realize")
              "frontier-not-ready"
              externalCallPlan
              externalCallPorts
              Nothing
          stagePlan = mkLinearStagePlan [stage] Aeson.Null 1 ReplayPolicyWarn
      -- Submit + park.
      executeStagePlan taskContext runId task stagePlan `shouldReturn` OutcomeSuspended
      Just key <- readIORef capturedKey
      -- First wake -> resume -> not-ready -> re-suspend (still waiting, attempt still submitted).
      now1 <- getCurrentTime
      _ <- runTx pool (Q.deliverExternalCallSignal key (Aeson.String "wake-1") now1)
      runTx pool (Q.updateRunStarted runId now1)
      resumeStagePlan taskContext runId task stagePlan `shouldReturn` OutcomeSuspended
      readRunStatus pool runId `shouldReturn` Just "waiting"
      readIORef fetchCount `shouldReturn` 1
      stillSubmitted <- runTx pool (loadExternalCallAttempt key)
      fmap ecaStatus stillSubmitted `shouldBe` Just "submitted"
      -- Second wake -> resume -> ready -> complete.
      now2 <- getCurrentTime
      _ <- runTx pool (Q.deliverExternalCallSignal key (Aeson.String "wake-2") now2)
      runTx pool (Q.updateRunStarted runId now2)
      resumeStagePlan taskContext runId task stagePlan `shouldReturn` OutcomeCompleted
      readRunStatus pool runId `shouldReturn` Just "completed"
      readIORef fetchCount `shouldReturn` 2

  describe "Pulse Executor" $ do
    it "caps exponential retry backoff before Int overflow" $ \_mPool -> do
      retryDelayMicros (FixedBackoffMicros maxBound) 1 `shouldBe` 300_000_000
      retryDelayMicros (ExponentialBackoffMicros 1_000_000) 32 `shouldBe` 300_000_000
      retryDelayMicros (ExponentialBackoffMicros maxBound) 2 `shouldBe` 300_000_000

    it "rejects non-positive stage attempt numbers at the database layer" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-attempt-number-constraint"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      logId <- runTx pool $ Q.appendStageStarted runId "test_alpha" now
      result <- DB.runTransaction pool $ Q.appendStageAttemptStarted logId runId 0 now
      case result of
        Left _ -> pure ()
        Right attemptId ->
          expectationFailure $
            "Expected attempt_number constraint failure, got attempt_id " <> show attemptId

    it "executes all stages for a fresh run (stub actions)" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-exec-fresh"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      outcome <- executeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 12

    it "resumes from graph state (skips completed stages)" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-cp"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Write graph state with first stage completed (replaces the old checkpoint at strategy_resolution)
      -- Runtime version 4 matches the fallback PaperPortfolioCycle stage plan
      writeGraphStateCompleted pool runId 4 ["strategy_resolution"] Aeson.Null
      outcome <- resumeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 11

    it "cancellation before first stage marks run cancelled" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-cancel"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      runTx pool $ Q.requestCancellation runId "test cancellation" now
      task <- loadTaskDef pool taskId
      outcome <- executeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCancelled
      status <- readRunStatus pool runId
      status `shouldBe` Just "cancelled"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 0

    it "resume with empty graph state starts from scratch" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-fresh"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Write graph state with no completed stages (all pending)
      -- Runtime version 4 matches the fallback PaperPortfolioCycle stage plan
      writeGraphStateCompleted pool runId 4 [] Aeson.Null
      outcome <- resumeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 12

    it "resume ignores stale checkpoint when no graph state exists" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-corrupt"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      -- Write a checkpoint with a nonexistent stage — irrelevant because
      -- resume is driven by graph state, not checkpoints. With no graph
      -- state, the run starts from scratch.
      runTx pool $
        Q.writeCheckpoint
          runId
          "paper_portfolio_cycle"
          "nonexistent_stage"
          (checkpointEnvelopeState task "nonexistent_stage" Aeson.Null)
          Nothing
          now
      outcome <- resumeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"

    it "resume with no graph state starts from scratch" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-no-graph-state"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- No graph state written — simulates crash before first node completed.
      -- Should start from scratch, not fail.
      outcome <- resumeTask stubPlanTaskRegistry taskContext runId task
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 12

    it "fails unregistered task types directly without entering the stage runner" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "response_eval_run" "test-unregistered-task"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      outcome <- executeTask Map.empty taskContext runId task
      outcome `shouldBe` OutcomeFailed
      status <- readRunStatus pool runId
      status `shouldBe` Just "failed"
      logCount <- countStageLogs pool runId
      logCount `shouldBe` 0

    it "retries a retryable stage and records the successful retry attempt" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-retry"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      retryContextsRef <- newIORef ([] :: [Maybe StageRetryFailureContext])
      let retryPolicy =
            StageRetryPolicy
              { srpPredicateName = "test_retry"
              , srpMaxAttempts = 2
              , srpBackoff = FixedBackoffMicros 0
              , srpRetryable = \case
                  StageFailureException _ -> True
                  StageFailureTimeout _ -> False
                  StageFailureTyped _ _ -> False
              , srpExhaustion = ExhaustionFailsRun
              }
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Just retryPolicy
                  , sdAction = \ctx -> do
                      atomicModifyIORef' retryContextsRef (\contexts -> (contexts <> [ctx.scRetryFailure], ()))
                      attempt <- atomicModifyIORef' attemptsRef (\n -> let next = n + 1 in (next, next))
                      if attempt == 1
                        then throwIO (userError "retryable failure")
                        else pure (StageComplete (Aeson.toJSON ctx.scInputs))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      attempts <- readIORef attemptsRef
      attempts `shouldBe` 2
      retryContexts <- readIORef retryContextsRef
      case retryContexts of
        [Nothing, Just retryFailure] -> do
          retryFailure.srfcPreviousAttempt `shouldBe` 1
          retryFailure.srfcFailureType `shouldBe` "stage_failure"
          retryFailure.srfcFailureMessage `shouldSatisfy` T.isInfixOf "retryable failure"
        other ->
          expectationFailure ("Expected retry failure context on the second attempt, got: " <> show other)
      logs <- readStageLogs pool runId
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psldStatus logs `shouldBe` ["completed"]
      fmap psldStateSummary logs `shouldBe` [Just (Aeson.object ["attempts" Aeson..= (2 :: Int)])]
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1, 2]
      fmap psaldStatus attemptLogs `shouldBe` ["failed", "completed"]

    it "re-checks cancellation before retrying another attempt" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-retry-cancelled"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let retryPolicy =
            StageRetryPolicy
              { srpPredicateName = "test_retry"
              , srpMaxAttempts = 2
              , srpBackoff = FixedBackoffMicros 0
              , srpRetryable = \case
                  StageFailureException _ -> True
                  StageFailureTimeout _ -> False
                  StageFailureTyped _ _ -> False
              , srpExhaustion = ExhaustionFailsRun
              }
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Just retryPolicy
                  , sdAction = liftChainAction $ \_runId _state -> do
                      attempt <- atomicModifyIORef' attemptsRef (\n -> let next = n + 1 in (next, next))
                      when (attempt == 1) $ do
                        now <- getCurrentTime
                        runTx pool $ Q.requestCancellation runId "cancel before retry" now
                      throwIO (userError "retryable failure")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCancelled
      attempts <- readIORef attemptsRef
      attempts `shouldBe` 1
      status <- readRunStatus pool runId
      status `shouldBe` Just "cancelled"
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1]
      fmap psaldStatus attemptLogs `shouldBe` ["failed"]
      stageLogs <- readStageLogs pool runId
      fmap psldStatus stageLogs `shouldBe` ["failed"]
      fmap psldStateSummary stageLogs `shouldBe` [Just (Aeson.String "Cancelled before retry attempt")]
      fmap psldCompletedAt stageLogs `shouldSatisfy` all isJust

    it "re-checks shutdown before retrying another attempt" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-retry-shutdown"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let retryPolicy =
            StageRetryPolicy
              { srpPredicateName = "test_retry"
              , srpMaxAttempts = 2
              , srpBackoff = FixedBackoffMicros 0
              , srpRetryable = \case
                  StageFailureException _ -> True
                  StageFailureTimeout _ -> False
                  StageFailureTyped _ _ -> False
              , srpExhaustion = ExhaustionFailsRun
              }
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Just retryPolicy
                  , sdAction = liftChainAction $ \_runId _state -> do
                      attempt <- atomicModifyIORef' attemptsRef (\n -> let next = n + 1 in (next, next))
                      when (attempt == 1) (atomically (writeTVar shutdownFlag True))
                      throwIO (userError "retryable failure")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeShutdown
      attempts <- readIORef attemptsRef
      attempts `shouldBe` 1
      status <- readRunStatus pool runId
      status `shouldBe` Just "running"
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1]
      fmap psaldStatus attemptLogs `shouldBe` ["failed"]

    it "responds to shutdown during retry backoff without waiting for full delay" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-shutdown-during-backoff"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let retryPolicy =
            StageRetryPolicy
              { srpPredicateName = "test_retry"
              , srpMaxAttempts = 3
              , srpBackoff = FixedBackoffMicros 30_000_000
              , srpRetryable = \case
                  StageFailureException _ -> True
                  StageFailureTimeout _ -> False
                  StageFailureTyped _ _ -> False
              , srpExhaustion = ExhaustionFailsRun
              }
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Just retryPolicy
                  , sdAction = liftChainAction $ \_runId _state -> do
                      attempt <- atomicModifyIORef' attemptsRef (\n -> let next = n + 1 in (next, next))
                      when (attempt == 1) (atomically (writeTVar shutdownFlag True))
                      throwIO (userError "retryable failure")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      startTime <- getCurrentTime
      outcome <- executeStagePlan taskContext runId task stagePlan
      endTime <- getCurrentTime
      outcome `shouldBe` OutcomeShutdown
      let elapsedSeconds = realToFrac (diffUTCTime endTime startTime) :: Double
      elapsedSeconds `shouldSatisfy` (< 5)

    it "skips a stage after retry budget exhaustion when configured" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-skip"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      nextStageRuns <- newIORef (0 :: Int)
      let retryPolicy =
            StageRetryPolicy
              { srpPredicateName = "test_retry"
              , srpMaxAttempts = 2
              , srpBackoff = FixedBackoffMicros 0
              , srpRetryable = \case
                  StageFailureException _ -> True
                  StageFailureTimeout _ -> False
                  StageFailureTyped _ _ -> False
              , srpExhaustion = ExhaustionSkipsStage
              }
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Just retryPolicy
                  , sdAction = liftChainAction $ \_runId _state -> throwIO (userError "keep failing")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              , simpleStage TestStageBeta $ \_runId state -> do
                  atomicModifyIORef' nextStageRuns (\n -> (n + 1, ()))
                  pure state
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      runs <- readIORef nextStageRuns
      runs `shouldBe` 1
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      logs <- readStageLogs pool runId
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psldStatus logs `shouldBe` ["skipped", "completed"]
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1, 2, 1]
      fmap psaldStatus attemptLogs `shouldBe` ["failed", "failed", "completed"]

    it "enforces per-stage timeout and marks the run timed out" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-timeout"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Just 1
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> do
                      threadDelay 1_500_000
                      pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeTimedOut
      status <- readRunStatus pool runId
      status `shouldBe` Just "timeout"
      logs <- readStageLogs pool runId
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psldStatus logs `shouldBe` ["failed"]
      fmap psaldStatus attemptLogs `shouldBe` ["failed"]

    it "resumes correctly when a stage was started but not completed before crash" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-started-only"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      betaRuns <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> do
                      atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                      pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      runs <- readIORef betaRuns
      runs `shouldBe` 1
      logs <- readStageLogs pool runId
      fmap psldStageName logs `shouldBe` ["test_beta"]
      fmap psldStatus logs `shouldBe` ["completed"]
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psaldStageLogId attemptLogs `shouldBe` fmap psldId logs
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1]

    it "resumes retry history on an open stage log after a crash between attempts" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-between-attempts"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      logId <- runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        existingLogId <- Q.appendStageStarted runId "test_beta" now
        attemptId <- Q.appendStageAttemptStarted existingLogId runId 1 now
        Q.updateStageAttemptCompleted
          attemptId
          StageFailed
          ( Just
              (Aeson.object ["attempt_number" Aeson..= (1 :: Int), "error" Aeson..= ("retryable failure" :: Text)])
          )
          now
        pure existingLogId
      betaRuns <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> do
                      atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                      pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      runs <- readIORef betaRuns
      runs `shouldBe` 1
      logs <- readStageLogs pool runId
      fmap psldId logs `shouldBe` [logId]
      fmap psldStatus logs `shouldBe` ["completed"]
      fmap psldStateSummary logs `shouldBe` [Just (Aeson.object ["attempts" Aeson..= (2 :: Int)])]
      attemptLogs <- readStageAttemptLogs pool runId
      fmap psaldStageLogId attemptLogs `shouldBe` [logId, logId]
      fmap psaldAttemptNumber attemptLogs `shouldBe` [1, 2]
      fmap psaldStatus attemptLogs `shouldBe` ["failed", "completed"]

    it "resumes past a stage when checkpoint exists but completion log is missing" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-checkpoint-only"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        _ <- Q.appendStageStarted runId "test_alpha" now
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
      betaRuns <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , simpleStage TestStageBeta $ \_runId state -> do
                  atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                  pure state
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      runs <- readIORef betaRuns
      runs `shouldBe` 1
      logs <- readStageLogs pool runId
      fmap psldStatus logs `shouldBe` ["started", "completed"]
      fmap psldStageName logs `shouldBe` ["test_alpha", "test_beta"]

    it "replays a stage when completion log exists but checkpoint is stale" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <-
        insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-completed-log-stale-checkpoint"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        logId <- Q.appendStageStarted runId "test_beta" now
        Q.updateStageCompleted logId StageCompleted Nothing now
      betaRuns <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> do
                      atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                      pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      runs <- readIORef betaRuns
      runs `shouldBe` 1
      logs <- readStageLogs pool runId
      fmap psldStatus logs `shouldBe` ["completed", "completed"]

    it "stops between stages when shutdown is requested and resumes from the checkpoint" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-shutdown-between-stages"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      betaRuns <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha $ \_runId state -> do
                  atomically $ writeTVar shutdownFlag True
                  pure state
              , simpleStage TestStageBeta $ \_runId state -> do
                  atomicModifyIORef' betaRuns (\n -> (n + 1, ()))
                  pure state
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      firstOutcome <- executeStagePlan taskContext runId task stagePlan
      firstOutcome `shouldBe` OutcomeShutdown
      firstStatus <- readRunStatus pool runId
      firstStatus `shouldBe` Just "running"
      betaAfterShutdown <- readIORef betaRuns
      betaAfterShutdown `shouldBe` 0
      atomically $ writeTVar shutdownFlag False
      secondOutcome <- resumeStagePlan taskContext runId task stagePlan
      secondOutcome `shouldBe` OutcomeCompleted
      finalStatus <- readRunStatus pool runId
      finalStatus `shouldBe` Just "completed"
      betaAfterResume <- readIORef betaRuns
      betaAfterResume `shouldBe` 1

    it "rethrows async exceptions from stage actions" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stage-async-exception"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha $ \_runId _state ->
                  throwIO ThreadKilled
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      result <-
        try (executeStagePlan taskContext runId task stagePlan) :: IO (Either SomeException RunOutcome)
      case result of
        Left _ -> pure ()
        Right outcome -> expectationFailure $ "Expected async exception to be rethrown, got outcome: " <> show outcome

    -- ========================================================================
    -- Replay policy enforcement
    -- ========================================================================

    it "block_resume policy blocks replay of irreversible stage with prior logs" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-replay-block"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      -- Pre-seed: checkpoint at Alpha, prior stage log for Beta (simulating prior execution)
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyBlockResume
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "replay_blocked")

    it "warn policy allows replay of irreversible stage with prior logs" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-replay-warn"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted

    it "per-stage replay policy override escalates past plan default" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-replay-override"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Just ReplayPolicyBlockResume
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "replay_blocked")

    it "require_operator_override policy blocks with distinct error type" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-replay-operator-override"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = Irreversible
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyRequireOperatorOverride
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "replay_blocked_operator_override_required")

    it "SafeToReplay stage ignores replay policy entirely" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-replay-safe-ignores-policy"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      runTx pool $ do
        Q.writeCheckpoint
          runId
          task.taskType
          "test_alpha"
          (checkpointEnvelopeState task "test_alpha" Aeson.Null)
          Nothing
          now
        _ <- Q.appendStageStarted runId "test_beta" now
        pure ()
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyBlockResume
      writeGraphStateForPlan pool runId stagePlan 1 Aeson.Null
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted

    -- ==========================================================================
    -- Signal suspension integration tests
    -- ==========================================================================

    it "stage returning StageSuspend transitions run to waiting" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-suspend"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (SignalName "test_signal"))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      status <- readRunStatus pool runId
      status `shouldBe` Just "waiting"

    it "deliverSignal wakes a waiting run to pending" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-deliver"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (SignalName "fill_event"))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      -- Run is now waiting
      status1 <- readRunStatus pool runId
      status1 `shouldBe` Just "waiting"
      -- Deliver the signal
      now <- getCurrentTime
      delivered <- runTx pool $ Q.deliverSignal runId "fill_event" (Aeson.String "fill_payload") now
      delivered `shouldBe` True
      -- Run should now be pending (woken by deliverSignal)
      status2 <- readRunStatus pool runId
      status2 `shouldBe` Just "pending"

    it "run-terminal wake ordering is deterministic and de-duplicates parents" $ \_mPool -> do
      let runA = UUID.fromWords 0 0 0 1
          runB = UUID.fromWords 0 0 0 2
          runC = UUID.fromWords 0 0 0 3
      Q.orderWokenRunIdsForUpdate [runC, runA, runB, runA, runC]
        `shouldBe` [runA, runB, runC]

    it "deliverSignal refuses to forge a reserved run-terminal name" $ \mPool -> withDb mPool $ \pool -> do
      -- External/host delivery must not be able to complete a run-terminal
      -- waiter while the awaited run is still running — that would spoof the
      -- await-a-run primitive. The run-terminal:<uuid> namespace is runtime-only.
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-forge-parent"
      parentRunId <- createTestRun pool taskId
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-forge-child"
      childRunId <- createTestRun pool childTaskId
      task <- loadTaskDef pool taskId
      let signalName = runTerminalSignalName childRunId
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend signalName)
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      -- A host tries to forge the run-terminal delivery while the child runs.
      now <- getCurrentTime
      forged <-
        runTx pool $
          Q.deliverSignal parentRunId (unSignalName signalName) (Aeson.String "forged") now
      forged `shouldBe` False
      -- The waiter is untouched: still waiting, signal still pending.
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "waiting"
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Just "pending"

    it "run-terminal compatibility registration refuses a missing target" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-missing-compat"
      parentRunId <- createTestRun pool taskId
      now <- getCurrentTime
      let signalName = runTerminalSignalName UUID.nil
      registration <-
        runTx pool $
          Q.registerSignalWaitOrResolve parentRunId (NodeId "awaiter") signalName now Nothing
      registration `shouldBe` Q.SignalWaitMissingRun UUID.nil
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Nothing

    it "run-terminal compatibility registration refuses a self-target" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-self-compat"
      parentRunId <- createTestRun pool taskId
      now <- getCurrentTime
      let signalName = runTerminalSignalName parentRunId
      registration <-
        runTx pool $
          Q.registerSignalWaitOrResolve parentRunId (NodeId "awaiter") signalName now Nothing
      registration
        `shouldBe` Q.SignalWaitRegistrationInvalid
          (Q.SignalWaitInvalidSelfRunTerminal parentRunId)
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Nothing

    it "signal wait registration rejects duplicate pending ownership" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-duplicate-compat"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      let signalName = SignalName "shared_event"
      first <-
        runTx pool $
          Q.registerSignalWaitOrResolve runId (NodeId "first") signalName now Nothing
      first `shouldBe` Q.SignalWaitRegistered
      sameNodeAgain <-
        runTx pool $
          Q.registerSignalWaitOrResolve runId (NodeId "first") signalName now Nothing
      sameNodeAgain `shouldBe` Q.SignalWaitRegistered
      duplicate <-
        runTx pool $
          Q.registerSignalWaitOrResolve runId (NodeId "second") signalName now Nothing
      duplicate
        `shouldBe` Q.SignalWaitRegistrationInvalid
          (Q.SignalWaitInvalidDuplicatePending "shared_event" (NodeId "first"))
      sigStatus <- runTx pool $ Q.lookupSignalStatus runId (unSignalName signalName)
      sigStatus `shouldBe` Just "pending"

    it "raw signal wait registration surfaces duplicate pending rows" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-duplicate-raw"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      let signalName = SignalName "raw_shared_event"
      result <-
        DB.runTransaction pool $ do
          Q.registerSignalWait runId (NodeId "first") signalName now Nothing
          Q.registerSignalWait runId (NodeId "second") signalName now Nothing
      case result of
        Left _err ->
          pure ()
        Right () ->
          expectationFailure "Expected duplicate pending signal registration to fail"
      sigStatus <- runTx pool $ Q.lookupSignalStatus runId (unSignalName signalName)
      sigStatus `shouldBe` Nothing

    it "run-terminal signal wakes a cross-run waiter" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-waiter"
      parentRunId <- createTestRun pool taskId
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-child"
      childRunId <- createTestRun pool childTaskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (runTerminalSignalName childRunId))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      status1 <- readRunStatus pool parentRunId
      status1 `shouldBe` Just "waiting"
      -- The child reaches terminal status through the regular status writer;
      -- delivery is centralized inside it and crosses runs by name.
      now <- getCurrentTime
      _ <- runTx pool $ Q.updateRunCompleted childRunId now
      status2 <- readRunStatus pool parentRunId
      status2 `shouldBe` Just "pending"

    it "resolves a wait on an already-terminal run without parking" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-resolved"
      parentRunId <- createTestRun pool taskId
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-done"
      childRunId <- createTestRun pool childTaskId
      now0 <- getCurrentTime
      _ <- runTx pool $ Q.updateRunCompleted childRunId now0
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (runTerminalSignalName childRunId))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      -- The awaited run is already terminal: the wait resolves at
      -- registration and the parent completes instead of suspending.
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "completed"

    it "run-terminal late waits resolve for every terminal status" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      let terminalCases =
            [
              ( "completed" :: Text
              , "completed" :: Text
              , Q.updateRunCompleted
              )
            ,
              ( "failed"
              , "failed"
              , \childRunId now ->
                  Q.updateRunFailed
                    Q.RunFailureUpdate
                      { Q.rfuRunId = childRunId
                      , Q.rfuCompletedAt = now
                      , Q.rfuErrType = "child_failed"
                      , Q.rfuErrMsg = "child failed"
                      , Q.rfuRetryable = False
                      }
              )
            ,
              ( "cancelled"
              , "cancelled"
              , \childRunId now -> Q.updateRunCancelled childRunId now "child cancelled"
              )
            ,
              ( "timeout"
              , "timeout"
              , \childRunId now ->
                  Q.updateRunTimedOut
                    Q.RunTimeoutUpdate
                      { Q.rtuRunId = childRunId
                      , Q.rtuCompletedAt = now
                      , Q.rtuErrType = "timeout"
                      , Q.rtuErrMsg = "child timed out"
                      }
              )
            ]
      forM_ terminalCases $ \(caseName, outcomeText, writeTerminal) -> do
        taskId <-
          insertTestTaskDef pool "paper_portfolio_cycle" ("test-run-terminal-late-parent-" <> caseName)
        parentRunId <- createTestRun pool taskId
        childTaskId <-
          insertTestTaskDef pool "paper_portfolio_cycle" ("test-run-terminal-late-child-" <> caseName)
        childRunId <- createTestRun pool childTaskId
        now <- getCurrentTime
        _ <- runTx pool $ writeTerminal childRunId now
        task <- loadTaskDef pool taskId
        let signalName = runTerminalSignalName childRunId
            expectedPayload =
              Aeson.object
                [ "runId" Aeson..= childRunId
                , "outcome" Aeson..= outcomeText
                ]
        outcome <- executeStagePlan taskContext parentRunId task (singleSignalWaitPlan signalName)
        outcome `shouldBe` OutcomeCompleted
        readRunStatus pool parentRunId `shouldReturn` Just "completed"
        runTx pool (Q.lookupSignalStatus parentRunId (unSignalName signalName))
          `shouldReturn` Just "delivered"
        outputs <- readGraphNodeOutputs pool parentRunId
        case outputs of
          Just (nodeOutputs, _) ->
            Map.lookup (NodeId "test_alpha") nodeOutputs `shouldBe` Just expectedPayload
          Nothing -> expectationFailure "Expected graph outputs for resolved terminal wait"

    it "resolves a wait on an already-timed-out run at registration" $ \mPool -> withDb mPool $ \pool -> do
      -- Timeout is terminal and updateRunTimedOut emits its only delivery
      -- before a late wait exists; a wait registered afterwards must resolve
      -- immediately rather than park on a delivery that already happened.
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-timeout-parent"
      parentRunId <- createTestRun pool taskId
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-timeout-child"
      childRunId <- createTestRun pool childTaskId
      now <- getCurrentTime
      _ <-
        runTx pool $
          Q.updateRunTimedOut
            Q.RunTimeoutUpdate
              { Q.rtuRunId = childRunId
              , Q.rtuCompletedAt = now
              , Q.rtuErrType = "timeout"
              , Q.rtuErrMsg = "child timed out"
              }
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (runTerminalSignalName childRunId))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "completed"

    it "fails instead of parking on a missing run-terminal target" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-missing-parent"
      parentRunId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let signalName = runTerminalSignalName UUID.nil
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend signalName)
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeFailed
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "failed"
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Nothing
      statuses <- readGraphNodeStatuses pool parentRunId
      (Map.lookup (NodeId "test_alpha") =<< statuses) `shouldBe` Just NodeFailed

    it "fails instead of parking on a self-targeted run-terminal wait" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-self-parent"
      parentRunId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let signalName = runTerminalSignalName parentRunId
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend signalName)
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeFailed
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "failed"
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Nothing
      statuses <- readGraphNodeStatuses pool parentRunId
      (Map.lookup (NodeId "test_alpha") =<< statuses) `shouldBe` Just NodeFailed

    it "fails instead of dropping duplicate same-signal wait nodes" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-duplicate-settlement"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let signalName = SignalName "shared_duplicate_event"
          stagePlan =
            parallelSignalWaitPlan
              [ ("wait_a", signalName)
              , ("wait_b", signalName)
              ]
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      status <- readRunStatus pool runId
      status `shouldBe` Just "failed"
      sigStatus <- runTx pool $ Q.lookupSignalStatus runId (unSignalName signalName)
      sigStatus `shouldBe` Nothing
      statuses <- readGraphNodeStatuses pool runId
      (Map.lookup (NodeId "wait_a") =<< statuses) `shouldBe` Just NodeFailed
      (Map.lookup (NodeId "wait_b") =<< statuses) `shouldBe` Just NodeFailed

    it "settles a run-terminal delivery that races before parking" $ \mPool -> withDb mPool $ \pool -> do
      -- Encodes the lost-wakeup ordering through the real executor path: the
      -- child reaches terminal status just before the parent returns
      -- StageSuspend. Settlement must observe that terminal status, complete
      -- the waiting node, and avoid committing a waiting run.
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-park-race-parent"
      parentRunId <- createTestRun pool taskId
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-park-race-child"
      childRunId <- createTestRun pool childTaskId
      task <- loadTaskDef pool taskId
      let signalName = runTerminalSignalName childRunId
          stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> do
                      now <- getCurrentTime
                      _ <- runTx pool $ Q.updateRunCompleted childRunId now
                      pure (StageSuspend signalName)
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool parentRunId
      status `shouldBe` Just "completed"
      sigStatus <- runTx pool $ Q.lookupSignalStatus parentRunId (unSignalName signalName)
      sigStatus `shouldBe` Just "delivered"

    it "run-terminal settlement keeps pending waits when another wait resolves" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mixed-parent"
      parentRunId <- createTestRun pool taskId
      doneTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mixed-done"
      doneRunId <- createTestRun pool doneTaskId
      liveTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mixed-live"
      liveRunId <- createTestRun pool liveTaskId
      now <- getCurrentTime
      _ <- runTx pool $ Q.updateRunCompleted doneRunId now
      task <- loadTaskDef pool taskId
      let doneSignal = runTerminalSignalName doneRunId
          liveSignal = runTerminalSignalName liveRunId
          stagePlan =
            parallelSignalWaitPlan
              [ ("await_done", doneSignal)
              , ("await_live", liveSignal)
              ]
      outcome <- executeStagePlan taskContext parentRunId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      readRunStatus pool parentRunId `shouldReturn` Just "waiting"
      runTx pool (Q.lookupSignalStatus parentRunId (unSignalName doneSignal))
        `shouldReturn` Just "delivered"
      runTx pool (Q.lookupSignalStatus parentRunId (unSignalName liveSignal))
        `shouldReturn` Just "pending"
      statuses <- readGraphNodeStatuses pool parentRunId
      case statuses of
        Just nodeStatuses -> do
          Map.lookup (NodeId "await_done") nodeStatuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "await_live") nodeStatuses
            `shouldBe` Just (NodeWaiting (unSignalName liveSignal))
        Nothing -> expectationFailure "Expected graph statuses for mixed settlement"
      outputs <- readGraphNodeOutputs pool parentRunId
      case outputs of
        Just (nodeOutputs, _) ->
          Map.lookup (NodeId "await_done") nodeOutputs
            `shouldBe` Just
              ( Aeson.object
                  [ "runId" Aeson..= doneRunId
                  , "outcome" Aeson..= ("completed" :: Text)
                  ]
              )
        Nothing -> expectationFailure "Expected graph outputs for mixed settlement"

    it "run-terminal delivery wakes every parent waiting on the same child" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      childTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-fanout-child"
      childRunId <- createTestRun pool childTaskId
      let signalName = runTerminalSignalName childRunId
          startParent label = do
            taskId <-
              insertTestTaskDef pool "paper_portfolio_cycle" ("test-run-terminal-fanout-parent-" <> label)
            runId <- createTestRun pool taskId
            task <- loadTaskDef pool taskId
            outcome <- executeStagePlan taskContext runId task (singleSignalWaitPlan signalName)
            outcome `shouldBe` OutcomeSuspended
            readRunStatus pool runId `shouldReturn` Just "waiting"
            runTx pool (Q.lookupSignalStatus runId (unSignalName signalName))
              `shouldReturn` Just "pending"
            pure runId
      parentA <- startParent "a"
      parentB <- startParent "b"
      now <- getCurrentTime
      _ <- runTx pool $ Q.updateRunCompleted childRunId now
      forM_ [parentA, parentB] $ \parentRunId -> do
        readRunStatus pool parentRunId `shouldReturn` Just "pending"
        runTx pool (Q.lookupSignalStatus parentRunId (unSignalName signalName))
          `shouldReturn` Just "delivered"

    it "run-terminal concurrent terminal writers handle overlapping parent waits" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      childATaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-overlap-child-a"
      childA <- createTestRun pool childATaskId
      childBTaskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-overlap-child-b"
      childB <- createTestRun pool childBTaskId
      let signalA = runTerminalSignalName childA
          signalB = runTerminalSignalName childB
          stagePlan =
            parallelSignalWaitPlan
              [ ("await_a", signalA)
              , ("await_b", signalB)
              ]
          startParent label = do
            taskId <-
              insertTestTaskDef pool "paper_portfolio_cycle" ("test-run-terminal-overlap-parent-" <> label)
            runId <- createTestRun pool taskId
            task <- loadTaskDef pool taskId
            outcome <- executeStagePlan taskContext runId task stagePlan
            outcome `shouldBe` OutcomeSuspended
            readRunStatus pool runId `shouldReturn` Just "waiting"
            pure runId
      parentA <- startParent "a"
      parentB <- startParent "b"
      completionResult <-
        timeout 5000000
          . withAsync (getCurrentTime >>= runTx pool . Q.updateRunCompleted childA)
          $ \completeA ->
            withAsync (getCurrentTime >>= runTx pool . Q.updateRunCompleted childB) $ \completeB -> do
              resultA <- waitCatch completeA
              resultB <- waitCatch completeB
              pure (resultA, resultB)
      case completionResult of
        Nothing ->
          expectationFailure "Concurrent terminal writers timed out, possible deadlock"
        Just (Right (), Right ()) ->
          pure ()
        Just (Left err, _) ->
          expectationFailure ("Child A terminal writer failed: " <> displayException err)
        Just (_, Left err) ->
          expectationFailure ("Child B terminal writer failed: " <> displayException err)
      forM_ [parentA, parentB] $ \parentRunId -> do
        readRunStatus pool parentRunId `shouldReturn` Just "pending"
        runTx pool (Q.lookupSignalStatus parentRunId (unSignalName signalA))
          `shouldReturn` Just "delivered"
        runTx pool (Q.lookupSignalStatus parentRunId (unSignalName signalB))
          `shouldReturn` Just "delivered"

    it "mutual run-terminal settlements do not deadlock" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskIdA <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mutual-settle-a"
      runA <- createTestRun pool taskIdA
      taskIdB <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mutual-settle-b"
      runB <- createTestRun pool taskIdB
      taskA <- loadTaskDef pool taskIdA
      taskB <- loadTaskDef pool taskIdB
      let signalA = runTerminalSignalName runA
          signalB = runTerminalSignalName runB
      settlementResult <-
        timeout 5000000
          . withAsync (executeStagePlan taskContext runA taskA (singleSignalWaitPlan signalB))
          $ \waitA ->
            withAsync (executeStagePlan taskContext runB taskB (singleSignalWaitPlan signalA)) $ \waitB -> do
              resultA <- waitCatch waitA
              resultB <- waitCatch waitB
              pure (resultA, resultB)
      case settlementResult of
        Nothing ->
          expectationFailure "Mutual run-terminal settlement timed out, possible deadlock"
        Just (resultA, resultB) -> do
          case resultA of
            Right OutcomeSuspended ->
              pure ()
            Right other ->
              expectationFailure ("Run A settlement outcome: " <> show other)
            Left err ->
              expectationFailure ("Run A settlement failed: " <> displayException err)
          case resultB of
            Right OutcomeSuspended ->
              pure ()
            Right other ->
              expectationFailure ("Run B settlement outcome: " <> show other)
            Left err ->
              expectationFailure ("Run B settlement failed: " <> displayException err)
      readRunStatus pool runA `shouldReturn` Just "waiting"
      readRunStatus pool runB `shouldReturn` Just "waiting"
      runTx pool (Q.lookupSignalStatus runA (unSignalName signalB))
        `shouldReturn` Just "pending"
      runTx pool (Q.lookupSignalStatus runB (unSignalName signalA))
        `shouldReturn` Just "pending"

    it "mutual run-terminal terminal writers do not deadlock" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskIdA <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mutual-complete-a"
      runA <- createTestRun pool taskIdA
      taskIdB <- insertTestTaskDef pool "paper_portfolio_cycle" "test-run-terminal-mutual-complete-b"
      runB <- createTestRun pool taskIdB
      taskA <- loadTaskDef pool taskIdA
      taskB <- loadTaskDef pool taskIdB
      let signalA = runTerminalSignalName runA
          signalB = runTerminalSignalName runB
      executeStagePlan taskContext runA taskA (singleSignalWaitPlan signalB)
        `shouldReturn` OutcomeSuspended
      executeStagePlan taskContext runB taskB (singleSignalWaitPlan signalA)
        `shouldReturn` OutcomeSuspended
      completionResult <-
        timeout 5000000
          . withAsync (getCurrentTime >>= runTx pool . Q.updateRunCompleted runA)
          $ \completeA ->
            withAsync (getCurrentTime >>= runTx pool . Q.updateRunCompleted runB) $ \completeB -> do
              resultA <- waitCatch completeA
              resultB <- waitCatch completeB
              pure (resultA, resultB)
      case completionResult of
        Nothing ->
          expectationFailure "Mutual run-terminal terminal writers timed out, possible deadlock"
        Just (resultA, resultB) -> do
          case resultA of
            Right () ->
              pure ()
            Left err ->
              expectationFailure ("Run A terminal writer failed: " <> displayException err)
          case resultB of
            Right () ->
              pure ()
            Left err ->
              expectationFailure ("Run B terminal writer failed: " <> displayException err)
      readRunStatus pool runA `shouldReturn` Just "completed"
      readRunStatus pool runB `shouldReturn` Just "completed"
      runTx pool (Q.lookupSignalStatus runA (unSignalName signalB))
        `shouldReturn` Just "delivered"
      runTx pool (Q.lookupSignalStatus runB (unSignalName signalA))
        `shouldReturn` Just "delivered"

    it "suspend→deliver→resume completes the full round-trip" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-roundtrip"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      completedRef <- newIORef False
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (SignalName "approval"))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_runId state -> do
                      atomicModifyIORef' completedRef (const (True, ()))
                      pure state
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      -- Phase 1: Execute until suspension
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeSuspended
      readRunStatus pool runId `shouldReturn` Just "waiting"
      -- Phase 2: Deliver the signal
      now <- getCurrentTime
      _ <- runTx pool $ Q.deliverSignal runId "approval" (Aeson.String "approved") now
      readRunStatus pool runId `shouldReturn` Just "pending"
      -- Phase 3: Re-claim and resume — must complete stage beta
      runTx pool $ Q.updateRunStarted runId now
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      readRunStatus pool runId `shouldReturn` Just "completed"
      completed <- readIORef completedRef
      completed `shouldBe` True

  describe "graph state persistence on failure" $ do
    it "persists NodeFailed for a leaf node failure" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-leaf-failure-graph-state"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_ s -> pure s)
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_ _ -> throwIO (userError "leaf boom")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          Map.lookup (NodeId "test_alpha") m `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "test_beta") m `shouldBe` Just NodeFailed

    it "persists NodeFailed for origin and downstream nodes on non-leaf failure" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-nonleaf-failure-graph-state"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_ _ -> throwIO (userError "origin boom")
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              , simpleStage TestStageBeta (\_ s -> pure s)
              , simpleStage TestStageGamma (\_ s -> pure s)
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          Map.lookup (NodeId "test_alpha") m `shouldBe` Just NodeFailed
          Map.lookup (NodeId "test_beta") m `shouldBe` Just NodeFailed
          Map.lookup (NodeId "test_gamma") m `shouldBe` Just NodeFailed

    it "persists NodeFailed for origin in a diamond graph without losing downstream" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-diamond-failure-graph-state"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Diamond: alpha -> beta, alpha -> gamma, beta -> delta, gamma -> delta
      -- Alpha fails, so beta, gamma, delta should all be failed too.
      let nodeAlpha = NodeId "test_alpha"
          nodeBeta = NodeId "test_beta"
          nodeGamma = NodeId "test_gamma"
          nodeDelta = NodeId "test_delta"
          topology =
            toRelation
              ( edge nodeAlpha nodeBeta
                  <> edge nodeAlpha nodeGamma
                  <> edge nodeBeta nodeDelta
                  <> edge nodeGamma nodeDelta
              )
      case validateDAG topology of
        Left err -> expectationFailure $ "Diamond graph validation failed: " <> show err
        Right () -> pure ()
      let defs =
            Map.fromList
              [
                ( nodeAlpha
                , StageDefinition
                    { sdStageId = TestStageAlpha
                    , sdTemplateId = stageTemplateId TestStageAlpha
                    , sdActionId = stageActionId TestStageAlpha
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> throwIO (userError "diamond origin boom")
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( nodeBeta
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( nodeGamma
                , StageDefinition
                    { sdStageId = TestStageGamma
                    , sdTemplateId = stageTemplateId TestStageGamma
                    , sdActionId = stageActionId TestStageGamma
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( nodeDelta
                , StageDefinition
                    { sdStageId = TestStageDelta
                    , sdTemplateId = stageTemplateId TestStageDelta
                    , sdActionId = stageActionId TestStageDelta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          Map.lookup nodeAlpha m `shouldBe` Just NodeFailed
          Map.lookup nodeBeta m `shouldBe` Just NodeFailed
          Map.lookup nodeGamma m `shouldBe` Just NodeFailed
          Map.lookup nodeDelta m `shouldBe` Just NodeFailed

    it "resume from settled-with-failures graph state returns OutcomeFailed, not OutcomeCompleted" $ \mPool -> withDb mPool $ \pool -> do
      -- Simulates the recovery path: a prior execution persisted NodeFailed
      -- graph state but the run status DB write failed, leaving the run as
      -- 'running'. Lease recovery resumes the run. The executor must detect
      -- the settled-but-failed graph and mark the run as failed rather than
      -- treating allSettled as success.
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-settled-failed"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_ s -> pure s)
              , simpleStage TestStageBeta (\_ s -> pure s)
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
          -- Simulate: prior execution persisted all-failed graph state
          topology = spTopology stagePlan
          gs :: GraphState Aeson.Value
          gs = foldl' (flip markFailed) (initialGraphState topology) [NodeId "test_alpha", NodeId "test_beta"]
      -- Write the failed graph state directly (simulating a prior crash)
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (gsNodeStatuses gs))
        (Aeson.toJSON (gsNodeOutputs gs))
        (Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32))
        Nothing
      -- Resume: should detect settled-with-failures and return OutcomeFailed
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      status <- readRunStatus pool runId
      status `shouldBe` Just "failed"

    it "resume resets NodeRunning to NodePending and re-executes the node" $ \mPool -> withDb mPool $ \pool -> do
      -- Simulates crash during concurrent frontier execution: nodes
      -- were persisted as NodeRunning. On resume, resetRunningToPending
      -- should make them eligible for re-execution.
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-resume-running-reset"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      executedRef <- newIORef False
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_ s -> do
                      atomicModifyIORef' executedRef (const (True, ()))
                      pure s
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
          topology = spTopology stagePlan
          -- Simulate: alpha was in-flight (NodeRunning) when crash occurred
          gs :: GraphState Aeson.Value
          gs = (initialGraphState topology) {gsNodeStatuses = Map.fromList [(NodeId "test_alpha", NodeRunning)]}
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (gsNodeStatuses gs))
        (Aeson.toJSON (gsNodeOutputs gs))
        (Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32))
        Nothing
      -- Resume should reset NodeRunning → NodePending and re-execute
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      executed <- readIORef executedRef
      executed `shouldBe` True

  describe "concurrent frontier execution" $ do
    it "executes independent frontier nodes concurrently" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-diamond"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Use MVar barriers to prove concurrency: both beta and gamma must
      -- signal "started" before either can proceed. If execution were
      -- sequential, this would deadlock.
      betaStarted <- newEmptyMVar
      gammaStarted <- newEmptyMVar
      let barrierStage name myBarrier otherBarrier =
            StageDefinition
              { sdStageId = name
              , sdTemplateId = stageTemplateId name
              , sdActionId = stageActionId name
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = \_ -> do
                  putMVar myBarrier ()
                  _ <- readMVar otherBarrier -- blocks until the other stage has started
                  pure (StageComplete Aeson.Null)
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          -- Diamond: alpha → beta, alpha → gamma, beta → delta, gamma → delta
          nodeAlpha = NodeId "test_alpha"
          nodeBeta = NodeId "test_beta"
          nodeGamma = NodeId "test_gamma"
          nodeDelta = NodeId "test_delta"
          topology =
            toRelation
              ( edge nodeAlpha nodeBeta
                  <> edge nodeAlpha nodeGamma
                  <> edge nodeBeta nodeDelta
                  <> edge nodeGamma nodeDelta
              )
          defs =
            Map.fromList
              [ (nodeAlpha, simpleStage TestStageAlpha (\_ _ -> pure Aeson.Null))
              , (nodeBeta, barrierStage TestStageBeta betaStarted gammaStarted)
              , (nodeGamma, barrierStage TestStageGamma gammaStarted betaStarted)
              , (nodeDelta, simpleStage TestStageDelta (\_ _ -> pure Aeson.Null))
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      -- If concurrent: both barriers release and the run completes.
      -- If sequential: deadlock (beta waits for gamma which never starts).
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted

    it "cancels in-flight siblings when one node fails" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-failure-cancel"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Diamond: alpha → beta (fails fast), alpha → gamma (slow)
      let nodeAlpha = NodeId "test_alpha"
          nodeBeta = NodeId "test_beta"
          nodeGamma = NodeId "test_gamma"
          nodeDelta = NodeId "test_delta"
          topology =
            toRelation
              ( edge nodeAlpha nodeBeta
                  <> edge nodeAlpha nodeGamma
                  <> edge nodeBeta nodeDelta
                  <> edge nodeGamma nodeDelta
              )
          defs =
            Map.fromList
              [ (nodeAlpha, simpleStage TestStageAlpha (\_ _ -> pure Aeson.Null))
              ,
                ( nodeBeta
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> throwIO (userError "beta fails")
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( nodeGamma
                , StageDefinition
                    { sdStageId = TestStageGamma
                    , sdTemplateId = stageTemplateId TestStageGamma
                    , sdActionId = stageActionId TestStageGamma
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        threadDelay 500000 -- slow — should be cancelled
                        pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              , (nodeDelta, simpleStage TestStageDelta (\_ _ -> pure Aeson.Null))
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          Map.lookup nodeAlpha m `shouldBe` Just NodeCompleted
          Map.lookup nodeBeta m `shouldBe` Just NodeFailed
          -- Gamma may still be pending if cancellation wins before the stage
          -- starts, interrupted if executor-owned sibling cancellation reaches
          -- an in-flight worker, completed if it finishes before the failure,
          -- or failed if cancellation arrives during non-async IO.
          let gammaStatus = Map.lookup nodeGamma m
          gammaStatus
            `shouldSatisfy` ( \s ->
                                s == Just NodePending
                                  || s == Just (NodeInterrupted InterruptedSiblingCancelled)
                                  || s == Just NodeCompleted
                                  || s == Just NodeFailed
                            )
          -- Delta is downstream of beta, so it should be failed
          Map.lookup nodeDelta m `shouldBe` Just NodeFailed

    it "prefers a settled failure over a sibling rewrite in the same frontier" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-rewrite-failure"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let mkDynStage stageId stageAction =
            StageDefinition
              { sdStageId = DynStageId stageId
              , sdTemplateId = stageTemplateId (DynStageId stageId)
              , sdActionId = stageActionId (DynStageId stageId)
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = stageAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          nodeAlpha = NodeId "alpha"
          nodeBeta = NodeId "beta"
          nodeGamma = NodeId "gamma"
          nodeDelta = NodeId "delta"
          nodeBetaSub1 = NodeId "beta:sub1"
          topology =
            toRelation
              ( edge nodeAlpha nodeBeta
                  <> edge nodeAlpha nodeGamma
                  <> edge nodeBeta nodeDelta
                  <> edge nodeGamma nodeDelta
              )
          rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "sub1"))
              , sgsDefinitions =
                  Map.fromList
                    [
                      ( NodeId "sub1"
                      , mkDynStage "sub1" (liftChainAction (\_ state -> pure (Aeson.object ["sub" Aeson..= state])))
                      )
                    ]
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub1"]
              }
          waitForBetaRewritten = do
            maybeStatuses <- readGraphNodeStatuses pool runId
            case maybeStatuses >>= Map.lookup nodeBeta of
              Just NodeRewritten -> pure ()
              _ -> do
                threadDelay 10000
                waitForBetaRewritten
          defs =
            Map.fromList
              [ (nodeAlpha, mkDynStage "alpha" (\_ -> pure (StageComplete Aeson.Null)))
              ,
                ( nodeBeta
                , mkDynStage "beta" $
                    \_ ->
                      pure (StageRewrite (Aeson.String "beta-output") (ExpandNode nodeBeta ExpandReplaceNode rewriteSpec))
                )
              ,
                ( nodeGamma
                , mkDynStage "gamma" $ \_ -> do
                    maybeBetaRewritten <- timeout 2_000_000 waitForBetaRewritten
                    case maybeBetaRewritten of
                      Nothing -> throwIO (userError "timed out waiting for beta rewrite persistence")
                      Just () -> pure ()
                    throwIO (userError "gamma fails after sibling rewrite")
                )
              , (nodeDelta, mkDynStage "delta" (\_ -> pure (StageComplete Aeson.Null)))
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          Map.lookup nodeAlpha m `shouldBe` Just NodeCompleted
          Map.lookup nodeBeta m `shouldBe` Just NodeRewritten
          Map.lookup nodeGamma m `shouldBe` Just NodeFailed
          Map.lookup nodeDelta m `shouldBe` Just NodeFailed
          Map.lookup nodeBetaSub1 m `shouldBe` Nothing
      outputs <- readGraphNodeOutputs pool runId
      case outputs of
        Nothing -> expectationFailure "Expected graph outputs to be persisted"
        Just (m, appliedRewriteId) -> do
          appliedRewriteId `shouldBe` Nothing
          Map.lookup nodeBeta m `shouldBe` Just (Aeson.String "beta-output")
          Map.lookup nodeBetaSub1 m `shouldBe` Nothing

    it "respects per-run concurrency cap" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-cap"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      concurrentRef <- newIORef (0 :: Int)
      peakRef <- newIORef (0 :: Int)
      let mkNode name =
            StageDefinition
              { sdStageId = name
              , sdTemplateId = stageTemplateId name
              , sdActionId = stageActionId name
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = \_ -> do
                  n <- atomicModifyIORef' concurrentRef (\c -> let c' = c + 1 in (c', c'))
                  atomicModifyIORef' peakRef (\p -> (max p n, ()))
                  threadDelay 30000
                  atomicModifyIORef' concurrentRef (\c -> (c - 1, ()))
                  pure (StageComplete Aeson.Null)
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          -- 4 independent roots (no edges between them)
          nodes = [NodeId "a", NodeId "b", NodeId "c", NodeId "d"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          stages = [TestStageAlpha, TestStageBeta, TestStageGamma, TestStageDelta]
          defs = Map.fromList (zip nodes (fmap mkNode stages))
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      peak <- readIORef peakRef
      peak `shouldSatisfy` (<= 2)

    it "blocks semaphore-queued workers after a terminal sibling finishes" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 2
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-terminal-blocks-queued-worker"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      roleRef <- newIORef (0 :: Int)
      blockerStarted <- newEmptyMVar
      blockerGate <- newEmptyMVar
      blockerCancelled <- newEmptyMVar
      lateStarts <- newIORef (0 :: Int)
      let mkDynStage stageId stageAction =
            StageDefinition
              { sdStageId = DynStageId stageId
              , sdTemplateId = stageTemplateId (DynStageId stageId)
              , sdActionId = stageActionId (DynStageId stageId)
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = stageAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          roleAction _ = do
            role <- atomicModifyIORef' roleRef (\n -> let n' = n + 1 in (n', n'))
            case role of
              1 ->
                flip finally (void (tryPutMVar blockerCancelled ())) $ do
                  putMVar blockerStarted ()
                  _ <- readMVar blockerGate
                  pure (StageComplete (Aeson.String "blocker"))
              2 -> do
                mBlocker <- timeout 2_000_000 (readMVar blockerStarted)
                case mBlocker of
                  Nothing -> throwIO (userError "timed out waiting for blocker worker")
                  Just () -> throwIO (userError "terminal worker fails after blocker starts")
              _ -> do
                atomicModifyIORef' lateStarts (\c -> (c + 1, ()))
                pure (StageComplete (Aeson.String "late"))
          nodes = [NodeId "a", NodeId "b", NodeId "c", NodeId "d"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [ (NodeId "a", mkDynStage "a" roleAction)
              , (NodeId "b", mkDynStage "b" roleAction)
              , (NodeId "c", mkDynStage "c" roleAction)
              , (NodeId "d", mkDynStage "d" roleAction)
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      result <- timeout 5_000_000 $ executeStagePlan taskContext runId task stagePlan
      case result of
        Nothing -> expectationFailure "Timed out waiting for terminal frontier"
        Just outcome -> outcome `shouldBe` OutcomeFailed
      starts <- readIORef lateStarts
      starts `shouldBe` 0
      cancelled <- timeout 2_000_000 (readMVar blockerCancelled)
      cancelled `shouldSatisfy` isJust

    it "cancels semaphore-queued workers without leaving stale NodeRunning statuses" $ \mPool -> withDb mPool $ \pool -> do
      -- cap=2 with three ready roots leaves one worker blocked on waitQSem.
      -- When the first worker fails, the queued worker must produce NodeResult
      -- (not escape as Left through waitAnyCatch) so the graph state is clean.
      (_, taskContext) <- mkTaskContextWith pool 2
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-semaphore-cancel"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let mkDynStage stageId action =
            StageDefinition
              { sdStageId = DynStageId stageId
              , sdTemplateId = stageTemplateId (DynStageId stageId)
              , sdActionId = stageActionId (DynStageId stageId)
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = action
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          nodes = [NodeId "a", NodeId "b", NodeId "c"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [ (NodeId "a", mkDynStage "a" (\_ -> throwIO (userError "a fails immediately")))
              , (NodeId "b", mkDynStage "b" (\_ -> pure (StageComplete (Aeson.String "b"))))
              , (NodeId "c", mkDynStage "c" (\_ -> pure (StageComplete (Aeson.String "c"))))
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          -- No node should be stuck in NodeRunning.  The failing node should
          -- be NodeFailed; the semaphore-queued siblings should be cancelled
          -- (NodeInterrupted) or NodeFailed, never NodeRunning.
          let stuckRunning = [nid | (nid, NodeRunning) <- Map.toList m]
          stuckRunning `shouldBe` []

    it "suspension on one node does not block concurrent siblings" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-suspend"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      completedRef <- newIORef (0 :: Int)
      -- 3 independent roots: node A suspends, nodes B and C complete
      let nodes = [NodeId "a", NodeId "b", NodeId "c"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [
                ( NodeId "a"
                , StageDefinition
                    { sdStageId = TestStageAlpha
                    , sdTemplateId = stageTemplateId TestStageAlpha
                    , sdActionId = stageActionId TestStageAlpha
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> pure (StageSuspend (SignalName "wait_for_it"))
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( NodeId "b"
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        atomicModifyIORef' completedRef (\c -> (c + 1, ()))
                        pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( NodeId "c"
                , StageDefinition
                    { sdStageId = TestStageGamma
                    , sdTemplateId = stageTemplateId TestStageGamma
                    , sdActionId = stageActionId TestStageGamma
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        atomicModifyIORef' completedRef (\c -> (c + 1, ()))
                        pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeSuspended
      completed <- readIORef completedRef
      completed `shouldBe` 2
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state"
        Just m -> do
          Map.lookup (NodeId "a") m `shouldSatisfy` (\s -> s == Just (NodeWaiting "wait_for_it"))
          Map.lookup (NodeId "b") m `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "c") m `shouldBe` Just NodeCompleted

  describe "concurrent frontier stress tests" $ do
    it "wide fan-out: 12 independent roots, cap=4, all succeed" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stress-fanout"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      completedRef <- newIORef (0 :: Int)
      let nodeCount = 12
          nodes = [NodeId (T.pack ("n" <> show i)) | i <- [1 :: Int .. nodeCount]]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          mkDef nid =
            ( nid
            , StageDefinition
                { sdStageId = DynStageId (unNodeId nid)
                , sdTemplateId = stageTemplateId (DynStageId (unNodeId nid))
                , sdActionId = stageActionId (DynStageId (unNodeId nid))
                , sdReplaySafety = SafeToReplay
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction = \_ -> do
                    threadDelay 5000 -- 5ms
                    atomicModifyIORef' completedRef (\c -> (c + 1, ()))
                    pure (StageComplete Aeson.Null)
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          defs = Map.fromList (fmap mkDef nodes)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      completed <- readIORef completedRef
      completed `shouldBe` nodeCount

    it "failure storm: 8 independent roots, 3 fail, others complete or cancel" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 8
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-stress-failure-storm"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let nodeCount = 8
          failingIndices = [3, 5, 7] :: [Int]
          nodes = [NodeId (T.pack ("n" <> show i)) | i <- [1 :: Int .. nodeCount]]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          mkDef i nid =
            ( nid
            , StageDefinition
                { sdStageId = DynStageId (unNodeId nid)
                , sdTemplateId = stageTemplateId (DynStageId (unNodeId nid))
                , sdActionId = stageActionId (DynStageId (unNodeId nid))
                , sdReplaySafety = SafeToReplay
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction = \_ ->
                    if i `elem` failingIndices
                      then do
                        threadDelay 2000
                        throwIO (userError ("node " <> show i <> " fails"))
                      else do
                        threadDelay 10000
                        pure (StageComplete Aeson.Null)
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          defs = Map.fromList (zipWith mkDef [1 ..] nodes)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state to be persisted"
        Just m -> do
          -- At least the first failing node should be NodeFailed
          let failedCount = length [nid | (nid, NodeFailed) <- Map.toList m]
          failedCount `shouldSatisfy` (>= 1)
          -- Every node should be terminal or pending (no NodeRunning left)
          let allStatuses = Map.elems m
          allStatuses `shouldSatisfy` notElem NodeRunning

    it
      "closes stage logs and records diagnostics when post-action finalization throws in a concurrent frontier"
      $ \mPool -> withDb mPool $ \pool -> do
        (_, taskContext) <- mkTaskContextWith pool 2
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-dispatch-exception"
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        let nodes = [NodeId "bad", NodeId "good"]
            topology = toRelation (mconcat [Vertex n | n <- nodes])
            defs =
              Map.fromList
                [
                  ( NodeId "bad"
                  , StageDefinition
                      { sdStageId = DynStageId "bad"
                      , sdTemplateId = stageTemplateId (DynStageId "bad")
                      , sdActionId = stageActionId (DynStageId "bad")
                      , sdReplaySafety = SafeToReplay
                      , sdReplayPolicyOverride = Nothing
                      , sdTimeoutSeconds = Nothing
                      , sdRetryPolicy = Nothing
                      , sdAction = \_ -> do
                          threadDelay 5_000
                          pure (StageComplete (error "post_action_dispatch_boom"))
                      , sdMemoryStrategy = defaultMemoryStrategy
                      }
                  )
                ,
                  ( NodeId "good"
                  , StageDefinition
                      { sdStageId = DynStageId "good"
                      , sdTemplateId = stageTemplateId (DynStageId "good")
                      , sdActionId = stageActionId (DynStageId "good")
                      , sdReplaySafety = SafeToReplay
                      , sdReplayPolicyOverride = Nothing
                      , sdTimeoutSeconds = Nothing
                      , sdRetryPolicy = Nothing
                      , sdAction = \_ -> do
                          threadDelay 20_000
                          pure (StageComplete Aeson.Null)
                      , sdMemoryStrategy = defaultMemoryStrategy
                      }
                  )
                ]
            stagePlan =
              StagePlan
                { spInitialState = Aeson.Null
                , spCheckpointRuntimeVersion = 1
                , spReplayPolicy = ReplayPolicyWarn
                , spInitialRewriteBudget = defaultRewriteBudget
                , spRewriteExhaustionPolicy = RewriteExhaustionFail
                , spBudgetExceededExhaustionPolicy = Nothing
                , spMaxRewriteReExecutions = 2
                , spTopology = topology
                , spDefinitions = defs
                , spTemplateRegistry = mkTemplateRegistry defs
                , spLoopRegistrations = Map.empty
                }
        outcome <- executeStagePlan taskContext runId task stagePlan
        outcome `shouldBe` OutcomeFailed

        stageLogs <- readStageLogs pool runId
        attemptLogs <- readStageAttemptLogs pool runId
        runEvents <- readRunEvents pool runId
        statuses <- readGraphNodeStatuses pool runId

        fmap psldStageName stageLogs `shouldContain` ["bad"]
        let badStageLogs = filter (\logEntry -> logEntry.psldStageName == "bad") stageLogs
            badAttemptLogs =
              filter
                ( \attemptLog ->
                    case badStageLogs of
                      [badLog] -> attemptLog.psaldStageLogId == badLog.psldId
                      _ -> False
                )
                attemptLogs
        fmap psldStatus badStageLogs `shouldBe` ["failed"]
        fmap psldCompletedAt badStageLogs `shouldSatisfy` all isJust
        fmap psaldStatus badAttemptLogs `shouldBe` ["failed"]
        fmap psaldCompletedAt badAttemptLogs `shouldSatisfy` all isJust

        let eventTypes = fmap preEventType runEvents
        mapM_
          (\ev -> eventTypes `shouldSatisfy` elem ev)
          ["stage.dispatch_exception", "frontier.settled_failed", "stage.failed", "run.failed.settled"]
        fmap preMessage runEvents `shouldSatisfy` any (T.isInfixOf "post_action_dispatch_boom")

        case statuses of
          Nothing -> expectationFailure "Expected graph state to be persisted"
          Just m -> do
            Map.lookup (NodeId "bad") m `shouldBe` Just NodeFailed
            Map.elems m `shouldSatisfy` notElem NodeRunning

  describe "frontier regression tests" $ do
    it "cancellation between stages returns OutcomeCancelled without retrying" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-cancel-no-retry"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      stage2Runs <- newIORef (0 :: Int)
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_ s -> do
                      -- Request cancellation during stage 1
                      now <- getCurrentTime
                      runTx pool $ Q.requestCancellation runId "test cancel" now
                      pure s
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = liftChainAction $ \_ s -> do
                      atomicModifyIORef' stage2Runs (\c -> (c + 1, ()))
                      pure s
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      -- Must complete within 3s — the old bug would spin forever
      result <- timeout 3000000 $ executeStagePlan taskContext runId task stagePlan
      case result of
        Nothing -> expectationFailure "Timed out — cancellation did not terminate"
        Just outcome -> outcome `shouldBe` OutcomeCancelled
      runs <- readIORef stage2Runs
      runs `shouldBe` 0

    it "concurrent pre-check returns OutcomeCancelled and launches no workers" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-precheck-cancel"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      workerStarts <- newIORef (0 :: Int)
      -- Request cancellation before execution
      now <- getCurrentTime
      runTx pool $ Q.requestCancellation runId "pre-cancel" now
      -- Two independent roots (frontier size > 1 triggers concurrent path)
      let nodes = [NodeId "a", NodeId "b"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [
                ( NodeId "a"
                , StageDefinition
                    { sdStageId = TestStageAlpha
                    , sdTemplateId = stageTemplateId TestStageAlpha
                    , sdActionId = stageActionId TestStageAlpha
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        atomicModifyIORef' workerStarts (\c -> (c + 1, ()))
                        pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( NodeId "b"
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        atomicModifyIORef' workerStarts (\c -> (c + 1, ()))
                        pure (StageComplete Aeson.Null)
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      result <- timeout 3000000 $ executeStagePlan taskContext runId task stagePlan
      case result of
        Nothing -> expectationFailure "Timed out — pre-check cancel did not terminate"
        Just outcome -> outcome `shouldBe` OutcomeCancelled
      starts <- readIORef workerStarts
      starts `shouldBe` 0
      -- Pre-check cancellation is now represented as NodeInterrupted and only
      -- normalized back to Pending at the explicit resume boundary.
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state"
        Just m -> do
          Map.lookup (NodeId "a") m `shouldBe` Just (NodeInterrupted InterruptedSiblingCancelled)
          Map.lookup (NodeId "b") m `shouldBe` Just (NodeInterrupted InterruptedSiblingCancelled)

    it "persists completed concurrent nodes before the frontier drains" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-incremental-persist"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      fastDone <- newEmptyMVar
      slowGate <- newEmptyMVar
      let nodes = [NodeId "fast", NodeId "slow"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [
                ( NodeId "fast"
                , StageDefinition
                    { sdStageId = TestStageAlpha
                    , sdTemplateId = stageTemplateId TestStageAlpha
                    , sdActionId = stageActionId TestStageAlpha
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        _ <- tryPutMVar fastDone ()
                        pure (StageComplete (Aeson.String "fast_output"))
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( NodeId "slow"
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        _ <- readMVar slowGate -- block until released
                        pure (StageComplete (Aeson.String "slow_output"))
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      withAsync (executeStagePlan taskContext runId task stagePlan) $ \planAsync -> do
        -- Wait for fast node to complete
        _ <- readMVar fastDone
        -- Give the persist a moment to flush (200ms to avoid CI flakiness)
        threadDelay 200000
        -- Check persisted state: fast should be completed while slow is still running
        statuses <- readGraphNodeStatuses pool runId
        case statuses of
          Nothing -> expectationFailure "Expected graph state to be persisted mid-frontier"
          Just m -> do
            Map.lookup (NodeId "fast") m `shouldBe` Just NodeCompleted
        -- Release slow node
        putMVar slowGate ()
        result <- timeout 5000000 $ waitCatch planAsync
        case result of
          Nothing -> expectationFailure "Plan timed out"
          Just (Left ex) -> expectationFailure $ "Plan threw: " <> show ex
          Just (Right outcome) -> outcome `shouldBe` OutcomeCompleted

  describe "graph-state persistence hardening" $ do
    it "rejects graph_state writes whose expected revision is stale" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-graph-state-cas-stale"
      runId <- createTestRun pool taskId
      let node = NodeId "test_alpha"
          stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              1
              ReplayPolicyWarn
          gs0 = initialGraphState stagePlan.spTopology
      writeRawGraphStateForPlan pool runId stagePlan gs0
      snapshot0 <- expectGraphStateSnapshot pool runId
      let revision1 =
            GraphStateRevision (addUTCTime 1 (unGraphStateRevision snapshot0.pgssRevision))
          revision2 =
            GraphStateRevision (addUTCTime 2 (unGraphStateRevision snapshot0.pgssRevision))
          winningState = markCompleted node (Aeson.String "winner") gs0
          staleState = markFailed node gs0
          mkWrite revision state =
            Q.GraphStateWrite
              { gswRunId = runId
              , gswNodeStatuses = Aeson.toJSON state.gsNodeStatuses
              , gswNodeOutputs = Aeson.toJSON state.gsNodeOutputs
              , gswRemainingRewriteBudget = Just (Aeson.toJSON defaultRewriteBudget)
              , gswRuntimeVersion = Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32)
              , gswAppliedRewriteId = Nothing
              , gswNodeProvenance = Just (Aeson.toJSON (initialProvenance stagePlan.spTopology))
              , gswTopologyHash = Just (computeTopologyHash stagePlan.spTopology)
              , gswUpdatedAt = unGraphStateRevision revision
              , gswExpectedRevision = Just snapshot0.pgssRevision
              }

      firstResult <- runTx pool $ Q.writeGraphState (mkWrite revision1 winningState)
      firstResult `shouldBe` Q.GraphStateWriteApplied revision1
      staleResult <- runTx pool $ Q.writeGraphState (mkWrite revision2 staleState)
      staleResult `shouldBe` Q.GraphStateWriteStale

      statuses <- readGraphNodeStatuses pool runId
      (Map.lookup node =<< statuses) `shouldBe` Just NodeCompleted
      outputs <- readGraphNodeOutputs pool runId
      fmap (Map.lookup node . fst) outputs `shouldBe` Just (Just (Aeson.String "winner"))

    it "stops a stale graph_state owner without overwriting newer state" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, _taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-graph-state-stale-owner"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let node = NodeId "test_alpha"
          stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              1
              ReplayPolicyWarn
          gs0 = initialGraphState stagePlan.spTopology
      writeRawGraphStateForPlan pool runId stagePlan gs0
      snapshot0 <- expectGraphStateSnapshot pool runId
      let winningState = markCompleted node (Aeson.String "winner") gs0
          winnerRevision =
            GraphStateRevision (addUTCTime 1 (unGraphStateRevision snapshot0.pgssRevision))
          winnerWrite =
            Q.GraphStateWrite
              { gswRunId = runId
              , gswNodeStatuses = Aeson.toJSON winningState.gsNodeStatuses
              , gswNodeOutputs = Aeson.toJSON winningState.gsNodeOutputs
              , gswRemainingRewriteBudget = Just (Aeson.toJSON defaultRewriteBudget)
              , gswRuntimeVersion = Just (fromIntegral stagePlan.spCheckpointRuntimeVersion :: Int32)
              , gswAppliedRewriteId = Nothing
              , gswNodeProvenance = Just (Aeson.toJSON (initialProvenance stagePlan.spTopology))
              , gswTopologyHash = Just (computeTopologyHash stagePlan.spTopology)
              , gswUpdatedAt = unGraphStateRevision winnerRevision
              , gswExpectedRevision = Just snapshot0.pgssRevision
              }
          stalePersistedState =
            PersistedGraphState
              { pgsGraphState = markFailed node gs0
              , pgsRemainingRewriteBudget = defaultRewriteBudget
              , pgsAppliedRewriteId = Nothing
              , pgsNodeProvenance = initialProvenance stagePlan.spTopology
              , pgsTopologyHash = Just (computeTopologyHash stagePlan.spTopology)
              , pgsRevision = Just snapshot0.pgssRevision
              }
      winnerResult <- runTx pool $ Q.writeGraphState winnerWrite
      winnerResult `shouldBe` Q.GraphStateWriteApplied winnerRevision

      gsVar <- newTVarIO stalePersistedState
      nodeCompletedAtVar <- newTVarIO Map.empty
      topologyVar <- newTVarIO stagePlan.spTopology
      loopControlsVar <- newTVarIO Map.empty
      let tvars =
            RunTVars
              { rvGsVar = gsVar
              , rvNodeCompletedAtVar = nodeCompletedAtVar
              , rvTopologyVar = topologyVar
              , rvLoopControlsVar = loopControlsVar
              }
          env = mkStageEnv pool testPulseConfig shutdownFlag runId task stagePlan tvars

      persistResult <- requireGraphStatePersist env stalePersistedState

      persistResult `shouldBe` Left OutcomeShutdown
      statuses <- readGraphNodeStatuses pool runId
      (Map.lookup node =<< statuses) `shouldBe` Just NodeCompleted
      events <- readRunEvents pool runId
      case filter ((== "run.graph_state_stale_write") . preEventType) events of
        [event] -> preSeverity event `shouldBe` "warn"
        matching ->
          expectationFailure $
            "Expected one stale graph-state event, found "
              <> show (length matching)

    it "fails a sequential frontier when graph_state persistence fails" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-sequential-persist-failure"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              1
              ReplayPolicyWarn
      outcome <-
        withInjectedGraphStateWriteFailure pool runId 1 $
          executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "graph_state_persist_failed")
      readGraphNodeStatuses pool runId `shouldReturn` Nothing

    it "fails a concurrent frontier and cancels workers when graph_state persistence fails" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-concurrent-persist-failure"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      fastDone <- newEmptyMVar
      slowStarted <- newEmptyMVar
      slowGate <- newEmptyMVar
      slowCancelled <- newEmptyMVar
      let nodes = [NodeId "fast", NodeId "slow"]
          topology = toRelation (mconcat [Vertex n | n <- nodes])
          defs =
            Map.fromList
              [
                ( NodeId "fast"
                , StageDefinition
                    { sdStageId = TestStageAlpha
                    , sdTemplateId = stageTemplateId TestStageAlpha
                    , sdActionId = stageActionId TestStageAlpha
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> do
                        _ <- readMVar slowStarted
                        _ <- tryPutMVar fastDone ()
                        pure (StageComplete (Aeson.String "fast_output"))
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ,
                ( NodeId "slow"
                , StageDefinition
                    { sdStageId = TestStageBeta
                    , sdTemplateId = stageTemplateId TestStageBeta
                    , sdActionId = stageActionId TestStageBeta
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ ->
                        flip finally (void (tryPutMVar slowCancelled ())) $ do
                          _ <- tryPutMVar slowStarted ()
                          _ <- readMVar slowGate
                          pure (StageComplete (Aeson.String "slow_output"))
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = topology
              , spDefinitions = defs
              , spTemplateRegistry = mkTemplateRegistry defs
              , spLoopRegistrations = Map.empty
              }
      -- The trigger fires once per accepted graph_state write.  The first
      -- call is an insert, and subsequent CAS writes are update-only:
      -- (1) initial state, (2) markRunning, (3) collectWorkerResults after
      -- the first worker.  We want to fail on (3) so workers actually run.
      outcome <-
        withInjectedGraphStateWriteFailure pool runId 3
          . withAsync (executeStagePlan taskContext runId task stagePlan)
          $ \planAsync -> do
            _ <- readMVar fastDone
            result <- timeout 5_000_000 (waitCatch planAsync)
            case result of
              Nothing -> expectationFailure "Concurrent plan timed out waiting for persist failure" >> pure OutcomeFailed
              Just (Left ex) -> expectationFailure ("Concurrent plan threw: " <> show ex) >> pure OutcomeFailed
              Just (Right plannedOutcome) -> pure plannedOutcome
      outcome `shouldBe` OutcomeFailed
      cancelled <- timeout 2_000_000 (readMVar slowCancelled)
      cancelled `shouldSatisfy` isJust
      runView <- runSession pool $ Q.getRunAdminView runId
      let errType = fmap Q.pravErrorType runView
      errType `shouldBe` Just (Just "graph_state_persist_failed")

    it
      "resumes from partial concurrent frontier persistence to the same final state as uninterrupted execution"
      $ \mPool -> withDb mPool $ \pool -> do
        let mkConvergencePlan fastDone slowGate =
              let nodes = [NodeId "fast", NodeId "slow"]
                  topology = toRelation (mconcat [Vertex n | n <- nodes])
                  defs =
                    Map.fromList
                      [
                        ( NodeId "fast"
                        , StageDefinition
                            { sdStageId = TestStageAlpha
                            , sdTemplateId = stageTemplateId TestStageAlpha
                            , sdActionId = stageActionId TestStageAlpha
                            , sdReplaySafety = SafeToReplay
                            , sdReplayPolicyOverride = Nothing
                            , sdTimeoutSeconds = Nothing
                            , sdRetryPolicy = Nothing
                            , sdAction = \_ -> do
                                _ <- tryPutMVar fastDone ()
                                pure (StageComplete (Aeson.String "fast_output"))
                            , sdMemoryStrategy = defaultMemoryStrategy
                            }
                        )
                      ,
                        ( NodeId "slow"
                        , StageDefinition
                            { sdStageId = TestStageBeta
                            , sdTemplateId = stageTemplateId TestStageBeta
                            , sdActionId = stageActionId TestStageBeta
                            , sdReplaySafety = SafeToReplay
                            , sdReplayPolicyOverride = Nothing
                            , sdTimeoutSeconds = Nothing
                            , sdRetryPolicy = Nothing
                            , sdAction = \_ -> do
                                _ <- readMVar slowGate
                                pure (StageComplete (Aeson.String "slow_output"))
                            , sdMemoryStrategy = defaultMemoryStrategy
                            }
                        )
                      ]
               in StagePlan
                    { spInitialState = Aeson.Null
                    , spCheckpointRuntimeVersion = 1
                    , spReplayPolicy = ReplayPolicyWarn
                    , spInitialRewriteBudget = defaultRewriteBudget
                    , spRewriteExhaustionPolicy = RewriteExhaustionFail
                    , spBudgetExceededExhaustionPolicy = Nothing
                    , spMaxRewriteReExecutions = 2
                    , spTopology = topology
                    , spDefinitions = defs
                    , spTemplateRegistry = mkTemplateRegistry defs
                    , spLoopRegistrations = Map.empty
                    }

        (_, resumeTaskContext) <- mkTaskContextWith pool 4
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-partial-persist-resume-convergence"
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        fastDone <- newEmptyMVar
        slowGate <- newEmptyMVar
        let interruptedPlan = mkConvergencePlan fastDone slowGate
        withAsync (executeStagePlan resumeTaskContext runId task interruptedPlan) $ \planAsync -> do
          _ <- readMVar fastDone
          _ <-
            waitForGraphStatuses
              pool
              runId
              (\m -> Map.lookup (NodeId "fast") m == Just NodeCompleted)
          cancel planAsync
          _ <- waitCatch planAsync
          pure ()
        putMVar slowGate ()
        resumeOutcome <- resumeStagePlan resumeTaskContext runId task interruptedPlan
        resumeOutcome `shouldBe` OutcomeCompleted
        resumedStatuses <- readGraphNodeStatuses pool runId
        resumedOutputs <- readGraphNodeOutputs pool runId

        (_, uninterruptedTaskContext) <- mkTaskContextWith pool 4
        uninterruptedTaskId <-
          insertTestTaskDef pool "paper_portfolio_cycle" "test-uninterrupted-convergence-baseline"
        uninterruptedRunId <- createTestRun pool uninterruptedTaskId
        uninterruptedTask <- loadTaskDef pool uninterruptedTaskId
        fastDoneBaseline <- newEmptyMVar
        slowGateBaseline <- newEmptyMVar
        putMVar slowGateBaseline ()
        let uninterruptedPlan = mkConvergencePlan fastDoneBaseline slowGateBaseline
        uninterruptedOutcome <-
          executeStagePlan uninterruptedTaskContext uninterruptedRunId uninterruptedTask uninterruptedPlan
        uninterruptedOutcome `shouldBe` OutcomeCompleted
        uninterruptedStatuses <- readGraphNodeStatuses pool uninterruptedRunId
        uninterruptedOutputs <- readGraphNodeOutputs pool uninterruptedRunId

        resumedStatuses `shouldBe` uninterruptedStatuses
        fmap fst resumedOutputs `shouldBe` fmap fst uninterruptedOutputs

  -- ==========================================================================
  -- Critical safety path tests
  -- ==========================================================================

  describe "graph-state resume version validation" $ do
    it "rejects graph state with mismatched runtime_version" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-version-mismatch"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              5 -- current runtime version
              ReplayPolicyWarn
      -- Write graph state with WRONG runtime version (99 != 5)
      let topology = spTopology stagePlan
          gs :: GraphState Aeson.Value
          gs = initialGraphState topology
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (gsNodeStatuses gs))
        (Aeson.toJSON (gsNodeOutputs gs))
        (Just 99)
        Nothing
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "graph_state_runtime_version_mismatch")

    it "accepts graph state with NULL runtime_version (pre-migration)" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-version-null"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              1
              ReplayPolicyWarn
      -- Write graph state with NULL runtime version (pre-migration row)
      let topology = spTopology stagePlan
          gs :: GraphState Aeson.Value
          gs = initialGraphState topology
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (gsNodeStatuses gs))
        (Aeson.toJSON (gsNodeOutputs gs))
        Nothing
        Nothing
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted

  describe "graph-state recovery precondition validation" $ do
    it "resume rejects off-topology output entries" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-recovery-output-domain"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let stagePlan =
            mkLinearStagePlan
              [simpleStage TestStageAlpha (\_runId state -> pure state)]
              Aeson.Null
              5
              ReplayPolicyWarn
          gs0 = initialGraphState stagePlan.spTopology
          gs =
            gs0
              { gsNodeOutputs = Map.insert (NodeId "ghost") Aeson.Null gs0.gsNodeOutputs
              }
      writeRawGraphStateForPlan pool runId stagePlan gs

      outcome <- resumeStagePlan taskContext runId task stagePlan

      outcome `shouldBe` OutcomeFailed
      expectRecoveryPreconditionFailure pool runId "output for node ghost is outside"

    it "resume rejects completed or rewritten nodes missing output" $ \mPool -> withDb mPool $ \pool -> do
      let missingOutputCases =
            [ ("completed", NodeCompleted)
            , ("rewritten", NodeRewritten)
            ]
      forM_ missingOutputCases $ \(caseName, status) -> do
        (_, taskContext) <- mkTaskContext pool
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" ("test-recovery-missing-" <> caseName)
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        let alpha = NodeId "test_alpha"
            stagePlan =
              mkLinearStagePlan
                [simpleStage TestStageAlpha (\_runId state -> pure state)]
                Aeson.Null
                5
                ReplayPolicyWarn
            gs0 = initialGraphState stagePlan.spTopology
            gs =
              gs0
                { gsNodeStatuses = Map.insert alpha status gs0.gsNodeStatuses
                , gsNodeOutputs = Map.empty
                }
        writeRawGraphStateForPlan pool runId stagePlan gs

        outcome <- resumeStagePlan taskContext runId task stagePlan

        outcome `shouldBe` OutcomeFailed
        expectRecoveryPreconditionFailure pool runId "has no persisted output"

    it "resume rejects outputs on non-output-owning statuses" $ \mPool -> withDb mPool $ \pool -> do
      let invalidOutputCases =
            [ ("pending", NodePending)
            , ("failed", NodeFailed)
            , ("skipped", NodeSkipped)
            , ("waiting", NodeWaiting "approval")
            ]
      forM_ invalidOutputCases $ \(caseName, status) -> do
        (_, taskContext) <- mkTaskContext pool
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" ("test-recovery-output-" <> caseName)
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        let alpha = NodeId "test_alpha"
            stagePlan =
              mkLinearStagePlan
                [simpleStage TestStageAlpha (\_runId state -> pure state)]
                Aeson.Null
                5
                ReplayPolicyWarn
            gs0 = initialGraphState stagePlan.spTopology
            gs =
              gs0
                { gsNodeStatuses = Map.insert alpha status gs0.gsNodeStatuses
                , gsNodeOutputs = Map.singleton alpha Aeson.Null
                }
        writeRawGraphStateForPlan pool runId stagePlan gs

        outcome <- resumeStagePlan taskContext runId task stagePlan

        outcome `shouldBe` OutcomeFailed
        expectRecoveryPreconditionFailure pool runId "is not allowed while status"

    it "resume rejects successor-unblocking state with open causal history" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-recovery-causal-open"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let alpha = NodeId "test_alpha"
          beta = NodeId "test_beta"
          stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , simpleStage TestStageBeta (\_runId state -> pure state)
              ]
              Aeson.Null
              5
              ReplayPolicyWarn
          gs0 = initialGraphState stagePlan.spTopology
          gs =
            gs0
              { gsNodeStatuses =
                  Map.insert alpha NodePending $
                    Map.insert beta NodeCompleted gs0.gsNodeStatuses
              , gsNodeOutputs = Map.singleton beta Aeson.Null
              }
      writeRawGraphStateForPlan pool runId stagePlan gs

      outcome <- resumeStagePlan taskContext runId task stagePlan

      outcome `shouldBe` OutcomeFailed
      expectRecoveryPreconditionFailure pool runId "successor-unblocking node test_beta"

    it "resume propagates persisted ancestor failure before selecting a frontier" $ \mPool -> withDb mPool $ \pool -> do
      gammaRanRef <- newIORef False
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-recovery-propagates-failure"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let alpha = NodeId "test_alpha"
          beta = NodeId "test_beta"
          gamma = NodeId "test_gamma"
          stagePlan =
            mkLinearStagePlan
              [ simpleStage TestStageAlpha (\_runId state -> pure state)
              , simpleStage TestStageBeta (\_runId state -> pure state)
              , simpleStage TestStageGamma $ \_runId state -> do
                  atomicModifyIORef' gammaRanRef (const (True, ()))
                  pure state
              ]
              Aeson.Null
              5
              ReplayPolicyWarn
          gs =
            GraphState
              { gsNodeStatuses =
                  Map.fromList
                    [ (alpha, NodeFailed)
                    , (beta, NodeCompleted)
                    , (gamma, NodePending)
                    ]
              , gsNodeOutputs = Map.singleton beta Aeson.Null
              }
      writeRawGraphStateForPlan pool runId stagePlan gs

      outcome <- resumeStagePlan taskContext runId task stagePlan

      outcome `shouldBe` OutcomeFailed
      gammaRan <- readIORef gammaRanRef
      gammaRan `shouldBe` False
      statuses <- readGraphNodeStatuses pool runId
      (Map.lookup gamma =<< statuses) `shouldBe` Just NodeFailed

  describe "first-writer-wins failRun" $ do
    it "second failRun does not overwrite the first error_type" $ \mPool -> withDb mPool $ \pool -> do
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-failrun-idempotent"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      -- First failRun: specific error
      _ <-
        DB.runTransaction pool $
          Q.updateRunFailed
            Q.RunFailureUpdate
              { rfuRunId = runId
              , rfuCompletedAt = now
              , rfuErrType = "graph_state_persist_failed"
              , rfuErrMsg = "first failure"
              , rfuRetryable = True
              }
      -- Second failRun: generic error (should be no-op)
      _ <-
        DB.runTransaction pool $
          Q.updateRunFailed
            Q.RunFailureUpdate
              { rfuRunId = runId
              , rfuCompletedAt = now
              , rfuErrType = "graph_settled_with_failures"
              , rfuErrMsg = "second failure"
              , rfuRetryable = False
              }
      -- The first error_type should be preserved
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "graph_state_persist_failed")

  describe "signal node_id scoping" $ do
    it "reused signal name does not consume stale delivery from different node" $ \mPool -> withDb mPool $ \pool -> do
      (_, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-signal-scoping"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Two-stage plan where both stages wait on "approval"
      let stagePlan =
            mkLinearStagePlan
              [ StageDefinition
                  { sdStageId = TestStageAlpha
                  , sdTemplateId = stageTemplateId TestStageAlpha
                  , sdActionId = stageActionId TestStageAlpha
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (SignalName "approval"))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              , StageDefinition
                  { sdStageId = TestStageBeta
                  , sdTemplateId = stageTemplateId TestStageBeta
                  , sdActionId = stageActionId TestStageBeta
                  , sdReplaySafety = SafeToReplay
                  , sdReplayPolicyOverride = Nothing
                  , sdTimeoutSeconds = Nothing
                  , sdRetryPolicy = Nothing
                  , sdAction = \_ctx -> pure (StageSuspend (SignalName "approval"))
                  , sdMemoryStrategy = defaultMemoryStrategy
                  }
              ]
              Aeson.Null
              1
              ReplayPolicyWarn
      -- Execute: alpha suspends on "approval"
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeSuspended
      -- Deliver signal to alpha's node
      now <- getCurrentTime
      delivered <- runTx pool $ Q.deliverSignal runId "approval" (Aeson.String "alpha_approved") now
      delivered `shouldBe` True
      -- Transition run to 'running' (mimics scheduler reclaim after deliverSignal set 'pending')
      now2 <- getCurrentTime
      runTx pool $ Q.updateRunStarted runId now2
      -- Resume: alpha completes via signal, beta should suspend on its own "approval"
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeSuspended
      -- Beta is now waiting — verify it did NOT consume alpha's delivery
      status <- readRunStatus pool runId
      status `shouldBe` Just "waiting"

  describe "rewrite resume hardening" $ do
    let rewriteRuntimeVersion = 3
        mkDynStageWithTemplate templateId stageId action =
          StageDefinition
            { sdStageId = DynStageId stageId
            , sdTemplateId = templateId
            , sdActionId = stageActionId (DynStageId stageId)
            , sdReplaySafety = SafeToReplay
            , sdReplayPolicyOverride = Nothing
            , sdTimeoutSeconds = Nothing
            , sdRetryPolicy = Nothing
            , sdAction = action
            , sdMemoryStrategy = defaultMemoryStrategy
            }
        mkDynStage stageId =
          mkDynStageWithTemplate (stageTemplateId (DynStageId stageId)) stageId
        mkDynLinearStage stageId action =
          mkDynStage stageId (liftChainAction action)
        mkRegistryDef templateId stageId action =
          mkDynStageWithTemplate templateId stageId (liftChainAction action)

    it "applies an admitted sink-node rewrite before run completion" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-sink-admission"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "sub1"))
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId "sub1", mkDynLinearStage "sub1" (\_ state -> pure (Aeson.object ["sub" Aeson..= state])))
                    ]
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub1"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ ->
                          pure
                            ( StageRewrite
                                (Aeson.String "alpha-output")
                                (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec)
                            )
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ ->
                            pure
                              ( StageRewrite
                                  (Aeson.String "alpha-output")
                                  (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec)
                              )
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected persisted graph state after sink rewrite"
        Just m -> do
          Map.lookup (NodeId "alpha") m `shouldBe` Nothing
          Map.lookup (NodeId "alpha:sub1") m `shouldBe` Just NodeCompleted
      outputs <- readGraphNodeOutputs pool runId
      case outputs of
        Nothing -> expectationFailure "Expected persisted graph outputs after sink rewrite"
        Just (m, appliedRewriteId) -> do
          appliedRewriteId `shouldSatisfy` isJust
          Map.lookup (NodeId "alpha:sub1") m
            `shouldBe` Just (Aeson.object ["sub" Aeson..= Aeson.String "seed"])

    it "executes an admitted append rewrite compiled from a raw Wire proposal" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-wire-proposal-append-smoke"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      compiledProposal <-
        case compileWireAppendProposalWithEnv wireSmokeCompileEnv wireSmokeAppendHole wireSmokeProposalSource of
          Left err ->
            expectationFailure ("Expected Wire proposal to compile, got: " <> show err) >> error "unreachable"
          Right compiled -> pure compiled
      proposalPlan <-
        case lowerCompiledCircuitToStagePlan wireSmokePulseConfig wireSmokeBinder compiledProposal of
          Left err -> expectationFailure ("Expected Wire proposal to lower, got: " <> show err) >> error "unreachable"
          Right loweredPlan -> pure loweredPlan
      let subgraph =
            SubgraphSpec
              { sgsTopology = proposalPlan.spTopology
              , sgsDefinitions = proposalPlan.spDefinitions
              , sgsEntryNodes = fmap nodeIdFromCircuitRef compiledProposal.compiledCircuitEntryNodes
              , sgsExitNodes = fmap nodeIdFromCircuitRef compiledProposal.compiledCircuitExitNodes
              }
          analystId = NodeId "analyst"
          reviewerId = NodeId "reviewer"
          analystDef =
            nodeStage analystId $ \_ ->
              pure (StageRewrite (Aeson.String "analyst-output") (AppendAfter analystId subgraph))
          reviewerDef =
            nodeStage reviewerId $ \ctx ->
              pure
                ( StageComplete
                    ( Aeson.object
                        [ "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                        ]
                    )
                )
          definitions =
            Map.fromList
              [ (analystId, analystDef)
              , (reviewerId, reviewerDef)
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (edge analystId reviewerId)
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      status <- readRunStatus pool runId
      status `shouldBe` Just "completed"
      rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      case rewriteRows of
        [row] -> row.pgravStatus `shouldBe` "admitted"
        rows -> expectationFailure ("Expected exactly one admitted rewrite row, got " <> show (length rows))
      maybeStatuses <- readGraphNodeStatuses pool runId
      case maybeStatuses of
        Nothing -> expectationFailure "Expected persisted graph state after Wire append smoke"
        Just statuses -> do
          Map.lookup (NodeId "analyst") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "analyst:stress_alpha") statuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "analyst:stress_beta") statuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "reviewer") statuses `shouldBe` Just NodeCompleted
      maybeOutputs <- readGraphNodeOutputs pool runId
      case maybeOutputs of
        Nothing -> expectationFailure "Expected persisted graph outputs after Wire append smoke"
        Just (outputs, appliedRewriteId) -> do
          appliedRewriteId `shouldSatisfy` isJust
          Map.lookup (NodeId "reviewer") outputs
            `shouldBe` Just
              ( Aeson.object
                  [ "inputNodeIds" Aeson..= ["analyst:stress_alpha" :: Text, "analyst:stress_beta"]
                  ]
              )
          adminTopologyResult <-
            Executor.materializedTopologyForAdmin
              (Just (SomeStagePlan stagePlan []))
              pool
              runId
              (Just (fromIntegral rewriteRuntimeVersion :: Int32))
              appliedRewriteId
          case adminTopologyResult of
            Left err ->
              expectationFailure ("Expected admin topology materialization to succeed, got: " <> T.unpack err)
            Right Nothing ->
              expectationFailure "Expected admin topology materialization to return topology"
            Right (Just topology) -> do
              Set.member (NodeId "analyst:stress_alpha") topology.relVertices `shouldBe` True
              Set.member (NodeId "analyst:stress_beta") topology.relVertices `shouldBe` True
              successors topology (NodeId "analyst")
                `shouldBe` Set.fromList
                  [ NodeId "analyst:stress_alpha"
                  , NodeId "analyst:stress_beta"
                  ]
              successors topology (NodeId "analyst:stress_beta") `shouldBe` Set.singleton reviewerId

    it "runtime-bounded iteration evidence: two loop instances can share one kernel template" $ \_mPool -> do
      let kernelTemplate = StageTemplateId "shared_loop_kernel"
          frontierWitness = FrontierShapeWitness FrontierWitnessV1 "shared-loop-kernel-v1"
          loopKernel = (nodeStage (NodeId "k") (\_ -> pure (StageComplete Aeson.Null))) {sdTemplateId = kernelTemplate}
          kernelWitness = singleStageKernelWitness loopKernel
          policyA = (runtimeIterationPolicy 3 frontierWitness kernelWitness) {lpNamespaceRoot = NodeId "loop_a"}
          policyB = (runtimeIterationPolicy 4 frontierWitness kernelWitness) {lpNamespaceRoot = NodeId "loop_b"}
          keyA = runtimeIterationInstance kernelTemplate policyA
          keyB = runtimeIterationInstance kernelTemplate policyB
          definitions =
            Map.fromList
              [ (NodeId "loop_a:iter_0:k", loopKernel)
              , (NodeId "loop_b:iter_0:k", loopKernel)
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path (Map.keys definitions))
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.fromList
                    [ (keyA, runtimeIterationRegistration policyA)
                    , (keyB, runtimeIterationRegistration policyB)
                    ]
              }
      Map.keysSet (initialLoopControls stagePlan) `shouldBe` Set.fromList [keyA, keyB]
      fmap fst (loopRegistrationForStage stagePlan kernelTemplate (NodeId "loop_a:iter_0:k"))
        `shouldBe` Just keyA
      fmap fst (loopRegistrationForStage stagePlan kernelTemplate (NodeId "loop_b:iter_0:k"))
        `shouldBe` Just keyB

    it "runtime-bounded iteration evidence: gas-neutral cap loop" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-witnessed-loop"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- A loop of `cap` body executions. iter_0 is the seed body, so the run admits
      -- cap - 1 self-appends. That still exceeds the default rewrite-gas ops budget
      -- (4), proving each AppendAfter is admitted witnessed (gas-neutral). The
      -- kernel uses a STABLE template id so a single spLoopRegistrations entry
      -- authorizes every iteration.
      let cap = 6 :: Int
          kernelTemplate = StageTemplateId "loop_kernel"
          loopFrontierWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-v1"
          readCounter ctx = case Map.elems ctx.scInputs of
            (Aeson.Number n : _) -> round n
            _ -> 0 :: Int
          loopKernel :: StageDefinition NodeId
          loopKernel =
            StageDefinition
              { sdStageId = NodeId "k"
              , sdTemplateId = kernelTemplate
              , sdActionId = stageActionId (NodeId "k")
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = loopAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          loopAction ctx = do
            let i = readCounter ctx
            if i >= cap - 1
              then pure (StageComplete (Aeson.toJSON i))
              else do
                let nid = NodeId ("loop:iter_" <> T.pack (show (i + 1)) <> ":k")
                    nextSpec =
                      SubgraphSpec
                        { sgsTopology = toRelation (path [nid])
                        , sgsDefinitions = Map.singleton nid loopKernel
                        , sgsEntryNodes = [nid]
                        , sgsExitNodes = [nid]
                        }
                    stepWitness =
                      LoopStepWitness
                        { lswFrontierWitness = loopFrontierWitness
                        , lswLoopStateExits = [ctx.scNodeId]
                        }
                pure (StageLoopStep (Aeson.toJSON (i + 1)) stepWitness (AppendAfter ctx.scNodeId nextSpec))
          initialId = NodeId "loop:iter_0:k"
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy cap loopFrontierWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (runtimeIterationRegistration loopPolicy)
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      length rewriteRows `shouldBe` cap - 1
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` replicate (cap - 1) "witnessed"
      let witnessedDeltas =
            [ rewriteDelta
            | (_, _, _, _, Just (Aeson.Object rewriteDelta), _, "witnessed") <- rewriteRows
            ]
      length witnessedDeltas `shouldBe` cap - 1
      forM_ witnessedDeltas $ \rewriteDelta -> do
        rewriteDelta `shouldSatisfy` KeyMap.member "witnessed_loop_step"
        case KeyMap.lookup "witnessed_loop_step" rewriteDelta of
          Just (Aeson.Object metadata) -> do
            metadata `shouldSatisfy` KeyMap.member "policy_version"
            metadata `shouldSatisfy` KeyMap.member "effective_bound"
            metadata `shouldSatisfy` KeyMap.member "remaining_before"
            metadata `shouldSatisfy` KeyMap.member "remaining_after"
            metadata `shouldSatisfy` KeyMap.member "step_witness"
          _ -> expectationFailure "Expected witnessed loop-step replay metadata object"
      maybeStatuses <- readGraphNodeStatuses pool runId
      case maybeStatuses of
        Nothing -> expectationFailure "Expected persisted graph state after witnessed loop"
        Just statuses -> do
          Map.lookup (NodeId "loop:iter_0:k") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "loop:iter_5:k") statuses `shouldBe` Just NodeCompleted

    it "runtime-bounded iteration evidence: paginated ingest" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-witnessed-loop-paginated-ingest"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let cap = 4 :: Int
          terminalCursor = 2 :: Int
          pages :: Map.Map Int [Text]
          pages =
            Map.fromList
              [ (0, ["alpha", "beta"])
              , (1, ["gamma"])
              , (2, ["delta", "epsilon"])
              ]
          kernelTemplate = StageTemplateId "loop_kernel_paginated_ingest"
          loopFrontierWitness = FrontierShapeWitness FrontierWitnessV1 "paginated-ingest-state-v1"
          readNumberField field ctx =
            case Map.elems ctx.scInputs of
              (Aeson.Object input : _) ->
                case KeyMap.lookup field input of
                  Just (Aeson.Number n) -> round n
                  _ -> 0 :: Int
              _ -> 0 :: Int
          pageAt cursor = Map.findWithDefault [] cursor pages
          stateOutput :: Int -> Int -> [Text] -> Aeson.Value
          stateOutput nextCursor seen page =
            Aeson.object
              [ "next_cursor" Aeson..= nextCursor
              , "seen" Aeson..= seen
              , "page" Aeson..= page
              ]
          terminalOutput :: Int -> Int -> [Text] -> Aeson.Value
          terminalOutput cursor seen page =
            Aeson.object
              [ "terminal" Aeson..= True
              , "pages" Aeson..= (cursor + 1)
              , "seen" Aeson..= seen
              , "last_page" Aeson..= page
              ]
          loopKernel :: StageDefinition NodeId
          loopKernel =
            StageDefinition
              { sdStageId = NodeId "k"
              , sdTemplateId = kernelTemplate
              , sdActionId = stageActionId (NodeId "k")
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = loopAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          loopAction ctx = do
            let cursor = readNumberField "next_cursor" ctx
                seenBefore = readNumberField "seen" ctx
                page = pageAt cursor
                seenAfter = seenBefore + length page
            if cursor >= terminalCursor
              then pure (StageComplete (terminalOutput cursor seenAfter page))
              else do
                let nextCursor = cursor + 1
                    nextNode = NodeId ("loop:iter_" <> T.pack (show nextCursor) <> ":k")
                    nextSpec =
                      SubgraphSpec
                        { sgsTopology = toRelation (path [nextNode])
                        , sgsDefinitions = Map.singleton nextNode loopKernel
                        , sgsEntryNodes = [nextNode]
                        , sgsExitNodes = [nextNode]
                        }
                    stepWitness =
                      LoopStepWitness
                        { lswFrontierWitness = loopFrontierWitness
                        , lswLoopStateExits = [ctx.scNodeId]
                        }
                pure
                  ( StageLoopStep
                      (stateOutput nextCursor seenAfter page)
                      stepWitness
                      (AppendAfter ctx.scNodeId nextSpec)
                  )
          initialId = NodeId "loop:iter_0:k"
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy cap loopFrontierWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (runtimeIterationRegistration loopPolicy)
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      length rewriteRows `shouldBe` terminalCursor
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` replicate terminalCursor "witnessed"
      forM_ (zip [1 :: Int ..] rewriteRows) $ \(iter, (_, _, _, _, mRewriteDelta, _, mode)) -> do
        mode `shouldBe` "witnessed"
        case mRewriteDelta of
          Just (Aeson.Object rewriteDelta) -> do
            let expectedNode = "loop:iter_" <> T.pack (show iter) <> ":k"
            KeyMap.lookup "entry_nodes" rewriteDelta `shouldBe` Just (Aeson.toJSON [expectedNode])
            KeyMap.lookup "exit_nodes" rewriteDelta `shouldBe` Just (Aeson.toJSON [expectedNode])
            KeyMap.lookup "witnessed_loop_step" rewriteDelta `shouldSatisfy` isJust
          other -> expectationFailure $ "Expected witnessed rewrite delta object, got " <> show other
      maybeStatuses <- readGraphNodeStatuses pool runId
      case maybeStatuses of
        Nothing -> expectationFailure "Expected persisted graph state after paginated loop"
        Just statuses -> do
          Map.lookup (NodeId "loop:iter_0:k") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "loop:iter_1:k") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "loop:iter_2:k") statuses `shouldBe` Just NodeCompleted
      maybeOutputs <- readGraphNodeOutputs pool runId
      case maybeOutputs of
        Nothing -> expectationFailure "Expected persisted graph outputs after paginated loop"
        Just (outputs, appliedRewriteId) -> do
          appliedRewriteId `shouldSatisfy` isJust
          Map.lookup (NodeId "loop:iter_0:k") outputs
            `shouldBe` Just (stateOutput 1 2 ["alpha", "beta"])
          Map.lookup (NodeId "loop:iter_1:k") outputs
            `shouldBe` Just (stateOutput 2 3 ["gamma"])
          Map.lookup (NodeId "loop:iter_2:k") outputs
            `shouldBe` Just (terminalOutput 2 5 ["delta", "epsilon"])
          adminTopologyResult <-
            Executor.materializedTopologyForAdmin
              (Just (SomeStagePlan stagePlan []))
              pool
              runId
              (Just (fromIntegral rewriteRuntimeVersion :: Int32))
              appliedRewriteId
          case adminTopologyResult of
            Left err ->
              expectationFailure ("Expected admin topology materialization to succeed, got: " <> T.unpack err)
            Right Nothing ->
              expectationFailure "Expected admin topology materialization to return topology"
            Right (Just topology) -> do
              successors topology (NodeId "loop:iter_0:k") `shouldBe` Set.singleton (NodeId "loop:iter_1:k")
              successors topology (NodeId "loop:iter_1:k") `shouldBe` Set.singleton (NodeId "loop:iter_2:k")

    it "runtime-bounded iteration evidence: effective bound" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-witnessed-loop-effective-bound"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let policyCap = 6 :: Int
          effectiveCap = 3 :: Int
          kernelTemplate = StageTemplateId "loop_kernel_effective_bound"
          loopFrontierWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-effective-bound-v1"
          readCounter ctx = case Map.elems ctx.scInputs of
            (Aeson.Number n : _) -> round n
            _ -> 0 :: Int
          loopKernel :: StageDefinition NodeId
          loopKernel =
            StageDefinition
              { sdStageId = NodeId "k"
              , sdTemplateId = kernelTemplate
              , sdActionId = stageActionId (NodeId "k")
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = loopAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          loopAction ctx = do
            let i = readCounter ctx
            if i >= policyCap - 1
              then pure (StageComplete (Aeson.toJSON i))
              else do
                let nid = NodeId ("loop:iter_" <> T.pack (show (i + 1)) <> ":k")
                    nextSpec =
                      SubgraphSpec
                        { sgsTopology = toRelation (path [nid])
                        , sgsDefinitions = Map.singleton nid loopKernel
                        , sgsEntryNodes = [nid]
                        , sgsExitNodes = [nid]
                        }
                    stepWitness =
                      LoopStepWitness
                        { lswFrontierWitness = loopFrontierWitness
                        , lswLoopStateExits = [ctx.scNodeId]
                        }
                pure (StageLoopStep (Aeson.toJSON (i + 1)) stepWitness (AppendAfter ctx.scNodeId nextSpec))
          initialId = NodeId "loop:iter_0:k"
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy policyCap loopFrontierWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (LoopRegistration loopPolicy (EffectiveBound (fromIntegral effectiveCap)))
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      length rewriteRows `shouldBe` effectiveCap - 1
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows
        `shouldBe` replicate (effectiveCap - 1) "witnessed"
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "loop_iteration_budget_exhausted")

    it "runtime-bounded iteration evidence: partial exhaustion completes with typed loop outcome" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-witnessed-loop-partial-bound"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let policyCap = 5 :: Int
          effectiveCap = 2 :: Int
          kernelTemplate = StageTemplateId "loop_kernel_partial_bound"
          loopFrontierWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-partial-bound-v1"
          readCounter ctx = case Map.elems ctx.scInputs of
            (Aeson.Number n : _) -> round n
            _ -> 0 :: Int
          loopKernel :: StageDefinition NodeId
          loopKernel =
            StageDefinition
              { sdStageId = NodeId "k"
              , sdTemplateId = kernelTemplate
              , sdActionId = stageActionId (NodeId "k")
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = loopAction
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          loopAction ctx = do
            let i = readCounter ctx
                nid = NodeId ("loop:iter_" <> T.pack (show (i + 1)) <> ":k")
                nextSpec =
                  SubgraphSpec
                    { sgsTopology = toRelation (path [nid])
                    , sgsDefinitions = Map.singleton nid loopKernel
                    , sgsEntryNodes = [nid]
                    , sgsExitNodes = [nid]
                    }
                stepWitness =
                  LoopStepWitness
                    { lswFrontierWitness = loopFrontierWitness
                    , lswLoopStateExits = [ctx.scNodeId]
                    }
            pure (StageLoopStep (Aeson.toJSON (i + 1)) stepWitness (AppendAfter ctx.scNodeId nextSpec))
          initialId = NodeId "loop:iter_0:k"
          definitions = Map.singleton initialId loopKernel
          loopPolicy =
            (runtimeIterationPolicy policyCap loopFrontierWitness (singleStageKernelWitness loopKernel))
              { lpExhaustion = IterationExhaustionPartial
              , lpAggregation = AggregateAccumulate
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (LoopRegistration loopPolicy (EffectiveBound (fromIntegral effectiveCap)))
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      length rewriteRows `shouldBe` effectiveCap - 1
      maybeOutputs <- readGraphNodeOutputs pool runId
      case maybeOutputs of
        Nothing -> expectationFailure "Expected persisted graph outputs after partial loop exhaustion"
        Just (outputs, _appliedRewriteId) ->
          Map.lookup (NodeId "loop:iter_1:k") outputs
            `shouldBe` Just (Aeson.toJSON (LoopPartial (Aeson.toJSON effectiveCap) (fromIntegral effectiveCap)))

    it "runtime-bounded iteration evidence: unauthorized loop step" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-unauthorized-loop"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- A stage emits StageLoopStep but its template is NOT registered in
      -- spLoopRegistrations, so it is not authorized for gas-neutral admission. It must
      -- route to the gassed path, which is fail-closed for a flat-namespaced spec
      -- (the gassed path re-namespaces under the anchor and rejects ':' ids), so
      -- the run fails rather than getting a free witnessed append.
      let driverId = NodeId "loop:iter_0:k"
          nextNode = NodeId "loop:iter_1:k"
          driverAction ctx =
            let nextSpec =
                  SubgraphSpec
                    { sgsTopology = toRelation (path [nextNode])
                    , sgsDefinitions = Map.singleton nextNode (nodeStage nextNode (\_ -> pure (StageComplete Aeson.Null)))
                    , sgsEntryNodes = [nextNode]
                    , sgsExitNodes = [nextNode]
                    }
                stepWitness =
                  LoopStepWitness
                    { lswFrontierWitness = FrontierShapeWitness FrontierWitnessV1 "unauthorized-loop"
                    , lswLoopStateExits = [ctx.scNodeId]
                    }
             in pure (StageLoopStep Aeson.Null stepWitness (AppendAfter ctx.scNodeId nextSpec))
          definitions = Map.singleton driverId (nodeStage driverId driverAction)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [driverId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` []

    it "runtime-bounded iteration evidence: bad frontier witness" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-loop-frontier-witness-rejected"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let cap = 2 :: Int
          kernelTemplate = StageTemplateId "loop_kernel_bad_witness"
          expectedWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-v1"
          badWitness = FrontierShapeWitness FrontierWitnessV1 "changed-frontier"
          initialId = NodeId "loop:iter_0:k"
          nextNode = NodeId "loop:iter_1:k"
          loopAction ctx =
            let nextSpec =
                  SubgraphSpec
                    { sgsTopology = toRelation (path [nextNode])
                    , sgsDefinitions = Map.singleton nextNode loopKernel
                    , sgsEntryNodes = [nextNode]
                    , sgsExitNodes = [nextNode]
                    }
                stepWitness =
                  LoopStepWitness
                    { lswFrontierWitness = badWitness
                    , lswLoopStateExits = [ctx.scNodeId]
                    }
             in pure (StageLoopStep Aeson.Null stepWitness (AppendAfter ctx.scNodeId nextSpec))
          loopKernel = (nodeStage (NodeId "k") loopAction) {sdTemplateId = kernelTemplate}
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy cap expectedWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (runtimeIterationRegistration loopPolicy)
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` []
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "witnessed_step_violation")

    it "runtime-bounded iteration evidence: bad kernel witness" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-loop-kernel-witness-rejected"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let cap = 2 :: Int
          kernelTemplate = StageTemplateId "loop_kernel_bad_kernel"
          expectedWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-v1"
          initialId = NodeId "loop:iter_0:k"
          unexpectedNode = NodeId "loop:iter_1:other"
          loopAction ctx =
            let nextSpec =
                  SubgraphSpec
                    { sgsTopology = toRelation (path [unexpectedNode])
                    , sgsDefinitions = Map.singleton unexpectedNode loopKernel
                    , sgsEntryNodes = [unexpectedNode]
                    , sgsExitNodes = [unexpectedNode]
                    }
                stepWitness =
                  LoopStepWitness
                    { lswFrontierWitness = expectedWitness
                    , lswLoopStateExits = [ctx.scNodeId]
                    }
             in pure (StageLoopStep Aeson.Null stepWitness (AppendAfter ctx.scNodeId nextSpec))
          loopKernel = (nodeStage (NodeId "k") loopAction) {sdTemplateId = kernelTemplate}
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy cap expectedWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (runtimeIterationRegistration loopPolicy)
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` []
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "witnessed_step_violation")

    it "runtime-bounded iteration evidence: rewrite-closed kernel" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-loop-open-rewrite-rejected"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let cap = 2 :: Int
          kernelTemplate = StageTemplateId "loop_kernel_open_rewrite"
          expectedWitness = FrontierShapeWitness FrontierWitnessV1 "loop-kernel-v1"
          initialId = NodeId "loop:iter_0:k"
          nextNode = NodeId "loop:iter_1:k"
          nextSpec =
            SubgraphSpec
              { sgsTopology = toRelation (path [nextNode])
              , sgsDefinitions = Map.singleton nextNode loopKernel
              , sgsEntryNodes = [nextNode]
              , sgsExitNodes = [nextNode]
              }
          loopAction ctx =
            pure (StageRewrite Aeson.Null (AppendAfter ctx.scNodeId nextSpec))
          loopKernel = (nodeStage (NodeId "k") loopAction) {sdTemplateId = kernelTemplate}
          definitions = Map.singleton initialId loopKernel
          loopPolicy = runtimeIterationPolicy cap expectedWitness (singleStageKernelWitness loopKernel)
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [initialId])
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations =
                  Map.singleton
                    (runtimeIterationInstance kernelTemplate loopPolicy)
                    (runtimeIterationRegistration loopPolicy)
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      fmap (\(_, _, _, _, _, _, mode) -> mode) rewriteRows `shouldBe` []
      adminRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      case adminRows of
        [row] -> do
          row.pgravSourceNodeId `shouldBe` "loop:iter_0:k"
          row.pgravStatus `shouldBe` "rejected"
          row.pgravRejectionReason
            `shouldSatisfy` maybe False (T.isInfixOf "ordinary StageRewrite is not admissible")
          row.pgravRewriteSpec
            `shouldBe` Aeson.toJSON (fmap toSerializableStageDefinition (AppendAfter initialId nextSpec))
          row.pgravBudgetBefore `shouldBe` Just (Aeson.toJSON defaultRewriteBudget)
          row.pgravBudgetAfter `shouldBe` Nothing
        rows ->
          expectationFailure
            ("Expected exactly one rejected loop-body rewrite row, got " <> show (length rows))
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "loop_kernel_open_rewrite_rejected")

    it "allows concurrent sibling rewrites to consume shared gas in admission order" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContextWith pool 4
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-recursive-append-rewrite-gas"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let anchorId = NodeId "a"
          reviewerId = NodeId "reviewer"
          completeNode localId =
            nodeStage (NodeId localId) $ \ctx ->
              pure
                ( StageComplete
                    ( Aeson.object
                        [ "nodeId" Aeson..= unNodeId ctx.scNodeId
                        , "inputs" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                        ]
                    )
                )
          pairSubgraph leftId rightId =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId leftId) <> Vertex (NodeId rightId))
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId leftId, completeNode leftId)
                    , (NodeId rightId, completeNode rightId)
                    ]
              , sgsEntryNodes = [NodeId leftId, NodeId rightId]
              , sgsExitNodes = [NodeId leftId, NodeId rightId]
              }
          firstSubgraph =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "c") <> Vertex (NodeId "d"))
              , sgsDefinitions =
                  Map.fromList
                    [
                      ( NodeId "c"
                      , nodeStage (NodeId "c") $ \ctx ->
                          pure
                            ( StageRewrite
                                ( Aeson.object
                                    [ "nodeId" Aeson..= unNodeId ctx.scNodeId
                                    , "inputs" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                                    ]
                                )
                                (AppendAfter ctx.scNodeId (pairSubgraph "e" "f"))
                            )
                      )
                    ,
                      ( NodeId "d"
                      , nodeStage (NodeId "d") $ \ctx ->
                          pure
                            ( StageRewrite
                                ( Aeson.object
                                    [ "nodeId" Aeson..= unNodeId ctx.scNodeId
                                    , "inputs" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                                    ]
                                )
                                (AppendAfter ctx.scNodeId (pairSubgraph "g" "h"))
                            )
                      )
                    ]
              , sgsEntryNodes = [NodeId "c", NodeId "d"]
              , sgsExitNodes = [NodeId "c", NodeId "d"]
              }
          definitions =
            Map.fromList
              [
                ( anchorId
                , nodeStage anchorId $ \ctx ->
                    pure
                      ( StageRewrite
                          ( Aeson.object
                              [ "nodeId" Aeson..= unNodeId ctx.scNodeId
                              , "inputs" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                              ]
                          )
                          (AppendAfter ctx.scNodeId firstSubgraph)
                      )
                )
              ,
                ( reviewerId
                , nodeStage reviewerId $ \ctx ->
                    pure
                      ( StageComplete
                          ( Aeson.object
                              [ "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                              ]
                          )
                      )
                )
              ]
          recursiveBudget =
            RewriteBudget
              { rbAddedNodesMax = 6
              , rbAddedEdgesMax = 12
              , rbAddedDepthMax = 3
              , rbFrontierDeltaMax = 3
              , rbRewriteOpsMax = 3
              }
          spentBudget =
            RewriteBudget
              { rbAddedNodesMax = 0
              , rbAddedEdgesMax = 0
              , rbAddedDepthMax = 0
              , rbFrontierDeltaMax = 0
              , rbRewriteOpsMax = 0
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = recursiveBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 1
              , spTopology = toRelation (edge anchorId reviewerId)
              , spDefinitions = definitions
              , spTemplateRegistry = mkTemplateRegistry definitions
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      case rewriteRows of
        [firstRow, secondRow, thirdRow] -> do
          firstRow.pgravSourceNodeId `shouldBe` "a"
          firstRow.pgravStatus `shouldBe` "admitted"
          Set.fromList [secondRow.pgravSourceNodeId, thirdRow.pgravSourceNodeId]
            `shouldBe` Set.fromList ["a:c", "a:d"]
          secondRow.pgravStatus `shouldBe` "admitted"
          thirdRow.pgravStatus `shouldBe` "admitted"
          secondRow.pgravBudgetBefore `shouldBe` firstRow.pgravBudgetAfter
          thirdRow.pgravBudgetBefore `shouldBe` secondRow.pgravBudgetAfter
          thirdRow.pgravBudgetAfter `shouldBe` Just (Aeson.toJSON spentBudget)
        rows -> expectationFailure ("Expected exactly three admitted rewrite rows, got " <> show (length rows))
      maybeStatuses <- readGraphNodeStatuses pool runId
      case maybeStatuses of
        Nothing -> expectationFailure "Expected persisted graph state after recursive append rewrite"
        Just statuses -> do
          Map.lookup anchorId statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "a:c") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "a:d") statuses `shouldBe` Just NodeRewritten
          Map.lookup (NodeId "a:c:e") statuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "a:c:f") statuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "a:d:g") statuses `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "a:d:h") statuses `shouldBe` Just NodeCompleted
          Map.lookup reviewerId statuses `shouldBe` Just NodeCompleted
      maybeOutputs <- readGraphNodeOutputs pool runId
      case maybeOutputs of
        Nothing -> expectationFailure "Expected persisted graph outputs after recursive append rewrite"
        Just (outputs, appliedRewriteId) -> do
          appliedRewriteId `shouldSatisfy` isJust
          Map.lookup reviewerId outputs
            `shouldBe` Just
              ( Aeson.object
                  [ "inputNodeIds" Aeson..= ["a:c:e" :: Text, "a:c:f", "a:d:g", "a:d:h"]
                  ]
              )
          adminTopologyResult <-
            Executor.materializedTopologyForAdmin
              (Just (SomeStagePlan stagePlan []))
              pool
              runId
              (Just (fromIntegral rewriteRuntimeVersion :: Int32))
              appliedRewriteId
          case adminTopologyResult of
            Left err ->
              expectationFailure ("Expected admin topology materialization to succeed, got: " <> T.unpack err)
            Right Nothing ->
              expectationFailure "Expected admin topology materialization to return topology"
            Right (Just topology) -> do
              successors topology anchorId
                `shouldBe` Set.fromList
                  [ NodeId "a:c"
                  , NodeId "a:d"
                  ]
              successors topology (NodeId "a:c")
                `shouldBe` Set.fromList
                  [ NodeId "a:c:e"
                  , NodeId "a:c:f"
                  ]
              successors topology (NodeId "a:c:e") `shouldBe` Set.singleton reviewerId
              successors topology (NodeId "a:c:f") `shouldBe` Set.singleton reviewerId
              successors topology (NodeId "a:d")
                `shouldBe` Set.fromList
                  [ NodeId "a:d:g"
                  , NodeId "a:d:h"
                  ]
              successors topology (NodeId "a:d:g") `shouldBe` Set.singleton reviewerId
              successors topology (NodeId "a:d:h") `shouldBe` Set.singleton reviewerId

    it
      "rejects an over-budget raw Wire append proposal and re-executes the anchor with rejection context"
      $ \mPool -> withDb mPool $ \pool -> do
        (_shutdownFlag, taskContext) <- mkTaskContext pool
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-wire-proposal-budget-rejection"
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        attemptsRef <- newIORef (0 :: Int)
        compiledProposal <-
          case compileWireAppendProposalWithEnv wireSmokeCompileEnv wireSmokeAppendHole wireSmokeProposalSource of
            Left err ->
              expectationFailure ("Expected Wire proposal to compile, got: " <> show err) >> error "unreachable"
            Right compiled -> pure compiled
        proposalPlan <-
          case lowerCompiledCircuitToStagePlan wireSmokePulseConfig wireSmokeBinder compiledProposal of
            Left err -> expectationFailure ("Expected Wire proposal to lower, got: " <> show err) >> error "unreachable"
            Right loweredPlan -> pure loweredPlan
        let subgraph =
              SubgraphSpec
                { sgsTopology = proposalPlan.spTopology
                , sgsDefinitions = proposalPlan.spDefinitions
                , sgsEntryNodes = fmap nodeIdFromCircuitRef compiledProposal.compiledCircuitEntryNodes
                , sgsExitNodes = fmap nodeIdFromCircuitRef compiledProposal.compiledCircuitExitNodes
                }
            analystId = NodeId "analyst"
            reviewerId = NodeId "reviewer"
            analystDef =
              nodeStage analystId $ \ctx -> do
                atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                case ctx.scRewriteRejection of
                  Nothing ->
                    pure (StageRewrite (Aeson.String "analyst-output") (AppendAfter analystId subgraph))
                  Just rejectionCtx ->
                    pure
                      ( StageComplete
                          ( Aeson.object
                              [ "degraded" Aeson..= True
                              , "rejectionType" Aeson..= rejectionCtx.rrcRejectionType
                              , "exceededDimensions" Aeson..= rejectionCtx.rrcExceededDimensions
                              ]
                          )
                      )
            reviewerDef =
              nodeStage reviewerId $ \ctx ->
                pure
                  ( StageComplete
                      ( Aeson.object
                          [ "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                          , "inputs" Aeson..= ctx.scInputs
                          ]
                      )
                  )
            definitions =
              Map.fromList
                [ (analystId, analystDef)
                , (reviewerId, reviewerDef)
                ]
            tinyBudget =
              RewriteBudget
                { rbAddedNodesMax = 1
                , rbAddedEdgesMax = 100
                , rbAddedDepthMax = 100
                , rbFrontierDeltaMax = 100
                , rbRewriteOpsMax = 100
                }
            stagePlan =
              StagePlan
                { spInitialState = Aeson.String "seed"
                , spCheckpointRuntimeVersion = rewriteRuntimeVersion
                , spReplayPolicy = ReplayPolicyWarn
                , spInitialRewriteBudget = tinyBudget
                , spRewriteExhaustionPolicy = RewriteExhaustionDegrade
                , spBudgetExceededExhaustionPolicy = Nothing
                , spMaxRewriteReExecutions = 1
                , spTopology = toRelation (edge analystId reviewerId)
                , spDefinitions = definitions
                , spTemplateRegistry = mkTemplateRegistry definitions
                , spLoopRegistrations = Map.empty
                }
        outcome <- executeStagePlan taskContext runId task stagePlan
        outcome `shouldBe` OutcomeCompleted
        attempts <- readIORef attemptsRef
        attempts `shouldBe` 2
        rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
        case rewriteRows of
          [row] -> do
            row.pgravStatus `shouldBe` "rejected"
            row.pgravRejectionReason
              `shouldSatisfy` maybe False (T.isInfixOf "Rewrite exceeded remaining budget")
            row.pgravExceededDimensions `shouldSatisfy` isJust
            row.pgravBudgetBefore `shouldBe` Just (Aeson.toJSON tinyBudget)
            row.pgravBudgetAfter `shouldBe` Nothing
          rows -> expectationFailure ("Expected exactly one rejected rewrite row, got " <> show (length rows))
        maybeStatuses <- readGraphNodeStatuses pool runId
        case maybeStatuses of
          Nothing -> expectationFailure "Expected persisted graph state after Wire budget rejection smoke"
          Just statuses -> do
            Map.lookup analystId statuses `shouldBe` Just NodeCompleted
            Map.lookup (NodeId "analyst:stress_alpha") statuses `shouldBe` Nothing
            Map.lookup (NodeId "analyst:stress_beta") statuses `shouldBe` Nothing
            Map.lookup reviewerId statuses `shouldBe` Just NodeCompleted
        maybeOutputs <- readGraphNodeOutputs pool runId
        case maybeOutputs of
          Nothing -> expectationFailure "Expected persisted graph outputs after Wire budget rejection smoke"
          Just (outputs, appliedRewriteId) -> do
            appliedRewriteId `shouldBe` Nothing
            Map.lookup reviewerId outputs
              `shouldBe` Just
                ( Aeson.object
                    [ "inputNodeIds" Aeson..= ["analyst" :: Text]
                    , "inputs"
                        Aeson..= Map.singleton
                          analystId
                          ( Aeson.object
                              [ "degraded" Aeson..= True
                              , "rejectionType" Aeson..= ("rewrite_budget_exceeded" :: Text)
                              , "exceededDimensions"
                                  Aeson..= [ Aeson.object
                                               [ "edDimension" Aeson..= ("DimAddedNodes" :: Text)
                                               , "edRequested" Aeson..= (2 :: Int)
                                               , "edRemaining" Aeson..= (1 :: Int)
                                               ]
                                           ]
                              ]
                          )
                    ]
                )

    it "materializes admitted rewrites from lineage when graph_state watermark lags" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-watermark-gap"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
              , sgsDefinitions =
                  Map.fromList
                    [
                      ( NodeId "sub1"
                      , mkRegistryDef
                          (StageTemplateId "template/sub1")
                          "sub1"
                          (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                      )
                    ,
                      ( NodeId "sub2"
                      , mkRegistryDef
                          (StageTemplateId "template/sub2")
                          "sub2"
                          (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                      )
                    ]
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub2"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage
                          "alpha"
                          ( \_ -> do
                              atomically $ writeTVar shutdownFlag True
                              pure
                                ( StageRewrite
                                    (Aeson.String "alpha-output")
                                    (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec)
                                )
                          )
                      )
                    ,
                      ( NodeId "template_sub1"
                      , mkRegistryDef
                          (StageTemplateId "template/sub1")
                          "sub1"
                          (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                      )
                    ,
                      ( NodeId "template_sub2"
                      , mkRegistryDef
                          (StageTemplateId "template/sub2")
                          "sub2"
                          (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage
                            "alpha"
                            ( \_ -> do
                                atomically $ writeTVar shutdownFlag True
                                pure
                                  ( StageRewrite
                                      (Aeson.String "alpha-output")
                                      (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec)
                                  )
                            )
                        )
                      ,
                        ( NodeId "template_sub1"
                        , mkRegistryDef
                            (StageTemplateId "template/sub1")
                            "sub1"
                            (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                        )
                      ,
                        ( NodeId "template_sub2"
                        , mkRegistryDef
                            (StageTemplateId "template/sub2")
                            "sub2"
                            (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeShutdown
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      rewriteId <-
        case rewriteRows of
          (rid, _, _, _, _, _, _) : _ -> pure rid
          [] -> expectationFailure "Expected persisted rewrite lineage" >> pure 0
      let staleStatuses = Aeson.toJSON (Map.singleton (NodeId "alpha") NodeRewritten)
          staleOutputs =
            Aeson.toJSON
              (Map.singleton (NodeId "alpha") (Aeson.String "alpha-output") :: Map.Map NodeId Aeson.Value)
      writeGraphStateCompat
        pool
        runId
        staleStatuses
        staleOutputs
        (Just (fromIntegral rewriteRuntimeVersion :: Int32))
        Nothing
      atomically $ writeTVar shutdownFlag False
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state after watermark-gap resume"
        Just m -> do
          Map.lookup (NodeId "alpha") m `shouldBe` Nothing
          Map.lookup (NodeId "alpha:sub1") m `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "alpha:sub2") m `shouldBe` Just NodeCompleted
      outputs <- readGraphNodeOutputs pool runId
      case outputs of
        Nothing -> expectationFailure "Expected graph outputs after watermark-gap resume"
        Just (_m, appliedRewriteId) ->
          appliedRewriteId `shouldBe` Just rewriteId

    it "materializes admin topology from latent template registry entries" $ \mPool -> withDb mPool $ \pool -> do
      taskId <-
        insertTestTaskDef pool "paper_portfolio_cycle" "test-admin-topology-latent-template-registry"
      runId <- createTestRun pool taskId
      now <- getCurrentTime
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "sub1"))
              , sgsDefinitions =
                  Map.singleton
                    (NodeId "sub1")
                    ( mkRegistryDef
                        (StageTemplateId "template/sub1")
                        "sub1"
                        (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                    )
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub1"]
              }
          visibleDefinitions =
            Map.singleton
              (NodeId "alpha")
              (mkDynLinearStage "alpha" (\_ state -> pure (Aeson.object ["alpha" Aeson..= state])))
          templateDefinitions =
            visibleDefinitions
              <> Map.singleton
                (NodeId "template_sub1")
                ( mkRegistryDef
                    (StageTemplateId "template/sub1")
                    "sub1"
                    (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                )
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions = visibleDefinitions
              , spTemplateRegistry = mkTemplateRegistry templateDefinitions
              , spLoopRegistrations = Map.empty
              }
          serializableRewrite =
            Aeson.toJSON $
              fmap Executor.toSerializableStageDefinition (AppendAfter (NodeId "alpha") rewriteSpec)
      rewriteId <-
        runTx pool $
          Q.writeGraphRewrite
            Q.GraphRewriteInsert
              { griRunId = runId
              , griSourceNodeId = "alpha"
              , griSourceNodeOutput = Nothing
              , griRewriteCost = Nothing
              , griRewriteDelta = Nothing
              , griBudgetBefore = Nothing
              , griBudgetAfter = Nothing
              , griRewriteSpec = serializableRewrite
              , griStatus = "admitted"
              , griRejectionReason = Nothing
              , griExceededDimensions = Nothing
              , griCreatedAt = now
              , griAdmissionMode = "gassed"
              }
      topologyResult <-
        Executor.materializedTopologyForAdmin
          (Just (SomeStagePlan stagePlan []))
          pool
          runId
          (Just (fromIntegral rewriteRuntimeVersion :: Int32))
          (Just rewriteId)
      case topologyResult of
        Left err ->
          expectationFailure ("Expected admin topology materialization to succeed, got: " <> T.unpack err)
        Right Nothing ->
          expectationFailure "Expected a materialized admin topology"
        Right (Just topology) -> do
          Set.member (NodeId "alpha") topology.relVertices `shouldBe` True
          Set.member (NodeId "alpha:sub1") topology.relVertices `shouldBe` True
          successors topology (NodeId "alpha") `shouldBe` Set.singleton (NodeId "alpha:sub1")

    it "repairs missing rewritten node statuses from the materialized watermark topology on resume" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-resume-repair"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
              , sgsDefinitions =
                  Map.fromList
                    [
                      ( NodeId "sub1"
                      , mkRegistryDef
                          (StageTemplateId "template/sub1")
                          "sub1"
                          (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                      )
                    ,
                      ( NodeId "sub2"
                      , mkRegistryDef
                          (StageTemplateId "template/sub2")
                          "sub2"
                          (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                      )
                    ]
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub2"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage
                          "alpha"
                          ( \_ -> do
                              atomically $ writeTVar shutdownFlag True
                              pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                          )
                      )
                    ,
                      ( NodeId "template_sub1"
                      , mkRegistryDef
                          (StageTemplateId "template/sub1")
                          "sub1"
                          (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                      )
                    ,
                      ( NodeId "template_sub2"
                      , mkRegistryDef
                          (StageTemplateId "template/sub2")
                          "sub2"
                          (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage
                            "alpha"
                            ( \_ -> do
                                atomically $ writeTVar shutdownFlag True
                                pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                            )
                        )
                      ,
                        ( NodeId "template_sub1"
                        , mkRegistryDef
                            (StageTemplateId "template/sub1")
                            "sub1"
                            (\_ state -> pure (Aeson.object ["sub1" Aeson..= state]))
                        )
                      ,
                        ( NodeId "template_sub2"
                        , mkRegistryDef
                            (StageTemplateId "template/sub2")
                            "sub2"
                            (\_ state -> pure (Aeson.object ["sub2" Aeson..= state]))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeShutdown
      rewriteRows <- runSession pool $ Q.readGraphRewrites runId
      rewriteId <-
        case rewriteRows of
          [(rid, _, _, _, _, _, _)] -> pure rid
          rows ->
            expectationFailure ("Expected exactly one persisted rewrite, got " <> show (length rows)) >> pure 0
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (Map.empty :: Map.Map NodeId NodeStatus))
        (Aeson.toJSON (Map.empty :: Map.Map NodeId Aeson.Value))
        (Just (fromIntegral rewriteRuntimeVersion :: Int32))
        (Just rewriteId)
      atomically $ writeTVar shutdownFlag False
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state after repaired resume"
        Just m -> do
          Map.lookup (NodeId "alpha:sub1") m `shouldBe` Just NodeCompleted
          Map.lookup (NodeId "alpha:sub2") m `shouldBe` Just NodeCompleted

    it "ignores rejected rewrite rows during resume replay" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-resume-ignore-rejected"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      now <- getCurrentTime
      let invalidRejectedRewrite =
            Aeson.object
              [ "unexpected" Aeson..= True
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.singleton
                    (NodeId "alpha")
                    (mkDynLinearStage "alpha" (\_ state -> pure (Aeson.object ["alpha" Aeson..= state])))
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.singleton
                      (NodeId "alpha")
                      (mkDynLinearStage "alpha" (\_ state -> pure (Aeson.object ["alpha" Aeson..= state])))
              , spLoopRegistrations = Map.empty
              }
      _ <-
        runTx pool $
          Q.writeGraphRewrite
            Q.GraphRewriteInsert
              { griRunId = runId
              , griSourceNodeId = "alpha"
              , griSourceNodeOutput = Nothing
              , griRewriteCost = Nothing
              , griRewriteDelta = Nothing
              , griBudgetBefore = Nothing
              , griBudgetAfter = Nothing
              , griRewriteSpec = invalidRejectedRewrite
              , griStatus = "rejected"
              , griRejectionReason = Just "rewrite anchor missing from snapshot"
              , griExceededDimensions = Nothing
              , griCreatedAt = now
              , griAdmissionMode = "gassed"
              }
      writeGraphStateCompat
        pool
        runId
        (Aeson.toJSON (Map.empty :: Map.Map NodeId NodeStatus))
        (Aeson.toJSON (Map.empty :: Map.Map NodeId Aeson.Value))
        (Just (fromIntegral rewriteRuntimeVersion :: Int32))
        Nothing
      replayRows <- runSession pool $ Q.readGraphRewrites runId
      replayRows `shouldBe` []
      adminRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      fmap Q.pgravStatus adminRows `shouldBe` ["rejected"]
      outcome <- resumeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      statuses <- readGraphNodeStatuses pool runId
      case statuses of
        Nothing -> expectationFailure "Expected graph state after ignoring rejected rewrite resume"
        Just m ->
          Map.lookup (NodeId "alpha") m `shouldBe` Just NodeCompleted

    it "rolls back rejected rewrite history when marking the run failed aborts" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-rejection-atomic"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "sub1"))
              , sgsDefinitions =
                  Map.singleton
                    (NodeId "sub1")
                    (mkDynLinearStage "sub1" (\_ state -> pure (Aeson.object ["sub" Aeson..= state])))
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub1"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.singleton
                    (NodeId "alpha")
                    ( mkDynStage "alpha" $ \_ ->
                        pure (StageRewrite Aeson.Null (ExpandNode (NodeId "missing-anchor") ExpandReplaceNode rewriteSpec))
                    )
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.singleton
                      (NodeId "alpha")
                      ( mkDynStage "alpha" $ \_ ->
                          pure (StageRewrite Aeson.Null (ExpandNode (NodeId "missing-anchor") ExpandReplaceNode rewriteSpec))
                      )
              , spLoopRegistrations = Map.empty
              }
      outcome <-
        withInjectedRunFailedWriteFailure pool runId $
          executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      rewriteRows `shouldBe` []
      readRunStatus pool runId `shouldReturn` Just "running"

    it "persists per-node provenance and topology hash after a successful rewrite" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-provenance"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "sub1"))
              , sgsDefinitions =
                  Map.singleton
                    (NodeId "sub1")
                    (mkDynLinearStage "sub1" (\_ state -> pure (Aeson.object ["sub" Aeson..= state])))
              , sgsEntryNodes = [NodeId "sub1"]
              , sgsExitNodes = [NodeId "sub1"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [NodeId "alpha", NodeId "beta"])
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ ->
                          pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                      )
                    ,
                      ( NodeId "beta"
                      , mkDynLinearStage "beta" (\_ state -> pure (Aeson.object ["beta" Aeson..= state]))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ ->
                            pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                        )
                      ,
                        ( NodeId "beta"
                        , mkDynLinearStage "beta" (\_ state -> pure (Aeson.object ["beta" Aeson..= state]))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      graphState <- runSession pool $ Q.readGraphState runId
      case graphState of
        Nothing -> expectationFailure "Expected graph state after rewrite provenance test"
        Just snapshot -> do
          snapshot.pgssTopologyHash `shouldSatisfy` isJust
          case snapshot.pgssNodeProvenance of
            Nothing -> expectationFailure "Expected node_provenance to be persisted"
            Just provenanceJson ->
              case Aeson.fromJSON provenanceJson of
                Aeson.Error err -> expectationFailure $ "Failed to decode provenance: " <> err
                Aeson.Success (provMap :: Map.Map NodeId NodeProvenanceEntry) -> do
                  let subNodeProv = Map.lookup (NodeId "alpha:sub1") provMap
                  case subNodeProv of
                    Nothing -> expectationFailure "Expected provenance for alpha:sub1"
                    Just entry -> do
                      entry.npeIntroducedByRewriteId `shouldSatisfy` isJust
                      entry.npeAnchorNodeId `shouldBe` Just (NodeId "alpha")
                  let betaNodeProv = Map.lookup (NodeId "beta") provMap
                  case betaNodeProv of
                    Nothing -> expectationFailure "Expected provenance for beta"
                    Just entry ->
                      entry.npeIntroducedByRewriteId `shouldBe` Nothing

    it "fails resume when a persisted rewrite cannot hydrate a stage template" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-resume-unknown-template"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "mystery"))
              , sgsDefinitions =
                  Map.singleton
                    (NodeId "mystery")
                    ( StageDefinition
                        { sdStageId = DynStageId "shared_semantic_stage"
                        , sdTemplateId = StageTemplateId "missing/template"
                        , sdActionId = stageActionId (DynStageId "shared_semantic_stage")
                        , sdReplaySafety = SafeToReplay
                        , sdReplayPolicyOverride = Nothing
                        , sdTimeoutSeconds = Nothing
                        , sdRetryPolicy = Nothing
                        , sdAction = liftChainAction (\_ state -> pure state)
                        , sdMemoryStrategy = defaultMemoryStrategy
                        }
                    )
              , sgsEntryNodes = [NodeId "mystery"]
              , sgsExitNodes = [NodeId "mystery"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ -> do
                          atomically $ writeTVar shutdownFlag True
                          pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ -> do
                            atomically $ writeTVar shutdownFlag True
                            pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeShutdown
      atomically $ writeTVar shutdownFlag False
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "graph_rewrite_hydration_failed")

    it "fails rewrite admission when the runtime registry contains duplicate template ids" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-duplicate-template-registry"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let duplicateTemplate = StageTemplateId "shared/template"
          rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "shared"))
              , sgsDefinitions =
                  Map.singleton
                    (NodeId "shared")
                    ( StageDefinition
                        { sdStageId = DynStageId "shared_semantic_stage"
                        , sdTemplateId = duplicateTemplate
                        , sdActionId = stageActionId (DynStageId "shared_semantic_stage")
                        , sdReplaySafety = SafeToReplay
                        , sdReplayPolicyOverride = Nothing
                        , sdTimeoutSeconds = Nothing
                        , sdRetryPolicy = Nothing
                        , sdAction = liftChainAction (\_ state -> pure state)
                        , sdMemoryStrategy = defaultMemoryStrategy
                        }
                    )
              , sgsEntryNodes = [NodeId "shared"]
              , sgsExitNodes = [NodeId "shared"]
              }
          duplicateRegistryA =
            ( NodeId "template_shared_a"
            , StageDefinition
                { sdStageId = DynStageId "shared_stage_a"
                , sdTemplateId = duplicateTemplate
                , sdActionId = stageActionId (DynStageId "shared_stage_a")
                , sdReplaySafety = SafeToReplay
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction =
                    liftChainAction
                      (\_ state -> pure (Aeson.object ["template" Aeson..= ("a" :: Text), "state" Aeson..= state]))
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          duplicateRegistryB =
            ( NodeId "template_shared_b"
            , StageDefinition
                { sdStageId = DynStageId "shared_stage_b"
                , sdTemplateId = duplicateTemplate
                , sdActionId = stageActionId (DynStageId "shared_stage_b")
                , sdReplaySafety = SafeToReplay
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction =
                    liftChainAction
                      (\_ state -> pure (Aeson.object ["template" Aeson..= ("b" :: Text), "state" Aeson..= state]))
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ -> do
                          atomically $ writeTVar shutdownFlag True
                          pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                      )
                    , duplicateRegistryA
                    , duplicateRegistryB
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ -> do
                            atomically $ writeTVar shutdownFlag True
                            pure (StageRewrite Aeson.Null (ExpandNode (NodeId "alpha") ExpandReplaceNode rewriteSpec))
                        )
                      , duplicateRegistryA
                      , duplicateRegistryB
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeFailed
      runView <- runSession pool $ Q.getRunAdminView runId
      fmap Q.pravErrorType runView `shouldBe` Just (Just "invalid_rewrite")

    it "hydrates rewritten stages by template id even when semantic stage ids are reused" $ \mPool -> withDb mPool $ \pool -> do
      (shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-rewrite-template-identity"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      let templateA = StageTemplateId "shared/template-a"
          templateB = StageTemplateId "shared/template-b"
          sharedTemplateA =
            ( NodeId "template_shared_a"
            , StageDefinition
                { sdStageId = DynStageId "shared_sub"
                , sdTemplateId = templateA
                , sdActionId = stageActionId (DynStageId "shared_sub")
                , sdReplaySafety = Irreversible
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction =
                    liftChainAction
                      (\_ state -> pure (Aeson.object ["template" Aeson..= ("a" :: Text), "state" Aeson..= state]))
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          sharedTemplateB =
            ( NodeId "template_shared_b"
            , StageDefinition
                { sdStageId = DynStageId "shared_sub"
                , sdTemplateId = templateB
                , sdActionId = stageActionId (DynStageId "shared_sub")
                , sdReplaySafety = Irreversible
                , sdReplayPolicyOverride = Nothing
                , sdTimeoutSeconds = Nothing
                , sdRetryPolicy = Nothing
                , sdAction =
                    liftChainAction
                      (\_ state -> pure (Aeson.object ["template" Aeson..= ("b" :: Text), "state" Aeson..= state]))
                , sdMemoryStrategy = defaultMemoryStrategy
                }
            )
          mkSharedRewrite templateId templateTag =
            SubgraphSpec
              { sgsTopology = toRelation (Vertex (NodeId "shared"))
              , sgsDefinitions =
                  Map.fromList
                    [
                      ( NodeId "shared"
                      , StageDefinition
                          { sdStageId = DynStageId "shared_sub"
                          , sdTemplateId = templateId
                          , sdActionId = stageActionId (DynStageId "shared_sub")
                          , sdReplaySafety = Irreversible
                          , sdReplayPolicyOverride = Nothing
                          , sdTimeoutSeconds = Nothing
                          , sdRetryPolicy = Nothing
                          , sdAction =
                              liftChainAction
                                (\_ state -> pure (Aeson.object ["template" Aeson..= templateTag, "state" Aeson..= state]))
                          , sdMemoryStrategy = defaultMemoryStrategy
                          }
                      )
                    ]
              , sgsEntryNodes = [NodeId "shared"]
              , sgsExitNodes = [NodeId "shared"]
              }
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = rewriteRuntimeVersion
              , spReplayPolicy = ReplayPolicyBlockResume
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (path [NodeId "alpha", NodeId "beta"] :: Graph NodeId)
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage
                          "alpha"
                          ( \_ ->
                              pure
                                ( StageRewrite
                                    Aeson.Null
                                    (ExpandNode (NodeId "alpha") ExpandReplaceNode (mkSharedRewrite templateA ("a" :: Text)))
                                )
                          )
                      )
                    ,
                      ( NodeId "beta"
                      , mkDynStage "beta" $ \_ -> do
                          atomically $ writeTVar shutdownFlag True
                          pure
                            ( StageRewrite
                                Aeson.Null
                                (ExpandNode (NodeId "beta") ExpandReplaceNode (mkSharedRewrite templateB ("b" :: Text)))
                            )
                      )
                    , sharedTemplateA
                    , sharedTemplateB
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage
                            "alpha"
                            ( \_ ->
                                pure
                                  ( StageRewrite
                                      Aeson.Null
                                      (ExpandNode (NodeId "alpha") ExpandReplaceNode (mkSharedRewrite templateA ("a" :: Text)))
                                  )
                            )
                        )
                      ,
                        ( NodeId "beta"
                        , mkDynStage "beta" $ \_ -> do
                            atomically $ writeTVar shutdownFlag True
                            pure
                              ( StageRewrite
                                  Aeson.Null
                                  (ExpandNode (NodeId "beta") ExpandReplaceNode (mkSharedRewrite templateB ("b" :: Text)))
                              )
                        )
                      , sharedTemplateA
                      , sharedTemplateB
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome1 <- executeStagePlan taskContext runId task stagePlan
      outcome1 `shouldBe` OutcomeShutdown
      atomically $ writeTVar shutdownFlag False
      outcome2 <- resumeStagePlan taskContext runId task stagePlan
      outcome2 `shouldBe` OutcomeCompleted
      outputs <- readGraphNodeOutputs pool runId
      case outputs of
        Nothing -> expectationFailure "Expected graph outputs after template-id resume"
        Just (m, _appliedRewriteId) -> do
          Map.lookup (NodeId "alpha:shared") m
            `shouldBe` Just (Aeson.object ["template" Aeson..= ("a" :: Text), "state" Aeson..= Aeson.String "seed"])
          Map.lookup (NodeId "beta:shared") m
            `shouldBe` Just
              ( Aeson.object
                  [ "template" Aeson..= ("b" :: Text)
                  , "state"
                      Aeson..= Aeson.object
                        [ "template" Aeson..= ("a" :: Text)
                        , "state" Aeson..= Aeson.String "seed"
                        ]
                  ]
              )
      stageLogs <- readStageLogs pool runId
      let stageNames = fmap (.psldStageName) stageLogs
      stageNames `shouldContain` ["alpha:shared"]
      stageNames `shouldContain` ["beta:shared"]

  describe "budget convergence" $ do
    let mkDynStage stageId action =
          StageDefinition
            { sdStageId = DynStageId stageId
            , sdTemplateId = stageTemplateId (DynStageId stageId)
            , sdActionId = stageActionId (DynStageId stageId)
            , sdReplaySafety = SafeToReplay
            , sdReplayPolicyOverride = Nothing
            , sdTimeoutSeconds = Nothing
            , sdRetryPolicy = Nothing
            , sdAction = action
            , sdMemoryStrategy = defaultMemoryStrategy
            }
        mkDynLinearStage stageId action =
          mkDynStage stageId (liftChainAction action)

    it "budgetFraction reports correct ratios" $ \_ -> do
      let budget = RewriteBudget 10 20 5 3 8
          remaining = RewriteBudget 5 10 0 3 2
          ctx = BudgetContext {bcInitialBudget = budget, bcRemainingBudget = remaining}
      budgetFraction ctx DimAddedNodes `shouldBe` 0.5
      budgetFraction ctx DimAddedEdges `shouldBe` 0.5
      budgetFraction ctx DimAddedDepth `shouldBe` 0.0
      budgetFraction ctx DimFrontierDelta `shouldBe` 1.0
      budgetFraction ctx DimRewriteOps `shouldBe` 0.25

    it "budgetFraction returns 0.0 when initial budget is 0 for a dimension" $ \_ -> do
      let budget = RewriteBudget 0 0 0 0 0
          ctx = BudgetContext {bcInitialBudget = budget, bcRemainingBudget = budget}
      budgetFraction ctx DimAddedNodes `shouldBe` 0.0
      budgetFraction ctx DimRewriteOps `shouldBe` 0.0

    it "node receives rejection context and returns StageComplete — run completes" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-budget-convergence-degrade"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      -- Rewrite spec that would add 5 nodes, exceeding the budget of 1
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (path [NodeId "s1", NodeId "s2", NodeId "s3", NodeId "s4", NodeId "s5"])
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId "s1", mkDynLinearStage "s1" (\_ s -> pure s))
                    , (NodeId "s2", mkDynLinearStage "s2" (\_ s -> pure s))
                    , (NodeId "s3", mkDynLinearStage "s3" (\_ s -> pure s))
                    , (NodeId "s4", mkDynLinearStage "s4" (\_ s -> pure s))
                    , (NodeId "s5", mkDynLinearStage "s5" (\_ s -> pure s))
                    ]
              , sgsEntryNodes = [NodeId "s1"]
              , sgsExitNodes = [NodeId "s5"]
              }
          -- Budget allows only 1 added node — rewrite will be rejected
          tinyBudget = RewriteBudget 1 100 100 100 100
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = 3
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = tinyBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionDegrade
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \ctx ->
                          case ctx.scRewriteRejection of
                            Just _ ->
                              -- After rejection, produce degraded output
                              pure (StageComplete (Aeson.String "degraded"))
                            Nothing ->
                              -- First execution: attempt a rewrite that exceeds budget
                              pure (StageRewrite (Aeson.String "alpha-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \ctx ->
                            case ctx.scRewriteRejection of
                              Just _ ->
                                pure (StageComplete (Aeson.String "degraded"))
                              Nothing ->
                                pure (StageRewrite (Aeson.String "alpha-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted

    it
      "uses fresh live gas on stage execution and admits a smaller second rewrite without stale-budget rejection"
      $ \mPool -> withDb mPool $ \pool -> do
        (_shutdownFlag, taskContext) <- mkTaskContext pool
        taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-budget-refresh-on-rewrite-retry"
        runId <- createTestRun pool taskId
        task <- loadTaskDef pool taskId
        let mkAppendSubgraph localNodeNames =
              let localNodeIds = fmap NodeId localNodeNames
               in SubgraphSpec
                    { sgsTopology = toRelation (path localNodeIds)
                    , sgsDefinitions =
                        Map.fromList
                          [ ( localNodeId
                            , nodeStage localNodeId $ \ctx ->
                                pure
                                  ( StageComplete
                                      ( Aeson.object
                                          [ "nodeId" Aeson..= unNodeId ctx.scNodeId
                                          , "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                                          ]
                                      )
                                  )
                            )
                          | localNodeId <- localNodeIds
                          ]
                    , sgsEntryNodes = take 1 localNodeIds
                    , sgsExitNodes = take 1 (reverse localNodeIds)
                    }
            largeSubgraph = mkAppendSubgraph ["l1", "l2", "l3", "l4"]
            smallSubgraph = mkAppendSubgraph ["s1", "s2"]
            leftId = NodeId "left"
            rightId = NodeId "right"
            reviewerId = NodeId "reviewer"
            chooseRewrite ctx =
              let remainingNodes = ctx.scBudgetContext.bcRemainingBudget.rbAddedNodesMax
               in if remainingNodes >= 4
                    then pure (StageRewrite (Aeson.String "large") (AppendAfter ctx.scNodeId largeSubgraph))
                    else
                      if remainingNodes >= 2
                        then pure (StageRewrite (Aeson.String "small") (AppendAfter ctx.scNodeId smallSubgraph))
                        else pure (StageComplete (Aeson.object ["remaining_nodes" Aeson..= remainingNodes]))
            definitions =
              Map.fromList
                [ (leftId, nodeStage leftId chooseRewrite)
                , (rightId, nodeStage rightId chooseRewrite)
                ,
                  ( reviewerId
                  , nodeStage reviewerId $ \ctx ->
                      pure
                        ( StageComplete
                            ( Aeson.object
                                [ "inputNodeIds" Aeson..= fmap unNodeId (Map.keys ctx.scInputs)
                                ]
                            )
                        )
                  )
                ]
            rewriteBudget =
              RewriteBudget
                { rbAddedNodesMax = 6
                , rbAddedEdgesMax = 32
                , rbAddedDepthMax = 8
                , rbFrontierDeltaMax = 8
                , rbRewriteOpsMax = 4
                }
            stagePlan =
              StagePlan
                { spInitialState = Aeson.String "seed"
                , spCheckpointRuntimeVersion = 3
                , spReplayPolicy = ReplayPolicyWarn
                , spInitialRewriteBudget = rewriteBudget
                , spRewriteExhaustionPolicy = RewriteExhaustionFail
                , spBudgetExceededExhaustionPolicy = Nothing
                , spMaxRewriteReExecutions = 1
                , spTopology = toRelation (edge leftId reviewerId <> edge rightId reviewerId)
                , spDefinitions = definitions
                , spTemplateRegistry = mkTemplateRegistry definitions
                , spLoopRegistrations = Map.empty
                }
            decodeBudget label = \case
              Just value ->
                case Aeson.fromJSON value of
                  Aeson.Success budget -> pure budget
                  Aeson.Error err -> expectationFailure (label <> ": " <> err) >> pure rewriteBudget
              Nothing ->
                expectationFailure (label <> ": missing budget payload") >> pure rewriteBudget
        outcome <- executeStagePlan taskContext runId task stagePlan
        outcome `shouldBe` OutcomeCompleted
        rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
        let admittedRows = filter ((== "admitted") . (.pgravStatus)) rewriteRows
            rejectedRows = filter ((== "rejected") . (.pgravStatus)) rewriteRows
        length rejectedRows `shouldBe` 0
        case admittedRows of
          [firstRow, secondRow] -> do
            firstBudgetAfter <- decodeBudget "first admitted rewrite budget_after" firstRow.pgravBudgetAfter
            secondBudgetBefore <-
              decodeBudget "second admitted rewrite budget_before" secondRow.pgravBudgetBefore
            secondBudgetAfter <- decodeBudget "second admitted rewrite budget_after" secondRow.pgravBudgetAfter
            firstBudgetAfter `shouldBe` secondBudgetBefore
            firstBudgetAfter.rbAddedNodesMax `shouldBe` 2
            secondBudgetAfter.rbAddedNodesMax `shouldBe` 0
          rows ->
            expectationFailure ("Expected exactly two admitted rewrites, got " <> show (length rows))

    it "uses the budget-specific exhaustion override to degrade without failing the run" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-budget-specific-exhaustion-override"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (path [NodeId "s1", NodeId "s2", NodeId "s3", NodeId "s4", NodeId "s5"])
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId "s1", mkDynLinearStage "s1" (\_ s -> pure s))
                    , (NodeId "s2", mkDynLinearStage "s2" (\_ s -> pure s))
                    , (NodeId "s3", mkDynLinearStage "s3" (\_ s -> pure s))
                    , (NodeId "s4", mkDynLinearStage "s4" (\_ s -> pure s))
                    , (NodeId "s5", mkDynLinearStage "s5" (\_ s -> pure s))
                    ]
              , sgsEntryNodes = [NodeId "s1"]
              , sgsExitNodes = [NodeId "s5"]
              }
          tinyBudget = RewriteBudget 1 100 100 100 100
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = 3
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = tinyBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Just RewriteExhaustionDegrade
              , spMaxRewriteReExecutions = 1
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ -> do
                          atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                          pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ -> do
                            atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                            pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      attempts <- readIORef attemptsRef
      attempts `shouldBe` 2
      maybeOutputs <- readGraphNodeOutputs pool runId
      case maybeOutputs of
        Nothing ->
          expectationFailure "Expected graph outputs after budget-specific degrade override"
        Just (outputs, _appliedRewriteId) ->
          Map.lookup (NodeId "alpha") outputs `shouldBe` Just (Aeson.String "stubborn-output")

    it "retries the same node after a rejected rewrite proposal and persists the rejected proposal" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-proposal-rejection-retry"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let rejectedSpec =
            Aeson.object
              [ "format" Aeson..= ("cortex.workflow.wire.proposal/v1" :: Text)
              , "source"
                  Aeson..= ( "node bad\n  <- src: AnalysisFragment ;\n  -> out: AnalysisFragment = @stress_dimension (src) ;"
                               :: Text
                           )
              ]
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = 3
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionDegrade
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \ctx -> do
                          attemptNumber <- atomicModifyIORef' attemptsRef (\n -> let next = n + 1 in (next, next))
                          case ctx.scRewriteRejection of
                            Nothing ->
                              pure
                                ( StageRejectRewrite
                                    (Aeson.String "alpha-output")
                                    StageRejectedRewrite
                                      { srrRejectionType = "wire_compile_rejected"
                                      , srrMessage = "proposal missing final graph expression"
                                      , srrRejectedSpec = Just rejectedSpec
                                      }
                                )
                            Just rejectionCtx ->
                              pure
                                ( StageComplete
                                    ( Aeson.object
                                        [ "attempt" Aeson..= attemptNumber
                                        , "rejection_type" Aeson..= rejectionCtx.rrcRejectionType
                                        , "rejection_message" Aeson..= rejectionCtx.rrcMessage
                                        ]
                                    )
                                )
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \ctx -> do
                            case ctx.scRewriteRejection of
                              Nothing ->
                                pure
                                  ( StageRejectRewrite
                                      (Aeson.String "alpha-output")
                                      StageRejectedRewrite
                                        { srrRejectionType = "wire_compile_rejected"
                                        , srrMessage = "proposal missing final graph expression"
                                        , srrRejectedSpec = Just rejectedSpec
                                        }
                                  )
                              Just rejectionCtx ->
                                pure
                                  ( StageComplete
                                      ( Aeson.object
                                          [ "rejection_type" Aeson..= rejectionCtx.rrcRejectionType
                                          , "rejection_message" Aeson..= rejectionCtx.rrcMessage
                                          ]
                                      )
                                  )
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      attempts <- readIORef attemptsRef
      attempts `shouldBe` 2
      rewriteRows <- runSession pool $ Q.readGraphRewritesForAdmin runId
      length rewriteRows `shouldBe` 1
      case rewriteRows of
        [row] -> do
          row.pgravStatus `shouldBe` "rejected"
          row.pgravRejectionReason `shouldBe` Just "proposal missing final graph expression"
          row.pgravRewriteSpec `shouldBe` rejectedSpec
        _ ->
          expectationFailure ("Expected exactly one rejected rewrite row, got " <> show (length rewriteRows))

    it "exhaustion policy Fail — run fails after max re-executions" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-budget-exhaustion-fail"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (path [NodeId "s1", NodeId "s2", NodeId "s3", NodeId "s4", NodeId "s5"])
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId "s1", mkDynLinearStage "s1" (\_ s -> pure s))
                    , (NodeId "s2", mkDynLinearStage "s2" (\_ s -> pure s))
                    , (NodeId "s3", mkDynLinearStage "s3" (\_ s -> pure s))
                    , (NodeId "s4", mkDynLinearStage "s4" (\_ s -> pure s))
                    , (NodeId "s5", mkDynLinearStage "s5" (\_ s -> pure s))
                    ]
              , sgsEntryNodes = [NodeId "s1"]
              , sgsExitNodes = [NodeId "s5"]
              }
          tinyBudget = RewriteBudget 1 100 100 100 100
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = 3
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = tinyBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ -> do
                          atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                          -- Always attempt rewrite, ignoring rejection context
                          pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ -> do
                            atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                            pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeFailed
      -- 1 initial + 2 re-executions = 3 total
      totalAttempts <- readIORef attemptsRef
      totalAttempts `shouldBe` 3

    it "exhaustion policy Degrade — run completes with last output after max re-executions" $ \mPool -> withDb mPool $ \pool -> do
      (_shutdownFlag, taskContext) <- mkTaskContext pool
      taskId <- insertTestTaskDef pool "paper_portfolio_cycle" "test-budget-exhaustion-degrade"
      runId <- createTestRun pool taskId
      task <- loadTaskDef pool taskId
      attemptsRef <- newIORef (0 :: Int)
      let rewriteSpec =
            SubgraphSpec
              { sgsTopology = toRelation (path [NodeId "s1", NodeId "s2", NodeId "s3", NodeId "s4", NodeId "s5"])
              , sgsDefinitions =
                  Map.fromList
                    [ (NodeId "s1", mkDynLinearStage "s1" (\_ s -> pure s))
                    , (NodeId "s2", mkDynLinearStage "s2" (\_ s -> pure s))
                    , (NodeId "s3", mkDynLinearStage "s3" (\_ s -> pure s))
                    , (NodeId "s4", mkDynLinearStage "s4" (\_ s -> pure s))
                    , (NodeId "s5", mkDynLinearStage "s5" (\_ s -> pure s))
                    ]
              , sgsEntryNodes = [NodeId "s1"]
              , sgsExitNodes = [NodeId "s5"]
              }
          tinyBudget = RewriteBudget 1 100 100 100 100
          stagePlan =
            StagePlan
              { spInitialState = Aeson.String "seed"
              , spCheckpointRuntimeVersion = 3
              , spReplayPolicy = ReplayPolicyWarn
              , spInitialRewriteBudget = tinyBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionDegrade
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = toRelation (Vertex (NodeId "alpha"))
              , spDefinitions =
                  Map.fromList
                    [
                      ( NodeId "alpha"
                      , mkDynStage "alpha" $ \_ -> do
                          atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                          -- Always attempt rewrite, ignoring rejection context
                          pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                      )
                    ]
              , spTemplateRegistry =
                  mkTemplateRegistry $
                    Map.fromList
                      [
                        ( NodeId "alpha"
                        , mkDynStage "alpha" $ \_ -> do
                            atomicModifyIORef' attemptsRef (\n -> (n + 1, ()))
                            pure (StageRewrite (Aeson.String "stubborn-output") (AppendAfter (NodeId "alpha") rewriteSpec))
                        )
                      ]
              , spLoopRegistrations = Map.empty
              }
      outcome <- executeStagePlan taskContext runId task stagePlan
      outcome `shouldBe` OutcomeCompleted
      -- 1 initial + 2 re-executions = 3 total
      totalAttempts <- readIORef attemptsRef
      totalAttempts `shouldBe` 3
