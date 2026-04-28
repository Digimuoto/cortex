{- |
Module      : Platform.Serde.Json.Object
Description : Platform runtime support for object.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Serde.Json.Object
  ( hasObjectBool
  , lookupObjectArray
  , lookupObjectText
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Vector qualified as V

hasObjectBool :: Text -> KeyMap.KeyMap Aeson.Value -> Bool
hasObjectBool fieldName obj =
  case KeyMap.lookup (Key.fromText fieldName) obj of
    Just (Aeson.Bool boolValue) -> boolValue
    _ -> False

lookupObjectText :: Text -> KeyMap.KeyMap Aeson.Value -> Maybe Text
lookupObjectText fieldName obj =
  case KeyMap.lookup (Key.fromText fieldName) obj of
    Just (Aeson.String textValue) -> Just textValue
    _ -> Nothing

lookupObjectArray :: Text -> KeyMap.KeyMap Aeson.Value -> Maybe [Aeson.Value]
lookupObjectArray fieldName obj =
  case KeyMap.lookup (Key.fromText fieldName) obj of
    Just (Aeson.Array values) -> Just (V.toList values)
    _ -> Nothing
