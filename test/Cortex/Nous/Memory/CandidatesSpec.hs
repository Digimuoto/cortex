{- |
Module      : Cortex.Nous.Memory.CandidatesSpec
Description : Tests for Cortex.Nous.Memory.Candidates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Nous.Memory.CandidatesSpec (spec) where

import Data.Char (isAsciiUpper, isDigit)
import Data.Functor.Identity
  ( Identity (..)
  )
import Data.List (sort)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

import Cortex.Nous.Memory.Candidates
  ( CortexMemorySearchPlan (..)
  , QueryComplexity (..)
  , buildMemorySearchPlan
  , classifyQueryComplexity
  , generateMemoryCandidates
  , mergeMemoryCandidates
  )
import Cortex.Nous.Memory.Host
  ( CortexMemoryHost (..)
  )
import Cortex.Nous.Memory.Query
  ( parseMemoryQuery
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..)
  , CortexMemoryEntityConfig (..)
  , CortexMemoryMatchedField (..)
  , CortexMemoryPassage (..)
  , CortexMemoryRetrievalSource (..)
  , defaultCortexMemoryEntityConfig
  )

{- | Test entity config that mimics ticker extraction for verifying
entity-aware query routing without Cortex depending on Portman.
-}
testEntityConfig :: CortexMemoryEntityConfig
testEntityConfig =
  CortexMemoryEntityConfig
    { cortexMemoryExtractEntities =
        filter isUppercaseToken . T.words . T.strip
    , cortexMemoryIsEntityOnlyQuery = \rawText ->
        let tokens = T.words (T.strip rawText)
         in not (null tokens) && all isUppercaseToken tokens
    , cortexMemoryQueryHasEntityIntent =
        any isUppercaseToken . T.words . T.strip
    , cortexMemoryPositiveStanceTerms = []
    , cortexMemoryNegativeStanceTerms = []
    }
  where
    isUppercaseToken w =
      T.all (\c -> isAsciiUpper c || isDigit c || c == '.' || c == '-') w
        && T.length w <= 6
        && not (T.null w)

