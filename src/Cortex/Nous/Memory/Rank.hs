{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cortex.Nous.Memory.Rank
  ( CortexMemoryRankWeights (..)
  , defaultCortexMemoryRankWeights
  , loadCortexMemoryRankWeights
  , rankMemoryCandidates
  )
where

import Control.Exception (IOException, try)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Data.Yaml qualified as Yaml
import Paths_cortex qualified

import Cortex.Nous.Memory.Query
  ( CortexMemoryQuery (..)
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..)
  , CortexMemoryMatchedField (..)
  , CortexMemoryPassage (..)
  , CortexMemoryRankedPassage (..)
  , CortexMemoryRetrievalSource (..)
  )

data CortexMemoryRankWeights = CortexMemoryRankWeights
  { cmrwLexical :: Double
  , cmrwSemantic :: Double
  , cmrwFuzzy :: Double
  , cmrwDirectTarget :: Double
  , cmrwAnchored :: Double
  , cmrwSessionLocal :: Double
  , cmrwEntityMatch :: Double
  , cmrwTitleHeadingMatch :: Double
  , cmrwRecency :: Double
  , cmrwSourcePrior :: Double
  }
  deriving stock (Eq, Show)

defaultCortexMemoryRankWeights :: CortexMemoryRankWeights
defaultCortexMemoryRankWeights =
  CortexMemoryRankWeights
    { cmrwLexical = 0.22
    , cmrwSemantic = 0.22
    , cmrwFuzzy = 0.11
    , cmrwDirectTarget = 0.14
    , cmrwAnchored = 0.10
    , cmrwSessionLocal = 0.08
    , cmrwEntityMatch = 0.06
    , cmrwTitleHeadingMatch = 0.04
    , cmrwRecency = 0.03
    , cmrwSourcePrior = 0.03
    }

loadCortexMemoryRankWeights :: IO (Either Text CortexMemoryRankWeights)
loadCortexMemoryRankWeights = do
  pathResult <- try (Paths_cortex.getDataFileName "config/cortex/memory-ranking.yaml")
  case pathResult of
    Left (err :: IOException) ->
      pure (Left ("Failed to resolve memory ranking config path: " <> T.pack (show err)))
    Right absolutePath -> do
      decoded <- Yaml.decodeFileEither absolutePath
      pure $
        case decoded of
          Left err ->
            Left
              ( "Failed to parse memory ranking config "
                  <> T.pack absolutePath
                  <> ": "
                  <> T.pack (Yaml.prettyPrintParseException err)
              )
          Right weights -> Right weights

rankMemoryCandidates
  :: UTCTime
  -> Map Text Double
  -> Double
  -> CortexMemoryRankWeights
  -> CortexMemoryQuery
  -> [CortexMemoryCandidate]
  -> [CortexMemoryRankedPassage]
rankMemoryCandidates now sourcePriorWeights sourcePriorDefault weights query =
  sortBy
    ( comparing (Down . cortexRankedFinalScore)
        <> comparing (Down . (.cortexMemorySourceUpdatedAt) . cortexRankedPassage)
    )
    . fmap rankOne
  where
    rankOne candidate =
      CortexMemoryRankedPassage
        { cortexRankedPassage = passage
        , cortexRankedCandidate = candidate
        , cortexRankedFinalScore = finalScore
        , cortexRankedConflictNote = Nothing
        }
      where
        passage = candidate.cortexCandidatePassage
        -- ts_rank_cd typically returns values in [0, ~0.1]; multiply by 4 to
        -- spread the range into [0, ~0.4] before clamping so the lexical
        -- weight has meaningful dynamic range relative to other features.
        finalScore =
          cmrwLexical weights * clamp01 (maybe 0 (* 4) candidate.cortexCandidateLexicalScore)
            + cmrwSemantic weights * clamp01 (fromMaybe 0 candidate.cortexCandidateSemanticScore)
            + cmrwFuzzy weights * clamp01 (fromMaybe 0 candidate.cortexCandidateFuzzyScore)
            + cmrwDirectTarget weights * sourceFeature CortexMemoryRetrievedFromDirectTarget candidate
            + cmrwAnchored weights * sourceFeature CortexMemoryRetrievedFromAnchored candidate
            + cmrwSessionLocal weights * sourceFeature CortexMemoryRetrievedFromSessionLocal candidate
            + cmrwEntityMatch weights * entityFeature query candidate
            + cmrwTitleHeadingMatch weights * titleHeadingFeature candidate
            + cmrwRecency weights * recencyFeature now query passage
            + cmrwSourcePrior weights * sourcePriorFeature sourcePriorWeights sourcePriorDefault passage

sourceFeature :: CortexMemoryRetrievalSource -> CortexMemoryCandidate -> Double
sourceFeature source candidate =
  if source `elem` candidate.cortexCandidateSources then 1 else 0

entityFeature :: CortexMemoryQuery -> CortexMemoryCandidate -> Double
entityFeature query candidate
  | null query.cortexMemoryQueryEntities = 0
  | any (`elem` candidate.cortexCandidatePassage.cortexMemoryEntities) query.cortexMemoryQueryEntities =
      1
  | CortexMemoryMatchedEntity `elem` candidate.cortexCandidateMatchedFields = 1
  | otherwise = 0

titleHeadingFeature :: CortexMemoryCandidate -> Double
titleHeadingFeature candidate
  | any
      (`elem` candidate.cortexCandidateMatchedFields)
      [CortexMemoryMatchedTitle, CortexMemoryMatchedHeading] =
      1
  | otherwise = 0

recencyFeature :: UTCTime -> CortexMemoryQuery -> CortexMemoryPassage -> Double
recencyFeature now query passage =
  -- Floor of 0.2 prevents very old passages from scoring zero on recency
  -- alone, which would disproportionately penalise archival reference material.
  max 0.2 (exp (negate (ageDays / recencyWindowDays)))
  where
    ageDays = realToFrac (diffUTCTime now passage.cortexMemorySourceUpdatedAt) / (86400 :: Double)
    recencyWindowDays =
      case query.cortexMemoryQueryRecencyHint of
        Just "latest" -> 14
        Just "recent" -> 14
        _ -> 30

{- | Source prior feature using app-defined weights keyed by source kind.
Source kinds not in the map get the default value.
-}
sourcePriorFeature :: Map Text Double -> Double -> CortexMemoryPassage -> Double
sourcePriorFeature priorWeights defaultPrior passage =
  Map.findWithDefault defaultPrior (T.toLower passage.cortexMemorySourceKind) priorWeights

clamp01 :: Double -> Double
clamp01 = max 0 . min 1

instance Yaml.FromJSON CortexMemoryRankWeights where
  parseJSON = Yaml.withObject "CortexMemoryRankWeights" $ \o ->
    CortexMemoryRankWeights
      <$> o Yaml..: "lexical"
      <*> o Yaml..: "semantic"
      <*> o Yaml..: "fuzzy"
      <*> o Yaml..: "directTarget"
      <*> o Yaml..: "anchored"
      <*> o Yaml..: "sessionLocal"
      <*> o Yaml..: "entityMatch"
      <*> o Yaml..: "titleHeadingMatch"
      <*> o Yaml..: "recency"
      <*> o Yaml..: "sourcePrior"
