{- |
Module      : Logos.Memory.CandidatesSpec
Description : Tests for Logos.Memory.Candidates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.CandidatesSpec (spec) where

import Data.Char (isAsciiUpper, isDigit)
import Data.Functor.Identity
  ( Identity (..)
  )
import Data.List (sort)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Candidates
  ( LogosMemorySearchPlan (..)
  , QueryComplexity (..)
  , buildMemorySearchPlan
  , classifyQueryComplexity
  , generateMemoryCandidates
  , mergeMemoryCandidates
  )
import Logos.Memory.Host
  ( LogosMemoryHost (..)
  )
import Logos.Memory.Query
  ( parseMemoryQuery
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryEntityConfig (..)
  , LogosMemoryMatchedField (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRetrievalSource (..)
  , defaultLogosMemoryEntityConfig
  )
import Test.Hspec

{- | Test entity config that mimics ticker extraction for verifying
entity-aware query routing without Cortex depending on Portman.
-}
testEntityConfig :: LogosMemoryEntityConfig
testEntityConfig =
  LogosMemoryEntityConfig
    { logosMemoryExtractEntities =
        filter isUppercaseToken . T.words . T.strip
    , logosMemoryIsEntityOnlyQuery = \rawText ->
        let tokens = T.words (T.strip rawText)
         in not (null tokens) && all isUppercaseToken tokens
    , logosMemoryQueryHasEntityIntent =
        any isUppercaseToken . T.words . T.strip
    , logosMemoryPositiveStanceTerms = []
    , logosMemoryNegativeStanceTerms = []
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
          query = parseMemoryQuery defaultLogosMemoryEntityConfig "AMD downside" [] Nothing
          merged =
            mergeMemoryCandidates
              query
              [ (baseCandidate passage)
                  { logosCandidateLexicalScore = Just 0.8
                  , logosCandidateMatchedTerms = ["amd"]
                  , logosCandidateMatchedFields = [LogosMemoryMatchedTitle]
                  , logosCandidateSources = [LogosMemoryRetrievedFromLexical]
                  }
              , (baseCandidate passage)
                  { logosCandidateFuzzyScore = Just 0.5
                  , logosCandidateMatchedTerms = ["downside"]
                  , logosCandidateMatchedFields = [LogosMemoryMatchedBody]
                  , logosCandidateSources = [LogosMemoryRetrievedFromFuzzy]
                  }
              , (baseCandidate passage)
                  { logosCandidateSemanticScore = Just 0.7
                  , logosCandidateSources = [LogosMemoryRetrievedFromSemantic]
                  }
              ]

      length merged `shouldBe` 1
      let candidate = case merged of (c : _) -> c; [] -> error "unexpected empty"
      candidate.logosCandidateLexicalScore `shouldBe` Just 0.8
      candidate.logosCandidateFuzzyScore `shouldBe` Just 0.5
      candidate.logosCandidateSemanticScore `shouldBe` Just 0.7
      sort candidate.logosCandidateMatchedTerms `shouldBe` ["amd", "downside"]
      sort candidate.logosCandidateSources
        `shouldBe` sort
          [ LogosMemoryRetrievedFromLexical
          , LogosMemoryRetrievedFromFuzzy
          , LogosMemoryRetrievedFromSemantic
          ]
      candidate.logosCandidateFusionScore
        `shouldSatisfy` \score ->
          abs (score - 3 * reciprocalRank 1) < 1.0e-12

    it "keeps reciprocal ranks local to each retrieval strategy" $ do
      let query = parseMemoryQuery defaultLogosMemoryEntityConfig "AMD downside" [] Nothing
          semanticPassage = mkPassage (uuidFromWord 300)
          lexicalCandidates =
            [ (baseCandidate (mkPassage (uuidFromWord n)))
                { logosCandidateLexicalScore = Just (1.0 - fromIntegral (n - 100) / 100)
                , logosCandidateSources = [LogosMemoryRetrievedFromLexical]
                }
            | n <- [100 .. 139]
            ]
          semanticCandidate =
            (baseCandidate semanticPassage)
              { logosCandidateSemanticScore = Just 0.9
              , logosCandidateSources = [LogosMemoryRetrievedFromSemantic]
              }
          merged = mergeMemoryCandidates query (lexicalCandidates <> [semanticCandidate])

      let candidate =
            case filter
              ((== semanticPassage.logosMemoryPassageId) . (.logosMemoryPassageId) . logosCandidatePassage)
              merged of
              (c : _) -> c
              [] -> error "semantic candidate missing"
      candidate.logosCandidateFusionScore
        `shouldSatisfy` \score ->
          abs (score - reciprocalRank 1) < 1.0e-12

  describe "generateMemoryCandidates" $ do
    it "does not truncate search candidates before downstream ranking" $ do
      let targetItemId = uuidFromWord 400
          linkedItemIds = fmap uuidFromWord [401 .. 408]
          query = parseMemoryQuery defaultLogosMemoryEntityConfig "AMD downside" linkedItemIds (Just targetItemId)
          plan =
            buildMemorySearchPlan
              defaultLogosMemoryEntityConfig
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
                { logosMemoryPassageOrder = fromIntegral (n - 520)
                }
            | n <- [520 .. 531]
            ]
          linkedPassages =
            concat
              [ [ (mkPassageForItem (uuidFromWord (600 + ix * 10 + fromIntegral offset)) (Just itemId) fixedTime)
                    { logosMemoryPassageOrder = offset
                    }
                | offset <- [0 :: Int .. 3]
                ]
              | (ix, itemId) <- zip [0 :: Word32 ..] linkedItemIds
              ]
          lexicalCandidates =
            [ (baseCandidate (mkPassageForItem (uuidFromWord (700 + n)) (Just (uuidFromWord (800 + n))) fixedTime))
                { logosCandidateLexicalScore = Just (0.9 - fromIntegral n / 100)
                , logosCandidateSources = [LogosMemoryRetrievedFromLexical]
                }
            | n <- [0 .. 9]
            ]
          fuzzyCandidate =
            (baseCandidate (mkPassageForItem (uuidFromWord 900) (Just (uuidFromWord 901)) fixedTime))
              { logosCandidateFuzzyScore = Just 0.7
              , logosCandidateSources = [LogosMemoryRetrievedFromFuzzy]
              }
          semanticCandidate =
            (baseCandidate (mkPassageForItem (uuidFromWord 902) (Just (uuidFromWord 903)) fixedTime))
              { logosCandidateSemanticScore = Just 0.8
              , logosCandidateSources = [LogosMemoryRetrievedFromSemantic]
              }
          host =
            LogosMemoryHost
              { logosMemoryLoadSessionPassages = \_ _ -> pure []
              , logosMemorySearchLexical = \_ _ -> pure lexicalCandidates
              , logosMemorySearchFuzzy = \_ _ -> pure [fuzzyCandidate]
              , logosMemorySearchSemantic = \_ _ -> pure [semanticCandidate]
              , logosMemoryLoadItemPassages = \_ -> pure (targetPassages <> linkedPassages)
              }
          generated = runIdentity (generateMemoryCandidates host plan sessionPassages)
          searchCandidates =
            filter
              ( any
                  ( `elem`
                      [ LogosMemoryRetrievedFromLexical
                      , LogosMemoryRetrievedFromFuzzy
                      , LogosMemoryRetrievedFromSemantic
                      ]
                  )
                  . logosCandidateSources
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
      plan.logosMemorySearchPlanUseLexical `shouldBe` True
      plan.logosMemorySearchPlanUseFuzzy `shouldBe` False
      plan.logosMemorySearchPlanUseSemantic `shouldBe` False

    it "enables all strategies for complex analytical queries" $ do
      let query = parseMemoryQuery testEntityConfig "AAPL revenue growth compared to MSFT margins" [] Nothing
          plan = buildMemorySearchPlan testEntityConfig query Nothing [] 60
      plan.logosMemorySearchPlanUseLexical `shouldBe` True
      plan.logosMemorySearchPlanUseFuzzy `shouldBe` True
      plan.logosMemorySearchPlanUseSemantic `shouldBe` True

baseCandidate :: LogosMemoryPassage -> LogosMemoryCandidate
baseCandidate passage =
  LogosMemoryCandidate
    { logosCandidatePassage = passage
    , logosCandidateLexicalScore = Nothing
    , logosCandidateFuzzyScore = Nothing
    , logosCandidateSemanticScore = Nothing
    , logosCandidateMatchedTerms = []
    , logosCandidateMatchedFields = []
    , logosCandidateSources = []
    , logosCandidateFusionScore = 0
    }

mkPassage :: UUID.UUID -> LogosMemoryPassage
mkPassage passageId' =
  LogosMemoryPassage
    { logosMemoryPassageId = passageId'
    , logosMemorySourceKind = "saved_report"
    , logosMemorySourceItemId = Just (uuidFromWord 2)
    , logosMemorySourceCheckpointId = Nothing
    , logosMemorySourceVersionId = uuidFromWord 3
    , logosMemoryChatSessionId = Nothing
    , logosMemoryPassageOrder = 0
    , logosMemorySourceTitle = "AMD note"
    , logosMemorySectionHeading = Just "Thesis"
    , logosMemoryPassageText = "AMD downside watch remains active."
    , logosMemoryEntities = ["AMD"]
    , logosMemoryReportType = Nothing
    , logosMemoryTimeRange = Nothing
    , logosMemoryPassageTokenCount = 8
    , logosMemorySourceCreatedAt = fixedTime
    , logosMemorySourceUpdatedAt = fixedTime
    }

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime 0)

reciprocalRank :: Int -> Double
reciprocalRank rankIndex = 1 / fromIntegral (60 + rankIndex)

mkPassageForItem :: UUID.UUID -> Maybe UUID.UUID -> UTCTime -> LogosMemoryPassage
mkPassageForItem passageId' itemId' updatedAt' =
  (mkPassage passageId')
    { logosMemorySourceItemId = itemId'
    , logosMemorySourceCreatedAt = updatedAt'
    , logosMemorySourceUpdatedAt = updatedAt'
    }

uuidFromWord :: Word32 -> UUID.UUID
uuidFromWord = UUID.fromWords 0 0 0
