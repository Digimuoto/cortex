{-# LANGUAGE OverloadedStrings #-}

module Cortex.Memory.DocumentSpec (spec) where

import Cortex.Memory.Document
  ( CortexMemoryDocument (..),
    CortexMemoryPassageDraft (..),
    MarkdownSection (..),
    indexMarkdownDocument,
    splitMarkdownSections,
  )
import Cortex.Memory.Pack
  ( selectByTokenBudget,
  )
import Cortex.Memory.Types
  ( defaultCortexMemoryEntityConfig,
  )
import Cortex.MemoryCompaction
  ( estimateTextTokens,
  )
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

spec :: Spec
spec = do
  describe "splitMarkdownSections" $ do
    it "splits intro text and headed sections in order" $ do
      splitMarkdownSections
        "Intro paragraph.\n\n## Thesis\nAAPL looks constructive.\n\n### Risks\nWatch valuation."
        `shouldBe` [ MarkdownSection 0 Nothing "Intro paragraph.",
                     MarkdownSection 1 (Just "Thesis") "AAPL looks constructive.",
                     MarkdownSection 2 (Just "Risks") "Watch valuation."
                   ]

    it "drops empty headed sections" $ do
      splitMarkdownSections "## Empty\n\n## Filled\nContent"
        `shouldBe` [MarkdownSection 0 (Just "Filled") "Content"]

  describe "indexMarkdownDocument" $ do
    it "turns a markdown document into normalized passage drafts with default (no-op) entity config" $ do
      indexMarkdownDocument defaultCortexMemoryEntityConfig validDocument
        `shouldBe` [ CortexMemoryPassageDraft
                       { memoryPassageSourceKind = "workspace_markdown",
                         memoryPassageOrder = 0,
                         memoryPassageSourceTitle = "Prior thesis",
                         memoryPassageSectionHeading = Just "AAPL",
                         memoryPassageText = "AAPL.",
                         memoryPassageEntities = Nothing,
                         memoryPassageReportType = Just "report",
                         memoryPassageTimeRange = Just "1y",
                         memoryPassageTokenCount = 2,
                         memoryPassageSourceCreatedAt = fixedTime,
                         memoryPassageSourceUpdatedAt = fixedTime
                       },
                     CortexMemoryPassageDraft
                       { memoryPassageSourceKind = "workspace_markdown",
                         memoryPassageOrder = 1,
                         memoryPassageSourceTitle = "Prior thesis",
                         memoryPassageSectionHeading = Just "NVDA",
                         memoryPassageText = "NVDA.",
                         memoryPassageEntities = Nothing,
                         memoryPassageReportType = Just "report",
                         memoryPassageTimeRange = Just "1y",
                         memoryPassageTokenCount = 2,
                         memoryPassageSourceCreatedAt = fixedTime,
                         memoryPassageSourceUpdatedAt = fixedTime
                       }
                   ]

    it "falls back to a single passage when the body has no headings" $ do
      fmap memoryPassageText (indexMarkdownDocument defaultCortexMemoryEntityConfig validDocument {memoryDocumentBody = "Single body"})
        `shouldBe` ["Single body"]

  describe "selectByTokenBudget" $ do
    it "keeps the first row even when it consumes the budget" $ do
      let huge = T.replicate 60 "a"
          next = T.replicate 20 "b"
      selectByTokenBudget 10 3 [huge, next] (fromIntegral . estimateTextTokens)
        `shouldBe` [huge]

    it "keeps rows within the budget and max count" $ do
      let chunk = T.replicate 20 "a"
      selectByTokenBudget 15 3 [chunk, chunk, chunk, chunk] (fromIntegral . estimateTextTokens)
        `shouldBe` [chunk, chunk, chunk]

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 3 21) (secondsToDiffTime 0)

validDocument :: CortexMemoryDocument
validDocument =
  CortexMemoryDocument
    { memoryDocumentSourceKind = "workspace_markdown",
      memoryDocumentTitle = "Prior thesis",
      memoryDocumentBody = "## AAPL\nAAPL.\n\n## NVDA\nNVDA.",
      memoryDocumentContextTexts = ["1y"],
      memoryDocumentReportType = Just "report",
      memoryDocumentTimeRange = Just "1y",
      memoryDocumentCreatedAt = fixedTime,
      memoryDocumentUpdatedAt = fixedTime
    }
