{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Types for the graph-native topological memory (DIG-529).
--
-- Memory is a deterministic query over the Pulse event substrate — not
-- a separate store.  A stage's "view" is the result of a walk over
-- 'Cortex.Pulse.Materialization.PersistedGraphState' at stage entry,
-- scored by a composite heuristic over graph influence, wall-clock
-- distance, and a pluggable semantic score, then filtered and sorted.
--
-- This module owns the pure types.  The walk / scoring / query logic
-- lives in 'Cortex.Pulse.Memory.Walk', 'Cortex.Pulse.Memory.Score', and
-- 'Cortex.Pulse.Memory.Query' respectively.  The umbrella
-- 'Cortex.Pulse.Memory' re-exports and provides handle constructors.
module Cortex.Pulse.Memory.Types
  ( -- * Walk specification
    WalkDirection (..),
    WalkScope (..),
    ScoreWeights (..),
    defaultScoreWeights,
    WalkSpec (..),
    defaultWalkSpec,
    analystWalkSpec,
    reviewerWalkSpec,
    plannerWalkSpec,

    -- * Named presets (selectable from wire meta)
    WalkSpecPreset (..),
    walkSpecPresetFromText,
    walkSpecPresetToText,
    resolveWalkSpecPreset,

    -- * Queries and extractors
    ExtractedFields (..),
    SemanticScorer,
    nullSemanticScorer,
    Query (..),
    emptyQuery,

    -- * Snapshots and results
    MemorySnapshot (..),
    emptyMemorySnapshot,
    MatchedObservation (..),
    MemoryHandle (..),

    -- * Per-stage strategy
    MemoryStrategy (..),
    TopologicalStrategyConfig (..),
    defaultMemoryStrategy,
    defaultTopologicalConfig,
  )
where

import Cortex.Graph (Relation)
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Runtime (NodeStatus)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonT
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime)
import GHC.Generics (Generic)

-- ============================================================================
-- WalkSpec
-- ============================================================================

-- | Which direction the walk reaches from the origin node.
--
--   * 'Ancestors' — reverse-BFS over the topology.  "What could have
--     informed this node?"
--   * 'Descendants' — forward-BFS.  "What did this node influence?"
--     Mostly useful under rewrite re-execution or resume, where some
--     descendants may already have settled outputs.
--   * 'Bidirectional' — the union of both cones.
data WalkDirection
  = Ancestors
  | Descendants
  | Bidirectional
  deriving stock (Eq, Show, Generic)

-- | Which node statuses the walk considers as candidates.
--
-- Memory is /past/ — only nodes with a stable, materialised outcome
-- belong here.  Live execution state ('NodeRunning', 'NodeWaiting'),
-- the current frontier, and not-yet-materialised descendants are
-- deliberately excluded: they are orchestration status, not
-- observations.  Mixing them into memory is a model leak.
--
--   * 'SettledOnly' — @NodeCompleted@ / @NodeSkipped@ / @NodeRewritten@.
--     __The only scope domain code should use.__
--
--   * 'DebugAllStatuses' — include every status (origin still
--     excluded).  __Not a semantic read surface.__  Reserved for
--     operator / admin inspection of the substrate: run-detail
--     traces, graph dumps, rewrite provenance views.  Use a
--     dedicated execution-status surface — not memory — if a domain
--     stage needs to know that a sibling is running or blocked on a
--     signal.
--
-- Note that nodes without outputs still drop at scoring time even
-- under 'DebugAllStatuses', because scoring requires a materialised
-- payload.  So widening the scope never surfaces live-only nodes as
-- memory matches; it only widens the nodes that get scored at all.
data WalkScope
  = SettledOnly
  | DebugAllStatuses
  deriving stock (Eq, Show, Generic)

