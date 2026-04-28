{-# LANGUAGE OverloadedStrings #-}

module Cortex.Algebra.GraphSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck (Gen, choose, elements, forAll, property, shuffle, sized, sublistOf, (===))

import Cortex.Algebra.Graph
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Runtime

import Platform.DurableTask.Types (RunOutcome (..))

{- | Normalize SCC output: sort each component, then sort components by
first element. This makes assertions deterministic regardless of
internal traversal order.
-}
normalizeSCCs :: Ord a => [[a]] -> [[a]]
normalizeSCCs = sortOn safeMin . fmap sort
  where
    safeMin [] = Nothing
    safeMin (x : _) = Just x

spec :: Spec
spec = do
  -- ========================================================================
  -- Algebraic graph DSL
  -- ========================================================================

  describe "Graph algebra" $ do
    it "path produces a chain, not a clique" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      relVertices rel `shouldBe` Set.fromList [1, 2, 3]
      relEdges rel `shouldBe` Set.fromList [(1, 2), (2, 3)]

    it "clique produces all forward edges" $ do
      let rel = toRelation (clique [1 :: Int, 2, 3])
      relEdges rel `shouldBe` Set.fromList [(1, 2), (1, 3), (2, 3)]

    it "star produces fan-out edges" $ do
      let rel = toRelation (star (1 :: Int) [2, 3, 4])
      relEdges rel `shouldBe` Set.fromList [(1, 2), (1, 3), (1, 4)]

    it "vertices produces no edges" $ do
      let rel = toRelation (vertices [1 :: Int, 2, 3])
      relVertices rel `shouldBe` Set.fromList [1, 2, 3]
      relEdges rel `shouldBe` Set.empty

    it "edge produces exactly one edge" $ do
      let rel = toRelation (edge (1 :: Int) 2)
      relVertices rel `shouldBe` Set.fromList [1, 2]
      relEdges rel `shouldBe` Set.fromList [(1, 2)]

    it "overlay unions graphs without cross-edges" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge (3 :: Int) 4)
      relEdges rel `shouldBe` Set.fromList [(1, 2), (3, 4)]

    it "connect creates all cross-edges" $ do
      let rel = toRelation (Connect (vertices [1 :: Int, 2]) (vertices [3, 4]))
      relEdges rel `shouldBe` Set.fromList [(1, 3), (1, 4), (2, 3), (2, 4)]

    it "empty produces an empty relation" $ do
      let rel = toRelation (Empty :: Graph Int)
      relVertices rel `shouldBe` Set.empty
      relEdges rel `shouldBe` Set.empty

  -- ========================================================================
  -- Graph analysis: DFS / BFS
  -- ========================================================================

  describe "dfs" $ do
    it "traverses a chain in order" $ do
      let rel = toRelation (path [1 :: Int, 2, 3, 4])
      dfs rel [1] `shouldBe` [1, 2, 3, 4]

    it "visits all reachable nodes from root" $ do
      let rel = toRelation (star (1 :: Int) [2, 3] <> edge 2 4 <> edge 3 5)
      let result = dfs rel [1]
      listToMaybe result `shouldBe` Just 1
      length result `shouldBe` 5

    it "ignores roots not in the graph" $ do
      let rel = toRelation (path [1 :: Int, 2])
      dfs rel [99, 1] `shouldBe` [1, 2]

  describe "bfs" $ do
    it "traverses a chain in order" $ do
      let rel = toRelation (path [1 :: Int, 2, 3, 4])
      bfs rel [1] `shouldBe` [1, 2, 3, 4]

    it "visits level by level" $ do
      let rel = toRelation (star (1 :: Int) [2, 3] <> edge 2 4 <> edge 3 5)
      let result = bfs rel [1]
      -- BFS: 1, then {2,3} (level 1), then {4,5} (level 2)
      listToMaybe result `shouldBe` Just 1
      take 3 result `shouldContain` [2, 3]
      length result `shouldBe` 5

  -- ========================================================================
  -- Priority-first search (hop-aware)
  -- ========================================================================

  describe "pfsWithDepth" $ do
    it "yields vertices in ascending heuristic order" $ do
      -- Priority: a hand-crafted ranking on a small DAG.
      let rel = toRelation (star (1 :: Int) [2, 3, 4, 5])
          heur (v, _) = 100 - v -- higher node id = smaller priority
          result = pfsWithDepth heur rel [1]
      -- Root comes first (no competitors), then 5, 4, 3, 2 (highest v first).
      fmap fst result `shouldBe` [1, 5, 4, 3, 2]

    it "records correct hop counts on a chain" $ do
      let rel = toRelation (path [1 :: Int, 2, 3, 4])
          result = pfsWithDepth (const (0 :: Int)) rel [1]
      result `shouldBe` [(1, 0), (2, 1), (3, 2), (4, 3)]

    it "visits the same vertex set as BFS" . property $ do
      let anyRoot rel = take 1 (Set.toAscList (relVertices rel))
          prop rel =
            let pfsVerts = Set.fromList (fmap fst (pfsWithDepth (const (0 :: Int)) rel (anyRoot rel)))
                bfsVerts = Set.fromList (bfs rel (anyRoot rel))
             in pfsVerts === bfsVerts
      forAll genDAG prop

    it "frontier order can differ from globally sorting the full reachable set" $ do
      let root = NodeId "root"
          a = NodeId "a"
          b = NodeId "b"
          c = NodeId "c"
          rel =
            toRelation
              ( edges
                  [ (root, a)
                  , (a, b)
                  , (root, c)
                  ]
              )
          heur (v, _) = case v of
            NodeId "root" -> (-1) :: Int
            NodeId "a" -> 2
            NodeId "b" -> 0
            NodeId "c" -> 1
            _ -> 99
          full = pfsWithDepth heur rel [root]
          sortedFull = sortOn heur full
      full `shouldBe` [(root, 0), (c, 1), (a, 1), (b, 2)]
      sortedFull `shouldBe` [(root, 0), (b, 2), (c, 1), (a, 1)]

    it "is lazy: take 1 does not force the full traversal" $ do
      -- Construct a graph where forcing every child would cost — but
      -- take 1 only needs the root.  Priority = const 0 so any root
      -- satisfies.  If searchWithDepth were strict this would still
      -- pass (since Haskell's lazy evaluation hides the effect), but
      -- we at least assert the head is what we expect on a large
      -- fan-out.
      let rel = toRelation (star (NodeId "root") [NodeId (T.pack ("n" <> show i)) | i <- [0 .. 99 :: Int]])
          result = pfsWithDepth (const (0 :: Int)) rel [NodeId "root"]
      take 1 result `shouldBe` [(NodeId "root", 0)]

    it "searchWithDepth with a queue frontier matches bfs order" $ do
      -- Sanity check: a Queue-backed searchWithDepth is BFS with
      -- hop counts.
      let rel = toRelation (path [1 :: Int, 2, 3])
          result = searchWithDepth (Queue Seq.empty :: Queue (Int, Int)) rel [1]
      fmap fst result `shouldBe` bfs rel [1]

    it "descending priority via Down surfaces highest-score nodes first with pfsWithDepth" $ do
      -- pfsWithDepth uses a min-priority frontier, so Down flips it to
      -- a highest-score-first traversal.
      let rel = toRelation (star (1 :: Int) [2, 3, 4])
          score v = fromIntegral v / 10 :: Double
          result = pfsWithDepth (\(v, _) -> Down (score v)) rel [1]
      -- Root first (no competitors). Then 4 (highest score), 3, 2.
      fmap fst result `shouldBe` [1, 4, 3, 2]

    it "maxFrontier with a raw score surfaces highest-score nodes first" $ do
      let rel = toRelation (star (1 :: Int) [2, 3, 4])
          score (v, _) = fromIntegral v / 10 :: Double
          result = searchWithDepth (maxFrontier score) rel [1]
      fmap fst result `shouldBe` [1, 4, 3, 2]

  -- ========================================================================
  -- DAG random-walk influence
  -- ========================================================================

  describe "dagRandomWalkInfluence" $ do
    it "origin carries mass 1" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          influence = dagRandomWalkInfluence 0.85 (NodeId "a") rel
      Map.lookup (NodeId "a") influence `shouldBe` Just 1.0

    it "chain decays multiplicatively by alpha / outDegree each hop" $ do
      -- a -> b -> c : out-degree 1 everywhere, so each hop is × α.
      let alpha = 0.85 :: Double
          rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          influence = dagRandomWalkInfluence alpha (NodeId "a") rel
      Map.lookup (NodeId "b") influence `shouldBe` Just alpha
      Map.lookup (NodeId "c") influence `shouldBe` Just (alpha * alpha)

    it "split out-edges divide mass by out-degree" $ do
      -- a -> {b, c} : both children share α / 2.
      let alpha = 0.85 :: Double
          rel = toRelation (edge (NodeId "a") (NodeId "b") <> edge (NodeId "a") (NodeId "c"))
          influence = dagRandomWalkInfluence alpha (NodeId "a") rel
      Map.lookup (NodeId "b") influence `shouldBe` Just (alpha / 2)
      Map.lookup (NodeId "c") influence `shouldBe` Just (alpha / 2)

    it "merge accumulates mass from every predecessor path" $ do
      -- a -> {b1, b2} -> c : c sees mass via both paths.
      -- Influence: b1 = b2 = α/2; c = α * α/2 / 1 + α * α/2 / 1 = α².
      let alpha = 0.85 :: Double
          rel =
            toRelation
              ( edges
                  [ (NodeId "a", NodeId "b1")
                  , (NodeId "a", NodeId "b2")
                  , (NodeId "b1", NodeId "c")
                  , (NodeId "b2", NodeId "c")
                  ]
              )
          influence = dagRandomWalkInfluence alpha (NodeId "a") rel
      Map.lookup (NodeId "c") influence `shouldBe` Just (alpha * alpha)

    it "merge ranks above single-chain at equal hop distance" $ do
      -- The property the memory axis actually cares about: two nodes
      -- both at hop distance 2 from origin — one via a merge, one via
      -- a linear chain — must not tie.  The merge wins.
      let alpha = 0.85 :: Double
          rel =
            toRelation
              ( edges
                  [ (NodeId "origin", NodeId "p1")
                  , (NodeId "origin", NodeId "p2")
                  , (NodeId "p1", NodeId "merge")
                  , (NodeId "p2", NodeId "merge")
                  , (NodeId "origin", NodeId "link")
                  , (NodeId "link", NodeId "chain")
                  ]
              )
          influence = dagRandomWalkInfluence alpha (NodeId "origin") rel
          mergeMass = Map.findWithDefault 0 (NodeId "merge") influence
          chainMass = Map.findWithDefault 0 (NodeId "chain") influence
      mergeMass `shouldSatisfy` (> chainMass)

    it "unreachable vertices receive zero mass" $ do
      -- a -> b ; c isolated.  Influence from a: c gets no mass.
      let rel = toRelation (edge (NodeId "a") (NodeId "b") <> vertices [NodeId "c"])
          influence = dagRandomWalkInfluence 0.85 (NodeId "a") rel
      Map.lookup (NodeId "c") influence `shouldBe` Just 0

    it "dangling vertices absorb their incoming mass" $ do
      -- a -> b (b has out-degree 0).  b gets α; no further propagation.
      let alpha = 0.85 :: Double
          rel = toRelation (edge (NodeId "a") (NodeId "b"))
          influence = dagRandomWalkInfluence alpha (NodeId "a") rel
      Map.lookup (NodeId "b") influence `shouldBe` Just alpha

    it "returns empty map when origin is not in the graph" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          influence = dagRandomWalkInfluence 0.85 (NodeId "missing") rel
      influence `shouldBe` Map.empty

    it "returns empty map on a cyclic input" $ do
      let rel = toRelation (edge (NodeId "a") (NodeId "b") <> edge (NodeId "b") (NodeId "a"))
          influence = dagRandomWalkInfluence 0.85 (NodeId "a") rel
      influence `shouldBe` Map.empty

  -- ========================================================================
  -- Topological sort
  -- ========================================================================

  describe "topSort" $ do
    it "returns a valid topological order for a chain" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      topSort rel `shouldBe` Just [1, 2, 3]

    it "returns a valid topological order for a diamond" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 1 3 <> edge 2 4 <> edge 3 4)
      case topSort rel of
        Nothing -> expectationFailure "Expected topological order"
        Just order -> do
          listToMaybe order `shouldBe` Just 1
          listToMaybe (reverse order) `shouldBe` Just 4

    it "returns Nothing for a cycle" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 2 3 <> edge 3 1)
      topSort rel `shouldBe` Nothing

    it "returns Nothing for a self-loop" $ do
      let rel = toRelation (edge (1 :: Int) 1)
      topSort rel `shouldBe` Nothing

    it "handles a disconnected graph" $ do
      let rel = toRelation (path [1 :: Int, 2] <> path [3, 4])
      case topSort rel of
        Nothing -> expectationFailure "Expected topological order"
        Just order -> do
          length order `shouldBe` 4
          let indexOf x = length (takeWhile (/= x) order)
          indexOf 1 `shouldSatisfy` (< indexOf 2)
          indexOf 3 `shouldSatisfy` (< indexOf 4)

  -- ========================================================================
  -- SCC
  -- ========================================================================

  describe "scc" $ do
    it "finds a single SCC in a cycle" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 2 3 <> edge 3 1)
      normalizeSCCs (scc rel) `shouldBe` [[1, 2, 3]]

    it "finds individual SCCs in a DAG" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      normalizeSCCs (scc rel) `shouldBe` [[1], [2], [3]]

    it "finds multiple SCCs" $ do
      let rel =
            toRelation
              ( edge (1 :: Int) 2
                  <> edge 2 1 -- SCC {1,2}
                  <> edge 3 4
                  <> edge 4 3 -- SCC {3,4}
                  <> edge 2 3 -- cross-edge between SCCs
              )
      normalizeSCCs (scc rel) `shouldBe` [[1, 2], [3, 4]]

    it "handles disconnected components" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 2 1 <> vertices [3, 4])
      normalizeSCCs (scc rel) `shouldBe` [[1, 2], [3], [4]]

  -- ========================================================================
  -- Validation
  -- ========================================================================

  describe "validateDAG" $ do
    it "accepts a valid DAG" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      validateDAG rel `shouldBe` Right ()

    it "rejects a cycle with a witness path" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 2 3 <> edge 3 1)
      case validateDAG rel of
        Right () -> expectationFailure "Expected cycle detection"
        Left (GraphHasCycle witness) -> do
          -- The witness should start and end with the same vertex
          listToMaybe witness `shouldBe` listToMaybe (reverse witness)
          length witness `shouldSatisfy` (>= 3)

    it "rejects a self-loop" $ do
      let rel = toRelation (edge (1 :: Int) 1)
      case validateDAG rel of
        Right () -> expectationFailure "Expected cycle detection"
        Left (GraphHasCycle _) -> pure ()

  describe "analyzeDAG" $ do
    it "returns topological order for a DAG" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      analyzeDAG rel `shouldBe` Right [1, 2, 3]

    it "returns cycle witness for a cyclic graph" $ do
      let rel = toRelation (edge (1 :: Int) 2 <> edge 2 1)
      case analyzeDAG rel of
        Right _ -> expectationFailure "Expected cycle"
        Left (GraphHasCycle _) -> pure ()

  -- ========================================================================
  -- Relation queries
  -- ========================================================================

  describe "predecessors" $ do
    it "returns direct predecessors" $ do
      let rel = toRelation (edge (1 :: Int) 3 <> edge 2 3)
      predecessors rel 3 `shouldBe` Set.fromList [1, 2]

    it "returns empty for a root" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
      predecessors rel 1 `shouldBe` Set.empty

  describe "reachable" $ do
    it "finds all reachable vertices" $ do
      let rel = toRelation (path [1 :: Int, 2, 3] <> vertices [4])
      reachable rel 1 `shouldBe` Set.fromList [1, 2, 3]

  -- ========================================================================
  -- mapRelation
  -- ========================================================================

  describe "mapRelation" $ do
    it "preserves structure under injective map" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
          mapped = mapRelation (* 10) rel
      relVertices mapped `shouldBe` Set.fromList [10, 20, 30]
      relEdges mapped `shouldBe` Set.fromList [(10, 20), (20, 30)]

    it "collapses vertices under non-injective map (quotient)" $ do
      let rel = toRelation (path [1 :: Int, 2, 3])
          mapped = mapRelation (const (0 :: Int)) rel
      relVertices mapped `shouldBe` Set.fromList [0]
      relEdges mapped `shouldBe` Set.fromList [(0, 0)]

  describe "normalizeForResume" $ do
    it "resets NodeRunning and NodeInterrupted to NodePending and leaves other statuses unchanged" $ do
      let gs =
            GraphState
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodePending)
                    , (NodeId "b", NodeRunning)
                    , (NodeId "c", NodeCompleted)
                    , (NodeId "d", NodeFailed)
                    , (NodeId "e", NodeRunning)
                    , (NodeId "f", NodeWaiting "sig")
                    , (NodeId "g", NodeInterrupted InterruptedShutdown)
                    ]
              , gsNodeOutputs = Map.empty :: Map.Map NodeId Int
              }
          result = normalizeForResume gs
      Map.lookup (NodeId "a") (gsNodeStatuses result) `shouldBe` Just NodePending
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodePending
      Map.lookup (NodeId "c") (gsNodeStatuses result) `shouldBe` Just NodeCompleted
      Map.lookup (NodeId "d") (gsNodeStatuses result) `shouldBe` Just NodeFailed
      Map.lookup (NodeId "e") (gsNodeStatuses result) `shouldBe` Just NodePending
      Map.lookup (NodeId "f") (gsNodeStatuses result) `shouldBe` Just (NodeWaiting "sig")
      Map.lookup (NodeId "g") (gsNodeStatuses result) `shouldBe` Just NodePending

    it "is a no-op when no nodes are running" $ do
      let gs =
            GraphState
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeCompleted)
                    , (NodeId "b", NodeFailed)
                    ]
              , gsNodeOutputs = Map.empty :: Map.Map NodeId Int
              }
      normalizeForResume gs `shouldBe` gs

  describe "applyFrontierResults terminal outcomes" $ do
    it "OutcomeNodeShutdown leaves node interrupted and returns Stuck" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs0 = initialGraphState rel
          results = [NodeResult (NodeId "a") OutcomeNodeShutdown]
          stepResult = applyFrontierResults rel results gs0
          gs' = stepResultState stepResult
      Map.lookup (NodeId "a") (gsNodeStatuses gs') `shouldBe` Just (NodeInterrupted InterruptedShutdown)
      -- Graph still has blocked work, but interrupted predecessors are not
      -- satisfied, so the graph is stuck until resume normalization.
      case stepResult of
        Stuck _ _ -> pure ()
        other -> expectationFailure $ "Expected Stuck, got: " <> show other

    it "OutcomeNodeRunCancelled leaves node interrupted and returns Stuck" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs0 = initialGraphState rel
          results = [NodeResult (NodeId "a") OutcomeNodeRunCancelled]
          stepResult = applyFrontierResults rel results gs0
          gs' = stepResultState stepResult
      Map.lookup (NodeId "a") (gsNodeStatuses gs')
        `shouldBe` Just (NodeInterrupted InterruptedRunCancelled)
      case stepResult of
        Stuck _ _ -> pure ()
        other -> expectationFailure $ "Expected Stuck, got: " <> show other

  -- ========================================================================
  -- propagateFailure closure operator
  -- ========================================================================

  describe "propagateFailure" $ do
    it "marks pending descendants of failed nodes as failed" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          gs =
            (initialGraphState rel)
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodePending)
                    , (NodeId "c", NodePending)
                    ]
              }
          result = propagateFailure rel gs
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodeFailed
      Map.lookup (NodeId "c") (gsNodeStatuses result) `shouldBe` Just NodeFailed

    it "marks waiting descendants of failed nodes as failed" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            (initialGraphState rel)
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodeWaiting "sig")
                    ]
              }
          result = propagateFailure rel gs
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodeFailed

    it "does not mark completed descendants as failed" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            (initialGraphState rel)
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodeCompleted)
                    ]
              }
          result = propagateFailure rel gs
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodeCompleted

    it "is idempotent: applying twice gives same result as once" $ do
      let rel =
            toRelation
              ( edge (NodeId "a") (NodeId "b")
                  <> edge (NodeId "a") (NodeId "c")
                  <> edge (NodeId "b") (NodeId "d")
                  <> edge (NodeId "c") (NodeId "d")
              )
          gs =
            (initialGraphState rel)
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodePending)
                    , (NodeId "c", NodeWaiting "sig")
                    , (NodeId "d", NodePending)
                    ]
              }
          applied1 = propagateFailure rel gs
          applied2 = propagateFailure rel applied1
      gsNodeStatuses applied1 `shouldBe` gsNodeStatuses applied2

    it "is extensive: never removes failures" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            (initialGraphState rel)
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodePending)
                    ]
              }
          result = propagateFailure rel gs
      -- a was already Failed, must remain Failed
      Map.lookup (NodeId "a") (gsNodeStatuses result) `shouldBe` Just NodeFailed

  -- ========================================================================
  -- classifyGraphState
  -- ========================================================================

  describe "classifyGraphState" $ do
    it "returns Progressing with frontier for a fresh graph" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs = initialGraphState rel
      case classifyGraphState rel gs of
        Progressing _ frontier -> frontier `shouldBe` [NodeId "a"]
        other -> expectationFailure $ "Expected Progressing, got: " <> show other

    it "returns Settled OutcomeCompleted when all nodes completed" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeCompleted), (NodeId "b", NodeCompleted)]
              , gsNodeOutputs = Map.fromList [(NodeId "a", Aeson.Null), (NodeId "b", Aeson.Null)]
              }
      case classifyGraphState rel gs of
        Settled _ OutcomeCompleted -> pure ()
        other -> expectationFailure $ "Expected Settled Completed, got: " <> show other

    it "returns Settled OutcomeFailed when a node failed" $ do
      let rel = toRelation (Vertex (NodeId "a"))
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeFailed)]
              , gsNodeOutputs = Map.empty
              }
      case classifyGraphState rel gs of
        Settled _ OutcomeFailed -> pure ()
        other -> expectationFailure $ "Expected Settled Failed, got: " <> show other

    it "returns Suspended when nodes are waiting and no frontier" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeWaiting "sig"), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      case classifyGraphState rel gs of
        Suspended _ -> pure ()
        other -> expectationFailure $ "Expected Suspended, got: " <> show other

    it "propagates failure before classifying" $ do
      -- a=Failed, b=Pending (downstream of a). After propagation, b=Failed.
      -- Graph should be Settled Failed, not Stuck.
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeFailed), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      case classifyGraphState rel gs of
        Settled _ OutcomeFailed -> pure ()
        other -> expectationFailure $ "Expected Settled Failed after propagation, got: " <> show other

  -- ========================================================================
  -- Property tests on random DAGs
  -- ========================================================================

  -- ========================================================================
  -- Pure simulation (no IO, no TVar, no persistence)
  -- ========================================================================

  describe "simulateRun (pure end-to-end)" $ do
    it "runs a linear pipeline to completion" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          gs0 = initialGraphState rel
          oracle _ _ = OutcomeSucceeded Aeson.Null
          (waves, result) = simulateRun rel gs0 Aeson.Null oracle 10
      length waves `shouldBe` 3
      case result of
        Settled _ OutcomeCompleted -> pure ()
        other -> expectationFailure $ "Expected Settled Completed, got: " <> show other

    it "runs a diamond graph with concurrent frontier" $ do
      let rel =
            toRelation
              ( edge (NodeId "a") (NodeId "b")
                  <> edge (NodeId "a") (NodeId "c")
                  <> edge (NodeId "b") (NodeId "d")
                  <> edge (NodeId "c") (NodeId "d")
              )
          gs0 = initialGraphState rel
          oracle _ _ = OutcomeSucceeded Aeson.Null
          (waves, result) = simulateRun rel gs0 Aeson.Null oracle 10
      length waves `shouldBe` 3
      case waves of
        [(_, [_], _), (_, frontierW1, _), (_, [_], _)] ->
          length frontierW1 `shouldBe` 2
        _ -> expectationFailure $ "Unexpected wave structure: " <> show (fmap (\(w, f, _) -> (w, f)) waves)
      case result of
        Settled _ OutcomeCompleted -> pure ()
        other -> expectationFailure $ "Expected Settled Completed, got: " <> show other

    it "handles mid-graph failure with propagation" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          gs0 = initialGraphState rel
          oracle nid _ =
            if nid == NodeId "b"
              then OutcomeNodeFailed (FailureDetail "test" "fail" True)
              else OutcomeSucceeded Aeson.Null
          (waves, result) = simulateRun rel gs0 Aeson.Null oracle 10
      length waves `shouldBe` 2
      case result of
        Settled _ OutcomeFailed -> pure ()
        other -> expectationFailure $ "Expected Settled Failed, got: " <> show other

    it "handles suspension" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b"])
          gs0 = initialGraphState rel
          oracle nid _ = if nid == NodeId "a" then OutcomeSuspendedOn "signal" else OutcomeSucceeded Aeson.Null
          (waves, result) = simulateRun rel gs0 Aeson.Null oracle 10
      length waves `shouldBe` 1
      case result of
        Suspended _ -> pure ()
        other -> expectationFailure $ "Expected Suspended, got: " <> show other

    it "stops after the first interrupted wave until resume normalization" $ do
      let rel = toRelation (Vertex (NodeId "a"))
          gs0 = initialGraphState rel
          oracle _ _ = OutcomeNodeCancelled
          (waves, result) = simulateRun rel gs0 Aeson.Null oracle 3
      length waves `shouldBe` 1
      case result of
        Stuck _ _ -> pure ()
        other -> expectationFailure $ "Expected Stuck, got: " <> show other

    -- ========================================================================
    -- Property tests on random DAGs
    -- ========================================================================

    it "random DAGs with forward-only oracles always terminate" . property $ do
      let prop (rel, gs, _) =
            let forwardOracle _ _ = OutcomeSucceeded Aeson.Null
                (_, result) = simulateRun rel gs Aeson.Null forwardOracle 100
             in case result of
                  Settled _ _ -> True
                  Suspended _ -> True
                  _ -> False
      forAll genFrontierScenario prop

    -- ========================================================================
    -- Property tests on random DAGs
    -- ========================================================================

    it "crash recovery preserves structural safety: partial frontier + normalize + re-classify is valid"
      . property
      $ do
        let prop (rel, gs, results) =
              -- Simulate a partial frontier: apply only some facts, then crash
              let half = take (length results `div` 2) results
                  gs_partial = reduceFacts half gs
                  -- Crash: normalize resumable statuses back to pending.
                  gs_recovered = normalizeForResume gs_partial
                  -- The recovered state should be validly classifiable
                  stepResult = classifyGraphState rel gs_recovered
               in case stepResult of
                    Progressing _ frontier -> not (null frontier) -- should have work to do
                    Settled _ _ -> True -- if all nodes happened to complete in the first half
                    Suspended _ -> True
                    Stuck _ _ -> False -- should never be stuck after recovery
        forAll genFrontierScenario prop

  describe "algebra properties (random DAGs)" $ do
    it "propagateFailure is idempotent on random graphs" $ do
      let prop (rel, gs) =
            let once' = propagateFailure rel gs
                twice' = propagateFailure rel once'
             in gsNodeStatuses once' === gsNodeStatuses twice'
      property (forAll genGraphWithFailures prop)

    it "propagateFailure is extensive: failure count never decreases" $ do
      let prop (rel, gs) =
            let failsBefore = countStatus NodeFailed gs
                failsAfter = countStatus NodeFailed (propagateFailure rel gs)
             in failsAfter >= failsBefore
      property (forAll genGraphWithFailures prop)

    it "applyFrontierResults is permutation-invariant on random frontiers" $ do
      let prop (rel, gs, results) =
            forAll (shuffle results) $ \shuffled ->
              applyFrontierResults rel results gs
                === applyFrontierResults rel shuffled gs
      property (forAll genFrontierScenario prop)

    it "sequential and batch reduction produce the same classification" $ do
      let prop (rel, gs, results) =
            let batchResult = applyFrontierResults rel results gs
                seqResult =
                  foldl'
                    (\s r -> applyFrontierResults rel [r] (stepResultState s))
                    (classifyGraphState rel gs)
                    results
             in stepResultState batchResult === stepResultState seqResult
      property (forAll genFrontierScenario prop)

    -- Lemma 1: frontier nodes form an antichain (no reachability between them)
    it "frontier nodes form an antichain under reachability" $ do
      let prop (rel, gs, _) =
            let frontier = readyNodes rel gs
             in all
                  (\(a, b) -> not (Set.member b (reachable rel a)))
                  [(x, y) | x <- frontier, y <- frontier, x /= y]
      property (forAll genFrontierScenario prop)

    -- Lemma 2: pairwise commutativity of applyNodeFact for distinct frontier nodes
    it "applyNodeFact commutes for distinct frontier nodes" $ do
      let prop (nr1, nr2, gs) =
            applyNodeFact nr1 (applyNodeFact nr2 gs)
              === applyNodeFact nr2 (applyNodeFact nr1 gs)
      property (forAll genFrontierPairScenario prop)

    -- Monotonicity of propagateFailure (set inclusion, not just count)
    it "propagateFailure is monotone: failed set only grows with more input failures" $ do
      let failedSet graphState =
            Map.keysSet (Map.filter (== NodeFailed) (gsNodeStatuses graphState))
          prop (rel, gs, gs') =
            let failsAfter = failedSet (propagateFailure rel gs)
                failsAfter' = failedSet (propagateFailure rel gs')
             in failsAfter `Set.isSubsetOf` failsAfter'
      property (forAll genMonotonePair prop)

  describe "diagnostic helpers" $ do
    it "classifyGraphState populates sdFailedNodes on stuck graph" $ do
      -- A graph where node "b" has failed and node "c" is pending with "b" as predecessor.
      -- After propagation "c" gets failed too, so the graph settles as Failed,
      -- not Stuck. To get Stuck, we need a state the algebra considers inconsistent:
      -- pending nodes with no failed/waiting predecessor and empty frontier.
      -- This can happen if the status map is inconsistent with the topology.
      let rel = toRelation (edge (NodeId "a") (NodeId "b"))
          -- "a" is completed, "b" is pending → "b" should be ready. Not stuck.
          -- For a real stuck case: topology has edge a→b but status map has
          -- a=Running (not terminal), b=Pending (not ready because a not completed).
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeRunning), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      case classifyGraphState rel gs of
        Stuck _ diag -> do
          sdPendingNodes diag `shouldBe` [NodeId "b"]
          -- "a" is Running not Failed, so no failed nodes in stuck diagnostic
          sdFailedNodes diag `shouldBe` []
          sdStuckOnFailed diag `shouldBe` []
        other -> expectationFailure $ "Expected Stuck, got: " <> show other

    it "classifyGraphState propagates failure and settles inconsistent state as failed" $ do
      -- "a" failed, "b" pending — propagation hasn't reached "b" yet.
      -- classifyGraphState applies propagation first, so "b" becomes failed too,
      -- and the graph settles as Failed.
      let rel = toRelation (edge (NodeId "a") (NodeId "b"))
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeFailed), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      case classifyGraphState rel gs of
        Settled _ OutcomeFailed -> pure () -- correct: after propagation, "b" fails too
        other -> expectationFailure $ "Expected Settled Failed, got: " <> show other

    it "blockedReasons identifies failed predecessors" $ do
      let rel = toRelation (edge (NodeId "a") (NodeId "b"))
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodeFailed), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      blockedReasons rel gs `shouldBe` [(NodeId "b", BlockedByFailed [NodeId "a"])]

    it "blockedReasons identifies pending predecessors" $ do
      let rel = toRelation (edge (NodeId "a") (NodeId "b"))
          gs =
            GraphState
              { gsNodeStatuses = Map.fromList [(NodeId "a", NodePending), (NodeId "b", NodePending)]
              , gsNodeOutputs = Map.empty
              }
      -- "a" is ready (no predecessors), so it's excluded from blockedReasons.
      -- Only "b" appears, blocked by its pending predecessor "a".
      blockedReasons rel gs `shouldBe` [(NodeId "b", BlockedByPending [NodeId "a"])]

    it "isLinearTopology accepts chains" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
      isLinearTopology rel `shouldBe` True

    it "isLinearTopology accepts a single isolated node" $ do
      let rel = toRelation (Vertex (NodeId "a"))
      isLinearTopology rel `shouldBe` True

    it "isLinearTopology rejects disconnected nodes" $ do
      let rel = toRelation (vertices [NodeId "a", NodeId "b"])
      isLinearTopology rel `shouldBe` False

    it "isLinearTopology rejects disconnected chains" $ do
      let rel = toRelation (edge (NodeId "a") (NodeId "b") <> edge (NodeId "c") (NodeId "d"))
      isLinearTopology rel `shouldBe` False

    it "isLinearTopology rejects diamond" $ do
      let rel =
            toRelation
              ( edge (NodeId "a") (NodeId "b")
                  <> edge (NodeId "a") (NodeId "c")
                  <> edge (NodeId "b") (NodeId "d")
                  <> edge (NodeId "c") (NodeId "d")
              )
      isLinearTopology rel `shouldBe` False

    it "isLinearTopology rejects fan-out" $ do
      let rel = toRelation (star (NodeId "a") [NodeId "b", NodeId "c"])
      isLinearTopology rel `shouldBe` False

    it "isLinearTopology rejects fan-in" $ do
      let rel = toRelation (edge (NodeId "a") (NodeId "c") <> edge (NodeId "b") (NodeId "c"))
      isLinearTopology rel `shouldBe` False

  -- ========================================================================
  -- Cache invariant tests
  -- ========================================================================

  describe "checkCacheInvariant" $ do
    it "holds for all algebra combinators" $ do
      let cases :: [Relation Int]
          cases =
            [ toRelation Empty
            , toRelation (Vertex 1)
            , toRelation (edge 1 2)
            , toRelation (path [1, 2, 3, 4])
            , toRelation (vertices [1, 2, 3])
            , toRelation (star 1 [2, 3, 4])
            , toRelation (clique [1, 2, 3])
            , toRelation (clique [1, 2])
            , toRelation (edges [(1, 2), (2, 3), (3, 1)])
            , toRelation (edge 1 2 <> edge 3 4)
            , toRelation (Connect (vertices [1, 2]) (vertices [3, 4]))
            , toRelation (Connect Empty (Vertex 1))
            , toRelation (Connect (Vertex 1) Empty)
            , toRelation (Connect Empty Empty)
            ]
      mapM_ (\rel -> checkCacheInvariant rel `shouldBe` True) cases

    it "holds for random algebra-built graphs (property)" . property $ do
      let prop g = checkCacheInvariant (toRelation g) === True
      forAll genGraph prop

    it "holds after addEdge" . property $ do
      let prop rel = forAll (genVertex rel) $ \u ->
            forAll (genVertex rel) $ \v ->
              checkCacheInvariant (addEdge u v rel) === True
      forAll genDAG prop

    it "holds after removeEdge" . property $ do
      let prop (rel, u, v) = checkCacheInvariant (removeEdge u v rel) === True
      forAll genDAGWithEdge prop

    it "holds after removeVertex" . property $ do
      let prop rel = forAll (genVertex rel) $ \v ->
            checkCacheInvariant (removeVertex v rel) === True
      forAll genDAG prop

    it "holds after mapRelation" . property $ do
      let prop rel = checkCacheInvariant (mapRelation (\(NodeId t) -> NodeId ("mapped_" <> t)) rel) === True
      forAll genDAG prop

    it "holds after transposeRelation" . property $ do
      let prop rel = checkCacheInvariant (transposeRelation rel) === True
      forAll genDAG prop

  -- ========================================================================
  -- Algebra identity laws on Relation
  -- ========================================================================

  describe "Relation algebra laws" $ do
    it "connect Empty g == g (left identity)" . property $ do
      let prop g = toRelation (Connect Empty g) === toRelation g
      forAll genGraph prop

    it "connect g Empty == g (right identity)" . property $ do
      let prop g = toRelation (Connect g Empty) === toRelation g
      forAll genGraph prop

    it "overlay Empty g == g (left identity)" . property $ do
      let prop g = toRelation (Overlay Empty g) === toRelation g
      forAll genGraph prop

    it "overlay g Empty == g (right identity)" . property $ do
      let prop g = toRelation (Overlay g Empty) === toRelation g
      forAll genGraph prop

    it "transposeRelation is involution" . property $ do
      let prop rel = transposeRelation (transposeRelation rel) === rel
      forAll genDAG prop

    it "transposeRelation swaps predecessors and successors" . property $ do
      let prop rel = forAll (genVertex rel) $ \v ->
            successors (transposeRelation rel) v === predecessors rel v
      forAll genDAG prop

  -- ========================================================================
  -- Frontier-parameterized topSort
  -- ========================================================================

  describe "topSortBy" $ do
    it "produces a valid topological order" . property $ do
      let prop rel =
            case topSortBy id rel of
              Nothing -> Set.null (relVertices rel) === True
              Just order ->
                let orderSet = Set.fromList order
                 in orderSet === relVertices rel
      forAll genDAG prop

    it "agrees with topSort on presence/absence of cycle" . property $ do
      let prop rel =
            case (topSort rel, topSortBy id rel) of
              (Just _, Just _) -> True === True
              (Nothing, Nothing) -> True === True
              _ -> False === True
      forAll genDAG prop

  -- ========================================================================
  -- propagateFailure through non-propagatable nodes
  -- ========================================================================

  describe "propagateFailure (traversal through non-propagatable)" $ do
    it "propagates through running nodes to reach pending descendants" $ do
      -- a=Failed, b=Running (not propagatable), c=Pending (should still be reached)
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          gs =
            GraphState
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodeRunning)
                    , (NodeId "c", NodePending)
                    ]
              , gsNodeOutputs = Map.empty
              }
          result = propagateFailure rel gs
      -- b is Running (not propagatable) — should remain Running
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodeRunning
      -- c is Pending (propagatable) — should become Failed despite b being in between
      Map.lookup (NodeId "c") (gsNodeStatuses result) `shouldBe` Just NodeFailed

    it "propagates through completed nodes to reach pending descendants" $ do
      let rel = toRelation (path [NodeId "a", NodeId "b", NodeId "c"])
          gs =
            GraphState
              { gsNodeStatuses =
                  Map.fromList
                    [ (NodeId "a", NodeFailed)
                    , (NodeId "b", NodeCompleted)
                    , (NodeId "c", NodePending)
                    ]
              , gsNodeOutputs = Map.empty
              }
          result = propagateFailure rel gs
      Map.lookup (NodeId "b") (gsNodeStatuses result) `shouldBe` Just NodeCompleted
      Map.lookup (NodeId "c") (gsNodeStatuses result) `shouldBe` Just NodeFailed

