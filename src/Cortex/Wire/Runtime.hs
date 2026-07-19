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
  , validateWireExecutorArgument
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageAction
  , StageContext (..)
  , StageDefinition (..)
  , StageResult (..)
  )
import Cortex.Wire.Contract (WireContractRegistry)
import Cortex.Wire.ContractValidation
  ( renderWireContractValidationError
  , validateJsonValueAgainstSchema
  )
import Cortex.Wire.Executor (WireExecutorArgumentShape (..))
import Cortex.Wire.NodeBoundary
  ( BoundaryEgressContext (..)
  , wrapNodeBoundaryOutput
  , wrapNodeBoundaryOutputs
  )
import Cortex.Wire.Syntax (WirePorts)
import Cortex.Wire.Value
  ( WireValue (..)
  , WireValueSet (..)
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

{- | Wrap a host executor binding with the ADR 0095 argument boundary. On each
run the wrapper builds the typed input bundle, evaluates the executor argument
from it, validates the evaluated record against @argument_shape@, and only then
invokes the binding action with that exact value. The base 'StageDefinition'
supplies stage identity and policy fields; its own 'sdAction' is superseded by
the boundary-wrapped binding action.
-}
wrapWireStageDefinition
  :: Maybe WireContractRegistry
  -> WireExecutorArgumentShape
  -> (WireInputBundle -> Either Text Aeson.Value)
  {- ^ Ingress argument evaluator, typically
  'Cortex.Wire.Pure.evaluateWireExecutorArgument' applied to the compiled
  argument envelope.
  -}
  -> WirePorts
  -> (Aeson.Value -> StageAction NodeId)
  -- ^ Binding action receiving the validated one-record argument unchanged.
  -> StageDefinition NodeId
  -> StageDefinition NodeId
wrapWireStageDefinition maybeRegistry argumentShape evaluateArgument ports bindingAction stageDef =
  stageDef
    { sdAction = \ctx -> do
        let inputBundle = wireInputBundleFromStageInputs ctx.scInputs
        case evaluateArgument inputBundle >>= validateWireExecutorArgument argumentShape of
          Left errText ->
            pure (StageFail "executor_argument_validation_failure" errText)
          Right validatedArgument -> do
            let unwrappedCtx =
                  ctx
                    { scInputs = inputBundle.wireInputBundleUnwrappedInputs
                    }
            stageResult <- bindingAction validatedArgument unwrappedCtx
            case wrapWireStageResult maybeRegistry ctx.scNodeId ctx.scRunId ports stageResult of
              Right wrappedResult -> pure wrappedResult
              -- An output that fails contract/variant validation is a typed terminal
              -- failure (ADR 0062), not an untyped stage exception.
              Left errText -> pure (StageFail "executor_output_validation_failure" errText)
    }

{- | Validate the normalized one-record executor argument and return that exact
value for delivery to the host binding. Validation therefore happens before
invocation without decoding or rebuilding the binding payload.
-}
validateWireExecutorArgument
  :: WireExecutorArgumentShape -> Aeson.Value -> Either Text Aeson.Value
validateWireExecutorArgument shape argument = do
  case argument of
    Aeson.Object _ -> Right ()
    _ -> Left "Wire executor argument must be a normalized JSON object"
  case shape of
    WireExecutorArgumentUnchecked -> Right argument
    WireExecutorArgumentSchema schema ->
      case validateJsonValueAgainstSchema "executor argument" schema argument of
        Right () -> Right argument
        Left validationError ->
          Left
            ( "Wire executor argument validation: "
                <> renderWireContractValidationError validationError
            )

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
  StageLoopStep outputValue witness rewrite ->
    (\wrapped -> StageLoopStep wrapped witness rewrite)
      <$> wrapWireStageOutput maybeRegistry producer runId ports outputValue
  StageRejectRewrite outputValue rejectedRewrite ->
    (`StageRejectRewrite` rejectedRewrite)
      <$> wrapWireStageOutput maybeRegistry producer runId ports outputValue
  StageSuspend signalName ->
    Right (StageSuspend signalName)
  StageFail errType message ->
    Right (StageFail errType message)

wrapWireStageOutput
  :: Maybe WireContractRegistry
  -> NodeId
  -> UUID
  -> WirePorts
  -> Aeson.Value
  -> Either Text Aeson.Value
wrapWireStageOutput maybeRegistry producer runId ports =
  wrapNodeBoundaryOutput
    maybeRegistry
    BoundaryEgressContext
      { boundaryEgressProducer = producer
      , boundaryEgressRunId = runId
      , boundaryEgressPorts = ports
      }

wrapWireStageOutputs
  :: Maybe WireContractRegistry
  -> NodeId
  -> UUID
  -> WirePorts
  -> Map Text Aeson.Value
  -> Either Text Aeson.Value
wrapWireStageOutputs maybeRegistry producer runId ports =
  wrapNodeBoundaryOutputs
    maybeRegistry
    BoundaryEgressContext
      { boundaryEgressProducer = producer
      , boundaryEgressRunId = runId
      , boundaryEgressPorts = ports
      }
