{- |
Module      : Cortex.Pulse.MemoryIntegrationSpec
Description : End-to-end integration spec for 'Cortex.Pulse.Memory' (DIG-529).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the IO 'MemoryHandle' constructed by 'newMemoryHandle'
against live TVars populated as an executor would populate them.
Two properties the issue calls out explicitly:

* __Sibling preservation__: two analyst branches under a shared
planner each emit an observation; the reviewer's query rooted at
its own node reaches both of them, not just one.

* __Within-run determinism__: the IO wrapper is a pure function
of the TVar state at snapshot time; two consecutive queries
against the same state yield identical matches and identical
scores.

Replay determinism across a crash-resume boundary is partially
covered here (the TVar-backed snapshot is a pure function of its
inputs; a resume that reconstructs equivalent TVars yields an
equivalent view).  A fuller DB-backed resume test belongs alongside
the executor integration tests under 'Cortex.Pulse.ExecutorSpec'.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.MemoryIntegrationSpec (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, writeTVar)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Relation
  , edges
  , toRelation
  )
import Cortex.Pulse.Materialize (PersistedGraphState (..))
import Cortex.Pulse.Memory
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite (RewriteBudget (..))
import Cortex.Pulse.Runtime (GraphState (..), NodeStatus (..))
import Cortex.Wire (unwrapWireStageValue)

-- ============================================================================
-- Fixtures
-- ============================================================================

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 4 22) (secondsToDiffTime 0)

tAt :: Integer -> UTCTime
tAt secs = addUTCTime (fromIntegral secs) t0

nid :: Text -> NodeId
nid = NodeId

-- | The DIG-507 fan-out shape: planner → three analysts → reviewer.
fanoutTopology :: Relation NodeId
fanoutTopology =
  toRelation
    ( edges
        [ (nid "planner", nid "analyst-a")
        , (nid "planner", nid "analyst-b")
        , (nid "planner", nid "analyst-c")
        , (nid "analyst-a", nid "reviewer")
        , (nid "analyst-b", nid "reviewer")
        , (nid "analyst-c", nid "reviewer")
        ]
    )

analystJson :: Text -> Text -> Aeson.Value
analystJson slot body =
  Aeson.object
    [ "slot" Aeson..= slot
    , "text" Aeson..= body
    ]

plannerJson :: Aeson.Value
plannerJson = Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan" :: Text)]

budget :: RewriteBudget
budget =
  RewriteBudget
    { rbAddedNodesMax = 0
    , rbAddedEdgesMax = 0
    , rbAddedDepthMax = 0
    , rbFrontierDeltaMax = 0
    , rbRewriteOpsMax = 0
    }

{- | A 'PersistedGraphState' shaped as if the planner and all three
analysts have settled and the reviewer is still pending.  The
analysts all share routing key @"analyst"@ — that's the DIG-529
sibling-preservation scenario.
-}
initialPersistedState :: PersistedGraphState
initialPersistedState =
  PersistedGraphState
    { pgsGraphState =
        GraphState
          { gsNodeStatuses =
              Map.fromList
                [ (nid "planner", NodeCompleted)
                , (nid "analyst-a", NodeCompleted)
                , (nid "analyst-b", NodeCompleted)
                , (nid "analyst-c", NodeCompleted)
                , (nid "reviewer", NodePending)
                ]
          , gsNodeOutputs =
              Map.fromList
                [ (nid "planner", plannerJson)
                , (nid "analyst-a", analystJson "analyst" "alpha revenue grew 12%")
                , (nid "analyst-b", analystJson "analyst" "beta revenue grew 5%")
                , (nid "analyst-c", analystJson "analyst" "gamma revenue declined 3%")
                ]
          }
    , pgsRemainingRewriteBudget = budget
    , pgsAppliedRewriteId = Nothing
    , pgsNodeProvenance = Map.empty
    , pgsTopologyHash = Nothing
    }

completedAtMap :: Map.Map NodeId UTCTime
completedAtMap =
  Map.fromList
    [ (nid "planner", tAt 0)
    , (nid "analyst-a", tAt 10)
    , (nid "analyst-b", tAt 20)
    , (nid "analyst-c", tAt 30)
    ]

