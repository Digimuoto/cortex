{- |
Module      : Cortex.Wire.ContractValidation
Description : Wire contract payload validation against declared schemas.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

ADR 0085's schema-as-type enforcement pass: validates @json@ and @artifact_ref@
payloads against the contract's declared 'wireContractSpecSchema'. The
supported schema dialect is the deliberately narrow subset upstreamed from
Logos (Logos ADR 0015): @type@, @required@, @properties@,
@additionalProperties@ (boolean form only), @items@, @enum@, string
@minLength@\/@maxLength@, and numeric @minimum@\/@maximum@. Unknown keywords
are ignored. Validation is fail-fast with a fixed per-node check order (enum,
type, string bounds, number bounds, object checks, array checks) and errors
carry the contract id plus a JSON path.

Recorded divergence from the Logos incubator: the payload-kind gate accepts
'WirePayloadArtifactRef' in addition to 'WirePayloadJson' (ADR 0085 Decision 1
covers both; the @artifact_ref@ payload validated here is the reference
object), and 'validateWireContractPayload' runs the shallow payload-kind
shape check before schema validation, so the exported validator is never
weaker than runtime egress — an @artifact_ref@ payload must be an object even
if the declared schema would permit otherwise. The keyword readers are exported so the Lean fixture emitter
transcribes schemas through the same parse path that enforcement uses.
'wireContractDialectVersion' mirrors
@Cortex.Wire.ContractValidation.dialectVersion@ on the Lean side.
-}
module Cortex.Wire.ContractValidation
  ( WireContractValidationError (..)
  , WireJsonPath (..)
  , renderWireContractValidationError
  , renderWireJsonPath
  , validateWireContractExamples
  , validateWireContractPayload
  , validateJsonValueAgainstSchema
  , wireContractJsonObjectSchema
  , wireContractDialectVersion
  , schemaTypeValues
  , optionalObjectField
  , optionalTextArrayField
  , optionalBoolField
  , optionalIntegerField
  , optionalNumberField
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)

import Cortex.Wire.Contracts
  ( WireContractRegistry (..)
  , WireContractSpec (..)
  )
import Cortex.Wire.Value
  ( WirePayloadKind (..)
  , renderWirePayloadKind
  , validateWirePayloadShape
  )

{- | Version of the supported schema dialect. Mirrored by the Lean constant
@Cortex.Wire.ContractValidation.dialectVersion@; the emitted fixture
umbrella carries a @#guard@ against this value so a one-sided bump fails
the build.
-}
wireContractDialectVersion :: Natural
wireContractDialectVersion = 1

data WireJsonPath
  = WireJsonPathRoot
  | WireJsonPathProperty WireJsonPath Text
  | WireJsonPathIndex WireJsonPath Int
  deriving stock (Eq, Ord, Show)

data WireContractValidationError
  = WireContractValidationMissingContract Text
  | WireContractValidationNonJsonPayload Text WirePayloadKind
  | WireContractValidationShapeMismatch Text WirePayloadKind Text
  | WireContractValidationMissingSchema Text
  | WireContractValidationInvalidSchema Text WireJsonPath Text
  | WireContractValidationTypeMismatch Text WireJsonPath [Text] Text
  | WireContractValidationRequiredPropertyMissing Text WireJsonPath Text
  | WireContractValidationUnexpectedProperty Text WireJsonPath Text
  | WireContractValidationEnumMismatch Text WireJsonPath Aeson.Value
  | WireContractValidationStringTooShort Text WireJsonPath Int Int
  | WireContractValidationStringTooLong Text WireJsonPath Int Int
  | WireContractValidationNumberTooSmall Text WireJsonPath Scientific Scientific
  | WireContractValidationNumberTooLarge Text WireJsonPath Scientific Scientific
  deriving stock (Eq, Show)

validateWireContractPayload
  :: WireContractRegistry -> Text -> Aeson.Value -> Either WireContractValidationError ()
validateWireContractPayload registry contractId payload = do
  contract <- lookupContract registry contractId
  validatePayloadKind contract
  case validateWirePayloadShape contract.wireContractSpecPayloadKind payload of
    Right () -> Right ()
    Left expectedShape ->
      Left
        ( WireContractValidationShapeMismatch
            contract.wireContractSpecId
            contract.wireContractSpecPayloadKind
            expectedShape
        )
  case contract.wireContractSpecSchema of
    Nothing -> Right ()
    Just schema -> validateSchemaValue contract.wireContractSpecId WireJsonPathRoot schema payload

validateWireContractExamples
  :: WireContractRegistry -> Text -> Either WireContractValidationError ()
validateWireContractExamples registry contractId = do
  contract <- lookupContract registry contractId
  validatePayloadKind contract
  mapM_ (validateWireContractPayload registry contractId) contract.wireContractSpecExamples