spec :: Spec
spec = do
  describe "mergeMemoryCandidates" $ do
    it "unions duplicate passage ids across strategies and preserves per-strategy scores" $ do
      let passage = mkPassage (uuidFromWord 1)
          query = parseMemoryQuery defaultCortexMemoryEntityConfig "AMD downside" [] Nothing
          merged =
            mergeMemoryCandidates
              query
              [ (baseCandidate passage)
                  { cortexCandidateLexicalScore = Just 0.8
                  , cortexCandidateMatchedTerms = ["amd"]
                  , cortexCandidateMatchedFields = [CortexMemoryMatchedTitle]
                  , cortexCandidateSources = [CortexMemoryRetrievedFromLexical]
                  }
              , (baseCandidate passage)
                  { cortexCandidateFuzzyScore = Just 0.5
                  , cortexCandidateMatchedTerms = ["downside"]
                  , cortexCandidateMatchedFields = [CortexMemoryMatchedBody]
                  , cortexCandidateSources = [CortexMemoryRetrievedFromFuzzy]
                  }
              , (baseCandidate passage)
                  { cortexCandidateSemanticScore = Just 0.7
                  , cortexCandidateSources = [CortexMemoryRetrievedFromSemantic]
                  }
              ]

      length merged `shouldBe` 1
      let candidate = case merged of (c : _) -> c; [] -> error "unexpected empty"
      candidate.cortexCandidateLexicalScore `shouldBe` Just 0.8
      candidate.cortexCandidateFuzzyScore `shouldBe` Just 0.5
      candidate.cortexCandidateSemanticScore `shouldBe` Just 0.7
      sort candidate.cortexCandidateMatchedTerms `shouldBe` ["amd", "downside"]
      sort candidate.cortexCandidateSources
        `shouldBe` sort
          [ CortexMemoryRetrievedFromLexical
          , CortexMemoryRetrievedFromFuzzy
          , CortexMemoryRetrievedFromSemantic
          ]
      candidate.cortexCandidateFusionScore
        `shouldSatisfy` \score ->
          abs (score - 3 * reciprocalRank 1) < 1.0e-12

    it "keeps reciprocal ranks local to each retrieval strategy" $ do
      let query = parseMemoryQuery defaultCortexMemoryEntityConfig "AMD downside" [] Nothing
          semanticPassage = mkPassage (uuidFromWord 300)
          lexicalCandidates =
            [ (baseCandidate (mkPassage (uuidFromWord n)))
                { cortexCandidateLexicalScore = Just (1.0 - fromIntegral (n - 100) / 100)
                , cortexCandidateSources = [CortexMemoryRetrievedFromLexical]
                }
            | n <- [100 .. 139]
            ]
          semanticCandidate =
            (baseCandidate semanticPassage)
              { cortexCandidateSemanticScore = Just 0.9
              , cortexCandidateSources = [CortexMemoryRetrievedFromSemantic]
              }
          merged = mergeMemoryCandidates query (lexicalCandidates <> [semanticCandidate])

      let candidate =
            case filter
              ((== semanticPassage.cortexMemoryPassageId) . (.cortexMemoryPassageId) . cortexCandidatePassage)
              merged of
              (c : _) -> c
              [] -> error "semantic candidate missing"
      candidate.cortexCandidateFusionScore
        `shouldSatisfy` \score ->
          abs (score - reciprocalRank 1) < 1.0e-12

  describe "generateMemoryCandidates" $ do
    it "does not truncate search candidates before downstream ranking" $ do
      let targetItemId = uuidFromWord 400
          linkedItemIds = fmap uuidFromWord [401 .. 408]
          query = parseMemoryQuery defaultCortexMemoryEntityConfig "AMD downside" linkedItemIds (Just targetItemId)
          plan =
            buildMemorySearchPlan
              defaultCortexMemoryEntityConfig
              query
              Nothing
              (targetItemId : linkedItemIds)
              60
          sessionPassages =
            [ mkPassageForItem (uuidFromWord n) Nothing fixedTime
            | n <- [500 .. 511]
            ]
          targetPassages =
            [ (mkPassageForItem (uuidFromWord n) (Just targetItemId) fixedTime)
                { cortexMemoryPassageOrder = fromIntegral (n - 520)
                }
            | n <- [520 .. 531]
            ]
          linkedPassages =
            concat
              [ [ (mkPassageForItem (uuidFromWord (600 + ix * 10 + fromIntegral offset)) (Just itemId) fixedTime)
                    { cortexMemoryPassageOrder = offset
                    }
                | offset <- [0 :: Int .. 3]
                ]
              | (ix, itemId) <- zip [0 :: Word32 ..] linkedItemIds
              ]
          lexicalCandidates =
            [ (baseCandidate (mkPassageForItem (uuidFromWord (700 + n)) (Just (uuidFromWord (800 + n))) fixedTime))
                { cortexCandidateLexicalScore = Just (0.9 - fromIntegral n / 100)
                , cortexCandidateSources = [CortexMemoryRetrievedFromLexical]
                }
            | n <- [0 .. 9]
            ]
          fuzzyCandidate =
            (baseCandidate (mkPassageForItem (uuidFromWord 900) (Just (uuidFromWord 901)) fixedTime))
              { cortexCandidateFuzzyScore = Just 0.7
              , cortexCandidateSources = [CortexMemoryRetrievedFromFuzzy]
              }
          semanticCandidate =
            (baseCandidate (mkPassageForItem (uuidFromWord 902) (Just (uuidFromWord 903)) fixedTime))
              { cortexCandidateSemanticScore = Just 0.8
              , cortexCandidateSources = [CortexMemoryRetrievedFromSemantic]
              }
          host =
            CortexMemoryHost
              { cortexMemoryLoadSessionPassages = \_ _ -> pure []
              , cortexMemorySearchLexical = \_ _ -> pure lexicalCandidates
              , cortexMemorySearchFuzzy = \_ _ -> pure [fuzzyCandidate]
              , cortexMemorySearchSemantic = \_ _ -> pure [semanticCandidate]
              , cortexMemoryLoadItemPassages = \_ -> pure (targetPassages <> linkedPassages)
              }
          generated = runIdentity (generateMemoryCandidates host plan sessionPassages)
          searchCandidates =
            filter
              ( any
                  ( `elem`
                      [ CortexMemoryRetrievedFromLexical
                      , CortexMemoryRetrievedFromFuzzy
                      , CortexMemoryRetrievedFromSemantic
                      ]
                  )
                  . cortexCandidateSources
              )
              generated

      -- With default (no-op) entity config, "AMD downside" (2 terms, no entities)
      -- routes to QuerySimpleLexical → lexical + fuzzy only, no semantic.
      length generated `shouldBe` 67
      length searchCandidates `shouldBe` 11

  describe "classifyQueryComplexity" $ do
    it "classifies blank query as QueryBlank" $ do
      let query = parseMemoryQuery testEntityConfig "" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QueryBlank

    it "classifies entity-only query as QueryEntityLookup" $ do
      let query = parseMemoryQuery testEntityConfig "AAPL" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QueryEntityLookup

    it "classifies lowercase short word as QuerySimpleLexical, not entity lookup" $ do
      let query = parseMemoryQuery testEntityConfig "apple" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QuerySimpleLexical

    it "classifies short query without entities as QuerySimpleLexical" $ do
      let query = parseMemoryQuery testEntityConfig "revenue" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QuerySimpleLexical

    it "classifies complex query as QueryFull" $ do
      let query = parseMemoryQuery testEntityConfig "AAPL revenue growth compared to MSFT margins" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QueryFull

    it "classifies short update queries as SimpleLexical" $ do
      let query = parseMemoryQuery testEntityConfig "updated guidance" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QuerySimpleLexical

    it "classifies continuation-like words with entities as QueryFull" $ do
      let query = parseMemoryQuery testEntityConfig "latest AAPL update" [] Nothing
      classifyQueryComplexity testEntityConfig query `shouldBe` QueryFull

  describe "query complexity routing" $ do
    it "uses only lexical for entity-only queries" $ do
      let query = parseMemoryQuery testEntityConfig "TSLA" [] Nothing
          plan = buildMemorySearchPlan testEntityConfig query Nothing [] 60
      plan.cmspUseLexical `shouldBe` True
      plan.cmspUseFuzzy `shouldBe` False
      plan.cmspUseSemantic `shouldBe` False

    it "enables all strategies for complex analytical queries" $ do
      let query = parseMemoryQuery testEntityConfig "AAPL revenue growth compared to MSFT margins" [] Nothing
          plan = buildMemorySearchPlan testEntityConfig query Nothing [] 60
      plan.cmspUseLexical `shouldBe` True
      plan.cmspUseFuzzy `shouldBe` True
      plan.cmspUseSemantic `shouldBe` True