analystExtractor :: Aeson.Value -> Maybe ExtractedFields
analystExtractor (Aeson.Object obj) =
  case KeyMap.lookup "text" obj of
    Just (Aeson.String bodyText) ->
      let slot = case KeyMap.lookup "slot" obj of
            Just (Aeson.String s) -> Just s
            _ -> Nothing
       in Just
            ExtractedFields
              { efRoutingKey = slot
              , efBodyText = bodyText
              , efEvidence = []
              }
    _ -> Nothing
analystExtractor _ = Nothing

{- | Extractor that peels a 'WireValue'-shaped envelope before
decoding — the pattern the DeepReport reviewer uses so it works
against wire-wrapped persisted outputs.
-}
wireAwareAnalystExtractor :: Aeson.Value -> Maybe ExtractedFields
wireAwareAnalystExtractor = analystExtractor . unwrapWireStageValue

{- | Build a 'WireValue'-wrapped analyst payload the way
'wrapWireStageResult' stashes it in 'gsNodeOutputs'.  Shape matches
the 'ToJSON WireValue' instance in 'Cortex.Wire.Value'.
-}
wireWrappedAnalyst :: Text -> Text -> Aeson.Value
wireWrappedAnalyst slot body =
  Aeson.object
    [ "contract" Aeson..= ("analyst.draft" :: Text)
    , "payloadKind" Aeson..= ("json" :: Text)
    , "mediaType" Aeson..= ("application/json" :: Text)
    , "producer" Aeson..= ("analyst-a" :: Text)
    , "value" Aeson..= analystJson slot body
    , "provenance" Aeson..= Aeson.Null
    ]

-- ============================================================================
-- Spec
-- ============================================================================

{- | Capture a snapshot from the canonical fan-out state and wrap it
as a 'MemoryHandle'.  Mirrors what 'StageEnv.seMemoryFactory' does
at stage entry.
-}
fanoutHandle
  :: PersistedGraphState
  -> Map.Map NodeId UTCTime
  -> IO MemoryHandle
fanoutHandle state completedAt = do
  gsVar <- newTVarIO state
  nodeCompletedAtVar <- newTVarIO completedAt
  topologyVar <- newTVarIO fanoutTopology
  newMemoryHandle <$> captureMemorySnapshot gsVar nodeCompletedAtVar topologyVar

