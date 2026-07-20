{- |
Module      : Cortex.Wire.NativePure.Shape
Description : Bounded native representations for certified PureWire kernels.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

@native_shape@ is a representation contract, separate from value-level JSON
schema validation.  Every recursive position is structurally finite and every
variable-size value carries an explicit capacity.
-}
module Cortex.Wire.NativePure.Shape
  ( NativeShape (..)
  , NativeShapeProjection (..)
  , NativeLayout (..)
  , NativeShapeError (..)
  , nativeShapeProjectionSchema
  , nativeShapeLayout
  , renderNativeShapeError
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM, when)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32, Word64)

nativeShapeProjectionSchema :: Text
nativeShapeProjectionSchema = "cortex.wire.native-shape/v1"

-- | Closed, bounded representation algebra admitted by NativePure v1.
data NativeShape
  = NativeUnit
  | NativeBool
  | NativeI64
  | NativeU64
  | NativeF64
  | NativeText !Word32
  | NativeVector !Word32 !NativeShape
  | NativeRecord !(Map Text NativeShape)
  | NativeSum !(Map Text NativeShape)
  deriving stock (Eq, Show)

-- | Versioned registered-contract representation projection.
data NativeShapeProjection = NativeShapeProjection
  { nativeShapeProjectionShape :: !NativeShape
  }
  deriving stock (Eq, Show)

-- | Size and alignment of one generated C representation.
data NativeLayout = NativeLayout
  { nativeLayoutSize :: !Word64
  , nativeLayoutAlignment :: !Word64
  }
  deriving stock (Eq, Show)

data NativeShapeError
  = NativeShapeEmptyRecord
  | NativeShapeEmptySum
  | NativeShapeEmptyFieldName
  | NativeShapeZeroCapacity !Text
  | NativeShapeLayoutOverflow
  deriving stock (Eq, Show)

renderNativeShapeError :: NativeShapeError -> Text
renderNativeShapeError = \case
  NativeShapeEmptyRecord -> "native record shape must contain at least one field"
  NativeShapeEmptySum -> "native sum shape must contain at least one variant"
  NativeShapeEmptyFieldName -> "native record and sum labels must not be empty"
  NativeShapeZeroCapacity kind -> kind <> " native shape requires a positive capacity"
  NativeShapeLayoutOverflow -> "native shape layout exceeds uint64_t"

instance ToJSON NativeShape where
  toJSON = \case
    NativeUnit -> Aeson.String "unit"
    NativeBool -> Aeson.String "bool"
    NativeI64 -> Aeson.String "i64"
    NativeU64 -> Aeson.String "u64"
    NativeF64 -> Aeson.String "f64"
    NativeText capacity ->
      Aeson.object ["kind" .= ("text" :: Text), "capacity" .= capacity]
    NativeVector capacity elementShape ->
      Aeson.object
        [ "kind" .= ("vector" :: Text)
        , "capacity" .= capacity
        , "element" .= elementShape
        ]
    NativeRecord fields ->
      Aeson.object ["kind" .= ("record" :: Text), "fields" .= fields]
    NativeSum variants ->
      Aeson.object ["kind" .= ("sum" :: Text), "variants" .= variants]

instance ToJSON NativeShapeProjection where
  toJSON projection =
    Aeson.object
      [ "schema" .= nativeShapeProjectionSchema
      , "shape" .= projection.nativeShapeProjectionShape
      ]

instance FromJSON NativeShapeProjection where
  parseJSON = Aeson.withObject "NativeShapeProjection" $ \objectValue -> do
    let actual = sort (fmap Key.toText (KeyMap.keys objectValue))
    if actual /= ["schema", "shape"]
      then fail "native_shape projection fields must be exactly: schema, shape"
      else do
        schema <- objectValue .: "schema"
        if schema /= nativeShapeProjectionSchema
          then fail ("unsupported native_shape schema: " <> T.unpack schema)
          else do
            shape <- objectValue .: "shape"
            case nativeShapeLayout shape of
              Left shapeError -> fail (T.unpack (renderNativeShapeError shapeError))
              Right _layout -> pure (NativeShapeProjection shape)

