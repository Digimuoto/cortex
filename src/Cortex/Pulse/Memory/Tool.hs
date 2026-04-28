{- |
Module      : Cortex.Pulse.Memory.Tool
Description : @cortex_memory_query@ tool — agent-driven ad-hoc recall over the.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

DIG-529/530 topological memory (DIG-530 follow-up).

This is the tool-surface complement to the declarative
@meta.memory = …@ per-node knob.  Where the wire meta bakes a
memory read into the stage's prefix (cheap, deterministic, no
agent latency), the tool lets an LLM-driven stage issue arbitrary
walks mid-reasoning when the authored walk didn't return enough
context.

The tool schema and the pure execution path live here so both the
Pulse-native dispatch (in-process stage actions calling
'executeCortexMemoryQuery' directly) and the DeepReport
interceptor (which partitions tool calls before the HTTP bounce)
share the same contract.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Memory.Tool
  ( -- * Tool identity + schema
    cortexMemoryQueryToolName
  , cortexMemoryQueryToolDefinition
  , cortexMemoryQuerySchema

    -- * Execution
  , CortexMemoryQueryArgs (..)
  , parseCortexMemoryQueryArgs
  , executeCortexMemoryQuery
  , renderCortexMemoryQueryResult
  )
where

import Control.Applicative ((<|>))
import Data.Aeson ((.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonT
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Pulse.Memory.Query (pureQueryMemory)
import Cortex.Pulse.Memory.Score (defaultSemanticScorer)
import Cortex.Pulse.Memory.Types
  ( ExtractedFields (..)
  , MatchedObservation (..)
  , MemoryHandle (..)
  , MemorySnapshot (..)
  , MemoryStrategy (..)
  , Query (..)
  , ScoreWeights (..)
  , TopologicalStrategyConfig (..)
  , WalkDirection (..)
  , WalkScope (..)
  , WalkSpec (..)
  , WalkSpecPreset (..)
  , emptyQuery
  , resolveWalkSpecPreset
  )
import Cortex.Pulse.Node (NodeId (..))

-- ============================================================================
-- Tool identity
-- ============================================================================

{- | Canonical tool name.  Matches the identifier the LLM emits in
'CortexToolCall.cortexToolCallName'.
-}
cortexMemoryQueryToolName :: Text
cortexMemoryQueryToolName = "cortex_memory_query"

{- | JSON-Schema describing the tool's argument object.  Hand-written
to match the style of the other built-in tools
('Portman.Server.Handler.ToolSchema').

Every field is optional.  Defaults mirror the Haskell defaults:
ancestor walk, settled-only scope, analyst preset, no routing
filter, no semantic text, no limit.
-}
cortexMemoryQuerySchema :: Aeson.Value
cortexMemoryQuerySchema =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= Aeson.object
          [ "preset"
              .= Aeson.object
                [ "type" .= ("string" :: Text)
                , "enum" .= (["analyst", "reviewer", "planner", "default"] :: [Text])
                , "description"
                    .= ( "Named WalkSpec preset.  Picks the base scoring weights + "
                           <> "direction.  Defaults to the caller stage's declared "
                           <> "strategy preset, or `analyst` when absent."
                           :: Text
                       )
                ]
          , "direction"
              .= Aeson.object
                [ "type" .= ("string" :: Text)
                , "enum" .= (["ancestors", "descendants", "bidirectional"] :: [Text])
                , "description"
                    .= ( "Override the preset's walk direction.  `ancestors` is the "
                           <> "causal cone (default); `descendants` looks forward; "
                           <> "`bidirectional` walks both."
                           :: Text
                       )
                ]
          , "scope"
              .= Aeson.object
                [ "type" .= ("string" :: Text)
                , "enum" .= (["settled_only", "debug_all_statuses"] :: [Text])
                , "description"
                    .= ( "Node-status filter.  `settled_only` is the only sensible "
                           <> "value for semantic reads; `debug_all_statuses` is an "
                           <> "operator-inspection escape hatch."
                           :: Text
                       )
                ]
          , "routingKey"
              .= Aeson.object
                [ "type" .= ("string" :: Text)
                , "description"
                    .= ( "Exact-match filter on the stage output's routing key. "
                           <> "The built-in structural extractor reads the first "
                           <> "non-empty string field among `slot`, `claim_ref`, "
                           <> "or `claimRef` from the output object.  Outputs "
                           <> "using a different routing-key field name will not "
                           <> "be matchable via this filter — their matches drop "
                           <> "when `routingKey` is set.  Omit to see every "
                           <> "settled observation."
                           :: Text
                       )
                ]
          , "queryText"
              .= Aeson.object
                [ "type" .= ("string" :: Text)
                , "description"
                    .= ( "Free-text hint scored by the semantic axis.  The "
                           <> "default scorer is token-jaccard — a short, narrow "
                           <> "natural-language phrase (`\"china revenue 12q4\"`) "
                           <> "raises the rank of nodes whose extracted body "
                           <> "shares vocabulary with the hint.  Pluggable; "
                           <> "pgvector / reranker implementations slot in here."
                           :: Text
                       )
                ]
          , "maxGraphDistance"
              .= Aeson.object
                [ "type" .= ("integer" :: Text)
                , "minimum" .= (0 :: Int)
                , "description" .= ("Hard hop-count cutoff applied before scoring." :: Text)
                ]
          , "limit"
              .= Aeson.object
                [ "type" .= ("integer" :: Text)
                , "minimum" .= (1 :: Int)
                , "description" .= ("Top-N cutoff applied after scoring." :: Text)
                ]
          ]
    , "additionalProperties" .= False
    ]

{- | Full OpenAPI-style function definition for registration in a
tool host.
-}
cortexMemoryQueryToolDefinition :: Aeson.Value
cortexMemoryQueryToolDefinition =
  Aeson.object
    [ "type" .= ("function" :: Text)
    , "function"
        .= Aeson.object
          [ "name" .= cortexMemoryQueryToolName
          , "description"
              .= ( "Query the run's topological memory for upstream observations. "
                     <> "Returns a ranked list of matched nodes with their outputs, "
                     <> "scores, and graph distances from the caller.  Use when the "
                     <> "stage's authored context is not enough and you need to "
                     <> "reach beyond direct parents — e.g. read sibling analysts "
                     <> "that share a routing key, or pull distant ancestors that "
                     <> "match a semantic hint."
                     :: Text
                 )
          , "parameters" .= cortexMemoryQuerySchema
          ]
    ]

-- ============================================================================
-- Argument parsing
-- ============================================================================

{- | Parsed form of the tool's JSON arguments.  Every field is
optional; 'Nothing' means "use the caller-supplied default" which
the dispatcher resolves against the stage's declared strategy.
-}
data CortexMemoryQueryArgs = CortexMemoryQueryArgs
  { cmqPreset :: !(Maybe WalkSpecPreset)
  , cmqDirection :: !(Maybe WalkDirection)
  , cmqScope :: !(Maybe WalkScope)
  , cmqRoutingKey :: !(Maybe Text)
  , cmqQueryText :: !(Maybe Text)
  , cmqMaxGraphDistance :: !(Maybe Int)
  , cmqLimit :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

instance Aeson.FromJSON CortexMemoryQueryArgs where
  parseJSON = Aeson.withObject "CortexMemoryQueryArgs" $ \obj -> do
    mPreset <- obj .:? "preset"
    mDirection <-
      obj .:? "direction" >>= traverse parseDirection
    mScope <-
      obj .:? "scope" >>= traverse parseScope
    CortexMemoryQueryArgs mPreset mDirection mScope
      <$> obj .:? "routingKey"
      <*> obj .:? "queryText"
      <*> obj .:? "maxGraphDistance"
      <*> obj .:? "limit"
    where
      parseDirection :: Text -> AesonT.Parser WalkDirection
      parseDirection = \case
        "ancestors" -> pure Ancestors
        "descendants" -> pure Descendants
        "bidirectional" -> pure Bidirectional
        other -> AesonT.parseFail ("unknown walk direction: " <> T.unpack other)

      parseScope :: Text -> AesonT.Parser WalkScope
      parseScope = \case
        "settled_only" -> pure SettledOnly
        "debug_all_statuses" -> pure DebugAllStatuses
        other -> AesonT.parseFail ("unknown walk scope: " <> T.unpack other)

{- | Decode the raw JSON args the LLM supplied.  Returns a human
readable error string for invalid input so the tool dispatcher
can surface it back to the model.
-}
parseCortexMemoryQueryArgs :: Aeson.Value -> Either Text CortexMemoryQueryArgs
parseCortexMemoryQueryArgs raw =
  case Aeson.fromJSON raw of
    Aeson.Success args -> Right args
    Aeson.Error err -> Left (T.pack err)

-- ============================================================================
-- Execution
-- ============================================================================

{- | Execute a parsed tool call against a memory handle bound to the
caller's stage entry.  The origin node id is the caller's own
'NodeId' so the walk starts from the stage's position in the
topology.

The caller's 'MemoryStrategy' seeds the defaults when the tool
args leave a field blank:

 * @cmqPreset = Nothing@ + caller is 'MemoryTopological' →
   inherit the stage's 'tscPreset'.  So a reviewer whose wire
   declares @memory = topological { preset = "reviewer"; … }@
   runs the tool against the reviewer preset unless the model
   overrides it.
 * @cmqPreset = Nothing@ + caller is 'MemoryClassic' →
   'PresetDefault'.  Classic stages didn't opt into a specific
   topological shape, so the balanced default is the least
   surprising inheritance.
 * @cmqRoutingKey = Nothing@ + caller is 'MemoryTopological'
   with a routing-key filter → /not/ inherited.  The tool lets
   the model explicitly broaden the filter, so leaving it blank
   means "every match", not "whatever the stage picked".

Pure JSON over an in-process IO snapshot read — no DB, no
network.
-}
executeCortexMemoryQuery
  :: MemoryHandle
  -> MemoryStrategy
  -> NodeId
  -> CortexMemoryQueryArgs
  -> IO Aeson.Value
executeCortexMemoryQuery handle callerStrategy origin args = do
  snap <- handle.memorySnapshot
  let basePreset = fromMaybe (inheritedPreset callerStrategy) args.cmqPreset
      baseSpec = resolveWalkSpecPreset basePreset
      walkSpec =
        baseSpec
          { wsDirection = fromMaybe baseSpec.wsDirection args.cmqDirection
          , wsScope = fromMaybe baseSpec.wsScope args.cmqScope
          , wsLimit = args.cmqLimit <|> baseSpec.wsLimit
          , wsWeights =
              baseSpec.wsWeights
                { swMaxGraphDistance =
                    args.cmqMaxGraphDistance <|> baseSpec.wsWeights.swMaxGraphDistance
                }
          }
      query =
        emptyQuery
          { qRoutingKey = args.cmqRoutingKey
          , qSemanticText = args.cmqQueryText
          , qExtractor = defaultExtractor
          , qSemanticScorer = defaultSemanticScorer
          }
      matches = pureQueryMemory origin snap walkSpec query
  pure (renderCortexMemoryQueryResult snap matches)

{- | Resolve the preset a bare tool call inherits from the caller's
declared memory strategy.
-}
inheritedPreset :: MemoryStrategy -> WalkSpecPreset
inheritedPreset = \case
  MemoryClassic -> PresetDefault
  MemoryTopological cfg -> cfg.tscPreset

{- | Serialise the result list into the LLM-visible JSON shape.  The
top-level object carries a summary plus each match's public
fields.  Raw 'Double' scores are emitted — callers that want a
stable string form should round on their side.
-}
renderCortexMemoryQueryResult
  :: MemorySnapshot
  -> [MatchedObservation]
  -> Aeson.Value
renderCortexMemoryQueryResult snap matches =
  Aeson.object
    [ "capturedAt" .= snap.msCapturedAt
    , "matchCount" .= length matches
    , "matches" .= fmap renderMatch matches
    ]
  where
    renderMatch m =
      Aeson.object
        [ "nodeId" .= m.moNodeId
        , "status" .= m.moStatus
        , "graphDistance" .= m.moGraphDistance
        , "score" .= m.moScore
        , "observedAt" .= m.moObservedAt
        , "temporalDelta" .= m.moTemporalDelta
        , -- Flatten 'Maybe (Maybe Text)' (no-extractor vs
          -- extractor-found-nothing) into a single nullable Text —
          -- the LLM-visible JSON only cares whether there is a
          -- routing key, not why there isn't.
          "routingKey" .= (m.moExtracted >>= efRoutingKey)
        , "bodyText" .= fmap efBodyText m.moExtracted
        , "output" .= m.moOutput
        ]

{- | Built-in structural extractor: returns the raw output so a
caller that didn't set a routing-key filter still gets the body
back.  Domain-specific extractors (analyst decoders, etc.) live
in the consumers, not here.

Wire-bound stages wrap their outputs in a 'WireValue' envelope
(see @Cortex.Wire.Runtime.wrapWireStageResult@).  The extractor
peels that envelope first — without importing Wire directly,
which would create a module cycle — by detecting the envelope's
JSON shape @{ "contract": …, "value": … }@ and looking inside
@value@.  Non-wire outputs fall through unchanged.
-}
defaultExtractor :: Aeson.Value -> Maybe ExtractedFields
defaultExtractor raw =
  let v = peelWireValueEnvelope raw
   in Just
        ExtractedFields
          { efRoutingKey = extractRoutingKey v
          , efBodyText = extractBodyText v
          , efEvidence = []
          }

{- | Structural 'WireValue' unwrap.  If the value is a JSON object
with both @contract@ and @value@ fields, return the inner
@value@; otherwise return the input unchanged.  Mirrors the
'Cortex.Wire.Runtime.unwrapWireStageValue' behaviour without
depending on the Wire module (which would cycle: Wire already
depends on 'Cortex.Pulse.Memory.Types').

A 'WireValueSet' wrapper (shape @{ "values": [ … ] }@, from
'Cortex.Wire.Value.WireValueSet' / 'singletonWireValueSet') is
also handled: the set is treated as a sequence of 'WireValue'
envelopes and we peel the first.  For @singletonWireValueSet@
(the common case) this is lossless; for multi-value sets it
surfaces the first value, which is adequate for routing-key /
body-text extraction — downstream logic that needs every element
should decode the full set explicitly.
-}
peelWireValueEnvelope :: Aeson.Value -> Aeson.Value
peelWireValueEnvelope (Aeson.Object obj)
  | Just inner <- KeyMap.lookup (Key.fromText "value") obj
  , KeyMap.member (Key.fromText "contract") obj =
      inner
  | Just (Aeson.Array arr) <- KeyMap.lookup (Key.fromText "values") obj
  , Aeson.Object firstObj : _ <- toList arr
  , Just inner <- KeyMap.lookup (Key.fromText "value") firstObj
  , KeyMap.member (Key.fromText "contract") firstObj =
      inner
peelWireValueEnvelope v = v

{- | Best-effort "slot" / "claim_ref" lookup for the routing-key
filter.  If the output isn't a JSON object with a string routing
field, returns 'Nothing' and the routing-key filter naturally
drops the match (when the caller set @routingKey@).
-}
extractRoutingKey :: Aeson.Value -> Maybe Text
extractRoutingKey (Aeson.Object obj) =
  ( KeyMap.lookup (Key.fromText "slot") obj
      <|> KeyMap.lookup (Key.fromText "claim_ref") obj
      <|> KeyMap.lookup (Key.fromText "claimRef") obj
  )
    >>= stringValue
  where
    stringValue (Aeson.String s) = Just s
    stringValue _ = Nothing
extractRoutingKey _ = Nothing

{- | Best-effort text body lookup for the semantic-score axis.
Looks for common fields; defaults to empty which makes the
semantic axis contribute zero.
-}
extractBodyText :: Aeson.Value -> Text
extractBodyText (Aeson.Object obj) =
  fromMaybe
    ""
    ( lookupString "text"
        <|> lookupString "body"
        <|> lookupString "content"
    )
  where
    lookupString k = case KeyMap.lookup (Key.fromText k) obj of
      Just (Aeson.String s) -> Just s
      _ -> Nothing
extractBodyText _ = ""
