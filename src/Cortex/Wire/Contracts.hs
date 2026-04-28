{- |
Module      : Cortex.Wire.Contracts
Description : Wire support for contracts.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Contracts
  ( WireContractSpec (..)
  , WireContractRegistry (..)
  , emptyWireContractRegistry
  , wireContractRegistryFromList
  , WireProjectionMode (..)
  , WireCompileEnv (..)
  , emptyWireCompileEnv
  , wireCompileEnvWithContractRegistry
  , wireCompileEnvWithExecutorRegistry
  , strictWireCompileEnv
  , portsMetadataValue
  , wirePortsFromMetadataValue
  , validatePorts
  )
where

import Control.Monad (void)
import Data.Aeson (ToJSON (..), (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.Executor (WireExecutorRegistry, emptyWireExecutorRegistry)
import Cortex.Wire.Syntax
import Cortex.Wire.Value (WirePayloadKind, renderWirePayloadKind)

data WireContractSpec = WireContractSpec
  { wireContractSpecId :: !Text
  , wireContractSpecPayloadKind :: !WirePayloadKind
  , wireContractSpecDescription :: !Text
  , wireContractSpecSchema :: !(Maybe Aeson.Value)
  , wireContractSpecExamples :: ![Aeson.Value]
  }
  deriving stock (Eq, Show)

instance ToJSON WireContractSpec where
  toJSON spec =
    Aeson.object
      [ "id" .= spec.wireContractSpecId
      , "payloadKind" .= renderWirePayloadKind spec.wireContractSpecPayloadKind
      , "description" .= spec.wireContractSpecDescription
      , "schema" .= spec.wireContractSpecSchema
      , "examples" .= spec.wireContractSpecExamples
      ]

newtype WireContractRegistry = WireContractRegistry
  { wireContractRegistryContracts :: Map Text WireContractSpec
  }
  deriving stock (Eq, Show)

instance ToJSON WireContractRegistry where
  toJSON registry =
    Aeson.object
      [ "contracts" .= Map.elems registry.wireContractRegistryContracts
      ]

emptyWireContractRegistry :: WireContractRegistry
emptyWireContractRegistry =
  WireContractRegistry Map.empty

wireContractRegistryFromList :: [WireContractSpec] -> WireContractRegistry
wireContractRegistryFromList specs =
  WireContractRegistry
    (Map.fromList [(spec.wireContractSpecId, spec) | spec <- specs])

data WireCompileEnv = WireCompileEnv
  { wireCompileEnvExecutorRegistry :: WireExecutorRegistry
  , wireCompileEnvProjectionMode :: WireProjectionMode
  , wireCompileEnvContractRegistry :: Maybe WireContractRegistry
  }
  deriving stock (Eq, Show)

data WireProjectionMode
  = WireProjectionPermissive
  | WireProjectionStrict
  deriving stock (Eq, Show)

emptyWireCompileEnv :: WireCompileEnv
emptyWireCompileEnv =
  WireCompileEnv
    { wireCompileEnvExecutorRegistry = emptyWireExecutorRegistry
    , wireCompileEnvProjectionMode = WireProjectionPermissive
    , wireCompileEnvContractRegistry = Nothing
    }

wireCompileEnvWithContractRegistry :: WireContractRegistry -> WireCompileEnv
wireCompileEnvWithContractRegistry registry =
  emptyWireCompileEnv {wireCompileEnvContractRegistry = Just registry}

wireCompileEnvWithExecutorRegistry :: WireExecutorRegistry -> WireCompileEnv
wireCompileEnvWithExecutorRegistry registry =
  emptyWireCompileEnv {wireCompileEnvExecutorRegistry = registry}

strictWireCompileEnv :: WireExecutorRegistry -> WireContractRegistry -> WireCompileEnv
strictWireCompileEnv executorRegistry contractRegistry =
  WireCompileEnv
    { wireCompileEnvExecutorRegistry = executorRegistry
    , wireCompileEnvProjectionMode = WireProjectionStrict
    , wireCompileEnvContractRegistry = Just contractRegistry
    }

portsMetadataValue :: WirePorts -> Aeson.Value
portsMetadataValue ports =
  Aeson.object
    [ "inputs" Aeson..= fmap encodeInputPort (Map.toList ports.wirePortsInputs)
    , "outputs" Aeson..= fmap encodeOutputPort (Map.toList ports.wirePortsOutputs)
    ]
  where
    encodeInputPort (portName, portSpec) =
      Aeson.object
        [ "name" Aeson..= portName
        , "accepts" Aeson..= portSpec.wireInputPortAccepts
        , "cardinality" Aeson..= renderCardinality portSpec.wireInputPortCardinality
        , "required" Aeson..= portSpec.wireInputPortRequired
        ]
    encodeOutputPort (portName, portSpec) =
      Aeson.object
        [ "name" Aeson..= portName
        , "contract" Aeson..= portSpec.wireOutputPortContract
        ]

wirePortsFromMetadataValue :: Aeson.Value -> Either Text WirePorts
wirePortsFromMetadataValue value =
  case AesonTypes.parseEither parsePortsMetadata value of
    Left errText -> Left (T.pack errText)
    Right ports -> Right ports

parsePortsMetadata :: Aeson.Value -> AesonTypes.Parser WirePorts
parsePortsMetadata = Aeson.withObject "WirePorts metadata" $ \obj -> do
  rawInputEntries <- obj .: "inputs"
  rawOutputEntries <- obj .: "outputs"
  inputEntries <- traverse parseInputMetadataEntry rawInputEntries
  outputEntries <- traverse parseOutputMetadataEntry rawOutputEntries
  pure
    WirePorts
      { wirePortsInputs = Map.fromList inputEntries
      , wirePortsOutputs = Map.fromList outputEntries
      }

parseInputMetadataEntry :: Aeson.Value -> AesonTypes.Parser (Text, WireInputPort)
parseInputMetadataEntry = Aeson.withObject "Wire input port metadata" $ \obj -> do
  portName <- obj .: "name"
  portSpec <-
    WireInputPort
      <$> obj .: "accepts"
      <*> obj .: "cardinality"
      <*> obj .: "required"
  pure (portName, portSpec)

parseOutputMetadataEntry :: Aeson.Value -> AesonTypes.Parser (Text, WireOutputPort)
parseOutputMetadataEntry = Aeson.withObject "Wire output port metadata" $ \obj -> do
  portName <- obj .: "name"
  portSpec <- WireOutputPort <$> obj .: "contract"
  pure (portName, portSpec)

validatePorts :: CircuitNodeRef -> WirePorts -> Either WireError WirePorts
validatePorts nodeRef ports = do
  traverseInputPorts
  traverseOutputPorts
  Right ports
  where
    traverseInputPorts =
      traverse_
        validateInputPort
        (Map.toList ports.wirePortsInputs)
    traverseOutputPorts =
      traverse_
        validateOutputPort
        (Map.toList ports.wirePortsOutputs)

    validateInputPort (portName, inputPort)
      | T.null (T.strip portName) =
          Left (WireInvalidPorts nodeRef "input port names must not be empty")
      | null inputPort.wireInputPortAccepts =
          Left (WireInvalidPorts nodeRef ("input port " <> portName <> " must accept at least one contract"))
      | any (T.null . T.strip) inputPort.wireInputPortAccepts =
          Left (WireInvalidPorts nodeRef ("input port " <> portName <> " uses an empty contract name"))
      | otherwise =
          Right ()

    validateOutputPort (portName, outputPort)
      | T.null (T.strip portName) =
          Left (WireInvalidPorts nodeRef "output port names must not be empty")
      | T.null (T.strip outputPort.wireOutputPortContract) =
          Left (WireInvalidPorts nodeRef ("output port " <> portName <> " must declare a non-empty contract"))
      | otherwise =
          Right ()

renderCardinality :: WireInputCardinality -> Text
renderCardinality = \case
  WireInputCardinalityOne -> "one"
  WireInputCardinalityMany -> "many"

traverse_ :: Applicative f => (a -> f b) -> [a] -> f ()
traverse_ f = foldr ((*>) . void . f) (pure ())
