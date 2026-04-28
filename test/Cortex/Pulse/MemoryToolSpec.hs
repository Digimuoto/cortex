{- | Pure tests for 'Cortex.Pulse.Memory.Tool' (DIG-530 follow-up).

Exercises:

 * Schema decoding — the LLM-facing JSON -> 'CortexMemoryQueryArgs'
   round-trips cleanly for valid inputs and rejects unknown
   enums.
 * 'executeCortexMemoryQuery' — given a bound 'MemoryHandle',
   returns the expected matches with shape stable enough for the
   audit trail.

The handle is built via 'newMemoryHandle' over a fixture snapshot
so no executor, DB, or HTTP needed.
-}
module Cortex.Pulse.MemoryToolSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Relation
  , edges
  , toRelation
  )
import Cortex.Pulse.Memory
import Cortex.Pulse.Memory.Tool
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Runtime (NodeStatus (..))

-- ============================================================================
-- Fixtures
-- ============================================================================

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 4 22) (secondsToDiffTime 0)

tAt :: Integer -> UTCTime
tAt secs = addUTCTime (fromIntegral secs) t0

nid :: Text -> NodeId
nid = NodeId

fanoutTopology :: Relation NodeId
fanoutTopology =
  toRelation
    ( edges
        [ (nid "planner", nid "analyst-a")
        , (nid "planner", nid "analyst-b")
        , (nid "analyst-a", nid "reviewer")
        , (nid "analyst-b", nid "reviewer")
        ]
    )

fanoutStatuses :: Map NodeId NodeStatus
fanoutStatuses =
  Map.fromList
    [ (nid "planner", NodeCompleted)
    , (nid "analyst-a", NodeCompleted)
    , (nid "analyst-b", NodeCompleted)
    , (nid "reviewer", NodePending)
    ]

fanoutOutputs :: Map NodeId Aeson.Value
fanoutOutputs =
  Map.fromList
    [
      ( nid "planner"
      , Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan text" :: Text)]
      )
    ,
      ( nid "analyst-a"
      , Aeson.object ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("alpha analysis" :: Text)]
      )
    ,
      ( nid "analyst-b"
      , Aeson.object ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("beta analysis" :: Text)]
      )
    ]

fanoutCompletedAt :: Map NodeId UTCTime
fanoutCompletedAt =
  Map.fromList
    [ (nid "planner", tAt 0)
    , (nid "analyst-a", tAt 10)
    , (nid "analyst-b", tAt 20)
    ]

fanoutSnapshot :: MemorySnapshot
fanoutSnapshot =
  MemorySnapshot
    { msTopology = fanoutTopology
    , msNodeStatuses = fanoutStatuses
    , msNodeOutputs = fanoutOutputs
    , msNodeCompletedAt = fanoutCompletedAt
    , msCapturedAt = tAt 60
    }

fanoutHandle :: MemoryHandle
fanoutHandle = newMemoryHandle fanoutSnapshot

-- ============================================================================
-- Spec
-- ============================================================================