{- | Kind-independent core: validate one JSON value against one declared
schema value from the root path. This is the function the node boundary
calls once the payload-kind gate has already been decided elsewhere.
-}
validateJsonValueAgainstSchema
  :: Text -> Aeson.Value -> Aeson.Value -> Either WireContractValidationError ()
validateJsonValueAgainstSchema contractId =
  validateSchemaValue contractId WireJsonPathRoot

wireContractJsonObjectSchema
  :: WireContractRegistry -> Text -> Either WireContractValidationError Aeson.Object
wireContractJsonObjectSchema registry contractId = do
  contract <- lookupContract registry contractId
  validatePayloadKind contract
  case contract.wireContractSpecSchema of
    Nothing -> Left (WireContractValidationMissingSchema contractId)
    Just (Aeson.Object schema) -> do
      schemaTypes <- schemaTypeValues contractId WireJsonPathRoot schema
      case schemaTypes of
        [] ->
          Left
            ( WireContractValidationInvalidSchema
                contractId
                WireJsonPathRoot
                "object schemas must declare type object"
            )
        types
          | "object" `elem` types -> Right schema
          | otherwise ->
              Left
                ( WireContractValidationInvalidSchema
                    contractId
                    WireJsonPathRoot
                    ("object schemas must declare type object, got " <> T.intercalate "|" types)
                )
    Just _ ->
      Left
        (WireContractValidationInvalidSchema contractId WireJsonPathRoot "schema must be a JSON object")

renderWireJsonPath :: WireJsonPath -> Text
renderWireJsonPath path =
  case go path of
    "" -> "$"
    suffix -> "$" <> suffix
  where
    go = \case
      WireJsonPathRoot -> ""
      WireJsonPathProperty parent name -> go parent <> "." <> name
      WireJsonPathIndex parent index -> go parent <> "[" <> T.pack (show index) <> "]"

renderWireContractValidationError :: WireContractValidationError -> Text
renderWireContractValidationError = \case
  WireContractValidationMissingContract contractId ->
    "Wire contract " <> contractId <> " is missing"
  WireContractValidationNonJsonPayload contractId payloadKind ->
    "Wire contract "
      <> contractId
      <> " has payload kind "
      <> renderWirePayloadKind payloadKind
      <> "; schema validation requires a json or artifact_ref payload"
  WireContractValidationShapeMismatch contractId payloadKind expectedShape ->
    "Wire contract "
      <> contractId
      <> " has payload kind "
      <> renderWirePayloadKind payloadKind
      <> " but value shape is invalid; expected "
      <> expectedShape
  WireContractValidationMissingSchema contractId ->
    "Wire contract " <> contractId <> " does not provide a JSON schema"
  WireContractValidationInvalidSchema contractId path detail ->
    "Wire contract "
      <> contractId
      <> " has invalid schema at "
      <> renderWireJsonPath path
      <> ": "
      <> detail
  WireContractValidationTypeMismatch contractId path expected actual ->
    "Wire contract "
      <> contractId
      <> " expected "
      <> T.intercalate "|" expected
      <> " at "
      <> renderWireJsonPath path
      <> ", got "
      <> actual
  WireContractValidationRequiredPropertyMissing contractId path propertyName ->
    "Wire contract "
      <> contractId
      <> " is missing required property "
      <> propertyName
      <> " at "
      <> renderWireJsonPath path
  WireContractValidationUnexpectedProperty contractId path propertyName ->
    "Wire contract "
      <> contractId
      <> " rejected unexpected property "
      <> propertyName
      <> " at "
      <> renderWireJsonPath path
  WireContractValidationEnumMismatch contractId path _ ->
    "Wire contract " <> contractId <> " rejected value outside enum at " <> renderWireJsonPath path
  WireContractValidationStringTooShort contractId path minLen actual ->
    "Wire contract "
      <> contractId
      <> " expected string length >= "
      <> T.pack (show minLen)
      <> " at "
      <> renderWireJsonPath path
      <> ", got "
      <> T.pack (show actual)
  WireContractValidationStringTooLong contractId path maxLen actual ->
    "Wire contract "
      <> contractId
      <> " expected string length <= "
      <> T.pack (show maxLen)
      <> " at "
      <> renderWireJsonPath path
      <> ", got "
      <> T.pack (show actual)
  WireContractValidationNumberTooSmall contractId path minValue actual ->
    "Wire contract "
      <> contractId
      <> " expected number >= "
      <> renderScientific minValue
      <> " at "
      <> renderWireJsonPath path
      <> ", got "
      <> renderScientific actual
  WireContractValidationNumberTooLarge contractId path maxValue actual ->
    "Wire contract "
      <> contractId
      <> " expected number <= "
      <> renderScientific maxValue
      <> " at "
      <> renderWireJsonPath path
      <> ", got "
      <> renderScientific actual

