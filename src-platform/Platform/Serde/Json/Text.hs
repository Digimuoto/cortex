{- |
Module      : Platform.Serde.Json.Text
Description : Platform runtime support for text.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Serde.Json.Text
  ( decodeLazyUtf8
  , jsonValueText
  , toolError
  , toolValidationError
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
toolError :: Text -> Text
toolError msg = "Error: " <> msg

-- | Format a field-level validation error as deterministic plain text.
toolValidationError :: Text -> Text -> Text -> Text
toolValidationError _field msg value = "Error: " <> msg <> ": " <> value
