{- |
Module      : Cortex.Pulse.Rewrite
Description : Pulse runtime support for rewrite.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Rewrite
  ( GraphRewrite (..)
  , ExpansionMode (..)
  , SubgraphSpec (..)
  , RewriteBudget (..)
  , RewriteCost (..)
  , BudgetDimension (..)
  , ExceededDimension (..)
  , RewriteBudgetError (..)
  , exceededDimensions
  , RewritePlanningError (..)
  , RewriteAnchorDisposition (..)
  , PlannedRewriteDelta (..)
  , ExpectedActual (..)
  , BoundaryLaw (..)
  , AnchorBoundaryUse (..)
  , BoundaryResourceUse (..)
  , BudgetedBoundaryResourceUse (..)
  , RewriteWitnessError (..)
  , renderRewriteWitnessError
  , rewriteWitnessErrorType
  , RewriteAdmissionError (..)
  , RewriteAdmissionWitness
  , rawGraphRewrite
  , runtimeGraphRewrite
  , plannedGraphRewriteDelta
  , admittedGraphRewriteDelta
  , admittedBoundaryResourceUse
  , AdmittedRewriteDelta
  , admitRewriteDelta
  , admittedDelta
  , admittedRemainingBudget
  , runtimePlannerRewrite
  , rewriteBoundaryResourceUse
  , budgetedBoundaryResourceUse
  , validatePlannedRewriteDelta
  , validateAdmittedRewriteDelta
  , planGraphRewriteWithAdmissionWitness
  , planGraphRewrite
  , consumeRewriteBudget
  , BudgetContext (..)
  , budgetFraction
  , lookupDimension
  , RewriteRejectionContext (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph
  ( Relation (..)
  , ValidationError (..)
  , addEdge
  , foldTopSort
  , mapRelation
  , predecessors
  , reachableFrom
  , relVertices
  , relationDiff
  , removeEdge
  , removeVertex
  , successors
  , transposeRelation
  , validateDAG
  )
import Cortex.Pulse.Node (NodeId (..))

{- | A rewrite fragment. Entry and exit lists are the serialized form of proof-side sets;
validation rejects duplicates before planning.
-}
data SubgraphSpec a def = SubgraphSpec
  { sgsTopology :: Relation a
  , sgsDefinitions :: Map a def
  , sgsEntryNodes :: [a]
  , sgsExitNodes :: [a]
  }
  deriving stock (Eq, Show, Generic, Functor)
  deriving anyclass (FromJSON, ToJSON)

data ExpansionMode
  = ExpandReplaceNode
  | ExpandRetainNodeAsEnvelope
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GraphRewrite a def
  = ExpandNode a ExpansionMode (SubgraphSpec a def)
  | AppendAfter a (SubgraphSpec a def)
  deriving stock (Eq, Show, Generic, Functor)
  deriving anyclass (FromJSON, ToJSON)

{- | Remaining structural rewrite budget. Dimensions are natural quantities, matching the
proof-side `RewriteBudget`.
-}
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax :: !Natural
  , rbAddedEdgesMax :: !Natural
  , rbAddedDepthMax :: !Natural
  , rbFrontierDeltaMax :: !Natural
  , rbRewriteOpsMax :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Structural rewrite cost. A cost is a proof-side natural vector, so negative costs are rejected
at JSON decoding and cannot reach budget admission.
-}
data RewriteCost = RewriteCost
  { rcAddedNodes :: !Natural
  , rcAddedEdges :: !Natural
  , rcAddedDepth :: !Natural
  , rcFrontierDelta :: !Natural
  , rcRewriteOps :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Which budget dimension was exceeded.
data BudgetDimension
  = DimAddedNodes
  | DimAddedEdges
  | DimAddedDepth
  | DimFrontierDelta
  | DimRewriteOps
  deriving stock (Eq, Show, Generic, Bounded, Enum)
  deriving anyclass (FromJSON, ToJSON)

-- | A single exceeded dimension with the requested and remaining values.
data ExceededDimension = ExceededDimension
  { edDimension :: !BudgetDimension
  , edRequested :: !Natural
  , edRemaining :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Budget context provided to every node at execution time.
data BudgetContext = BudgetContext
  { bcInitialBudget :: !RewriteBudget
  , bcRemainingBudget :: !RewriteBudget
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Fraction of budget remaining for a given dimension (0.0 = exhausted, 1.0 = full).
budgetFraction :: BudgetContext -> BudgetDimension -> Double
budgetFraction ctx dim =
  let initial = lookupDimension dim ctx.bcInitialBudget
      remaining = lookupDimension dim ctx.bcRemainingBudget
   in if initial == 0 then 0 else fromIntegral remaining / fromIntegral initial

-- | Extract the natural value for a budget dimension from a 'RewriteBudget'.
lookupDimension :: BudgetDimension -> RewriteBudget -> Natural
lookupDimension DimAddedNodes = rbAddedNodesMax
lookupDimension DimAddedEdges = rbAddedEdgesMax
lookupDimension DimAddedDepth = rbAddedDepthMax
lookupDimension DimFrontierDelta = rbFrontierDeltaMax
lookupDimension DimRewriteOps = rbRewriteOpsMax

-- | Rejection context passed back to a node when its rewrite was rejected.
data RewriteRejectionContext = RewriteRejectionContext
  { rrcRejectionType :: !Text
  , rrcMessage :: !Text
  , rrcExceededDimensions :: ![ExceededDimension]
  , rrcBudgetContext :: !BudgetContext
  , rrcAttemptedCost :: !(Maybe RewriteCost)
  , rrcAttemptNumber :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data RewriteBudgetError
  = RewriteBudgetExceeded RewriteBudget RewriteCost
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Compute which dimensions exceeded their budget.
exceededDimensions :: RewriteBudgetError -> [ExceededDimension]
exceededDimensions (RewriteBudgetExceeded budget cost) =
  [ ExceededDimension dim req rem'
  | (dim, req, rem') <-
      [ (DimAddedNodes, rcAddedNodes cost, rbAddedNodesMax budget)
      , (DimAddedEdges, rcAddedEdges cost, rbAddedEdgesMax budget)
      , (DimAddedDepth, rcAddedDepth cost, rbAddedDepthMax budget)
      , (DimFrontierDelta, rcFrontierDelta cost, rbFrontierDeltaMax budget)
      , (DimRewriteOps, rcRewriteOps cost, rbRewriteOpsMax budget)
      ]
  , req > rem'
  ]

data RewritePlanningError a
  = RewriteInvalidTopology (ValidationError a)
  | RewriteAnchorMissingFromTopology a
  | RewriteAnchorMissingDefinition a
  | RewriteCurrentDefinitionsMissing [a]
  | RewriteCurrentDefinitionsOutsideTopology [a]
  | RewriteTopologyEmpty
  | RewriteDefinitionsMissing [a]
  | RewriteDefinitionsOutsideTopology [a]
  | RewriteEntryNodesMissing
  | RewriteExitNodesMissing
  | RewriteDuplicateEntryNodes [a]
  | RewriteDuplicateExitNodes [a]
  | RewriteEntryNodesOutsideTopology [a]
  | RewriteExitNodesOutsideTopology [a]
  | RewriteInvalidLocalNodeIds [a]
  | RewriteNamespacedNodeCollision [a]
  | RewriteOrphanNodes [a]
  deriving stock (Eq, Show, Generic)

data RewriteAnchorDisposition
  = RewriteAnchorRemoved
  | RewriteAnchorRetained
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PlannedRewriteDelta def = PlannedRewriteDelta
  { prdTopology :: !(Relation NodeId)
  , prdDefinitions :: !(Map NodeId def)
  , prdNewNodes :: !(Set NodeId)
  , prdRemovedNodes :: !(Set NodeId)
  , prdAddedEdges :: !(Set (NodeId, NodeId))
  , prdEntryNodes :: ![NodeId]
  , prdExitNodes :: ![NodeId]
  , prdAnchorNode :: !NodeId
  , prdAnchorDisposition :: !RewriteAnchorDisposition
  , prdCost :: !RewriteCost
  }
  deriving stock (Eq, Show, Generic, Functor)
  deriving anyclass (FromJSON, ToJSON)

data ExpectedActual a = ExpectedActual
  { eaExpected :: !a
  , eaActual :: !a
  }
  deriving stock (Eq, Show, Generic)

data BoundaryLaw
  = ContractPreservingSubstitution
  | AppendContinuation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AnchorBoundaryUse
  = AnchorBoundaryConsumed
  | AnchorBoundaryRetained
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BoundaryResourceUse = BoundaryResourceUse
  { bruLaw :: !BoundaryLaw
  , bruSlotAnchor :: !NodeId
  , bruAnchorBoundaryUse :: !AnchorBoundaryUse
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BudgetedBoundaryResourceUse = BudgetedBoundaryResourceUse
  { bbruUse :: !BoundaryResourceUse
  , bbruCost :: !RewriteCost
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Typed drift report for the Haskell planner/theory correspondence surface.

The Lean side names these facts in `PlanGraphRewriteChecks` and
`AdmittedRewriteDelta`.  Haskell cannot prove them, but this checker
recomputes the equations from the same inputs used by `planGraphRewrite` so
future implementation drift fails loudly in tests or runtime debug paths.
-}
data RewriteWitnessError
  = RewriteWitnessInputRejected [RewritePlanningError NodeId]
  | RewriteWitnessAnchorMismatch !(ExpectedActual NodeId)
  | RewriteWitnessTopologyMismatch
  | RewriteWitnessInsertedVerticesMissing ![NodeId]
  | RewriteWitnessInsertedEdgesMissing ![(NodeId, NodeId)]
  | RewriteWitnessEntryNodesMismatch !(ExpectedActual [NodeId])
  | RewriteWitnessExitNodesMismatch !(ExpectedActual [NodeId])
  | RewriteWitnessAnchorDispositionMismatch !(ExpectedActual RewriteAnchorDisposition)
  | RewriteWitnessRemovedAnchorPresent !NodeId
  | RewriteWitnessRetainedAnchorMissing !NodeId
  | RewriteWitnessNewNodesMismatch !(ExpectedActual (Set NodeId))
  | RewriteWitnessRemovedNodesMismatch !(ExpectedActual (Set NodeId))
  | RewriteWitnessAddedEdgesMismatch !(ExpectedActual (Set (NodeId, NodeId)))
  | RewriteWitnessDefinitionUpdateMismatch !(ExpectedActual (Set NodeId))
  | RewriteWitnessFinalDefinitionCoverageMismatch !(ExpectedActual (Set NodeId))
  | RewriteWitnessCostMismatch !(ExpectedActual RewriteCost)
  | RewriteWitnessFinalTopologyInvalid !(ValidationError NodeId)
  | RewriteWitnessBudgetRejected !RewriteBudgetError
  | RewriteWitnessRemainingBudgetMismatch !(ExpectedActual RewriteBudget)
  deriving stock (Eq, Show, Generic)

renderRewriteWitnessError :: RewriteWitnessError -> Text
renderRewriteWitnessError = \case
  RewriteWitnessInputRejected errors ->
    "Rewrite witness input validation failed: " <> renderRewritePlanningErrors errors
  RewriteWitnessAnchorMismatch pair ->
    "Rewrite witness anchor mismatch: " <> renderExpectedActual renderNodeId pair
  RewriteWitnessTopologyMismatch ->
    "Rewrite witness final topology differs from the planned topology equation"
  RewriteWitnessInsertedVerticesMissing nodes ->
    "Rewrite witness final topology is missing inserted vertices: " <> renderNodeIds nodes
  RewriteWitnessInsertedEdgesMissing edges ->
    "Rewrite witness final topology is missing inserted edges: " <> renderEdgeList edges
  RewriteWitnessEntryNodesMismatch pair ->
    "Rewrite witness entry nodes mismatch: " <> renderExpectedActual renderNodeIds pair
  RewriteWitnessExitNodesMismatch pair ->
    "Rewrite witness exit nodes mismatch: " <> renderExpectedActual renderNodeIds pair
  RewriteWitnessAnchorDispositionMismatch pair ->
    "Rewrite witness anchor disposition mismatch: " <> renderExpectedActual renderAnchorDisposition pair
  RewriteWitnessRemovedAnchorPresent nodeId ->
    "Rewrite witness removed anchor is still present in final topology: " <> renderNodeId nodeId
  RewriteWitnessRetainedAnchorMissing nodeId ->
    "Rewrite witness retained anchor is missing from final topology: " <> renderNodeId nodeId
  RewriteWitnessNewNodesMismatch pair ->
    "Rewrite witness new-node set mismatch: " <> renderExpectedActual renderNodeSet pair
  RewriteWitnessRemovedNodesMismatch pair ->
    "Rewrite witness removed-node set mismatch: " <> renderExpectedActual renderNodeSet pair
  RewriteWitnessAddedEdgesMismatch pair ->
    "Rewrite witness added-edge set mismatch: " <> renderExpectedActual renderEdgeSet pair
  RewriteWitnessDefinitionUpdateMismatch pair ->
    "Rewrite witness definition-domain update mismatch: " <> renderExpectedActual renderNodeSet pair
  RewriteWitnessFinalDefinitionCoverageMismatch pair ->
    "Rewrite witness final definition coverage mismatch: " <> renderExpectedActual renderNodeSet pair
  RewriteWitnessCostMismatch pair ->
    "Rewrite witness cost mismatch: " <> renderExpectedActual renderRewriteCost pair
  RewriteWitnessFinalTopologyInvalid err ->
    "Rewrite witness final topology is invalid: " <> showText err
  RewriteWitnessBudgetRejected err ->
    "Rewrite witness budget check rejected the delta: " <> renderRewriteBudgetError err
  RewriteWitnessRemainingBudgetMismatch pair ->
    "Rewrite witness remaining-budget mismatch: " <> renderExpectedActual renderRewriteBudget pair

{- | Stable error type string for planner/theory drift diagnostics.
These values are intended for observability and should not be renamed casually.
-}
rewriteWitnessErrorType :: RewriteWitnessError -> Text
rewriteWitnessErrorType = \case
  RewriteWitnessInputRejected {} -> "rewrite_witness_input_rejected"
  RewriteWitnessAnchorMismatch {} -> "rewrite_witness_anchor_mismatch"
  RewriteWitnessTopologyMismatch {} -> "rewrite_witness_topology_mismatch"
  RewriteWitnessInsertedVerticesMissing {} -> "rewrite_witness_inserted_vertices_missing"
  RewriteWitnessInsertedEdgesMissing {} -> "rewrite_witness_inserted_edges_missing"
  RewriteWitnessEntryNodesMismatch {} -> "rewrite_witness_entry_nodes_mismatch"
  RewriteWitnessExitNodesMismatch {} -> "rewrite_witness_exit_nodes_mismatch"
  RewriteWitnessAnchorDispositionMismatch {} -> "rewrite_witness_anchor_disposition_mismatch"
  RewriteWitnessRemovedAnchorPresent {} -> "rewrite_witness_removed_anchor_present"
  RewriteWitnessRetainedAnchorMissing {} -> "rewrite_witness_retained_anchor_missing"
  RewriteWitnessNewNodesMismatch {} -> "rewrite_witness_new_nodes_mismatch"
  RewriteWitnessRemovedNodesMismatch {} -> "rewrite_witness_removed_nodes_mismatch"
  RewriteWitnessAddedEdgesMismatch {} -> "rewrite_witness_added_edges_mismatch"
  RewriteWitnessDefinitionUpdateMismatch {} -> "rewrite_witness_definition_update_mismatch"
  RewriteWitnessFinalDefinitionCoverageMismatch {} -> "rewrite_witness_final_definition_coverage_mismatch"
  RewriteWitnessCostMismatch {} -> "rewrite_witness_cost_mismatch"
  RewriteWitnessFinalTopologyInvalid {} -> "rewrite_witness_final_topology_invalid"
  RewriteWitnessBudgetRejected {} -> "rewrite_witness_budget_rejected"
  RewriteWitnessRemainingBudgetMismatch {} -> "rewrite_witness_remaining_budget_mismatch"

renderExpectedActual :: (a -> Text) -> ExpectedActual a -> Text
renderExpectedActual renderValue pair =
  "expected=" <> renderValue pair.eaExpected <> "; actual=" <> renderValue pair.eaActual

renderRewritePlanningErrors :: [RewritePlanningError NodeId] -> Text
renderRewritePlanningErrors =
  T.intercalate "; " . fmap renderRewritePlanningError

renderRewritePlanningError :: RewritePlanningError NodeId -> Text
renderRewritePlanningError = \case
  RewriteInvalidTopology err ->
    "rewrite produced invalid graph: " <> showText err
  RewriteAnchorMissingFromTopology nodeId ->
    "rewrite anchor node is outside the current topology: " <> renderNodeId nodeId
  RewriteAnchorMissingDefinition nodeId ->
    "rewrite anchor node is missing a definition: " <> renderNodeId nodeId
  RewriteCurrentDefinitionsMissing nodes ->
    "current topology is missing definitions for: " <> renderNodeIds nodes
  RewriteCurrentDefinitionsOutsideTopology nodes ->
    "current definitions contain nodes outside topology: " <> renderNodeIds nodes
  RewriteTopologyEmpty ->
    "rewrite subgraph must insert at least one node"
  RewriteDefinitionsMissing nodes ->
    "rewrite subgraph is missing definitions for: " <> renderNodeIds nodes
  RewriteDefinitionsOutsideTopology nodes ->
    "rewrite subgraph defines nodes outside topology: " <> renderNodeIds nodes
  RewriteEntryNodesMissing ->
    "rewrite subgraph must declare at least one entry node"
  RewriteExitNodesMissing ->
    "rewrite subgraph must declare at least one exit node"
  RewriteDuplicateEntryNodes nodes ->
    "rewrite subgraph declares duplicate entry nodes: " <> renderNodeIds nodes
  RewriteDuplicateExitNodes nodes ->
    "rewrite subgraph declares duplicate exit nodes: " <> renderNodeIds nodes
  RewriteEntryNodesOutsideTopology nodes ->
    "rewrite entry nodes are outside topology: " <> renderNodeIds nodes
  RewriteExitNodesOutsideTopology nodes ->
    "rewrite exit nodes are outside topology: " <> renderNodeIds nodes
  RewriteInvalidLocalNodeIds nodes ->
    "rewrite local node ids must be non-empty and must not contain namespace delimiter ':': "
      <> renderNodeIds nodes
  RewriteNamespacedNodeCollision nodes ->
    "rewrite namespaced nodes collide with existing topology: " <> renderNodeIds nodes
  RewriteOrphanNodes nodes ->
    "rewrite subgraph contains orphan nodes: " <> renderNodeIds nodes

renderNodeId :: NodeId -> Text
renderNodeId = unNodeId

renderNodeIds :: [NodeId] -> Text
renderNodeIds = T.intercalate ", " . fmap renderNodeId

renderNodeSet :: Set NodeId -> Text
renderNodeSet = renderNodeIds . Set.toAscList

renderEdge :: (NodeId, NodeId) -> Text
renderEdge (fromNode, toNode) = renderNodeId fromNode <> " -> " <> renderNodeId toNode

renderEdgeList :: [(NodeId, NodeId)] -> Text
renderEdgeList = T.intercalate ", " . fmap renderEdge

renderEdgeSet :: Set (NodeId, NodeId) -> Text
renderEdgeSet = renderEdgeList . Set.toAscList

renderAnchorDisposition :: RewriteAnchorDisposition -> Text
renderAnchorDisposition = \case
  RewriteAnchorRemoved -> "removed"
  RewriteAnchorRetained -> "retained"

renderRewriteCost :: RewriteCost -> Text
renderRewriteCost cost =
  "{added_nodes="
    <> showText cost.rcAddedNodes
    <> ", added_edges="
    <> showText cost.rcAddedEdges
    <> ", added_depth="
    <> showText cost.rcAddedDepth
    <> ", frontier_delta="
    <> showText cost.rcFrontierDelta
    <> ", rewrite_ops="
    <> showText cost.rcRewriteOps
    <> "}"

renderRewriteBudget :: RewriteBudget -> Text
renderRewriteBudget budget =
  "{added_nodes="
    <> showText budget.rbAddedNodesMax
    <> ", added_edges="
    <> showText budget.rbAddedEdgesMax
    <> ", added_depth="
    <> showText budget.rbAddedDepthMax
    <> ", frontier_delta="
    <> showText budget.rbFrontierDeltaMax
    <> ", rewrite_ops="
    <> showText budget.rbRewriteOpsMax
    <> "}"

renderRewriteBudgetError :: RewriteBudgetError -> Text
renderRewriteBudgetError budgetErr@(RewriteBudgetExceeded remaining requested) =
  "requested="
    <> renderRewriteCost requested
    <> "; remaining="
    <> renderRewriteBudget remaining
    <> "; exceeded_dimensions=["
    <> T.intercalate ", " (fmap renderExceededDimension (exceededDimensions budgetErr))
    <> "]"

renderExceededDimension :: ExceededDimension -> Text
renderExceededDimension dim =
  showText dim.edDimension
    <> "(requested="
    <> showText dim.edRequested
    <> ", remaining="
    <> showText dim.edRemaining
    <> ")"

showText :: Show a => a -> Text
showText = T.pack . show

data RewriteAdmissionError
  = RewriteAdmissionPlanningRejected ![RewritePlanningError NodeId]
  | RewriteAdmissionWitnessInvalid ![RewriteWitnessError]
  | RewriteAdmissionBudgetRejected !RewriteBudgetError
  deriving stock (Eq, Show, Generic)

data RewriteAdmissionWitness def = RewriteAdmissionWitness
  { rawGraphRewrite :: !(GraphRewrite NodeId def)
  , runtimeGraphRewrite :: !(GraphRewrite NodeId def)
  , plannedGraphRewriteDelta :: !(PlannedRewriteDelta def)
  , admittedGraphRewriteDelta :: !(AdmittedRewriteDelta def)
  , admittedBoundaryResourceUse :: !BudgetedBoundaryResourceUse
  }
  deriving stock (Show, Generic)

{- | Witness that a rewrite delta has been admitted against a budget.
The constructor is not exported — the only way to obtain an
'AdmittedRewriteDelta' is through 'admitRewriteDelta'.
-}
data AdmittedRewriteDelta def = AdmittedRewriteDelta
  { ardDelta :: PlannedRewriteDelta def
  , ardRemainingBudget :: RewriteBudget
  }
  deriving stock (Eq, Show, Generic)

{- | Validate that a planned rewrite delta fits within the remaining budget.
On success, returns an 'AdmittedRewriteDelta' witness bundling the delta
with the decremented budget.
-}
admitRewriteDelta
  :: RewriteBudget -> PlannedRewriteDelta def -> Either RewriteBudgetError (AdmittedRewriteDelta def)
admitRewriteDelta budget delta = do
  remaining <- consumeRewriteBudget budget delta.prdCost
  pure AdmittedRewriteDelta {ardDelta = delta, ardRemainingBudget = remaining}

admittedDelta :: AdmittedRewriteDelta def -> PlannedRewriteDelta def
admittedDelta = ardDelta

admittedRemainingBudget :: AdmittedRewriteDelta def -> RewriteBudget
admittedRemainingBudget = ardRemainingBudget

consumeRewriteBudget :: RewriteBudget -> RewriteCost -> Either RewriteBudgetError RewriteBudget
consumeRewriteBudget budget cost
  | rcAddedNodes cost > rbAddedNodesMax budget = Left (RewriteBudgetExceeded budget cost)
  | rcAddedEdges cost > rbAddedEdgesMax budget = Left (RewriteBudgetExceeded budget cost)
  | rcAddedDepth cost > rbAddedDepthMax budget = Left (RewriteBudgetExceeded budget cost)
  | rcFrontierDelta cost > rbFrontierDeltaMax budget = Left (RewriteBudgetExceeded budget cost)
  | rcRewriteOps cost > rbRewriteOpsMax budget = Left (RewriteBudgetExceeded budget cost)
  | otherwise =
      Right
        RewriteBudget
          { rbAddedNodesMax = rbAddedNodesMax budget - rcAddedNodes cost
          , rbAddedEdgesMax = rbAddedEdgesMax budget - rcAddedEdges cost
          , rbAddedDepthMax = rbAddedDepthMax budget - rcAddedDepth cost
          , rbFrontierDeltaMax = rbFrontierDeltaMax budget - rcFrontierDelta cost
          , rbRewriteOpsMax = rbRewriteOpsMax budget - rcRewriteOps cost
          }

{- | Plan a bounded topology rewrite from the current materialized graph.

Proof contract note: the Lean planner bridge treats the input relation and
definition map as a source-valid planning context. The current topology is
expected to have been admitted as a DAG before planning starts, while
'validateRewriteAnchor' checks that definitions exactly cover the current
topology and that the anchor is present in both. This function still validates
the final topology with 'validateDAG' after constructing the planned relation.
-}
planGraphRewrite
  :: GraphRewrite NodeId def
  -> Relation NodeId
  -> Map NodeId def
  -> Either [RewritePlanningError NodeId] (PlannedRewriteDelta def)
planGraphRewrite rewrite topology defs = do
  validateRewriteAnchor topology defs (rewriteAnchor rewrite)
  validateSubgraphSpec (rewriteSpec rewrite)
  validateNamespaceDiscipline topology (rewriteAnchor rewrite) (rewriteSpec rewrite)
  let rewrite' = runtimePlannerRewrite rewrite
      topoFinal = plannedFinalTopology rewrite' topology
      defs' = plannedFinalDefinitions rewrite' defs
  first (pure . RewriteInvalidTopology) (validateDAG topoFinal) >>= \() ->
    pure (mkPlannedDelta rewrite' topology defs' topoFinal)
  where
    mkPlannedDelta rewrite' oldTopology defs' topoFinal =
      let (newNodes, removedNodes, addedEdges, _removedEdges) = relationDiff oldTopology topoFinal
          spec' = rewriteSpec rewrite'
          anchorDisposition = rewriteAnchorDisposition rewrite'
          insertedDepthNodes =
            longestInsertedPathNodeCount
              spec'.sgsTopology
              spec'.sgsEntryNodes
              spec'.sgsExitNodes
          addedDepth = case anchorDisposition of
            RewriteAnchorRemoved -> max 0 (insertedDepthNodes - 1)
            RewriteAnchorRetained -> insertedDepthNodes
          cost =
            RewriteCost
              { rcAddedNodes = fromIntegral (Set.size newNodes)
              , rcAddedEdges = fromIntegral (Set.size addedEdges)
              , rcAddedDepth = fromIntegral addedDepth
              , rcFrontierDelta = fromIntegral (max 0 (length spec'.sgsEntryNodes - 1))
              , rcRewriteOps = 1
              }
       in PlannedRewriteDelta
            { prdTopology = topoFinal
            , prdDefinitions = defs'
            , prdNewNodes = newNodes
            , prdRemovedNodes = removedNodes
            , prdAddedEdges = addedEdges
            , prdEntryNodes = spec'.sgsEntryNodes
            , prdExitNodes = spec'.sgsExitNodes
            , prdAnchorNode = rewriteAnchor rewrite'
            , prdAnchorDisposition = anchorDisposition
            , prdCost = cost
            }

runtimePlannerRewrite :: GraphRewrite NodeId def -> GraphRewrite NodeId def
runtimePlannerRewrite = \case
  ExpandNode nid mode spec ->
    ExpandNode nid mode (namespaceSubgraph nid spec)
  AppendAfter nid spec ->
    AppendAfter nid (namespaceSubgraph nid spec)

rewriteBoundaryResourceUse :: GraphRewrite NodeId def -> BoundaryResourceUse
rewriteBoundaryResourceUse = \case
  ExpandNode nid _mode _spec ->
    BoundaryResourceUse
      { bruLaw = ContractPreservingSubstitution
      , bruSlotAnchor = nid
      , bruAnchorBoundaryUse = AnchorBoundaryConsumed
      }
  AppendAfter nid _spec ->
    BoundaryResourceUse
      { bruLaw = AppendContinuation
      , bruSlotAnchor = nid
      , bruAnchorBoundaryUse = AnchorBoundaryRetained
      }

budgetedBoundaryResourceUse
  :: GraphRewrite NodeId def -> RewriteCost -> BudgetedBoundaryResourceUse
budgetedBoundaryResourceUse rewrite cost =
  BudgetedBoundaryResourceUse
    { bbruUse = rewriteBoundaryResourceUse rewrite
    , bbruCost = cost
    }

validatePlannedRewriteDelta
  :: GraphRewrite NodeId def
  -> Relation NodeId
  -> Map NodeId def
  -> PlannedRewriteDelta def
  -> Either [RewriteWitnessError] ()
validatePlannedRewriteDelta rawRewrite topology defs delta =
  case plannedRewriteWitnessErrors rawRewrite topology defs delta of
    [] -> Right ()
    errors -> Left errors

validateAdmittedRewriteDelta
  :: RewriteBudget
  -> PlannedRewriteDelta def
  -> AdmittedRewriteDelta def
  -> Either [RewriteWitnessError] ()
validateAdmittedRewriteDelta budget delta admitted =
  case consumeRewriteBudget budget delta.prdCost of
    Left err ->
      Left [RewriteWitnessBudgetRejected err]
    Right expectedRemaining
      | expectedRemaining == admittedRemainingBudget admitted ->
          Right ()
      | otherwise ->
          Left
            [ RewriteWitnessRemainingBudgetMismatch $
                ExpectedActual
                  { eaExpected = expectedRemaining
                  , eaActual = admittedRemainingBudget admitted
                  }
            ]

planGraphRewriteWithAdmissionWitness
  :: RewriteBudget
  -> GraphRewrite NodeId def
  -> Relation NodeId
  -> Map NodeId def
  -> Either RewriteAdmissionError (RewriteAdmissionWitness def)
planGraphRewriteWithAdmissionWitness budget rawRewrite topology defs = do
  delta <-
    first RewriteAdmissionPlanningRejected $
      planGraphRewrite rawRewrite topology defs
  first RewriteAdmissionWitnessInvalid $
    validatePlannedRewriteDelta rawRewrite topology defs delta
  admitted <-
    first RewriteAdmissionBudgetRejected $
      admitRewriteDelta budget delta
  first RewriteAdmissionWitnessInvalid $
    validateAdmittedRewriteDelta budget delta admitted
  pure
    RewriteAdmissionWitness
      { rawGraphRewrite = rawRewrite
      , runtimeGraphRewrite = runtimePlannerRewrite rawRewrite
      , plannedGraphRewriteDelta = delta
      , admittedGraphRewriteDelta = admitted
      , admittedBoundaryResourceUse =
          budgetedBoundaryResourceUse (runtimePlannerRewrite rawRewrite) delta.prdCost
      }

plannedRewriteWitnessErrors
  :: GraphRewrite NodeId def
  -> Relation NodeId
  -> Map NodeId def
  -> PlannedRewriteDelta def
  -> [RewriteWitnessError]
plannedRewriteWitnessErrors rawRewrite topology defs delta =
  concat
    [ inputValidationErrors
    , anchorErrors
    , topologyErrors
    , containedErrors
    , entryExitErrors
    , anchorDispositionErrors
    , topologyDiffErrors
    , definitionErrors
    , costErrors
    , finalAcyclicErrors
    ]
  where
    rewrite' = runtimePlannerRewrite rawRewrite
    spec' = rewriteSpec rewrite'
    expectedTopology = plannedFinalTopology rewrite' topology
    expectedDefinitionKeys = plannedFinalDefinitionKeys rewrite' defs
    (expectedNewNodes, expectedRemovedNodes, expectedAddedEdges, _expectedRemovedEdges) =
      relationDiff topology delta.prdTopology

    inputValidationErrors =
      case validateRewriteAnchor topology defs (rewriteAnchor rawRewrite)
        *> validateSubgraphSpec (rewriteSpec rawRewrite)
        *> validateNamespaceDiscipline topology (rewriteAnchor rawRewrite) (rewriteSpec rawRewrite) of
        Left errors -> [RewriteWitnessInputRejected errors]
        Right () -> []

    anchorErrors =
      [ RewriteWitnessAnchorMismatch $
          ExpectedActual
            { eaExpected = rewriteAnchor rawRewrite
            , eaActual = delta.prdAnchorNode
            }
      | delta.prdAnchorNode /= rewriteAnchor rawRewrite
      ]

    topologyErrors =
      [RewriteWitnessTopologyMismatch | delta.prdTopology /= expectedTopology]

    containedErrors =
      let missingVertices =
            Set.toAscList $
              Set.difference spec'.sgsTopology.relVertices delta.prdTopology.relVertices
          missingEdges =
            Set.toAscList $
              Set.difference spec'.sgsTopology.relEdges delta.prdTopology.relEdges
       in [RewriteWitnessInsertedVerticesMissing missingVertices | not (null missingVertices)]
            <> [RewriteWitnessInsertedEdgesMissing missingEdges | not (null missingEdges)]

    entryExitErrors =
      [ RewriteWitnessEntryNodesMismatch $
          ExpectedActual
            { eaExpected = spec'.sgsEntryNodes
            , eaActual = delta.prdEntryNodes
            }
      | delta.prdEntryNodes /= spec'.sgsEntryNodes
      ]
        <> [ RewriteWitnessExitNodesMismatch $
               ExpectedActual
                 { eaExpected = spec'.sgsExitNodes
                 , eaActual = delta.prdExitNodes
                 }
           | delta.prdExitNodes /= spec'.sgsExitNodes
           ]

    anchorDispositionErrors =
      [ RewriteWitnessAnchorDispositionMismatch $
          ExpectedActual
            { eaExpected = rewriteAnchorDisposition rewrite'
            , eaActual = delta.prdAnchorDisposition
            }
      | delta.prdAnchorDisposition /= rewriteAnchorDisposition rewrite'
      ]
        <> case delta.prdAnchorDisposition of
          RewriteAnchorRemoved ->
            [ RewriteWitnessRemovedAnchorPresent (rewriteAnchor rewrite')
            | Set.member (rewriteAnchor rewrite') delta.prdTopology.relVertices
            ]
          RewriteAnchorRetained ->
            [ RewriteWitnessRetainedAnchorMissing (rewriteAnchor rewrite')
            | not (Set.member (rewriteAnchor rewrite') delta.prdTopology.relVertices)
            ]

    topologyDiffErrors =
      [ RewriteWitnessNewNodesMismatch $
          ExpectedActual
            { eaExpected = expectedNewNodes
            , eaActual = delta.prdNewNodes
            }
      | delta.prdNewNodes /= expectedNewNodes
      ]
        <> [ RewriteWitnessRemovedNodesMismatch $
               ExpectedActual
                 { eaExpected = expectedRemovedNodes
                 , eaActual = delta.prdRemovedNodes
                 }
           | delta.prdRemovedNodes /= expectedRemovedNodes
           ]
        <> [ RewriteWitnessAddedEdgesMismatch $
               ExpectedActual
                 { eaExpected = expectedAddedEdges
                 , eaActual = delta.prdAddedEdges
                 }
           | delta.prdAddedEdges /= expectedAddedEdges
           ]

    definitionErrors =
      let actualDefinitionKeys = Map.keysSet delta.prdDefinitions
          topologyNodes = delta.prdTopology.relVertices
       in [ RewriteWitnessDefinitionUpdateMismatch $
              ExpectedActual
                { eaExpected = expectedDefinitionKeys
                , eaActual = actualDefinitionKeys
                }
          | actualDefinitionKeys /= expectedDefinitionKeys
          ]
            <> [ RewriteWitnessFinalDefinitionCoverageMismatch $
                   ExpectedActual
                     { eaExpected = topologyNodes
                     , eaActual = actualDefinitionKeys
                     }
               | actualDefinitionKeys /= topologyNodes
               ]

    costErrors =
      let expectedCost = plannedRewriteCost rewrite' delta
       in [ RewriteWitnessCostMismatch $
              ExpectedActual
                { eaExpected = expectedCost
                , eaActual = delta.prdCost
                }
          | delta.prdCost /= expectedCost
          ]

    finalAcyclicErrors =
      case validateDAG delta.prdTopology of
        Left err -> [RewriteWitnessFinalTopologyInvalid err]
        Right () -> []

plannedFinalDefinitionKeys :: GraphRewrite NodeId def -> Map NodeId def -> Set NodeId
plannedFinalDefinitionKeys rewrite defs =
  let spec = rewriteSpec rewrite
   in case rewriteAnchorDisposition rewrite of
        RewriteAnchorRemoved ->
          Set.delete (rewriteAnchor rewrite) (Map.keysSet defs) <> Map.keysSet spec.sgsDefinitions
        RewriteAnchorRetained ->
          Map.keysSet defs <> Map.keysSet spec.sgsDefinitions

plannedRewriteCost :: GraphRewrite NodeId def -> PlannedRewriteDelta def -> RewriteCost
plannedRewriteCost rewrite delta =
  -- Deliberately re-derive mkPlannedDelta's cost from delta state for the drift checker.
  let insertedDepthNodes =
        longestInsertedPathNodeCount
          (rewriteSpec rewrite).sgsTopology
          (rewriteSpec rewrite).sgsEntryNodes
          (rewriteSpec rewrite).sgsExitNodes
      addedDepth = case delta.prdAnchorDisposition of
        RewriteAnchorRemoved -> max 0 (insertedDepthNodes - 1)
        RewriteAnchorRetained -> insertedDepthNodes
   in RewriteCost
        { rcAddedNodes = fromIntegral (Set.size delta.prdNewNodes)
        , rcAddedEdges = fromIntegral (Set.size delta.prdAddedEdges)
        , rcAddedDepth = fromIntegral addedDepth
        , rcFrontierDelta = fromIntegral (max 0 (length delta.prdEntryNodes - 1))
        , rcRewriteOps = 1
        }

rewriteAnchor :: GraphRewrite NodeId def -> NodeId
rewriteAnchor = \case
  ExpandNode nid _ _ -> nid
  AppendAfter nid _ -> nid

rewriteSpec :: GraphRewrite NodeId def -> SubgraphSpec NodeId def
rewriteSpec = \case
  ExpandNode _ _ spec -> spec
  AppendAfter _ spec -> spec

rewriteAnchorDisposition :: GraphRewrite NodeId def -> RewriteAnchorDisposition
rewriteAnchorDisposition = \case
  ExpandNode _ ExpandReplaceNode _ -> RewriteAnchorRemoved
  ExpandNode _ ExpandRetainNodeAsEnvelope _ -> RewriteAnchorRetained
  AppendAfter _ _ -> RewriteAnchorRetained

plannedFinalDefinitions :: GraphRewrite NodeId def -> Map NodeId def -> Map NodeId def
plannedFinalDefinitions rewrite defs =
  let spec = rewriteSpec rewrite
   in case rewriteAnchorDisposition rewrite of
        RewriteAnchorRemoved -> Map.delete (rewriteAnchor rewrite) defs <> spec.sgsDefinitions
        RewriteAnchorRetained -> defs <> spec.sgsDefinitions

plannedFinalTopology :: GraphRewrite NodeId def -> Relation NodeId -> Relation NodeId
plannedFinalTopology rewrite topology =
  let anchor = rewriteAnchor rewrite
      spec = rewriteSpec rewrite
      succs = Set.toList (successors topology anchor)
      topoBase = plannedBaseTopology rewrite topology succs
      topoWithSub = topoBase <> spec.sgsTopology
      topoWithEntries = wireEntryEdges rewrite topology topoWithSub
   in wireExitEdges spec.sgsExitNodes succs topoWithEntries

plannedBaseTopology :: GraphRewrite NodeId def -> Relation NodeId -> [NodeId] -> Relation NodeId
plannedBaseTopology rewrite topology succs =
  let anchor = rewriteAnchor rewrite
   in case rewrite of
        ExpandNode _ ExpandReplaceNode _ -> removeVertex anchor topology
        ExpandNode _ ExpandRetainNodeAsEnvelope _ ->
          foldl' (flip (removeEdge anchor)) topology succs
        AppendAfter _ _ ->
          foldl' (flip (removeEdge anchor)) topology succs

wireEntryEdges :: GraphRewrite NodeId def -> Relation NodeId -> Relation NodeId -> Relation NodeId
wireEntryEdges rewrite oldTopology topology =
  let anchor = rewriteAnchor rewrite
      entries = (rewriteSpec rewrite).sgsEntryNodes
   in case rewriteAnchorDisposition rewrite of
        RewriteAnchorRemoved ->
          let preds = Set.toList (predecessors oldTopology anchor)
           in foldl' (\r p -> foldl' (flip (addEdge p)) r entries) topology preds
        RewriteAnchorRetained ->
          foldl' (flip (addEdge anchor)) topology entries

wireExitEdges :: [NodeId] -> [NodeId] -> Relation NodeId -> Relation NodeId
wireExitEdges exits succs topology =
  foldl' (\r e -> foldl' (flip (addEdge e)) r succs) topology exits

namespaceNodeId :: NodeId -> NodeId -> NodeId
namespaceNodeId (NodeId parent) (NodeId local) = NodeId (parent <> ":" <> local)

namespaceSubgraph :: NodeId -> SubgraphSpec NodeId def -> SubgraphSpec NodeId def
namespaceSubgraph parent spec =
  SubgraphSpec
    { sgsTopology = mapRelation (namespaceNodeId parent) spec.sgsTopology
    , sgsDefinitions = Map.mapKeys (namespaceNodeId parent) spec.sgsDefinitions
    , sgsEntryNodes = fmap (namespaceNodeId parent) spec.sgsEntryNodes
    , sgsExitNodes = fmap (namespaceNodeId parent) spec.sgsExitNodes
    }

validateNamespaceDiscipline
  :: Relation NodeId
  -> NodeId
  -> SubgraphSpec NodeId def
  -> Either [RewritePlanningError NodeId] ()
validateNamespaceDiscipline topology anchor spec =
  let localNodes = relVertices spec.sgsTopology
      badLocalNodes = Set.toList (Set.filter nodeIdInvalidLocalSegment localNodes)
      namespacedNodes = Set.map (namespaceNodeId anchor) localNodes
      collisions = Set.toList (Set.intersection namespacedNodes (relVertices topology))
      errors =
        [RewriteInvalidLocalNodeIds badLocalNodes | not (null badLocalNodes)]
          <> [RewriteNamespacedNodeCollision collisions | not (null collisions)]
   in if null errors then Right () else Left errors

nodeIdInvalidLocalSegment :: NodeId -> Bool
nodeIdInvalidLocalSegment (NodeId nodeId) =
  T.null nodeId || T.singleton ':' `T.isInfixOf` nodeId

validateRewriteAnchor
  :: Relation NodeId
  -> Map NodeId def
  -> NodeId
  -> Either [RewritePlanningError NodeId] ()
validateRewriteAnchor topology defs nid =
  let topologyNodes = relVertices topology
      definitionNodes = Map.keysSet defs
      missingDefinitions = Set.toList (Set.difference topologyNodes definitionNodes)
      extraDefinitions = Set.toList (Set.difference definitionNodes topologyNodes)
      errors =
        [RewriteCurrentDefinitionsMissing missingDefinitions | not (null missingDefinitions)]
          <> [RewriteCurrentDefinitionsOutsideTopology extraDefinitions | not (null extraDefinitions)]
          <> [RewriteAnchorMissingFromTopology nid | not (Set.member nid topologyNodes)]
          <> [RewriteAnchorMissingDefinition nid | not (Map.member nid defs)]
   in if null errors then Right () else Left errors

validateSubgraphSpec
  :: SubgraphSpec NodeId def
  -> Either [RewritePlanningError NodeId] ()
validateSubgraphSpec spec =
  let insertedNodes = spec.sgsTopology.relVertices
      definitionNodes = Map.keysSet spec.sgsDefinitions
      missingDefinitions = Set.toList (Set.difference insertedNodes definitionNodes)
      extraDefinitions = Set.toList (Set.difference definitionNodes insertedNodes)
      entryNodes = Set.fromList spec.sgsEntryNodes
      exitNodes = Set.fromList spec.sgsExitNodes
      duplicateEntries = duplicateValues spec.sgsEntryNodes
      duplicateExits = duplicateValues spec.sgsExitNodes
      badEntries = Set.toList (Set.difference entryNodes insertedNodes)
      badExits = Set.toList (Set.difference exitNodes insertedNodes)
      reachableFromEntries =
        reachableFrom spec.sgsTopology spec.sgsEntryNodes
      reachesExit =
        reachableFrom (transposeRelation spec.sgsTopology) spec.sgsExitNodes
      orphanNodes =
        Set.toList
          (Set.difference insertedNodes (Set.intersection reachableFromEntries reachesExit))
      errors =
        concat
          [ [RewriteTopologyEmpty | Set.null insertedNodes]
          , [RewriteDefinitionsMissing missingDefinitions | not (null missingDefinitions)]
          , [RewriteDefinitionsOutsideTopology extraDefinitions | not (null extraDefinitions)]
          , [RewriteEntryNodesMissing | null spec.sgsEntryNodes]
          , [RewriteExitNodesMissing | null spec.sgsExitNodes]
          , [RewriteDuplicateEntryNodes duplicateEntries | not (null duplicateEntries)]
          , [RewriteDuplicateExitNodes duplicateExits | not (null duplicateExits)]
          , [RewriteEntryNodesOutsideTopology badEntries | not (null badEntries)]
          , [RewriteExitNodesOutsideTopology badExits | not (null badExits)]
          , [RewriteOrphanNodes orphanNodes | not (null orphanNodes)]
          ]
   in case validateDAG spec.sgsTopology of
        Left err -> Left (RewriteInvalidTopology err : errors)
        Right () ->
          if null errors then Right () else Left errors

duplicateValues :: Ord a => [a] -> [a]
duplicateValues = reverse . go Set.empty Set.empty []
  where
    go _seen _emitted acc [] = acc
    go seen emitted acc (value : values)
      | Set.member value emitted = go seen emitted acc values
      | Set.member value seen =
          go seen (Set.insert value emitted) (value : acc) values
      | otherwise =
          go (Set.insert value seen) emitted acc values

{- | Longest path node count from any entry to any exit in the subgraph.

Folds the transposed relation so that predecessor values in the fold
correspond to successor values in the original graph, giving longest
path from each node to any sink.  Exit-reachability is precomputed
via a single reverse traversal from all exits.  O(|V| + |E|).
-}
longestInsertedPathNodeCount :: Relation NodeId -> [NodeId] -> [NodeId] -> Int
longestInsertedPathNodeCount rel entryNodes exitNodes =
  case (entryNodes, exitNodes) of
    ([], _) -> 0
    (_, []) -> 0
    _ ->
      case foldTopSort step (transposeRelation rel) of
        Nothing -> 0
        Just (_, dpMap) ->
          let canReachExit = reachableFrom (transposeRelation rel) exitNodes
           in maximum
                (0 : [Map.findWithDefault 0 entry dpMap | entry <- entryNodes, Set.member entry canReachExit])
  where
    step _ predVals
      | Map.null predVals = 1
      | otherwise = 1 + maximum (Map.elems predVals)
