{- |
Module      : Cortex.Pulse.Materialization
Description : Pulse runtime support for materialization.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Materialization
  ( PersistedRewrite (..)
  , PersistedRewriteRow
  , PersistedGraphState (..)
  , NodeProvenanceEntry (..)
  , NodeProvenance
  , applyPlannedRewrite
  , authorizeWitnessedReplayWithControl
  , authorizeExternalReplayWithControl
  , computeTopologyHash
  , decodeOptionalJsonValue
  , hydratePersistedRewriteRow
  , hydratePersistedRewriteRowForAdmin
  , initialProvenance
  , resolveRewriteDeltaAndCost
  , reconcileGraphState
  , rewriteDeltaSummaryJson
  , witnessedRewriteDeltaSummaryJson
  , externalRewriteDeltaSummaryJson
  , MaterializationHashMode (..)
  , materializePlannedRewrite
  , materializeRewrite
  )
where

import Control.Monad (when)
import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Bifunctor (bimap, first)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph
  ( Relation (..)
  , relEdges
  , relVertices
  )
import Cortex.Pulse.GraphStateRevision (GraphStateRevision)
import Cortex.Pulse.Hydrate
  ( RewriteError (..)
  , SerializableStageDefinition (..)
  , decodeSerializableRewrite
  , hydrateRewrite
  , planRewriteDelta
  , planRewriteDeltaNamespaced
  , toSerializableStageDefinition
  )
import Cortex.Pulse.Iteration
  ( EffectiveBound (..)
  , LoopBoundSource (..)
  , LoopControl (..)
  , LoopPolicy (..)
  , LoopRegistration (..)
  , LoopStepWitness (..)
  , authorizeWitnessedStep
  , authorizeWitnessedStepWithControl
  , renderWitnessedStepViolation
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( LoopInstanceKey
  , StableStageId
  , StageAction
  , StageDefinition (..)
  , StagePlan (..)
  , loopRegistrationForStage
  )
import Cortex.Pulse.Rewrite
  ( AdmissionMode (..)
  , GraphRewrite (..)
  , PlannedRewriteDelta (..)
  , RewriteAnchorDisposition (..)
  , RewriteBudget
  , RewriteCost
  , admissionModeFromText
  , admitExternalDelta
  , admitRewriteDelta
  , admitWitnessedDelta
  , admittedDelta
  , admittedRemainingBudget
  )
import Cortex.Pulse.Runtime
  ( GraphState (..)
  , NodeStatus (..)
  )

data PersistedRewrite stageId = PersistedRewrite
  { prRewriteId :: Int64
  , prSourceNodeId :: NodeId
  , prSourceNodeOutput :: Maybe Aeson.Value
  , prRewriteCost :: Maybe RewriteCost
  , prRewriteDelta :: Maybe Aeson.Value
  , prRewrite :: GraphRewrite NodeId (StageDefinition stageId)
  , prAdmissionMode :: AdmissionMode
  }

data MaterializationHashMode
  = UpdateTopologyHash
  | DeferTopologyHash
  deriving stock (Eq, Show)

data WitnessedReplayMetadata = WitnessedReplayMetadata
  { wrmPolicyVersion :: !Int
  , wrmEffectiveBound :: !EffectiveBound
  , wrmRemainingBefore :: !Natural
  , wrmRemainingAfter :: !Natural
  , wrmStepWitness :: !LoopStepWitness
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WitnessedReplayMetadata where
  toJSON metadata =
    Aeson.object
      [ "policy_version" Aeson..= metadata.wrmPolicyVersion
      , "effective_bound" Aeson..= metadata.wrmEffectiveBound
      , "remaining_before" Aeson..= metadata.wrmRemainingBefore
      , "remaining_after" Aeson..= metadata.wrmRemainingAfter
      , "step_witness" Aeson..= metadata.wrmStepWitness
      ]

instance FromJSON WitnessedReplayMetadata where
  parseJSON =
    Aeson.withObject "WitnessedReplayMetadata" $ \object ->
      WitnessedReplayMetadata
        <$> object Aeson..: "policy_version"
        <*> object Aeson..: "effective_bound"
        <*> object Aeson..: "remaining_before"
        <*> object Aeson..: "remaining_after"
        <*> object Aeson..: "step_witness"

newtype WitnessedReplayEnvelope = WitnessedReplayEnvelope
  { wreWitnessedLoopStep :: WitnessedReplayMetadata
  }

instance FromJSON WitnessedReplayEnvelope where
  parseJSON =
    Aeson.withObject "WitnessedReplayEnvelope" $ \object ->
      WitnessedReplayEnvelope <$> object Aeson..: "witnessed_loop_step"

{- | Replay metadata persisted per externally-driven step row (ADR 0088). The
capped counters do not apply; the cross-checked quantity is the admitted-step
count before and after this row, matching 'lcAdmittedSteps' reconstruction.
-}
data ExternalReplayMetadata = ExternalReplayMetadata
  { ermPolicyVersion :: !Int
  , ermStepsBefore :: !Natural
  , ermStepsAfter :: !Natural
  , ermStepWitness :: !LoopStepWitness
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ExternalReplayMetadata where
  toJSON metadata =
    Aeson.object
      [ "policy_version" Aeson..= metadata.ermPolicyVersion
      , "steps_before" Aeson..= metadata.ermStepsBefore
      , "steps_after" Aeson..= metadata.ermStepsAfter
      , "step_witness" Aeson..= metadata.ermStepWitness
      ]

instance FromJSON ExternalReplayMetadata where
  parseJSON =
    Aeson.withObject "ExternalReplayMetadata" $ \object ->
      ExternalReplayMetadata
        <$> object Aeson..: "policy_version"
        <*> object Aeson..: "steps_before"
        <*> object Aeson..: "steps_after"
        <*> object Aeson..: "step_witness"

newtype ExternalReplayEnvelope = ExternalReplayEnvelope
  { ereExternalStep :: ExternalReplayMetadata
  }

instance FromJSON ExternalReplayEnvelope where
  parseJSON =
    Aeson.withObject "ExternalReplayEnvelope" $ \object ->
      ExternalReplayEnvelope <$> object Aeson..: "external_step"

type PersistedRewriteRow =
  ( Int64
  , Text
  , Maybe Aeson.Value
  , Maybe Aeson.Value
  , Maybe Aeson.Value
  , Aeson.Value
  , Text
  )

{- | Per-node provenance entry tracking which rewrite introduced a node.
Initial plan nodes have 'Nothing' for both fields.
-}
data NodeProvenanceEntry = NodeProvenanceEntry
  { npeIntroducedByRewriteId :: Maybe Int64
  , npeAnchorNodeId :: Maybe NodeId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Map from each node to its provenance (which rewrite introduced it).
type NodeProvenance = Map.Map NodeId NodeProvenanceEntry

data PersistedGraphState = PersistedGraphState
  { pgsGraphState :: GraphState Aeson.Value
  , pgsRemainingRewriteBudget :: RewriteBudget
  , pgsAppliedRewriteId :: Maybe Int64
  , pgsNodeProvenance :: NodeProvenance
  , pgsTopologyHash :: Maybe Text
  , pgsRevision :: Maybe GraphStateRevision
  }
  deriving stock (Eq, Show)

applyPlannedRewrite
  :: PlannedRewriteDelta (StageDefinition stageId)
  -> StagePlan stageId
  -> StagePlan stageId
applyPlannedRewrite delta plan =
  plan
    { spTopology = delta.prdTopology
    , spDefinitions = delta.prdDefinitions
    , spTemplateRegistry = plan.spTemplateRegistry
    }

{- | Build initial provenance for a plan's topology. All nodes get 'Nothing'
origin since they are part of the original plan, not introduced by a rewrite.
-}
initialProvenance :: Relation NodeId -> NodeProvenance
initialProvenance topology =
  Map.fromSet (const (NodeProvenanceEntry Nothing Nothing)) (relVertices topology)

{- | Compute a deterministic topology hash from sorted node IDs and sorted edge
pairs. Used as an integrity witness: if the persisted hash differs from the
hash recomputed during resume, the materialized state and lineage diverge.
-}
computeTopologyHash :: Relation NodeId -> Text
computeTopologyHash topology =
  let nodes = fmap unNodeId (Set.toAscList (relVertices topology))
      edges = fmap (bimap unNodeId unNodeId) (Set.toAscList (relEdges topology))
      canonical = Aeson.encode (nodes, edges)
      digest = hashlazy @SHA256 canonical
   in T.pack (show digest)

decodeJsonValue :: Aeson.FromJSON a => Text -> Aeson.Value -> Either Text a
decodeJsonValue label value =
  case Aeson.fromJSON value of
    Aeson.Success decoded -> Right decoded
    Aeson.Error err ->
      Left ("Failed to decode " <> label <> ": " <> T.pack err)

decodeOptionalJsonValue :: Aeson.FromJSON a => Text -> Maybe Aeson.Value -> Either Text (Maybe a)
decodeOptionalJsonValue label = traverse (decodeJsonValue label)

hydratePersistedRewriteRow
  :: StableStageId stageId
  => StagePlan stageId
  -> PersistedRewriteRow
  -> Either RewriteError (PersistedRewrite stageId)
hydratePersistedRewriteRow plan row = do
  let ( rewriteId
        , sourceNodeIdText
        , sourceNodeOutput
        , rewriteCostJson
        , rewriteDeltaJson
        , rewriteValue
        , admissionModeRaw
        ) = row
  serializableRewrite <- first RewriteHydrationFailed $ decodeSerializableRewrite rewriteValue
  hydratedRewrite <-
    first RewriteHydrationFailed $ hydrateRewrite plan.spTemplateRegistry serializableRewrite
  rewriteCost <-
    first RewriteHydrationFailed $ decodeOptionalJsonValue "persisted rewrite cost" rewriteCostJson
  pure
    PersistedRewrite
      { prRewriteId = rewriteId
      , prSourceNodeId = NodeId sourceNodeIdText
      , prSourceNodeOutput = sourceNodeOutput
      , prRewriteCost = rewriteCost
      , prRewriteDelta = rewriteDeltaJson
      , prRewrite = hydratedRewrite
      , prAdmissionMode = admissionModeFromText admissionModeRaw
      }

{- | Hydrate a rewrite for admin topology materialization only.

The admin graph view only needs node ids and edges. It must be able to
replay organic rewrites whose executor-specific stage definitions were
persisted with local template ids that are not present in the initial
executable template registry. These placeholder actions are never executed.
-}
hydratePersistedRewriteRowForAdmin
  :: StableStageId stageId
  => PersistedRewriteRow
  -> Either RewriteError (PersistedRewrite stageId)
hydratePersistedRewriteRowForAdmin row = do
  let ( rewriteId
        , sourceNodeIdText
        , sourceNodeOutput
        , rewriteCostJson
        , rewriteDeltaJson
        , rewriteValue
        , admissionModeRaw
        ) = row
  serializableRewrite <- first RewriteHydrationFailed $ decodeSerializableRewrite rewriteValue
  rewriteCost <-
    first RewriteHydrationFailed $ decodeOptionalJsonValue "persisted rewrite cost" rewriteCostJson
  pure
    PersistedRewrite
      { prRewriteId = rewriteId
      , prSourceNodeId = NodeId sourceNodeIdText
      , prSourceNodeOutput = sourceNodeOutput
      , prRewriteCost = rewriteCost
      , prRewriteDelta = rewriteDeltaJson
      , prRewrite = fmap adminStageDefinition serializableRewrite
      , prAdmissionMode = admissionModeFromText admissionModeRaw
      }
  where
    adminStageDefinition ssd =
      StageDefinition
        { sdStageId = ssd.ssdStageId
        , sdTemplateId = ssd.ssdTemplateId
        , sdActionId = ssd.ssdActionId
        , sdReplaySafety = ssd.ssdReplaySafety
        , sdReplayPolicyOverride = ssd.ssdReplayPolicyOverride
        , sdTimeoutSeconds = ssd.ssdTimeoutSeconds
        , sdRetryPolicy = ssd.ssdRetryPolicy
        , sdAction = adminOnlyStagePlaceholderAction
        , sdMemoryStrategy = defaultMemoryStrategy
        }

adminOnlyStagePlaceholderAction :: StageAction stageId
adminOnlyStagePlaceholderAction _ =
  ioError
    (userError "Cortex.Pulse.Materialization: admin-only rewritten stage placeholder must not execute")

resolveRewriteDeltaAndCost
  :: Eq stageId
  => PersistedRewrite stageId
  -> StagePlan stageId
  -> Either RewriteError (PlannedRewriteDelta (StageDefinition stageId), RewriteCost)
resolveRewriteDeltaAndCost persistedRewrite plan = do
  -- Witnessed loop-step and externally-driven specs are already flat-namespaced
  -- under the loop seed, so they must be planned without re-namespacing under
  -- the anchor.
  let planFn = case persistedRewrite.prAdmissionMode of
        AdmissionWitnessed -> planRewriteDeltaNamespaced
        AdmissionExternal -> planRewriteDeltaNamespaced
        AdmissionGassed -> planRewriteDelta
  delta <- first RewriteValidationFailed (planFn persistedRewrite.prRewrite plan)
  pure (delta, fromMaybe delta.prdCost persistedRewrite.prRewriteCost)

resolveRewriteSourceOutput
  :: PersistedRewrite stageId
  -> GraphState Aeson.Value
  -> Maybe Aeson.Value
resolveRewriteSourceOutput persistedRewrite gs =
  case persistedRewrite.prSourceNodeOutput of
    Just output -> Just output
    Nothing -> Map.lookup persistedRewrite.prSourceNodeId gs.gsNodeOutputs

rewriteDeltaSummaryJson :: PlannedRewriteDelta def -> Aeson.Value
rewriteDeltaSummaryJson delta =
  Aeson.object (rewriteDeltaSummaryFields delta)

witnessedRewriteDeltaSummaryJson
  :: LoopPolicy
  -> LoopStepWitness
  -> LoopControl
  -> LoopControl
  -> PlannedRewriteDelta def
  -> Aeson.Value
witnessedRewriteDeltaSummaryJson policy witness control nextControl delta =
  Aeson.object $
    rewriteDeltaSummaryFields delta
      <> [ "witnessed_loop_step"
             Aeson..= WitnessedReplayMetadata
               { wrmPolicyVersion = lpPolicyVersion policy
               , wrmEffectiveBound = lcEffectiveBound control
               , wrmRemainingBefore = lcRemainingIterations control
               , wrmRemainingAfter = lcRemainingIterations nextControl
               , wrmStepWitness = witness
               }
         ]

{- | Delta summary for an externally-driven step row: the shared delta fields
plus the @external_step@ replay metadata cross-checked on resume.
-}
externalRewriteDeltaSummaryJson
  :: LoopPolicy
  -> LoopStepWitness
  -> LoopControl
  -> LoopControl
  -> PlannedRewriteDelta def
  -> Aeson.Value
externalRewriteDeltaSummaryJson policy witness control nextControl delta =
  Aeson.object $
    rewriteDeltaSummaryFields delta
      <> [ "external_step"
             Aeson..= ExternalReplayMetadata
               { ermPolicyVersion = lpPolicyVersion policy
               , ermStepsBefore = lcAdmittedSteps control
               , ermStepsAfter = lcAdmittedSteps nextControl
               , ermStepWitness = witness
               }
         ]

rewriteDeltaSummaryFields :: PlannedRewriteDelta def -> [Pair]
rewriteDeltaSummaryFields delta =
  [ "anchor_node" Aeson..= unNodeId delta.prdAnchorNode
  , "anchor_disposition" Aeson..= show delta.prdAnchorDisposition
  , "new_nodes" Aeson..= fmap unNodeId (Set.toList delta.prdNewNodes)
  , "removed_nodes" Aeson..= fmap unNodeId (Set.toList delta.prdRemovedNodes)
  , "added_edges"
      Aeson..= fmap
        ( \(fromNode, toNode) -> Aeson.object ["from" Aeson..= unNodeId fromNode, "to" Aeson..= unNodeId toNode]
        )
        (Set.toList delta.prdAddedEdges)
  , "entry_nodes" Aeson..= fmap unNodeId delta.prdEntryNodes
  , "exit_nodes" Aeson..= fmap unNodeId delta.prdExitNodes
  ]

decodeWitnessedReplayMetadata
  :: PersistedRewrite stageId -> Either RewriteError WitnessedReplayMetadata
decodeWitnessedReplayMetadata persistedRewrite =
  case persistedRewrite.prRewriteDelta of
    Nothing ->
      Left . RewriteHydrationFailed $
        "Witnessed rewrite "
          <> T.pack (show persistedRewrite.prRewriteId)
          <> " is missing persisted witnessed replay metadata"
    Just rewriteDeltaJson -> do
      let decodedEnvelope :: Either Text WitnessedReplayEnvelope
          decodedEnvelope =
            decodeJsonValue "persisted witnessed replay metadata" rewriteDeltaJson
      envelope <-
        first RewriteHydrationFailed decodedEnvelope
      pure envelope.wreWitnessedLoopStep

decodeExternalReplayMetadata
  :: PersistedRewrite stageId -> Either RewriteError ExternalReplayMetadata
decodeExternalReplayMetadata persistedRewrite =
  case persistedRewrite.prRewriteDelta of
    Nothing ->
      Left . RewriteHydrationFailed $
        "Externally-driven rewrite "
          <> T.pack (show persistedRewrite.prRewriteId)
          <> " is missing persisted external replay metadata"
    Just rewriteDeltaJson -> do
      let decodedEnvelope :: Either Text ExternalReplayEnvelope
          decodedEnvelope =
            decodeJsonValue "persisted external replay metadata" rewriteDeltaJson
      envelope <-
        first RewriteHydrationFailed decodedEnvelope
      pure envelope.ereExternalStep

reconcileGraphState
  :: Relation NodeId
  -> GraphState Aeson.Value
  -> Either RewriteError (GraphState Aeson.Value)
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

{- | Re-run the static witnessed-admission gate on a persisted rewrite row.
This private helper is used only by 'materializeRewrite' after live admission or
after resume has already run 'authorizeWitnessedReplayWithControl'. The producer
is the persisted @source_node_id@ (NOT the rewrite's own anchor), so the
self-append check verifies the rewrite anchor matches the stored producer.
Authorization keys on that producer's registered loop template; an unregistered
producer is rejected.
-}
authorizeWitnessedReplay
  :: Aeson.ToJSON stageId
  => StagePlan stageId
  -> PersistedRewrite stageId
  -> PlannedRewriteDelta (StageDefinition stageId)
  -> Either RewriteError ()
authorizeWitnessedReplay stagePlan persistedRewrite delta = do
  (producer, _templateId, policy) <- witnessedReplayPolicy stagePlan persistedRewrite
  requireCappedBoundSource persistedRewrite policy
  metadata <- decodeWitnessedReplayMetadata persistedRewrite
  when (metadata.wrmPolicyVersion /= lpPolicyVersion policy) $
    Left
      (RewriteHydrationFailed (witnessedPolicyVersionMismatchMessage persistedRewrite policy metadata))
  let serializableRewrite = fmap toSerializableStageDefinition persistedRewrite.prRewrite
  first (RewriteHydrationFailed . renderWitnessedStepViolation) $
    authorizeWitnessedStep policy producer metadata.wrmStepWitness serializableRewrite delta.prdCost

{- | Control-aware replay validation for witnessed rows. This is used by resume
when reconstructing topology from persisted lineage. It verifies that the row's
admitted replay metadata matches the reconstructed run-local loop control, then
advances that control exactly once.
-}
authorizeWitnessedReplayWithControl
  :: Aeson.ToJSON stageId
  => StagePlan stageId
  -> PersistedRewrite stageId
  -> PlannedRewriteDelta (StageDefinition stageId)
  -> Map.Map LoopInstanceKey LoopControl
  -> Either RewriteError (Map.Map LoopInstanceKey LoopControl)
authorizeWitnessedReplayWithControl stagePlan persistedRewrite delta controls = do
  (producer, loopKey, policy) <- witnessedReplayPolicy stagePlan persistedRewrite
  requireCappedBoundSource persistedRewrite policy
  control <-
    maybe
      ( Left . RewriteHydrationFailed $
          "Witnessed rewrite at producer "
            <> unNodeId producer
            <> " has no reconstructed loop control for template "
            <> T.pack (show loopKey)
      )
      Right
      (Map.lookup loopKey controls)
  metadata <- decodeWitnessedReplayMetadata persistedRewrite
  when (metadata.wrmPolicyVersion /= lpPolicyVersion policy) $
    Left
      (RewriteHydrationFailed (witnessedPolicyVersionMismatchMessage persistedRewrite policy metadata))
  when (metadata.wrmEffectiveBound /= lcEffectiveBound control) $
    Left
      ( RewriteHydrationFailed $
          witnessedControlMismatchMessage
            persistedRewrite
            "effective_bound"
            (Aeson.toJSON (lcEffectiveBound control))
            (Aeson.toJSON metadata.wrmEffectiveBound)
      )
  when (metadata.wrmRemainingBefore /= lcRemainingIterations control) $
    Left
      ( RewriteHydrationFailed $
          witnessedControlMismatchMessage
            persistedRewrite
            "remaining_before"
            (Aeson.toJSON (lcRemainingIterations control))
            (Aeson.toJSON metadata.wrmRemainingBefore)
      )
  let serializableRewrite = fmap toSerializableStageDefinition persistedRewrite.prRewrite
  nextControl <-
    first (RewriteHydrationFailed . renderWitnessedStepViolation) $
      authorizeWitnessedStepWithControl
        policy
        control
        producer
        metadata.wrmStepWitness
        persistedRewrite.prSourceNodeOutput
        serializableRewrite
        delta.prdCost
  when (metadata.wrmRemainingAfter /= lcRemainingIterations nextControl) $
    Left
      ( RewriteHydrationFailed $
          witnessedControlMismatchMessage
            persistedRewrite
            "remaining_after"
            (Aeson.toJSON (lcRemainingIterations nextControl))
            (Aeson.toJSON metadata.wrmRemainingAfter)
      )
  pure (Map.insert loopKey nextControl controls)

witnessedReplayPolicy
  :: StagePlan stageId
  -> PersistedRewrite stageId
  -> Either RewriteError (NodeId, LoopInstanceKey, LoopPolicy)
witnessedReplayPolicy stagePlan persistedRewrite = do
  let producer = persistedRewrite.prSourceNodeId
  case Map.lookup producer stagePlan.spDefinitions of
    Just producerDef
      | Just (loopKey, registration) <- loopRegistrationForStage stagePlan producerDef.sdTemplateId producer ->
          Right (producer, loopKey, registration.lrPolicy)
    _ ->
      Left . RewriteHydrationFailed $
        "Witnessed rewrite at producer " <> unNodeId producer <> " is not an authorized loop kernel"

{- | Re-run the static externally-driven admission gate on a persisted row
(ADR 0088). Mirrors 'authorizeWitnessedReplay': the producer is the persisted
@source_node_id@, the registration is resolved through the same key mechanism,
and the row is additionally required to belong to a 'BoundExternalDelivery'
registration — an @external@-tagged row for a capped registration (or vice
versa) is a journal/registration mismatch, rejected rather than reinterpreted.
-}
authorizeExternalReplay
  :: Aeson.ToJSON stageId
  => StagePlan stageId
  -> PersistedRewrite stageId
  -> PlannedRewriteDelta (StageDefinition stageId)
  -> Either RewriteError ()
authorizeExternalReplay stagePlan persistedRewrite delta = do
  (producer, _loopKey, policy) <- witnessedReplayPolicy stagePlan persistedRewrite
  requireExternalBoundSource persistedRewrite policy
  metadata <- decodeExternalReplayMetadata persistedRewrite
  when (metadata.ermPolicyVersion /= lpPolicyVersion policy) $
    Left
      ( RewriteHydrationFailed
          (policyVersionMismatchMessage persistedRewrite policy metadata.ermPolicyVersion)
      )
  let serializableRewrite = fmap toSerializableStageDefinition persistedRewrite.prRewrite
  first (RewriteHydrationFailed . renderWitnessedStepViolation) $
    authorizeWitnessedStep policy producer metadata.ermStepWitness serializableRewrite delta.prdCost

{- | Control-aware replay validation for externally-driven rows. Used by resume
when reconstructing topology from persisted lineage: the row's admitted-step
counters must match the reconstructed control, which then advances exactly
once. The full step gate (self-append anchor, canonical index, delivery entry,
kernel digest, size envelope) re-runs inside
'Cortex.Pulse.Iteration.authorizeWitnessedStepWithControl'.
-}
authorizeExternalReplayWithControl
  :: Aeson.ToJSON stageId
  => StagePlan stageId
  -> PersistedRewrite stageId
  -> PlannedRewriteDelta (StageDefinition stageId)
  -> Map.Map LoopInstanceKey LoopControl
  -> Either RewriteError (Map.Map LoopInstanceKey LoopControl)
authorizeExternalReplayWithControl stagePlan persistedRewrite delta controls = do
  (producer, loopKey, policy) <- witnessedReplayPolicy stagePlan persistedRewrite
  requireExternalBoundSource persistedRewrite policy
  control <-
    maybe
      ( Left . RewriteHydrationFailed $
          "Externally-driven rewrite at producer "
            <> unNodeId producer
            <> " has no reconstructed loop control for template "
            <> T.pack (show loopKey)
      )
      Right
      (Map.lookup loopKey controls)
  metadata <- decodeExternalReplayMetadata persistedRewrite
  when (metadata.ermPolicyVersion /= lpPolicyVersion policy) $
    Left
      ( RewriteHydrationFailed
          (policyVersionMismatchMessage persistedRewrite policy metadata.ermPolicyVersion)
      )
  when (metadata.ermStepsBefore /= lcAdmittedSteps control) $
    Left
      ( RewriteHydrationFailed $
          witnessedControlMismatchMessage
            persistedRewrite
            "steps_before"
            (Aeson.toJSON (lcAdmittedSteps control))
            (Aeson.toJSON metadata.ermStepsBefore)
      )
  let serializableRewrite = fmap toSerializableStageDefinition persistedRewrite.prRewrite
  nextControl <-
    first (RewriteHydrationFailed . renderWitnessedStepViolation) $
      authorizeWitnessedStepWithControl
        policy
        control
        producer
        metadata.ermStepWitness
        persistedRewrite.prSourceNodeOutput
        serializableRewrite
        delta.prdCost
  when (metadata.ermStepsAfter /= lcAdmittedSteps nextControl) $
    Left
      ( RewriteHydrationFailed $
          witnessedControlMismatchMessage
            persistedRewrite
            "steps_after"
            (Aeson.toJSON (lcAdmittedSteps nextControl))
            (Aeson.toJSON metadata.ermStepsAfter)
      )
  pure (Map.insert loopKey nextControl controls)

requireExternalBoundSource
  :: PersistedRewrite stageId -> LoopPolicy -> Either RewriteError ()
requireExternalBoundSource persistedRewrite policy =
  case lpBoundSource policy of
    BoundExternalDelivery _ -> Right ()
    BoundIterationCap ->
      Left . RewriteHydrationFailed $
        "Externally-driven rewrite "
          <> T.pack (show persistedRewrite.prRewriteId)
          <> " resolves to a capped loop registration; admission mode and registration disagree"

requireCappedBoundSource
  :: PersistedRewrite stageId -> LoopPolicy -> Either RewriteError ()
requireCappedBoundSource persistedRewrite policy =
  case lpBoundSource policy of
    BoundIterationCap -> Right ()
    BoundExternalDelivery _ ->
      Left . RewriteHydrationFailed $
        "Witnessed rewrite "
          <> T.pack (show persistedRewrite.prRewriteId)
          <> " resolves to an externally-driven registration; admission mode and registration disagree"

policyVersionMismatchMessage
  :: PersistedRewrite stageId -> LoopPolicy -> Int -> Text
policyVersionMismatchMessage persistedRewrite policy admittedVersion =
  "Witnessed rewrite "
    <> T.pack (show persistedRewrite.prRewriteId)
    <> " was admitted with loop policy version "
    <> T.pack (show admittedVersion)
    <> " but the registered policy is version "
    <> T.pack (show (lpPolicyVersion policy))

witnessedPolicyVersionMismatchMessage
  :: PersistedRewrite stageId -> LoopPolicy -> WitnessedReplayMetadata -> Text
witnessedPolicyVersionMismatchMessage persistedRewrite policy metadata =
  policyVersionMismatchMessage persistedRewrite policy metadata.wrmPolicyVersion

witnessedControlMismatchMessage
  :: PersistedRewrite stageId -> Text -> Aeson.Value -> Aeson.Value -> Text
witnessedControlMismatchMessage persistedRewrite field expected actual =
  "Witnessed rewrite "
    <> T.pack (show persistedRewrite.prRewriteId)
    <> " replay metadata field "
    <> field
    <> " does not match reconstructed loop control (expected "
    <> T.pack (show expected)
    <> ", got "
    <> T.pack (show actual)
    <> ")"

materializeRewrite
  :: (Aeson.ToJSON stageId, Eq stageId)
  => PersistedRewrite stageId
  -> StagePlan stageId
  -> PersistedGraphState
  -> Either RewriteError (StagePlan stageId, PersistedGraphState)
materializeRewrite persistedRewrite stagePlan persistedState = do
  (delta, _rewriteCost) <- resolveRewriteDeltaAndCost persistedRewrite stagePlan
  materializePlannedRewrite UpdateTopologyHash True persistedRewrite delta stagePlan persistedState

materializePlannedRewrite
  :: Aeson.ToJSON stageId
  => MaterializationHashMode
  -> Bool
  -> PersistedRewrite stageId
  -> PlannedRewriteDelta (StageDefinition stageId)
  -> StagePlan stageId
  -> PersistedGraphState
  -> Either RewriteError (StagePlan stageId, PersistedGraphState)
materializePlannedRewrite hashMode validateWitnessed persistedRewrite delta stagePlan persistedState = do
  -- Witnessed self-append steps are gas-neutral: the cost is recorded but does
  -- not gate, so the remaining rewrite budget is left unchanged on replay.
  admitted <- case persistedRewrite.prAdmissionMode of
    AdmissionWitnessed -> do
      -- Re-validate witnessed rows on replay; never trust the stored admission
      -- tag. A row that fails the same security gate as the live path is
      -- rejected, not admitted gas-neutral.
      when validateWitnessed $
        authorizeWitnessedReplay stagePlan persistedRewrite delta
      Right (admitWitnessedDelta persistedState.pgsRemainingRewriteBudget delta)
    AdmissionExternal -> do
      -- Externally-driven rows re-run the same step gate plus the
      -- registration bound-source cross-check before gas-neutral admission.
      when validateWitnessed $
        authorizeExternalReplay stagePlan persistedRewrite delta
      Right (admitExternalDelta persistedState.pgsRemainingRewriteBudget delta)
    AdmissionGassed ->
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
          { gsNodeStatuses = cleanStatuses <> pendingStatuses
          , gsNodeOutputs = cleanOutputs
          }
      newNodeProvenance =
        Map.fromSet
          ( const
              NodeProvenanceEntry
                { npeIntroducedByRewriteId = Just persistedRewrite.prRewriteId
                , npeAnchorNodeId = Just persistedRewrite.prSourceNodeId
                }
          )
          admDelta.prdNewNodes
      updatedProvenance =
        Map.withoutKeys persistedState.pgsNodeProvenance admDelta.prdRemovedNodes
          <> newNodeProvenance
      stagePlan' = applyPlannedRewrite admDelta stagePlan
      persistedState' =
        persistedState
          { pgsGraphState = gs'
          , pgsRemainingRewriteBudget = admittedRemainingBudget admitted
          , pgsAppliedRewriteId = Just persistedRewrite.prRewriteId
          , pgsNodeProvenance = updatedProvenance
          , pgsTopologyHash =
              case hashMode of
                UpdateTopologyHash -> Just (computeTopologyHash stagePlan'.spTopology)
                DeferTopologyHash -> persistedState.pgsTopologyHash
          }
  pure (stagePlan', persistedState')
