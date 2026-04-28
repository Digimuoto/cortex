{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.Contracts
  ( WireContractSpec (..),
    WireContractRegistry (..),
    emptyWireContractRegistry,
    wireContractRegistryFromList,
    WireCompileEnv (..),
    emptyWireCompileEnv,
    portsMetadataValue,
    wirePortsFromMetadataValue,
    validatePorts,
  )
where

import Control.Monad (void)
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.Syntax
import Cortex.Wire.Value (WirePayloadKind, renderWirePayloadKind)
import Data.Aeson (ToJSON (..), (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

data WireContractSpec = WireContractSpec
  { wireContractSpecId :: !Text,
    wireContractSpecPayloadKind :: !WirePayloadKind,
    wireContractSpecDescription :: !Text,
    wireContractSpecSchema :: !(Maybe Aeson.Value),
    wireContractSpecExamples :: ![Aeson.Value]
  }
  deriving stock (Eq, Show)

instance ToJSON WireContractSpec where
  toJSON spec =
    Aeson.object
      [ "id" .= spec.wireContractSpecId,
        "payloadKind" .= renderWirePayloadKind spec.wireContractSpecPayloadKind,
        "description" .= spec.wireContractSpecDescription,
        "schema" .= spec.wireContractSpecSchema,
        "examples" .= spec.wireContractSpecExamples
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
  { wireCompileEnvNativeExecutorPorts :: Map Text WirePorts,
    wireCompileEnvEmitKindPorts :: Map Text WirePorts,
    wireCompileEnvConditionPorts :: Map Text WirePorts,
    wireCompileEnvLlmDefaultPorts :: Maybe WirePorts,
    wireCompileEnvAwaitDefaultPorts :: Maybe WirePorts,
    wireCompileEnvContractRegistry :: Maybe WireContractRegistry
  }
  deriving stock (Eq, Show)

emptyWireCompileEnv :: WireCompileEnv
emptyWireCompileEnv =
  WireCompileEnv
    { wireCompileEnvNativeExecutorPorts = Map.empty,
      wireCompileEnvEmitKindPorts = Map.empty,
      wireCompileEnvConditionPorts = Map.empty,
      wireCompileEnvLlmDefaultPorts = Nothing,
      wireCompileEnvAwaitDefaultPorts = Nothing,
      wireCompileEnvContractRegistry = Nothing
    }

portsMetadataValue :: WirePorts -> Aeson.Value
portsMetadataValue ports =
  Aeson.object
    [ "inputs" Aeson..= fmap encodeInputPort (Map.toList ports.wirePortsInputs),
      "outputs" Aeson..= fmap encodeOutputPort (Map.toList ports.wirePortsOutputs)
    ]
  where
    encodeInputPort (portName, portSpec) =
      Aeson.object
        [ "name" Aeson..= portName,
          "accepts" Aeson..= portSpec.wireInputPortAccepts,
          "cardinality" Aeson..= renderCardinality portSpec.wireInputPortCardinality,
          "required" Aeson..= portSpec.wireInputPortRequired
        ]
    encodeOutputPort (portName, portSpec) =
      Aeson.object
        [ "name" Aeson..= portName,
          "contract" Aeson..= portSpec.wireOutputPortContract
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
      { wirePortsInputs = Map.fromList inputEntries,
        wirePortsOutputs = Map.fromList outputEntries
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

traverse_ :: (Applicative f) => (a -> f b) -> [a] -> f ()
traverse_ f = foldr ((*>) . void . f) (pure ())
