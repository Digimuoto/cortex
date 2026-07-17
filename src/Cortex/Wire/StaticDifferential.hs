{- |
Module      : Cortex.Wire.StaticDifferential
Description : Differential corpus and Haskell reference driver for the static Wire C backend.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream Wire surface.

ADR 0091 requires the Lean target interpreter, the generated freestanding C,
and the Haskell 'Cortex.Pulse.GraphRuntime' primitives to agree over
exhaustive small DAGs and adversarial lifecycle states. This module owns the
shared scenario corpus, a canonical single-line trace format that all three
drivers emit, and the Haskell reference driver built directly on the
GraphRuntime frontier, failure-closure, and completion primitives. The Lean
driver ('CortexWireDiff') and the C harness ('differential-harness.c') replay
the same corpus and must produce byte-identical traces.
-}
module Cortex.Wire.StaticDifferential
  ( -- * Corpus
    Scenario (..)
  , CompletionEvent (..)
  , differentialCorpus
  , scenarioArtifact

    -- * Reference driver
  , runScenario
  , renderTraceLine

    -- * Emission
  , renderScenarioLine
  , emitDifferentialCorpus
  )
where

import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.ByteString.Lazy qualified as BSL
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Cortex.Algebra.Graph (Graph, edges, toRelation, vertices)
import Cortex.Algebra.Graph.Core (Relation)
import Cortex.Pulse.GraphRuntime
  ( GraphState (..)
  , NodeStatus (..)
  , allSettled
  , hasFailedNodes
  , initialGraphState
  , markCompleted
  , markFailed
  , markRunning
  , markSkipped
  , propagateFailure
  , readyNodes
  )
import Cortex.Pulse.Node (NodeId (..))

{- | One completion delivered to a running node when @drive@ reports awaiting.

@outcome@ and @node@ are kept as raw integers rather than a closed sum so the
corpus can drive the adversarial invalid-node and invalid-outcome branches of
the C ABI without special-casing them in the format.
-}
data CompletionEvent = CompletionEvent
  { ceNode :: !Int
  , ceOutcome :: !Int
  , cePayload :: !Word64
  }
  deriving stock (Eq, Show)

{- | A single differential scenario: a fixed topology, a per-node effect-begin
plan, and an ordered stream of asynchronous completions.
-}
data Scenario = Scenario
  { scId :: !Text
  , scNodeCount :: !Int
  , scEdges :: ![(Int, Int)]
  , scBegin :: ![Int]
  {- ^ Effect kind returned by @effect_begin@ for each node
  (0 accepted-async, 1 success, 2 skipped, 3 failure; other values exercise
  the C @default@ branch).
  -}
  , scBeginPayload :: ![Word64]
  -- ^ Payload handle a synchronous success begin writes for each node.
  , scCompletions :: ![CompletionEvent]
  }
  deriving stock (Eq, Show)

-- Effect-kind codes shared with the generated C ABI.
effectAsync, effectSuccess, effectSkipped, effectFailure :: Int
effectAsync = 0
effectSuccess = 1
effectSkipped = 2
effectFailure = 3

-- Drive-result codes shared with the generated C ABI.
driveAwaiting, driveCompleted, driveFailed, driveStuck :: Int
driveAwaiting = 0
driveCompleted = 1
driveFailed = 2
driveStuck = 3

-- Completion-result codes shared with the generated C ABI.
completionApplied, completionStale, completionInvalid :: Int
completionApplied = 0
completionStale = 1
completionInvalid = 2

-- Lifecycle status codes shared with the generated C ABI.
statusPending, statusRunning, statusCompleted, statusFailed, statusSkipped, statusInvalid :: Int
statusPending = 0
statusRunning = 1
statusCompleted = 2
statusFailed = 3
statusSkipped = 4
statusInvalid = 255

-- | Dense node identifier used by the GraphRuntime state.
nodeIdOf :: Int -> NodeId
nodeIdOf = NodeId . T.pack . show

-- | Build the runtime relation for a dense topology, including isolated nodes.
scenarioRelation :: Scenario -> Relation NodeId
scenarioRelation sc =
  toRelation graph
  where
    graph :: Graph NodeId
    graph =
      vertices (fmap nodeIdOf [0 .. scNodeCount sc - 1])
        <> edges [(nodeIdOf s, nodeIdOf t) | (s, t) <- scEdges sc]

