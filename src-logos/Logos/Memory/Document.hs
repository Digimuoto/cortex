{- |
Module      : Logos.Memory.Document
Description : Logos reasoning-library support for document.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Document
  ( LogosMemoryDocument (..)
  , LogosMemoryPassageDraft (..)
  , MarkdownSection (..)
  , indexMarkdownDocument
  , splitMarkdownSections
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Logos.Memory.Compact (estimateTextTokens)
import Logos.Memory.Types (LogosMemoryEntityConfig (..))

data LogosMemoryDocument = LogosMemoryDocument
  { memoryDocumentSourceKind :: Text
  , memoryDocumentTitle :: Text
  , memoryDocumentBody :: Text
  , memoryDocumentContextTexts :: [Text]
  , memoryDocumentReportType :: Maybe Text
  , memoryDocumentTimeRange :: Maybe Text
  , memoryDocumentCreatedAt :: UTCTime
  , memoryDocumentUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

data LogosMemoryPassageDraft = LogosMemoryPassageDraft
  { memoryPassageSourceKind :: Text
  , memoryPassageOrder :: Int
  , memoryPassageSourceTitle :: Text
  , memoryPassageSectionHeading :: Maybe Text
  , memoryPassageText :: Text
  , memoryPassageEntities :: Maybe Text
  , memoryPassageReportType :: Maybe Text
  , memoryPassageTimeRange :: Maybe Text
  , memoryPassageTokenCount :: Int
  , memoryPassageSourceCreatedAt :: UTCTime
  , memoryPassageSourceUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

data MarkdownSection = MarkdownSection
  { markdownSectionOrder :: Int
  , markdownSectionHeading :: Maybe Text
  , markdownSectionText :: Text
  }
  deriving stock (Eq, Show, Generic)

indexMarkdownDocument
  :: LogosMemoryEntityConfig -> LogosMemoryDocument -> [LogosMemoryPassageDraft]
indexMarkdownDocument entityConfig document
  | T.null (T.strip document.memoryDocumentBody) = []
  | otherwise =
      fmap
        ( \section ->
            LogosMemoryPassageDraft
              { memoryPassageSourceKind = document.memoryDocumentSourceKind
              , memoryPassageOrder = section.markdownSectionOrder
              , memoryPassageSourceTitle = document.memoryDocumentTitle
              , memoryPassageSectionHeading = section.markdownSectionHeading
              , memoryPassageText = section.markdownSectionText
              , memoryPassageEntities = entitiesText
              , memoryPassageReportType = document.memoryDocumentReportType
              , memoryPassageTimeRange = document.memoryDocumentTimeRange
              , memoryPassageTokenCount = fromIntegral (estimateTextTokens section.markdownSectionText)
              , memoryPassageSourceCreatedAt = document.memoryDocumentCreatedAt
              , memoryPassageSourceUpdatedAt = document.memoryDocumentUpdatedAt
              }
        )
        finalSections
  where
    sections = nonEmptySections (splitMarkdownSections document.memoryDocumentBody)
    finalSections =
      if null sections
        then [MarkdownSection 0 Nothing document.memoryDocumentBody]
        else sections
    combinedText =
      T.unlines $
        filter
          (not . T.null)
          ([document.memoryDocumentTitle, document.memoryDocumentBody] <> document.memoryDocumentContextTexts)
    entitiesText = commaText (logosMemoryExtractEntities entityConfig combinedText)

splitMarkdownSections :: Text -> [MarkdownSection]
splitMarkdownSections rawText =
  finalizeSections finalState
  where
    initialState = (Nothing, [] :: [Text], [] :: [MarkdownSection], 0 :: Int)
    finalState = foldl' step initialState (T.lines rawText)

    step (currentHeading, currentLines, acc, nextOrder) line =
      case parseHeadingLine line of
        Just heading ->
          let emitted = flushSection currentHeading currentLines nextOrder
              nextOrder' = maybe nextOrder ((+ 1) . markdownSectionOrder) (safeLast emitted)
           in (Just heading, [], acc <> emitted, nextOrder')
        Nothing ->
          (currentHeading, currentLines <> [line], acc, nextOrder)

    finalizeSections (currentHeading, currentLines, acc, nextOrder) =
      acc <> flushSection currentHeading currentLines nextOrder

    flushSection currentHeading currentLines nextOrder =
      let body = T.strip (T.unlines currentLines)
       in [ MarkdownSection
              { markdownSectionOrder = nextOrder
              , markdownSectionHeading = currentHeading
              , markdownSectionText = body
              }
          | not (T.null body)
          ]

commaText :: [Text] -> Maybe Text
commaText values =
  nonEmptyText . Just $
    T.intercalate ", " (filter (not . T.null) values)

nonEmptyText :: Maybe Text -> Maybe Text
nonEmptyText maybeText =
  case fmap T.strip maybeText of
    Just trimmed | not (T.null trimmed) -> Just trimmed
    _ -> Nothing

nonEmptySections :: [MarkdownSection] -> [MarkdownSection]
nonEmptySections =
  filter (not . T.null . T.strip . markdownSectionText)

parseHeadingLine :: Text -> Maybe Text
parseHeadingLine line = do
  stripped <- nonEmptyText (Just (T.strip line))
  guardHeading stripped
  let heading = T.strip (T.dropWhile (== '#') stripped)
  nonEmptyText (Just heading)
  where
    guardHeading txt
      | "#" `T.isPrefixOf` txt
          && T.length (T.takeWhile (== '#') txt) <= 6
          && T.isPrefixOf " " (T.dropWhile (== '#') txt) =
          Just ()
      | otherwise = Nothing

safeLast :: [a] -> Maybe a
safeLast [] = Nothing
safeLast values = Just (last values)
