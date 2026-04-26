{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Cortex.Memory.Types
  ( CortexMemoryEntityConfig (..),
    defaultCortexMemoryEntityConfig,
    CortexMemoryMatchedField (..),
    CortexMemoryRetrievalSource (..),
    CortexMemoryPassage (..),
    CortexMemoryCandidate (..),
    CortexMemoryRankedPassage (..),
  )
where

import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- | Configuration for domain-specific entity extraction in the memory system.
-- Downstream consumers provide entity extraction logic (e.g. stock tickers,
-- product SKUs) without Cortex knowing about specific domain types.
data CortexMemoryEntityConfig = CortexMemoryEntityConfig
  { -- | Extract domain-specific entity tags from text.
    cortexMemoryExtractEntities :: Text -> [Text],
    -- | Classify whether the raw query consists entirely of entity identifiers.
    cortexMemoryIsEntityOnlyQuery :: Text -> Bool,
    -- | Detect whether the raw query contains any intentional entity identifiers.
    -- Used to distinguish "AMD downside" (has entity intent → full pipeline)
    -- from "revenue" (no entity intent → simple lexical). This checks the raw
    -- input signal (e.g. uppercase tokens), not the extractor output which may
    -- aggressively match ordinary words.
    cortexMemoryQueryHasEntityIntent :: Text -> Bool,
    -- | Domain-specific terms indicating a positive stance (e.g. "bullish",
    -- "overweight"). Used by conflict resolution to detect opposing views
    -- between passages covering the same entity and heading.
    -- Empty list disables stance-based conflict suppression.
    cortexMemoryPositiveStanceTerms :: [Text],
    -- | Domain-specific terms indicating a negative stance (e.g. "bearish",
    -- "underweight"). Counterpart to positive stance terms.
    cortexMemoryNegativeStanceTerms :: [Text]
  }

defaultCortexMemoryEntityConfig :: CortexMemoryEntityConfig
defaultCortexMemoryEntityConfig =
  CortexMemoryEntityConfig
    { cortexMemoryExtractEntities = const [],
      cortexMemoryIsEntityOnlyQuery = const False,
      cortexMemoryQueryHasEntityIntent = const False,
      cortexMemoryPositiveStanceTerms = [],
      cortexMemoryNegativeStanceTerms = []
    }

data CortexMemoryMatchedField
  = CortexMemoryMatchedTitle
  | CortexMemoryMatchedHeading
  | CortexMemoryMatchedBody
  | CortexMemoryMatchedEntity
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data CortexMemoryRetrievalSource
  = CortexMemoryRetrievedFromSessionLocal
  | CortexMemoryRetrievedFromAnchored
  | CortexMemoryRetrievedFromLexical
  | CortexMemoryRetrievedFromFuzzy
  | CortexMemoryRetrievedFromSemantic
  | CortexMemoryRetrievedFromDirectTarget
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data CortexMemoryPassage = CortexMemoryPassage
  { cortexMemoryPassageId :: UUID,
    cortexMemorySourceKind :: Text,
    cortexMemorySourceItemId :: Maybe UUID,
    cortexMemorySourceCheckpointId :: Maybe UUID,
    cortexMemorySourceVersionId :: UUID,
    cortexMemoryChatSessionId :: Maybe UUID,
    cortexMemoryPassageOrder :: Int,
    cortexMemorySourceTitle :: Text,
    cortexMemorySectionHeading :: Maybe Text,
    cortexMemoryPassageText :: Text,
    cortexMemoryEntities :: [Text],
    cortexMemoryReportType :: Maybe Text,
    cortexMemoryTimeRange :: Maybe Text,
    cortexMemoryPassageTokenCount :: Int,
    cortexMemorySourceCreatedAt :: UTCTime,
    cortexMemorySourceUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

data CortexMemoryCandidate = CortexMemoryCandidate
  { cortexCandidatePassage :: CortexMemoryPassage,
    cortexCandidateLexicalScore :: Maybe Double,
    cortexCandidateFuzzyScore :: Maybe Double,
    cortexCandidateSemanticScore :: Maybe Double,
    cortexCandidateMatchedTerms :: [Text],
    cortexCandidateMatchedFields :: [CortexMemoryMatchedField],
    cortexCandidateSources :: [CortexMemoryRetrievalSource],
    cortexCandidateFusionScore :: Double
  }
  deriving stock (Eq, Show, Generic)

data CortexMemoryRankedPassage = CortexMemoryRankedPassage
  { cortexRankedPassage :: CortexMemoryPassage,
    cortexRankedCandidate :: CortexMemoryCandidate,
    cortexRankedFinalScore :: Double,
    cortexRankedConflictNote :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
