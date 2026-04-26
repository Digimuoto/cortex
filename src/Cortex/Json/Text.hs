module Cortex.Json.Text
  ( decodeLazyUtf8,
    jsonValueText,
    toolError,
    toolValidationError,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)

decodeLazyUtf8 :: BSL.ByteString -> Text
decodeLazyUtf8 = TE.decodeUtf8With lenientDecode . BSL.toStrict

jsonValueText :: Aeson.Value -> Text
jsonValueText = decodeLazyUtf8 . Aeson.encode

-- | Format a tool error as deterministic plain text.
-- This is the contract that assistant/tool tests and the LLM parser expect.
toolError :: Text -> Text
toolError msg = "Error: " <> msg

-- | Format a field-level validation error as deterministic plain text.
-- Includes the invalid value for debuggability.
toolValidationError :: Text -> Text -> Text -> Text
toolValidationError _field msg value = "Error: " <> msg <> ": " <> value
