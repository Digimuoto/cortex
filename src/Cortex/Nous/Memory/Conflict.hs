{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Memory.Conflict
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

import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..)
  , CortexMemoryEntityConfig (..)
  , CortexMemoryPassage (..)
  , CortexMemoryRankedPassage (..)
  , CortexMemoryRetrievalSource (..)
  )

resolveMemoryConflicts
  :: CortexMemoryEntityConfig -> [CortexMemoryRankedPassage] -> [CortexMemoryRankedPassage]
resolveMemoryConflicts entityConfig =
  suppressConflicts entityConfig
    . annotateSurvivors entityConfig
    . dedupeByVersionAndSection

dedupeByVersionAndSection :: [CortexMemoryRankedPassage] -> [CortexMemoryRankedPassage]
dedupeByVersionAndSection rows =
  reverse . snd $
    foldl step (Set.empty, []) sortedRows
  where
    sortedRows =
      sortBy
        ( comparing (Down . (.cortexMemorySourceUpdatedAt) . cortexRankedPassage)
            <> comparing (Down . cortexRankedFinalScore)
        )
        rows
    step (seen, acc) row =
      let key = dedupeKey row
       in if Set.member key seen
            then (seen, acc)
            else (Set.insert key seen, row : acc)

dedupeKey :: CortexMemoryRankedPassage -> (Maybe UUID, Maybe UUID, UUID, Text)
dedupeKey row =
  ( row.cortexRankedPassage.cortexMemorySourceItemId
  , row.cortexRankedPassage.cortexMemorySourceCheckpointId
  , row.cortexRankedPassage.cortexMemorySourceVersionId
  , normalizeHeadingKey row.cortexRankedPassage
  )

suppressConflicts
  :: CortexMemoryEntityConfig -> [CortexMemoryRankedPassage] -> [CortexMemoryRankedPassage]
suppressConflicts entityConfig rows =
  filter (\row -> row.cortexRankedPassage.cortexMemoryPassageId `Set.notMember` suppressedIds) rows
  where
    suppressedIds =
      Set.fromList
        [ loser.cortexRankedPassage.cortexMemoryPassageId
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
  :: CortexMemoryEntityConfig -> [CortexMemoryRankedPassage] -> [CortexMemoryRankedPassage]
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
        { cortexRankedConflictNote =
            cortexRankedConflictNote row
              <|> Map.lookup row.cortexRankedPassage.cortexMemoryPassageId conflictNotes
        }
    noteForGroup groupRows =
      case sortConflictGroup groupRows of
        winner : losers
          | hasOpposingStances entityConfig (winner : losers) ->
              [(winner.cortexRankedPassage.cortexMemoryPassageId, conflictNote)]
        _ -> []
    conflictNote =
      "A newer or explicitly targeted passage superseded an older conflicting memory passage. Re-verify any recommendation before relying on it."

sortConflictGroup :: [CortexMemoryRankedPassage] -> [CortexMemoryRankedPassage]
sortConflictGroup =
  sortBy
    ( comparing (Down . hasDirectTargetSource)
        <> comparing (Down . (.cortexMemorySourceUpdatedAt) . cortexRankedPassage)
        <> comparing (Down . cortexRankedFinalScore)
    )
  where
    hasDirectTargetSource row =
      let candidate = row.cortexRankedCandidate
       in CortexMemoryRetrievedFromDirectTarget `elem` candidate.cortexCandidateSources

conflictKey :: CortexMemoryRankedPassage -> Maybe (UUID, Text, Text)
conflictKey row = do
  itemId <- row.cortexRankedPassage.cortexMemorySourceItemId
  primaryEntity <- listToMaybe row.cortexRankedPassage.cortexMemoryEntities
  let headingKey = normalizeHeadingKey row.cortexRankedPassage
  if T.null headingKey then Nothing else Just (itemId, primaryEntity, headingKey)

normalizeHeadingKey :: CortexMemoryPassage -> Text
normalizeHeadingKey passage =
  normalizeWhitespaceLower
    (fromMaybe passage.cortexMemorySourceTitle passage.cortexMemorySectionHeading)

hasOpposingStances :: CortexMemoryEntityConfig -> [CortexMemoryRankedPassage] -> Bool
hasOpposingStances entityConfig rows
  | null (cortexMemoryPositiveStanceTerms entityConfig) = False
  | null (cortexMemoryNegativeStanceTerms entityConfig) = False
  | otherwise =
      let stances = mapMaybe (detectConflictStance entityConfig) rows
       in ConflictPositive `elem` stances && ConflictNegative `elem` stances

data ConflictStance = ConflictPositive | ConflictNegative
  deriving stock (Eq, Show)

detectConflictStance
  :: CortexMemoryEntityConfig -> CortexMemoryRankedPassage -> Maybe ConflictStance
detectConflictStance entityConfig row =
  let haystack =
        normalizeWhitespaceLower
          ( row.cortexRankedPassage.cortexMemorySourceTitle
              <> " "
              <> row.cortexRankedPassage.cortexMemoryPassageText
          )
   in if any (`T.isInfixOf` haystack) (cortexMemoryPositiveStanceTerms entityConfig)
        then Just ConflictPositive
        else
          if any (`T.isInfixOf` haystack) (cortexMemoryNegativeStanceTerms entityConfig)
            then Just ConflictNegative
            else Nothing

normalizeWhitespaceLower :: Text -> Text
normalizeWhitespaceLower =
  T.unwords . T.words . T.toLower
