{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Pulse.Rewrite
  ( GraphRewrite (..),
    ExpansionMode (..),
    SubgraphSpec (..),
    RewriteBudget (..),
    RewriteCost (..),
    BudgetDimension (..),
    ExceededDimension (..),
    RewriteBudgetError (..),
    exceededDimensions,
    RewritePlanningError (..),
    RewriteAnchorDisposition (..),
    PlannedRewriteDelta (..),
    AdmittedRewriteDelta,
    admitRewriteDelta,
    admittedDelta,
    admittedRemainingBudget,
    planGraphRewrite,
    consumeRewriteBudget,
    BudgetContext (..),
    budgetFraction,
    lookupDimension,
    RewriteRejectionContext (..),
  )
where

import Cortex.Algebra.Graph
  ( Relation (..),
    ValidationError (..),
    addEdge,
    foldTopSort,
    mapRelation,
    predecessors,
    reachableFrom,
    relVertices,
    relationDiff,
    removeEdge,
    removeVertex,
    successors,
    transposeRelation,
    validateDAG,
  )
import Cortex.Pulse.Node (NodeId (..))
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

-- | A rewrite fragment. Entry and exit lists are the serialized form of proof-side sets;
-- validation rejects duplicates before planning.
data SubgraphSpec a def = SubgraphSpec
  { sgsTopology :: Relation a,
    sgsDefinitions :: Map a def,
    sgsEntryNodes :: [a],
    sgsExitNodes :: [a]
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

-- | Remaining structural rewrite budget. Dimensions are natural quantities, matching the
-- proof-side `RewriteBudget`.
data RewriteBudget = RewriteBudget
  { rbAddedNodesMax :: !Natural,
    rbAddedEdgesMax :: !Natural,
    rbAddedDepthMax :: !Natural,
    rbFrontierDeltaMax :: !Natural,
    rbRewriteOpsMax :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Structural rewrite cost. A cost is a proof-side natural vector, so negative costs are rejected
-- at JSON decoding and cannot reach budget admission.
data RewriteCost = RewriteCost
  { rcAddedNodes :: !Natural,
    rcAddedEdges :: !Natural,
    rcAddedDepth :: !Natural,
    rcFrontierDelta :: !Natural,
    rcRewriteOps :: !Natural
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
  { edDimension :: !BudgetDimension,
    edRequested :: !Natural,
    edRemaining :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Budget context provided to every node at execution time.
data BudgetContext = BudgetContext
  { bcInitialBudget :: !RewriteBudget,
    bcRemainingBudget :: !RewriteBudget
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
  { rrcRejectionType :: !Text,
    rrcMessage :: !Text,
    rrcExceededDimensions :: ![ExceededDimension],
    rrcBudgetContext :: !BudgetContext,
    rrcAttemptedCost :: !(Maybe RewriteCost),
    rrcAttemptNumber :: !Int
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
      [ (DimAddedNodes, rcAddedNodes cost, rbAddedNodesMax budget),
        (DimAddedEdges, rcAddedEdges cost, rbAddedEdgesMax budget),
        (DimAddedDepth, rcAddedDepth cost, rbAddedDepthMax budget),
        (DimFrontierDelta, rcFrontierDelta cost, rbFrontierDeltaMax budget),
        (DimRewriteOps, rcRewriteOps cost, rbRewriteOpsMax budget)
      ],
    req > rem'
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
  { prdTopology :: !(Relation NodeId),
    prdDefinitions :: !(Map NodeId def),
    prdNewNodes :: !(Set NodeId),
    prdRemovedNodes :: !(Set NodeId),
    prdAddedEdges :: !(Set (NodeId, NodeId)),
    prdEntryNodes :: ![NodeId],
    prdExitNodes :: ![NodeId],
    prdAnchorNode :: !NodeId,
    prdAnchorDisposition :: !RewriteAnchorDisposition,
    prdCost :: !RewriteCost
  }
  deriving stock (Eq, Show, Generic, Functor)
  deriving anyclass (FromJSON, ToJSON)

-- | Witness that a rewrite delta has been admitted against a budget.
-- The constructor is not exported — the only way to obtain an
-- 'AdmittedRewriteDelta' is through 'admitRewriteDelta'.
data AdmittedRewriteDelta def = AdmittedRewriteDelta
  { ardDelta :: PlannedRewriteDelta def,
    ardRemainingBudget :: RewriteBudget
  }
  deriving stock (Eq, Show, Generic)

-- | Validate that a planned rewrite delta fits within the remaining budget.
-- On success, returns an 'AdmittedRewriteDelta' witness bundling the delta
-- with the decremented budget.
admitRewriteDelta :: RewriteBudget -> PlannedRewriteDelta def -> Either RewriteBudgetError (AdmittedRewriteDelta def)
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
          { rbAddedNodesMax = rbAddedNodesMax budget - rcAddedNodes cost,
            rbAddedEdgesMax = rbAddedEdgesMax budget - rcAddedEdges cost,
            rbAddedDepthMax = rbAddedDepthMax budget - rcAddedDepth cost,
            rbFrontierDeltaMax = rbFrontierDeltaMax budget - rcFrontierDelta cost,
            rbRewriteOpsMax = rbRewriteOpsMax budget - rcRewriteOps cost
          }

planGraphRewrite ::
  GraphRewrite NodeId def ->
  Relation NodeId ->
  Map NodeId def ->
  Either [RewritePlanningError NodeId] (PlannedRewriteDelta def)
planGraphRewrite rewrite topology defs = case rewrite of
  ExpandNode nid mode spec -> do
    validateRewriteAnchor topology defs nid
    validateSubgraphSpec spec
    validateNamespaceDiscipline topology nid spec
    let spec' = namespaceSubgraph nid spec
        rewrite' = ExpandNode nid mode spec'
        topoFinal = plannedFinalTopology rewrite' topology
        defs' = plannedFinalDefinitions rewrite' defs
    first (pure . RewriteInvalidTopology) (validateDAG topoFinal) >>= \() ->
      pure (mkPlannedDelta rewrite' topology defs' topoFinal)
  AppendAfter nid spec -> do
    validateRewriteAnchor topology defs nid
    validateSubgraphSpec spec
    validateNamespaceDiscipline topology nid spec
    let spec' = namespaceSubgraph nid spec
        rewrite' = AppendAfter nid spec'
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
              { rcAddedNodes = fromIntegral (Set.size newNodes),
                rcAddedEdges = fromIntegral (Set.size addedEdges),
                rcAddedDepth = fromIntegral addedDepth,
                rcFrontierDelta = fromIntegral (max 0 (length spec'.sgsEntryNodes - 1)),
                rcRewriteOps = 1
              }
       in PlannedRewriteDelta
            { prdTopology = topoFinal,
              prdDefinitions = defs',
              prdNewNodes = newNodes,
              prdRemovedNodes = removedNodes,
              prdAddedEdges = addedEdges,
              prdEntryNodes = spec'.sgsEntryNodes,
              prdExitNodes = spec'.sgsExitNodes,
              prdAnchorNode = rewriteAnchor rewrite',
              prdAnchorDisposition = anchorDisposition,
              prdCost = cost
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
    { sgsTopology = mapRelation (namespaceNodeId parent) spec.sgsTopology,
      sgsDefinitions = Map.mapKeys (namespaceNodeId parent) spec.sgsDefinitions,
      sgsEntryNodes = fmap (namespaceNodeId parent) spec.sgsEntryNodes,
      sgsExitNodes = fmap (namespaceNodeId parent) spec.sgsExitNodes
    }

validateNamespaceDiscipline ::
  Relation NodeId ->
  NodeId ->
  SubgraphSpec NodeId def ->
  Either [RewritePlanningError NodeId] ()
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

validateRewriteAnchor ::
  Relation NodeId ->
  Map NodeId def ->
  NodeId ->
  Either [RewritePlanningError NodeId] ()
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

validateSubgraphSpec ::
  SubgraphSpec NodeId def ->
  Either [RewritePlanningError NodeId] ()
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
          [ [RewriteTopologyEmpty | Set.null insertedNodes],
            [RewriteDefinitionsMissing missingDefinitions | not (null missingDefinitions)],
            [RewriteDefinitionsOutsideTopology extraDefinitions | not (null extraDefinitions)],
            [RewriteEntryNodesMissing | null spec.sgsEntryNodes],
            [RewriteExitNodesMissing | null spec.sgsExitNodes],
            [RewriteDuplicateEntryNodes duplicateEntries | not (null duplicateEntries)],
            [RewriteDuplicateExitNodes duplicateExits | not (null duplicateExits)],
            [RewriteEntryNodesOutsideTopology badEntries | not (null badEntries)],
            [RewriteExitNodesOutsideTopology badExits | not (null badExits)],
            [RewriteOrphanNodes orphanNodes | not (null orphanNodes)]
          ]
   in case validateDAG spec.sgsTopology of
        Left err -> Left (RewriteInvalidTopology err : errors)
        Right () ->
          if null errors then Right () else Left errors

duplicateValues :: (Ord a) => [a] -> [a]
duplicateValues = reverse . go Set.empty Set.empty []
  where
    go _seen _emitted acc [] = acc
    go seen emitted acc (value : values)
      | Set.member value emitted = go seen emitted acc values
      | Set.member value seen =
          go seen (Set.insert value emitted) (value : acc) values
      | otherwise =
          go (Set.insert value seen) emitted acc values

-- | Longest path node count from any entry to any exit in the subgraph.
--
-- Folds the transposed relation so that predecessor values in the fold
-- correspond to successor values in the original graph, giving longest
-- path from each node to any sink.  Exit-reachability is precomputed
-- via a single reverse traversal from all exits.  O(|V| + |E|).
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
           in maximum (0 : [Map.findWithDefault 0 entry dpMap | entry <- entryNodes, Set.member entry canReachExit])
  where
    step _ predVals
      | Map.null predVals = 1
      | otherwise = 1 + maximum (Map.elems predVals)
