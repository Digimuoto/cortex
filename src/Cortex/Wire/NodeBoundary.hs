{- |
Module      : Cortex.Wire.NodeBoundary
Description : Private Wire node-boundary normal-form support.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Private support for ADR 0039's node boundary normal form. The public Wire
syntax stays compact, but compiler lowering and runtime egress share this
phase vocabulary:

@
input port environment -> ingress adapter -> body -> egress adapter -> output port environment
@

This module deliberately does not import 'Cortex.Wire.Pure'. The pure evaluator
depends on the runtime input bundle, while the runtime egress wrapper depends on
this module; importing Pure here would create an implementation cycle. Compile
time pure validation therefore remains at the call site after the normal-form
record is built.
-}
module Cortex.Wire.NodeBoundary
  ( NodeBoundaryNormalForm (..)
  , NodeBoundaryIngress
  , NodeBoundaryBody
  , NodeBoundaryEgress (..)
  , BoundaryEgressContext (..)
  , pureNodeBoundaryNormalForm
  , pureSumNodeBoundaryNormalForm
  , executorNodeBoundaryNormalForm
  , signalNodeBoundaryNormalForm
  , artifactNodeBoundaryNormalForm
  , validateNodeBoundaryNormalForm
  , normalFormPorts
  , normalFormOutputPorts
  , wrapNodeBoundaryOutput
  , wrapNodeBoundaryOutputs
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire.AST
  ( QualifiedRef
  , WireExecutor
  , WireOutputPort (..)
  , WirePorts (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.Contract (WireContractRegistry (..), WireContractSpec (..))
import Cortex.Wire.ContractValidation
  ( renderWireContractValidationError
  , validateJsonValueAgainstSchema
  )
import Cortex.Wire.Syntax (CorePureBinding, CorePureExpr)
import Cortex.Wire.Value
  ( WirePayloadKind (..)
  , WireValue (..)
  , WireValueSet (..)
  , mkWireValue
  , renderWirePayloadKind
  , validateWirePayloadShape
  )

data NodeBoundaryIngress
  = NodeBoundaryCorePureIngress !CorePureIngress
  | NodeBoundaryExecutorIngress !ExecutorIngress
  deriving stock (Eq, Show)

data CorePureIngress = CorePureIngress
  { corePureIngressBindings :: ![CorePureBinding]
  , corePureIngressWhere :: !(Maybe CorePureExpr)
  }
  deriving stock (Eq, Show)

data ExecutorIngress = ExecutorIngress
  { executorIngressWhere :: !(Maybe CorePureExpr)
  , executorIngressInput :: !CorePureExpr
  }
  deriving stock (Eq, Show)

data NodeBoundaryBody
  = NodeBoundaryCorePureBody !CorePureBody
  | NodeBoundaryExecutorBody !ExecutorBody
  | NodeBoundarySignalBody !SignalBody
  | NodeBoundaryArtifactBody !ArtifactBody
  deriving stock (Eq, Show)

data CorePureBody
  = CorePureProductBody !(Map Text CorePureExpr)
  | CorePureSumBody ![Text] !CorePureExpr
  deriving stock (Eq, Show)

data ExecutorBody = ExecutorBody
  { executorBodyExecutor :: !WireExecutor
  , executorBodyConfig :: !(Maybe Aeson.Value)
  }
  deriving stock (Eq, Show)

newtype SignalBody = SignalBody
  { signalBodyName :: Text
  }
  deriving stock (Eq, Show)

data ArtifactBody = ArtifactBody
  { artifactBodyKind :: !Text
  , artifactBodyTarget :: !QualifiedRef
  }
  deriving stock (Eq, Show)

newtype NodeBoundaryEgress = NodeBoundaryEgress
  { nodeBoundaryOutputPorts :: Map Text WireOutputPort
  }
  deriving stock (Eq, Show)

data NodeBoundaryNormalForm = NodeBoundaryNormalForm
  { nodeBoundaryRef :: !CircuitNodeRef
  , nodeBoundaryPorts :: !WirePorts
  , nodeBoundaryIngress :: !NodeBoundaryIngress
  , nodeBoundaryBody :: !NodeBoundaryBody
  , nodeBoundaryEgress :: !NodeBoundaryEgress
  }
  deriving stock (Eq, Show)

data BoundaryEgressContext = BoundaryEgressContext
  { boundaryEgressProducer :: !NodeId
  , boundaryEgressRunId :: !UUID
  , boundaryEgressPorts :: !WirePorts
  }
  deriving stock (Eq, Show)

pureNodeBoundaryNormalForm
  :: CircuitNodeRef
  -> WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> NodeBoundaryNormalForm
pureNodeBoundaryNormalForm nodeRef ports bindings whereExpr outputExprs =
  NodeBoundaryNormalForm
    { nodeBoundaryRef = nodeRef
    , nodeBoundaryPorts = ports
    , nodeBoundaryIngress =
        NodeBoundaryCorePureIngress
          CorePureIngress
            { corePureIngressBindings = bindings
            , corePureIngressWhere = whereExpr
            }
    , nodeBoundaryBody =
        NodeBoundaryCorePureBody (CorePureProductBody outputExprs)
    , nodeBoundaryEgress =
        NodeBoundaryEgress
          { nodeBoundaryOutputPorts = ports.wirePortsOutputs
          }
    }

pureSumNodeBoundaryNormalForm
  :: CircuitNodeRef
  -> WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> [Text]
  -> CorePureExpr
  -> NodeBoundaryNormalForm
pureSumNodeBoundaryNormalForm nodeRef ports bindings whereExpr labels bodyExpr =
  NodeBoundaryNormalForm
    { nodeBoundaryRef = nodeRef
    , nodeBoundaryPorts = ports
    , nodeBoundaryIngress =
        NodeBoundaryCorePureIngress
          CorePureIngress
            { corePureIngressBindings = bindings
            , corePureIngressWhere = whereExpr
            }
    , nodeBoundaryBody =
        NodeBoundaryCorePureBody (CorePureSumBody labels bodyExpr)
    , nodeBoundaryEgress =
        NodeBoundaryEgress
          { nodeBoundaryOutputPorts = ports.wirePortsOutputs
          }
    }

executorNodeBoundaryNormalForm
  :: CircuitNodeRef
  -> WirePorts
  -> Maybe CorePureExpr
  -> CorePureExpr
  -> WireExecutor
  -> Maybe Aeson.Value
  -> NodeBoundaryNormalForm
executorNodeBoundaryNormalForm nodeRef ports whereExpr inputExpr executor configValue =
  NodeBoundaryNormalForm
    { nodeBoundaryRef = nodeRef
    , nodeBoundaryPorts = ports
    , nodeBoundaryIngress =
        NodeBoundaryExecutorIngress
          ExecutorIngress
            { executorIngressWhere = whereExpr
            , executorIngressInput = inputExpr
            }
    , nodeBoundaryBody =
        NodeBoundaryExecutorBody
          ExecutorBody
            { executorBodyExecutor = executor
            , executorBodyConfig = configValue
            }
    , nodeBoundaryEgress =
        NodeBoundaryEgress
          { nodeBoundaryOutputPorts = ports.wirePortsOutputs
          }
    }

signalNodeBoundaryNormalForm
  :: CircuitNodeRef
  -> WirePorts
  -> Maybe CorePureExpr
  -> CorePureExpr
  -> Text
  -> NodeBoundaryNormalForm
signalNodeBoundaryNormalForm nodeRef ports whereExpr inputExpr signalName =
  NodeBoundaryNormalForm
    { nodeBoundaryRef = nodeRef
    , nodeBoundaryPorts = ports
    , nodeBoundaryIngress =
        NodeBoundaryExecutorIngress
          ExecutorIngress
            { executorIngressWhere = whereExpr
            , executorIngressInput = inputExpr
            }
    , nodeBoundaryBody =
        NodeBoundarySignalBody
          SignalBody
            { signalBodyName = signalName
            }
    , nodeBoundaryEgress =
        NodeBoundaryEgress
          { nodeBoundaryOutputPorts = ports.wirePortsOutputs
          }
    }

artifactNodeBoundaryNormalForm
  :: CircuitNodeRef
  -> WirePorts
  -> Maybe CorePureExpr
  -> CorePureExpr
  -> Text
  -> QualifiedRef
  -> NodeBoundaryNormalForm
artifactNodeBoundaryNormalForm nodeRef ports whereExpr inputExpr artifactKind targetRef =
  NodeBoundaryNormalForm
    { nodeBoundaryRef = nodeRef
    , nodeBoundaryPorts = ports
    , nodeBoundaryIngress =
        NodeBoundaryExecutorIngress
          ExecutorIngress
            { executorIngressWhere = whereExpr
            , executorIngressInput = inputExpr
            }
    , nodeBoundaryBody =
        NodeBoundaryArtifactBody
          ArtifactBody
            { artifactBodyKind = artifactKind
            , artifactBodyTarget = targetRef
            }
    , nodeBoundaryEgress =
        NodeBoundaryEgress
          { nodeBoundaryOutputPorts = ports.wirePortsOutputs
          }
    }

normalFormPorts :: NodeBoundaryNormalForm -> WirePorts
normalFormPorts =
  nodeBoundaryPorts

normalFormOutputPorts :: NodeBoundaryNormalForm -> Map Text WireOutputPort
normalFormOutputPorts =
  nodeBoundaryOutputPorts . nodeBoundaryEgress

validateNodeBoundaryNormalForm :: NodeBoundaryNormalForm -> Either Text ()
validateNodeBoundaryNormalForm form = do
  validatePhasePair
  if normalFormOutputPorts form == form.nodeBoundaryPorts.wirePortsOutputs
    then Right ()
    else
      Left
        ( "Wire node "
            <> form.nodeBoundaryRef.unCircuitNodeRef
            <> " boundary egress ports do not match declared output ports."
        )
  where
    validatePhasePair =
      case (form.nodeBoundaryIngress, form.nodeBoundaryBody) of
        (NodeBoundaryCorePureIngress {}, NodeBoundaryCorePureBody {}) ->
          Right ()
        (NodeBoundaryExecutorIngress {}, NodeBoundaryExecutorBody {}) ->
          Right ()
        (NodeBoundaryExecutorIngress {}, NodeBoundarySignalBody {}) ->
          Right ()
        (NodeBoundaryExecutorIngress {}, NodeBoundaryArtifactBody {}) ->
          Right ()
        (NodeBoundaryCorePureIngress {}, NodeBoundaryExecutorBody {}) ->
          corePureIngressMismatch
        (NodeBoundaryCorePureIngress {}, NodeBoundarySignalBody {}) ->
          corePureIngressMismatch
        (NodeBoundaryCorePureIngress {}, NodeBoundaryArtifactBody {}) ->
          corePureIngressMismatch
        (NodeBoundaryExecutorIngress {}, NodeBoundaryCorePureBody {}) ->
          Left
            ( "Wire node "
                <> form.nodeBoundaryRef.unCircuitNodeRef
                <> " has executor ingress with a CorePure body."
            )

    corePureIngressMismatch =
      Left
        ( "Wire node "
            <> form.nodeBoundaryRef.unCircuitNodeRef
            <> " has CorePure ingress with a non-CorePure body."
        )

wrapNodeBoundaryOutput
  :: Maybe WireContractRegistry
  -> BoundaryEgressContext
  -> Aeson.Value
  -> Either Text Aeson.Value
wrapNodeBoundaryOutput maybeRegistry ctx outputValue =
  case classifyOutputBoundary ctx.boundaryEgressPorts of
    BoundaryInvalid invalid -> Left invalid
    BoundaryVariant variantPorts -> validateVariantEmission maybeRegistry ctx variantPorts outputValue
    BoundaryProduct -> wrapProductBoundaryOutput maybeRegistry ctx outputValue

wrapProductBoundaryOutput
  :: Maybe WireContractRegistry
  -> BoundaryEgressContext
  -> Aeson.Value
  -> Either Text Aeson.Value
wrapProductBoundaryOutput maybeRegistry ctx outputValue =
  case explicitWireOutput outputValue of
    Just wireOutput ->
      validateExplicitWireOutput maybeRegistry ctx.boundaryEgressPorts wireOutput *> Right outputValue
    Nothing ->
      case outputContracts of
        [] -> Right outputValue
        [contractId] -> do
          outputPortName <-
            case Map.keys ctx.boundaryEgressPorts.wirePortsOutputs of
              [portName] -> Right portName
              _ ->
                Left
                  ( "Wire node "
                      <> unNodeId ctx.boundaryEgressProducer
                      <> " declared one output contract but did not expose exactly one output port."
                  )
          payloadKind <- payloadKindForContract maybeRegistry contractId
          validateWireValuePayloadShape maybeRegistry contractId payloadKind outputValue
          let wireValue =
                (mkWireValue contractId payloadKind (Just (unNodeId ctx.boundaryEgressProducer)) outputValue)
                  { wireValueProvenance =
                      Just
                        ( Aeson.object
                            [ "runId" Aeson..= UUID.toText ctx.boundaryEgressRunId
                            , "nodeId" Aeson..= unNodeId ctx.boundaryEgressProducer
                            ]
                        )
                  , wireValuePort = Just outputPortName
                  }
          Right (Aeson.toJSON wireValue)
        _ ->
          Left
            ( "Wire node "
                <> unNodeId ctx.boundaryEgressProducer
                <> " declares multiple output contracts ("
                <> T.intercalate ", " outputContracts
                <> ") but returned a raw JSON value. Return an explicit WireValueSet."
            )
  where
    outputContracts =
      fmap (.wireOutputPortContract) (Map.elems ctx.boundaryEgressPorts.wirePortsOutputs)

wrapNodeBoundaryOutputs
  :: Maybe WireContractRegistry
  -> BoundaryEgressContext
  -> Map Text Aeson.Value
  -> Either Text Aeson.Value
wrapNodeBoundaryOutputs maybeRegistry ctx outputValues =
  case classifyOutputBoundary ctx.boundaryEgressPorts of
    BoundaryInvalid invalid -> Left invalid
    BoundaryVariant variantPorts ->
      case Map.toAscList outputValues of
        [(portName, value)]
          | portName `elem` variantPorts -> do
              wireValue <- outputWireValue (portName, value)
              Right (Aeson.toJSON wireValue)
          | otherwise ->
              Left
                ( "Emitted variant label "
                    <> portName
                    <> " is not a declared variant of Wire node "
                    <> unNodeId ctx.boundaryEgressProducer
                    <> "."
                )
        _ ->
          Left
            ( "Wire node "
                <> unNodeId ctx.boundaryEgressProducer
                <> " is a variant-emitting node and must commit exactly one variant."
            )
    BoundaryProduct -> do
      let expectedPorts = Map.keysSet ctx.boundaryEgressPorts.wirePortsOutputs
          actualPorts = Map.keysSet outputValues
      if expectedPorts == actualPorts
        then pure ()
        else
          Left
            ( "Wire node "
                <> unNodeId ctx.boundaryEgressProducer
                <> " returned pure output ports "
                <> renderSet actualPorts
                <> ", expected "
                <> renderSet expectedPorts
                <> "."
            )
      wireValues <- traverse outputWireValue (Map.toAscList outputValues)
      let wireValueSet = WireValueSet wireValues
      validateExplicitWireOutput maybeRegistry ctx.boundaryEgressPorts (ExplicitWireValueSet wireValueSet)
      Right (Aeson.toJSON wireValueSet)
  where
    renderSet values =
      "{"
        <> T.intercalate ", " (Set.toAscList values)
        <> "}"

    outputWireValue (portName, value) = do
      outputPort <-
        case Map.lookup portName ctx.boundaryEgressPorts.wirePortsOutputs of
          Just portSpec -> Right portSpec
          Nothing -> Left ("Wire output port " <> portName <> " is not offered by this node.")
      payloadKind <- payloadKindForContract maybeRegistry outputPort.wireOutputPortContract
      validateWireValuePayloadShape maybeRegistry outputPort.wireOutputPortContract payloadKind value
      Right
        ( ( mkWireValue
              outputPort.wireOutputPortContract
              payloadKind
              (Just (unNodeId ctx.boundaryEgressProducer))
              value
          )
            { wireValueProvenance =
                Just
                  ( Aeson.object
                      [ "runId" Aeson..= UUID.toText ctx.boundaryEgressRunId
                      , "nodeId" Aeson..= unNodeId ctx.boundaryEgressProducer
                      ]
                  )
            , wireValuePort = Just portName
            }
        )

-- | The ADR 0062 classification of a node's output boundary.
data OutputBoundaryKind
  = -- | No exclusive group: an ordinary product output boundary.
    BoundaryProduct
  | -- | A single exclusive group with no ordinary ports: its declared variant labels.
    BoundaryVariant ![Text]
  | -- | A group mixed with ordinary ports, or several groups: invalid for variant emission.
    BoundaryInvalid !Text

{- | Classify a node's output boundary for ADR 0062. A boundary with no exclusive
group is an ordinary product boundary; a single exclusive group with no ordinary
ports is a variant boundary (carrying its declared variant labels); anything else -
a group mixed with ordinary ports, or several groups - is invalid for variant
emission ("one selected variant plus side outputs" is out of scope).
-}
classifyOutputBoundary :: WirePorts -> OutputBoundaryKind
classifyOutputBoundary ports =
  case Set.toList (Set.fromList groupIds) of
    [] -> BoundaryProduct
    [groupId]
      | null ordinaryPorts ->
          BoundaryVariant
            [name | (name, spec) <- outs, spec.wireOutputPortExclusiveGroup == Just groupId]
      | otherwise ->
          BoundaryInvalid
            "A variant-emitting node must not mix an exclusive output group with ordinary outputs (ADR 0062: one selected variant plus side outputs is out of scope)."
    _ ->
      BoundaryInvalid
        "A variant-emitting node must expose exactly one exclusive output group (ADR 0062)."
  where
    outs = Map.toList ports.wirePortsOutputs
    groupIds = [groupId | (_, spec) <- outs, Just groupId <- [spec.wireOutputPortExclusiveGroup]]
    ordinaryPorts = [name | (name, spec) <- outs, isNothing spec.wireOutputPortExclusiveGroup]

{- | A variant-emitting boundary commits exactly one explicit 'WireValue' whose port
is a declared variant label (ADR 0062). A 'WireValueSet', a raw value, a missing
label, or an undeclared label is rejected.
-}
validateVariantEmission
  :: Maybe WireContractRegistry
  -> BoundaryEgressContext
  -> [Text]
  -> Aeson.Value
  -> Either Text Aeson.Value
validateVariantEmission maybeRegistry ctx variantPorts outputValue =
  case explicitWireOutput outputValue of
    Just (ExplicitWireValue wireValue) ->
      case wireValue.wireValuePort of
        Just portName
          | portName `elem` variantPorts ->
              validateWireValue maybeRegistry ctx.boundaryEgressPorts wireValue *> Right outputValue
          | otherwise ->
              Left
                ( "Emitted variant label "
                    <> portName
                    <> " is not a declared variant. Declared variants: "
                    <> T.intercalate ", " variantPorts
                    <> "."
                )
        Nothing ->
          Left "A variant-emitting node must set the variant label (the WireValue port)."
    Just (ExplicitWireValueSet _) ->
      Left "A variant-emitting node must commit exactly one variant, not a WireValueSet."
    Nothing ->
      Left "A variant-emitting node must commit exactly one explicit variant WireValue."

data ExplicitWireOutput
  = ExplicitWireValue !WireValue
  | ExplicitWireValueSet !WireValueSet

explicitWireOutput :: Aeson.Value -> Maybe ExplicitWireOutput
explicitWireOutput value =
  case (Aeson.fromJSON value :: Aeson.Result WireValue) of
    Aeson.Success wireValue ->
      Just (ExplicitWireValue wireValue)
    Aeson.Error _ ->
      case Aeson.fromJSON value of
        Aeson.Success wireValueSet ->
          Just (ExplicitWireValueSet wireValueSet)
        Aeson.Error _ ->
          Nothing

validateExplicitWireOutput
  :: Maybe WireContractRegistry
  -> WirePorts
  -> ExplicitWireOutput
  -> Either Text ()
validateExplicitWireOutput maybeRegistry ports = \case
  ExplicitWireValue wireValue ->
    validateWireValue maybeRegistry ports wireValue
  ExplicitWireValueSet (WireValueSet wireValues) ->
    traverse_ (validateWireValue maybeRegistry ports) wireValues

validateWireValue
  :: Maybe WireContractRegistry
  -> WirePorts
  -> WireValue
  -> Either Text ()
validateWireValue maybeRegistry ports wireValue = do
  case wireValuePortMatch ports wireValue of
    WireValuePortMatched ->
      pure ()
    WireValuePortMissingContract offeredContracts ->
      Left
        ( "Wire output contract "
            <> wireValue.wireValueContract
            <> " is not offered by this node. Offered contracts: "
            <> T.intercalate ", " (Set.toAscList offeredContracts)
        )
    WireValuePortUnknownPort portName ->
      Left
        ( "Wire output port "
            <> portName
            <> " is not offered by this node. Offered ports: "
            <> T.intercalate ", " (Map.keys ports.wirePortsOutputs)
        )
    WireValuePortContractMismatch portName expectedContract ->
      Left
        ( "Wire output port "
            <> portName
            <> " offers contract "
            <> expectedContract
            <> ", but the explicit WireValue declared "
            <> wireValue.wireValueContract
            <> "."
        )
    WireValuePortAmbiguous candidates ->
      Left
        ( "Wire output contract "
            <> wireValue.wireValueContract
            <> " is offered by multiple output ports ("
            <> T.intercalate ", " candidates
            <> "). Explicit WireValue output must set the port field."
        )
  expectedKind <- payloadKindForContract maybeRegistry wireValue.wireValueContract
  if wireValue.wireValuePayloadKind == expectedKind
    then pure ()
    else
      Left
        ( "Wire output contract "
            <> wireValue.wireValueContract
            <> " has payload kind "
            <> renderWirePayloadKind wireValue.wireValuePayloadKind
            <> ", expected "
            <> renderWirePayloadKind expectedKind
        )
  validateWireValuePayloadShape
    maybeRegistry
    wireValue.wireValueContract
    expectedKind
    wireValue.wireValueValue

data WireValuePortMatch
  = WireValuePortMatched
  | WireValuePortMissingContract !(Set.Set Text)
  | WireValuePortUnknownPort !Text
  | WireValuePortContractMismatch !Text !Text
  | WireValuePortAmbiguous ![Text]

wireValuePortMatch :: WirePorts -> WireValue -> WireValuePortMatch
wireValuePortMatch ports wireValue =
  case wireValue.wireValuePort of
    Just portName ->
      case Map.lookup portName ports.wirePortsOutputs of
        Nothing -> WireValuePortUnknownPort portName
        Just portSpec ->
          if portSpec.wireOutputPortContract == wireValue.wireValueContract
            then WireValuePortMatched
            else WireValuePortContractMismatch portName portSpec.wireOutputPortContract
    Nothing ->
      let offeredContracts =
            Set.fromList (fmap (.wireOutputPortContract) (Map.elems ports.wirePortsOutputs))
          matchingPorts =
            [ portName
            | (portName, portSpec) <- Map.toList ports.wirePortsOutputs
            , portSpec.wireOutputPortContract == wireValue.wireValueContract
            ]
       in case matchingPorts of
            [] -> WireValuePortMissingContract offeredContracts
            [_] -> WireValuePortMatched
            _ -> WireValuePortAmbiguous matchingPorts

{- | ADR 0085 boundary validation: the shallow payload-kind shape check,
deepened by schema validation when the registered contract declares a
schema and the payload kind is @json@ or @artifact_ref@. Contracts without
a declared schema keep the shallow check only.
-}
validateWireValuePayloadShape
  :: Maybe WireContractRegistry -> Text -> WirePayloadKind -> Aeson.Value -> Either Text ()
validateWireValuePayloadShape maybeRegistry contractId payloadKind value = do
  case validateWirePayloadShape payloadKind value of
    Right () -> Right ()
    Left expectedShape ->
      Left
        ( "Wire output contract "
            <> contractId
            <> " has payload kind "
            <> renderWirePayloadKind payloadKind
            <> " but value shape is invalid; expected "
            <> expectedShape
            <> "."
        )
  case contractSchemaForContract maybeRegistry contractId of
    Just schema
      | payloadKind == WirePayloadJson || payloadKind == WirePayloadArtifactRef ->
          case validateJsonValueAgainstSchema contractId schema value of
            Right () -> Right ()
            Left validationError ->
              Left
                ( "Wire output schema validation: "
                    <> renderWireContractValidationError validationError
                )
    _ -> Right ()

contractSchemaForContract :: Maybe WireContractRegistry -> Text -> Maybe Aeson.Value
contractSchemaForContract maybeRegistry contractId = do
  registry <- maybeRegistry
  spec <- Map.lookup contractId registry.wireContractRegistryContracts
  spec.wireContractSpecSchema

payloadKindForContract :: Maybe WireContractRegistry -> Text -> Either Text WirePayloadKind
payloadKindForContract Nothing _contractId =
  Right WirePayloadJson
payloadKindForContract (Just registry) contractId =
  case Map.lookup contractId registry.wireContractRegistryContracts of
    Just spec -> Right spec.wireContractSpecPayloadKind
    Nothing ->
      Left ("Wire contract " <> contractId <> " is not registered at runtime.")
