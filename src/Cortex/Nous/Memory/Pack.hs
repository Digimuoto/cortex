{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Nous.Memory.Pack
  ( selectByTokenBudget
  , packSessionPassages
  , packReferencePassages

    -- * MMR internals (exported for testing)
  , passageFeatures
  , jaccardSimilarity
  )
where

import Data.Int (Int64)
import Data.List (sortBy)
import Data.Maybe (maybeToList)
import Data.Ord (Down (..), comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Nous.Memory.Types
  ( CortexMemoryPassage (..)
  , CortexMemoryRankedPassage (..)
  )

selectByTokenBudget
  :: Int64
  -> Int
  -> [a]
  -> (a -> Int)
  -> [a]
selectByTokenBudget tokenBudget maxCount rows rowTokens =
  reverse (fst (foldl step ([], 0 :: Int64) (take maxCount rows)))
  where
    step (selected, usedTokens) row =
      let nextRowTokens = fromIntegral (max 1 (rowTokens row))
          nextTokens = usedTokens + nextRowTokens
       in if not (null selected) && nextTokens > tokenBudget
            then (selected, usedTokens)
            else (row : selected, min tokenBudget nextTokens)

packSessionPassages
  :: Int64
  -> Int
  -> [CortexMemoryPassage]
  -> [CortexMemoryPassage]
packSessionPassages tokenBudget maxCount rows =
  selectByTokenBudget
    tokenBudget
    maxCount
    (sortedRows rows)
    (\row -> row.cortexMemoryPassageTokenCount)
  where
    sortedRows =
      sortBy
        ( comparing (Down . (\row -> row.cortexMemorySourceUpdatedAt))
            <> comparing (Down . (\row -> row.cortexMemoryPassageOrder))
        )

{- | Pack reference passages using MMR (Maximal Marginal Relevance) to balance
relevance with diversity. For each selection step, picks the passage that
maximizes: lambda * relevance - (1 - lambda) * max_similarity_to_selected.

Falls back to greedy-by-score for < 3 candidates (MMR overhead not worth it).
Similarity is Jaccard on passage feature sets (entities, heading, title terms)
since embedding vectors are not available at packing time.
-}
packReferencePassages
  :: Int64
  -> Int
  -> [CortexMemoryRankedPassage]
  -> [CortexMemoryRankedPassage]
packReferencePassages tokenBudget maxCount rows
  | length rows < 3 = greedyPack rows
  | otherwise = selectByMMR mmrLambda tokenBudget maxCount (sortedRows rows)
  where
    greedyPack rs =
      selectByTokenBudget
        tokenBudget
        maxCount
        (sortedRows rs)
        (\row -> row.cortexRankedPassage.cortexMemoryPassageTokenCount)
    sortedRows =
      sortBy
        ( comparing (Down . cortexRankedFinalScore)
            <> comparing (Down . (\row -> row.cortexRankedPassage.cortexMemorySourceUpdatedAt))
        )

{- | MMR lambda: 0.7 = relevance-dominant. Standard default from Carbonell &
Goldstein (1998). Higher values favor relevance over diversity.
-}
mmrLambda :: Double
mmrLambda = 0.7

{- | Extract feature set from a passage for Jaccard diversity computation.
Uses entities, section heading, and title terms as proxy for content overlap.
-}
passageFeatures :: CortexMemoryRankedPassage -> Set Text
passageFeatures row =
  Set.fromList $
    fmap T.toLower row.cortexRankedPassage.cortexMemoryEntities
      <> maybeToList (T.toLower <$> row.cortexRankedPassage.cortexMemorySectionHeading)
      <> T.words (T.toLower row.cortexRankedPassage.cortexMemorySourceTitle)

-- | Jaccard similarity between two feature sets. Returns 1.0 if both empty.
jaccardSimilarity :: Set Text -> Set Text -> Double
jaccardSimilarity a b
  | Set.null a && Set.null b = 1.0
  | otherwise =
      fromIntegral (Set.size (Set.intersection a b))
        / fromIntegral (Set.size (Set.union a b))

{- | MMR selection: iteratively pick the passage that maximizes
lambda * normalizedRelevance - (1 - lambda) * maxSimilarityToSelected.
Respects token budget and max count constraints.
-}
selectByMMR
  :: Double
  -> Int64
  -> Int
  -> [CortexMemoryRankedPassage]
  -> [CortexMemoryRankedPassage]
selectByMMR lambda tokenBudget maxCount candidates =
  reverse (go [] [] 0 0 candidatesWithFeatures)
  where
    candidatesWithFeatures = fmap (\c -> (c, passageFeatures c)) candidates
    maxScore = case candidates of
      (top : _) -> max 1e-9 (cortexRankedFinalScore top)
      [] -> 1.0

    go selected _ _ _ [] = selected
    go selected selFeatures count usedTokens remaining@(first : rest)
      | count >= maxCount = selected
      | otherwise =
          let (best, bestFeatures) =
                fst $
                  foldl'
                    ( \(bestSoFar, bestScore) (candidate, features) ->
                        let relevance = cortexRankedFinalScore candidate / maxScore
                            maxSim = case selFeatures of
                              [] -> 0.0
                              sfs -> maximum (fmap (jaccardSimilarity features) sfs)
                            mmrScore = lambda * relevance - (1.0 - lambda) * maxSim
                         in if mmrScore > bestScore
                              then ((candidate, features), mmrScore)
                              else (bestSoFar, bestScore)
                    )
                    (first, -1e9)
                    (first : rest)
              tokens = fromIntegral (max 1 best.cortexRankedPassage.cortexMemoryPassageTokenCount)
              newTokens = usedTokens + tokens
              remaining' = filter (\(c, _) -> c /= best) remaining
           in if not (null selected) && newTokens > tokenBudget
                then -- Skip this oversized candidate and try the next best fit
                  go selected selFeatures count usedTokens remaining'
                else
                  go
                    (best : selected)
                    (bestFeatures : selFeatures)
                    (count + 1)
                    (min tokenBudget newTokens)
                    remaining'