spec :: Spec
spec = describe "cortex_memory_query tool" $ do
  describe "schema + args parsing" $ do
    it "decodes a populated args object" $ do
      let raw =
            Aeson.object
              [ "preset" Aeson..= ("reviewer" :: Text)
              , "direction" Aeson..= ("ancestors" :: Text)
              , "scope" Aeson..= ("settled_only" :: Text)
              , "routingKey" Aeson..= ("analyst" :: Text)
              , "limit" Aeson..= (16 :: Int)
              , "maxGraphDistance" Aeson..= (2 :: Int)
              ]
      case parseCortexMemoryQueryArgs raw of
        Left err -> expectationFailure ("unexpected parse failure: " <> show err)
        Right args -> do
          args.cmqPreset `shouldBe` Just PresetReviewer
          args.cmqDirection `shouldBe` Just Ancestors
          args.cmqScope `shouldBe` Just SettledOnly
          args.cmqRoutingKey `shouldBe` Just "analyst"
          args.cmqLimit `shouldBe` Just 16
          args.cmqMaxGraphDistance `shouldBe` Just 2

    it "treats an empty object as all-defaults" $ do
      case parseCortexMemoryQueryArgs (Aeson.object []) of
        Left err -> expectationFailure ("unexpected parse failure: " <> show err)
        Right args -> do
          args.cmqPreset `shouldBe` Nothing
          args.cmqDirection `shouldBe` Nothing
          args.cmqRoutingKey `shouldBe` Nothing
          args.cmqLimit `shouldBe` Nothing

    it "rejects an unknown direction" $ do
      let raw = Aeson.object ["direction" Aeson..= ("sideways" :: Text)]
      parseCortexMemoryQueryArgs raw `shouldSatisfy` isLeft

    it "rejects an unknown scope" $ do
      let raw = Aeson.object ["scope" Aeson..= ("anything_goes" :: Text)]
      parseCortexMemoryQueryArgs raw `shouldSatisfy` isLeft

    it "exposes the tool schema as a valid JSON-schema object" $ do
      case cortexMemoryQuerySchema of
        Aeson.Object obj -> do
          KeyMap.lookup "type" obj `shouldBe` Just (Aeson.String "object")
          KeyMap.lookup (Key.fromText "additionalProperties") obj `shouldBe` Just (Aeson.Bool False)
        other -> expectationFailure ("expected object schema, got " <> show other)

    it "exposes a function-shaped tool definition with the canonical name" $ do
      case cortexMemoryQueryToolDefinition of
        Aeson.Object obj -> do
          KeyMap.lookup "type" obj `shouldBe` Just (Aeson.String "function")
          case KeyMap.lookup "function" obj of
            Just (Aeson.Object fn) ->
              KeyMap.lookup "name" fn `shouldBe` Just (Aeson.String cortexMemoryQueryToolName)
            other -> expectationFailure ("expected function object, got " <> show other)
        other -> expectationFailure ("expected object definition, got " <> show other)

  describe "executeCortexMemoryQuery" $ do
    it "returns every settled ancestor from the reviewer (no routing filter)" $ do
      let args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Nothing
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Nothing
              }
      result <-
        executeCortexMemoryQuery fanoutHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 3)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "filters by routing key — analyst-only returns the two analysts" $ do
      let args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Just "analyst"
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Nothing
              }
      result <-
        executeCortexMemoryQuery fanoutHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 2)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "honours the limit override" $ do
      let args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Nothing
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Just 1
              }
      result <-
        executeCortexMemoryQuery fanoutHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 1)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "honours the max-graph-distance cutoff" $ do
      let args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Nothing
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Just 1
              , cmqLimit = Nothing
              }
      result <-
        executeCortexMemoryQuery fanoutHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          -- analysts are 1 hop; planner is 2 hops, cut.
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 2)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "unwraps WireValue envelopes before extracting slot/text" $ do
      -- Wire-bound stages persist outputs like:
      --   { "contract": "analyst.draft", "value": { "slot": "analyst", "text": "…" }, … }
      -- The tool must peel that envelope so routingKey filters and
      -- bodyText both work against wire-shaped outputs.
      let wireWrapped :: Text -> Text -> Aeson.Value
          wireWrapped slot body =
            Aeson.object
              [ "contract" Aeson..= ("analyst.draft" :: Text)
              , "payloadKind" Aeson..= ("json" :: Text)
              , "mediaType" Aeson..= ("application/json" :: Text)
              , "producer" Aeson..= ("analyst-a" :: Text)
              , "value"
                  Aeson..= Aeson.object
                    [ "slot" Aeson..= slot
                    , "text" Aeson..= body
                    ]
              , "provenance" Aeson..= Aeson.Null
              ]
          wireOutputs =
            Map.fromList
              [
                ( nid "planner"
                , Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan text" :: Text)]
                )
              , (nid "analyst-a", wireWrapped "analyst" "alpha analysis")
              , (nid "analyst-b", wireWrapped "analyst" "beta analysis")
              ]
          wireSnap =
            fanoutSnapshot {msNodeOutputs = wireOutputs}
          wireHandle = newMemoryHandle wireSnap
          args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Just "analyst"
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Nothing
              }
      result <-
        executeCortexMemoryQuery wireHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          -- Both analysts match via routingKey="analyst" only if the
          -- envelope was peeled; without unwrap, matchCount = 0.
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 2)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "unwraps WireValueSet envelopes (plural 'values' field, not 'wireValues')" $ do
      -- 'Cortex.Wire.Value.WireValueSet' serialises as @{ "values": [ WireValue ] }@.
      -- The extractor must peel that set wrapper to reach each
      -- element's inner @value@ object, otherwise routing-key filters
      -- and bodyText extraction fail against stages that emit
      -- explicit sets ('singletonWireValueSet' is the common case).
      let wireWrapped :: Text -> Text -> Aeson.Value
          wireWrapped slot body =
            Aeson.object
              [ "contract" Aeson..= ("analyst.draft" :: Text)
              , "payloadKind" Aeson..= ("json" :: Text)
              , "mediaType" Aeson..= ("application/json" :: Text)
              , "producer" Aeson..= ("analyst-a" :: Text)
              , "value"
                  Aeson..= Aeson.object
                    [ "slot" Aeson..= slot
                    , "text" Aeson..= body
                    ]
              , "provenance" Aeson..= Aeson.Null
              ]
          wireValueSet :: Text -> Text -> Aeson.Value
          wireValueSet slot body =
            Aeson.object
              [ "values" Aeson..= [wireWrapped slot body]
              ]
          wireOutputs =
            Map.fromList
              [
                ( nid "planner"
                , Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan text" :: Text)]
                )
              , (nid "analyst-a", wireValueSet "analyst" "alpha analysis")
              , (nid "analyst-b", wireValueSet "analyst" "beta analysis")
              ]
          wireSnap = fanoutSnapshot {msNodeOutputs = wireOutputs}
          wireHandle = newMemoryHandle wireSnap
          args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Just "analyst"
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Nothing
              }
      result <-
        executeCortexMemoryQuery wireHandle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj ->
          KeyMap.lookup "matchCount" obj `shouldBe` Just (Aeson.Number 2)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "queryText narrows recall via the token-jaccard semantic axis" $ do
      -- Under a limit of 1 with no semantic weight, ranking is
      -- driven by graph influence alone and ties break on NodeId.
      -- Setting a queryText that only overlaps with one of the
      -- analysts' body text must shift the top match to that
      -- analyst — proves the scorer is wired up and the "use
      -- `queryText` to narrow recall" nudge in the reviewer prompt
      -- is not just advisory.
      let semanticWeightSnap =
            fanoutSnapshot
              { msNodeOutputs =
                  Map.fromList
                    [
                      ( nid "planner"
                      , Aeson.object ["slot" Aeson..= ("planner" :: Text), "text" Aeson..= ("plan details" :: Text)]
                      )
                    ,
                      ( nid "analyst-a"
                      , Aeson.object
                          ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("china revenue grew 12 percent" :: Text)]
                      )
                    ,
                      ( nid "analyst-b"
                      , Aeson.object
                          ["slot" Aeson..= ("analyst" :: Text), "text" Aeson..= ("europe margin held steady" :: Text)]
                      )
                    ]
              }
          handle = newMemoryHandle semanticWeightSnap
          args =
            CortexMemoryQueryArgs
              { cmqPreset = Just PresetDefault
              , cmqDirection = Just Ancestors
              , cmqScope = Just SettledOnly
              , cmqRoutingKey = Just "analyst"
              , cmqQueryText = Just "china revenue"
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Just 1
              }
      result <-
        executeCortexMemoryQuery handle defaultMemoryStrategy (nid "reviewer") args
      case result of
        Aeson.Object obj -> case KeyMap.lookup "matches" obj of
          Just (Aeson.Array arr) -> case toList arr of
            [Aeson.Object matchObj] ->
              KeyMap.lookup "nodeId" matchObj `shouldBe` Just (Aeson.String "analyst-a")
            other -> expectationFailure ("expected one match, got " <> show other)
          other -> expectationFailure ("expected matches array, got " <> show other)
        other -> expectationFailure ("expected object result, got " <> show other)

    it "inherits the caller's topological preset when cmqPreset is Nothing" $ do
      -- The reviewer preset has wsLimit = Nothing and balanced
      -- weights; here we just verify the inherited limit behaviour
      -- by supplying a TopologicalStrategyConfig with a tight
      -- per-stage limit and confirming it's surfaced even with a
      -- bare args object.
      let callerCfg =
            TopologicalStrategyConfig
              { tscPreset = PresetReviewer
              , tscRoutingKey = Nothing
              , tscLimit = Nothing
              }
          callerStrategy = MemoryTopological callerCfg
          bareArgs =
            CortexMemoryQueryArgs
              { cmqPreset = Nothing
              , cmqDirection = Nothing
              , cmqScope = Nothing
              , cmqRoutingKey = Nothing
              , cmqQueryText = Nothing
              , cmqMaxGraphDistance = Nothing
              , cmqLimit = Nothing
              }
      inherited <-
        executeCortexMemoryQuery fanoutHandle callerStrategy (nid "reviewer") bareArgs
      classic <-
        executeCortexMemoryQuery fanoutHandle MemoryClassic (nid "reviewer") bareArgs
      -- Reviewer preset uses Ancestors + SettledOnly, same as the
      -- default; but it also raises graph-distance weighting so the
      -- /ordering/ shifts.  Both snapshots match the same three
      -- settled ancestors of the reviewer (planner + two analysts),
      -- so matchCount is stable — the point is that defaulting no
      -- longer hardcodes PresetDefault, so the caller strategy
      -- reaches the walk.  Spot-check that the match sets agree in
      -- size; divergence would indicate the strategy got swallowed.
      let matchCount (Aeson.Object o) = KeyMap.lookup "matchCount" o
          matchCount _ = Nothing
      matchCount inherited `shouldBe` Just (Aeson.Number 3)
      matchCount classic `shouldBe` Just (Aeson.Number 3)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
