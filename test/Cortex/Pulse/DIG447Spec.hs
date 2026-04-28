{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Pulse.DIG447Spec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import GHC.Generics (Generic)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Graph (..)
  , toRelation
  )
import Cortex.Pulse.Executor
  ( RewriteExhaustionPolicy (..)
  , StableStageId (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , applyRewrite
  , buildStageTemplateRegistry
  , stageActionId
  , stageTemplateId
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
  describe "DIG-447: Rewrite Anchor Validation" $ do
    let mkDef sid =
          StageDefinition
            { sdStageId = sid
            , sdTemplateId = stageTemplateId sid
            , sdActionId = stageActionId sid
            , sdReplaySafety = SafeToReplay
            , sdReplayPolicyOverride = Nothing
            , sdTimeoutSeconds = Nothing
            , sdRetryPolicy = Nothing
            , sdAction = \_ -> pure (error "not implemented")
            , sdMemoryStrategy = defaultMemoryStrategy
            }
        -- a
        initialTopo = toRelation (Vertex (NodeId "a") :: Graph NodeId)
        initialDefs = Map.fromList [(NodeId "a", mkDef StageA)]
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

    it "rejects ExpandNode if anchor node is missing from topology" $ do
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = ExpandNode (NodeId "missing") ExpandReplaceNode spec'
      case applyRewrite rewrite initialPlan of
        Left errs -> show errs `shouldContain` "RewriteAnchorMissingFromTopology"
        Right _ -> expectationFailure "Should have failed with missing anchor"

    it "rejects AppendAfter if anchor node is missing from topology" $ do
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = AppendAfter (NodeId "missing") spec'
      case applyRewrite rewrite initialPlan of
        Left errs -> show errs `shouldContain` "RewriteAnchorMissingFromTopology"
        Right _ -> expectationFailure "Should have failed with missing anchor"

    it "rejects ExpandNode if anchor node is missing from definitions" $ do
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = ExpandNode (NodeId "a") ExpandReplaceNode spec'
          -- Manually corrupt the plan by removing the definition but keeping the vertex
          invalidPlan = initialPlan {spDefinitions = Map.delete (NodeId "a") initialDefs}
      case applyRewrite rewrite invalidPlan of
        Left errs -> show errs `shouldContain` "RewriteAnchorMissingDefinition"
        Right _ -> expectationFailure "Should have failed with missing definition"

    it "rejects subgraph if entry/exit nodes are outside its own topology" $ do
      -- subgraph topology only has "sub1", but entry/exit claim "ghost"
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "ghost"] [NodeId "ghost"]
          rewrite = ExpandNode (NodeId "a") ExpandReplaceNode spec'
      case applyRewrite rewrite initialPlan of
        Left errs -> do
          let msg = show errs
          msg `shouldContain` "RewriteEntryNodesOutsideTopology"
          msg `shouldContain` "RewriteExitNodesOutsideTopology"
        Right _ -> expectationFailure "Should have failed with out-of-bounds entry/exit"
  where
    templateRegistry defs =
      either (error . show) id (buildStageTemplateRegistry defs)
