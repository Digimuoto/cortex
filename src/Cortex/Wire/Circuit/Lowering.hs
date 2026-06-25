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
  )
where

import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
  , StageReplaySafety
  , StageResult (..)
  , StageRetryPolicy
  , StageTemplateId
  , buildStageTemplateRegistry
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Rewrite
  ( GraphRewrite (AppendAfter)
  , RewriteAnchorDisposition (..)
  , RewriteBudget
  , SubgraphSpec (..)
  , rewriteBoundaryResourceUse
  )
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
  ( CircuitArtifactBoundary
  , CircuitIR
  , CircuitNodeRef (..)
  , CircuitRewriteBoundary
  , CircuitSignalBoundary
  , CircuitTaskNode
  )

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
        pure $
          case selection.circuitConditionSelectionBranch of
            CircuitConditionThen ->
              StageRewrite selection.circuitConditionSelectionOutput (AppendAfter stageId thenFragment)
            CircuitConditionElse ->
              maybe
                (StageComplete selection.circuitConditionSelectionOutput)
                (StageRewrite selection.circuitConditionSelectionOutput . AppendAfter stageId)
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
