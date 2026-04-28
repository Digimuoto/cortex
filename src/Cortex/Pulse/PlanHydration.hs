module Cortex.Pulse.PlanHydration
  ( RewriteValidationError (..)
  , RewriteError (..)
  , renderRewriteError
  , rewriteErrorType
  , SerializableStageDefinition (..)
  , decodeSerializableRewrite
  , hydrateRewrite
  , buildStageTemplateRegistry
  , renderRewriteValidationError
  , renderRewriteBudgetError
  , planRewriteDelta
  , toSerializableStageDefinition
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Functor (($>))
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Pulse.Node
  ( NodeId (..)
  )
import Cortex.Pulse.Plan
  ( ReplayPolicy
  , StageActionId (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety
  , StageRetryPolicy
  , StageTemplateId (..)
  , buildStageTemplateRegistry
  )
import Cortex.Pulse.Rewrite
  ( ExceededDimension (..)
  , GraphRewrite (..)
  , PlannedRewriteDelta (..)
  , RewriteBudgetError (..)
  , RewritePlanningError (..)
  , SubgraphSpec (..)
  , exceededDimensions
  , planGraphRewrite
  )

data RewriteValidationError
  = RewritePlanningIssue (RewritePlanningError NodeId)
  | RewriteDuplicateTemplate Text
  deriving stock (Eq, Show)

{- | Structured error for rewrite subsystem boundaries. Preserves error
category through the executor pipeline instead of collapsing to Text.
-}
data RewriteError
  = RewriteValidationFailed [RewriteValidationError]
  | RewriteBudgetExhausted RewriteBudgetError
  | RewriteHydrationFailed Text
  | RewriteReconciliationFailed Text
  deriving stock (Eq, Show)

-- | Human-readable rendering of a 'RewriteError'.
renderRewriteError :: RewriteError -> Text
renderRewriteError = \case
  RewriteValidationFailed errs -> renderRewriteValidationError errs
  RewriteBudgetExhausted budgetErr -> renderRewriteBudgetError budgetErr
  RewriteHydrationFailed msg -> msg
  RewriteReconciliationFailed msg -> msg

{- | Stable error type string for observability. These values appear in
dashboards and must not change without coordination.
-}
rewriteErrorType :: RewriteError -> Text
rewriteErrorType = \case
  RewriteValidationFailed {} -> "invalid_rewrite"
  RewriteBudgetExhausted {} -> "rewrite_budget_exceeded"
  RewriteHydrationFailed {} -> "graph_rewrite_hydration_failed"
  RewriteReconciliationFailed {} -> "graph_state_parse_failed"

decodeSerializableRewrite
  :: Aeson.FromJSON stageId
  => Aeson.Value
  -> Either Text (GraphRewrite NodeId (SerializableStageDefinition stageId))
decodeSerializableRewrite val =
  case Aeson.fromJSON val of
    Aeson.Success rewrite ->
      Right rewrite
    Aeson.Error err ->
      Left ("Failed to decode persisted graph rewrite: " <> T.pack err)

hydrateRewrite
  :: Map StageTemplateId (StageDefinition stageId)
  -> GraphRewrite NodeId (SerializableStageDefinition stageId)
  -> Either Text (GraphRewrite NodeId (StageDefinition stageId))
hydrateRewrite templateRegistry rewrite =
  case rewrite of
    ExpandNode nid mode spec ->
      ExpandNode nid mode <$> hydrateSubgraph templateRegistry spec
    AppendAfter nid spec ->
      AppendAfter nid <$> hydrateSubgraph templateRegistry spec
  where
    hydrateSubgraph registry spec = do
      defs <- traverse hydrateDef spec.sgsDefinitions
      pure spec {sgsDefinitions = defs}
      where
        hydrateDef ssd = do
          templateDef <- lookupTemplateDef registry ssd.ssdTemplateId ssd.ssdActionId
          pure
            StageDefinition
              { sdStageId = ssd.ssdStageId
              , sdTemplateId = ssd.ssdTemplateId
              , sdActionId = templateDef.sdActionId
              , sdReplaySafety = ssd.ssdReplaySafety
              , sdReplayPolicyOverride = ssd.ssdReplayPolicyOverride
              , sdTimeoutSeconds = ssd.ssdTimeoutSeconds
              , sdRetryPolicy = templateDef.sdRetryPolicy
              , sdAction = templateDef.sdAction
              , -- DIG-530: inherit the memory strategy from the
                -- template definition.  The wire's @memory = …@
                -- declaration lands on the template; rewritten
                -- stages that replay from persistence pick up the
                -- same strategy the original authored node had, so
                -- a reclaimed reviewer doesn't silently drop back
                -- to MemoryClassic.
                sdMemoryStrategy = templateDef.sdMemoryStrategy
              }

lookupTemplateDef
  :: Map StageTemplateId (StageDefinition stageId)
  -> StageTemplateId
  -> StageActionId
  -> Either Text (StageDefinition stageId)
lookupTemplateDef templateRegistry templateId actionId =
  case Map.lookup templateId templateRegistry of
    Just sd
      | sd.sdActionId == actionId ->
          Right sd
      | otherwise ->
          Left $
            "Stage template/action mismatch for rewritten template "
              <> unStageTemplateId templateId
              <> ": serialized action "
              <> unStageActionId actionId
              <> " does not match registry action "
              <> unStageActionId sd.sdActionId
    Nothing ->
      Left $
        "No stage template definition found for rewritten template "
          <> unStageTemplateId templateId

renderRewriteValidationError :: [RewriteValidationError] -> Text
renderRewriteValidationError errs = T.intercalate "; " (fmap renderOne errs)
  where
    renderOne = \case
      RewritePlanningIssue (RewriteInvalidTopology err) ->
        "Rewrite produced invalid graph: " <> T.pack (show err)
      RewritePlanningIssue (RewriteAnchorMissingFromTopology nid) ->
        "Rewrite anchor node is outside the current topology: " <> unNodeId nid
      RewritePlanningIssue (RewriteAnchorMissingDefinition nid) ->
        "Rewrite anchor node is missing a stage definition: " <> unNodeId nid
      RewritePlanningIssue (RewriteCurrentDefinitionsMissing nodes) ->
        "Current topology is missing stage definitions for: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteCurrentDefinitionsOutsideTopology nodes) ->
        "Current stage definitions contain nodes outside the topology: " <> showNodeIds nodes
      RewritePlanningIssue RewriteTopologyEmpty ->
        "Rewrite subgraph must insert at least one node"
      RewritePlanningIssue (RewriteDefinitionsMissing nodes) ->
        "Rewrite subgraph is missing stage definitions for: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteDefinitionsOutsideTopology nodes) ->
        "Rewrite defines stages outside the inserted topology: " <> showNodeIds nodes
      RewritePlanningIssue RewriteEntryNodesMissing ->
        "Rewrite subgraph must declare at least one entry node"
      RewritePlanningIssue RewriteExitNodesMissing ->
        "Rewrite subgraph must declare at least one exit node"
      RewritePlanningIssue (RewriteDuplicateEntryNodes nodes) ->
        "Rewrite subgraph declares duplicate entry nodes: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteDuplicateExitNodes nodes) ->
        "Rewrite subgraph declares duplicate exit nodes: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteEntryNodesOutsideTopology nodes) ->
        "Rewrite entry nodes are outside the inserted topology: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteExitNodesOutsideTopology nodes) ->
        "Rewrite exit nodes are outside the inserted topology: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteInvalidLocalNodeIds nodes) ->
        "Rewrite local node ids must be non-empty and must not contain namespace delimiter ':': "
          <> showNodeIds nodes
      RewritePlanningIssue (RewriteNamespacedNodeCollision nodes) ->
        "Rewrite namespaced nodes collide with existing topology: " <> showNodeIds nodes
      RewritePlanningIssue (RewriteOrphanNodes nodes) ->
        "Rewrite subgraph contains orphan nodes: " <> showNodeIds nodes
      RewriteDuplicateTemplate msg ->
        "Duplicate stage template definition found: " <> msg

renderRewriteBudgetError :: RewriteBudgetError -> Text
renderRewriteBudgetError budgetErr@(RewriteBudgetExceeded remaining requested) =
  "Rewrite exceeded remaining budget. requested="
    <> T.pack (show requested)
    <> "; remaining="
    <> T.pack (show remaining)
    <> "; exceeded_dimensions=["
    <> T.intercalate ", " (fmap renderExceeded (exceededDimensions budgetErr))
    <> "]"
  where
    renderExceeded dim =
      T.pack (show dim.edDimension)
        <> "(requested="
        <> T.pack (show dim.edRequested)
        <> ", remaining="
        <> T.pack (show dim.edRemaining)
        <> ")"

planRewriteDelta
  :: Eq stageId
  => GraphRewrite NodeId (StageDefinition stageId)
  -> StagePlan stageId
  -> Either [RewriteValidationError] (PlannedRewriteDelta (StageDefinition stageId))
planRewriteDelta rewrite plan = do
  delta <-
    first (fmap RewritePlanningIssue) $
      planGraphRewrite rewrite plan.spTopology plan.spDefinitions
  first (pure . RewriteDuplicateTemplate) (buildStageTemplateRegistry delta.prdDefinitions) $> ()
  pure delta

data SerializableStageDefinition stageId = SerializableStageDefinition
  { ssdStageId :: stageId
  , ssdTemplateId :: StageTemplateId
  , ssdActionId :: StageActionId
  , ssdReplaySafety :: StageReplaySafety
  , ssdReplayPolicyOverride :: Maybe ReplayPolicy
  , ssdTimeoutSeconds :: Maybe Int32
  , ssdRetryPolicy :: Maybe StageRetryPolicy
  }
  deriving stock (Eq, Show, Generic)

instance Aeson.FromJSON stageId => Aeson.FromJSON (SerializableStageDefinition stageId) where
  parseJSON = Aeson.withObject "SerializableStageDefinition" $ \o -> do
    ssdStageId <- o Aeson..: "ssdStageId"
    ssdTemplateId <- o Aeson..: "ssdTemplateId"
    ssdActionId <-
      o
        Aeson..:? "ssdActionId"
        Aeson..!= StageActionId (unStageTemplateId ssdTemplateId)
    ssdReplaySafety <- o Aeson..: "ssdReplaySafety"
    ssdReplayPolicyOverride <- o Aeson..:? "ssdReplayPolicyOverride"
    ssdTimeoutSeconds <- o Aeson..:? "ssdTimeoutSeconds"
    ssdRetryPolicy <- o Aeson..:? "ssdRetryPolicy"
    pure
      SerializableStageDefinition
        { ssdStageId = ssdStageId
        , ssdTemplateId = ssdTemplateId
        , ssdActionId = ssdActionId
        , ssdReplaySafety = ssdReplaySafety
        , ssdReplayPolicyOverride = ssdReplayPolicyOverride
        , ssdTimeoutSeconds = ssdTimeoutSeconds
        , ssdRetryPolicy = ssdRetryPolicy
        }

instance Aeson.ToJSON stageId => Aeson.ToJSON (SerializableStageDefinition stageId) where
  toJSON ssd =
    Aeson.object
      [ "ssdStageId" Aeson..= ssd.ssdStageId
      , "ssdTemplateId" Aeson..= ssd.ssdTemplateId
      , "ssdActionId" Aeson..= ssd.ssdActionId
      , "ssdReplaySafety" Aeson..= ssd.ssdReplaySafety
      , "ssdReplayPolicyOverride" Aeson..= ssd.ssdReplayPolicyOverride
      , "ssdTimeoutSeconds" Aeson..= ssd.ssdTimeoutSeconds
      , "ssdRetryPolicy" Aeson..= ssd.ssdRetryPolicy
      ]

toSerializableStageDefinition :: StageDefinition stageId -> SerializableStageDefinition stageId
toSerializableStageDefinition sd =
  SerializableStageDefinition
    { ssdStageId = sd.sdStageId
    , ssdTemplateId = sd.sdTemplateId
    , ssdActionId = sd.sdActionId
    , ssdReplaySafety = sd.sdReplaySafety
    , ssdReplayPolicyOverride = sd.sdReplayPolicyOverride
    , ssdTimeoutSeconds = sd.sdTimeoutSeconds
    , ssdRetryPolicy = sd.sdRetryPolicy
    }

showNodeIds :: [NodeId] -> Text
showNodeIds = T.intercalate ", " . fmap unNodeId
