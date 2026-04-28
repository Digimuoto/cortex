-- | Composite scoring for memory matches (DIG-529).
--
-- Given a candidate node, its graph influence from the origin, the
-- snapshot capture time, the node's completion time, and the query's
-- semantic text + scorer, 'composeScore' produces a single
-- @[0, 1]@-clamped weighted combination of the three axes:
--
--   * graph influence (more causally connected = higher)
--   * temporal distance (newer = higher)
--   * semantic similarity (more relevant = higher)
--
-- Each axis is independently normalised into @[0, 1]@ before the
-- weighted sum; weights are applied multiplicatively and the final
-- score is clamped into @[0, 1]@ again.  Absent axes (no temporal
-- data, no semantic query) contribute zero rather than skewing the
-- score.
--
-- The shipped semantic default is a token-jaccard similarity suitable
-- for short LLM-generated bodies.  pgvector / reranker implementations
-- slot in via 'SemanticScorer' in the query.
module Cortex.Pulse.Memory.Score
  ( composeScore,
    clamp01,
    temporalDistanceScore,
    defaultSemanticScorer,
    tokenJaccard,
    tokenise,
  )
where

import Cortex.Pulse.Memory.Types
  ( ScoreWeights (..),
    SemanticScorer,
  )
import Data.Char (isAlphaNum, toLower)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)

-- ============================================================================
-- Composite
-- ============================================================================

-- | Combine the three normalised axes under the given weights.
--
-- The sum of weighted-clamped components is itself clamped, so passing
-- very large weights cannot push the score above 1.  Passing weight 0
-- on an axis drops it entirely — callers use that to configure
-- per-stage-kind walk specs (e.g. the analyst heavily weights graph
-- influence; the reviewer balances all three).
--
-- The graph-axis input is a random-walk influence value produced by
-- 'Cortex.Algebra.Graph.Influence.dagRandomWalkInfluence' — a
-- connectivity-aware signal that rewards merges over linear chains.
-- The hop count from the walk is still carried on the
-- 'Cortex.Pulse.Memory.Types.MatchedObservation' for display and for
-- the optional 'swMaxGraphDistance' pre-filter, but it does not
-- contribute to the score directly.
composeScore ::
  ScoreWeights ->
  -- | graph-axis influence value from 'dagRandomWalkInfluence' (clamped
  -- to @[0, 1]@ inside this function — callers can pass raw values)
  Double ->
  -- | snapshot capture time
  UTCTime ->
  -- | node's completion time, if any
  Maybe UTCTime ->
  -- | pluggable semantic scorer
  SemanticScorer ->
  -- | query semantic text (if any)
  Maybe Text ->
  -- | candidate body text (empty string if no extractor)
  Text ->
  Double
composeScore weights graphInfluence capturedAt completedAt scorer mQueryText bodyText =
  let graphPart = swGraphDistance weights * clamp01 graphInfluence
      temporalPart = swTemporalDistance weights * maybe 0 (temporalDistanceScore capturedAt) completedAt
      semanticPart = case mQueryText of
        Nothing -> 0
        Just qText
          | T.null bodyText -> 0
          | otherwise -> swSemantic weights * clamp01 (scorer qText bodyText)
   in clamp01 (graphPart + temporalPart + semanticPart)

-- ============================================================================
-- Individual axes
-- ============================================================================

-- | Normalise temporal distance (wall-clock) into @[0, 1]@,
-- freshest = 1.
--
-- Decay shape: @1 / (1 + age_hours)@.  An observation made at the
-- capture moment scores 1; one made an hour earlier scores 0.5; one a
-- day earlier scores ~0.04.  Tuned for wire-timescale workloads where
-- hours matter.  Negative deltas (a completion timestamp from after
-- the snapshot — impossible under normal flow but possible under
-- clock skew) clamp to 1.
temporalDistanceScore :: UTCTime -> UTCTime -> Double
temporalDistanceScore capturedAt completedAt =
  let ageSeconds = max 0 (realToFrac (diffUTCTime capturedAt completedAt) :: Double)
      ageHours = ageSeconds / 3600
   in 1 / (1 + ageHours)

-- ============================================================================
-- Semantic scoring (default)
-- ============================================================================

-- | Default scorer: token-jaccard similarity over normalised tokens.
-- Not a good retrieval mechanism in isolation, but adequate as the
-- always-available baseline while pgvector / reranker scorers are
-- integrated via the pluggable 'SemanticScorer' field.
defaultSemanticScorer :: SemanticScorer
defaultSemanticScorer = tokenJaccard

-- | Jaccard similarity over the token sets of two texts.  Tokens are
-- lowercase alphanumeric runs; punctuation and whitespace are
-- separators.
--
-- Returns 0 when either side is empty.  Always in @[0, 1]@.
tokenJaccard :: Text -> Text -> Double
tokenJaccard a b =
  let tokensA = Set.fromList (tokenise a)
      tokensB = Set.fromList (tokenise b)
      inter = Set.intersection tokensA tokensB
      union = Set.union tokensA tokensB
   in if Set.null union
        then 0
        else fromIntegral (Set.size inter) / fromIntegral (Set.size union)

-- | Split on non-alphanumeric characters, lower-case, drop empties.
tokenise :: Text -> [Text]
tokenise =
  filter (not . T.null)
    . T.split (not . isAlphaNum)
    . T.map toLower

-- ============================================================================
-- Utilities
-- ============================================================================

-- | Clamp a 'Double' into the closed interval @[0, 1]@.  @NaN@ inputs
-- are clamped to 0 so downstream comparisons are total.
clamp01 :: Double -> Double
clamp01 x
  | isNaN x = 0
  | x <= 0 = 0
  | x >= 1 = 1
  | otherwise = x
