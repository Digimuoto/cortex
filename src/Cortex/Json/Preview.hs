{-# LANGUAGE OverloadedStrings #-}

module Cortex.Json.Preview
  ( toolCallPayloadPreview,
    truncateJsonValue,
    truncateText,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Platform.Text (truncateText)

toolCallPayloadPreview :: Int -> Int -> Int -> Text -> Maybe Aeson.Value
toolCallPayloadPreview maxDepth maxArrayItems maxObjectFields rawResult =
  case Aeson.decodeStrict' (TE.encodeUtf8 rawResult) of
    Just jsonValue ->
      Just (truncateJsonValue maxDepth maxArrayItems maxObjectFields jsonValue)
    Nothing ->
      let trimmed = T.strip rawResult
          shortText = truncateText 600 trimmed
       in if T.null shortText
            then Nothing
            else Just (Aeson.object ["text" .= shortText])

truncateJsonValue :: Int -> Int -> Int -> Aeson.Value -> Aeson.Value
truncateJsonValue maxDepth maxArrayItems maxObjectFields value
  | maxDepth <= 0 = Aeson.String "..."
  | otherwise =
      case value of
        Aeson.Array arr ->
          Aeson.Array . V.fromList $
            fmap
              (truncateJsonValue (maxDepth - 1) maxArrayItems maxObjectFields)
              (take maxArrayItems (V.toList arr))
        Aeson.Object obj ->
          Aeson.object
            [ key .= truncateJsonValue (maxDepth - 1) maxArrayItems maxObjectFields fieldValue
            | (key, fieldValue) <- take maxObjectFields (KeyMap.toList obj)
            ]
        Aeson.String txt ->
          Aeson.String (truncateText 600 txt)
        other -> other
