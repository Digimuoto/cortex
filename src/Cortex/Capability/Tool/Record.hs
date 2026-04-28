{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Tool.Record
  ( CortexToolCallRecord (..)
  , buildToolCallRecord
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Platform.Serde.Json.Preview
  ( toolCallPayloadPreview
  , truncateJsonValue
  , truncateText
  )

data CortexToolCallRecord = CortexToolCallRecord
  { cortexToolCallRecordId :: Text
  , cortexToolCallRecordName :: Text
  , cortexToolCallRecordArgs :: Aeson.Value
  , cortexToolCallRecordResult :: Aeson.Value
  , cortexToolCallRecordTimestamp :: UTCTime
  , cortexToolCallRecordDuration :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

buildToolCallRecord :: Text -> Text -> Text -> Text -> UTCTime -> Int -> CortexToolCallRecord
buildToolCallRecord callId toolName rawArgs rawResult timestamp durationMs =
  CortexToolCallRecord
    { cortexToolCallRecordId = callId
    , cortexToolCallRecordName = toolName
    , cortexToolCallRecordArgs =
        case parseToolArgs rawArgs of
          Right jsonValue -> truncateJsonValue 12 40 60 jsonValue
          Left _ ->
            Aeson.object
              [ "rawText" .= truncateText 600 (T.strip rawArgs)
              ]
    , cortexToolCallRecordResult =
        fromMaybe
          (Aeson.object ["text" .= truncateText 600 (T.strip rawResult)])
          (toolCallPayloadPreview 20 50 100 rawResult)
    , cortexToolCallRecordTimestamp = timestamp
    , cortexToolCallRecordDuration = durationMs
    }

parseToolArgs :: Text -> Either Text Aeson.Value
parseToolArgs rawArgs =
  let normalized = T.strip rawArgs
      jsonText = if T.null normalized then "{}" else normalized
   in case Aeson.eitherDecodeStrict' (TE.encodeUtf8 jsonText) of
        Left err -> Left (T.pack err)
        Right value -> Right value
