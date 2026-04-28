{- |
Module      : Cortex.Pulse.GraphRewriteSpec
Description : Tests for Cortex.Pulse.GraphRewrite.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.GraphRewriteSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import GHC.Generics (Generic)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Graph (..)
  , Relation (..)
  , checkCacheInvariant
  , edge
  , path
  , predecessors
  , successors
  , toRelation
  )
import Cortex.Pulse.Executor
  ( RewriteExhaustionPolicy (..)
  , StableStageId (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , StageRetryBackoff (..)
  , StageRetryExhaustion (..)
  , StageRetryPolicy (..)
  , StageTemplateId (..)
  , applyRewrite
  , buildStageTemplateRegistry
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Materialize (computeTopologyHash)
import Cortex.Pulse.Memory (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( BudgetDimension (..)
  , ExceededDimension (..)
  , ExpansionMode (..)
  , GraphRewrite (..)
  , PlannedRewriteDelta (..)
  , RewriteAnchorDisposition (..)
  , RewriteBudget (..)
  , RewriteBudgetError (..)
  , RewriteCost (..)
  , RewritePlanningError (..)
  , SubgraphSpec (..)
  , admitRewriteDelta
  , admittedRemainingBudget
  , consumeRewriteBudget
  , exceededDimensions
  , planGraphRewrite
  )
import Cortex.Pulse.Types (defaultRewriteBudget)

data TestStage = StageA | StageB | StageC | Sub1 | Sub2
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId TestStage where
  stageIdToText = \case
    StageA -> "a"
    StageB -> "b"
    StageC -> "c"
    Sub1 -> "sub1"
    Sub2 -> "sub2"

spec :: Spec
spec = do
  describe "applyRewrite" $ do
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
        -- a -> b -> c
        initialTopo = toRelation (path [NodeId "a", NodeId "b", NodeId "c"] :: Graph NodeId)
        initialDefs =
          Map.fromList
            [ (NodeId "a", mkDef StageA)
            , (NodeId "b", mkDef StageB)
            , (NodeId "c", mkDef StageC)
            ]
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

    describe "ExpandNode (ExpandReplaceNode)" $ do
      it "replaces a midpoint node and wires entry/exit correctly" $ do
        -- b replaced by sub1 -> sub2
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = ExpandNode (NodeId "b") ExpandReplaceNode spec'
            mPlan' = applyRewrite rewrite initialPlan

        case mPlan' of
          Left errs -> expectationFailure $ "applyRewrite failed: " <> show errs
          Right plan' -> do
            let topo' = spTopology plan'
            -- 1. Cache invariant holds
            checkCacheInvariant topo' `shouldBe` True
            -- 2. b is gone
            Set.member (NodeId "b") (relVertices topo') `shouldBe` False
            -- 3. namespaced nodes are there
            Set.member (NodeId "b:sub1") (relVertices topo') `shouldBe` True
            Set.member (NodeId "b:sub2") (relVertices topo') `shouldBe` True
            -- 4. a -> b:sub1 (predecessor to entry)
            Set.member (NodeId "a") (predecessors topo' (NodeId "b:sub1")) `shouldBe` True
            -- 5. b:sub2 -> c (exit to successor)
            Set.member (NodeId "c") (successors topo' (NodeId "b:sub2")) `shouldBe` True
            -- 6. No a -> b or b -> c
            Set.member (NodeId "a", NodeId "b") (relEdges topo') `shouldBe` False
            Set.member (NodeId "b", NodeId "c") (relEdges topo') `shouldBe` False

      it "rejects rewrites when the anchor node is absent" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = ExpandNode (NodeId "missing") ExpandReplaceNode spec'

        case applyRewrite rewrite initialPlan of
          Left errs ->
            show errs `shouldContain` "RewriteAnchorMissingFromTopology"
          Right _ ->
            expectationFailure "Expected rewrite with missing anchor to be rejected"

    describe "ExpandNode (ExpandRetainNodeAsEnvelope)" $ do
      it "retains the node and wires it as envelope" $ do
        -- b expanded into sub1 -> sub2, but b remains
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = ExpandNode (NodeId "b") ExpandRetainNodeAsEnvelope spec'
            mPlan' = applyRewrite rewrite initialPlan

        case mPlan' of
          Left errs -> expectationFailure $ "applyRewrite failed: " <> show errs
          Right plan' -> do
            let topo' = spTopology plan'
            -- 1. Cache invariant holds
            checkCacheInvariant topo' `shouldBe` True
            -- 2. b is still there
            Set.member (NodeId "b") (relVertices topo') `shouldBe` True
            -- 3. a -> b (original wiring preserved)
            Set.member (NodeId "a") (predecessors topo' (NodeId "b")) `shouldBe` True
            -- 4. b -> b:sub1 (envelope to entry)
            Set.member (NodeId "b") (predecessors topo' (NodeId "b:sub1")) `shouldBe` True
            -- 5. b:sub2 -> c (exit to successor)
            Set.member (NodeId "c") (successors topo' (NodeId "b:sub2")) `shouldBe` True
            -- 6. b -> c is REMOVED (successors now wait for sub2)
            Set.member (NodeId "b", NodeId "c") (relEdges topo') `shouldBe` False

    describe "AppendAfter" $ do
      it "interposes a subgraph between a node and its successors" $ do
        -- append sub1 -> sub2 after b
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = AppendAfter (NodeId "b") spec'
            mPlan' = applyRewrite rewrite initialPlan

        case mPlan' of
          Left errs -> expectationFailure $ "applyRewrite failed: " <> show errs
          Right plan' -> do
            let topo' = spTopology plan'
            -- 1. Cache invariant holds
            checkCacheInvariant topo' `shouldBe` True
            -- 2. b is still there
            Set.member (NodeId "b") (relVertices topo') `shouldBe` True
            -- 3. b -> b:sub1 (source to entry)
            Set.member (NodeId "b") (predecessors topo' (NodeId "b:sub1")) `shouldBe` True
            -- 4. b:sub2 -> c (exit to successor)
            Set.member (NodeId "c") (successors topo' (NodeId "b:sub2")) `shouldBe` True
            -- 5. b -> c is REMOVED
            Set.member (NodeId "b", NodeId "c") (relEdges topo') `shouldBe` False

      it "rejects appends when the anchor node is absent" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = AppendAfter (NodeId "missing") spec'

        case applyRewrite rewrite initialPlan of
          Left err ->
            show err `shouldContain` "RewriteAnchorMissingFromTopology"
          Right _ ->
            expectationFailure "Expected append with missing anchor to be rejected"

      it "rejects appends when the anchor node has no stage definition" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            invalidPlan =
              initialPlan
                { spTopology = toRelation (path [NodeId "a", NodeId "ghost", NodeId "c"] :: Graph NodeId)
                , spDefinitions =
                    Map.fromList
                      [ (NodeId "a", mkDef StageA)
                      , (NodeId "c", mkDef StageC)
                      ]
                , spTemplateRegistry =
                    templateRegistry $
                      Map.fromList
                        [ (NodeId "a", mkDef StageA)
                        , (NodeId "c", mkDef StageC)
                        ]
                }
            rewrite = AppendAfter (NodeId "ghost") spec'

        case applyRewrite rewrite invalidPlan of
          Left errs ->
            show errs `shouldContain` "RewriteAnchorMissingDefinition"
          Right _ ->
            expectationFailure "Expected append with missing anchor definition to be rejected"

    describe "rewrite validation" $ do
      it "rejects duplicate entry nodes before planning a rewrite" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1", NodeId "sub1"] [NodeId "sub2"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            errs `shouldContain` [RewriteDuplicateEntryNodes [NodeId "sub1"]]
          Right _ ->
            expectationFailure "Expected duplicate entry nodes to be rejected"

      it "rejects duplicate exit nodes before planning a rewrite" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2", NodeId "sub2"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            errs `shouldContain` [RewriteDuplicateExitNodes [NodeId "sub2"]]
          Right _ ->
            expectationFailure "Expected duplicate exit nodes to be rejected"

      it "rejects local inserted node ids containing the namespace delimiter" $ do
        let subTopo = toRelation (Vertex (NodeId "sub:1") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub:1", mkDef Sub1)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub:1"] [NodeId "sub:1"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            errs `shouldContain` [RewriteInvalidLocalNodeIds [NodeId "sub:1"]]
          Right _ ->
            expectationFailure "Expected namespace-delimiter local node id to be rejected"

      it "rejects empty local inserted node ids" $ do
        let subTopo = toRelation (Vertex (NodeId "") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "", mkDef Sub1)]
            spec' = SubgraphSpec subTopo subDefs [NodeId ""] [NodeId ""]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            errs `shouldContain` [RewriteInvalidLocalNodeIds [NodeId ""]]
          Right _ ->
            expectationFailure "Expected empty local node id to be rejected"

      it "rejects namespaced inserted nodes that collide with the current topology" $ do
        let collisionNode = NodeId "b:sub1"
            topoWithCollision = initialTopo <> toRelation (Vertex collisionNode :: Graph NodeId)
            defsWithCollision = Map.insert collisionNode (mkDef Sub1) initialDefs
            subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite topoWithCollision defsWithCollision of
          Left errs ->
            errs `shouldContain` [RewriteNamespacedNodeCollision [collisionNode]]
          Right _ ->
            expectationFailure "Expected namespaced inserted node collision to be rejected"

      it "rejects current definitions outside the current topology" $ do
        let staleNode = NodeId "stale"
            defsWithStale = Map.insert staleNode (mkDef Sub1) initialDefs
            subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite initialTopo defsWithStale of
          Left errs ->
            errs `shouldContain` [RewriteCurrentDefinitionsOutsideTopology [staleNode]]
          Right _ ->
            expectationFailure "Expected stale current definition to be rejected"

      it "rejects current topology nodes without definitions" $ do
        let ghostNode = NodeId "ghost"
            topoWithGhost = initialTopo <> toRelation (Vertex ghostNode :: Graph NodeId)
            subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
            rewrite = AppendAfter (NodeId "b") spec'

        case planGraphRewrite rewrite topoWithGhost initialDefs of
          Left errs ->
            errs `shouldContain` [RewriteCurrentDefinitionsMissing [ghostNode]]
          Right _ ->
            expectationFailure "Expected current topology node without definition to be rejected"

    describe "planGraphRewrite proof-shaped delta" $ do
      let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
          entry = NodeId "b:sub1"
          exit = NodeId "b:sub2"
          assertDelta
            rewrite
            expectedDisposition
            expectedRemoved
            expectedAddedEdges
            expectedDepth = do
              case planGraphRewrite rewrite initialTopo initialDefs of
                Left errs ->
                  expectationFailure $ "planGraphRewrite failed: " <> show errs
                Right delta -> do
                  prdAnchorNode delta `shouldBe` NodeId "b"
                  prdAnchorDisposition delta `shouldBe` expectedDisposition
                  prdEntryNodes delta `shouldBe` [entry]
                  prdExitNodes delta `shouldBe` [exit]
                  prdNewNodes delta `shouldBe` Set.fromList [entry, exit]
                  prdRemovedNodes delta `shouldBe` expectedRemoved
                  prdAddedEdges delta `shouldBe` expectedAddedEdges
                  Map.keysSet (prdDefinitions delta)
                    `shouldBe` Set.union (Set.difference (Map.keysSet initialDefs) expectedRemoved) (Set.fromList [entry, exit])
                  prdCost delta
                    `shouldBe` RewriteCost
                      { rcAddedNodes = 2
                      , rcAddedEdges = fromIntegral (Set.size expectedAddedEdges)
                      , rcAddedDepth = expectedDepth
                      , rcFrontierDelta = 0
                      , rcRewriteOps = 1
                      }

      it "constructs replace-node deltas from the planned relation formula" $ do
        assertDelta
          (ExpandNode (NodeId "b") ExpandReplaceNode spec')
          RewriteAnchorRemoved
          (Set.singleton (NodeId "b"))
          (Set.fromList [(NodeId "a", entry), (entry, exit), (exit, NodeId "c")])
          1

      it "constructs retained-envelope deltas from the planned relation formula" $ do
        assertDelta
          (ExpandNode (NodeId "b") ExpandRetainNodeAsEnvelope spec')
          RewriteAnchorRetained
          Set.empty
          (Set.fromList [(NodeId "b", entry), (entry, exit), (exit, NodeId "c")])
          2

      it "constructs append-after deltas from the planned relation formula" $ do
        assertDelta
          (AppendAfter (NodeId "b") spec')
          RewriteAnchorRetained
          Set.empty
          (Set.fromList [(NodeId "b", entry), (entry, exit), (exit, NodeId "c")])
          2

    describe "rewrite budgeting" $ do
      it "computes structural rewrite cost and decrements remaining budget pointwise" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = ExpandNode (NodeId "b") ExpandReplaceNode spec'
            remaining =
              RewriteBudget
                { rbAddedNodesMax = 5
                , rbAddedEdgesMax = 6
                , rbAddedDepthMax = 4
                , rbFrontierDeltaMax = 2
                , rbRewriteOpsMax = 3
                }

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            expectationFailure $ "planGraphRewrite failed: " <> show errs
          Right delta -> do
            prdCost delta
              `shouldBe` RewriteCost
                { rcAddedNodes = 2
                , rcAddedEdges = 3
                , rcAddedDepth = 1
                , rcFrontierDelta = 0
                , rcRewriteOps = 1
                }
            consumeRewriteBudget remaining (prdCost delta)
              `shouldBe` Right
                RewriteBudget
                  { rbAddedNodesMax = 3
                  , rbAddedEdgesMax = 3
                  , rbAddedDepthMax = 3
                  , rbFrontierDeltaMax = 2
                  , rbRewriteOpsMax = 2
                  }

      it "rejects rewrites whose structural cost exceeds the remaining budget" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = AppendAfter (NodeId "b") spec'
            remaining =
              RewriteBudget
                { rbAddedNodesMax = 2
                , rbAddedEdgesMax = 2
                , rbAddedDepthMax = 1
                , rbFrontierDeltaMax = 0
                , rbRewriteOpsMax = 1
                }

        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            expectationFailure $ "planGraphRewrite failed: " <> show errs
          Right delta ->
            consumeRewriteBudget remaining (prdCost delta)
              `shouldBe` Left (RewriteBudgetExceeded remaining (prdCost delta))

      it "admitRewriteDelta bundles budget check with delta" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = ExpandNode (NodeId "b") ExpandReplaceNode spec'
            remaining = defaultRewriteBudget
        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            expectationFailure $ "planGraphRewrite failed: " <> show errs
          Right delta ->
            case admitRewriteDelta remaining delta of
              Left _ -> expectationFailure "admitRewriteDelta should succeed within budget"
              Right admitted ->
                consumeRewriteBudget remaining (prdCost delta)
                  `shouldBe` Right (admittedRemainingBudget admitted)

      it "admitRewriteDelta rejects over-budget deltas" $ do
        let subTopo = toRelation (edge (NodeId "sub1") (NodeId "sub2") :: Graph NodeId)
            subDefs = Map.fromList [(NodeId "sub1", mkDef Sub1), (NodeId "sub2", mkDef Sub2)]
            spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub2"]
            rewrite = AppendAfter (NodeId "b") spec'
            remaining =
              RewriteBudget
                { rbAddedNodesMax = 2
                , rbAddedEdgesMax = 2
                , rbAddedDepthMax = 1
                , rbFrontierDeltaMax = 0
                , rbRewriteOpsMax = 1
                }
        case planGraphRewrite rewrite initialTopo initialDefs of
          Left errs ->
            expectationFailure $ "planGraphRewrite failed: " <> show errs
          Right delta ->
            case admitRewriteDelta remaining delta of
              Left budgetErr ->
                budgetErr `shouldBe` RewriteBudgetExceeded remaining (prdCost delta)
              Right _ ->
                expectationFailure "admitRewriteDelta should reject over-budget delta"

      it "exceededDimensions reports which budget dimensions were exceeded" $ do
        let budgetErr =
              RewriteBudgetExceeded
                RewriteBudget
                  { rbAddedNodesMax = 2
                  , rbAddedEdgesMax = 10
                  , rbAddedDepthMax = 1
                  , rbFrontierDeltaMax = 0
                  , rbRewriteOpsMax = 1
                  }
                RewriteCost
                  { rcAddedNodes = 4
                  , rcAddedEdges = 3
                  , rcAddedDepth = 2
                  , rcFrontierDelta = 0
                  , rcRewriteOps = 0
                  }
            dims = exceededDimensions budgetErr
        fmap (\d -> (edDimension d, edRequested d, edRemaining d)) dims
          `shouldBe` [(DimAddedNodes, 4, 2), (DimAddedDepth, 2, 1)]

      it "rejects serialized negative rewrite costs before admission" $ do
        let negativeCostJson =
              Aeson.object
                [ "rcAddedNodes" Aeson..= (-1 :: Int)
                , "rcAddedEdges" Aeson..= (0 :: Int)
                , "rcAddedDepth" Aeson..= (0 :: Int)
                , "rcFrontierDelta" Aeson..= (0 :: Int)
                , "rcRewriteOps" Aeson..= (0 :: Int)
                ]

        case Aeson.fromJSON negativeCostJson :: Aeson.Result RewriteCost of
          Aeson.Error _err -> pure ()
          Aeson.Success cost ->
            expectationFailure $
              "Expected negative rewrite cost to fail JSON decoding, got: " <> show cost

      it "rejects serialized negative rewrite budgets before runtime use" $ do
        let negativeBudgetJson =
              Aeson.object
                [ "rbAddedNodesMax" Aeson..= (-1 :: Int)
                , "rbAddedEdgesMax" Aeson..= (0 :: Int)
                , "rbAddedDepthMax" Aeson..= (0 :: Int)
                , "rbFrontierDeltaMax" Aeson..= (0 :: Int)
                , "rbRewriteOpsMax" Aeson..= (0 :: Int)
                ]

        case Aeson.fromJSON negativeBudgetJson :: Aeson.Result RewriteBudget of
          Aeson.Error _err -> pure ()
          Aeson.Success budget ->
            expectationFailure $
              "Expected negative rewrite budget to fail JSON decoding, got: " <> show budget

  describe "buildStageTemplateRegistry" $ do
    let mkDynDef nid templateId =
          ( nid
          , StageDefinition
              { sdStageId = StageA
              , sdTemplateId = templateId
              , sdActionId = stageActionId StageA
              , sdReplaySafety = SafeToReplay
              , sdReplayPolicyOverride = Nothing
              , sdTimeoutSeconds = Nothing
              , sdRetryPolicy = Nothing
              , sdAction = \_ -> pure (error "not implemented")
              , sdMemoryStrategy = defaultMemoryStrategy
              }
          )
        mkRetryPolicy name retryable =
          Just
            StageRetryPolicy
              { srpPredicateName = name
              , srpMaxAttempts = 3
              , srpBackoff = FixedBackoffMicros 1000
              , srpRetryable = retryable
              , srpExhaustion = ExhaustionFailsRun
              }

    it "allows equivalent duplicate template ids for rewritten clones" $ do
      let sharedTemplate = StageTemplateId "shared/template"
          defs =
            Map.fromList
              [ mkDynDef (NodeId "template_registry") sharedTemplate
              , mkDynDef (NodeId "alpha:shared") sharedTemplate
              ]

      case buildStageTemplateRegistry defs of
        Left err ->
          expectationFailure $
            "Expected equivalent duplicate template ids to be accepted, got: " <> T.unpack err
        Right registry ->
          Map.keysSet registry `shouldBe` Set.singleton sharedTemplate

    it "rejects duplicate template ids in the runtime registry" $ do
      let defs =
            Map.fromList
              [ mkDynDef (NodeId "template_a") (StageTemplateId "shared/template")
              ,
                ( NodeId "template_b"
                , StageDefinition
                    { sdStageId = StageB
                    , sdTemplateId = StageTemplateId "shared/template"
                    , sdActionId = stageActionId StageB
                    , sdReplaySafety = SafeToReplay
                    , sdReplayPolicyOverride = Nothing
                    , sdTimeoutSeconds = Nothing
                    , sdRetryPolicy = Nothing
                    , sdAction = \_ -> pure (error "not implemented")
                    , sdMemoryStrategy = defaultMemoryStrategy
                    }
                )
              ]

      case buildStageTemplateRegistry defs of
        Left err -> do
          err `shouldSatisfy` T.isInfixOf "Duplicate stage template definition found"
          err `shouldSatisfy` T.isInfixOf "shared/template"
        Right _ ->
          expectationFailure "Expected duplicate stage template ids to be rejected"

    it "rejects duplicate template ids when retry predicate names differ" $ do
      let sharedTemplate = StageTemplateId "shared/template"
          defs =
            Map.fromList
              [
                ( NodeId "template_a"
                , (snd (mkDynDef (NodeId "template_a") sharedTemplate))
                    { sdRetryPolicy = mkRetryPolicy "always_retry" (const True)
                    }
                )
              ,
                ( NodeId "template_b"
                , (snd (mkDynDef (NodeId "template_b") sharedTemplate))
                    { sdRetryPolicy = mkRetryPolicy "never_retry" (const False)
                    }
                )
              ]

      case buildStageTemplateRegistry defs of
        Left err -> do
          err `shouldSatisfy` T.isInfixOf "Duplicate stage template definition found"
          err `shouldSatisfy` T.isInfixOf "shared/template"
        Right _ ->
          expectationFailure "Expected duplicate retry predicate names to be rejected"

  describe "computeTopologyHash" $ do
    it "is deterministic — same topology produces the same hash" $ do
      let topo = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
      computeTopologyHash topo `shouldBe` computeTopologyHash topo

    it "differs for topologies that differ by one edge" $ do
      let topo1 = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          topo2 = toRelation (path [NodeId "a", NodeId "b", NodeId "c"] <> edge (NodeId "a") (NodeId "c"))
      computeTopologyHash topo1 `shouldNotBe` computeTopologyHash topo2

    it "differs for topologies that differ by one vertex" $ do
      let topo1 = toRelation (path [NodeId "a", NodeId "b"])
          topo2 = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
      computeTopologyHash topo1 `shouldNotBe` computeTopologyHash topo2

templateRegistry
  :: Eq stageId
  => Map.Map NodeId (StageDefinition stageId)
  -> Map.Map StageTemplateId (StageDefinition stageId)
templateRegistry defs =
  either (error . T.unpack) id (buildStageTemplateRegistry defs)
