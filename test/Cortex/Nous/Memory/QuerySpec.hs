module Cortex.Nous.Memory.QuerySpec (spec) where

import Data.List (sort)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

import Cortex.Nous.Memory.Query
  ( CortexMemoryQuery (..)
  , cortexMemoryQueryPositiveTerms
  , parseMemoryQuery
  )
import Cortex.Nous.Memory.Types
  ( defaultCortexMemoryEntityConfig
  )

spec :: Spec
spec = do
  describe "parseMemoryQuery" $ do
    it "preserves phrases, negated terms, and intent hints (no entity config)" $ do
      let anchored = [uuidFromWord 1, uuidFromWord 2, uuidFromWord 1]
          explicitTarget = Just (uuidFromWord 9)
          parsed =
            parseMemoryQuery
              defaultCortexMemoryEntityConfig
              "Continue the latest GE plan about \"gross margin\" -bearish"
              anchored
              explicitTarget

      parsed.cortexMemoryQueryPhrases `shouldBe` ["gross margin"]
      parsed.cortexMemoryQueryNegativeTerms `shouldBe` ["bearish"]
      -- With default entity config, no entities are extracted
      parsed.cortexMemoryQueryEntities `shouldBe` []
      parsed.cortexMemoryQueryContinuationIntent `shouldBe` True
      parsed.cortexMemoryQueryRecencyHint `shouldBe` Just "latest"
      parsed.cortexMemoryQueryReportTypeHint `shouldBe` Just "plan"
      sort parsed.cortexMemoryQueryAnchoredItemIds `shouldBe` sort [uuidFromWord 1, uuidFromWord 2]
      parsed.cortexMemoryQueryExplicitTargetItemId `shouldBe` explicitTarget
      let positiveTerms = cortexMemoryQueryPositiveTerms parsed
      positiveTerms `shouldSatisfy` \ts -> all (`elem` ts) ["gross", "margin"]

uuidFromWord :: Word32 -> UUID.UUID
uuidFromWord = UUID.fromWords 0 0 0
