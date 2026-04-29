{- |
Module      : Logos.Memory.Types
Description : Logos reasoning-library support for types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Types
  ( LogosMemoryEntityConfig (..)
  , defaultLogosMemoryEntityConfig
  , LogosMemoryMatchedField (..)
  , LogosMemoryRetrievalSource (..)
  , LogosMemoryPassage (..)
  , LogosMemoryCandidate (..)
  , LogosMemoryRankedPassage (..)
  )
where

import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

{- | Configuration for domain-specific entity extraction in the memory system.
Downstream consumers provide entity extraction logic (e.g. stock tickers,
product SKUs) without Cortex knowing about specific domain types.
-}
data LogosMemoryEntityConfig = LogosMemoryEntityConfig
  { logosMemoryExtractEntities :: Text -> [Text]
  -- ^ Extract domain-specific entity tags from text.
  , logosMemoryIsEntityOnlyQuery :: Text -> Bool
  -- ^ Classify whether the raw query consists entirely of entity identifiers.
  , logosMemoryQueryHasEntityIntent :: Text -> Bool
  {- ^ Detect whether the raw query contains any intentional entity identifiers.
   Used to distinguish "AMD downside" (has entity intent → full pipeline)
   from "revenue" (no entity intent → simple lexical). This checks the raw
   input signal (e.g. uppercase tokens), not the extractor output which may
   aggressively match ordinary words.
  -}
  , logosMemoryPositiveStanceTerms :: [Text]
  {- ^ Domain-specific terms indicating a positive stance (e.g. "bullish",
   "overweight"). Used by conflict resolution to detect opposing views
   between passages covering the same entity and heading.
   Empty list disables stance-based conflict suppression.
  -}
  , logosMemoryNegativeStanceTerms :: [Text]
  {- ^ Domain-specific terms indicating a negative stance (e.g. "bearish",
   "underweight"). Counterpart to positive stance terms.
  -}
  }

defaultLogosMemoryEntityConfig :: LogosMemoryEntityConfig
defaultLogosMemoryEntityConfig =
  LogosMemoryEntityConfig
    { logosMemoryExtractEntities = const []
    , logosMemoryIsEntityOnlyQuery = const False
    , logosMemoryQueryHasEntityIntent = const False
    , logosMemoryPositiveStanceTerms = []
    , logosMemoryNegativeStanceTerms = []
    }

data LogosMemoryMatchedField
  = LogosMemoryMatchedTitle
  | LogosMemoryMatchedHeading
  | LogosMemoryMatchedBody
  | LogosMemoryMatchedEntity
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data LogosMemoryRetrievalSource
  = LogosMemoryRetrievedFromSessionLocal
  | LogosMemoryRetrievedFromAnchored
  | LogosMemoryRetrievedFromLexical
  | LogosMemoryRetrievedFromFuzzy
  | LogosMemoryRetrievedFromSemantic
  | LogosMemoryRetrievedFromDirectTarget
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data LogosMemoryPassage = LogosMemoryPassage
  { logosMemoryPassageId :: UUID
  , logosMemorySourceKind :: Text
  , logosMemorySourceItemId :: Maybe UUID
  , logosMemorySourceCheckpointId :: Maybe UUID
  , logosMemorySourceVersionId :: UUID
  , logosMemoryChatSessionId :: Maybe UUID
  , logosMemoryPassageOrder :: Int
  , logosMemorySourceTitle :: Text
  , logosMemorySectionHeading :: Maybe Text
  , logosMemoryPassageText :: Text
  , logosMemoryEntities :: [Text]
  , logosMemoryReportType :: Maybe Text
  , logosMemoryTimeRange :: Maybe Text
  , logosMemoryPassageTokenCount :: Int
  , logosMemorySourceCreatedAt :: UTCTime
  , logosMemorySourceUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

data LogosMemoryCandidate = LogosMemoryCandidate
  { logosCandidatePassage :: LogosMemoryPassage
  , logosCandidateLexicalScore :: Maybe Double
  , logosCandidateFuzzyScore :: Maybe Double
  , logosCandidateSemanticScore :: Maybe Double
  , logosCandidateMatchedTerms :: [Text]
  , logosCandidateMatchedFields :: [LogosMemoryMatchedField]
  , logosCandidateSources :: [LogosMemoryRetrievalSource]
  , logosCandidateFusionScore :: Double
  }
  deriving stock (Eq, Show, Generic)

data LogosMemoryRankedPassage = LogosMemoryRankedPassage
  { logosRankedPassage :: LogosMemoryPassage
  , logosRankedCandidate :: LogosMemoryCandidate
  , logosRankedFinalScore :: Double
  , logosRankedConflictNote :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