lookupContract
  :: WireContractRegistry -> Text -> Either WireContractValidationError WireContractSpec
lookupContract registry contractId =
  maybe
    (Left (WireContractValidationMissingContract contractId))
    Right
    (Map.lookup contractId registry.wireContractRegistryContracts)

{- | Payload-kind gate. Divergence from the Logos incubator (recorded per ADR
0085): @artifact_ref@ is accepted alongside @json@ — the reference object
is the payload the schema describes.
-}
validatePayloadKind :: WireContractSpec -> Either WireContractValidationError ()
validatePayloadKind contract =
  case contract.wireContractSpecPayloadKind of
    WirePayloadJson -> Right ()
    WirePayloadArtifactRef -> Right ()
    payloadKind -> Left (WireContractValidationNonJsonPayload contract.wireContractSpecId payloadKind)

validateSchemaValue
  :: Text -> WireJsonPath -> Aeson.Value -> Aeson.Value -> Either WireContractValidationError ()
validateSchemaValue contractId schemaPath schemaValue payload =
  case schemaValue of
    Aeson.Object schema -> do
      validateEnum contractId schemaPath schema payload
      validateType contractId schemaPath schema payload
      validateStringBounds contractId schemaPath schema payload
      validateNumberBounds contractId schemaPath schema payload
      validateObjectPayload contractId schemaPath schema payload
      validateArrayPayload contractId schemaPath schema payload
    _ -> Left (WireContractValidationInvalidSchema contractId schemaPath "schema node must be an object")

validateEnum
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateEnum contractId schemaPath schema payload =
  case KeyMap.lookup "enum" schema of
    Nothing -> Right ()
    Just (Aeson.Array allowed)
      | payload `elem` allowed -> Right ()
      | otherwise -> Left (WireContractValidationEnumMismatch contractId schemaPath payload)
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath "enum")
            "enum must be an array"
        )

validateType
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateType contractId schemaPath schema payload = do
  types <- schemaTypeValues contractId schemaPath schema
  if null types || any (`valueMatchesType` payload) types
    then Right ()
    else Left (WireContractValidationTypeMismatch contractId schemaPath types (valueTypeName payload))

validateStringBounds
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateStringBounds contractId schemaPath schema payload =
  case payload of
    Aeson.String txt -> do
      minimumLength <- optionalIntegerField contractId schemaPath "minLength" schema
      maximumLength <- optionalIntegerField contractId schemaPath "maxLength" schema
      let actualLength = T.length txt
      case minimumLength of
        Just minLen
          | actualLength < minLen ->
              Left (WireContractValidationStringTooShort contractId schemaPath minLen actualLength)
        _ -> Right ()
      case maximumLength of
        Just maxLen
          | actualLength > maxLen ->
              Left (WireContractValidationStringTooLong contractId schemaPath maxLen actualLength)
        _ -> Right ()
    _ -> Right ()

validateNumberBounds
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateNumberBounds contractId schemaPath schema payload =
  case payload of
    Aeson.Number actual -> do
      minimumValue <- optionalNumberField contractId schemaPath "minimum" schema
      maximumValue <- optionalNumberField contractId schemaPath "maximum" schema
      case minimumValue of
        Just minValue
          | actual < minValue ->
              Left (WireContractValidationNumberTooSmall contractId schemaPath minValue actual)
        _ -> Right ()
      case maximumValue of
        Just maxValue
          | actual > maxValue ->
              Left (WireContractValidationNumberTooLarge contractId schemaPath maxValue actual)
        _ -> Right ()
    _ -> Right ()

validateObjectPayload
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateObjectPayload contractId schemaPath schema payload =
  case payload of
    Aeson.Object obj -> do
      properties <- optionalObjectField contractId schemaPath "properties" schema
      required <- optionalTextArrayField contractId schemaPath "required" schema
      additionalProperties <- optionalBoolField contractId schemaPath "additionalProperties" schema
      mapM_ (validateRequired obj) required
      mapM_ (validateProperty properties additionalProperties) (KeyMap.toList obj)
    _ -> Right ()
  where
    validateRequired obj requiredKey =
      if KeyMap.member (Key.fromText requiredKey) obj
        then Right ()
        else Left (WireContractValidationRequiredPropertyMissing contractId schemaPath requiredKey)
    validateProperty properties additionalProperties (key, value) =
      case KeyMap.lookup key properties of
        Just propertySchema ->
          validateSchemaValue
            contractId
            (WireJsonPathProperty schemaPath (Key.toText key))
            propertySchema
            value
        Nothing ->
          case additionalProperties of
            Just False -> Left (WireContractValidationUnexpectedProperty contractId schemaPath (Key.toText key))
            _ -> Right ()

validateArrayPayload
  :: Text -> WireJsonPath -> Aeson.Object -> Aeson.Value -> Either WireContractValidationError ()
