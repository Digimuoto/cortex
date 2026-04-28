{- |
Module      : Platform.Text
Description : Platform runtime support for text.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Text
  ( showText
  , stripNonEmptyMaybeText
  , stripNonEmptyText
  , truncateText
  )
where

import Data.Text (Text)
import Data.Text qualified as T

showText :: Show a => a -> Text
showText = T.pack . show

stripNonEmptyText :: Text -> Maybe Text
stripNonEmptyText rawText
  | T.null stripped = Nothing
  | otherwise = Just stripped
  where
    stripped = T.strip rawText

stripNonEmptyMaybeText :: Maybe Text -> Maybe Text
stripNonEmptyMaybeText =
  (>>= stripNonEmptyText)

truncateText :: Int -> Text -> Text
truncateText maxLen txt
  | maxLen <= 0 = ""
  | T.length txt <= maxLen = txt
  | maxLen <= 3 = T.take maxLen txt
  | otherwise = T.take (maxLen - 3) txt <> "..."
