module Cortex.Text
  ( showText,
    stripNonEmptyMaybeText,
    stripNonEmptyText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

showText :: (Show a) => a -> Text
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