validateArrayPayload contractId schemaPath schema payload =
  case payload of
    Aeson.Array values ->
      case KeyMap.lookup "items" schema of
        Nothing -> Right ()
        Just itemSchema ->
          mapM_
            ( \(index, value) ->
                validateSchemaValue contractId (WireJsonPathIndex schemaPath index) itemSchema value
            )
            (zip [0 ..] (Vector.toList values))
    _ -> Right ()

schemaTypeValues
  :: Text -> WireJsonPath -> Aeson.Object -> Either WireContractValidationError [Text]
schemaTypeValues contractId schemaPath schema =
  case KeyMap.lookup "type" schema of
    Nothing -> Right []
    Just (Aeson.String schemaType) -> Right [schemaType]
    Just (Aeson.Array values) -> traverse parseType (toList values)
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath "type")
            "type must be a string or array of strings"
        )
  where
    parseType (Aeson.String schemaType) = Right schemaType
    parseType _ =
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath "type")
            "type array must contain only strings"
        )

optionalObjectField
  :: Text -> WireJsonPath -> Text -> Aeson.Object -> Either WireContractValidationError Aeson.Object
optionalObjectField contractId schemaPath fieldName schema =
  case KeyMap.lookup (Key.fromText fieldName) schema of
    Nothing -> Right KeyMap.empty
    Just (Aeson.Object obj) -> Right obj
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath fieldName)
            (fieldName <> " must be an object")
        )

optionalTextArrayField
  :: Text -> WireJsonPath -> Text -> Aeson.Object -> Either WireContractValidationError [Text]
optionalTextArrayField contractId schemaPath fieldName schema =
  case KeyMap.lookup (Key.fromText fieldName) schema of
    Nothing -> Right []
    Just (Aeson.Array values) -> traverse parseText (toList values)
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath fieldName)
            (fieldName <> " must be an array")
        )
  where
    parseText (Aeson.String txt) = Right txt
    parseText _ =
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath fieldName)
            (fieldName <> " must contain only strings")
        )

optionalBoolField
  :: Text -> WireJsonPath -> Text -> Aeson.Object -> Either WireContractValidationError (Maybe Bool)
optionalBoolField contractId schemaPath fieldName schema =
  case KeyMap.lookup (Key.fromText fieldName) schema of
    Nothing -> Right Nothing
    Just (Aeson.Bool flag) -> Right (Just flag)
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath fieldName)
            (fieldName <> " must be a boolean")
        )

optionalIntegerField
  :: Text -> WireJsonPath -> Text -> Aeson.Object -> Either WireContractValidationError (Maybe Int)
optionalIntegerField contractId schemaPath fieldName schema =
  case KeyMap.lookup (Key.fromText fieldName) schema of
    Nothing -> Right Nothing
    Just (Aeson.Number value) ->
      maybe
        (Left (invalidNumber "must be an integer"))
        (Right . Just)
        (Scientific.toBoundedInteger value)
    Just _ -> Left (invalidNumber "must be a number")
  where
    invalidNumber detail =
      WireContractValidationInvalidSchema
        contractId
        (WireJsonPathProperty schemaPath fieldName)
        (fieldName <> " " <> detail)

optionalNumberField
  :: Text
  -> WireJsonPath
  -> Text
  -> Aeson.Object
  -> Either WireContractValidationError (Maybe Scientific)
optionalNumberField contractId schemaPath fieldName schema =
  case KeyMap.lookup (Key.fromText fieldName) schema of
    Nothing -> Right Nothing
    Just (Aeson.Number value) -> Right (Just value)
    Just _ ->
      Left
        ( WireContractValidationInvalidSchema
            contractId
            (WireJsonPathProperty schemaPath fieldName)
            (fieldName <> " must be a number")
        )

valueMatchesType :: Text -> Aeson.Value -> Bool
valueMatchesType schemaType value =
  case (schemaType, value) of
    ("object", Aeson.Object _) -> True
    ("array", Aeson.Array _) -> True
    ("string", Aeson.String _) -> True
    ("number", Aeson.Number _) -> True
    ("integer", Aeson.Number number) -> Scientific.isInteger number
    ("boolean", Aeson.Bool _) -> True
    ("null", Aeson.Null) -> True
    _ -> False

valueTypeName :: Aeson.Value -> Text
valueTypeName = \case
  Aeson.Object _ -> "object"
  Aeson.Array _ -> "array"
  Aeson.String _ -> "string"
  Aeson.Number number
    | Scientific.isInteger number -> "integer"
    | otherwise -> "number"
  Aeson.Bool _ -> "boolean"
  Aeson.Null -> "null"

renderScientific :: Scientific -> Text
renderScientific =
  T.pack . Scientific.formatScientific Scientific.Generic Nothing