instance FromJSON NativeShape where
  parseJSON value = parseScalar value <|> parseComposite value
    where
      parseScalar = Aeson.withText "NativeShape" $ \raw ->
        case T.toCaseFold (T.strip raw) of
          "unit" -> pure NativeUnit
          "bool" -> pure NativeBool
          "i64" -> pure NativeI64
          "u64" -> pure NativeU64
          "f64" -> pure NativeF64
          other -> fail ("unknown native shape: " <> T.unpack other)

      parseComposite = Aeson.withObject "NativeShape" $ \objectValue -> do
        kind <- objectValue .: "kind"
        case T.toCaseFold (T.strip kind) of
          "text" -> do
            exactKeys ["kind", "capacity"] objectValue
            NativeText <$> positiveCapacity "text" objectValue
          "vector" -> do
            exactKeys ["kind", "capacity", "element"] objectValue
            NativeVector
              <$> positiveCapacity "vector" objectValue
              <*> objectValue .: "element"
          "record" -> do
            exactKeys ["kind", "fields"] objectValue
            NativeRecord <$> objectValue .: "fields"
          "sum" -> do
            exactKeys ["kind", "variants"] objectValue
            NativeSum <$> objectValue .: "variants"
          "option" -> do
            exactKeys ["kind", "payload"] objectValue
            payload <- objectValue .: "payload"
            pure (NativeSum (Map.fromList [("none", NativeUnit), ("some", payload)]))
          other -> fail ("unknown native shape kind: " <> T.unpack other)

      positiveCapacity kind objectValue = do
        capacity <- objectValue .: "capacity"
        if capacity == (0 :: Word32)
          then fail (T.unpack kind <> " native shape requires a positive capacity")
          else pure capacity

      exactKeys expected objectValue =
        let actual = sort (fmap Key.toText (KeyMap.keys objectValue))
            canonicalExpected = sort expected
         in if actual == canonicalExpected
              then pure ()
              else
                fail
                  ( "native shape "
                      <> T.unpack kindForDiagnostic
                      <> " fields must be exactly: "
                      <> T.unpack (T.intercalate ", " canonicalExpected)
                  )
        where
          kindForDiagnostic =
            case KeyMap.lookup "kind" objectValue of
              Just (Aeson.String shapeKind) -> shapeKind
              _ -> "object"

-- | Compute the fixed C layout, including record and tagged-sum padding.
nativeShapeLayout :: NativeShape -> Either NativeShapeError NativeLayout
nativeShapeLayout = \case
  NativeUnit -> pure (NativeLayout 1 1)
  NativeBool -> pure (NativeLayout 1 1)
  NativeI64 -> pure (NativeLayout 8 8)
  NativeU64 -> pure (NativeLayout 8 8)
  NativeF64 -> pure (NativeLayout 8 8)
  NativeText capacity -> do
    when (capacity == 0) (Left (NativeShapeZeroCapacity "text"))
    -- uint32_t length followed by capacity bytes.
    size <- checkedAdd 4 (fromIntegral capacity)
    aligned <- alignUp size 4
    pure (NativeLayout aligned 4)
  NativeVector capacity elementShape -> do
    when (capacity == 0) (Left (NativeShapeZeroCapacity "vector"))
    elementLayout <- nativeShapeLayout elementShape
    payload <- checkedMultiply (fromIntegral capacity) elementLayout.nativeLayoutSize
    size <- checkedAdd 4 payload
    aligned <- alignUp size (max 4 elementLayout.nativeLayoutAlignment)
    pure
      ( NativeLayout
          aligned
          (max 4 elementLayout.nativeLayoutAlignment)
      )
  NativeRecord fields -> do
    validateFields NativeShapeEmptyRecord fields
    (size, alignment) <- foldM appendField (0, 1) (Map.elems fields)
    aligned <- alignUp size alignment
    pure (NativeLayout aligned alignment)
  NativeSum variants -> do
    validateFields NativeShapeEmptySum variants
    layouts <- traverse nativeShapeLayout (Map.elems variants)
    let payloadAlignment = maximum (1 : fmap (.nativeLayoutAlignment) layouts)
        payloadSize = maximum (0 : fmap (.nativeLayoutSize) layouts)
        alignment = max 4 payloadAlignment
    payloadOffset <- alignUp 4 payloadAlignment
    total <- checkedAdd payloadOffset payloadSize
    aligned <- alignUp total alignment
    pure (NativeLayout aligned alignment)
  where
    validateFields emptyError fields = do
      when (Map.null fields) (Left emptyError)
      when (any (T.null . T.strip) (Map.keys fields)) (Left NativeShapeEmptyFieldName)

    appendField (offset, aggregateAlignment) fieldShape = do
      fieldLayout <- nativeShapeLayout fieldShape
      fieldOffset <- alignUp offset fieldLayout.nativeLayoutAlignment
      nextOffset <- checkedAdd fieldOffset fieldLayout.nativeLayoutSize
      pure (nextOffset, max aggregateAlignment fieldLayout.nativeLayoutAlignment)

checkedAdd :: Word64 -> Word64 -> Either NativeShapeError Word64
checkedAdd left right
  | maxBound - left < right = Left NativeShapeLayoutOverflow
  | otherwise = Right (left + right)

checkedMultiply :: Word64 -> Word64 -> Either NativeShapeError Word64
checkedMultiply left right
  | left /= 0 && maxBound `div` left < right = Left NativeShapeLayoutOverflow
  | otherwise = Right (left * right)

alignUp :: Word64 -> Word64 -> Either NativeShapeError Word64
alignUp value alignment
  | alignment <= 1 = Right value
  | otherwise = checkedAdd value ((alignment - (value `mod` alignment)) `mod` alignment)
