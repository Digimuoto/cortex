{-# LANGUAGE OverloadedStrings #-}

module Platform.Text
  ( truncateText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

truncateText :: Int -> Text -> Text
truncateText maxLen txt
  | maxLen <= 0 = ""
  | T.length txt <= maxLen = txt
  | maxLen <= 3 = T.take maxLen txt
  | otherwise = T.take (maxLen - 3) txt <> "..."
