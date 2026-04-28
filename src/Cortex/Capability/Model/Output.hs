{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Model.Output
  ( appendSourcesSection
  , renderChoiceContentWithSources
  , shouldAppendExternalSourceFooter
  )
where

import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexGroundingMode (..)
  )

renderChoiceContentWithSources :: CortexGroundingMode -> CortexChoice -> Text
renderChoiceContentWithSources groundingMode choice
  | shouldAppendExternalSourceFooter groundingMode choice.cortexChoiceSourceLinks =
      appendSourcesSection choice.cortexChoiceContent choice.cortexChoiceSourceLinks
  | otherwise = choice.cortexChoiceContent

shouldAppendExternalSourceFooter :: CortexGroundingMode -> [(Text, Text)] -> Bool
shouldAppendExternalSourceFooter groundingMode sourceLinks
  | groundingMode /= GroundingEnabled = False
  | null sourceLinks = False
  | otherwise = True

appendSourcesSection :: Text -> [(Text, Text)] -> Text
appendSourcesSection content sourceLinks
  | null dedupedSourceLinks = content
  | otherwise =
      let separator
            | T.null (T.strip content) = ""
            | T.isSuffixOf "\n" content = "\n"
            | otherwise = "\n\n"
          sourcesBody =
            T.intercalate "\n" $
              "Sources:"
                : fmap renderMarkdownSourceLink dedupedSourceLinks
       in content <> separator <> sourcesBody
  where
    dedupedSourceLinks = dedupeSourceLinks sourceLinks

renderMarkdownSourceLink :: (Text, Text) -> Text
renderMarkdownSourceLink (label, url) =
  "- [" <> escapeMarkdownLinkTitle normalizedLabel <> "](<" <> escapeMarkdownLinkUrl url <> ">)"
  where
    normalizedLabel =
      if T.null (T.strip label)
        then url
        else T.strip label

escapeMarkdownLinkTitle :: Text -> Text
escapeMarkdownLinkTitle =
  T.concatMap escapeChar
  where
    escapeChar '\\' = "\\\\"
    escapeChar '[' = "\\["
    escapeChar ']' = "\\]"
    escapeChar char = T.singleton char

escapeMarkdownLinkUrl :: Text -> Text
escapeMarkdownLinkUrl =
  T.concatMap escapeChar
  where
    escapeChar '\\' = "\\\\"
    escapeChar '<' = "\\<"
    escapeChar '>' = "\\>"
    escapeChar char = T.singleton char

dedupeSourceLinks :: [(Text, Text)] -> [(Text, Text)]
dedupeSourceLinks = go []
  where
    go _ [] = []
    go seen (link@(_, url) : rest)
      | url `elem` seen = go seen rest
      | otherwise = link : go (url : seen) rest