spec :: Spec
spec = describe "MemoryHandle (stage-entry bound)" $ do
  it "preserves sibling analysts under a shared routing key" $ do
    handle <- fanoutHandle initialPersistedState completedAtMap
    let query =
          emptyQuery
            { qExtractor = analystExtractor
            , qRoutingKey = Just "analyst"
            }
    matches <- handle.queryMemory (nid "reviewer") analystWalkSpec query
    -- All three analysts share routing_key="analyst".  Reviewer's
    -- ancestors walk reaches every one of them regardless of which
    -- chain it took — that's the broadcast-read property.
    fmap moNodeId matches
      `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

  it "is bit-identical across consecutive queries on the bound snapshot" $ do
    -- With stage-entry binding the capture time is frozen, so even
    -- the temporal score axis is stable — two reads must agree
    -- exactly on every field.
    handle <- fanoutHandle initialPersistedState completedAtMap
    let query = emptyQuery {qExtractor = analystExtractor}
    a <- handle.queryMemory (nid "reviewer") analystWalkSpec query
    b <- handle.queryMemory (nid "reviewer") analystWalkSpec query
    a `shouldBe` b

  it "resume reconstructs an equivalent view from equivalent state" $ do
    let query = emptyQuery {qExtractor = analystExtractor, qRoutingKey = Just "analyst"}
    -- Pre-crash: stage enters, binds a snapshot, queries.
    handle1 <- fanoutHandle initialPersistedState completedAtMap
    preCrash <- handle1.queryMemory (nid "reviewer") analystWalkSpec query

    -- Post-resume: the executor reconstructs equivalent state and
    -- binds a new snapshot.  Same persisted state, same completion
    -- map, same topology ⇒ equivalent view.
    handle2 <- fanoutHandle initialPersistedState completedAtMap
    postResume <- handle2.queryMemory (nid "reviewer") analystWalkSpec query

    fmap moNodeId preCrash `shouldBe` fmap moNodeId postResume
    fmap moExtracted preCrash `shouldBe` fmap moExtracted postResume

  it "does NOT observe writes that happen after stage entry (no mid-stage drift)" $ do
    -- The point of binding: if the executor mutates gsVar after the
    -- stage started, the stage's memory view does not move.
    gsVar <- newTVarIO initialPersistedState
    nodeCompletedAtVar <- newTVarIO completedAtMap
    topologyVar <- newTVarIO fanoutTopology
    -- Stage entry: capture snapshot, bind handle.
    snap <- captureMemorySnapshot gsVar nodeCompletedAtVar topologyVar
    let handle = newMemoryHandle snap
        query = emptyQuery {qExtractor = analystExtractor, qRoutingKey = Just "analyst"}
    initial <- handle.queryMemory (nid "reviewer") analystWalkSpec query
    length initial `shouldBe` 3

    -- Mid-stage mutation: delete one analyst output from the live
    -- TVar.  A re-query against the bound handle must still return
    -- three — the snapshot is frozen.
    let droppedState =
          initialPersistedState
            { pgsGraphState =
                (initialPersistedState.pgsGraphState)
                  { gsNodeOutputs =
                      Map.delete
                        (nid "analyst-b")
                        initialPersistedState.pgsGraphState.gsNodeOutputs
                  }
            }
    atomically $ writeTVar gsVar droppedState
    afterMutation <- handle.queryMemory (nid "reviewer") analystWalkSpec query
    length afterMutation `shouldBe` 3

    -- A new snapshot captured after the mutation does observe it —
    -- that represents a /different/ stage's entry.
    freshSnap <- captureMemorySnapshot gsVar nodeCompletedAtVar topologyVar
    let freshHandle = newMemoryHandle freshSnap
    freshMatches <- freshHandle.queryMemory (nid "reviewer") analystWalkSpec query
    length freshMatches `shouldBe` 2

  it "decodes wire-wrapped analyst outputs via unwrapWireStageValue" $ do
    -- When the wire runtime binds analyst stages, persisted outputs
    -- sit inside a 'WireValue' envelope.  A naive decoder against
    -- 'moOutput' sees the envelope, not the domain type, and drops
    -- every wire-shaped analyst from the memory view.  Unwrapping
    -- before decoding restores them.  Non-wire (plain) outputs pass
    -- through 'unwrapWireStageValue' unchanged.
    let wireOutputs =
          Map.fromList
            [ (nid "planner", plannerJson)
            , (nid "analyst-a", wireWrappedAnalyst "analyst" "alpha revenue grew 12%")
            , (nid "analyst-b", wireWrappedAnalyst "analyst" "beta revenue grew 5%")
            , (nid "analyst-c", wireWrappedAnalyst "analyst" "gamma revenue declined 3%")
            ]
        wireState =
          initialPersistedState
            { pgsGraphState =
                (initialPersistedState.pgsGraphState)
                  { gsNodeOutputs = wireOutputs
                  }
            }
    handle <- fanoutHandle wireState completedAtMap
    let naiveQuery = emptyQuery {qExtractor = analystExtractor, qRoutingKey = Just "analyst"}
        unwrappingQuery = emptyQuery {qExtractor = wireAwareAnalystExtractor, qRoutingKey = Just "analyst"}

    naiveMatches <- handle.queryMemory (nid "reviewer") analystWalkSpec naiveQuery
    -- Without unwrapping, the extractor fails (payload is the wire
    -- envelope, not the analyst shape) and the routing-key filter
    -- drops every analyst — that's the regression.
    naiveMatches `shouldBe` []

    unwrappedMatches <- handle.queryMemory (nid "reviewer") analystWalkSpec unwrappingQuery
    fmap moNodeId unwrappedMatches
      `shouldMatchList` [nid "analyst-a", nid "analyst-b", nid "analyst-c"]

  it "waiting nodes are never surfaced as memory matches" $ do
    -- NodeWaiting is present/locked execution state, not past
    -- observation.  A reviewer running while analyst-b is suspended
    -- on a signal must not see analyst-b in its memory view — no
    -- matter which scope the walk uses.  Scope widening
    -- ('DebugAllStatuses') just traverses farther; payload-less
    -- nodes drop at scoring time.
    let waitingStatuses =
          Map.insert
            (nid "analyst-b")
            (NodeWaiting "pending_signal")
            initialPersistedState.pgsGraphState.gsNodeStatuses
        waitingOutputs =
          Map.delete
            (nid "analyst-b")
            initialPersistedState.pgsGraphState.gsNodeOutputs
        waitingState =
          initialPersistedState
            { pgsGraphState =
                (initialPersistedState.pgsGraphState)
                  { gsNodeStatuses = waitingStatuses
                  , gsNodeOutputs = waitingOutputs
                  }
            }
    handle <- fanoutHandle waitingState completedAtMap
    let structuralQuery = emptyQuery
    settledOnly <-
      handle.queryMemory (nid "reviewer") analystWalkSpec structuralQuery
    fmap moNodeId settledOnly
      `shouldMatchList` [nid "planner", nid "analyst-a", nid "analyst-c"]

    -- Widen the scope to the debug knob: analyst-b is now reachable
    -- by the walk, but it still has no output in the substrate so
    -- the scoring stage drops it.  The waiting node never becomes a
    -- memory match — even under the operator/inspection scope.
    widened <-
      handle.queryMemory
        (nid "reviewer")
        (analystWalkSpec {wsScope = DebugAllStatuses})
        structuralQuery
    fmap moNodeId widened
      `shouldMatchList` [nid "planner", nid "analyst-a", nid "analyst-c"]
    any (\m -> moNodeId m == nid "analyst-b") widened `shouldBe` False

  it "same-frontier siblings are invisible to each other via stage-entry binding" $ do
    -- Planner → { analyst-a, analyst-b } → reviewer.  Both analysts
    -- are in the same frontier.  At analyst-b's stage entry,
    -- analyst-a is still running (no output, NodeRunning status).
    -- Even if analyst-a settles while analyst-b is executing, the
    -- snapshot bound at analyst-b's entry must not grow.  This is
    -- the "no same-frontier bleed" property.
    let entryStatuses =
          Map.fromList
            [ (nid "planner", NodeCompleted)
            , (nid "analyst-a", NodeRunning)
            , (nid "analyst-b", NodeRunning)
            , (nid "analyst-c", NodeRunning)
            , (nid "reviewer", NodePending)
            ]
        entryOutputs =
          Map.fromList [(nid "planner", plannerJson)]
        entryState =
          initialPersistedState
            { pgsGraphState =
                (initialPersistedState.pgsGraphState)
                  { gsNodeStatuses = entryStatuses
                  , gsNodeOutputs = entryOutputs
                  }
            }
    gsVar <- newTVarIO entryState
    nodeCompletedAtVar <- newTVarIO (Map.singleton (nid "planner") (tAt 0))
    topologyVar <- newTVarIO fanoutTopology

    -- Bind analyst-b's entry snapshot now — analyst-a has not yet
    -- settled.
    entrySnap <- captureMemorySnapshot gsVar nodeCompletedAtVar topologyVar
    let analystBHandle = newMemoryHandle entrySnap

    -- Executor then settles analyst-a into gsVar + nodeCompletedAt.
    let settledAState =
          entryState
            { pgsGraphState =
                (entryState.pgsGraphState)
                  { gsNodeStatuses = Map.insert (nid "analyst-a") NodeCompleted entryStatuses
                  , gsNodeOutputs = Map.insert (nid "analyst-a") (analystJson "analyst" "alpha settled") entryOutputs
                  }
            }
    atomically $ writeTVar gsVar settledAState
    atomically $ modifyTVar' nodeCompletedAtVar (Map.insert (nid "analyst-a") (tAt 10))

    -- analyst-b's memory view — bound at its entry — still does not
    -- include analyst-a.  The past is what was past when analyst-b
    -- started; the present (analyst-a settling mid-flight) is not
    -- retroactively merged.
    entryMatches <-
      analystBHandle.queryMemory
        (nid "analyst-b")
        analystWalkSpec
        (emptyQuery {qExtractor = analystExtractor})
    fmap moNodeId entryMatches `shouldBe` [nid "planner"]

    -- A fresh snapshot captured later does see analyst-a — that's
    -- the reviewer's view once analyst-b eventually settles and the
    -- reviewer's own stage entry fires.
    laterSnap <- captureMemorySnapshot gsVar nodeCompletedAtVar topologyVar
    let reviewerHandle = newMemoryHandle laterSnap
    laterMatches <-
      reviewerHandle.queryMemory
        (nid "reviewer")
        analystWalkSpec
        (emptyQuery {qExtractor = analystExtractor, qRoutingKey = Just "analyst"})
    fmap moNodeId laterMatches `shouldBe` [nid "analyst-a"]
