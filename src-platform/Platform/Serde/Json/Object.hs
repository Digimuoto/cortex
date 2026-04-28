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
