{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for 'Cortex.Pulse.Memory' (DIG-529).
--
-- Three groups:
--
--   * 'walkCandidates' — ancestor / descendant / scope / hop-count.
--   * 'composeScore' / 'tokenJaccard' / 'clamp01' — the scoring axes.
--   * 'pureQueryMemory' — end-to-end against a fixed snapshot, plus
--     the determinism property (same inputs ⇒ same outputs).
module Cortex.Pulse.MemorySpec (spec) where

import Cortex.Graph
  ( Relation,
    edges,
    toRelation,
    vertices,
  )
import Cortex.Pulse.Memory
import Cortex.Pulse.Memory.Score
  ( clamp01,
    composeScore,
    temporalDistanceScore,
    tokenJaccard,
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Runtime (NodeStatus (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Test.Hspec

-- ============================================================================
-- Fixtures
-- ============================================================================

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 4 22) (secondsToDiffTime 0)

tAt :: Integer -> UTCTime
tAt secs = addUTCTime (fromIntegral secs) t0

nid :: Text -> NodeId
nid = NodeId

-- | Planner → {Analyst-A, Analyst-B, Analyst-C} → Reviewer.  The
-- canonical DIG-507-shaped fan-out used across several specs.
fanoutTopology :: Relation NodeId
fanoutTopology =
  toRelation
    ( edges
        [ (nid "planner", nid "analyst-a"),
          (nid "planner", nid "analyst-b"),
          (nid "planner", nid "analyst-c"),
          (nid "analyst-a", nid "reviewer"),
          (nid "analyst-b", nid "reviewer"),
          (nid "analyst-c", nid "reviewer")
        ]
    )

singleNodeTopology :: Relation NodeId
singleNodeTopology = toRelation (vertices [nid "only"])

-- | All analysts settled; planner settled; reviewer pending.
fanoutStatuses :: Map NodeId NodeStatus
fanoutStatuses =
  Map.fromList
    [ (nid "planner", NodeCompleted),
      (nid "analyst-a", NodeCompleted),
      (nid "analyst-b", NodeCompleted),
      (nid "analyst-c", NodeCompleted),
      (nid "reviewer", NodePending)
    ]

fanoutOutputs :: Map NodeId Aeson.Value
fanoutOutputs =
  Map.fromList
    [ (nid "planner", Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan details" :: Text)]),
      (nid "analyst-a", Aeson.object ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("alpha revenue grew 12 percent" :: Text)]),
      (nid "analyst-b", Aeson.object ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("beta revenue grew 5 percent" :: Text)]),
      (nid "analyst-c", Aeson.object ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("gamma revenue declined 3 percent" :: Text)])
    ]

fanoutCompletedAt :: Map NodeId UTCTime
fanoutCompletedAt =
  Map.fromList
    [ (nid "planner", tAt 0),
      (nid "analyst-a", tAt 10),
      (nid "analyst-b", tAt 20),
      (nid "analyst-c", tAt 30)
    ]

fanoutSnapshot :: MemorySnapshot
fanoutSnapshot =
  MemorySnapshot
    { msTopology = fanoutTopology,
      msNodeStatuses = fanoutStatuses,
      msNodeOutputs = fanoutOutputs,
      msNodeCompletedAt = fanoutCompletedAt,
      msCapturedAt = tAt 60
    }

-- | Merge-vs-chain shape: from @origin@, @merge@ is reached via two
-- disjoint paths (@origin → p1 → merge@ and @origin → p2 → merge@)
-- while @chain@ is reached via a single linear path
-- (@origin → link → chain@).  Both @merge@ and @chain@ sit at hop
-- distance 2, so 'graphDistanceScore' would tie them under the old
-- hop-count axis.  Random-walk influence rewards the merge for the
-- aggregate mass flowing through its two parents.
mergeVsChainTopology :: Relation NodeId
mergeVsChainTopology =
  toRelation
    ( edges
        [ (nid "origin", nid "p1"),
          (nid "origin", nid "p2"),
          (nid "p1", nid "merge"),
          (nid "p2", nid "merge"),
          (nid "origin", nid "link"),
          (nid "link", nid "chain")
        ]
    )

mergeVsChainStatuses :: Map NodeId NodeStatus
mergeVsChainStatuses =
  Map.fromList
    [ (nid "origin", NodeCompleted),
      (nid "p1", NodeCompleted),
      (nid "p2", NodeCompleted),
      (nid "merge", NodeCompleted),
      (nid "link", NodeCompleted),
      (nid "chain", NodeCompleted)
    ]

mergeVsChainOutputs :: Map NodeId Aeson.Value
mergeVsChainOutputs =
  Map.fromList
    [ (nid "p1", Aeson.object ["text" Aeson..= ("p1 body" :: Text)]),
      (nid "p2", Aeson.object ["text" Aeson..= ("p2 body" :: Text)]),
      (nid "merge", Aeson.object ["text" Aeson..= ("merge body" :: Text)]),
      (nid "link", Aeson.object ["text" Aeson..= ("link body" :: Text)]),
      (nid "chain", Aeson.object ["text" Aeson..= ("chain body" :: Text)])
    ]

mergeVsChainCompletedAt :: Map NodeId UTCTime
mergeVsChainCompletedAt =
  Map.fromList
    [ (nid "origin", tAt 0),
      (nid "p1", tAt 10),
      (nid "p2", tAt 10),
      (nid "merge", tAt 20),
      (nid "link", tAt 10),
      (nid "chain", tAt 20)
    ]

mergeVsChainSnapshot :: MemorySnapshot
mergeVsChainSnapshot =
  MemorySnapshot
    { msTopology = mergeVsChainTopology,
      msNodeStatuses = mergeVsChainStatuses,
      msNodeOutputs = mergeVsChainOutputs,
      msNodeCompletedAt = mergeVsChainCompletedAt,
      msCapturedAt = tAt 60
    }

bidirectionalBridgeTopology :: Relation NodeId
bidirectionalBridgeTopology =
  toRelation
    ( edges
        [ (nid "a", nid "b"),
          (nid "c", nid "b")
        ]
    )

bidirectionalBridgeStatuses :: Map NodeId NodeStatus
bidirectionalBridgeStatuses =
  Map.fromList
    [ (nid "a", NodeCompleted),
      (nid "b", NodeCompleted),
      (nid "c", NodeCompleted)
    ]

bidirectionalBridgeOutputs :: Map NodeId Aeson.Value
bidirectionalBridgeOutputs =
  Map.fromList
    [ (nid "b", Aeson.object ["text" Aeson..= ("shared descendant" :: Text)]),
      (nid "c", Aeson.object ["text" Aeson..= ("side ancestor" :: Text)])
    ]

bidirectionalBridgeCompletedAt :: Map NodeId UTCTime
bidirectionalBridgeCompletedAt =
  Map.fromList
    [ (nid "a", tAt 0),
      (nid "b", tAt 10),
      (nid "c", tAt 20)
    ]

bidirectionalBridgeSnapshot :: MemorySnapshot
bidirectionalBridgeSnapshot =
  MemorySnapshot
    { msTopology = bidirectionalBridgeTopology,
      msNodeStatuses = bidirectionalBridgeStatuses,
      msNodeOutputs = bidirectionalBridgeOutputs,
      msNodeCompletedAt = bidirectionalBridgeCompletedAt,
      msCapturedAt = tAt 60
    }

-- | Extractor: pick the @"text"@ field from analyst-shaped JSONB.
textExtractor :: Aeson.Value -> Maybe ExtractedFields
textExtractor (Aeson.Object obj) =
  case KeyMap.lookup "text" obj of
    Just (Aeson.String bodyText) ->
      let slot = case KeyMap.lookup "slot" obj of
            Just (Aeson.String s) -> Just s
            _ -> Nothing
       in Just
            ExtractedFields
              { efRoutingKey = slot,
                efBodyText = bodyText,
                efEvidence = []
              }
    _ -> Nothing
textExtractor _ = Nothing

-- ============================================================================
-- Spec
-- ============================================================================

spec :: Spec
spec = do
  describe "walkCandidates (via pureQueryMemory)" $ do
    it "ancestors from reviewer reach every analyst and the planner" $ do
      let walkSpec =
            WalkSpec
              { wsDirection = Ancestors,
                wsScope = SettledOnly,
                wsWeights = defaultScoreWeights,
                wsLimit = Nothing
              }
          query =
            emptyQuery
              { qExtractor = textExtractor,
                qSemanticScorer = nullSemanticScorer
              }
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      fmap moNodeId matches
        `shouldMatchList` [nid "planner", nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "ancestors from analyst-a reach only the planner" $ do
      let walkSpec = defaultWalkSpec
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "analyst-a") fanoutSnapshot walkSpec query
      fmap moNodeId matches `shouldBe` [nid "planner"]

    it "descendants from planner reach every analyst (reviewer filtered by scope)" $ do
      let walkSpec =
            defaultWalkSpec
              { wsDirection = Descendants
              }
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "planner") fanoutSnapshot walkSpec query
      -- Reviewer is NodePending, so scope SettledOnly drops it.
      fmap moNodeId matches
        `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "DebugAllStatuses scope still drops candidates with no output payload" $ do
      let walkSpec =
            defaultWalkSpec
              { wsDirection = Descendants,
                wsScope = DebugAllStatuses
              }
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "planner") fanoutSnapshot walkSpec query
      fmap moNodeId matches
        `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "origin itself is always excluded" $ do
      let walkSpec = defaultWalkSpec
          query = emptyQuery
          matches = pureQueryMemory (nid "analyst-a") fanoutSnapshot walkSpec query
      notElem (nid "analyst-a") (fmap moNodeId matches) `shouldBe` True

    it "max-graph-distance cutoff limits hop reach" $ do
      let walkSpec =
            defaultWalkSpec
              { wsDirection = Ancestors,
                wsWeights = defaultScoreWeights {swMaxGraphDistance = Just 1}
              }
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      fmap moNodeId matches
        `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "single-node topology produces no matches from the only node" $ do
      let snap =
            emptyMemorySnapshot (tAt 0) singleNodeTopology
          query = emptyQuery
          matches = pureQueryMemory (nid "only") snap defaultWalkSpec query
      matches `shouldBe` []

    it "bidirectional walk stays within the ancestor-or-descendant union" $ do
      -- Shape: a → b ← c.  From a, 'Bidirectional' BFS unions the
      -- pure-ancestor walk (empty from a) and pure-descendant walk
      -- (reaches b).  c is neither an ancestor nor a descendant of
      -- a and must not appear.  The previous PFS path that collapsed
      -- bidirectional into a single @topology <> transpose@ overlay
      -- reached c via alternating-direction edges; this test pins
      -- the correct semantics.
      let walkSpec =
            WalkSpec
              { wsDirection = Bidirectional,
                wsScope = SettledOnly,
                wsWeights = defaultScoreWeights,
                wsLimit = Nothing
              }
          matches =
            pureQueryMemory (nid "a") bidirectionalBridgeSnapshot walkSpec emptyQuery
      fmap moNodeId matches `shouldBe` [nid "b"]

  describe "random-walk influence axis" $ do
    it "ranks a merge node above a single-chain node at equal hop distance" $ do
      -- Shape: origin → {p1, p2} → merge, and origin → link → chain.
      -- Both 'merge' and 'chain' are 2 hops from origin.  Hop-count
      -- scoring would tie them; random-walk influence gives 'merge'
      -- more mass because two of origin's out-edges flow into it.
      let walkSpec =
            defaultWalkSpec
              { wsDirection = Descendants,
                wsWeights =
                  ScoreWeights
                    { swGraphDistance = 1,
                      swTemporalDistance = 0,
                      swSemantic = 0,
                      swMaxGraphDistance = Nothing
                    }
              }
          query = emptyQuery {qExtractor = textExtractor}
          matches =
            pureQueryMemory (nid "origin") mergeVsChainSnapshot walkSpec query
          scoreOf target =
            case filter (\m -> moNodeId m == target) matches of
              (m : _) -> moScore m
              [] -> error ("expected " <> show target <> " in matches")
      scoreOf (nid "merge") `shouldSatisfy` (> scoreOf (nid "chain"))

  describe "composeScore / clamp01 / tokenJaccard" $ do
    it "clamp01 is total on NaN, negative, and >1 inputs" $ do
      clamp01 (0 / 0) `shouldBe` 0
      clamp01 (-1) `shouldBe` 0
      clamp01 1.5 `shouldBe` 1
      clamp01 0.3 `shouldBe` 0.3

    it "tokenJaccard is symmetric and bounded in [0,1]" $ do
      tokenJaccard "alpha beta" "beta alpha" `shouldBe` 1
      tokenJaccard "alpha beta" "gamma delta" `shouldBe` 0
      let s = tokenJaccard "alpha beta gamma" "beta gamma delta"
      s `shouldSatisfy` (\x -> x > 0 && x < 1)
      s `shouldBe` tokenJaccard "beta gamma delta" "alpha beta gamma"

    it "temporalDistanceScore freshest=1, decays with age" $ do
      let now = tAt 3600 -- one hour after t0
      temporalDistanceScore now now `shouldBe` 1
      temporalDistanceScore now t0 `shouldBe` 0.5
      temporalDistanceScore t0 now `shouldBe` 1

    it "composeScore passes through the graph-axis influence value" $ do
      let weights =
            ScoreWeights
              { swGraphDistance = 1,
                swTemporalDistance = 0,
                swSemantic = 0,
                swMaxGraphDistance = Nothing
              }
          score =
            composeScore
              weights
              0.4 -- influence value
              (tAt 0)
              Nothing
              tokenJaccard
              Nothing
              "any body text"
      -- graph axis: weight 1 * influence 0.4 = 0.4.  Temporal + semantic zero.
      score `shouldBe` 0.4

    it "composeScore zeros out the semantic axis when no query text" $ do
      let weights = defaultScoreWeights
          score =
            composeScore
              weights
              1 -- full influence contribution
              (tAt 0)
              Nothing
              tokenJaccard
              Nothing
              "any body text"
      -- weights are 1/1/1; graph=1, temporal=0, semantic=0 ⇒ clamp01 1 = 1
      score `shouldBe` 1

    it "composeScore weights each axis multiplicatively" $ do
      let weights =
            ScoreWeights
              { swGraphDistance = 0,
                swTemporalDistance = 0,
                swSemantic = 1,
                swMaxGraphDistance = Nothing
              }
          score =
            composeScore
              weights
              1 -- ignored because graph weight is 0
              (tAt 0)
              (Just (tAt 0))
              tokenJaccard
              (Just "alpha beta")
              "alpha beta"
      -- graph=0 (weight 0), temporal=0 (weight 0), semantic=1 (weight 1)
      score `shouldBe` 1

  describe "pureQueryMemory — determinism and ordering" $ do
    it "is deterministic: same inputs yield identical outputs" $ do
      let walkSpec = defaultWalkSpec
          query = emptyQuery {qExtractor = textExtractor}
          a = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
          b = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      a `shouldBe` b

    it "filters by routing key" $ do
      let walkSpec = defaultWalkSpec
          query =
            emptyQuery
              { qExtractor = textExtractor,
                qRoutingKey = Just "analyst"
              }
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      fmap moNodeId matches
        `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "sort is (score DESC, graphDistance ASC, NodeId ASC)" $ do
      let walkSpec =
            defaultWalkSpec
              { wsWeights =
                  ScoreWeights
                    { swGraphDistance = 1,
                      swTemporalDistance = 0,
                      swSemantic = 0,
                      swMaxGraphDistance = Nothing
                    }
              }
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      -- Random-walk influence from the reviewer (walking the
      -- transposed topology): each direct-predecessor analyst gets
      -- α/3 ≈ 0.283; the planner collects mass from all three
      -- analysts, α² * 3 / 3 = α² ≈ 0.722 — the "merges beat chains"
      -- property in action.  Planner therefore ranks above the
      -- analysts, and the three analysts tie-break by NodeId.
      fmap moNodeId matches
        `shouldBe` [nid "planner", nid "analyst-a", nid "analyst-b", nid "analyst-c"]

    it "applies wsLimit after sort" $ do
      let walkSpec = defaultWalkSpec {wsLimit = Just 2}
          query = emptyQuery {qExtractor = textExtractor}
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      length matches `shouldBe` 2

    it "returns empty when the origin has no ancestors and scope is SettledOnly" $ do
      let walkSpec = defaultWalkSpec
          query = emptyQuery
          matches = pureQueryMemory (nid "planner") fanoutSnapshot walkSpec query
      matches `shouldBe` []

    it "drops candidates whose routing key disagrees with qRoutingKey" $ do
      let walkSpec = defaultWalkSpec
          query =
            emptyQuery
              { qExtractor = textExtractor,
                qRoutingKey = Just "nonexistent-slot"
              }
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      matches `shouldBe` []

    it "surfaces extracted fields on matches" $ do
      let walkSpec = defaultWalkSpec
          query = emptyQuery {qExtractor = textExtractor, qRoutingKey = Just "analyst"}
          matches = pureQueryMemory (nid "reviewer") fanoutSnapshot walkSpec query
      [efBodyText ef | m <- matches, Just ef <- [moExtracted m]]
        `shouldMatchList` [ "alpha revenue grew 12 percent",
                            "beta revenue grew 5 percent",
                            "gamma revenue declined 3 percent"
                          ]

  describe "MemoryHandle" $ do
    it "newMemoryHandle returns the bound snapshot on every call" $ do
      let handle = newMemoryHandle fanoutSnapshot
      snap1 <- handle.memorySnapshot
      snap2 <- handle.memorySnapshot
      snap1 `shouldBe` snap2
      snap1 `shouldBe` fanoutSnapshot

    it "discardMemoryHandle returns no matches for any query" $ do
      let handle = discardMemoryHandle
      matches <- handle.queryMemory (nid "reviewer") defaultWalkSpec emptyQuery
      matches `shouldBe` []
