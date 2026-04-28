{- |
Module      : Cortex.Wire.Runtime
Description : Wire support for runtime.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Runtime
  ( unwrapWireStageInputs
  , unwrapWireStageValue
  , WireInputBundle (..)
  , wireInputBundleFromStageInputs
  , wireInputBundlePromptSummary
  , wrapWireStageOutput
  , wrapWireStageOutputs
  , wrapWireStageResult
  , wrapWireStageDefinition
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageContext (..)
  , StageDefinition (..)
  , StageResult (..)
  )
import Cortex.Wire.Contract (WireContractRegistry (..), WireContractSpec (..))
import Cortex.Wire.Syntax (WireOutputPort (..), WirePorts (..))
import Cortex.Wire.Value
  ( WirePayloadKind (..)
  , WireValue (..)
  , WireValueSet (..)
  , mkWireValue
  , renderWirePayloadKind
  , validateWirePayloadShape
  )

unwrapWireStageInputs :: Map NodeId Aeson.Value -> Map NodeId Aeson.Value
unwrapWireStageInputs =
  fmap unwrapWireStageValue

unwrapWireStageValue :: Aeson.Value -> Aeson.Value
unwrapWireStageValue value =
  case (Aeson.fromJSON value :: Aeson.Result WireValue) of
    Aeson.Success wireValue ->
      wireValue.wireValueValue
    Aeson.Error _ ->
      case Aeson.fromJSON value of
        Aeson.Success (WireValueSet wireValues) ->
          case wireValues of
            [] -> Aeson.Null
            [wireValue] -> wireValue.wireValueValue
            _ -> Aeson.toJSON (fmap (.wireValueValue) wireValues)
        Aeson.Error _ ->
          value

data WireInputBundle = WireInputBundle
  { wireInputBundleOriginalInputs :: !(Map NodeId Aeson.Value)
  , wireInputBundleUnwrappedInputs :: !(Map NodeId Aeson.Value)
  , wireInputBundleValues :: ![WireValue]
  , wireInputBundleByContract :: !(Map Text [WireValue])
  , wireInputBundleByProducer :: !(Map NodeId [WireValue])
  }
  deriving stock (Eq, Show)

wireInputBundleFromStageInputs :: Map NodeId Aeson.Value -> WireInputBundle
wireInputBundleFromStageInputs inputs =
  let valuesByProducer =
        Map.map wireValuesFromStageValue inputs
      allValues =
        concat (Map.elems valuesByProducer)
   in WireInputBundle
        { wireInputBundleOriginalInputs = inputs
        , wireInputBundleUnwrappedInputs = unwrapWireStageInputs inputs
        , wireInputBundleValues = allValues
        , wireInputBundleByContract =
            Map.fromListWith
              (<>)
              [(wireValue.wireValueContract, [wireValue]) | wireValue <- allValues]
        , wireInputBundleByProducer = Map.filter (not . null) valuesByProducer
        }

wireInputBundlePromptSummary :: WireInputBundle -> Text
wireInputBundlePromptSummary inputBundle =
  if null inputBundle.wireInputBundleValues
    then ""
    else
      T.unlines
        ( "Typed Wire inputs:"
            : fmap renderContractGroup (Map.toAscList inputBundle.wireInputBundleByContract)
        )
  where
    renderContractGroup (contractId, wireValues) =
      "- "
        <> contractId
        <> ": "
        <> T.pack (show (length wireValues))
        <> " value(s) from "
        <> renderProducers wireValues
    renderProducers wireValues =
      case Set.toAscList (Set.fromList (mapMaybe (.wireValueProducer) wireValues)) of
        [] -> "unknown producer"
        producerIds -> T.intercalate ", " producerIds

wireValuesFromStageValue :: Aeson.Value -> [WireValue]
wireValuesFromStageValue value =
  case (Aeson.fromJSON value :: Aeson.Result WireValue) of
    Aeson.Success wireValue ->
      [wireValue]
    Aeson.Error _ ->
      case Aeson.fromJSON value of
        Aeson.Success (WireValueSet wireValues) -> wireValues
        Aeson.Error _ -> []

wrapWireStageDefinition
  :: Maybe WireContractRegistry
  -> WirePorts
  -> StageDefinition NodeId
  -> StageDefinition NodeId
wrapWireStageDefinition maybeRegistry ports stageDef =
  stageDef
    { sdAction = \ctx -> do
        let inputBundle = wireInputBundleFromStageInputs ctx.scInputs
            unwrappedCtx =
              ctx
                { scInputs = inputBundle.wireInputBundleUnwrappedInputs
                }
        stageResult <- stageDef.sdAction unwrappedCtx
        case wrapWireStageResult maybeRegistry ctx.scNodeId ctx.scRunId ports stageResult of
          Right wrappedResult -> pure wrappedResult
          Left errText -> fail (T.unpack errText)
    }

wrapWireStageResult
  :: Maybe WireContractRegistry
  -> NodeId
  -> UUID
  -> WirePorts
  -> StageResult NodeId
  -> Either Text (StageResult NodeId)
wrapWireStageResult maybeRegistry producer runId ports = \case
  StageComplete outputValue ->
    StageComplete <$> wrapWireStageOutput maybeRegistry producer runId ports outputValue
  StageRewrite outputValue rewrite ->
    (`StageRewrite` rewrite) <$> wrapWireStageOutput maybeRegistry producer runId ports outputValue
  StageRejectRewrite outputValue rejectedRewrite ->
    (`StageRejectRewrite` rejectedRewrite)
      <$> wrapWireStageOutput maybeRegistry producer runId ports outputValue
  StageSuspend signalName ->
    Right (StageSuspend signalName)

wrapWireStageOutput
  :: Maybe WireContractRegistry
  -> NodeId
  -> UUID
  -> WirePorts
  -> Aeson.Value
  -> Either Text Aeson.Value
wrapWireStageOutput maybeRegistry producer runId ports outputValue =
  case explicitWireOutput outputValue of
    Just wireOutput -> validateExplicitWireOutput maybeRegistry ports wireOutput *> Right outputValue
    Nothing ->
      case outputContracts of
        [] -> Right outputValue
        [contractId] -> do
          outputPortName <-
            case Map.keys ports.wirePortsOutputs of
              [portName] -> Right portName
              _ ->
                Left
                  ( "Wire node "
                      <> unNodeId producer
                      <> " declared one output contract but did not expose exactly one output port."
                  )
          payloadKind <- payloadKindForContract maybeRegistry contractId
          validateWireValuePayloadShape contractId payloadKind outputValue
          let wireValue =
                (mkWireValue contractId payloadKind (Just (unNodeId producer)) outputValue)
                  { wireValueProvenance =
                      Just
                        ( Aeson.object
                            [ "runId" Aeson..= UUID.toText runId
                            , "nodeId" Aeson..= unNodeId producer
                            ]
                        )
                  , wireValuePort = Just outputPortName
                  }
          Right (Aeson.toJSON wireValue)
        _ ->
          Left
            ( "Wire node "
                <> unNodeId producer
                <> " declares multiple output contracts ("
                <> T.intercalate ", " outputContracts
                <> ") but returned a raw JSON value. Return an explicit WireValueSet."
            )
  where
    outputContracts =
      fmap (.wireOutputPortContract) (Map.elems ports.wirePortsOutputs)

wrapWireStageOutputs
  :: Maybe WireContractRegistry
  -> NodeId
  -> UUID
  -> WirePorts
  -> Map Text Aeson.Value
  -> Either Text Aeson.Value
wrapWireStageOutputs maybeRegistry producer runId ports outputValues = do
  let expectedPorts = Map.keysSet ports.wirePortsOutputs
      actualPorts = Map.keysSet outputValues
  if expectedPorts == actualPorts
    then pure ()
    else
      Left
        ( "Wire node "
            <> unNodeId producer
            <> " returned pure output ports "
            <> renderSet actualPorts
            <> ", expected "
            <> renderSet expectedPorts
            <> "."
        )
  wireValues <- traverse outputWireValue (Map.toAscList outputValues)
  let wireValueSet = WireValueSet wireValues
  validateExplicitWireOutput maybeRegistry ports (ExplicitWireValueSet wireValueSet)
  Right (Aeson.toJSON wireValueSet)
  where
    renderSet values =
      "{"
        <> T.intercalate ", " (Set.toAscList values)
        <> "}"

    outputWireValue (portName, value) = do
      outputPort <-
        case Map.lookup portName ports.wirePortsOutputs of
          Just portSpec -> Right portSpec
          Nothing -> Left ("Wire output port " <> portName <> " is not offered by this node.")
      payloadKind <- payloadKindForContract maybeRegistry outputPort.wireOutputPortContract
      validateWireValuePayloadShape outputPort.wireOutputPortContract payloadKind value
      Right
        ( (mkWireValue outputPort.wireOutputPortContract payloadKind (Just (unNodeId producer)) value)
            { wireValueProvenance =
                Just
                  ( Aeson.object
                      [ "runId" Aeson..= UUID.toText runId
                      , "nodeId" Aeson..= unNodeId producer
                      ]
                  )
            , wireValuePort = Just portName
            }
        )

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
  validateWireValuePayloadShape wireValue.wireValueContract expectedKind wireValue.wireValueValue

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

validateWireValuePayloadShape :: Text -> WirePayloadKind -> Aeson.Value -> Either Text ()
validateWireValuePayloadShape contractId payloadKind value =
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

payloadKindForContract :: Maybe WireContractRegistry -> Text -> Either Text WirePayloadKind
payloadKindForContract Nothing _contractId =
  Right WirePayloadJson
payloadKindForContract (Just registry) contractId =
  case Map.lookup contractId registry.wireContractRegistryContracts of
    Just spec -> Right spec.wireContractSpecPayloadKind
    Nothing ->
      Left ("Wire contract " <> contractId <> " is not registered at runtime.")
