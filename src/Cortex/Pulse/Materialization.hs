{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Pulse.Materialization
  ( PersistedRewrite (..),
    PersistedGraphState (..),
    NodeProvenanceEntry (..),
    NodeProvenance,
    applyPlannedRewrite,
    computeTopologyHash,
    decodeOptionalJsonValue,
    hydratePersistedRewriteRow,
    hydratePersistedRewriteRowForAdmin,
    initialProvenance,
    resolveRewriteDeltaAndCost,
    reconcileGraphState,
    rewriteDeltaSummaryJson,
    materializeRewrite,
  )
where

import Control.Monad (when)
import Cortex.Algebra.Graph
  ( Relation (..),
    relEdges,
    relVertices,
  )
import Cortex.Pulse.Hydrate
  ( RewriteError (..),
    SerializableStageDefinition (..),
    decodeSerializableRewrite,
    hydrateRewrite,
    planRewriteDelta,
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StableStageId,
    StageAction,
    StageDefinition (..),
    StagePlan (..),
  )
import Cortex.Pulse.Rewrite
  ( GraphRewrite (..),
    PlannedRewriteDelta (..),
    RewriteAnchorDisposition (..),
    RewriteBudget,
    RewriteCost,
    admitRewriteDelta,
    admittedDelta,
    admittedRemainingBudget,
  )
import Cortex.Pulse.Runtime
  ( GraphState (..),
    NodeStatus (..),
  )
import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (bimap, first)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data PersistedRewrite stageId = PersistedRewrite
  { prRewriteId :: Int64,
    prSourceNodeId :: NodeId,
    prSourceNodeOutput :: Maybe Aeson.Value,
    prRewriteCost :: Maybe RewriteCost,
    prRewrite :: GraphRewrite NodeId (StageDefinition stageId)
  }

-- | Per-node provenance entry tracking which rewrite introduced a node.
-- Initial plan nodes have 'Nothing' for both fields.
data NodeProvenanceEntry = NodeProvenanceEntry
  { npeIntroducedByRewriteId :: Maybe Int64,
    npeAnchorNodeId :: Maybe NodeId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Map from each node to its provenance (which rewrite introduced it).
type NodeProvenance = Map.Map NodeId NodeProvenanceEntry

data PersistedGraphState = PersistedGraphState
  { pgsGraphState :: GraphState Aeson.Value,
    pgsRemainingRewriteBudget :: RewriteBudget,
    pgsAppliedRewriteId :: Maybe Int64,
    pgsNodeProvenance :: NodeProvenance,
    pgsTopologyHash :: Maybe Text
  }
  deriving stock (Eq, Show)

applyPlannedRewrite ::
  PlannedRewriteDelta (StageDefinition stageId) ->
  StagePlan stageId ->
  StagePlan stageId
applyPlannedRewrite delta plan =
  plan
    { spTopology = delta.prdTopology,
      spDefinitions = delta.prdDefinitions,
      spTemplateRegistry = plan.spTemplateRegistry
    }

-- | Build initial provenance for a plan's topology. All nodes get 'Nothing'
-- origin since they are part of the original plan, not introduced by a rewrite.
initialProvenance :: Relation NodeId -> NodeProvenance
initialProvenance topology =
  Map.fromSet (const (NodeProvenanceEntry Nothing Nothing)) (relVertices topology)

-- | Compute a deterministic topology hash from sorted node IDs and sorted edge
-- pairs. Used as an integrity witness: if the persisted hash differs from the
-- hash recomputed during resume, the materialized state and lineage diverge.
computeTopologyHash :: Relation NodeId -> Text
computeTopologyHash topology =
  let nodes = fmap unNodeId (Set.toAscList (relVertices topology))
      edges = fmap (bimap unNodeId unNodeId) (Set.toAscList (relEdges topology))
      canonical = Aeson.encode (nodes, edges)
      digest = hashlazy @SHA256 canonical
   in T.pack (show digest)

decodeJsonValue :: (Aeson.FromJSON a) => Text -> Aeson.Value -> Either Text a
decodeJsonValue label value =
  case Aeson.fromJSON value of
    Aeson.Success decoded -> Right decoded
    Aeson.Error err ->
      Left ("Failed to decode " <> label <> ": " <> T.pack err)

decodeOptionalJsonValue :: (Aeson.FromJSON a) => Text -> Maybe Aeson.Value -> Either Text (Maybe a)
decodeOptionalJsonValue label = traverse (decodeJsonValue label)

hydratePersistedRewriteRow ::
  (StableStageId stageId) =>
  StagePlan stageId ->
  (Int64, Text, Maybe Aeson.Value, Maybe Aeson.Value, Aeson.Value) ->
  Either RewriteError (PersistedRewrite stageId)
hydratePersistedRewriteRow plan (rewriteId, sourceNodeIdText, sourceNodeOutput, rewriteCostJson, rewriteValue) = do
  serializableRewrite <- first RewriteHydrationFailed $ decodeSerializableRewrite rewriteValue
  hydratedRewrite <- first RewriteHydrationFailed $ hydrateRewrite plan.spTemplateRegistry serializableRewrite
  rewriteCost <- first RewriteHydrationFailed $ decodeOptionalJsonValue "persisted rewrite cost" rewriteCostJson
  pure
    PersistedRewrite
      { prRewriteId = rewriteId,
        prSourceNodeId = NodeId sourceNodeIdText,
        prSourceNodeOutput = sourceNodeOutput,
        prRewriteCost = rewriteCost,
        prRewrite = hydratedRewrite
      }

-- | Hydrate a rewrite for admin topology materialization only.
--
-- The admin graph view only needs node ids and edges. It must be able to
-- replay organic rewrites whose prompt-specific stage definitions were
-- persisted with local template ids that are not present in the initial
-- executable template registry. These placeholder actions are never executed.
hydratePersistedRewriteRowForAdmin ::
  (StableStageId stageId) =>
  (Int64, Text, Maybe Aeson.Value, Maybe Aeson.Value, Aeson.Value) ->
  Either RewriteError (PersistedRewrite stageId)
hydratePersistedRewriteRowForAdmin (rewriteId, sourceNodeIdText, sourceNodeOutput, rewriteCostJson, rewriteValue) = do
  serializableRewrite <- first RewriteHydrationFailed $ decodeSerializableRewrite rewriteValue
  rewriteCost <- first RewriteHydrationFailed $ decodeOptionalJsonValue "persisted rewrite cost" rewriteCostJson
  pure
    PersistedRewrite
      { prRewriteId = rewriteId,
        prSourceNodeId = NodeId sourceNodeIdText,
        prSourceNodeOutput = sourceNodeOutput,
        prRewriteCost = rewriteCost,
        prRewrite = fmap adminStageDefinition serializableRewrite
      }
  where
    adminStageDefinition ssd =
      StageDefinition
        { sdStageId = ssd.ssdStageId,
          sdTemplateId = ssd.ssdTemplateId,
          sdActionId = ssd.ssdActionId,
          sdReplaySafety = ssd.ssdReplaySafety,
          sdReplayPolicyOverride = ssd.ssdReplayPolicyOverride,
          sdTimeoutSeconds = ssd.ssdTimeoutSeconds,
          sdRetryPolicy = ssd.ssdRetryPolicy,
          sdAction = adminOnlyStagePlaceholderAction,
          sdMemoryStrategy = defaultMemoryStrategy
        }

adminOnlyStagePlaceholderAction :: StageAction stageId
adminOnlyStagePlaceholderAction _ =
  ioError (userError "Cortex.Pulse.Materialization: admin-only rewritten stage placeholder must not execute")

resolveRewriteDeltaAndCost ::
  (Eq stageId) =>
  PersistedRewrite stageId ->
  StagePlan stageId ->
  Either RewriteError (PlannedRewriteDelta (StageDefinition stageId), RewriteCost)
resolveRewriteDeltaAndCost persistedRewrite plan = do
  delta <- first RewriteValidationFailed (planRewriteDelta persistedRewrite.prRewrite plan)
  pure (delta, fromMaybe delta.prdCost persistedRewrite.prRewriteCost)

resolveRewriteSourceOutput ::
  PersistedRewrite stageId ->
  GraphState Aeson.Value ->
  Maybe Aeson.Value
resolveRewriteSourceOutput persistedRewrite gs =
  case persistedRewrite.prSourceNodeOutput of
    Just output -> Just output
    Nothing -> Map.lookup persistedRewrite.prSourceNodeId gs.gsNodeOutputs

rewriteDeltaSummaryJson :: PlannedRewriteDelta def -> Aeson.Value
rewriteDeltaSummaryJson delta =
  Aeson.object
    [ "anchor_node" Aeson..= unNodeId delta.prdAnchorNode,
      "anchor_disposition" Aeson..= show delta.prdAnchorDisposition,
      "new_nodes" Aeson..= fmap unNodeId (Set.toList delta.prdNewNodes),
      "removed_nodes" Aeson..= fmap unNodeId (Set.toList delta.prdRemovedNodes),
      "added_edges"
        Aeson..= fmap
          (\(fromNode, toNode) -> Aeson.object ["from" Aeson..= unNodeId fromNode, "to" Aeson..= unNodeId toNode])
          (Set.toList delta.prdAddedEdges),
      "entry_nodes" Aeson..= fmap unNodeId delta.prdEntryNodes,
      "exit_nodes" Aeson..= fmap unNodeId delta.prdExitNodes
    ]

reconcileGraphState ::
  Relation NodeId ->
  GraphState Aeson.Value ->
  Either RewriteError (GraphState Aeson.Value)
reconcileGraphState topology gs =
  let topologyNodes = relVertices topology
      statusNodes = Map.keysSet gs.gsNodeStatuses
      unknownNodes = Set.difference statusNodes topologyNodes
      missingNodes = Set.difference topologyNodes statusNodes
   in if not (Set.null unknownNodes)
        then
          Left . RewriteReconciliationFailed $
            "Persisted graph state references nodes outside the rebuilt topology: "
              <> T.intercalate ", " (fmap unNodeId (Set.toList unknownNodes))
        else
          Right $
            gs
              { gsNodeStatuses =
                  gs.gsNodeStatuses
                    <> Map.fromSet (const NodePending) missingNodes
              }

materializeRewrite ::
  (Eq stageId) =>
  PersistedRewrite stageId ->
  StagePlan stageId ->
  PersistedGraphState ->
  Either RewriteError (StagePlan stageId, PersistedGraphState)
materializeRewrite persistedRewrite stagePlan persistedState = do
  (delta, _rewriteCost) <- resolveRewriteDeltaAndCost persistedRewrite stagePlan
  admitted <-
    first RewriteBudgetExhausted $
      admitRewriteDelta persistedState.pgsRemainingRewriteBudget delta
  let admDelta = admittedDelta admitted
      gs = persistedState.pgsGraphState
      sourceOutput = resolveRewriteSourceOutput persistedRewrite gs
      requiresAnchorOutput = admDelta.prdAnchorDisposition == RewriteAnchorRetained
  when (requiresAnchorOutput && isNothing sourceOutput)
    . Left
    . RewriteHydrationFailed
    $ "Missing persisted anchor output for retained rewrite anchor "
      <> unNodeId persistedRewrite.prSourceNodeId
  let anchorStatuses =
        Map.insert persistedRewrite.prSourceNodeId NodeRewritten gs.gsNodeStatuses
      anchorOutputs =
        maybe
          gs.gsNodeOutputs
          (\output -> Map.insert persistedRewrite.prSourceNodeId output gs.gsNodeOutputs)
          sourceOutput
      cleanStatuses = Map.withoutKeys anchorStatuses admDelta.prdRemovedNodes
      cleanOutputs = Map.withoutKeys anchorOutputs admDelta.prdRemovedNodes
      pendingStatuses = Map.fromSet (const NodePending) admDelta.prdNewNodes
      gs' =
        gs
          { gsNodeStatuses = cleanStatuses <> pendingStatuses,
            gsNodeOutputs = cleanOutputs
          }
      newNodeProvenance =
        Map.fromSet
          ( const
              NodeProvenanceEntry
                { npeIntroducedByRewriteId = Just persistedRewrite.prRewriteId,
                  npeAnchorNodeId = Just persistedRewrite.prSourceNodeId
                }
          )
          admDelta.prdNewNodes
      updatedProvenance =
        Map.withoutKeys persistedState.pgsNodeProvenance admDelta.prdRemovedNodes
          <> newNodeProvenance
      stagePlan' = applyPlannedRewrite admDelta stagePlan
      persistedState' =
        persistedState
          { pgsGraphState = gs',
            pgsRemainingRewriteBudget = admittedRemainingBudget admitted,
            pgsAppliedRewriteId = Just persistedRewrite.prRewriteId,
            pgsNodeProvenance = updatedProvenance,
            pgsTopologyHash = Just (computeTopologyHash stagePlan'.spTopology)
          }
  pure (stagePlan', persistedState')
