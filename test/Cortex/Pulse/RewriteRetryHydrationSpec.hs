{- |
Module      : Cortex.Pulse.RewriteRetryHydrationSpec
Description : Tests for rewrite retry predicate hydration.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.RewriteRetryHydrationSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.Generics (Generic)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Graph (..)
  , toRelation
  )
import Cortex.Pulse.Executor
  ( RewriteExhaustionPolicy (..)
  , SerializableStageDefinition (..)
  , StableStageId (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , StageRetryBackoff (..)
  , StageRetryExhaustion (..)
  , StageRetryPolicy (..)
  , applyRewrite
  , buildStageTemplateRegistry
  , hydrateRewrite
  , stageActionId
  , stageTemplateId
  , toSerializableStageDefinition
  )
import Cortex.Pulse.Memory (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( ExpansionMode (..)
  , GraphRewrite (..)
  , SubgraphSpec (..)
  )
import Cortex.Pulse.Types (defaultRewriteBudget)

data TestStage = StageA | Sub1
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId TestStage where
  stageIdToText = \case
    StageA -> "a"
    Sub1 -> "sub1"

spec :: Spec
spec = do
  describe "rewrite-resume retry predicate parity" $ do
    it "round-trips rewrite retry predicates through JSON and legacy payloads" $ do
      let customRetryPolicy =
            StageRetryPolicy
              { srpPredicateName = "never_retry"
              , srpMaxAttempts = 3
              , srpBackoff = FixedBackoffMicros 1000000
              , srpRetryable = const False -- NEVER retry
              , srpExhaustion = ExhaustionFailsRun
              }
          mkDef sid tid retry =
            StageDefinition
              { sdStageId = sid
              , sdTemplateId = tid
              , sdActionId = stageActionId sid
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Just retry
              , sdAction = \_ -> pure (error "not implemented")
              , sdMemoryStrategy = defaultMemoryStrategy
              }

          -- 1. Initial plan with StageA
          initialTopo = toRelation (Vertex (NodeId "a") :: Graph NodeId)
          initialDefs = Map.fromList [(NodeId "a", mkDef StageA (stageTemplateId StageA) customRetryPolicy)]
          initialPlan =
            StagePlan
              { spInitialState = Aeson.Null
              , spCheckpointRuntimeVersion = 1
              , spReplayPolicy = error "not used"
              , spInitialRewriteBudget = defaultRewriteBudget
              , spRewriteExhaustionPolicy = RewriteExhaustionFail
              , spBudgetExceededExhaustionPolicy = Nothing
              , spMaxRewriteReExecutions = 2
              , spTopology = initialTopo
              , spDefinitions = initialDefs
              , spTemplateRegistry = templateRegistry initialDefs
              }

          -- 2. Rewrite StageA into Sub1
          subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1 (stageTemplateId Sub1) customRetryPolicy)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = ExpandNode (NodeId "a") ExpandReplaceNode spec'

          serializableRewrite = fmap toSerializableStageDefinition rewrite
          registry = templateRegistry (Map.union initialDefs subDefs)
          serializedValue = Aeson.toJSON serializableRewrite
          legacyValue = stripPredicateNames serializedValue

          decodeRewrite :: Aeson.Value -> IO (GraphRewrite NodeId (SerializableStageDefinition TestStage))
          decodeRewrite value =
            case (Aeson.fromJSON value :: Aeson.Result (GraphRewrite NodeId (SerializableStageDefinition TestStage))) of
              Aeson.Error err ->
                expectationFailure ("JSON decode failed: " <> err) >> error "decodeRewrite"
              Aeson.Success decodedRewrite ->
                pure decodedRewrite

          assertHydratedPolicy decodedRewrite =
            case hydrateRewrite registry decodedRewrite of
              Left err -> expectationFailure $ "Hydration failed: " <> T.unpack err
              Right hydratedRewrite ->
                case applyRewrite hydratedRewrite initialPlan of
                  Left errs -> expectationFailure $ "Rewrite failed: " <> show errs
                  Right plan' ->
                    case Map.lookup (NodeId "a:sub1") (spDefinitions plan') of
                      Nothing ->
                        expectationFailure "Rewritten node 'a:sub1' not found in plan"
                      Just def ->
                        case sdRetryPolicy def of
                          Nothing ->
                            expectationFailure "Retry policy missing from rewritten definition"
                          Just policy -> do
                            srpPredicateName policy `shouldBe` "never_retry"
                            srpRetryable policy (error "some error") `shouldBe` False

      decodedRewrite <- decodeRewrite serializedValue
      assertHydratedPolicy decodedRewrite

      decodedLegacyRewrite <- decodeRewrite legacyValue
      case decodedLegacyRewrite of
        ExpandNode _ _ legacySpec ->
          case Map.lookup (NodeId "sub1") (sgsDefinitions legacySpec) of
            Nothing ->
              expectationFailure "Legacy decoded rewrite missing sub1 definition"
            Just ssd ->
              fmap srpPredicateName (ssdRetryPolicy ssd) `shouldBe` Just "default"
        _ ->
          expectationFailure "Expected expanded rewrite after decoding legacy payload"
      assertHydratedPolicy decodedLegacyRewrite
  where
    templateRegistry defs =
      either (error . show) id (buildStageTemplateRegistry defs)

stripPredicateNames :: Aeson.Value -> Aeson.Value
stripPredicateNames = \case
  Aeson.Object obj ->
    Aeson.Object . KeyMap.map stripPredicateNames $
      KeyMap.delete "predicate_name" obj
  Aeson.Array arr ->
    Aeson.Array (fmap stripPredicateNames arr)
  other ->
    other
