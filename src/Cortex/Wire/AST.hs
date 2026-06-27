{- |
Module      : Cortex.Wire.AST
Description : Wire support for ast.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.AST
  ( QualifiedRef (..)
  , renderQualifiedRef
  , EndpointRef (..)
  , renderEndpointRef
  , Connection (..)
  , connect
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , wireOrdinaryOutputPort
  , WirePorts (..)
  , defaultInputPortName
  , defaultOutputPortName
  , WireExecutor (..)
  , WireNodeRuntimeOptions (..)
  , emptyWireNodeRuntimeOptions
  , WireError (..)
  , renderWireError
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph (ValidationError (..))
import Cortex.Pulse.Memory.Types (MemoryStrategy)
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))

newtype QualifiedRef = QualifiedRef
  { qualifiedRefSegments :: NonEmpty Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

renderQualifiedRef :: QualifiedRef -> Text
renderQualifiedRef = T.intercalate "." . NE.toList . qualifiedRefSegments

data EndpointRef = EndpointRef
  { endpointNodeRef :: !CircuitNodeRef
  , endpointPortName :: !(Maybe Text)
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

renderEndpointRef :: EndpointRef -> Text
renderEndpointRef endpointRef =
  endpointRef.endpointNodeRef.unCircuitNodeRef
    <> foldMap ("." <>) endpointRef.endpointPortName

data Connection = Connection
  { connectionFrom :: !EndpointRef
  , connectionTo :: !EndpointRef
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

connect :: EndpointRef -> EndpointRef -> Connection
connect = Connection

data WireInputCardinality
  = WireInputCardinalityOne
  | WireInputCardinalityMany
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WireInputCardinality where
  parseJSON = Aeson.withText "WireInputCardinality" $ \rawValue ->
    case T.toCaseFold (T.strip rawValue) of
      "one" -> pure WireInputCardinalityOne
      "many" -> pure WireInputCardinalityMany
      other ->
        fail
          ("Unknown input port cardinality: " <> T.unpack other)

data WireInputPort = WireInputPort
  { wireInputPortAccepts :: ![Text]
  , wireInputPortCardinality :: !WireInputCardinality
  , wireInputPortRequired :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WireInputPort where
  parseJSON = Aeson.withObject "WireInputPort" $ \obj ->
    WireInputPort
      <$> obj Aeson..: "accepts"
      <*> obj Aeson..:? "cardinality" Aeson..!= WireInputCardinalityMany
      <*> obj Aeson..:? "required" Aeson..!= False

data WireOutputPort = WireOutputPort
  { wireOutputPortContract :: !Text
  , wireOutputPortExclusiveGroup :: !(Maybe Natural)
  {- ^ The exclusive (sum) output group this port belongs to, if any. Ports sharing
  a group id are the variants of one @select@-able boundary (ADR 0062); 'Nothing'
  is an ordinary product output.
  -}
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | An ordinary (non-variant) output port: no exclusive group.
wireOrdinaryOutputPort :: Text -> WireOutputPort
wireOrdinaryOutputPort contract =
  WireOutputPort {wireOutputPortContract = contract, wireOutputPortExclusiveGroup = Nothing}

instance FromJSON WireOutputPort where
  parseJSON = Aeson.withObject "WireOutputPort" $ \obj ->
    WireOutputPort
      <$> obj Aeson..: "contract"
      <*> obj Aeson..:? "exclusiveGroup"

data WirePorts = WirePorts
  { wirePortsInputs :: !(Map Text WireInputPort)
  , wirePortsOutputs :: !(Map Text WireOutputPort)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WirePorts where
  parseJSON = Aeson.withObject "WirePorts" $ \obj ->
    WirePorts
      <$> obj Aeson..:? "inputs" Aeson..!= mempty
      <*> obj Aeson..:? "outputs" Aeson..!= mempty

defaultInputPortName :: Text
defaultInputPortName = "in"

defaultOutputPortName :: Text
defaultOutputPortName = "out"

data WireExecutor
  = WireExecutorNative !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data WireNodeRuntimeOptions = WireNodeRuntimeOptions
  { wireNodeRuntimeTimeoutSeconds :: !(Maybe Int32)
  , wireNodeRuntimeRetryCount :: !(Maybe Int32)
  , wireNodeRuntimeStepBudget :: !(Maybe Int32)
  , wireNodeRuntimeToolLoopMinSteps :: !(Maybe Int32)
  , wireNodeRuntimeMaxOutputTokens :: !(Maybe Int32)
  , wireNodeRuntimeReasoningEnabled :: !(Maybe Bool)
  , wireNodeRuntimeMemory :: !(Maybe MemoryStrategy)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WireNodeRuntimeOptions where
  parseJSON = Aeson.withObject "WireNodeRuntimeOptions" $ \obj ->
    WireNodeRuntimeOptions
      <$> obj Aeson..:? "timeoutSeconds"
      <*> obj Aeson..:? "retryCount"
      <*> obj Aeson..:? "stepBudget"
      <*> obj Aeson..:? "toolLoopMinSteps"
      <*> obj Aeson..:? "maxOutputTokens"
      <*> obj Aeson..:? "reasoningEnabled"
      <*> obj Aeson..:? "memory"

emptyWireNodeRuntimeOptions :: WireNodeRuntimeOptions
emptyWireNodeRuntimeOptions =
  WireNodeRuntimeOptions
    { wireNodeRuntimeTimeoutSeconds = Nothing
    , wireNodeRuntimeRetryCount = Nothing
    , wireNodeRuntimeStepBudget = Nothing
    , wireNodeRuntimeToolLoopMinSteps = Nothing
    , wireNodeRuntimeMaxOutputTokens = Nothing
    , wireNodeRuntimeReasoningEnabled = Nothing
    , wireNodeRuntimeMemory = Nothing
    }

data WireError
  = WireParseError !Text
  | WireMissingCircuit
  | WireDuplicateNodeRef !CircuitNodeRef
  | WireMissingRequiredField !CircuitNodeRef !Text
  | WireUnknownNodeRef !CircuitNodeRef
  | WireUnusedNodeRef !CircuitNodeRef
  | WireDisconnectedTopology ![CircuitNodeRef]
  | WireInvalidTopology !(ValidationError CircuitNodeRef)
  | WireEmptyCircuit
  | WireInvalidPorts !CircuitNodeRef !Text
  | WireMissingPortsForNode !CircuitNodeRef !Text
  | WireUnknownPort !CircuitNodeRef !Text
  | WireMissingDefaultInputPort !CircuitNodeRef
  | WireMissingDefaultOutputPort !CircuitNodeRef
  | WireNoCompatiblePorts !EndpointRef !EndpointRef
  | WireAmbiguousCompatiblePorts !EndpointRef !EndpointRef ![Text]
  | WirePortContractMismatch !EndpointRef !Text !EndpointRef !Text ![Text]
  | WireMissingRequiredInputPort !CircuitNodeRef !Text
  | WireInputPortCardinalityViolation !CircuitNodeRef !Text !Int
  | WireUnknownContract !Text !Text
  | WireUnknownExecutor !CircuitNodeRef !Text
  | WireExecutorPortsMismatch !CircuitNodeRef !Text
  | WireUnknownConditionRef !Text
  | WireDuplicateLetBinding !Text
  | WireUnknownLetBinding !Text
  | WireUnknownUseNamespace !Text
  | WireUnknownUseItem !Text !Text
  | WireDuplicateBinding !Text
  | WireExecutorNotInScope !Text
  | WireTypeMismatchInConcat !Text !Text
  | WireFieldTypeMismatch !Text !Text !Text
  deriving stock (Eq, Show, Generic)

renderWireError :: WireError -> Text
renderWireError = \case
  WireParseError msg ->
    "Wire parse error:\n" <> msg
  WireMissingCircuit ->
    "Wire file must end in a file-return expression."
  WireDuplicateNodeRef nodeRef ->
    "Wire file declared node " <> unCircuitNodeRef nodeRef <> " more than once."
  WireMissingRequiredField nodeRef fieldName ->
    "Node " <> unCircuitNodeRef nodeRef <> " is missing required field " <> fieldName <> "."
  WireUnknownNodeRef nodeRef ->
    "Wire expression references unknown node " <> unCircuitNodeRef nodeRef <> "."
  WireUnusedNodeRef nodeRef ->
    "Declared node " <> unCircuitNodeRef nodeRef <> " does not appear in the file-return expression."
  WireDisconnectedTopology nodeRefs ->
    "Wire graph must form one connected component. Disconnected node(s): "
      <> T.intercalate ", " (fmap unCircuitNodeRef nodeRefs)
      <> "."
  WireInvalidTopology (GraphHasCycle cyclePath) ->
    "Wire graph must be a DAG. Cycle: "
      <> T.intercalate " -> " (fmap unCircuitNodeRef cyclePath)
      <> "."
  WireEmptyCircuit ->
    "Wire file-return expression must contain at least one connected node."
  WireInvalidPorts nodeRef errText ->
    "Node " <> unCircuitNodeRef nodeRef <> " declared invalid ports: " <> errText
  WireMissingPortsForNode nodeRef contextLabel ->
    "Node " <> unCircuitNodeRef nodeRef <> " requires explicit ports because " <> contextLabel <> "."
  WireUnknownPort nodeRef portName ->
    "Node " <> unCircuitNodeRef nodeRef <> " does not declare port " <> portName <> "."
  WireMissingDefaultInputPort nodeRef ->
    "Node "
      <> unCircuitNodeRef nodeRef
      <> " does not declare the default input port "
      <> defaultInputPortName
      <> "."
  WireMissingDefaultOutputPort nodeRef ->
    "Node "
      <> unCircuitNodeRef nodeRef
      <> " does not declare the default output port "
      <> defaultOutputPortName
      <> "."
  WireNoCompatiblePorts fromRef toRef ->
    "Connection "
      <> renderEndpointRef fromRef
      <> " has no output port compatible with "
      <> renderEndpointRef toRef
      <> "."
  WireAmbiguousCompatiblePorts fromRef toRef candidates ->
    "Connection "
      <> renderEndpointRef fromRef
      <> " to "
      <> renderEndpointRef toRef
      <> " is ambiguous. Compatible port pairs: "
      <> T.intercalate ", " candidates
      <> ". Specify endpoint ports explicitly."
  WirePortContractMismatch fromRef actualContract toRef sinkPort acceptedContracts ->
    "Connection "
      <> renderEndpointRef fromRef
      <> " ("
      <> actualContract
      <> ") is not compatible with "
      <> renderEndpointRef toRef
      <> " (port "
      <> sinkPort
      <> " accepts "
      <> T.intercalate ", " acceptedContracts
      <> ")."
  WireMissingRequiredInputPort nodeRef portName ->
    "Node " <> unCircuitNodeRef nodeRef <> " is missing required input port " <> portName <> "."
  WireInputPortCardinalityViolation nodeRef portName actualCount ->
    "Node "
      <> unCircuitNodeRef nodeRef
      <> " received "
      <> T.pack (show actualCount)
      <> " inbound edges on single-cardinality port "
      <> portName
      <> "."
  WireUnknownContract contextLabel contractName ->
    "Wire contract "
      <> contractName
      <> " is not registered in "
      <> contextLabel
      <> "."
  WireUnknownExecutor nodeRef executorId ->
    "Node "
      <> unCircuitNodeRef nodeRef
      <> " references executor "
      <> executorId
      <> ", but it is not present in the strict Wire executor projection."
  WireExecutorPortsMismatch nodeRef executorId ->
    "Node "
      <> unCircuitNodeRef nodeRef
      <> " declares ports that do not match the strict Wire executor projection for "
      <> executorId
      <> "."
  WireUnknownConditionRef conditionRef ->
    "Condition " <> conditionRef <> " has no known port contract."
  WireDuplicateLetBinding name ->
    "Module-level `let " <> name <> "` was declared more than once."
  WireUnknownLetBinding name ->
    "`let " <> name <> "` referenced but not declared in scope."
  WireUnknownUseNamespace namespace ->
    "`use` references unknown registry namespace " <> namespace <> "."
  WireUnknownUseItem namespace itemName ->
    "`use` references unknown item " <> itemName <> " in namespace " <> namespace <> "."
  WireDuplicateBinding name ->
    "Wire file binds name " <> name <> " more than once."
  WireExecutorNotInScope executorName ->
    "Executor " <> executorName <> " is not in Wire source scope; import it with `use` first."
  WireTypeMismatchInConcat left right ->
    "`++` requires both operands of the same kind; got "
      <> left
      <> " on the left and "
      <> right
      <> " on the right."
  WireFieldTypeMismatch fieldName expected actual ->
    "Field `"
      <> fieldName
      <> "` expected a "
      <> expected
      <> " value, but the expression resolves to a "
      <> actual
      <> "."
