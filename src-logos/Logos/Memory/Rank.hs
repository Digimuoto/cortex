{- |
Module      : Logos.Memory.Rank
Description : Logos reasoning-library support for rank.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Rank
  ( LogosMemoryRankWeights (..)
  , defaultLogosMemoryRankWeights
  , loadLogosMemoryRankWeights
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
import Logos.Memory.Query
  ( LogosMemoryQuery (..)
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryMatchedField (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  , LogosMemoryRetrievalSource (..)
  )
import Paths_cortex qualified

data LogosMemoryRankWeights = LogosMemoryRankWeights
  { logosMemoryRankWeightLexical :: Double
  , logosMemoryRankWeightSemantic :: Double
  , logosMemoryRankWeightFuzzy :: Double
  , logosMemoryRankWeightDirectTarget :: Double
  , logosMemoryRankWeightAnchored :: Double
  , logosMemoryRankWeightSessionLocal :: Double
  , logosMemoryRankWeightEntityMatch :: Double
  , logosMemoryRankWeightTitleHeadingMatch :: Double
  , logosMemoryRankWeightRecency :: Double
  , logosMemoryRankWeightSourcePrior :: Double
  }
  deriving stock (Eq, Show)

defaultLogosMemoryRankWeights :: LogosMemoryRankWeights
defaultLogosMemoryRankWeights =
  LogosMemoryRankWeights
    { logosMemoryRankWeightLexical = 0.22
    , logosMemoryRankWeightSemantic = 0.22
    , logosMemoryRankWeightFuzzy = 0.11
    , logosMemoryRankWeightDirectTarget = 0.14
    , logosMemoryRankWeightAnchored = 0.10
    , logosMemoryRankWeightSessionLocal = 0.08
    , logosMemoryRankWeightEntityMatch = 0.06
    , logosMemoryRankWeightTitleHeadingMatch = 0.04
    , logosMemoryRankWeightRecency = 0.03
    , logosMemoryRankWeightSourcePrior = 0.03
    }

loadLogosMemoryRankWeights :: IO (Either Text LogosMemoryRankWeights)
loadLogosMemoryRankWeights = do
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
  -> LogosMemoryRankWeights
  -> LogosMemoryQuery
  -> [LogosMemoryCandidate]
  -> [LogosMemoryRankedPassage]
rankMemoryCandidates now sourcePriorWeights sourcePriorDefault weights query =
  sortBy
    ( comparing (Down . logosRankedFinalScore)
        <> comparing (Down . (.logosMemorySourceUpdatedAt) . logosRankedPassage)
    )
    . fmap rankOne
  where
    rankOne candidate =
      LogosMemoryRankedPassage
        { logosRankedPassage = passage
        , logosRankedCandidate = candidate
        , logosRankedFinalScore = finalScore
        , logosRankedConflictNote = Nothing
        }
      where
        passage = candidate.logosCandidatePassage
        -- ts_rank_cd typically returns values in [0, ~0.1]; multiply by 4 to
        -- spread the range into [0, ~0.4] before clamping so the lexical
        -- weight has meaningful dynamic range relative to other features.
        finalScore =
          logosMemoryRankWeightLexical weights * clamp01 (maybe 0 (* 4) candidate.logosCandidateLexicalScore)
            + logosMemoryRankWeightSemantic weights * clamp01 (fromMaybe 0 candidate.logosCandidateSemanticScore)
            + logosMemoryRankWeightFuzzy weights * clamp01 (fromMaybe 0 candidate.logosCandidateFuzzyScore)
            + logosMemoryRankWeightDirectTarget weights
              * sourceFeature LogosMemoryRetrievedFromDirectTarget candidate
            + logosMemoryRankWeightAnchored weights * sourceFeature LogosMemoryRetrievedFromAnchored candidate
            + logosMemoryRankWeightSessionLocal weights
              * sourceFeature LogosMemoryRetrievedFromSessionLocal candidate
            + logosMemoryRankWeightEntityMatch weights * entityFeature query candidate
            + logosMemoryRankWeightTitleHeadingMatch weights * titleHeadingFeature candidate
            + logosMemoryRankWeightRecency weights * recencyFeature now query passage
            + logosMemoryRankWeightSourcePrior weights
              * sourcePriorFeature sourcePriorWeights sourcePriorDefault passage

sourceFeature :: LogosMemoryRetrievalSource -> LogosMemoryCandidate -> Double
sourceFeature source candidate =
  if source `elem` candidate.logosCandidateSources then 1 else 0

entityFeature :: LogosMemoryQuery -> LogosMemoryCandidate -> Double
entityFeature query candidate
  | null query.logosMemoryQueryEntities = 0
  | any (`elem` candidate.logosCandidatePassage.logosMemoryEntities) query.logosMemoryQueryEntities =
      1
  | LogosMemoryMatchedEntity `elem` candidate.logosCandidateMatchedFields = 1
  | otherwise = 0

titleHeadingFeature :: LogosMemoryCandidate -> Double
titleHeadingFeature candidate
  | any
      (`elem` candidate.logosCandidateMatchedFields)
      [LogosMemoryMatchedTitle, LogosMemoryMatchedHeading] =
      1
  | otherwise = 0

recencyFeature :: UTCTime -> LogosMemoryQuery -> LogosMemoryPassage -> Double
recencyFeature now query passage =
  -- Floor of 0.2 prevents very old passages from scoring zero on recency
  -- alone, which would disproportionately penalise archival reference material.
  max 0.2 (exp (negate (ageDays / recencyWindowDays)))
  where
    ageDays = realToFrac (diffUTCTime now passage.logosMemorySourceUpdatedAt) / (86400 :: Double)
    recencyWindowDays =
      case query.logosMemoryQueryRecencyHint of
        Just "latest" -> 14
        Just "recent" -> 14
        _ -> 30

{- | Source prior feature using app-defined weights keyed by source kind.
Source kinds not in the map get the default value.
-}
sourcePriorFeature :: Map Text Double -> Double -> LogosMemoryPassage -> Double
sourcePriorFeature priorWeights defaultPrior passage =
  Map.findWithDefault defaultPrior (T.toLower passage.logosMemorySourceKind) priorWeights

clamp01 :: Double -> Double
clamp01 = max 0 . min 1

instance Yaml.FromJSON LogosMemoryRankWeights where
  parseJSON = Yaml.withObject "LogosMemoryRankWeights" $ \o ->
    LogosMemoryRankWeights
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