baseCandidate :: CortexMemoryPassage -> CortexMemoryCandidate
baseCandidate passage =
  CortexMemoryCandidate
    { cortexCandidatePassage = passage
    , cortexCandidateLexicalScore = Nothing
    , cortexCandidateFuzzyScore = Nothing
    , cortexCandidateSemanticScore = Nothing
    , cortexCandidateMatchedTerms = []
    , cortexCandidateMatchedFields = []
    , cortexCandidateSources = []
    , cortexCandidateFusionScore = 0
    }

mkPassage :: UUID.UUID -> CortexMemoryPassage
mkPassage passageId' =
  CortexMemoryPassage
    { cortexMemoryPassageId = passageId'
    , cortexMemorySourceKind = "saved_report"
    , cortexMemorySourceItemId = Just (uuidFromWord 2)
    , cortexMemorySourceCheckpointId = Nothing
    , cortexMemorySourceVersionId = uuidFromWord 3
    , cortexMemoryChatSessionId = Nothing
    , cortexMemoryPassageOrder = 0
    , cortexMemorySourceTitle = "AMD note"
    , cortexMemorySectionHeading = Just "Thesis"
    , cortexMemoryPassageText = "AMD downside watch remains active."
    , cortexMemoryEntities = ["AMD"]
    , cortexMemoryReportType = Nothing
    , cortexMemoryTimeRange = Nothing
    , cortexMemoryPassageTokenCount = 8
    , cortexMemorySourceCreatedAt = fixedTime
    , cortexMemorySourceUpdatedAt = fixedTime
    }

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime 0)

reciprocalRank :: Int -> Double
reciprocalRank rankIndex = 1 / fromIntegral (60 + rankIndex)

mkPassageForItem :: UUID.UUID -> Maybe UUID.UUID -> UTCTime -> CortexMemoryPassage
mkPassageForItem passageId' itemId' updatedAt' =
  (mkPassage passageId')
    { cortexMemorySourceItemId = itemId'
    , cortexMemorySourceCreatedAt = updatedAt'
    , cortexMemorySourceUpdatedAt = updatedAt'
    }

uuidFromWord :: Word32 -> UUID.UUID
uuidFromWord = UUID.fromWords 0 0 0