-- | Weights for the composite score.
--
-- The three axes correspond to @graph_influence@, @temporal_distance@,
-- and @semantic@ in the paper draft
-- @paper-drafts2/topological-memory-as-query.md@.  Higher weight ⇒ axis
-- contributes more to the final ranking.  Weights do not need to sum
-- to one — 'clamp01' is applied per-axis in 'Cortex.Pulse.Memory.Score'.
--
-- 'swMaxGraphDistance' is a hard cutoff applied before scoring: nodes
-- beyond that many hops are dropped even if their other scores are
-- excellent.  'Nothing' means no cutoff.  This is a pure pre-filter —
-- scoring itself uses random-walk influence, not hop count.
data ScoreWeights = ScoreWeights
  { swGraphDistance :: !Double,
    swTemporalDistance :: !Double,
    swSemantic :: !Double,
    swMaxGraphDistance :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

-- | Balanced default: each axis weighted equally, no cutoff.  Domain
-- consumers (analyst / reviewer walk specs) will override with their
-- own weightings.
defaultScoreWeights :: ScoreWeights
defaultScoreWeights =
  ScoreWeights
    { swGraphDistance = 1.0,
      swTemporalDistance = 1.0,
      swSemantic = 1.0,
      swMaxGraphDistance = Nothing
    }

-- | Full walk specification: direction, status filter, scoring weights,
-- and an optional top-N limit applied after sort.
data WalkSpec = WalkSpec
  { wsDirection :: !WalkDirection,
    wsScope :: !WalkScope,
    wsWeights :: !ScoreWeights,
    wsLimit :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

-- | Reverse-BFS ancestors, settled nodes only, balanced weights, no
-- cutoff or limit.  The most conservative default — read every settled
-- upstream node.
defaultWalkSpec :: WalkSpec
defaultWalkSpec =
  WalkSpec
    { wsDirection = Ancestors,
      wsScope = SettledOnly,
      wsWeights = defaultScoreWeights,
      wsLimit = Nothing
    }

-- ----------------------------------------------------------------------------
-- Per-stage walk-spec presets
-- ----------------------------------------------------------------------------
--
-- These are reusable 'WalkSpec' shapes for the common Pulse stage
-- roles, defined so domain code (e.g. @Portman.Task.DeepReportWorkflow@)
-- doesn't encode the walk geometry inline.  Tune weights at the call
-- site if a stage wants semantic or temporal weighting; the default
-- axis weights stay balanced (1.0/1.0/1.0).

-- | Analyst stages look at their causal cone: reverse-BFS ancestors,
-- settled nodes only.  Matches 'defaultWalkSpec' — an analyst is the
-- canonical consumer shape.
analystWalkSpec :: WalkSpec
analystWalkSpec = defaultWalkSpec

-- | Reviewer stages read every settled ancestor by the time they
-- enter.  Because the memory view is pinned at the reviewer's stage
-- entry ('Cortex.Pulse.Memory.newMemoryHandle' binds a snapshot at
-- construction), reviewer siblings that are still running or waiting
-- at that moment are not visible — /no same-frontier bleed/.  Once a
-- sibling settles and a later stage starts, the next stage's entry
-- snapshot includes it.  Direction stays 'Ancestors'.  Graph weight
-- is raised slightly so highly-connected observations rank ahead of
-- peripheral ancestors when scores tie.
reviewerWalkSpec :: WalkSpec
reviewerWalkSpec =
  WalkSpec
    { wsDirection = Ancestors,
      wsScope = SettledOnly,
      wsWeights =
        ScoreWeights
          { swGraphDistance = 1.5,
            swTemporalDistance = 1.0,
            swSemantic = 1.0,
            swMaxGraphDistance = Nothing
          },
      wsLimit = Nothing
    }

-- | Planner / meta-stage preset: bidirectional walk (the planner may
-- look at both the causal cone it's planning against and the
-- downstream stages it's shaping), settled nodes only, temporal
-- weighting emphasised so recently-settled state dominates stale
-- history.
plannerWalkSpec :: WalkSpec
plannerWalkSpec =
  WalkSpec
    { wsDirection = Bidirectional,
      wsScope = SettledOnly,
      wsWeights =
        ScoreWeights
          { swGraphDistance = 1.0,
            swTemporalDistance = 1.5,
            swSemantic = 1.0,
            swMaxGraphDistance = Nothing
          },
      wsLimit = Nothing
    }

-- ============================================================================
-- Queries, extractors, and semantic scoring
-- ============================================================================

-- | Fields pulled out of a stage output JSONB by a domain-specific
-- extractor.  These are the fields the scoring and rendering layers
-- actually look at.
--
--   * 'efRoutingKey' — the "claim ref" / logical topic the output is
--     about.  Used to filter by 'qRoutingKey'.  'Nothing' if the output
--     has no declared routing key.
--   * 'efBodyText' — the primary textual body the semantic scorer runs
--     against.
--   * 'efEvidence' — tool-call IDs or other evidence refs carried by
--     the output.  Surfaced in the match record for downstream
--     rendering.
data ExtractedFields = ExtractedFields
  { efRoutingKey :: !(Maybe Text),
    efBodyText :: !Text,
    efEvidence :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | Pluggable semantic scorer.  Input: query text and candidate body;
-- output: score in @[0, 1]@ (caller guarantees @clamp01@).
--
-- The shipped default is token-jaccard (see
-- 'Cortex.Pulse.Memory.Score.defaultSemanticScorer').  pgvector /
-- reranker implementations slot in by constructing a different
-- 'SemanticScorer' and threading it through the handle.
type SemanticScorer = Text -> Text -> Double

-- | A query against the topological memory.
--
--   * 'qRoutingKey' — exact-match filter on 'efRoutingKey'.  'Nothing'
--     matches any routing key.
--   * 'qSemanticText' — free-text scored by the 'qSemanticScorer'.
--     'Nothing' skips the semantic axis (contributes zero).
--   * 'qExtractor' — domain-specific decoder pulling 'ExtractedFields'
--     out of a stage output JSONB.  Analogous to
--     @analystOutputsFromInputs@.  'Nothing' means the match is
--     structural-only (a node matches iff its status matches the walk
--     scope); no body text, no routing-key filter.
--   * 'qSemanticScorer' — the scorer used when 'qSemanticText' is set.
--
-- A 'Query' is pure data and fully serialisable except for
-- 'qExtractor' and 'qSemanticScorer'.  Domain modules construct
-- Query values at call sites.
data Query = Query
  { qRoutingKey :: !(Maybe Text),
    qSemanticText :: !(Maybe Text),
    qExtractor :: !(Aeson.Value -> Maybe ExtractedFields),
    qSemanticScorer :: !SemanticScorer
  }

-- | Empty query: no filters, no semantic text, no extractor.  Matches
-- every node within the walk's scope but carries no extracted body or
-- routing key — callers that want rendered drafts must provide an
-- extractor.  Uses 'defaultSemanticScorer' as a harmless default since
-- no semantic text is set.
emptyQuery :: Query
emptyQuery =
  Query
    { qRoutingKey = Nothing,
      qSemanticText = Nothing,
      qExtractor = const Nothing,
      qSemanticScorer = nullSemanticScorer
    }

-- | Constant-zero scorer.  Harmless default that contributes nothing
-- to the semantic axis — safe to place in an empty query that has no
-- semantic text anyway.  The production default is
-- 'Cortex.Pulse.Memory.Score.defaultSemanticScorer'
-- (token-jaccard); callers explicitly wire that in at query
-- construction time.
nullSemanticScorer :: SemanticScorer
nullSemanticScorer _ _ = 0

-- ============================================================================
-- Snapshots
-- ============================================================================

-- | Immutable snapshot of the run substrate a memory query reads from.
--
-- A snapshot is materialised by 'Cortex.Pulse.Memory.newMemoryHandle'
-- reading the executor's @gsVar :: TVar PersistedGraphState@ plus the
-- companion @nodeCompletedAt@ map once at stage entry.  The query
-- function is a pure fold over this value.
--
-- Determinism property: two calls to 'Cortex.Pulse.Memory.queryMemory'
-- against the same 'MemorySnapshot' (equal by 'Eq') with the same
-- 'WalkSpec' and 'Query' produce equal results.
data MemorySnapshot = MemorySnapshot
  { msTopology :: !(Relation NodeId),
    msNodeStatuses :: !(Map NodeId NodeStatus),
    msNodeOutputs :: !(Map NodeId Aeson.Value),
    msNodeCompletedAt :: !(Map NodeId UTCTime),
    msCapturedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | Empty snapshot — useful for tests and for stages that do not have
-- an executor-backed handle.
emptyMemorySnapshot :: UTCTime -> Relation NodeId -> MemorySnapshot
emptyMemorySnapshot now topology =
  MemorySnapshot
    { msTopology = topology,
      msNodeStatuses = Map.empty,
      msNodeOutputs = Map.empty,
      msNodeCompletedAt = Map.empty,
      msCapturedAt = now
    }

-- ============================================================================
-- Match result
-- ============================================================================

-- | A single node surfaced by a memory query.
--
-- Sorted by 'moScore' descending.  Ties are broken by ascending
-- 'moGraphDistance' (closer first) then ascending 'NodeId' for
-- deterministic ordering.
data MatchedObservation = MatchedObservation
  { moNodeId :: !NodeId,
    moStatus :: !NodeStatus,
    moOutput :: !Aeson.Value,
    moExtracted :: !(Maybe ExtractedFields),
    moScore :: !Double,
    moGraphDistance :: !Int,
    moTemporalDelta :: !(Maybe NominalDiffTime),
    moObservedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

-- ============================================================================
-- Handle
-- ============================================================================

-- | IO handle exposed to stages via 'StageContext.scMemory'.
--
-- __Stage-entry binding.__  The handle wraps a single
-- 'MemorySnapshot' captured at stage entry.  'memorySnapshot' returns
-- that bound value every time; 'queryMemory' runs 'pureQueryMemory'
-- against it.  Multiple reads from the same stage see the same graph
-- state, statuses, outputs, and completion timestamps — no
-- frontier-sibling bleed partway through the stage.  A stage that
-- needs the very latest state should run to completion, persist, and
-- let the next stage pick it up at its own entry.
--
-- The handle is cheap to construct: one STM transaction over the
-- three executor TVars plus a 'getCurrentTime'.  The executor builds
-- a fresh one per stage attempt via 'StageEnv.seMemoryFactory'.  See
-- 'Cortex.Pulse.Memory' for constructors.
data MemoryHandle = MemoryHandle
  { memorySnapshot :: IO MemorySnapshot,
    queryMemory :: NodeId -> WalkSpec -> Query -> IO [MatchedObservation]
  }

-- ============================================================================
-- Memory strategy (per-stage selectable memory surface)
-- ============================================================================

-- | Symbolic name of a shipped 'WalkSpec' preset, so wire authors can
-- pick one by name instead of spelling out every field.  @Custom@
-- keeps the escape hatch for code-level construction.
data WalkSpecPreset
  = PresetAnalyst
  | PresetReviewer
  | PresetPlanner
  | PresetDefault
  deriving stock (Eq, Show, Generic)

walkSpecPresetToText :: WalkSpecPreset -> Text
walkSpecPresetToText = \case
  PresetAnalyst -> "analyst"
  PresetReviewer -> "reviewer"
  PresetPlanner -> "planner"
  PresetDefault -> "default"

walkSpecPresetFromText :: Text -> Either Text WalkSpecPreset
walkSpecPresetFromText = \case
  "analyst" -> Right PresetAnalyst
  "reviewer" -> Right PresetReviewer
  "planner" -> Right PresetPlanner
  "default" -> Right PresetDefault
  other -> Left ("unknown walk-spec preset: " <> other)

-- | Materialise a preset into a 'WalkSpec' value.
resolveWalkSpecPreset :: WalkSpecPreset -> WalkSpec
resolveWalkSpecPreset = \case
  PresetAnalyst -> analystWalkSpec
  PresetReviewer -> reviewerWalkSpec
  PresetPlanner -> plannerWalkSpec
  PresetDefault -> defaultWalkSpec

instance Aeson.ToJSON WalkSpecPreset where
  toJSON = Aeson.String . walkSpecPresetToText

instance Aeson.FromJSON WalkSpecPreset where
  parseJSON = Aeson.withText "WalkSpecPreset" $ \t ->
    case walkSpecPresetFromText t of
      Right p -> pure p
      Left err -> AesonT.parseFail (show err)

-- | Knobs a 'MemoryTopological' strategy exposes on the wire.
data TopologicalStrategyConfig = TopologicalStrategyConfig
  { -- | Which named 'WalkSpec' preset to use as the base.
    tscPreset :: !WalkSpecPreset,
    -- | Optional exact-match routing-key filter.  'Nothing' keeps
    -- every match.
    tscRoutingKey :: !(Maybe Text),
    -- | Optional top-N override.  'Nothing' defers to the preset's
    -- own 'wsLimit'.
    tscLimit :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

defaultTopologicalConfig :: TopologicalStrategyConfig
defaultTopologicalConfig =
  TopologicalStrategyConfig
    { tscPreset = PresetAnalyst,
      tscRoutingKey = Nothing,
      tscLimit = Nothing
    }

instance Aeson.ToJSON TopologicalStrategyConfig where
  toJSON cfg =
    Aeson.object
      [ "preset" Aeson..= cfg.tscPreset,
        "routingKey" Aeson..= cfg.tscRoutingKey,
        "limit" Aeson..= cfg.tscLimit
      ]

instance Aeson.FromJSON TopologicalStrategyConfig where
  parseJSON = Aeson.withObject "TopologicalStrategyConfig" $ \obj ->
    TopologicalStrategyConfig
      <$> obj Aeson..:? "preset" Aeson..!= PresetAnalyst
      <*> obj Aeson..:? "routingKey"
      <*> obj Aeson..:? "limit"

-- | Per-stage memory read surface.
--
--   * 'MemoryClassic' — chain-scoped @scInputs@ only.  The historical
--     Pulse default: a stage sees exactly what the executor hands it
--     from direct parents.  Local causality by construction; the
--     wire itself is the information-architecture surface.  No walk,
--     no query, cheapest possible.
--
--   * 'MemoryTopological' — DIG-529 graph-native query at stage entry,
--     scored and filtered per the config.  Broadcasts reads across
--     the settled substrate; useful when the wire's upstream bundle
--     doesn't already include every observation the stage needs.
--
-- New strategies ('MemoryRetrieval', 'MemoryHybrid', …) slot in here
-- without changing the surface shape.
data MemoryStrategy
  = MemoryClassic
  | MemoryTopological !TopologicalStrategyConfig
  deriving stock (Eq, Show, Generic)

defaultMemoryStrategy :: MemoryStrategy
defaultMemoryStrategy = MemoryClassic

-- JSON encoding uses a tagged object so future variants extend
-- without breaking persisted wires.  Shape:
--   { "tag": "classic" }
--   { "tag": "topological", "config": { "preset": "analyst", ... } }
instance Aeson.ToJSON MemoryStrategy where
  toJSON MemoryClassic = Aeson.object ["tag" Aeson..= ("classic" :: Text)]
  toJSON (MemoryTopological cfg) =
    Aeson.object
      [ "tag" Aeson..= ("topological" :: Text),
        "config" Aeson..= cfg
      ]

instance Aeson.FromJSON MemoryStrategy where
  parseJSON = Aeson.withObject "MemoryStrategy" $ \obj -> do
    tag <- obj Aeson..: "tag"
    case (tag :: Text) of
      "classic" -> pure MemoryClassic
      "topological" -> do
        cfg <- obj Aeson..:? "config" Aeson..!= defaultTopologicalConfig
        pure (MemoryTopological cfg)
      other -> AesonT.parseFail ("unknown memory strategy tag: " <> show other)
