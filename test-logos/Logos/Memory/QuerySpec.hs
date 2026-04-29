{- |
Module      : Logos.Memory.QuerySpec
Description : Tests for Logos.Memory.Query.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.QuerySpec (spec) where

import Data.List (sort)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Query
  ( LogosMemoryQuery (..)
  , logosMemoryQueryPositiveTerms
  , parseMemoryQuery
  )
import Logos.Memory.Types
  ( defaultLogosMemoryEntityConfig
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "parseMemoryQuery" $ do
    it "preserves phrases, negated terms, and intent hints (no entity config)" $ do
      let anchored = [uuidFromWord 1, uuidFromWord 2, uuidFromWord 1]
          explicitTarget = Just (uuidFromWord 9)
          parsed =
            parseMemoryQuery
              defaultLogosMemoryEntityConfig
              "Continue the latest GE plan about \"gross margin\" -bearish"
              anchored
              explicitTarget

      parsed.logosMemoryQueryPhrases `shouldBe` ["gross margin"]
      parsed.logosMemoryQueryNegativeTerms `shouldBe` ["bearish"]
      -- With default entity config, no entities are extracted
      parsed.logosMemoryQueryEntities `shouldBe` []
      parsed.logosMemoryQueryContinuationIntent `shouldBe` True
      parsed.logosMemoryQueryRecencyHint `shouldBe` Just "latest"
      parsed.logosMemoryQueryReportTypeHint `shouldBe` Just "plan"
      sort parsed.logosMemoryQueryAnchoredItemIds `shouldBe` sort [uuidFromWord 1, uuidFromWord 2]
      parsed.logosMemoryQueryExplicitTargetItemId `shouldBe` explicitTarget
      let positiveTerms = logosMemoryQueryPositiveTerms parsed
      positiveTerms `shouldSatisfy` \ts -> all (`elem` ts) ["gross", "margin"]

uuidFromWord :: Word32 -> UUID.UUID
uuidFromWord = UUID.fromWords 0 0 0