statusCode :: NodeStatus -> Int
statusCode = \case
  NodePending -> statusPending
  NodeRunning -> statusRunning
  NodeCompleted -> statusCompleted
  NodeFailed -> statusFailed
  NodeSkipped -> statusSkipped
  NodeInterrupted _ -> statusInvalid
  NodeRewritten -> statusInvalid
  NodeWaiting _ -> statusInvalid

-- | One recorded trace token: a driven step or an applied completion.
data TraceStep
  = DriveStep !Int ![Int] ![Maybe Word64]
  | CompleteStep !CompletionEvent !Int

-- | Full trace of one scenario, matched byte-for-byte across the three drivers.
data Trace = Trace
  { trId :: !Text
  , trSteps :: ![TraceStep]
  , trTerminal :: !Int
  , trFinalStatus :: ![Int]
  , trFinalOutput :: ![Maybe Word64]
  }

{- | The reference machine: a GraphRuntime state plus a terminal-failure latch.

The latch mirrors the generated C @terminal_failed@ flag: once a drive settles
the run as failed, further drives are frozen and completions are rejected.
-}
data Machine = Machine
  { mState :: !(GraphState Word64)
  , mTerminal :: !Bool
  }

anyRunning :: GraphState Word64 -> Bool
anyRunning state =
  NodeRunning `elem` Map.elems (gsNodeStatuses state)

statusSnapshot :: Int -> GraphState Word64 -> [Int]
statusSnapshot n state =
  [ maybe statusPending statusCode (Map.lookup (nodeIdOf i) (gsNodeStatuses state))
  | i <- [0 .. n - 1]
  ]

outputSnapshot :: Int -> GraphState Word64 -> [Maybe Word64]
outputSnapshot n state =
  [Map.lookup (nodeIdOf i) (gsNodeOutputs state) | i <- [0 .. n - 1]]

{- | Latch terminal failure: cancel each running sibling once by moving it to
failed, mirroring the C @latch_terminal_failure@ sweep.
-}
latchTerminalFailure :: Int -> GraphState Word64 -> GraphState Word64
latchTerminalFailure n state =
  foldl
    ( \st i ->
        if Map.lookup (nodeIdOf i) (gsNodeStatuses st) == Just NodeRunning
          then markFailed (nodeIdOf i) st
          else st
    )
    state
    [0 .. n - 1]

{- | One @drive@ call, mirroring the corrected generated C inner loop exactly.

Each outer iteration closes failures and short-circuits to failed (latching the
terminal flag and cancelling running siblings), then snapshots the pending
frontier and dispatches its members in ascending identifier order, marking each
running immediately before invoking its begin. Dispatch stops at the first node
that begins failed, leaving later frontier members pending — so a sibling failure
never strands an undispatched node in the running state.
-}
driveOnce
  :: Relation NodeId
  -> Scenario
  -> Machine
  -> (Int, Machine)
driveOnce rel sc machine
  | mTerminal machine = (driveFailed, machine)
  | otherwise = loop (mState machine)
  where
    n = scNodeCount sc

    beginKind :: Int -> Int
    beginKind = indexOr effectFailure (scBegin sc)

    beginPayload :: Int -> Word64
    beginPayload = indexOr 0 (scBeginPayload sc)

    loop state0 =
      let closed = propagateFailure rel state0
       in if hasFailedNodes rel closed
            then (driveFailed, Machine (latchTerminalFailure n closed) True)
            else
              let frontier = fmap (read . T.unpack . unNodeId) (sortOn unNodeId (readyNodes rel closed))
               in if null frontier
                    then
                      if anyRunning closed
                        then (driveAwaiting, Machine closed False)
                        else
                          if allSettled rel closed
                            then (driveCompleted, Machine closed False)
                            else (driveStuck, Machine closed False)
                    else loop (dispatchFrontier closed frontier)

    -- Dispatch the snapshot in order; each node is marked running, then begun;
    -- a failing begin stops the pass, leaving later members pending.
    dispatchFrontier state [] = state
    dispatchFrontier state (node : rest) =
      let nid = nodeIdOf node
          running = markRunning nid state
          kind = beginKind node
          dispatched
            | kind == effectAsync = running
            | kind == effectSuccess = markCompleted nid (beginPayload node) running
            | kind == effectSkipped = markSkipped nid running
            | otherwise = markFailed nid running
       in if Map.lookup nid (gsNodeStatuses dispatched) == Just NodeFailed
            then dispatched
            else dispatchFrontier dispatched rest

