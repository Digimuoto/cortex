{- |
Module      : Cortex.Wire.Circuit.Lowering
Description : Wire support for lowering.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Circuit.Lowering
  ( CircuitPulseConfig (..)
  , CircuitConditionBranch (..)
  , CircuitConditionSelection (..)
  , CircuitConditionBinding (..)
  , CircuitPulseBinder (..)
  , CircuitLoweringError (..)
  , lowerCompiledCircuitToSomeStagePlan
  , lowerCompiledCircuitToStagePlan
  , lowerCircuitIRToSomeStagePlan
  , lowerCircuitIRToStagePlan
  , committedVariantConditionBinding
  , committedVariantBinder
  , committedVariantBinderWith
  , signalStage
  , artifactStage
  , committedVariantSelection
  , committedVariantSelectKeys
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Bifunctor (first)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)

import Cortex.Algebra.Graph
  ( Relation
  , ValidationError
  , mapRelation
  , relEdges
  , relVertices
  , successors
  , validateDAG
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( ReplayPolicy
  , RewriteExhaustionPolicy (..)
  , SomeStagePlan (..)
  , StageActionId
  , StageContext (..)
  , StageDefinition (..)
  , StageLatentBranch (..)
  , StageLatentCondition (..)
  , StageLatentDeltaSignature (..)
  , StageLatentNode (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , StageRetryPolicy
  , StageTemplateId
  , buildStageTemplateRegistry
  , stageActionId
  , stageTemplateId
  , taskStage
  )
import Cortex.Pulse.Rewrite
  ( GraphRewrite (AppendAfter)
  , RewriteAnchorDisposition (..)
  , RewriteBudget
  , SubgraphSpec (..)
  , rewriteBoundaryResourceUse
  )
import Cortex.Pulse.Signal (SignalName (..))
import Cortex.Wire.Circuit.Artifact
  ( CircuitConditionNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitFragment (..)
  , CompiledCircuitNode (..)
  , compiledCircuitNodeRef
  )
import Cortex.Wire.Circuit.Compile
  ( CircuitCompileError
  , compileCircuitIR
  )
import Cortex.Wire.Circuit.IR
  ( CircuitArtifactBoundary (..)
  , CircuitIR
  , CircuitNodeRef (..)
  , CircuitRewriteBoundary
  , CircuitSignalBoundary (..)
  , CircuitTaskNode
  )
import Cortex.Wire.Value (WireValue (..))

data CircuitConditionBranch
  = CircuitConditionThen
  | CircuitConditionElse
  deriving stock (Eq, Show)

data CircuitConditionSelection = CircuitConditionSelection
  { circuitConditionSelectionOutput :: Aeson.Value
  , circuitConditionSelectionBranch :: CircuitConditionBranch
  }
  deriving stock (Eq, Show)

{- | Bound execution policy for a lowered condition node.

The selector receives the durable run id and the completed outputs of the
condition node's predecessors, then chooses which latent branch to materialize
and what output payload to persist for the condition anchor itself.
-}
data CircuitConditionBinding = CircuitConditionBinding
  { circuitConditionReplaySafety :: StageReplaySafety
  , circuitConditionReplayPolicyOverride :: Maybe ReplayPolicy
  , circuitConditionTimeoutSeconds :: Maybe Int32
  , circuitConditionRetryPolicy :: Maybe StageRetryPolicy
  , circuitConditionTemplateId :: Maybe StageTemplateId
  , circuitConditionActionId :: Maybe StageActionId
  , circuitConditionSelectBranch :: UUID -> Map NodeId Aeson.Value -> IO CircuitConditionSelection
  }

data CircuitPulseConfig = CircuitPulseConfig
  { circuitPulseInitialState :: Aeson.Value
  , circuitPulseRuntimeVersion :: Int
  , circuitPulseReplayPolicy :: ReplayPolicy
  , circuitPulseInitialRewriteBudget :: RewriteBudget
  , circuitPulseRewriteExhaustionPolicy :: RewriteExhaustionPolicy
  , circuitPulseBudgetExceededExhaustionPolicy :: Maybe RewriteExhaustionPolicy
  , circuitPulseMaxRewriteReExecutions :: !Int
  }

data CircuitPulseBinder = CircuitPulseBinder
  { bindCircuitTaskNode :: CircuitTaskNode -> Either CircuitLoweringError (StageDefinition NodeId)
  , bindCircuitSignalBoundary
      :: CircuitSignalBoundary
      -> Either CircuitLoweringError (StageDefinition NodeId)
  , bindCircuitArtifactBoundary
      :: CircuitArtifactBoundary
      -> Either CircuitLoweringError (StageDefinition NodeId)
  , bindCircuitRewriteBoundary
      :: CircuitRewriteBoundary
      -> Either CircuitLoweringError (StageDefinition NodeId)
  , bindCircuitConditionNode
      :: CircuitConditionNode
      -> Either CircuitLoweringError CircuitConditionBinding
  }

data CircuitLoweringError
  = CircuitLoweringCompileError CircuitCompileError
  | CircuitStageRefMismatch CircuitNodeRef NodeId
  | CircuitLoweredGraphInvalid (ValidationError NodeId)
  | CircuitTemplateRegistryInvalid Text
  | -- | A @wire_select@ condition node's metadata is missing or malformed (ADR 0062).
    CircuitConditionMetadataInvalid !Text
  | {- | A boundary node (signal, artifact, or rewrite) was reached but the binder in
    use does not bind that boundary kind. Carries the boundary kind. Distinct from a
    malformed template registry: the circuit is well-formed, the binder is just
    narrower than the circuit requires.
    -}
    CircuitBoundaryUnsupported !Text
  deriving stock (Eq, Show)

lowerCircuitIRToStagePlan
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CircuitIR
  -> Either CircuitLoweringError (StagePlan NodeId)
lowerCircuitIRToStagePlan pulseConfig binder circuitIr =
  fmap fst (lowerCircuitIRInternal pulseConfig binder circuitIr)

lowerCircuitIRToSomeStagePlan
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CircuitIR
  -> Either CircuitLoweringError SomeStagePlan
lowerCircuitIRToSomeStagePlan pulseConfig binder circuitIr = do
  (stagePlan, latentConditions) <- lowerCircuitIRInternal pulseConfig binder circuitIr
  pure (SomeStagePlan stagePlan latentConditions)

lowerCompiledCircuitToStagePlan
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitLoweringError (StagePlan NodeId)
lowerCompiledCircuitToStagePlan pulseConfig binder compiledCircuit =
  fmap fst (lowerCompiledCircuitInternal pulseConfig binder compiledCircuit)

lowerCompiledCircuitToSomeStagePlan
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitLoweringError SomeStagePlan
lowerCompiledCircuitToSomeStagePlan pulseConfig binder compiledCircuit = do
  (stagePlan, latentConditions) <- lowerCompiledCircuitInternal pulseConfig binder compiledCircuit
  pure (SomeStagePlan stagePlan latentConditions)

lowerCircuitIRInternal
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CircuitIR
  -> Either CircuitLoweringError (StagePlan NodeId, [StageLatentCondition])
lowerCircuitIRInternal pulseConfig binder circuitIr = do
  compiled <-
    either
      (Left . CircuitLoweringCompileError)
      Right
      (compileCircuitIR circuitIr)
  lowerCompiledCircuitInternal pulseConfig binder compiled

lowerCompiledCircuitInternal
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitLoweringError (StagePlan NodeId, [StageLatentCondition])
lowerCompiledCircuitInternal pulseConfig binder compiledCircuit = do
  definitionsList <-
    traverse (lowerNode pulseConfig binder) (Map.elems compiledCircuit.compiledCircuitNodes)
  let actualDefinitions = Map.fromList [(stage.sdStageId, stage) | stage <- definitionsList]
  latentTemplateEntries <- collectLatentTemplateEntries pulseConfig binder compiledCircuit
  latentConditions <- collectLatentConditions pulseConfig binder compiledCircuit
  templateRegistry <-
    either
      (Left . CircuitTemplateRegistryInvalid)
      Right
      (buildStageTemplateRegistry (actualDefinitions <> Map.fromList latentTemplateEntries))
  let topology = mapRelation (NodeId . unCircuitNodeRef) compiledCircuit.compiledCircuitTopology
  case validateDAG topology of
    Left err -> Left (CircuitLoweredGraphInvalid err)
    Right () ->
      pure
        ( StagePlan
            { spInitialState = pulseConfig.circuitPulseInitialState
            , spCheckpointRuntimeVersion = pulseConfig.circuitPulseRuntimeVersion
            , spReplayPolicy = pulseConfig.circuitPulseReplayPolicy
            , spInitialRewriteBudget = pulseConfig.circuitPulseInitialRewriteBudget
            , spRewriteExhaustionPolicy = pulseConfig.circuitPulseRewriteExhaustionPolicy
            , spBudgetExceededExhaustionPolicy = pulseConfig.circuitPulseBudgetExceededExhaustionPolicy
            , spMaxRewriteReExecutions = pulseConfig.circuitPulseMaxRewriteReExecutions
            , spTopology = topology
            , spDefinitions = actualDefinitions
            , spTemplateRegistry = templateRegistry
            , spLoopRegistrations = Map.empty
            }
        , latentConditions
        )

lowerNode
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuitNode
  -> Either CircuitLoweringError (StageDefinition NodeId)
lowerNode pulseConfig binder compiledNode = do
  let expectedRef = compiledCircuitNodeRef compiledNode
      expectedNodeId = NodeId (unCircuitNodeRef expectedRef)
  stage <- case compiledNode of
    CompiledCircuitTask taskNode -> bindCircuitTaskNode binder taskNode
    CompiledCircuitSignal signalBoundary -> bindCircuitSignalBoundary binder signalBoundary
    CompiledCircuitArtifact artifactBoundary -> bindCircuitArtifactBoundary binder artifactBoundary
    CompiledCircuitRewriteBoundary rewriteBoundary -> bindCircuitRewriteBoundary binder rewriteBoundary
    CompiledCircuitCondition conditionNode ->
      lowerConditionNode pulseConfig binder conditionNode
  if stage.sdStageId == expectedNodeId
    then Right stage
    else Left (CircuitStageRefMismatch expectedRef stage.sdStageId)

lowerConditionNode
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CircuitConditionNode
  -> Either CircuitLoweringError (StageDefinition NodeId)
lowerConditionNode pulseConfig binder conditionNode = do
  conditionBinding <- bindCircuitConditionNode binder conditionNode
  -- Lower latent fragments eagerly so the full compiled artifact is validated
  -- up front. Branch selection remains runtime-latent even though both
  -- candidate fragments are already bound here.
  thenFragment <- lowerFragment pulseConfig binder conditionNode.circuitConditionNodeThenFragment
  elseFragment <-
    traverse (lowerFragment pulseConfig binder) conditionNode.circuitConditionNodeElseFragment
  let stageId = NodeId (unCircuitNodeRef conditionNode.circuitConditionNodeRef)
      selectBranch = circuitConditionSelectBranch conditionBinding
      action ctx = do
        selection <- selectBranch ctx.scRunId ctx.scInputs
        -- Anchor the branch-materializing rewrite on the condition's runtime node
        -- id, not its lower-time id. A nested select condition is materialized
        -- under its parent's namespace ({parent}:{local}), so the lower-time id is
        -- not a live topology node; only ctx.scNodeId reflects the actual anchor
        -- (ADR 0062, GitHub #321).
        let anchorNodeId = ctx.scNodeId
        pure $
          case selection.circuitConditionSelectionBranch of
            CircuitConditionThen ->
              StageRewrite selection.circuitConditionSelectionOutput (AppendAfter anchorNodeId thenFragment)
            CircuitConditionElse ->
              maybe
                (StageComplete selection.circuitConditionSelectionOutput)
                (StageRewrite selection.circuitConditionSelectionOutput . AppendAfter anchorNodeId)
                elseFragment
  pure
    StageDefinition
      { sdStageId = stageId
      , sdTemplateId = fromMaybe (stageTemplateId stageId) conditionBinding.circuitConditionTemplateId
      , sdActionId = fromMaybe (stageActionId stageId) conditionBinding.circuitConditionActionId
      , sdReplaySafety = conditionBinding.circuitConditionReplaySafety
      , sdReplayPolicyOverride = conditionBinding.circuitConditionReplayPolicyOverride
      , sdTimeoutSeconds = conditionBinding.circuitConditionTimeoutSeconds
      , sdRetryPolicy = conditionBinding.circuitConditionRetryPolicy
      , sdAction = action
      , sdMemoryStrategy = defaultMemoryStrategy
      }

lowerFragment
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuitFragment
  -> Either CircuitLoweringError (SubgraphSpec NodeId (StageDefinition NodeId))
lowerFragment pulseConfig binder fragment = do
  let topology = mapRelation (NodeId . unCircuitNodeRef) fragment.compiledCircuitFragmentTopology
  case validateDAG topology of
    Left err -> Left (CircuitLoweredGraphInvalid err)
    Right () -> do
      definitionsList <-
        traverse (lowerNode pulseConfig binder) (Map.elems fragment.compiledCircuitFragmentNodes)
      pure
        SubgraphSpec
          { sgsTopology = topology
          , sgsDefinitions = Map.fromList [(stage.sdStageId, stage) | stage <- definitionsList]
          , sgsEntryNodes = fmap (NodeId . unCircuitNodeRef) fragment.compiledCircuitFragmentEntryNodes
          , sgsExitNodes = fmap (NodeId . unCircuitNodeRef) fragment.compiledCircuitFragmentExitNodes
          }

collectLatentTemplateEntries
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitLoweringError [(NodeId, StageDefinition NodeId)]
collectLatentTemplateEntries pulseConfig binder compiledCircuit =
  concat
    <$> traverse
      (collectNodeLatentEntries pulseConfig binder [])
      (Map.elems compiledCircuit.compiledCircuitNodes)

collectNodeLatentEntries
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> [Text]
  -> CompiledCircuitNode
  -> Either CircuitLoweringError [(NodeId, StageDefinition NodeId)]
collectNodeLatentEntries pulseConfig binder pathSegments = \case
  CompiledCircuitCondition conditionNode ->
    (<>)
      <$> collectFragmentTemplateEntries
        pulseConfig
        binder
        (pathSegments <> [unCircuitNodeRef conditionNode.circuitConditionNodeRef, "then"])
        conditionNode.circuitConditionNodeThenFragment
      <*> maybe
        (Right [])
        ( collectFragmentTemplateEntries
            pulseConfig
            binder
            (pathSegments <> [unCircuitNodeRef conditionNode.circuitConditionNodeRef, "else"])
        )
        conditionNode.circuitConditionNodeElseFragment
  _ ->
    Right []

collectFragmentTemplateEntries
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> [Text]
  -> CompiledCircuitFragment
  -> Either CircuitLoweringError [(NodeId, StageDefinition NodeId)]
collectFragmentTemplateEntries pulseConfig binder pathSegments fragment =
  concat
    <$> traverse
      ( \(nodeRef, compiledNode) -> do
          loweredStage <- lowerNode pulseConfig binder compiledNode
          descendants <-
            collectNodeLatentEntries
              pulseConfig
              binder
              (pathSegments <> [unCircuitNodeRef nodeRef])
              compiledNode
          pure ((templateRegistryNodeId pathSegments nodeRef, loweredStage) : descendants)
      )
      (Map.toList fragment.compiledCircuitFragmentNodes)

templateRegistryNodeId :: [Text] -> CircuitNodeRef -> NodeId
templateRegistryNodeId pathSegments nodeRef =
  NodeId ("__template_registry__:" <> T.intercalate "/" (pathSegments <> [unCircuitNodeRef nodeRef]))

collectLatentConditions
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitLoweringError [StageLatentCondition]
collectLatentConditions pulseConfig binder compiledCircuit =
  concat
    <$> traverse
      (collectNodeLatentConditions pulseConfig binder rootNodeId compiledCircuit.compiledCircuitTopology)
      (Map.elems compiledCircuit.compiledCircuitNodes)
  where
    rootNodeId = NodeId . unCircuitNodeRef

collectNodeLatentConditions
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> (CircuitNodeRef -> NodeId)
  -> Relation CircuitNodeRef
  -> CompiledCircuitNode
  -> Either CircuitLoweringError [StageLatentCondition]
collectNodeLatentConditions pulseConfig binder actualize enclosingTopology = \case
  CompiledCircuitCondition conditionNode -> do
    let anchorNodeId = actualize conditionNode.circuitConditionNodeRef
        postSuccessorNodes =
          actualize
            <$> Set.toList (successors enclosingTopology conditionNode.circuitConditionNodeRef)
    thenBranch <-
      lowerLatentBranch
        pulseConfig
        binder
        anchorNodeId
        postSuccessorNodes
        "then"
        conditionNode.circuitConditionNodeThenFragment
    elseBranches <-
      traverse
        ( lowerLatentBranch
            pulseConfig
            binder
            anchorNodeId
            postSuccessorNodes
            "else"
        )
        conditionNode.circuitConditionNodeElseFragment
    pure
      [ StageLatentCondition
          { slcAnchorNodeId = anchorNodeId
          , slcBranches = thenBranch : foldMap pure elseBranches
          }
      ]
  _ ->
    pure []

lowerLatentBranch
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> NodeId
  -> [NodeId]
  -> Text
  -> CompiledCircuitFragment
  -> Either CircuitLoweringError StageLatentBranch
lowerLatentBranch pulseConfig binder anchorNodeId postSuccessorNodes branchId fragment = do
  loweredFragment <- lowerFragment pulseConfig binder fragment
  nestedConditions <-
    concat
      <$> traverse
        ( collectNodeLatentConditions
            pulseConfig
            binder
            actualizeInBranch
            fragment.compiledCircuitFragmentTopology
        )
        (Map.elems fragment.compiledCircuitFragmentNodes)
  let canonicalize = namespaceNodeId anchorNodeId
      canonicalTopology = mapRelation canonicalize loweredFragment.sgsTopology
      canonicalNodes =
        Map.fromList
          [ ( canonicalNodeId
            , StageLatentNode {slnTemplateId = stage.sdTemplateId, slnActionId = stage.sdActionId}
            )
          | (localNodeId, stage) <- Map.toList loweredFragment.sgsDefinitions
          , let canonicalNodeId = canonicalize localNodeId
          ]
      entryNodes = fmap canonicalize loweredFragment.sgsEntryNodes
      exitNodes = fmap canonicalize loweredFragment.sgsExitNodes
      deltaSignature =
        StageLatentDeltaSignature
          { sldsAnchorNodeId = anchorNodeId
          , sldsAnchorDisposition = RewriteAnchorRetained
          , sldsBoundaryResourceUse = rewriteBoundaryResourceUse (AppendAfter anchorNodeId loweredFragment)
          , sldsNewNodes = canonicalTopology.relVertices
          , sldsAddedEdges =
              canonicalTopology.relEdges
                <> Set.fromList [(anchorNodeId, entryNodeId) | entryNodeId <- entryNodes]
                <> Set.fromList
                  [(exitNodeId, successorNodeId) | exitNodeId <- exitNodes, successorNodeId <- postSuccessorNodes]
          , sldsEntryNodes = entryNodes
          , sldsExitNodes = exitNodes
          }
  pure
    StageLatentBranch
      { slbBranchId = branchId
      , slbAnchorNodeId = anchorNodeId
      , slbNodes = canonicalNodes
      , slbTopology = canonicalTopology
      , slbEntryNodes = entryNodes
      , slbExitNodes = exitNodes
      , slbPostSuccessorNodes = postSuccessorNodes
      , slbDeltaSignature = deltaSignature
      , slbNestedConditions = nestedConditions
      }
  where
    actualizeInBranch = namespaceNodeId anchorNodeId . actualizeLocal
    actualizeLocal = NodeId . unCircuitNodeRef

namespaceNodeId :: NodeId -> NodeId -> NodeId
namespaceNodeId (NodeId parentNodeId) (NodeId localNodeId) =
  NodeId (parentNodeId <> ":" <> localNodeId)

{- | The @(thenKeys, elseKeys)@ select-arm label sets of a @wire_select@ condition
node, parsed from its compiled metadata (ADR 0062): the variant labels routed to the
then branch and to the else branch respectively.
-}
committedVariantSelectKeys :: Aeson.Value -> Either CircuitLoweringError ([Text], [Text])
committedVariantSelectKeys metadata =
  first (CircuitConditionMetadataInvalid . T.pack) $
    AesonTypes.parseEither
      ( Aeson.withObject "wire_select condition metadata" $ \o ->
          (,) <$> o Aeson..: "thenKeys" <*> o Aeson..: "elseKeys"
      )
      metadata

{- | Decide a select branch from the committed variant label (ADR 0062). The select
boundary's producer commits exactly one variant 'WireValue' whose @wireValuePort@ is
the chosen label; this finds that producer among the condition node's predecessor
outputs (the first whose label is one of the select keys) and routes by then-key
membership. It runs no effect, so a resume that re-evaluates it from the same
persisted inputs reproduces the same branch. With no committed select label it
defaults to the else branch with a null anchor output.
-}
committedVariantSelection
  :: [Text] -> [Text] -> Map NodeId Aeson.Value -> CircuitConditionSelection
committedVariantSelection thenKeys elseKeys scInputs =
  case committedSelectKeyLabel of
    Just (label, raw)
      | label `elem` thenKeys ->
          CircuitConditionSelection raw CircuitConditionThen
      | otherwise ->
          CircuitConditionSelection raw CircuitConditionElse
    Nothing ->
      CircuitConditionSelection Aeson.Null CircuitConditionElse
  where
    selectKeys = thenKeys <> elseKeys
    committedSelectKeyLabel =
      listToMaybe
        [ (label, raw)
        | raw <- Map.elems scInputs
        , Aeson.Success wireValue <- [Aeson.fromJSON raw :: Aeson.Result WireValue]
        , Just label <- [wireValue.wireValuePort]
        , label `elem` selectKeys
        ]

{- | A production condition binding (ADR 0062) whose branch is decided by the
committed variant label of the select boundary's producer, read from the persisted
predecessor outputs and routed via the compiled @thenKeys@/@elseKeys@. No backend or
effect runs in selection, so durable resume is deterministic. This replaces the
test-only hardcoded selectors as the runtime guard source ADR 0033 deferred.
-}
committedVariantConditionBinding
  :: CircuitConditionNode -> Either CircuitLoweringError CircuitConditionBinding
committedVariantConditionBinding conditionNode = do
  (thenKeys, elseKeys) <- committedVariantSelectKeys conditionNode.circuitConditionNodeMetadata
  Right
    CircuitConditionBinding
      { circuitConditionReplaySafety = SafeToReplay
      , circuitConditionReplayPolicyOverride = Nothing
      , circuitConditionTimeoutSeconds = Nothing
      , circuitConditionRetryPolicy = Nothing
      , circuitConditionTemplateId = Nothing
      , circuitConditionActionId = Nothing
      , circuitConditionSelectBranch = \_runId scInputs ->
          pure (committedVariantSelection thenKeys elseKeys scInputs)
      }

{- | The general committed-variant @select(...)@ binder builder (GitHub #323, #36,
ADR 0080): the caller supplies the task-node binding and the signal/artifact/rewrite
boundary bindings; the condition binding is fixed to 'committedVariantConditionBinding'
so it cannot be forgotten. Build the boundary stages with 'signalStage' /
'artifactStage'. 'committedVariantBinder' is the task-only special case where every
boundary is rejected.
-}
committedVariantBinderWith
  :: (CircuitTaskNode -> Either CircuitLoweringError (StageDefinition NodeId))
  -> (CircuitSignalBoundary -> Either CircuitLoweringError (StageDefinition NodeId))
  -> (CircuitArtifactBoundary -> Either CircuitLoweringError (StageDefinition NodeId))
  -> (CircuitRewriteBoundary -> Either CircuitLoweringError (StageDefinition NodeId))
  -> CircuitPulseBinder
committedVariantBinderWith bindTaskNode bindSignal bindArtifact bindRewrite =
  CircuitPulseBinder
    { bindCircuitTaskNode = bindTaskNode
    , bindCircuitSignalBoundary = bindSignal
    , bindCircuitArtifactBoundary = bindArtifact
    , bindCircuitRewriteBoundary = bindRewrite
    , bindCircuitConditionNode = committedVariantConditionBinding
    }

{- | Smart constructor for the common committed-variant @select(...)@ binder
(GitHub #323, ADR 0080): the caller supplies the task-node binding; the condition
binding is fixed to 'committedVariantConditionBinding', and the signal/artifact/rewrite
boundaries are rejected with 'CircuitBoundaryUnsupported'. A caller whose circuit has
boundary nodes uses 'committedVariantBinderWith' with 'signalStage' / 'artifactStage'.
-}
committedVariantBinder
  :: (CircuitTaskNode -> Either CircuitLoweringError (StageDefinition NodeId))
  -> CircuitPulseBinder
committedVariantBinder bindTaskNode =
  committedVariantBinderWith
    bindTaskNode
    (\_ -> Left (CircuitBoundaryUnsupported "signal"))
    (\_ -> Left (CircuitBoundaryUnsupported "artifact"))
    (\_ -> Left (CircuitBoundaryUnsupported "rewrite"))

{- | Lower a signal boundary to a stage that suspends the run on the boundary's signal
name. Suspension is idempotent (a resumed re-evaluation re-suspends on the same
signal), so the stage binds as 'SafeToReplay'. The stage id is taken from the boundary
ref so the lowering ref-check passes.
-}
signalStage :: CircuitSignalBoundary -> StageDefinition NodeId
signalStage boundary =
  taskStage
    (boundaryNodeId boundary.circuitSignalBoundaryRef)
    SafeToReplay
    (\_ -> pure (StageSuspend (SignalName boundary.circuitSignalName)))

{- | Lower an artifact boundary to a stage whose action and replay safety the caller
supplies. Cortex has no built-in artifact runtime, so the caller defines what the
artifact stage does (e.g. write the artifact, then 'StageComplete' its descriptor) and
whether re-running it on resume is safe. The stage id is taken from the boundary ref so
the lowering ref-check passes.
-}
artifactStage
  :: CircuitArtifactBoundary
  -> StageReplaySafety
  -> (StageContext -> IO (StageResult NodeId))
  -> StageDefinition NodeId
artifactStage boundary =
  taskStage (boundaryNodeId boundary.circuitArtifactBoundaryRef)

-- | A boundary's circuit node ref is its stage id (the lowering ref-check requires it).
boundaryNodeId :: CircuitNodeRef -> NodeId
boundaryNodeId = NodeId . unCircuitNodeRef
