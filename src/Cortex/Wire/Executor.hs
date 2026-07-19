{- |
Module      : Cortex.Wire.Executor
Description : Source-level executor references and compile-time executor projections.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Wire only needs the structural projection of registered executor authority:
identity, ports, vocabulary, config shape, and effect metadata. Runnable host
authority lives in 'Cortex.Capability.Executor'.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Executor
  ( WireExecutor (..)
  , WireExecutorId (..)
  , wireExecutorIdToText
  , wireExecutorIdFromWireExecutor
  , WireExecutorEffect (..)
  , WireExecutorConfigShape (..)
  , WireExecutorArgumentShape (..)
  , WireExecutorArgumentBindingTime (..)
  , wireExecutorArgumentShapeFromConfigShape
  , wireExecutorConfigShapeFromArgumentShape
  , wireExecutorArgumentBindingTimes
  , wireExecutorArgumentStaticFields
  , wireExecutorArgumentIngressShape
  , wireExecutorArgumentStaticShape
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , wireExecutorProjectionArgumentShape
  , wireExecutorProjectionIngressShape
  , wireExecutorProjectionWithArgumentShape
  , wireExecutorProjectionFromPorts
  , wireContractsFromPorts
  , WireExecutorRegistry (..)
  , emptyWireExecutorRegistry
  , wireExecutorRegistryFromList
  , lookupWireExecutorProjection
  , wireExecutorRegistryVocabulary
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

import Cortex.Wire.AST
  ( WireExecutor (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )

newtype WireExecutorId = WireExecutorId {unWireExecutorId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Aeson.ToJSON, Aeson.FromJSON)

wireExecutorIdToText :: WireExecutorId -> Text
wireExecutorIdToText = unWireExecutorId

wireExecutorIdFromWireExecutor :: WireExecutor -> WireExecutorId
wireExecutorIdFromWireExecutor = \case
  WireExecutorNative targetId -> WireExecutorId targetId

data WireExecutorEffect
  = WireExecutorPure
  | WireExecutorModel
  | WireExecutorHostEffect
  | WireExecutorImpure
  deriving stock (Eq, Show, Generic)

data WireExecutorConfigShape
  = WireExecutorConfigUnchecked
  | WireExecutorConfigSchema Aeson.Value
  deriving stock (Eq, Show, Generic)

{- | Canonical one-record executor ingress shape. The config-named type remains
as a compatibility view until the final Wire migration.
-}
data WireExecutorArgumentShape
  = WireExecutorArgumentUnchecked
  | WireExecutorArgumentSchema Aeson.Value
  deriving stock (Eq, Show, Generic)

{- | Availability required by one top-level field of the executor's single
argument record. Fields default to ingress; an executor projection may mark a
declared property with @x-cortex-binding-time = "admission"@.
-}
data WireExecutorArgumentBindingTime
  = WireExecutorArgumentAdmission
  | WireExecutorArgumentIngress
  deriving stock (Eq, Ord, Show, Generic)

wireExecutorArgumentShapeFromConfigShape :: WireExecutorConfigShape -> WireExecutorArgumentShape
wireExecutorArgumentShapeFromConfigShape = \case
  WireExecutorConfigUnchecked -> WireExecutorArgumentUnchecked
  WireExecutorConfigSchema schema -> WireExecutorArgumentSchema schema

wireExecutorConfigShapeFromArgumentShape :: WireExecutorArgumentShape -> WireExecutorConfigShape
wireExecutorConfigShapeFromArgumentShape = \case
  WireExecutorArgumentUnchecked -> WireExecutorConfigUnchecked
  WireExecutorArgumentSchema schema -> WireExecutorConfigSchema schema

{- | Read the total top-level binding-time partition from one authoritative
argument schema. Unknown fields remain an ordinary schema concern; every
declared property without an annotation is runtime ingress data.
-}
wireExecutorArgumentBindingTimes
  :: WireExecutorArgumentShape -> Either Text (Map Text WireExecutorArgumentBindingTime)
wireExecutorArgumentBindingTimes = \case
  WireExecutorArgumentUnchecked -> Right Map.empty
  WireExecutorArgumentSchema schema -> do
    root <- expectObject "executor argument schema" schema
    properties <- optionalObject "properties" root
    Map.fromList <$> traverse propertyBindingTime (KeyMap.toList properties)
  where
    propertyBindingTime (propertyKey, propertySchema) = do
      let propertyName = Key.toText propertyKey
      bindingTime <- case propertySchema of
        Aeson.Object object ->
          case KeyMap.lookup bindingTimeKey object of
            Nothing -> Right WireExecutorArgumentIngress
            Just (Aeson.String raw) ->
              case T.toCaseFold (T.strip raw) of
                "admission" -> Right WireExecutorArgumentAdmission
                "ingress" -> Right WireExecutorArgumentIngress
                other ->
                  Left
                    ( "executor argument property "
                        <> propertyName
                        <> " has unknown x-cortex-binding-time "
                        <> other
                    )
            Just _ ->
              Left
                ( "executor argument property "
                    <> propertyName
                    <> " must declare x-cortex-binding-time as a string"
                )
        _ -> Right WireExecutorArgumentIngress
      Right (propertyName, bindingTime)

    bindingTimeKey = Key.fromText "x-cortex-binding-time"

wireExecutorArgumentStaticFields
  :: WireExecutorArgumentShape -> Either Text (Set Text)
wireExecutorArgumentStaticFields shape =
  Map.keysSet . Map.filter (== WireExecutorArgumentAdmission)
    <$> wireExecutorArgumentBindingTimes shape

{- | Schema for the residual record delivered at runtime after admission
fields have been specialized out.
-}
wireExecutorArgumentIngressShape
  :: WireExecutorArgumentShape -> Either Text WireExecutorArgumentShape
wireExecutorArgumentIngressShape =
  partitionArgumentShape (== WireExecutorArgumentIngress) False

{- | Schema for the record evaluated and validated during admission. It is
closed even when the complete argument schema permits additional properties,
because the compiler constructs this record solely from declared static fields.
-}
wireExecutorArgumentStaticShape
  :: WireExecutorArgumentShape -> Either Text WireExecutorArgumentShape
wireExecutorArgumentStaticShape =
  partitionArgumentShape (== WireExecutorArgumentAdmission) True

partitionArgumentShape
  :: (WireExecutorArgumentBindingTime -> Bool)
  -> Bool
  -> WireExecutorArgumentShape
  -> Either Text WireExecutorArgumentShape
partitionArgumentShape _select _closeObject WireExecutorArgumentUnchecked =
  Right WireExecutorArgumentUnchecked
partitionArgumentShape select closeObject original@(WireExecutorArgumentSchema schema) = do
  root <- expectObject "executor argument schema" schema
  properties <- optionalObject "properties" root
  bindingTimes <- wireExecutorArgumentBindingTimes original
  required <- optionalRequired root
  let selectedNames = Map.keysSet (Map.filter select bindingTimes)
      selectedProperties =
        KeyMap.filterWithKey (\key _ -> Key.toText key `Set.member` selectedNames) properties
      selectedRequired = filter (`Set.member` selectedNames) required
      withProperties = KeyMap.insert (Key.fromText "properties") (Aeson.Object selectedProperties) root
      withRequired =
        KeyMap.insert
          (Key.fromText "required")
          (Aeson.Array (Vector.fromList (fmap Aeson.String selectedRequired)))
          withProperties
      partitioned =
        if closeObject
          then KeyMap.insert (Key.fromText "additionalProperties") (Aeson.Bool False) withRequired
          else withRequired
  Right (WireExecutorArgumentSchema (Aeson.Object partitioned))

expectObject :: Text -> Aeson.Value -> Either Text Aeson.Object
expectObject label = \case
  Aeson.Object object -> Right object
  _ -> Left (label <> " must be an object")

optionalObject :: Text -> Aeson.Object -> Either Text Aeson.Object
optionalObject fieldName object =
  case KeyMap.lookup (Key.fromText fieldName) object of
    Nothing -> Right KeyMap.empty
    Just (Aeson.Object value) -> Right value
    Just _ -> Left ("executor argument schema " <> fieldName <> " must be an object")

optionalRequired :: Aeson.Object -> Either Text [Text]
optionalRequired object =
  case KeyMap.lookup (Key.fromText "required") object of
    Nothing -> Right []
    Just (Aeson.Array values) -> traverse requiredName (Vector.toList values)
    Just _ -> Left "executor argument schema required must be an array of strings"
  where
    requiredName = \case
      Aeson.String name -> Right name
      _ -> Left "executor argument schema required must contain only strings"

data WireExecutorPortPolicy
  = WireExecutorFixedPorts
  | WireExecutorAuthorDeclaredPorts
  deriving stock (Eq, Show, Generic)

data WireExecutorProjection = WireExecutorProjection
  { wireExecutorProjectionId :: !WireExecutorId
  , wireExecutorProjectionPorts :: !WirePorts
  , wireExecutorProjectionVocabulary :: !(Set Text)
  , wireExecutorProjectionEffect :: !WireExecutorEffect
  , wireExecutorProjectionConfigShape :: !WireExecutorConfigShape
  , wireExecutorProjectionPortPolicy :: !WireExecutorPortPolicy
  }
  deriving stock (Eq, Show, Generic)

{- | Canonical argument-facing view of a projection. It is computed from the
retained config field so existing record construction remains source-compatible.
-}
wireExecutorProjectionArgumentShape :: WireExecutorProjection -> WireExecutorArgumentShape
wireExecutorProjectionArgumentShape =
  wireExecutorArgumentShapeFromConfigShape . wireExecutorProjectionConfigShape

wireExecutorProjectionIngressShape
  :: WireExecutorProjection -> Either Text WireExecutorArgumentShape
wireExecutorProjectionIngressShape =
  wireExecutorArgumentIngressShape . wireExecutorProjectionArgumentShape

wireExecutorProjectionWithArgumentShape
  :: WireExecutorArgumentShape -> WireExecutorProjection -> WireExecutorProjection
wireExecutorProjectionWithArgumentShape shape projection =
  projection
    { wireExecutorProjectionConfigShape = wireExecutorConfigShapeFromArgumentShape shape
    }

wireExecutorProjectionFromPorts
  :: WireExecutorId
  -> WirePorts
  -> WireExecutorEffect
  -> WireExecutorProjection
wireExecutorProjectionFromPorts executorId ports effect =
  WireExecutorProjection
    { wireExecutorProjectionId = executorId
    , wireExecutorProjectionPorts = ports
    , wireExecutorProjectionVocabulary = wireContractsFromPorts ports
    , wireExecutorProjectionEffect = effect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorFixedPorts
    }

wireContractsFromPorts :: WirePorts -> Set Text
wireContractsFromPorts ports =
  Set.fromList $
    concatMap (.wireInputPortAccepts) (Map.elems ports.wirePortsInputs)
      <> fmap (.wireOutputPortContract) (Map.elems ports.wirePortsOutputs)

newtype WireExecutorRegistry = WireExecutorRegistry
  { wireExecutorRegistryProjections :: Map WireExecutorId WireExecutorProjection
  }
  deriving stock (Eq, Show, Generic)

emptyWireExecutorRegistry :: WireExecutorRegistry
emptyWireExecutorRegistry =
  WireExecutorRegistry Map.empty

wireExecutorRegistryFromList :: [WireExecutorProjection] -> WireExecutorRegistry
wireExecutorRegistryFromList projections =
  WireExecutorRegistry
    (Map.fromList [(projection.wireExecutorProjectionId, projection) | projection <- projections])

lookupWireExecutorProjection
  :: WireExecutorId -> WireExecutorRegistry -> Maybe WireExecutorProjection
lookupWireExecutorProjection executorId registry =
  Map.lookup executorId registry.wireExecutorRegistryProjections

wireExecutorRegistryVocabulary :: WireExecutorRegistry -> Set Text
wireExecutorRegistryVocabulary registry =
  foldMap wireExecutorProjectionVocabulary registry.wireExecutorRegistryProjections
