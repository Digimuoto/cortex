{- |
Module      : Logos.Memory.Conflict
Description : Logos reasoning-library support for conflict.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Conflict
  ( resolveMemoryConflicts
  )
where

import Control.Applicative ((<|>))
import Data.List (sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryEntityConfig (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  , LogosMemoryRetrievalSource (..)
  )

resolveMemoryConflicts
  :: LogosMemoryEntityConfig -> [LogosMemoryRankedPassage] -> [LogosMemoryRankedPassage]
resolveMemoryConflicts entityConfig =
  suppressConflicts entityConfig
    . annotateSurvivors entityConfig
    . dedupeByVersionAndSection

dedupeByVersionAndSection :: [LogosMemoryRankedPassage] -> [LogosMemoryRankedPassage]
dedupeByVersionAndSection rows =
  reverse . snd $
    foldl step (Set.empty, []) sortedRows
  where
    sortedRows =
      sortBy
        ( comparing (Down . (.logosMemorySourceUpdatedAt) . logosRankedPassage)
            <> comparing (Down . logosRankedFinalScore)
        )
        rows
    step (seen, acc) row =
      let key = dedupeKey row
       in if Set.member key seen
            then (seen, acc)
            else (Set.insert key seen, row : acc)

dedupeKey :: LogosMemoryRankedPassage -> (Maybe UUID, Maybe UUID, UUID, Text)
dedupeKey row =
  ( row.logosRankedPassage.logosMemorySourceItemId
  , row.logosRankedPassage.logosMemorySourceCheckpointId
  , row.logosRankedPassage.logosMemorySourceVersionId
  , normalizeHeadingKey row.logosRankedPassage
  )

suppressConflicts
  :: LogosMemoryEntityConfig -> [LogosMemoryRankedPassage] -> [LogosMemoryRankedPassage]
suppressConflicts entityConfig rows =
  filter (\row -> row.logosRankedPassage.logosMemoryPassageId `Set.notMember` suppressedIds) rows
  where
    suppressedIds =
      Set.fromList
        [ loser.logosRankedPassage.logosMemoryPassageId
        | groupRows <- Map.elems grouped
        , winner : losers <- [sortConflictGroup groupRows]
        , hasOpposingStances entityConfig (winner : losers)
        , loser <- losers
        ]
    grouped =
      Map.fromListWith
        (<>)
        [ (key, [row])
        | row <- rows
        , Just key <- [conflictKey row]
        ]

annotateSurvivors
  :: LogosMemoryEntityConfig -> [LogosMemoryRankedPassage] -> [LogosMemoryRankedPassage]
annotateSurvivors entityConfig rows =
  fmap annotate rows
  where
    grouped =
      Map.fromListWith
        (<>)
        [ (key, [row])
        | row <- rows
        , Just key <- [conflictKey row]
        ]
    conflictNotes =
      Map.fromList $
        concatMap noteForGroup (Map.elems grouped)
    annotate row =
      row
        { logosRankedConflictNote =
            logosRankedConflictNote row
              <|> Map.lookup row.logosRankedPassage.logosMemoryPassageId conflictNotes
        }
    noteForGroup groupRows =
      case sortConflictGroup groupRows of
        winner : losers
          | hasOpposingStances entityConfig (winner : losers) ->
              [(winner.logosRankedPassage.logosMemoryPassageId, conflictNote)]
        _ -> []
    conflictNote =
      "A newer or explicitly targeted passage superseded an older conflicting memory passage. Re-verify any recommendation before relying on it."

sortConflictGroup :: [LogosMemoryRankedPassage] -> [LogosMemoryRankedPassage]
sortConflictGroup =
  sortBy
    ( comparing (Down . hasDirectTargetSource)
        <> comparing (Down . (.logosMemorySourceUpdatedAt) . logosRankedPassage)
        <> comparing (Down . logosRankedFinalScore)
    )
  where
    hasDirectTargetSource row =
      let candidate = row.logosRankedCandidate
       in LogosMemoryRetrievedFromDirectTarget `elem` candidate.logosCandidateSources

conflictKey :: LogosMemoryRankedPassage -> Maybe (UUID, Text, Text)
conflictKey row = do
  itemId <- row.logosRankedPassage.logosMemorySourceItemId
  primaryEntity <- listToMaybe row.logosRankedPassage.logosMemoryEntities
  let headingKey = normalizeHeadingKey row.logosRankedPassage
  if T.null headingKey then Nothing else Just (itemId, primaryEntity, headingKey)

normalizeHeadingKey :: LogosMemoryPassage -> Text
normalizeHeadingKey passage =
  normalizeWhitespaceLower
    (fromMaybe passage.logosMemorySourceTitle passage.logosMemorySectionHeading)

hasOpposingStances :: LogosMemoryEntityConfig -> [LogosMemoryRankedPassage] -> Bool
hasOpposingStances entityConfig rows
  | null (logosMemoryPositiveStanceTerms entityConfig) = False
  | null (logosMemoryNegativeStanceTerms entityConfig) = False
  | otherwise =
      let stances = mapMaybe (detectConflictStance entityConfig) rows
       in ConflictPositive `elem` stances && ConflictNegative `elem` stances

data ConflictStance = ConflictPositive | ConflictNegative
  deriving stock (Eq, Show)

detectConflictStance
  :: LogosMemoryEntityConfig -> LogosMemoryRankedPassage -> Maybe ConflictStance
detectConflictStance entityConfig row =
  let haystack =
        normalizeWhitespaceLower
          ( row.logosRankedPassage.logosMemorySourceTitle
              <> " "
              <> row.logosRankedPassage.logosMemoryPassageText
          )
   in if any (`T.isInfixOf` haystack) (logosMemoryPositiveStanceTerms entityConfig)
        then Just ConflictPositive
        else
          if any (`T.isInfixOf` haystack) (logosMemoryNegativeStanceTerms entityConfig)
            then Just ConflictNegative
            else Nothing

normalizeWhitespaceLower :: Text -> Text
normalizeWhitespaceLower =
  T.unwords . T.words . T.toLower
