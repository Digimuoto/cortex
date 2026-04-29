{- |
Module      : Logos.Memory.SourceSpec
Description : Tests for Logos.Memory.Source.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.SourceSpec (spec) where

import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Document
  ( LogosMemoryDocument (..)
  , LogosMemoryPassageDraft (..)
  )
import Logos.Memory.Source
  ( LogosMemoryIndexedPassage (..)
  , LogosMemorySource (..)
  , indexMemorySource
  )
import Logos.Memory.Types
  ( defaultLogosMemoryEntityConfig
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "indexMemorySource" $ do
    it "preserves source identity across every indexed passage" $ do
      let versionId = uuidFromWord 10
          itemId = uuidFromWord 11
          sessionId = uuidFromWord 12
          indexedPassages =
            indexMemorySource defaultLogosMemoryEntityConfig $
              LogosMemorySource
                { logosMemorySourceVersionId = versionId
                , logosMemorySourceItemId = Just itemId
                , logosMemorySourceCheckpointId = Nothing
                , logosMemorySourceChatSessionId = Just sessionId
                , logosMemorySourceDocument =
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
            indexMemorySource defaultLogosMemoryEntityConfig $
              LogosMemorySource
                { logosMemorySourceVersionId = uuidFromWord 20
                , logosMemorySourceItemId = Nothing
                , logosMemorySourceCheckpointId = Just (uuidFromWord 21)
                , logosMemorySourceChatSessionId = Nothing
                , logosMemorySourceDocument = mkDocument "checkpoint" "Empty checkpoint" "   "
                }

      indexedPassages `shouldBe` []

mkDocument :: Text -> Text -> Text -> LogosMemoryDocument
mkDocument sourceKind title body =
  LogosMemoryDocument
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

indexedVersionId :: LogosMemoryIndexedPassage -> UUID
indexedVersionId = (.logosMemoryIndexedVersionId)

indexedItemId :: LogosMemoryIndexedPassage -> Maybe UUID
indexedItemId = (.logosMemoryIndexedSourceItemId)

indexedSessionId :: LogosMemoryIndexedPassage -> Maybe UUID
indexedSessionId = (.logosMemoryIndexedChatSessionId)

indexedHeading :: LogosMemoryIndexedPassage -> Maybe Text
indexedHeading = (.memoryPassageSectionHeading) . (.logosMemoryIndexedPassageDraft)