{- | Apply one completion to a running node, mirroring the C @complete@ ABI,
including post-terminal rejection.
-}
applyCompletionEvent
  :: Scenario
  -> CompletionEvent
  -> Machine
  -> (Int, Machine)
applyCompletionEvent sc event machine
  | mTerminal machine = (completionStale, machine)
  | ceNode event < 0 || ceNode event >= scNodeCount sc = (completionInvalid, machine)
  | currentStatus /= NodeRunning = (completionStale, machine)
  | ceOutcome event == effectSuccess =
      (completionApplied, machine {mState = markCompleted nid (cePayload event) state})
  | ceOutcome event == effectSkipped =
      (completionApplied, machine {mState = markSkipped nid state})
  | ceOutcome event == effectFailure =
      (completionApplied, machine {mState = markFailed nid state})
  | otherwise = (completionInvalid, machine)
  where
    state = mState machine
    nid = nodeIdOf (ceNode event)
    currentStatus = Map.findWithDefault NodePending nid (gsNodeStatuses state)

{- | Replay a full scenario through the GraphRuntime primitives.

The harness loop drives, and whenever a drive reports awaiting it consumes the
next completion event. Once a drive settles the run, any remaining completions
are still delivered so the differential observes their post-terminal rejection,
but no further drives are issued. Progress is monotone — every non-empty frontier
removes at least one node from the pending set — so the loop terminates without a
fuel bound.
-}
runScenario :: Scenario -> Trace
runScenario sc =
  let rel = scenarioRelation sc
      machine0 = Machine (initialGraphState rel) False
      (steps, terminal, finalMachine) = go rel machine0 (scCompletions sc) []
   in Trace
        { trId = scId sc
        , trSteps = reverse steps
        , trTerminal = terminal
        , trFinalStatus = statusSnapshot (scNodeCount sc) (mState finalMachine)
        , trFinalOutput = outputSnapshot (scNodeCount sc) (mState finalMachine)
        }
  where
    snapshotStep result machine =
      DriveStep
        result
        (statusSnapshot (scNodeCount sc) (mState machine))
        (outputSnapshot (scNodeCount sc) (mState machine))

    go rel machine events acc =
      let (result, machine') = driveOnce rel sc machine
          driveTok = snapshotStep result machine'
       in if result == driveAwaiting
            then case events of
              [] -> (driveTok : acc, result, machine')
              (event : rest) ->
                let (cResult, machine'') = applyCompletionEvent sc event machine'
                    completeTok = CompleteStep event cResult
                 in go rel machine'' rest (completeTok : driveTok : acc)
            else drain machine' events (driveTok : acc) result

    -- After a terminal drive, deliver remaining completions (each rejected) so
    -- the differential records post-terminal completion handling.
    drain machine [] acc terminal = (acc, terminal, machine)
    drain machine (event : rest) acc terminal =
      let (cResult, machine') = applyCompletionEvent sc event machine
          completeTok = CompleteStep event cResult
       in drain machine' rest (completeTok : acc) terminal

-- | Safe list index with an explicit default for out-of-range positions.
indexOr :: a -> [a] -> Int -> a
indexOr fallback xs i =
  case drop i xs of
    (value : _) -> value
    [] -> fallback

-- | Render an optional opaque handle: a decimal literal or @n@ for absent.
renderOutput :: Maybe Word64 -> Text
renderOutput = maybe "n" (T.pack . show)

renderIntList :: [Int] -> Text
renderIntList = T.intercalate "," . fmap (T.pack . show)

renderOutputList :: [Maybe Word64] -> Text
renderOutputList = T.intercalate "," . fmap renderOutput

renderStep :: TraceStep -> Text
renderStep = \case
  DriveStep result statuses outputs ->
    "D"
      <> T.pack (show result)
      <> ":"
      <> renderIntList statuses
      <> ":"
      <> renderOutputList outputs
  CompleteStep event result ->
    "C"
      <> T.pack (show (ceNode event))
      <> ","
      <> T.pack (show (ceOutcome event))
      <> ","
      <> T.pack (show (cePayload event))
      <> ":"
      <> T.pack (show result)

{- | Canonical single-line trace, shared verbatim by all three drivers.

The fields are tab-separated: scenario id, space-separated step tokens, the
terminal drive-result code, the final status vector, and the final output
vector. Byte equality of these lines across the three drivers is the differential
gate.
-}
renderTraceLine :: Trace -> Text
renderTraceLine trace =
  T.intercalate
    "\t"
    [ trId trace
    , T.unwords (fmap renderStep (trSteps trace))
    , T.pack (show (trTerminal trace))
    , renderIntList (trFinalStatus trace)
    , renderOutputList (trFinalOutput trace)
    ]

-- | The static-program artifact JSON for a scenario topology.
scenarioArtifact :: Scenario -> Value
scenarioArtifact sc =
  Aeson.object
    [ "schema" .= ("cortex.wire.static-program/v1" :: Text)
    , "admission_schema_version" .= (4 :: Int)
    , "program_id" .= scId sc
    , "program_identity" .= ("differential-" <> scId sc)
    , "nodes"
        .= [ Aeson.object
               [ "id" .= i
               , "ref" .= ("node-" <> T.pack (show i))
               , "executor" .= ("fixture.differential" :: Text)
               ]
           | i <- [0 .. scNodeCount sc - 1]
           ]
    , "edges"
        .= [Aeson.object ["from" .= s, "to" .= t] | (s, t) <- scEdges sc]
    ]

{- | The scenario consumed by the Lean and C drivers, as one whitespace-free line.

Six space-separated fields: id, node count, edges, begin kinds, begin payloads,
and completions. List fields use comma separators (and @:@ within an edge or
completion tuple), with @-@ standing for an empty list. This flat grammar keeps
the C harness and Lean driver parsers trivial and free of a JSON dependency.
-}
renderScenarioLine :: Scenario -> Text
renderScenarioLine sc =
  T.unwords
    [ scId sc
    , T.pack (show (scNodeCount sc))
    , listOrDash [T.pack (show s) <> ":" <> T.pack (show t) | (s, t) <- scEdges sc]
    , listOrDash (fmap (T.pack . show) (scBegin sc))
    , listOrDash (fmap (T.pack . show) (scBeginPayload sc))
    , listOrDash
        [ T.pack (show (ceNode e))
            <> ":"
            <> T.pack (show (ceOutcome e))
            <> ":"
            <> T.pack (show (cePayload e))
        | e <- scCompletions sc
        ]
    ]
  where
    listOrDash [] = "-"
    listOrDash xs = T.intercalate "," xs

-- ---------------------------------------------------------------------------
-- Corpus
-- ---------------------------------------------------------------------------

-- | All directed pairs over dense identifiers @0 .. n - 1@.
directedPairs :: Int -> [(Int, Int)]
directedPairs n = [(s, t) | s <- [0 .. n - 1], t <- [0 .. n - 1], s /= t]

-- | Whether an edge set is acyclic, by iterated source elimination.
acyclic :: Int -> [(Int, Int)] -> Bool
acyclic n = go [0 .. n - 1]
  where
    go [] _ = True
    go remaining remainingEdges =
      case filter (\v -> not (any (\(_s, t) -> t == v) remainingEdges)) remaining of
        [] -> null remaining
        (v : _) ->
          go
            (filter (/= v) remaining)
            (filter (\(s, t) -> s /= v && t /= v) remainingEdges)

-- | All subsets of a list, smallest-first is not required; order is fixed.
subsets :: [a] -> [[a]]
subsets [] = [[]]
subsets (x : xs) = let rest = subsets xs in rest <> fmap (x :) rest

-- | Every acyclic DAG on dense identifiers @0 .. n - 1@.
acyclicTopologies :: Int -> [[(Int, Int)]]
acyclicTopologies n =
  filter (acyclic n) (subsets (directedPairs n))

-- | A short stable tag for an edge set, used to build scenario identifiers.
edgeTag :: [(Int, Int)] -> Text
edgeTag [] = "e"
edgeTag es =
  "e" <> T.intercalate "_" [T.pack (show s <> "-" <> show t) | (s, t) <- es]

-- | Named four-node shapes covering the ADR-mandated composite topologies.
namedTopologies :: [(Text, Int, [(Int, Int)])]
namedTopologies =
  [ ("chain4", 4, [(0, 1), (1, 2), (2, 3)])
  , ("diamond4", 4, [(0, 1), (0, 2), (1, 3), (2, 3)])
  , ("fanout4", 4, [(0, 1), (0, 2), (0, 3)])
  , ("fanin4", 4, [(0, 3), (1, 3), (2, 3)])
  , ("indfrontier4", 4, [(0, 2), (1, 3)])
  ]

-- | Topologies driven exhaustively for small @n@ plus the named composites.
corpusTopologies :: [(Text, Int, [(Int, Int)])]
corpusTopologies =
  [ ("t" <> T.pack (show n) <> "-" <> edgeTag es, n, es)
  | n <- [0 .. 3]
  , es <- acyclicTopologies n
  ]
    <> [("t4-" <> name, n, es) | (name, n, es) <- namedTopologies]

-- | Lifecycle scenarios generated for one topology.
topologyScenarios :: Text -> Int -> [(Int, Int)] -> [Scenario]
topologyScenarios topoId n es =
  concat
    [ [allAsyncSuccess]
    , [allSyncSuccess]
    , [descendingCompletions | n >= 2]
    , perNodeSyncFailure
    , perNodeAsyncFailure
    , perNodeSyncSkip
    , adversarial
    ]
  where
    scenario name begin payload completions =
      Scenario
        { scId = topoId <> "-" <> name
        , scNodeCount = n
        , scEdges = es
        , scBegin = begin
        , scBeginPayload = payload
        , scCompletions = completions
        }

    allNodes = [0 .. n - 1]

    -- Every node begins asynchronously and is completed with a success in
    -- ascending identifier order.
    allAsyncSuccess =
      scenario
        "all-async-success"
        (replicate n effectAsync)
        (replicate n 0)
        [CompletionEvent i effectSuccess (fromIntegral (100 + i)) | i <- allNodes]

    -- Every node begins with a synchronous success; no completions are needed.
    allSyncSuccess =
      scenario
        "all-sync-success"
        (replicate n effectSuccess)
        [fromIntegral (200 + i) | i <- allNodes]
        []

    -- Async successes delivered in descending identifier order.
    descendingCompletions =
      scenario
        "async-success-descending"
        (replicate n effectAsync)
        (replicate n 0)
        [CompletionEvent i effectSuccess (fromIntegral (300 + i)) | i <- reverse allNodes]

    -- Each node in turn fails synchronously; the rest succeed synchronously.
    perNodeSyncFailure =
      [ scenario
          ("sync-failure-" <> T.pack (show k))
          [if i == k then effectFailure else effectSuccess | i <- allNodes]
          [fromIntegral (400 + i) | i <- allNodes]
          []
      | k <- allNodes
      ]

    -- Each node in turn begins async and is completed with a failure.
    perNodeAsyncFailure =
      [ scenario
          ("async-failure-" <> T.pack (show k))
          [if i == k then effectAsync else effectSuccess | i <- allNodes]
          [fromIntegral (500 + i) | i <- allNodes]
          [CompletionEvent k effectFailure 0]
      | k <- allNodes
      ]

    -- Each node in turn is skipped synchronously.
    perNodeSyncSkip =
      [ scenario
          ("sync-skip-" <> T.pack (show k))
          [if i == k then effectSkipped else effectSuccess | i <- allNodes]
          [fromIntegral (600 + i) | i <- allNodes]
          []
      | k <- allNodes
      ]

    -- Adversarial completion streams over an all-async topology.
    adversarial
      | n == 0 = []
      | otherwise =
          [ -- Stale: complete node 0, then complete it again.
            scenario
              "adversarial-duplicate"
              (replicate n effectAsync)
              (replicate n 0)
              ( [CompletionEvent i effectSuccess (fromIntegral (700 + i)) | i <- allNodes]
                  <> [CompletionEvent 0 effectSuccess 0]
              )
          , -- Invalid: complete an out-of-range node before the valid stream.
            scenario
              "adversarial-invalid-node"
              (replicate n effectAsync)
              (replicate n 0)
              ( CompletionEvent n effectSuccess 0
                  : [CompletionEvent i effectSuccess (fromIntegral (800 + i)) | i <- allNodes]
              )
          , -- Invalid outcome code delivered to a running node.
            scenario
              "adversarial-invalid-outcome"
              (replicate n effectAsync)
              (replicate n 0)
              (CompletionEvent 0 99 0 : [CompletionEvent i effectSuccess (fromIntegral (900 + i)) | i <- allNodes])
          , -- Stale after synchronous settlement: complete an already-terminal node.
            scenario
              "adversarial-stale-terminal"
              (replicate n effectSuccess)
              [fromIntegral (1000 + i) | i <- allNodes]
              [CompletionEvent 0 effectSuccess 0]
          , -- Post-terminal: fail node 0, then attempt a completion after the run
            -- has latched failed. On an independent topology this also cancels a
            -- still-running sibling exactly once.
            scenario
              "adversarial-post-terminal"
              (replicate n effectAsync)
              (replicate n 0)
              ( CompletionEvent 0 effectFailure 0
                  : [CompletionEvent i effectSuccess (fromIntegral (1100 + i)) | i <- allNodes, i /= 0]
              )
          ]

-- | The full differential corpus: every topology's lifecycle scenarios.
differentialCorpus :: [Scenario]
differentialCorpus =
  [ scenario
  | (topoId, n, es) <- corpusTopologies
  , scenario <- topologyScenarios topoId n es
  ]

{- | Emit the corpus, per-topology artifacts and scenarios, and the Haskell
reference traces under @outDir@.

Layout:

* @outDir\/topologies\/\<topoId\>\/artifact.json@ — the static-program artifact.
* @outDir\/topologies\/\<topoId\>\/scenarios.jsonl@ — one scenario JSON per line.
* @outDir\/haskell-traces.txt@ — one canonical trace line per scenario.
* @outDir\/index.json@ — topology and scenario inventory for the check log.

Returns the topology and scenario counts so the caller can report coverage.
-}
emitDifferentialCorpus :: FilePath -> IO (Int, Int)
emitDifferentialCorpus outDir = do
  createDirectoryIfMissing True outDir
  let topologies = corpusTopologies
      byTopology =
        [ (topoId, n, es, topologyScenarios topoId n es)
        | (topoId, n, es) <- topologies
        ]
  mapM_ writeTopology byTopology
  let allScenarios = concatMap (\(_, _, _, scs) -> scs) byTopology
      traceLines = fmap (renderTraceLine . runScenario) allScenarios
  TE.encodeUtf8 (T.unlines traceLines)
    & BSL.fromStrict
    & BSL.writeFile (outDir </> "haskell-traces.txt")
  -- Combined corpus consumed by the topology-agnostic Lean driver.
  TE.encodeUtf8 (T.unlines (fmap renderScenarioLine allScenarios))
    & BSL.fromStrict
    & BSL.writeFile (outDir </> "scenarios-all.txt")
  writeJsonFile (outDir </> "index.json") (indexJson byTopology)
  pure (length topologies, length allScenarios)
  where
    (&) :: a -> (a -> b) -> b
    x & f = f x

    writeTopology (topoId, _n, _es, scs) = do
      let dir = outDir </> "topologies" </> T.unpack topoId
      createDirectoryIfMissing True dir
      case scs of
        [] -> pure ()
        (firstScenario : _) ->
          writeJsonFile (dir </> "artifact.json") (scenarioArtifact firstScenario)
      TE.encodeUtf8 (T.unlines (fmap renderScenarioLine scs))
        & BSL.fromStrict
        & BSL.writeFile (dir </> "scenarios.txt")

    indexJson byTopology =
      Aeson.object
        [ "topology_count" .= length byTopology
        , "scenario_count" .= sum [length scs | (_, _, _, scs) <- byTopology]
        , "topologies"
            .= [ Aeson.object
                   [ "id" .= topoId
                   , "node_count" .= n
                   , "edge_count" .= length es
                   , "scenario_count" .= length scs
                   ]
               | (topoId, n, es, scs) <- byTopology
               ]
        ]

    writeJsonFile path value =
      BSL.writeFile
        path
        (AesonPretty.encodePretty' prettyConfig value <> "\n")

    prettyConfig =
      AesonPretty.defConfig
        { AesonPretty.confIndent = AesonPretty.Spaces 2
        , AesonPretty.confCompare = compare
        , AesonPretty.confTrailingNewline = False
        }
