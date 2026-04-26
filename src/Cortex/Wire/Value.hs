{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.Value
  ( WirePayloadKind (..),
    renderWirePayloadKind,
    parseWirePayloadKindText,
    wirePayloadKindMediaType,
    describeWirePayloadKindShape,
    validateWirePayloadShape,
    WireValue (..),
    WireValueSet (..),
    mkWireValue,
    singletonWireValueSet,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data WirePayloadKind
  = WirePayloadJson
  | WirePayloadMarkdown
  | WirePayloadText
  | WirePayloadTable
  | WirePayloadArtifactRef
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON WirePayloadKind where
  toJSON =
    Aeson.String . renderWirePayloadKind

instance FromJSON WirePayloadKind where
  parseJSON = Aeson.withText "WirePayloadKind" $ \rawValue ->
    case parseWirePayloadKindText rawValue of
      Just payloadKind -> pure payloadKind
      Nothing -> fail ("Unknown Wire payload kind: " <> T.unpack rawValue)

renderWirePayloadKind :: WirePayloadKind -> Text
renderWirePayloadKind = \case
  WirePayloadJson -> "json"
  WirePayloadMarkdown -> "markdown"
  WirePayloadText -> "text"
  WirePayloadTable -> "table"
  WirePayloadArtifactRef -> "artifact_ref"

parseWirePayloadKindText :: Text -> Maybe WirePayloadKind
parseWirePayloadKindText rawValue =
  case T.toCaseFold (T.strip rawValue) of
    "json" -> Just WirePayloadJson
    "markdown" -> Just WirePayloadMarkdown
    "text" -> Just WirePayloadText
    "table" -> Just WirePayloadTable
    "artifact_ref" -> Just WirePayloadArtifactRef
    "artifactref" -> Just WirePayloadArtifactRef
    _ -> Nothing

wirePayloadKindMediaType :: WirePayloadKind -> Text
wirePayloadKindMediaType = \case
  WirePayloadJson -> "application/json"
  WirePayloadMarkdown -> "text/markdown"
  WirePayloadText -> "text/plain"
  WirePayloadTable -> "application/vnd.cortex.table+json"
  WirePayloadArtifactRef -> "application/vnd.cortex.artifact-ref+json"

describeWirePayloadKindShape :: WirePayloadKind -> Text
describeWirePayloadKindShape = \case
  WirePayloadJson -> "any valid JSON value"
  WirePayloadMarkdown -> "a JSON string"
  WirePayloadText -> "a JSON string"
  WirePayloadTable -> "a JSON object or array"
  WirePayloadArtifactRef -> "a JSON object"

validateWirePayloadShape :: WirePayloadKind -> Aeson.Value -> Either Text ()
validateWirePayloadShape payloadKind value =
  case payloadKind of
    WirePayloadJson ->
      Right ()
    WirePayloadMarkdown ->
      requireString
    WirePayloadText ->
      requireString
    WirePayloadTable ->
      case value of
        Aeson.Object _ -> Right ()
        Aeson.Array _ -> Right ()
        _ -> Left expectedShape
    WirePayloadArtifactRef ->
      case value of
        Aeson.Object _ -> Right ()
        _ -> Left expectedShape
  where
    requireString =
      case value of
        Aeson.String _ -> Right ()
        _ -> Left expectedShape
    expectedShape =
      describeWirePayloadKindShape payloadKind

data WireValue = WireValue
  { wireValueContract :: !Text,
    wireValuePort :: !(Maybe Text),
    wireValuePayloadKind :: !WirePayloadKind,
    wireValueMediaType :: !Text,
    wireValueProducer :: !(Maybe Text),
    wireValueValue :: !Aeson.Value,
    wireValueProvenance :: !(Maybe Aeson.Value)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WireValue where
  toJSON wireValue =
    Aeson.object
      [ "contract" .= wireValue.wireValueContract,
        "port" .= wireValue.wireValuePort,
        "payloadKind" .= renderWirePayloadKind wireValue.wireValuePayloadKind,
        "mediaType" .= wireValue.wireValueMediaType,
        "producer" .= wireValue.wireValueProducer,
        "value" .= wireValue.wireValueValue,
        "provenance" .= wireValue.wireValueProvenance
      ]

instance FromJSON WireValue where
  parseJSON = Aeson.withObject "WireValue" $ \obj -> do
    payloadKind <- obj .: "payloadKind"
    WireValue
      <$> obj .: "contract"
      <*> obj .:? "port"
      <*> pure payloadKind
      <*> obj .:? "mediaType" Aeson..!= wirePayloadKindMediaType payloadKind
      <*> obj .:? "producer"
      <*> obj .: "value"
      <*> obj .:? "provenance"

newtype WireValueSet = WireValueSet
  { wireValueSetValues :: [WireValue]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WireValueSet where
  toJSON valueSet =
    Aeson.object
      [ "values" .= valueSet.wireValueSetValues
      ]

instance FromJSON WireValueSet where
  parseJSON = Aeson.withObject "WireValueSet" $ \obj ->
    WireValueSet <$> obj .: "values"

mkWireValue :: Text -> WirePayloadKind -> Maybe Text -> Aeson.Value -> WireValue
mkWireValue contract payloadKind producer value =
  WireValue
    { wireValueContract = contract,
      wireValuePort = Nothing,
      wireValuePayloadKind = payloadKind,
      wireValueMediaType = wirePayloadKindMediaType payloadKind,
      wireValueProducer = producer,
      wireValueValue = value,
      wireValueProvenance = Nothing
    }

singletonWireValueSet :: WireValue -> WireValueSet
singletonWireValueSet wireValue =
  WireValueSet [wireValue]
