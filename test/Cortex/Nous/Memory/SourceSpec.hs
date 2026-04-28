{- |
Module      : Cortex.Nous.Memory.SourceSpec
Description : Tests for Cortex.Nous.Memory.Source.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Nous.Memory.SourceSpec (spec) where

import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

import Cortex.Nous.Memory.Document
  ( CortexMemoryDocument (..)
  , CortexMemoryPassageDraft (..)
  )
import Cortex.Nous.Memory.Source
  ( CortexMemoryIndexedPassage (..)
  , CortexMemorySource (..)
  , indexMemorySource
  )
import Cortex.Nous.Memory.Types
  ( defaultCortexMemoryEntityConfig
  )

spec :: Spec
spec = do
  describe "indexMemorySource" $ do
    it "preserves source identity across every indexed passage" $ do
      let versionId = uuidFromWord 10
          itemId = uuidFromWord 11
          sessionId = uuidFromWord 12
          indexedPassages =
            indexMemorySource defaultCortexMemoryEntityConfig $
              CortexMemorySource
                { cortexMemorySourceVersionId = versionId
                , cortexMemorySourceItemId = Just itemId
                , cortexMemorySourceCheckpointId = Nothing
                , cortexMemorySourceChatSessionId = Just sessionId
                , cortexMemorySourceDocument =
                    mkDocument
                      "saved_report"
                      "AMD continuation memo"
                      "## Thesis\nAMD remains constructive.\n\n## Risks\nGross margin downside would weaken the case."
                }

      fmap indexedVersionId indexedPassages `shouldBe` [versionId, versionId]
      fmap indexedItemId indexedPassages `shouldBe` [Just itemId, Just itemId]
      fmap indexedSessionId indexedPassages `shouldBe` [Just sessionId, Just sessionId]
      fmap indexedHeading indexedPassages `shouldBe` [Just "Thesis", Just "Risks"]

    it "returns no passages for blank source documents" $ do
      let indexedPassages =
            indexMemorySource defaultCortexMemoryEntityConfig $
              CortexMemorySource
                { cortexMemorySourceVersionId = uuidFromWord 20
                , cortexMemorySourceItemId = Nothing
                , cortexMemorySourceCheckpointId = Just (uuidFromWord 21)
                , cortexMemorySourceChatSessionId = Nothing
                , cortexMemorySourceDocument = mkDocument "checkpoint" "Empty checkpoint" "   "
                }

      indexedPassages `shouldBe` []

mkDocument :: Text -> Text -> Text -> CortexMemoryDocument
mkDocument sourceKind title body =
  CortexMemoryDocument
    { memoryDocumentSourceKind = sourceKind
    , memoryDocumentTitle = title
    , memoryDocumentBody = body
    , memoryDocumentContextTexts = []
    , memoryDocumentReportType = Nothing
    , memoryDocumentTimeRange = Nothing
    , memoryDocumentCreatedAt = fixedNow
    , memoryDocumentUpdatedAt = fixedNow
    }

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 3 21) (secondsToDiffTime 0)

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0

indexedVersionId :: CortexMemoryIndexedPassage -> UUID
indexedVersionId = (.cortexMemoryIndexedVersionId)

indexedItemId :: CortexMemoryIndexedPassage -> Maybe UUID
indexedItemId = (.cortexMemoryIndexedSourceItemId)

indexedSessionId :: CortexMemoryIndexedPassage -> Maybe UUID
indexedSessionId = (.cortexMemoryIndexedChatSessionId)

indexedHeading :: CortexMemoryIndexedPassage -> Maybe Text
indexedHeading = (.memoryPassageSectionHeading) . (.cortexMemoryIndexedPassageDraft)
