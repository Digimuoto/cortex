{- |
Module      : Cortex.Pulse.Plan
Description : Pulse runtime support for plan.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Plan
  ( StageAction
  , StageContext (..)
  , StageRejectedRewrite (..)
  , StageResult (..)
  , StableStageId (..)
  , StageActionId (..)
  , stageActionId
  , StageTemplateId (..)
  , stageTemplateId
  , buildStageTemplateRegistry
  , mergeStageTemplateRegistries
  , StageLatentNode (..)
  , StageLatentDeltaSignature (..)
  , StageLatentBranch (..)
  , StageLatentCondition (..)
  , LoopInstanceKey (..)
  , StagePlan (..)
  , initialLoopControls
  , loopRegistrationForStage
  , SomeStagePlan (..)
  , StageDefinition (..)
  , taskStage
  , StageReplaySafety (..)
  , ReplayPolicy (..)
  , RewriteExhaustionPolicy (..)
  , StageRetryPolicy (..)
  , StageRetryBackoff (..)
  , StageRetryExhaustion (..)
  , StageFailure (..)
  , StageRetryFailureContext (..)
  , mkLinearStagePlan
  , liftChainAction
  )
where

import Control.Exception (SomeException)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Cortex.Algebra.Graph
  ( Relation (..)
  , ValidationError (..)
  , path
  , toRelation
  , validateDAG
  )
import Cortex.Pulse.Iteration
  ( LoopControl
  , LoopPolicy (..)
  , LoopRegistration (..)
  , LoopStepWitness
  , initLoopControl
  , loopProducerMatchesPolicy
  )
import Cortex.Pulse.Memory.Types (MemoryHandle, MemoryStrategy, defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( BoundaryResourceUse
  , BudgetContext
  , GraphRewrite (..)
  , RewriteAnchorDisposition
  , RewriteBudget
  , RewriteRejectionContext
  )
import Cortex.Pulse.Signal (SignalName)

data StageRejectedRewrite = StageRejectedRewrite
  { srrRejectionType :: !Text
  , srrMessage :: !Text
  , srrRejectedSpec :: !(Maybe Aeson.Value)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON)

data StageResult stageId
  = StageComplete Aeson.Value
  | StageSuspend SignalName
  | StageRewrite Aeson.Value (GraphRewrite NodeId (StageDefinition stageId))
  | StageRejectRewrite Aeson.Value StageRejectedRewrite
  | {- | A runtime-bounded-iteration self-append step (ADR 0055). Carries the
    stage output, the live frontier witness to certify, and the @AppendAfter@ of
    the next, already-flat-namespaced kernel instance. Distinct from
    'StageRewrite' so the executor admits it gas-neutral (witnessed, ADR 0056)
    rather than against rewrite gas.
    -}
    StageLoopStep Aeson.Value LoopStepWitness (GraphRewrite NodeId (StageDefinition stageId))
  | {- | An expected, typed terminal failure returned as a value (not thrown): the
    error-type tag (first field, e.g. @external_call_failure@) and a human
    message (second). Used for backend failures that should route through the
    ADR 0026 failure closure with a typed reason rather than collapsing to a
    generic @stage_failure@ exception.
    -}
    StageFail !Text !Text

-- | Execution context provided to every stage action.
data StageContext = StageContext
  { scRunId :: !UUID
  , scNodeId :: !NodeId
  , scInputs :: !(Map NodeId Aeson.Value)
  , scAttempt :: !Int
  , scBudgetContext :: !BudgetContext
  , scRewriteRejection :: !(Maybe RewriteRejectionContext)
  , scRetryFailure :: !(Maybe StageRetryFailureContext)
  , scMemory :: !MemoryHandle
  {- ^ Graph-native topological memory.  A stage queries the
   substrate via this handle rather than reading a dedicated claim
   store.  Constructed once per run by the executor from the run's
   'PersistedGraphState' / node-completion / topology TVars.
  -}
  , scMemoryStrategy :: !MemoryStrategy
  {- ^ Per-stage memory read surface selector.  Copied from
   the bound 'StageDefinition.sdMemoryStrategy' so that stage
   actions can dispatch on the declared surface (classic vs.
   topological, future retrieval/hybrid) without re-reading the
   plan.
  -}
  }

type StageAction stageId = StageContext -> IO (StageResult stageId)

liftChainAction :: (UUID -> Aeson.Value -> IO Aeson.Value) -> StageAction stageId
liftChainAction f ctx =
  let singleInput = case Map.elems ctx.scInputs of
        [v] -> v
        [] -> Aeson.Null
        _ -> Aeson.toJSON ctx.scInputs
   in StageComplete <$> f ctx.scRunId singleInput

{- | Smart constructor for a task-node stage: a runnable 'StageDefinition' with
safe-to-replay defaults (no timeout, retry, or replay override) and the classic
memory strategy. The library form of the per-node stage a caller would otherwise
hand-build, used to bind compiled-circuit task nodes (GitHub #330).
-}
taskStage :: NodeId -> (StageContext -> IO (StageResult NodeId)) -> StageDefinition NodeId
taskStage nodeId action =
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

class (Eq stageId, Show stageId, Aeson.FromJSON stageId, Aeson.ToJSON stageId) => StableStageId stageId where
  stageIdToText :: stageId -> Text

instance StableStageId NodeId where
  stageIdToText = unNodeId

newtype StageTemplateId = StageTemplateId {unStageTemplateId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Aeson.FromJSON, Aeson.ToJSON)

stageTemplateId :: StableStageId stageId => stageId -> StageTemplateId
stageTemplateId = StageTemplateId . stageIdToText

newtype StageActionId = StageActionId {unStageActionId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Aeson.FromJSON, Aeson.ToJSON)

stageActionId :: StableStageId stageId => stageId -> StageActionId
stageActionId = StageActionId . stageIdToText

data StageReplaySafety
  = SafeToReplay
  | Irreversible
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data ReplayPolicy
  = ReplayPolicyWarn
  | ReplayPolicyBlockResume
  | ReplayPolicyRequireOperatorOverride
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageRetryBackoff
  = FixedBackoffMicros Int
  | ExponentialBackoffMicros Int
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageRetryExhaustion
  = ExhaustionFailsRun
  | ExhaustionSkipsStage
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageFailure
  = StageFailureException SomeException
  | StageFailureTimeout Int32
  | {- | A typed terminal failure (error-type tag, message) surfaced from a
    'StageFail' result, so the run's @error_type@ carries the typed reason
    instead of a generic @stage_failure@.
    -}
    StageFailureTyped !Text !Text

instance Show StageFailure where
  show = T.unpack . stageFailureMessage

data StageRetryFailureContext = StageRetryFailureContext
  { srfcPreviousAttempt :: !Int
  , srfcFailureType :: !Text
  , srfcFailureMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageRetryPolicy = StageRetryPolicy
  { srpPredicateName :: Text
  , srpMaxAttempts :: Int
  , srpBackoff :: StageRetryBackoff
  , srpRetryable :: StageFailure -> Bool
  , srpExhaustion :: StageRetryExhaustion
  }
  deriving stock (Generic)

instance Eq StageRetryPolicy where
  a == b =
    a.srpPredicateName == b.srpPredicateName
      && a.srpMaxAttempts == b.srpMaxAttempts
      && a.srpBackoff == b.srpBackoff
      && a.srpExhaustion == b.srpExhaustion

instance Show StageRetryPolicy where
  show p =
    "StageRetryPolicy { srpPredicateName = "
      <> show p.srpPredicateName
      <> ", srpMaxAttempts = "
      <> show p.srpMaxAttempts
      <> ", srpBackoff = "
      <> show p.srpBackoff
      <> ", srpExhaustion = "
      <> show p.srpExhaustion
      <> " }"

instance Aeson.FromJSON StageRetryPolicy where
  parseJSON = Aeson.withObject "StageRetryPolicy" $ \v ->
    StageRetryPolicy
      <$> v Aeson..:? "predicate_name" Aeson..!= "default"
      <*> v Aeson..: "max_attempts"
      <*> v Aeson..: "backoff"
      <*> pure (const True)
      <*> v Aeson..: "exhaustion"

instance Aeson.ToJSON StageRetryPolicy where
  toJSON p =
    Aeson.object
      [ "predicate_name" Aeson..= p.srpPredicateName
      , "max_attempts" Aeson..= p.srpMaxAttempts
      , "backoff" Aeson..= p.srpBackoff
      , "exhaustion" Aeson..= p.srpExhaustion
      ]

data StageDefinition stageId = StageDefinition
  { sdStageId :: stageId
  , sdTemplateId :: StageTemplateId
  , sdActionId :: StageActionId
  , sdReplaySafety :: StageReplaySafety
  , sdReplayPolicyOverride :: Maybe ReplayPolicy
  , sdTimeoutSeconds :: Maybe Int32
  , sdRetryPolicy :: Maybe StageRetryPolicy
  , sdAction :: StageAction stageId
  , sdMemoryStrategy :: MemoryStrategy
  {- ^ Memory read surface the stage expects.  Defaults to
   'MemoryClassic' (scInputs only) so pre-existing plans stay on
   the historical chain-scoped path until a wire opts in.
  -}
  }

data StageLatentNode = StageLatentNode
  { slnTemplateId :: StageTemplateId
  , slnActionId :: StageActionId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageLatentDeltaSignature = StageLatentDeltaSignature
  { sldsAnchorNodeId :: NodeId
  , sldsAnchorDisposition :: RewriteAnchorDisposition
  , sldsBoundaryResourceUse :: BoundaryResourceUse
  , sldsNewNodes :: Set NodeId
  , sldsAddedEdges :: Set (NodeId, NodeId)
  , sldsEntryNodes :: [NodeId]
  , sldsExitNodes :: [NodeId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageLatentBranch = StageLatentBranch
  { slbBranchId :: Text
  , slbAnchorNodeId :: NodeId
  , slbNodes :: Map NodeId StageLatentNode
  , slbTopology :: Relation NodeId
  , slbEntryNodes :: [NodeId]
  , slbExitNodes :: [NodeId]
  , slbPostSuccessorNodes :: [NodeId]
  , slbDeltaSignature :: StageLatentDeltaSignature
  , slbNestedConditions :: [StageLatentCondition]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StageLatentCondition = StageLatentCondition
  { slcAnchorNodeId :: NodeId
  , slcBranches :: [StageLatentBranch]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

{- | A runtime-bounded loop instance is identified by the finite kernel template
and the flat namespace root that owns its materialized iterations. Multiple loop
nodes may reuse the same kernel template as long as they have distinct roots.
-}
data LoopInstanceKey = LoopInstanceKey
  { likTemplateId :: !StageTemplateId
  , likNamespaceRoot :: !NodeId
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

-- | What to do when a node exhausts its re-execution attempts after budget rejection.
data RewriteExhaustionPolicy
  = -- | Hard fail after max re-executions (default, backward compat)
    RewriteExhaustionFail
  | -- | Accept last output, continue without rewrite
    RewriteExhaustionDegrade
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data StagePlan stageId = StagePlan
  { spInitialState :: Aeson.Value
  , spCheckpointRuntimeVersion :: Int
  , spReplayPolicy :: ReplayPolicy
  , spInitialRewriteBudget :: RewriteBudget
  , spRewriteExhaustionPolicy :: RewriteExhaustionPolicy
  , spBudgetExceededExhaustionPolicy :: Maybe RewriteExhaustionPolicy
  , spMaxRewriteReExecutions :: !Int
  , spTopology :: Relation NodeId
  , spDefinitions :: Map NodeId (StageDefinition stageId)
  , spTemplateRegistry :: Map StageTemplateId (StageDefinition stageId)
  , spLoopRegistrations :: Map LoopInstanceKey LoopRegistration
  {- ^ Loop kernels authorized for witnessed (gas-neutral) self-append in this
  run (ADR 0055), keyed by the kernel's 'StageTemplateId' plus namespace root.
  Each registration carries both the static policy and the admitted effective
  bound. A 'StageLoopStep' whose producer template/namespace pair is not
  registered here is admitted on the ordinary gassed path instead (fail-closed).
  Empty authorizes no loops.
  -}
  }

initialLoopControls :: StagePlan stageId -> Map LoopInstanceKey LoopControl
initialLoopControls stagePlan =
  fmap
    (\registration -> initLoopControl registration.lrPolicy registration.lrEffectiveBound)
    stagePlan.spLoopRegistrations

loopRegistrationForStage
  :: StagePlan stageId
  -> StageTemplateId
  -> NodeId
  -> Maybe (LoopInstanceKey, LoopRegistration)
loopRegistrationForStage stagePlan templateId producer =
  List.find matches (Map.toList stagePlan.spLoopRegistrations)
  where
    matches (key, registration) =
      key.likTemplateId == templateId
        && key.likNamespaceRoot == registration.lrPolicy.lpNamespaceRoot
        && loopProducerMatchesPolicy registration.lrPolicy producer

data SomeStagePlan where
  SomeStagePlan
    :: StableStageId stageId => StagePlan stageId -> [StageLatentCondition] -> SomeStagePlan

mkLinearStagePlan
  :: StableStageId stageId
  => [StageDefinition stageId]
  -> Aeson.Value
  -> Int
  -> ReplayPolicy
  -> RewriteBudget
  -> Either Text (StagePlan stageId)
mkLinearStagePlan stages initialState runtimeVersion replayPolicy rewriteBudget =
  let nodeIds = fmap (NodeId . stageIdToText . (.sdStageId)) stages
      topology = toRelation (path nodeIds)
      definitions =
        Map.fromList
          [ (NodeId (stageIdToText stage.sdStageId), stage)
          | stage <- stages
          ]
   in case validateDAG topology of
        Left (GraphHasCycle cycle') ->
          Left $
            "mkLinearStagePlan: cycle detected in stage plan (duplicate stage IDs?): "
              <> T.pack (show (fmap unNodeId cycle'))
        Right () ->
          case buildStageTemplateRegistry definitions of
            Left err ->
              Left ("mkLinearStagePlan: " <> err)
            Right templateRegistry ->
              Right $
                StagePlan
                  { spInitialState = initialState
                  , spCheckpointRuntimeVersion = runtimeVersion
                  , spReplayPolicy = replayPolicy
                  , spInitialRewriteBudget = rewriteBudget
                  , spRewriteExhaustionPolicy = RewriteExhaustionFail
                  , spBudgetExceededExhaustionPolicy = Nothing
                  , spMaxRewriteReExecutions = 2
                  , spTopology = topology
                  , spDefinitions = definitions
                  , spTemplateRegistry = templateRegistry
                  , spLoopRegistrations = Map.empty
                  }

buildStageTemplateRegistry
  :: Eq stageId
  => Map NodeId (StageDefinition stageId)
  -> Either Text (Map StageTemplateId (StageDefinition stageId))
buildStageTemplateRegistry =
  foldl'
    ( \acc (nodeId, stageDef) ->
        acc >>= \registry ->
          insertTemplate registry (Just nodeId) stageDef
    )
    (Right Map.empty)
    . Map.toList

mergeStageTemplateRegistries
  :: Eq stageId
  => Map StageTemplateId (StageDefinition stageId)
  -> Map StageTemplateId (StageDefinition stageId)
  -> Either Text (Map StageTemplateId (StageDefinition stageId))
mergeStageTemplateRegistries baseRegistry =
  foldl'
    ( \acc stageDef ->
        acc >>= \registry ->
          insertTemplate registry Nothing stageDef
    )
    (Right baseRegistry)
    . Map.elems

insertTemplate
  :: Eq stageId
  => Map StageTemplateId (StageDefinition stageId)
  -> Maybe NodeId
  -> StageDefinition stageId
  -> Either Text (Map StageTemplateId (StageDefinition stageId))
insertTemplate templateRegistry maybeNodeId stageDef =
  case Map.lookup stageDef.sdTemplateId templateRegistry of
    Just existingDef
      | stageTemplateFingerprint existingDef == stageTemplateFingerprint stageDef ->
          Right templateRegistry
      | otherwise ->
          Left $
            case maybeNodeId of
              Just nodeId ->
                "Duplicate stage template definition found for rewritten template "
                  <> unStageTemplateId stageDef.sdTemplateId
                  <> " (node: "
                  <> unNodeId nodeId
                  <> ")"
              Nothing ->
                "Duplicate stage template definition found for rewritten template "
                  <> unStageTemplateId stageDef.sdTemplateId
    Nothing ->
      Right (Map.insert stageDef.sdTemplateId stageDef templateRegistry)

stageTemplateFingerprint
  :: StageDefinition stageId
  -> (stageId, StageActionId, StageReplaySafety, Maybe ReplayPolicy, Maybe Int32, Maybe StageRetryPolicy)
stageTemplateFingerprint stageDef =
  ( stageDef.sdStageId
  , stageDef.sdActionId
  , stageDef.sdReplaySafety
  , stageDef.sdReplayPolicyOverride
  , stageDef.sdTimeoutSeconds
  , stageDef.sdRetryPolicy
  )

stageFailureMessage :: StageFailure -> Text
stageFailureMessage = \case
  StageFailureException exc -> T.pack (show exc)
  StageFailureTimeout seconds -> "Stage timed out after " <> T.pack (show seconds) <> "s"
  StageFailureTyped _ message -> message