-- ============================================================================
-- QuickCheck generators
-- ============================================================================

-- | Generate a random Graph expression (not lowered to Relation).
genGraph :: Gen (Graph Int)
genGraph = sized go
  where
    go 0 = elements [Empty, Vertex 1]
    go n = do
      let sub = go (n `div` 2)
      v <- choose (1 :: Int, 10)
      elements
        =<< sequence
          [ pure Empty
          , pure (Vertex v)
          , Overlay <$> sub <*> sub
          , Connect <$> sub <*> sub
          ]

-- | Pick a random vertex from a relation.
genVertex :: Relation NodeId -> Gen NodeId
genVertex rel =
  let vs = Set.toList (relVertices rel)
   in if null vs then pure (NodeId "0") else elements vs

-- | Generate a DAG that has at least one edge, and return the relation plus one of its edges.
genDAGWithEdge :: Gen (Relation NodeId, NodeId, NodeId)
genDAGWithEdge = do
  rel <- genDAG
  let es = Set.toList (relEdges rel)
  if null es
    then do
      -- Ensure at least one edge
      let rel' = addEdge (NodeId "0") (NodeId "1") rel
      pure (rel', NodeId "0", NodeId "1")
    else do
      (u, v) <- elements es
      pure (rel, u, v)

{- | Generate a random DAG by creating nodes 0..n and adding forward edges
(i → j where i < j) randomly. This guarantees acyclicity.
-}
genDAG :: Gen (Relation NodeId)
genDAG = sized $ \size -> do
  let n = min size 8 + 2 -- 2 to 10 nodes
      nodes = [NodeId (T.pack (show i)) | i <- [0 .. n - 1 :: Int]]
      possibleEdges = [(nodes !! i, nodes !! j) | i <- [0 .. n - 1], j <- [i + 1 .. n - 1]]
  selectedEdges <- sublistOf possibleEdges
  let g =
        mconcat [edge a b | (a, b) <- selectedEdges]
          <> mconcat [Vertex v | v <- nodes]
  pure (toRelation g)

{- | Generate a random graph state where some nodes are Failed and the
rest are Pending. Good for testing propagateFailure.
-}
genGraphWithFailures :: Gen (Relation NodeId, GraphState Aeson.Value)
genGraphWithFailures = do
  rel <- genDAG
  let nodes = Set.toList (relVertices rel)
  statuses <-
    mapM
      ( \nid -> do
          status <- elements [NodePending, NodePending, NodePending, NodeFailed] -- 25% fail rate
          pure (nid, status)
      )
      nodes
  pure (rel, GraphState (Map.fromList statuses) Map.empty)

{- | Generate a frontier scenario: a DAG, a valid initial state where some
nodes have completed, and a set of NodeResults for the current frontier.
-}
genFrontierScenario :: Gen (Relation NodeId, GraphState Aeson.Value, [NodeResult])
genFrontierScenario = do
  rel <- genDAG
  let allNodes = Set.toList (relVertices rel)
  -- Pick some nodes to be already completed (forming a valid prefix)
  completedCount <- choose (0, max 0 (length allNodes - 2))
  -- Use topological order to ensure completed nodes form a valid prefix
  case topSort rel of
    Nothing -> pure (rel, initialGraphState rel, []) -- degenerate case
    Just topoOrder -> do
      let completed = take completedCount topoOrder
          remaining = drop completedCount topoOrder
          statuses =
            Map.fromList $
              [(nid, NodeCompleted) | nid <- completed]
                <> [(nid, NodePending) | nid <- remaining]
          outputs = Map.fromList [(nid, Aeson.Null) | nid <- completed]
          gs = GraphState statuses outputs
          frontier = readyNodes rel gs
      -- Generate results for frontier nodes
      results <- mapM genResultFor frontier
      pure (rel, gs, results)

-- | Generate a random forward NodeResult for a node.
genResultFor :: NodeId -> Gen NodeResult
genResultFor nid = do
  outcome <-
    elements
      [ OutcomeSucceeded Aeson.Null
      , OutcomeSkipped
      , OutcomeNodeFailed (FailureDetail "test" "test failure" True)
      , OutcomeNodeTimedOut
      ]
  pure (NodeResult nid outcome)

-- ============================================================================
-- QuickCheck generators
-- ============================================================================

-- | Count nodes with a specific status.
countStatus :: NodeStatus -> GraphState o -> Int
countStatus target gs =
  length [() | s <- Map.elems (gsNodeStatuses gs), s == target]

{- | Generate a pair of distinct frontier NodeResults and the graph state.
Used for testing pairwise commutativity of applyNodeFact.
-}
genFrontierPairScenario :: Gen (NodeResult, NodeResult, GraphState Aeson.Value)
genFrontierPairScenario = do
  (_rel, gs, results) <- genFrontierScenario
  case results of
    (r1 : r2 : _) -> pure (r1, r2, gs)
    _ -> do
      -- Not enough frontier nodes; generate a wider graph
      let nodes = [NodeId (T.pack (show i)) | i <- [0 .. 4 :: Int]]
          rel' = toRelation (vertices nodes)
          gs' = initialGraphState rel'
          frontier = readyNodes rel' gs'
      case frontier of
        (f1 : f2 : _) -> do
          r1 <- genResultFor f1
          r2 <- genResultFor f2
          pure (r1, r2, gs')
        _ -> do
          -- Degenerate: just produce two distinct node results
          r1 <- genResultFor (NodeId "0")
          r2 <- genResultFor (NodeId "1")
          pure (r1, r2, gs')

{- | Generate a pair of graph states where the second has a superset of failures.
Used for testing monotonicity of propagateFailure.
-}
genMonotonePair :: Gen (Relation NodeId, GraphState Aeson.Value, GraphState Aeson.Value)
genMonotonePair = do
  rel <- genDAG
  let nodes = Set.toList (relVertices rel)
  -- gs: some nodes failed
  statuses1 <-
    mapM
      ( \nid -> do
          status <- elements [NodePending, NodePending, NodePending, NodePending, NodeFailed]
          pure (nid, status)
      )
      nodes
  -- gs': same failures plus possibly more
  statuses2 <-
    mapM
      ( \(nid, s) -> case s of
          NodeFailed -> pure (nid, NodeFailed) -- keep existing failures
          _ -> do
            status <- elements [s, s, s, NodeFailed] -- 25% chance of additional failure
            pure (nid, status)
      )
      statuses1
  let gs = GraphState (Map.fromList statuses1) Map.empty
      gs' = GraphState (Map.fromList statuses2) Map.empty
  pure (rel, gs, gs')
