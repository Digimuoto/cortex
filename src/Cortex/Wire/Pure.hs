{- |
Module      : Cortex.Wire.Pure
Description : Deterministic Wire pure evaluator.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pure nodes are authored as output equations and lowered to one host-bound
native pure task. The evaluator receives only already-wrapped Wire inputs and a
CorePure AST; it has no host callbacks, IO, time, randomness, model access,
or executor authority.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Pure
  ( PureEvalError (..)
  , CorePureBuiltinAuthority (..)
  , CorePureBuiltinAuthorityReport (..)
  , CorePureStaticContext (..)
  , PreparedPureTask
  , renderPureEvalError
  , validatePurePorts
  , validateCorePureExpr
  , validatePureTaskConfig
  , validatePureVariantTaskConfig
  , preparePureTaskOutputs
  , corePureStaticContextFromBindings
  , corePureWhereStaticFields
  , bindPureInputValues
  , evaluatePureTaskOutputs
  , evaluatePureTaskVariant
  , evaluatePreparedPureTaskOutputs
  , WireExecutorArgumentSpec (..)
  , wireExecutorArgumentSpecFromMetadata
  , evaluateWireExecutorArgument
  , corePureBuiltinSignature
  , corePureBuiltinAuthorityReport
  , corePureBuiltinAuthorityFree
  , pureWireExecutorId
  , pureWireExecutorProjection
  , pureExecutorArgumentSchema
  , canonicalJson
  )
where

import Control.Monad (foldM, unless, (>=>))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char qualified as Char
import Data.Foldable (traverse_)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, toBoundedInteger)
import Data.Scientific qualified as Scientific
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

import Cortex.Wire.Executor
  ( WireExecutorArgumentShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  )
import Cortex.Wire.Pure.Bounds
  ( FoldAccumulator
  , clampIndex
  , clampedIndexValue
  , corePureBoundedIterationCap
  , foldAccumulatorValue
  , foldRangePlan
  , mkFoldAccumulator
  , planRange
  )
import Cortex.Wire.Runtime (WireInputBundle (..))
import Cortex.Wire.Syntax
  ( CorePureBinOp (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , CorePureUnaryOp (..)
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  , defaultInputPortName
  )
import Cortex.Wire.Value (WirePayloadKind (..), WireValue (..), renderWirePayloadKind)

data PureEvalError
  = PureMissingVariable !Text
  | PureDivisionByZero
  | PureNonFiniteFloatDivision !PureNonFiniteFloatDivisionOperands
  | PureInputPortUnsupported !Text !Text
  | PureInputPortRequiresLabel !Text !Text
  | PureInputPortMissing !Text !Text
  | PureInputPortAmbiguous !Text !Int
  | PureInputPayloadKindMismatch !Text !WirePayloadKind
  | PureOutputPortsUnsupported !Text
  | PureOutputPortsMismatch ![Text] ![Text]
  | PureTypeMismatch !Text !Text
  | PureFieldMissing !Text
  | PureIndexOutOfBounds !Int
  | PureFunctionExpected !Text
  | PureFunctionArity !Text !Int !Int
  | PureDuplicateBinding !Text
  | PureDuplicateLambdaParam !Text
  | PureDuplicateRecordFieldPath ![Text] ![Text]
  | PureJsonParseError !Text
  | PureBoundExceeded !Text
  | PureWhereExpectedRecord !Text
  | PureStaticFieldSetUndeterminable
  | PureStaticBindingCycle !Text
  | PureStaticLetShadowsStatic !Text
  | PureVariantBoundaryInvalid !Text
  | PureVariantConstructorExpected ![Text]
  | PureVariantConstructorArity !Text !Int
  | PureVariantLabelShadowed !Text
  deriving stock (Eq, Show, Generic)

data PureNonFiniteFloatDivisionOperands = PureNonFiniteFloatDivisionOperands
  { pnffNumerator :: !Text
  , pnffDenominator :: !Text
  }
  deriving stock (Eq, Show)

data CorePureBuiltinAuthority
  = CorePureBuiltinPureValue
  deriving stock (Eq, Show, Generic)

data CorePureBuiltinAuthorityReport = CorePureBuiltinAuthorityReport
  { corePureBuiltinAuthorityName :: !Text
  , corePureBuiltinAuthorityArity :: !Int
  , corePureBuiltinAuthority :: !CorePureBuiltinAuthority
  }
  deriving stock (Eq, Show, Generic)

newtype CorePureStaticContext = CorePureStaticContext
  { corePureStaticContextFields :: Map Text (Set Text)
  }
  deriving stock (Eq, Show, Generic)

data PreparedPureTask = PreparedPureTask
  { preparedPureTaskPorts :: !WirePorts
  , preparedPureTaskInputs :: ![PreparedPureInput]
  , preparedPureTaskBindings :: ![CorePureBinding]
  , preparedPureTaskWhere :: !(Maybe CorePureExpr)
  , preparedPureTaskOutputs :: !(Map Text CorePureExpr)
  }
  deriving stock (Eq, Show, Generic)

data PreparedPureInput = PreparedPureInput
  { preparedPureInputPortName :: !Text
  , preparedPureInputContract :: !Text
  , preparedPureInputDefaultPort :: !Bool
  }
  deriving stock (Eq, Show, Generic)

renderPureEvalError :: PureEvalError -> Text
renderPureEvalError = \case
  PureMissingVariable variableName ->
    "Pure expression references missing variable " <> variableName <> "."
  PureDivisionByZero ->
    "Pure expression attempted division by zero."
  PureNonFiniteFloatDivision PureNonFiniteFloatDivisionOperands {pnffNumerator, pnffDenominator} ->
    "Pure expression attempted finite Float64 division outside finite range: "
      <> pnffNumerator
      <> " / "
      <> pnffDenominator
      <> "."
  PureInputPortUnsupported portName reason ->
    "Pure input port " <> portName <> " is unsupported: " <> reason <> "."
  PureInputPortRequiresLabel portName contractId ->
    "Pure input port "
      <> portName
      <> " for repeated contract "
      <> contractId
      <> " must be labeled explicitly."
  PureInputPortMissing portName contractId ->
    "Pure input port "
      <> portName
      <> " expected one WireValue for contract "
      <> contractId
      <> "."
  PureInputPortAmbiguous portName count ->
    "Pure input port "
      <> portName
      <> " matched "
      <> T.pack (show count)
      <> " WireValues."
  PureInputPayloadKindMismatch portName payloadKind ->
    "Pure input port "
      <> portName
      <> " expected a JSON WireValue but received payload kind "
      <> renderWirePayloadKind payloadKind
      <> "."
  PureOutputPortsUnsupported reason ->
    "Pure output ports are unsupported: " <> reason <> "."
  PureOutputPortsMismatch expected actual ->
    "Pure output equations must match output ports exactly. Expected "
      <> renderList expected
      <> ", got "
      <> renderList actual
      <> "."
  PureTypeMismatch expected actual ->
    "Pure expression expected " <> expected <> " but received " <> actual <> "."
  PureFieldMissing fieldName ->
    "Pure expression referenced missing field " <> fieldName <> "."
  PureIndexOutOfBounds index ->
    "Pure expression referenced out-of-bounds index " <> T.pack (show index) <> "."
  PureFunctionExpected actual ->
    "Pure expression expected a function but received " <> actual <> "."
  PureFunctionArity functionName expected actual ->
    "Pure function "
      <> functionName
      <> " expected "
      <> T.pack (show expected)
      <> " argument(s) but received "
      <> T.pack (show actual)
      <> "."
  PureDuplicateBinding bindingName ->
    "Pure expression declares binding " <> bindingName <> " more than once in the same scope."
  PureDuplicateLambdaParam paramName ->
    "Pure expression declares lambda parameter " <> paramName <> " more than once."
  PureDuplicateRecordFieldPath leftPath rightPath ->
    "Pure record literal declares conflicting field paths "
      <> renderRecordPath leftPath
      <> " and "
      <> renderRecordPath rightPath
      <> "."
  PureJsonParseError reason ->
    "Pure expression could not parse JSON: " <> reason <> "."
  PureBoundExceeded boundName ->
    "Pure expression exceeded the fixed CorePure " <> boundName <> " bound."
  PureWhereExpectedRecord actual ->
    "Pure where-clause must evaluate to a record, but received " <> actual <> "."
  PureStaticFieldSetUndeterminable ->
    "Pure where-clause field set is not statically determinable."
  PureStaticBindingCycle bindingName ->
    "Pure where-clause field discovery found a cyclic top-level binding at " <> bindingName <> "."
  PureStaticLetShadowsStatic bindingName ->
    "Pure where-clause local let binding shadows statically known binding " <> bindingName <> "."
  PureVariantBoundaryInvalid reason ->
    "Pure variant boundary is invalid: " <> reason <> "."
  PureVariantConstructorExpected labels ->
    "Every pure sum control-flow path must return one declared constructor ("
      <> T.intercalate ", " labels
      <> ")."
  PureVariantConstructorArity label actual ->
    "Pure sum constructor "
      <> label
      <> " requires exactly one payload argument, received "
      <> T.pack (show actual)
      <> "."
  PureVariantLabelShadowed label ->
    "Pure sum constructor label " <> label <> " is shadowed by a local binding."
  where
    renderList values =
      "[" <> T.intercalate ", " values <> "]"

    renderRecordPath =
      T.intercalate "."

validatePurePorts :: WirePorts -> Map Text CorePureExpr -> Either PureEvalError ()
validatePurePorts ports outputExprs =
  preparePureInputs ports *> validatePureOutputPorts ports outputExprs

validatePureTaskConfig
  :: WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError ()
validatePureTaskConfig ports bindings whereExpr outputExprs =
  validatePurePorts ports outputExprs
    *> validateCorePureTaskExpressions bindings whereExpr outputExprs

validatePureVariantTaskConfig
  :: WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> [Text]
  -> CorePureExpr
  -> Either PureEvalError ()
validatePureVariantTaskConfig ports bindings whereExpr labels bodyExpr = do
  _ <- preparePureInputs ports
  validateVariantBoundary ports labels
  validateCorePureBindingNames bindings
  traverse_ (validateCorePureExpr . (.corePureBindingExpr)) bindings
  traverse_ validateCorePureExpr whereExpr
  validateCorePureExpr bodyExpr
  traverse_ (rejectShadowed . (.corePureBindingName)) bindings
  traverse_ rejectShadowed (Map.keys ports.wirePortsInputs)
  staticContext <- corePureStaticContextFromBindings bindings
  whereFields <- maybe (Right Set.empty) (corePureWhereStaticFields staticContext) whereExpr
  traverse_ rejectShadowed (Set.toList whereFields)
  validateVariantResult labels bodyExpr
  where
    rejectShadowed name
      | name `elem` labels = Left (PureVariantLabelShadowed name)
      | otherwise = Right ()

validateVariantBoundary :: WirePorts -> [Text] -> Either PureEvalError ()
validateVariantBoundary ports labels
  | length labels < 2 = invalid "an exclusive sum requires at least two labels"
  | any (T.null . T.strip) labels = invalid "declared labels must not be blank"
  | Set.size (Set.fromList labels) /= length labels = invalid "declared labels must be unique"
  | otherwise =
      case Set.toList groups of
        [group]
          | expected == Set.fromList labels
          , all ((== Just group) . (.wireOutputPortExclusiveGroup)) outputPorts ->
              Right ()
        _ -> invalid "declared labels must exactly match one exclusive output group"
  where
    invalid = Left . PureVariantBoundaryInvalid
    expected = Map.keysSet ports.wirePortsOutputs
    outputPorts = Map.elems ports.wirePortsOutputs
    groups =
      Set.fromList
        [ group
        | port <- outputPorts
        , Just group <- [port.wireOutputPortExclusiveGroup]
        ]

validateVariantResult :: [Text] -> CorePureExpr -> Either PureEvalError ()
validateVariantResult labels = go Set.empty
  where
    labelSet = Set.fromList labels

    go locals = \case
      CorePureIf _condition thenExpr elseExpr ->
        go locals thenExpr *> go locals elseExpr
      CorePureLet bindings bodyExpr -> do
        let names = fmap (.corePureBindingName) (NE.toList bindings)
        case filter (`Set.member` labelSet) names of
          shadowed : _ -> Left (PureVariantLabelShadowed shadowed)
          [] -> go (locals <> Set.fromList names) bodyExpr
      CorePureCall (CorePureIdent label) arguments
        | label `Set.member` labelSet && label `Set.notMember` locals ->
            case arguments of
              [_payload] -> Right ()
              _ -> Left (PureVariantConstructorArity label (length arguments))
      _ -> Left (PureVariantConstructorExpected labels)

preparePureTaskOutputs
  :: WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError PreparedPureTask
preparePureTaskOutputs ports bindings whereExpr outputExprs = do
  preparedInputs <- preparePureInputs ports
  validatePureOutputPorts ports outputExprs
  validateCorePureTaskExpressions bindings whereExpr outputExprs
  Right
    PreparedPureTask
      { preparedPureTaskPorts = ports
      , preparedPureTaskInputs = preparedInputs
      , preparedPureTaskBindings = bindings
      , preparedPureTaskWhere = whereExpr
      , preparedPureTaskOutputs = outputExprs
      }

corePureStaticContextFromBindings
  :: [CorePureBinding] -> Either PureEvalError CorePureStaticContext
corePureStaticContextFromBindings bindings = do
  validateCorePureBindingNames bindings
  let preliminaryFields =
        [ (binding.corePureBindingName, fields)
        | binding <- bindings
        , Right fields <- [corePureStaticFieldsFromBindings bindings Set.empty binding.corePureBindingExpr]
        ]
      preliminaryContext = CorePureStaticContext (Map.fromList preliminaryFields)
      checkedFields =
        [ (binding.corePureBindingName, fields)
        | binding <- bindings
        , Right fields <- [staticFieldsFromContext preliminaryContext binding.corePureBindingExpr]
        ]
  Right (CorePureStaticContext (Map.fromList checkedFields))

corePureWhereStaticFields
  :: CorePureStaticContext -> CorePureExpr -> Either PureEvalError (Set Text)
corePureWhereStaticFields =
  staticFieldsFromContext

staticFieldsFromContext
  :: CorePureStaticContext -> CorePureExpr -> Either PureEvalError (Set Text)
staticFieldsFromContext ctx = \case
  CorePureRecord fields ->
    Right (Set.fromList [NE.head field.corePureFieldPath | field <- fields])
  CorePureLet bindings bodyExpr -> do
    validateStaticLetBindings ctx (NE.toList bindings)
    staticFieldsFromContext ctx bodyExpr
  CorePureIdent name ->
    case Map.lookup name ctx.corePureStaticContextFields of
      Just fields -> Right fields
      Nothing -> Left PureStaticFieldSetUndeterminable
  CorePureBinary CorePureMerge lhs rhs ->
    Set.union <$> staticFieldsFromContext ctx lhs <*> staticFieldsFromContext ctx rhs
  _ ->
    Left PureStaticFieldSetUndeterminable

validateStaticLetBindings
  :: CorePureStaticContext -> [CorePureBinding] -> Either PureEvalError ()
validateStaticLetBindings ctx =
  traverse_ validateBinding
  where
    validateBinding binding =
      case Map.lookup binding.corePureBindingName ctx.corePureStaticContextFields of
        Just _fields -> Left (PureStaticLetShadowsStatic binding.corePureBindingName)
        Nothing -> Right ()

corePureStaticFieldsFromBindings
  :: [CorePureBinding] -> Set Text -> CorePureExpr -> Either PureEvalError (Set Text)
corePureStaticFieldsFromBindings bindings visited = \case
  CorePureRecord fields ->
    Right (Set.fromList [NE.head field.corePureFieldPath | field <- fields])
  CorePureLet _ bodyExpr ->
    corePureStaticFieldsFromBindings bindings visited bodyExpr
  CorePureIdent name
    | Set.member name visited ->
        Left (PureStaticBindingCycle name)
    | otherwise ->
        case lookupBinding name of
          Just bindingExpr ->
            corePureStaticFieldsFromBindings bindings (Set.insert name visited) bindingExpr
          Nothing ->
            Left PureStaticFieldSetUndeterminable
  CorePureBinary CorePureMerge lhs rhs ->
    Set.union
      <$> corePureStaticFieldsFromBindings bindings visited lhs
      <*> corePureStaticFieldsFromBindings bindings visited rhs
  _ ->
    Left PureStaticFieldSetUndeterminable
  where
    lookupBinding name =
      case [binding.corePureBindingExpr | binding <- bindings, binding.corePureBindingName == name] of
        bindingExpr : _ -> Just bindingExpr
        [] -> Nothing

preparePureInputs :: WirePorts -> Either PureEvalError [PreparedPureInput]
preparePureInputs ports =
  traverse
    prepareInputPort
    (Map.toAscList ports.wirePortsInputs)
  where
    inputContractCounts = pureInputContractCounts ports

    prepareInputPort (portName, inputPort) = do
      contractId <- exactPureInputContract portName inputPort
      if repeatedGeneratedPurePortName inputContractCounts portName contractId
        then Left (PureInputPortRequiresLabel portName contractId)
        else
          Right
            PreparedPureInput
              { preparedPureInputPortName = portName
              , preparedPureInputContract = contractId
              , preparedPureInputDefaultPort =
                  Map.size ports.wirePortsInputs == 1 && portName == defaultInputPortName
              }

validatePureOutputPorts :: WirePorts -> Map Text CorePureExpr -> Either PureEvalError ()
validatePureOutputPorts ports outputExprs =
  let expected = Map.keys ports.wirePortsOutputs
      actual = Map.keys outputExprs
   in if expected == actual
        then Right ()
        else Left (PureOutputPortsMismatch expected actual)

pureInputContractCounts :: WirePorts -> Map Text Int
pureInputContractCounts ports =
  Map.fromListWith
    (+)
    [ (contractId, 1 :: Int)
    | inputPort <- Map.elems ports.wirePortsInputs
    , contractId <- inputPort.wireInputPortAccepts
    ]

exactPureInputContract :: Text -> WireInputPort -> Either PureEvalError Text
exactPureInputContract portName inputPort =
  case inputPort.wireInputPortAccepts of
    [contractId]
      | inputPort.wireInputPortCardinality == WireInputCardinalityOne ->
          Right contractId
      | otherwise ->
          Left (PureInputPortUnsupported portName "list inputs are not supported by pure output equations")
    [] ->
      Left (PureInputPortUnsupported portName "no accepted contract")
    _ ->
      Left (PureInputPortUnsupported portName "multiple accepted contracts")

repeatedGeneratedPurePortName :: Map Text Int -> Text -> Text -> Bool
repeatedGeneratedPurePortName inputContractCounts portName contractId =
  Map.findWithDefault 0 contractId inputContractCounts > 1
    && generatedPurePortName contractId portName

generatedPurePortName :: Text -> Text -> Bool
generatedPurePortName contractId portName =
  let prefix = contractId <> "_"
      suffix = T.drop (T.length prefix) portName
   in prefix `T.isPrefixOf` portName && not (T.null suffix) && T.all Char.isDigit suffix

bindPureInputValues :: WirePorts -> WireInputBundle -> Either PureEvalError (Map Text Aeson.Value)
bindPureInputValues ports inputBundle = do
  preparedInputs <- preparePureInputs ports
  bindPreparedPureInputValues id preparedInputs inputBundle

bindPreparedPureInputValues
  :: (Aeson.Value -> value)
  -> [PreparedPureInput]
  -> WireInputBundle
  -> Either PureEvalError (Map Text value)
bindPreparedPureInputValues wrapValue preparedInputs inputBundle =
  Map.fromList <$> traverse bindInputPort preparedInputs
  where
    bindInputPort preparedInput = do
      let portName = preparedInput.preparedPureInputPortName
      wireValue <- singleMatchedValue preparedInput
      value <- wireValueJson portName wireValue
      Right (portName, wrapValue value)

    singleMatchedValue preparedInput =
      case matchedWireValues preparedInput of
        [wireValue] -> Right wireValue
        [] ->
          Left
            ( PureInputPortMissing
                preparedInput.preparedPureInputPortName
                preparedInput.preparedPureInputContract
            )
        values -> Left (PureInputPortAmbiguous preparedInput.preparedPureInputPortName (length values))

    matchedWireValues preparedInput =
      [ wireValue
      | wireValue <- inputBundle.wireInputBundleValues
      , wireValue.wireValueContract == preparedInput.preparedPureInputContract
      , inputValueMatchesPort preparedInput wireValue
      ]

    inputValueMatchesPort preparedInput wireValue
      | preparedInput.preparedPureInputDefaultPort =
          True
      | otherwise =
          wireValue.wireValuePort == Just preparedInput.preparedPureInputPortName

wireValueJson :: Text -> WireValue -> Either PureEvalError Aeson.Value
wireValueJson portName wireValue
  | wireValue.wireValuePayloadKind /= WirePayloadJson =
      Left (PureInputPayloadKindMismatch portName wireValue.wireValuePayloadKind)
  | otherwise =
      Right wireValue.wireValueValue

evaluatePureTaskOutputs
  :: WirePorts
  -> WireInputBundle
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError (Map Text Aeson.Value)
evaluatePureTaskOutputs ports inputBundle bindings whereExpr outputExprs = do
  preparedTask <- preparePureTaskOutputs ports bindings whereExpr outputExprs
  evaluatePreparedPureTaskOutputs preparedTask inputBundle

evaluatePureTaskVariant
  :: WirePorts
  -> WireInputBundle
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> [Text]
  -> CorePureExpr
  -> Either PureEvalError (Map Text Aeson.Value)
evaluatePureTaskVariant ports inputBundle bindings whereExpr labels bodyExpr = do
  validatePureVariantTaskConfig ports bindings whereExpr labels bodyExpr
  preparedInputs <- preparePureInputs ports
  inputEnv <- bindPreparedPureInputValues CorePureJson preparedInputs inputBundle
  outerEnv <- bindCorePureBindings (corePureEnvFromInputValues inputEnv) bindings
  env <- bindCorePureWhere outerEnv whereExpr
  (label, payload) <- evaluateVariantResult labels env bodyExpr
  pure (Map.singleton label payload)

evaluateVariantResult
  :: [Text]
  -> CorePureEnv
  -> CorePureExpr
  -> Either PureEvalError (Text, Aeson.Value)
evaluateVariantResult labels env = \case
  CorePureIf condition thenExpr elseExpr -> do
    conditionValue <- evaluateCorePureExpr env condition >>= corePureValueToJson
    case conditionValue of
      Aeson.Bool True -> evaluateVariantResult labels env thenExpr
      Aeson.Bool False -> evaluateVariantResult labels env elseExpr
      other -> Left (PureTypeMismatch "boolean" (jsonValueKind other))
  CorePureLet bindings bodyExpr -> do
    localEnv <- bindCorePureBindings env (NE.toList bindings)
    evaluateVariantResult labels localEnv bodyExpr
  CorePureCall (CorePureIdent label) [payloadExpr] -> do
    payload <- evaluateCorePureExpr env payloadExpr >>= corePureValueToJson
    pure (label, payload)
  _ -> Left (PureVariantConstructorExpected labels)

{- | Compiled executor-argument envelope: the normalized one-record argument
expression together with the module-level CorePure bindings and node @where@
record it may reference.
-}
data WireExecutorArgumentSpec = WireExecutorArgumentSpec
  { wireExecutorArgumentExpr :: !CorePureExpr
  , wireExecutorArgumentBindings :: ![CorePureBinding]
  , wireExecutorArgumentWhere :: !(Maybe CorePureExpr)
  }
  deriving stock (Eq, Show)

{- | Decode the @argument@ envelope from compiled executor task metadata.
Unknown envelope fields are rejections: the envelope is a versioned compiler
artifact, not a forward-compatible surface.
-}
wireExecutorArgumentSpecFromMetadata :: Aeson.Value -> Either Text WireExecutorArgumentSpec
wireExecutorArgumentSpecFromMetadata metadataValue = do
  metadataObject <-
    case metadataValue of
      Aeson.Object obj -> Right obj
      _ -> Left "executor task metadata must be a JSON object"
  argumentValue <-
    case KeyMap.lookup "argument" metadataObject of
      Just value -> Right value
      Nothing -> Left "executor task metadata is missing the argument envelope"
  argumentObject <-
    case argumentValue of
      Aeson.Object obj -> Right obj
      _ -> Left "executor argument envelope must be a JSON object"
  let unknownKeys =
        [ keyText
        | key <- KeyMap.keys argumentObject
        , let keyText = Key.toText key
        , keyText /= "value" && keyText /= "bindings" && keyText /= "where"
        ]
  unless (null unknownKeys) $
    Left ("unsupported executor argument envelope fields: " <> T.intercalate ", " unknownKeys)
  exprValue <-
    case KeyMap.lookup "value" argumentObject of
      Just value -> Right value
      Nothing -> Left "executor argument envelope is missing the value field"
  argumentExpr <- decodeEnvelopeField "executor argument value" exprValue
  bindings <-
    maybe
      (Right [])
      (decodeEnvelopeField "executor argument bindings")
      (KeyMap.lookup "bindings" argumentObject)
  whereExpr <-
    traverse
      (decodeEnvelopeField "executor argument where")
      (KeyMap.lookup "where" argumentObject)
  Right
    WireExecutorArgumentSpec
      { wireExecutorArgumentExpr = argumentExpr
      , wireExecutorArgumentBindings = bindings
      , wireExecutorArgumentWhere = whereExpr
      }
  where
    decodeEnvelopeField :: Aeson.FromJSON a => Text -> Aeson.Value -> Either Text a
    decodeEnvelopeField label value =
      case Aeson.fromJSON value of
        Aeson.Success decoded -> Right decoded
        Aeson.Error err -> Left (label <> ": " <> T.pack err)

{- | Evaluate a compiled executor argument at node ingress: bind the node's
input ports, module-level CorePure bindings, and the node @where@ record, then
evaluate the normalized one-record argument expression to the exact JSON value
the host binding receives. This is the evaluation step ADR 0095 sequences
before 'Cortex.Wire.Runtime.validateWireExecutorArgument' and host invocation.
-}
evaluateWireExecutorArgument
  :: WirePorts
  -> WireExecutorArgumentSpec
  -> WireInputBundle
  -> Either PureEvalError Aeson.Value
evaluateWireExecutorArgument ports spec inputBundle = do
  preparedInputs <- preparePureInputs ports
  inputEnv <- bindPreparedPureInputValues CorePureJson preparedInputs inputBundle
  outerEnv <-
    bindCorePureBindings
      (corePureEnvFromInputValues inputEnv)
      spec.wireExecutorArgumentBindings
  env <- bindCorePureWhere outerEnv spec.wireExecutorArgumentWhere
  evaluateCorePureExpr env spec.wireExecutorArgumentExpr >>= corePureValueToJson

evaluatePreparedPureTaskOutputs
  :: PreparedPureTask
  -> WireInputBundle
  -> Either PureEvalError (Map Text Aeson.Value)
evaluatePreparedPureTaskOutputs preparedTask inputBundle = do
  inputEnv <- bindPreparedPureInputValues CorePureJson preparedTask.preparedPureTaskInputs inputBundle
  let baseEnv = corePureEnvFromInputValues inputEnv
  -- Fast paths are optional specializations for common CorePure AST shapes.
  -- Each recognizer must decline when user bindings shadow the builtin names it
  -- depends on, then the generic evaluator below remains the source of truth.
  -- Any matched path must preserve the same errors and output JSON shape as the
  -- slow path; tests cover both shadowing and error-equivalence cases.
  case evaluateCollectionSummaryFastPath baseEnv preparedTask of
    Just result ->
      result
    Nothing -> do
      case evaluateNumericMapSummaryFastPath baseEnv preparedTask of
        Just result ->
          result
        Nothing -> do
          outerEnv <- bindCorePureBindings baseEnv preparedTask.preparedPureTaskBindings
          env <- bindCorePureWhere outerEnv preparedTask.preparedPureTaskWhere
          traverse (evaluateOutput env) preparedTask.preparedPureTaskOutputs
  where
    evaluateOutput env outputExpr = do
      value <- evaluateCorePureExpr env outputExpr
      corePureValueToJson value

data CollectionSummarySpec = CollectionSummarySpec
  { collectionSummaryOutputName :: !Text
  , collectionSummarySourceExpr :: !CorePureExpr
  , collectionSummaryPredicate :: !(Aeson.Value -> Either PureEvalError Bool)
  , collectionSummaryProjectionField :: !Text
  , collectionSummaryCountField :: !Text
  , collectionSummaryTotalField :: !Text
  }

evaluateCollectionSummaryFastPath
  :: CorePureEnv -> PreparedPureTask -> Maybe (Either PureEvalError (Map Text Aeson.Value))
evaluateCollectionSummaryFastPath baseEnv preparedTask = do
  spec <- collectionSummarySpec preparedTask
  Just $ do
    sourceValue <- evaluateCorePureExpr baseEnv spec.collectionSummarySourceExpr
    values <- corePureArray sourceValue
    (accepted, total) <-
      Vector.foldM'
        (accumulateCollectionSummary spec)
        (0 :: Int, 0)
        values
    let output =
          Aeson.Object $
            KeyMap.fromList
              [ (Key.fromText spec.collectionSummaryCountField, Aeson.Number (fromIntegral accepted))
              , (Key.fromText spec.collectionSummaryTotalField, Aeson.Number total)
              ]
    Right (Map.singleton spec.collectionSummaryOutputName output)

accumulateCollectionSummary
  :: CollectionSummarySpec
  -> (Int, Scientific)
  -> Aeson.Value
  -> Either PureEvalError (Int, Scientific)
accumulateCollectionSummary spec (count, total) value = do
  keep <- spec.collectionSummaryPredicate value
  if keep
    then do
      projectedValue <- projectJsonField spec.collectionSummaryProjectionField value
      number <- jsonNumber projectedValue
      Right (count + 1, total + number)
    else Right (count, total)

collectionSummarySpec :: PreparedPureTask -> Maybe CollectionSummarySpec
collectionSummarySpec preparedTask = do
  (outputName, outputExpr) <- singleMapEntry preparedTask.preparedPureTaskOutputs
  outputFields <- topLevelRecordFields outputExpr
  (sourceExpr, predicate, projectionField, countField, totalField) <-
    case preparedTask.preparedPureTaskBindings of
      [filterBinding, mapBinding] -> do
        (filteredName, sourceExpr, predicate) <- collectionFilterBinding filterBinding
        (mappedName, projectionField) <- collectionMapBinding filteredName mapBinding
        if collectionSummaryBindingsShadowBuiltins filteredName mappedName
          then Nothing
          else do
            (countField, totalField) <-
              collectionSummaryOutputFields filteredName mappedName outputFields
            Just (sourceExpr, predicate, projectionField, countField, totalField)
      _ ->
        Nothing
  case preparedTask.preparedPureTaskWhere of
    Nothing ->
      Just
        CollectionSummarySpec
          { collectionSummaryOutputName = outputName
          , collectionSummarySourceExpr = sourceExpr
          , collectionSummaryPredicate = predicate
          , collectionSummaryProjectionField = projectionField
          , collectionSummaryCountField = countField
          , collectionSummaryTotalField = totalField
          }
    Just _whereExpr ->
      Nothing

collectionFilterBinding
  :: CorePureBinding
  -> Maybe (Text, CorePureExpr, Aeson.Value -> Either PureEvalError Bool)
collectionFilterBinding binding =
  case binding.corePureBindingExpr of
    CorePureCall (CorePureIdent "filter") [CorePureLambda params predicateExpr, sourceExpr] -> do
      predicate <- jsonFilterPredicate params predicateExpr
      Just (binding.corePureBindingName, sourceExpr, predicate)
    _ ->
      Nothing

collectionMapBinding :: Text -> CorePureBinding -> Maybe (Text, Text)
collectionMapBinding filteredName binding =
  case binding.corePureBindingExpr of
    CorePureCall
      (CorePureIdent "map")
      [ CorePureLambda params (CorePureFieldAccess (CorePureIdent baseName) fieldName)
        , CorePureIdent sourceName
        ]
        | [paramName] <- NE.toList params
        , baseName == paramName
        , sourceName == filteredName ->
            Just (binding.corePureBindingName, fieldName)
    _ ->
      Nothing

collectionSummaryOutputFields :: Text -> Text -> [(Text, CorePureExpr)] -> Maybe (Text, Text)
collectionSummaryOutputFields filteredName mappedName outputFields =
  case outputFields of
    [_, _] -> do
      countField <- collectionLengthField filteredName outputFields
      totalField <- collectionSumField mappedName outputFields
      Just (countField, totalField)
    _ ->
      Nothing

collectionLengthField :: Text -> [(Text, CorePureExpr)] -> Maybe Text
collectionLengthField filteredName =
  fmap fst . List.find (isLengthOf filteredName . snd)

collectionSumField :: Text -> [(Text, CorePureExpr)] -> Maybe Text
collectionSumField mappedName =
  fmap fst . List.find (isSumOf mappedName . snd)

isLengthOf :: Text -> CorePureExpr -> Bool
isLengthOf bindingName = \case
  CorePureCall (CorePureIdent "length") [CorePureIdent name] ->
    name == bindingName
  _ ->
    False

isSumOf :: Text -> CorePureExpr -> Bool
isSumOf bindingName = \case
  CorePureCall (CorePureIdent "sum") [CorePureIdent name] ->
    name == bindingName
  _ ->
    False

collectionSummaryBindingsShadowBuiltins :: Text -> Text -> Bool
collectionSummaryBindingsShadowBuiltins filteredName mappedName =
  filteredName `elem` builtinNames || mappedName `elem` builtinNames
  where
    builtinNames = ["filter", "map", "sum", "length"]

topLevelRecordFields :: CorePureExpr -> Maybe [(Text, CorePureExpr)]
topLevelRecordFields = \case
  CorePureRecord fields ->
    traverse topLevelRecordField fields
  _ ->
    Nothing
  where
    topLevelRecordField field =
      case NE.toList field.corePureFieldPath of
        [fieldName] -> Just (fieldName, field.corePureFieldValue)
        _nestedPath -> Nothing

singleMapEntry :: Map Text value -> Maybe (Text, value)
singleMapEntry values =
  case Map.toAscList values of
    [entry] -> Just entry
    _ -> Nothing

data NumericMapSummarySpec = NumericMapSummarySpec
  { numericMapSummaryOutputName :: !Text
  , numericMapSummarySourceExpr :: !CorePureExpr
  , numericMapSummaryEvaluate :: !(Aeson.Value -> Either PureEvalError Scientific)
  , numericMapSummaryCountField :: !Text
  , numericMapSummaryTotalField :: !Text
  }

evaluateNumericMapSummaryFastPath
  :: CorePureEnv -> PreparedPureTask -> Maybe (Either PureEvalError (Map Text Aeson.Value))
evaluateNumericMapSummaryFastPath baseEnv preparedTask = do
  spec <- numericMapSummarySpec baseEnv preparedTask
  Just $ do
    sourceValue <- evaluateCorePureExpr baseEnv spec.numericMapSummarySourceExpr
    values <- corePureArray sourceValue
    (count, total) <-
      Vector.foldM'
        (accumulateNumericMapSummary spec)
        (0 :: Int, 0)
        values
    let output =
          Aeson.Object $
            KeyMap.fromList
              [ (Key.fromText spec.numericMapSummaryCountField, Aeson.Number (fromIntegral count))
              , (Key.fromText spec.numericMapSummaryTotalField, Aeson.Number total)
              ]
    Right (Map.singleton spec.numericMapSummaryOutputName output)

accumulateNumericMapSummary
  :: NumericMapSummarySpec
  -> (Int, Scientific)
  -> Aeson.Value
  -> Either PureEvalError (Int, Scientific)
accumulateNumericMapSummary spec (count, total) value = do
  number <- spec.numericMapSummaryEvaluate value
  Right (count + 1, total + number)

numericMapSummarySpec :: CorePureEnv -> PreparedPureTask -> Maybe NumericMapSummarySpec
numericMapSummarySpec baseEnv preparedTask = do
  (outputName, outputExpr) <- singleMapEntry preparedTask.preparedPureTaskOutputs
  outputFields <- topLevelRecordFields outputExpr
  (mappedName, sourceExpr, evaluateNumber) <-
    case preparedTask.preparedPureTaskBindings of
      [mapBinding] ->
        numericMapSummaryBinding baseEnv mapBinding
      _ ->
        Nothing
  if collectionSummaryBindingsShadowBuiltins mappedName mappedName
    then Nothing
    else do
      (countField, totalField) <-
        collectionSummaryOutputFields mappedName mappedName outputFields
      case preparedTask.preparedPureTaskWhere of
        Nothing ->
          Just
            NumericMapSummarySpec
              { numericMapSummaryOutputName = outputName
              , numericMapSummarySourceExpr = sourceExpr
              , numericMapSummaryEvaluate = evaluateNumber
              , numericMapSummaryCountField = countField
              , numericMapSummaryTotalField = totalField
              }
        Just _whereExpr ->
          Nothing

numericMapSummaryBinding
  :: CorePureEnv
  -> CorePureBinding
  -> Maybe (Text, CorePureExpr, Aeson.Value -> Either PureEvalError Scientific)
numericMapSummaryBinding baseEnv binding =
  case binding.corePureBindingExpr of
    CorePureCall (CorePureIdent "map") [CorePureLambda params body, sourceExpr] -> do
      evaluateNumber <- numericJsonMapNumber params body baseEnv
      Just (binding.corePureBindingName, sourceExpr, evaluateNumber)
    _ ->
      Nothing

data CorePureEnv = CorePureEnv
  { corePureEnvOverlay :: ![(Text, CorePureValue)]
  , corePureEnvBase :: !(Map Text CorePureValue)
  }

corePureEnvFromInputValues :: Map Text CorePureValue -> CorePureEnv
corePureEnvFromInputValues =
  CorePureEnv corePureBuiltinValues

corePureEnvLookup :: Text -> CorePureEnv -> Maybe CorePureValue
corePureEnvLookup name env =
  -- Overlay scopes are small and hot during lambda application; linear lookup
  -- avoids rebuilding Map unions while preserving nearest-binding precedence.
  case List.lookup name env.corePureEnvOverlay of
    Just value -> Just value
    Nothing -> Map.lookup name env.corePureEnvBase

corePureEnvInsert :: Text -> CorePureValue -> CorePureEnv -> CorePureEnv
corePureEnvInsert name value env =
  env {corePureEnvOverlay = (name, value) : env.corePureEnvOverlay}

corePureEnvPrepend :: [(Text, CorePureValue)] -> CorePureEnv -> CorePureEnv
corePureEnvPrepend bindings env =
  env {corePureEnvOverlay = bindings <> env.corePureEnvOverlay}

bindCorePureWhere :: CorePureEnv -> Maybe CorePureExpr -> Either PureEvalError CorePureEnv
bindCorePureWhere env = \case
  Nothing -> Right env
  Just whereExpr -> do
    whereValue <- evaluateCorePureExpr env whereExpr >>= corePureValueToJson
    case whereValue of
      Aeson.Object object ->
        Right $
          foldl
            ( \acc (key, value) ->
                corePureEnvInsert (Key.toText key) (CorePureJson value) acc
            )
            env
            (KeyMap.toList object)
      other ->
        Left (PureWhereExpectedRecord (jsonValueKind other))

data CorePureValue
  = CorePureJson !Aeson.Value
  | CorePureClosure !(NonEmpty Text) !CorePureExpr !CorePureEnv
  | CorePureBuiltin !Text !Int ![CorePureValue] !([CorePureValue] -> Either PureEvalError CorePureValue)

validateCorePureTaskExpressions
  :: [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError ()
validateCorePureTaskExpressions bindings whereExpr outputExprs =
  validateCorePureBindingNames bindings
    *> traverse_ (validateCorePureExpr . (.corePureBindingExpr)) bindings
    *> traverse_ validateCorePureExpr whereExpr
    *> traverse_ validateCorePureExpr outputExprs

validateCorePureExpr :: CorePureExpr -> Either PureEvalError ()
validateCorePureExpr = \case
  CorePureLit {} ->
    Right ()
  CorePureIdent {} ->
    Right ()
  CorePureList items ->
    traverse_ validateCorePureExpr items
  CorePureRecord fields ->
    validateCorePureRecordFieldPaths fields
      *> traverse_ (validateCorePureExpr . (.corePureFieldValue)) fields
  CorePureFieldAccess baseExpr _fieldName ->
    validateCorePureExpr baseExpr
  CorePureIndex baseExpr indexExpr ->
    validateCorePureExpr baseExpr *> validateCorePureExpr indexExpr
  CorePureLambda params bodyExpr ->
    validateCorePureParamNames params *> validateCorePureExpr bodyExpr
  CorePureCall functionExpr argumentExprs ->
    validateCorePureExpr functionExpr *> traverse_ validateCorePureExpr argumentExprs
  CorePureUnary _unaryOp operandExpr ->
    validateCorePureExpr operandExpr
  CorePureBinary _binaryOp lhsExpr rhsExpr ->
    validateCorePureExpr lhsExpr *> validateCorePureExpr rhsExpr
  CorePureLet bindings bodyExpr ->
    let bindingList = NE.toList bindings
     in validateCorePureBindingNames bindingList
          *> traverse_ (validateCorePureExpr . (.corePureBindingExpr)) bindingList
          *> validateCorePureExpr bodyExpr
  CorePureIf conditionExpr thenExpr elseExpr ->
    validateCorePureExpr conditionExpr
      *> validateCorePureExpr thenExpr
      *> validateCorePureExpr elseExpr

validateCorePureRecordFieldPaths :: [CorePureField] -> Either PureEvalError ()
validateCorePureRecordFieldPaths fields =
  case firstRecordFieldPathConflict (fmap (.corePureFieldPath) fields) of
    Just (leftPath, rightPath) ->
      Left (PureDuplicateRecordFieldPath (NE.toList leftPath) (NE.toList rightPath))
    Nothing ->
      Right ()

firstRecordFieldPathConflict
  :: [NonEmpty Text]
  -> Maybe (NonEmpty Text, NonEmpty Text)
firstRecordFieldPathConflict =
  go []
  where
    go _seen [] =
      Nothing
    go seen (path : rest) =
      case List.find (`recordFieldPathsConflict` path) seen of
        Just priorPath -> Just (priorPath, path)
        Nothing -> go (seen <> [path]) rest

recordFieldPathsConflict :: NonEmpty Text -> NonEmpty Text -> Bool
recordFieldPathsConflict leftPath rightPath =
  let left = NE.toList leftPath
      right = NE.toList rightPath
   in left `List.isPrefixOf` right || right `List.isPrefixOf` left

evaluateCorePureExpr :: CorePureEnv -> CorePureExpr -> Either PureEvalError CorePureValue
evaluateCorePureExpr env = \case
  CorePureLit literal ->
    Right (CorePureJson (corePureLiteralToJson literal))
  CorePureIdent name ->
    case corePureEnvLookup name env of
      Just value -> Right value
      Nothing -> Left (PureMissingVariable name)
  CorePureList items -> do
    values <- traverse (evaluateCorePureExpr env >=> corePureValueToJson) items
    Right (CorePureJson (Aeson.Array (Vector.fromList values)))
  CorePureRecord fields -> do
    object <- foldM insertField KeyMap.empty fields
    Right (CorePureJson (Aeson.Object object))
    where
      insertField object (CorePureField path valueExpr) = do
        value <- evaluateCorePureExpr env valueExpr >>= corePureValueToJson
        Right (mergeObjects object (objectForPath (foldr (:) [] path) value))
  CorePureFieldAccess baseExpr fieldName -> do
    baseValue <- evaluateCorePureExpr env baseExpr >>= corePureValueToJson
    CorePureJson <$> projectJsonField fieldName baseValue
  CorePureIndex baseExpr indexExpr -> do
    baseValue <- evaluateCorePureExpr env baseExpr >>= corePureValueToJson
    indexValue <- evaluateCorePureExpr env indexExpr >>= corePureValueToJson
    evaluateCorePureIndex baseValue indexValue
  CorePureLambda params body ->
    validateCorePureParamNames params *> Right (CorePureClosure params body env)
  CorePureCall functionExpr argumentExprs -> do
    functionValue <- evaluateCorePureExpr env functionExpr
    argumentValues <- traverse (evaluateCorePureExpr env) argumentExprs
    applyCorePureValue functionValue argumentValues
  CorePureUnary unaryOp operandExpr -> do
    operand <- evaluateCorePureExpr env operandExpr
    evaluateCorePureUnary unaryOp operand
  CorePureBinary CorePureAnd lhsExpr rhsExpr -> do
    lhs <- evaluateCorePureExpr env lhsExpr >>= corePureBool
    if lhs
      then CorePureJson . Aeson.Bool <$> (evaluateCorePureExpr env rhsExpr >>= corePureBool)
      else Right (CorePureJson (Aeson.Bool False))
  CorePureBinary CorePureOr lhsExpr rhsExpr -> do
    lhs <- evaluateCorePureExpr env lhsExpr >>= corePureBool
    if lhs
      then Right (CorePureJson (Aeson.Bool True))
      else CorePureJson . Aeson.Bool <$> (evaluateCorePureExpr env rhsExpr >>= corePureBool)
  CorePureBinary binaryOp lhsExpr rhsExpr -> do
    lhs <- evaluateCorePureExpr env lhsExpr
    rhs <- evaluateCorePureExpr env rhsExpr
    evaluateCorePureBinary binaryOp lhs rhs
  CorePureLet bindings bodyExpr -> do
    localEnv <- bindCorePureBindings env (NE.toList bindings)
    evaluateCorePureExpr localEnv bodyExpr
  CorePureIf conditionExpr thenExpr elseExpr -> do
    condition <- evaluateCorePureExpr env conditionExpr >>= corePureBool
    evaluateCorePureExpr env (if condition then thenExpr else elseExpr)

bindCorePureBindings
  :: CorePureEnv
  -> [CorePureBinding]
  -> Either PureEvalError CorePureEnv
bindCorePureBindings env bindings = do
  validateCorePureBindingNames bindings
  foldM bindCorePureBinding env bindings
  where
    bindCorePureBinding currentEnv binding = do
      value <- evaluateCorePureExpr currentEnv binding.corePureBindingExpr
      Right (corePureEnvInsert binding.corePureBindingName value currentEnv)

validateCorePureBindingNames :: [CorePureBinding] -> Either PureEvalError ()
validateCorePureBindingNames bindings =
  case duplicateNames (fmap (.corePureBindingName) bindings) of
    name : _ -> Left (PureDuplicateBinding name)
    [] -> Right ()

validateCorePureParamNames :: NonEmpty Text -> Either PureEvalError ()
validateCorePureParamNames params =
  case duplicateNames (NE.toList params) of
    name : _ -> Left (PureDuplicateLambdaParam name)
    [] -> Right ()

duplicateNames :: [Text] -> [Text]
duplicateNames names =
  [ name
  | (name, count) <- Map.toAscList (Map.fromListWith (+) [(name, 1 :: Int) | name <- names])
  , count > 1
  ]

corePureLiteralToJson :: CorePureLiteral -> Aeson.Value
corePureLiteralToJson = \case
  CorePureString text -> Aeson.String text
  CorePureNumber number -> Aeson.Number number
  CorePureBool bool -> Aeson.Bool bool
  CorePureNull -> Aeson.Null

evaluateCorePureIndex :: Aeson.Value -> Aeson.Value -> Either PureEvalError CorePureValue
evaluateCorePureIndex baseValue indexValue =
  case (baseValue, indexValue) of
    (Aeson.Array values, Aeson.Number indexNumber) -> do
      index <- integerIndex indexNumber
      case values Vector.!? index of
        Just value -> Right (CorePureJson value)
        Nothing -> Left (PureIndexOutOfBounds index)
    (Aeson.Object object, Aeson.String keyText) ->
      case KeyMap.lookup (Key.fromText keyText) object of
        Just value -> Right (CorePureJson value)
        Nothing -> Left (PureFieldMissing keyText)
    (Aeson.Array {}, other) ->
      Left (PureTypeMismatch "integer array index" (jsonValueKind other))
    (Aeson.Object {}, other) ->
      Left (PureTypeMismatch "string object key" (jsonValueKind other))
    (other, _) ->
      Left (PureTypeMismatch "array or object" (jsonValueKind other))

integerIndex :: Scientific -> Either PureEvalError Int
integerIndex number =
  case toBoundedInteger number of
    Just index
      | index >= (0 :: Int) -> Right index
      | otherwise -> Left (PureIndexOutOfBounds index)
    Nothing -> Left (PureTypeMismatch "integer" "number")

evaluateCorePureUnary :: CorePureUnaryOp -> CorePureValue -> Either PureEvalError CorePureValue
evaluateCorePureUnary = \case
  CorePureNot ->
    fmap (CorePureJson . Aeson.Bool . not) . corePureBool
  CorePureNegate ->
    fmap (CorePureJson . Aeson.Number . negate) . corePureNumber

evaluateCorePureBinary
  :: CorePureBinOp
  -> CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
evaluateCorePureBinary binaryOp lhs rhs =
  case binaryOp of
    CorePureAdd -> numericBinary (+) lhs rhs
    CorePureSubtract -> numericBinary (-) lhs rhs
    CorePureMultiply -> numericBinary (*) lhs rhs
    CorePureDivide ->
      numericFloatDivide lhs rhs
    CorePureMerge -> do
      lhsObject <- corePureObject lhs
      rhsObject <- corePureObject rhs
      Right (CorePureJson (Aeson.Object (mergeObjects lhsObject rhsObject)))
    CorePureEqual ->
      jsonCompare (==) lhs rhs
    CorePureNotEqual ->
      jsonCompare (/=) lhs rhs
    CorePureLessThan ->
      numericCompare (<) lhs rhs
    CorePureLessThanOrEqual ->
      numericCompare (<=) lhs rhs
    CorePureGreaterThan ->
      numericCompare (>) lhs rhs
    CorePureGreaterThanOrEqual ->
      numericCompare (>=) lhs rhs
    CorePureAnd ->
      boolBinary (&&) lhs rhs
    CorePureOr ->
      boolBinary (||) lhs rhs

numericBinary
  :: (Scientific -> Scientific -> Scientific)
  -> CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
numericBinary op lhs rhs =
  CorePureJson . Aeson.Number <$> (op <$> corePureNumber lhs <*> corePureNumber rhs)

numericFloatDivide
  :: CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
numericFloatDivide lhs rhs = do
  lhsNumber <- corePureNumber lhs
  rhsNumber <- corePureNumber rhs
  if rhsNumber == 0
    then Left PureDivisionByZero
    else do
      let lhsFloat = Scientific.toRealFloat lhsNumber :: Double
          rhsFloat = Scientific.toRealFloat rhsNumber :: Double
          result = lhsFloat / rhsFloat
      if finiteFloat lhsFloat && finiteFloat rhsFloat && finiteFloat result
        then Right (CorePureJson (Aeson.Number (Scientific.fromFloatDigits result)))
        else
          Left
            ( PureNonFiniteFloatDivision
                PureNonFiniteFloatDivisionOperands
                  { pnffNumerator = canonicalNumber lhsNumber
                  , pnffDenominator = canonicalNumber rhsNumber
                  }
            )

finiteFloat :: Double -> Bool
finiteFloat value =
  not (isNaN value || isInfinite value)

numericCompare
  :: (Scientific -> Scientific -> Bool)
  -> CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
numericCompare op lhs rhs =
  CorePureJson . Aeson.Bool <$> (op <$> corePureNumber lhs <*> corePureNumber rhs)

boolBinary
  :: (Bool -> Bool -> Bool)
  -> CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
boolBinary op lhs rhs =
  CorePureJson . Aeson.Bool <$> (op <$> corePureBool lhs <*> corePureBool rhs)

jsonCompare
  :: (Aeson.Value -> Aeson.Value -> Bool)
  -> CorePureValue
  -> CorePureValue
  -> Either PureEvalError CorePureValue
jsonCompare op lhs rhs =
  CorePureJson . Aeson.Bool <$> (op <$> corePureValueToJson lhs <*> corePureValueToJson rhs)

applyCorePureValue :: CorePureValue -> [CorePureValue] -> Either PureEvalError CorePureValue
applyCorePureValue functionValue argumentValues =
  case functionValue of
    CorePureClosure params body closureEnv
      -- Closure parameters were validated when the lambda expression was
      -- admitted by validateCorePureExpr; apply only enforces arity.
      | NE.length params == length argumentValues ->
          evaluateCorePureExpr
            (corePureEnvPrepend (zip (NE.toList params) argumentValues) closureEnv)
            body
      | length argumentValues < NE.length params -> do
          (appliedParams, remainingParams) <-
            partialClosureParams params (length argumentValues)
          let closureEnv' = corePureEnvPrepend (zip appliedParams argumentValues) closureEnv
          Right (CorePureClosure remainingParams body closureEnv')
      | otherwise ->
          Left (PureFunctionArity "<lambda>" (NE.length params) (length argumentValues))
    CorePureBuiltin name arity appliedValues implementation ->
      let allValues = appliedValues <> argumentValues
       in if length allValues == arity
            then implementation allValues
            else
              if length allValues < arity
                then Right (CorePureBuiltin name arity allValues implementation)
                else Left (PureFunctionArity name arity (length allValues))
    other ->
      Left (PureFunctionExpected (corePureValueKind other))

data CorePureBuiltinSpec = CorePureBuiltinSpec
  { corePureBuiltinName :: !Text
  , corePureBuiltinArity :: !Int
  , corePureBuiltinAuthority :: !CorePureBuiltinAuthority
  , corePureBuiltinImplementation :: !([CorePureValue] -> Either PureEvalError CorePureValue)
  }

corePureBuiltinSpecs :: [CorePureBuiltinSpec]
corePureBuiltinSpecs =
  [ builtin "map" 2 corePureMap
  , builtin "fmap" 2 corePureMap
  , builtin "filter" 2 corePureFilter
  , builtin "zip" 2 corePureZip
  , builtin "zipWith" 3 corePureZipWith
  , builtin "length" 1 corePureLength
  , builtin "sum" 1 corePureSum
  , builtin "all" 2 corePureAll
  , builtin "any" 2 corePureAny
  , builtin "min" 2 (numericBuiltin2 min)
  , builtin "max" 2 (numericBuiltin2 max)
  , builtin "abs" 1 corePureAbs
  , builtin "clamp" 3 corePureClamp
  , builtin "concat" 1 corePureConcat
  , builtin "toString" 1 corePureToString
  , builtin "joinWith" 2 corePureJoinWith
  , builtin "toJson" 1 corePureToJson
  , builtin "fromJson" 1 corePureFromJson
  , -- List-shape builtins (issue #295, batch 1).
    builtin "reverse" 1 corePureReverse
  , builtin "sort" 1 corePureSort
  , builtin "sortBy" 2 corePureSortBy
  , builtin "take" 2 corePureTake
  , builtin "drop" 2 corePureDrop
  , builtin "enumerate" 1 corePureEnumerate
  , builtin "mapIndexed" 2 corePureMapIndexed
  , -- List-search builtins.
    builtin "find" 2 corePureFind
  , builtin "findIndex" 2 corePureFindIndex
  , builtin "contains" 2 corePureContains
  , builtin "indexOf" 2 corePureIndexOf
  , builtin "count" 2 corePureCount
  , -- String builtins.
    builtin "split" 2 corePureSplit
  , builtin "replace" 3 corePureReplace
  , builtin "substring" 3 corePureSubstring
  , builtin "trim" 1 (stringUnaryBuiltin "trim" (Aeson.String . T.strip))
  , builtin "toLower" 1 (stringUnaryBuiltin "toLower" (Aeson.String . T.toLower))
  , builtin "toUpper" 1 (stringUnaryBuiltin "toUpper" (Aeson.String . T.toUpper))
  , builtin "startsWith" 2 (stringBinaryBoolBuiltin "startsWith" T.isPrefixOf)
  , builtin "endsWith" 2 (stringBinaryBoolBuiltin "endsWith" T.isSuffixOf)
  , builtin "strLength" 1 (stringUnaryBuiltin "strLength" (Aeson.Number . fromIntegral . T.length))
  , builtin
      "lines"
      1
      (stringUnaryBuiltin "lines" (Aeson.Array . Vector.fromList . fmap Aeson.String . T.lines))
  , builtin "unlines" 1 corePureUnlines
  , -- Record builtins.
    builtin "keys" 1 corePureKeys
  , builtin "values" 1 corePureValues
  , builtin "entries" 1 corePureEntries
  , -- Null / option builtins.
    builtin "withDefault" 2 corePureWithDefault
  , builtin "isNull" 1 corePureIsNull
  , -- Bounded-iteration builtins (capped; see ADR on CorePure bounded iteration).
    builtin "range" 2 corePureRange
  , builtin "fold" 3 corePureFold
  , builtin "foldRight" 3 corePureFoldRight
  ]
  where
    builtin name arity implementation =
      CorePureBuiltinSpec
        { corePureBuiltinName = name
        , corePureBuiltinArity = arity
        , corePureBuiltinAuthority = CorePureBuiltinPureValue
        , corePureBuiltinImplementation = implementation
        }

corePureBuiltinSignature :: [(Text, Int)]
corePureBuiltinSignature =
  [ (spec.corePureBuiltinName, spec.corePureBuiltinArity)
  | spec <- corePureBuiltinSpecs
  ]

corePureBuiltinAuthorityReport :: [CorePureBuiltinAuthorityReport]
corePureBuiltinAuthorityReport =
  [ CorePureBuiltinAuthorityReport
      { corePureBuiltinAuthorityName = spec.corePureBuiltinName
      , corePureBuiltinAuthorityArity = spec.corePureBuiltinArity
      , corePureBuiltinAuthority = spec.corePureBuiltinAuthority
      }
  | spec <- corePureBuiltinSpecs
  ]

corePureBuiltinAuthorityFree :: Bool
corePureBuiltinAuthorityFree =
  all
    (\report -> report.corePureBuiltinAuthority == CorePureBuiltinPureValue)
    corePureBuiltinAuthorityReport

corePureBuiltinValues :: [(Text, CorePureValue)]
corePureBuiltinValues =
  [ ( spec.corePureBuiltinName
    , CorePureBuiltin
        spec.corePureBuiltinName
        spec.corePureBuiltinArity
        []
        spec.corePureBuiltinImplementation
    )
  | spec <- corePureBuiltinSpecs
  ]

partialClosureParams
  :: NonEmpty Text -> Int -> Either PureEvalError ([Text], NonEmpty Text)
partialClosureParams params appliedCount =
  case splitAt appliedCount (NE.toList params) of
    (appliedParams, remainingParam : remainingParams) ->
      Right (appliedParams, remainingParam NE.:| remainingParams)
    _ ->
      Left (PureFunctionArity "<lambda>" (NE.length params) appliedCount)

corePureMap :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureMap
  [ CorePureClosure params (CorePureFieldAccess (CorePureIdent baseName) fieldName) _closureEnv
    , listValue
    ]
    | [param] <- NE.toList params
    , baseName == param = do
        values <- Vector.toList <$> corePureArray listValue
        mapped <- traverse (projectJsonField fieldName) values
        Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureMap [CorePureClosure params body closureEnv, listValue]
  | Just applyMap <- numericJsonMapValue params body closureEnv = do
      values <- Vector.toList <$> corePureArray listValue
      mapped <- traverse applyMap values
      Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureMap [CorePureClosure params body closureEnv, listValue]
  | [param] <- NE.toList params = do
      values <- Vector.toList <$> corePureArray listValue
      mapped <-
        traverse
          (applyUnaryJsonClosure param body closureEnv >=> corePureValueToJson)
          values
      Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureMap [functionValue, listValue] = do
  values <- corePureArray listValue
  mapped <- traverse (applyJsonFunction functionValue) (Vector.toList values)
  CorePureJson . Aeson.Array . Vector.fromList <$> traverse corePureValueToJson mapped
corePureMap args = impossibleBuiltinArity "map" 2 args

corePureFilter :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFilter [CorePureClosure params body _closureEnv, listValue]
  | Just predicate <- jsonFilterPredicate params body = do
      values <- Vector.toList <$> corePureArray listValue
      filtered <- filterMCore predicate values
      Right (CorePureJson (Aeson.Array (Vector.fromList filtered)))
corePureFilter [CorePureClosure params body closureEnv, listValue]
  | [param] <- NE.toList params = do
      values <- Vector.toList <$> corePureArray listValue
      filtered <-
        filterMCore
          ( \value -> do
              result <- applyUnaryJsonClosure param body closureEnv value
              corePureBool result
          )
          values
      Right (CorePureJson (Aeson.Array (Vector.fromList filtered)))
corePureFilter [functionValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  filtered <-
    filterMCore
      ( \value -> do
          result <- applyJsonFunction functionValue value
          corePureBool result
      )
      values
  Right (CorePureJson (Aeson.Array (Vector.fromList filtered)))
corePureFilter args = impossibleBuiltinArity "filter" 2 args

corePureZip :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureZip [lhsValue, rhsValue] = do
  lhs <- Vector.toList <$> corePureArray lhsValue
  rhs <- Vector.toList <$> corePureArray rhsValue
  let pairs =
        [ Aeson.object ["fst" Aeson..= lhsItem, "snd" Aeson..= rhsItem]
        | (lhsItem, rhsItem) <- zip lhs rhs
        ]
  Right (CorePureJson (Aeson.Array (Vector.fromList pairs)))
corePureZip args = impossibleBuiltinArity "zip" 2 args

corePureZipWith :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureZipWith [CorePureClosure params body _closureEnv, lhsValue, rhsValue]
  | Just applyBinary <- numericZipWithBinary params body = do
      lhs <- Vector.toList <$> corePureArray lhsValue
      rhs <- Vector.toList <$> corePureArray rhsValue
      mapped <-
        traverse
          (uncurry applyBinary)
          (zip lhs rhs)
      Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureZipWith [CorePureClosure params body closureEnv, lhsValue, rhsValue]
  | [lhsParam, rhsParam] <- NE.toList params = do
      lhs <- Vector.toList <$> corePureArray lhsValue
      rhs <- Vector.toList <$> corePureArray rhsValue
      mapped <-
        traverse
          ( \(lhsItem, rhsItem) ->
              applyBinaryJsonClosure lhsParam rhsParam body closureEnv lhsItem rhsItem
                >>= corePureValueToJson
          )
          (zip lhs rhs)
      Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureZipWith [functionValue, lhsValue, rhsValue] = do
  lhs <- Vector.toList <$> corePureArray lhsValue
  rhs <- Vector.toList <$> corePureArray rhsValue
  mapped <-
    traverse
      ( \(lhsItem, rhsItem) ->
          applyCorePureValue functionValue [CorePureJson lhsItem, CorePureJson rhsItem]
            >>= corePureValueToJson
      )
      (zip lhs rhs)
  Right (CorePureJson (Aeson.Array (Vector.fromList mapped)))
corePureZipWith args = impossibleBuiltinArity "zipWith" 3 args

corePureLength :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureLength [value] =
  case value of
    CorePureJson (Aeson.Array values) ->
      Right (CorePureJson (Aeson.Number (fromIntegral (Vector.length values))))
    CorePureJson (Aeson.Object object) ->
      Right (CorePureJson (Aeson.Number (fromIntegral (KeyMap.size object))))
    other ->
      Left (PureTypeMismatch "array or object" (corePureValueKind other))
corePureLength args = impossibleBuiltinArity "length" 1 args

corePureSum :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureSum [listValue] = do
  values <- corePureArray listValue
  total <- Vector.foldM' addJsonNumber 0 values
  Right (CorePureJson (Aeson.Number total))
  where
    addJsonNumber acc = \case
      Aeson.Number number -> Right $! acc + number
      other -> Left (PureTypeMismatch "number" (jsonValueKind other))
corePureSum args = impossibleBuiltinArity "sum" 1 args

corePureAll :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureAll [CorePureClosure params body closureEnv, listValue]
  | [param] <- NE.toList params = do
      values <- Vector.toList <$> corePureArray listValue
      results <- traverse (applyUnaryJsonClosure param body closureEnv >=> corePureBool) values
      Right (CorePureJson (Aeson.Bool (and results)))
corePureAll [functionValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  results <- traverse (applyJsonFunction functionValue >=> corePureBool) values
  Right (CorePureJson (Aeson.Bool (and results)))
corePureAll args = impossibleBuiltinArity "all" 2 args

corePureAny :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureAny [CorePureClosure params body closureEnv, listValue]
  | [param] <- NE.toList params = do
      values <- Vector.toList <$> corePureArray listValue
      results <- traverse (applyUnaryJsonClosure param body closureEnv >=> corePureBool) values
      Right (CorePureJson (Aeson.Bool (or results)))
corePureAny [functionValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  results <- traverse (applyJsonFunction functionValue >=> corePureBool) values
  Right (CorePureJson (Aeson.Bool (or results)))
corePureAny args = impossibleBuiltinArity "any" 2 args

numericBuiltin2
  :: (Scientific -> Scientific -> Scientific)
  -> [CorePureValue]
  -> Either PureEvalError CorePureValue
numericBuiltin2 op [lhs, rhs] =
  numericBinary op lhs rhs
numericBuiltin2 _ args =
  impossibleBuiltinArity "<numeric>" 2 args

corePureAbs :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureAbs [value] =
  CorePureJson . Aeson.Number . abs <$> corePureNumber value
corePureAbs args = impossibleBuiltinArity "abs" 1 args

corePureClamp :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureClamp [minValue, maxValue, value] = do
  minNumber <- corePureNumber minValue
  maxNumber <- corePureNumber maxValue
  number <- corePureNumber value
  Right (CorePureJson (Aeson.Number (max minNumber (min maxNumber number))))
corePureClamp args = impossibleBuiltinArity "clamp" 3 args

corePureConcat :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureConcat [listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  strings <- traverse corePureJsonString values
  Right (CorePureJson (Aeson.String (T.concat strings)))
corePureConcat args = impossibleBuiltinArity "concat" 1 args

corePureToString :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureToString [value] = do
  text <- corePureScalarText value
  Right (CorePureJson (Aeson.String text))
corePureToString args = impossibleBuiltinArity "toString" 1 args

corePureJoinWith :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureJoinWith [separatorValue, listValue] = do
  separator <- corePureStringValue separatorValue
  values <- Vector.toList <$> corePureArray listValue
  strings <- traverse corePureJsonString values
  Right (CorePureJson (Aeson.String (T.intercalate separator strings)))
corePureJoinWith args = impossibleBuiltinArity "joinWith" 2 args

corePureToJson :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureToJson [value] = do
  jsonValue <- corePureValueToJson value
  Right (CorePureJson (Aeson.String (canonicalJson jsonValue)))
corePureToJson args = impossibleBuiltinArity "toJson" 1 args

corePureFromJson :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFromJson [value] = do
  text <- corePureStringValue value
  case Aeson.eitherDecodeStrict (TE.encodeUtf8 text) of
    Right jsonValue -> Right (CorePureJson jsonValue)
    Left reason -> Left (PureJsonParseError (T.pack reason))
corePureFromJson args = impossibleBuiltinArity "fromJson" 1 args

corePureReverse :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureReverse [listValue] = do
  values <- corePureArray listValue
  Right (CorePureJson (Aeson.Array (Vector.reverse values)))
corePureReverse args = impossibleBuiltinArity "reverse" 1 args

corePureSort :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureSort [listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  Right (CorePureJson (Aeson.Array (Vector.fromList (List.sortBy compareJsonValues values))))
corePureSort args = impossibleBuiltinArity "sort" 1 args

corePureSortBy :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureSortBy [keyFunction, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  keyed <-
    traverse
      ( \value -> do
          key <- applyJsonFunction keyFunction value >>= corePureValueToJson
          Right (key, value)
      )
      values
  let sorted = List.sortBy (\lhs rhs -> compareJsonValues (fst lhs) (fst rhs)) keyed
  Right (CorePureJson (Aeson.Array (Vector.fromList (fmap snd sorted))))
corePureSortBy args = impossibleBuiltinArity "sortBy" 2 args

corePureTake :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureTake [countValue, listValue] = do
  values <- corePureArray listValue
  count <- boundedIndex (Vector.length values) countValue
  Right (CorePureJson (Aeson.Array (Vector.take count values)))
corePureTake args = impossibleBuiltinArity "take" 2 args

corePureDrop :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureDrop [countValue, listValue] = do
  values <- corePureArray listValue
  count <- boundedIndex (Vector.length values) countValue
  Right (CorePureJson (Aeson.Array (Vector.drop count values)))
corePureDrop args = impossibleBuiltinArity "drop" 2 args

corePureEnumerate :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureEnumerate [listValue] = do
  values <- corePureArray listValue
  let indexed =
        Vector.imap
          (\index value -> Aeson.object ["index" Aeson..= index, "value" Aeson..= value])
          values
  Right (CorePureJson (Aeson.Array indexed))
corePureEnumerate args = impossibleBuiltinArity "enumerate" 1 args

corePureMapIndexed :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureMapIndexed [functionValue, listValue] = do
  values <- corePureArray listValue
  mapped <-
    Vector.imapM
      ( \index value ->
          applyCorePureValue
            functionValue
            [CorePureJson (Aeson.Number (fromIntegral index)), CorePureJson value]
            >>= corePureValueToJson
      )
      values
  Right (CorePureJson (Aeson.Array mapped))
corePureMapIndexed args = impossibleBuiltinArity "mapIndexed" 2 args

corePureFind :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFind [predicateValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  findFirst values
  where
    findFirst [] = Right (CorePureJson Aeson.Null)
    findFirst (value : rest) = do
      keep <- applyJsonFunction predicateValue value >>= corePureBool
      if keep then Right (CorePureJson value) else findFirst rest
corePureFind args = impossibleBuiltinArity "find" 2 args

corePureFindIndex :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFindIndex [predicateValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  findFrom (0 :: Int) values
  where
    findFrom _ [] = Right (CorePureJson (Aeson.Number (-1)))
    findFrom index (value : rest) = do
      keep <- applyJsonFunction predicateValue value >>= corePureBool
      if keep
        then Right (CorePureJson (Aeson.Number (fromIntegral index)))
        else findFrom (index + 1) rest
corePureFindIndex args = impossibleBuiltinArity "findIndex" 2 args

corePureContains :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureContains [needleValue, listValue] = do
  needle <- corePureValueToJson needleValue
  values <- corePureArray listValue
  Right (CorePureJson (Aeson.Bool (Vector.elem needle values)))
corePureContains args = impossibleBuiltinArity "contains" 2 args

corePureIndexOf :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureIndexOf [needleValue, listValue] = do
  needle <- corePureValueToJson needleValue
  values <- corePureArray listValue
  let foundIndex = fromMaybe (-1) (Vector.elemIndex needle values)
  Right (CorePureJson (Aeson.Number (fromIntegral foundIndex)))
corePureIndexOf args = impossibleBuiltinArity "indexOf" 2 args

corePureCount :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureCount [predicateValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  results <- traverse (applyJsonFunction predicateValue >=> corePureBool) values
  Right (CorePureJson (Aeson.Number (fromIntegral (length (filter id results)))))
corePureCount args = impossibleBuiltinArity "count" 2 args

corePureSplit :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureSplit [separatorValue, stringValue] = do
  separator <- corePureStringValue separatorValue
  text <- corePureStringValue stringValue
  let parts = if T.null separator then T.chunksOf 1 text else T.splitOn separator text
  Right (CorePureJson (Aeson.Array (Vector.fromList (fmap Aeson.String parts))))
corePureSplit args = impossibleBuiltinArity "split" 2 args

corePureReplace :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureReplace [oldValue, newValue, stringValue] = do
  oldText <- corePureStringValue oldValue
  newText <- corePureStringValue newValue
  text <- corePureStringValue stringValue
  let result = if T.null oldText then text else T.replace oldText newText text
  Right (CorePureJson (Aeson.String result))
corePureReplace args = impossibleBuiltinArity "replace" 3 args

corePureSubstring :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureSubstring [startValue, endValue, stringValue] = do
  text <- corePureStringValue stringValue
  let len = T.length text
  lo <- boundedIndex len startValue
  hi0 <- boundedIndex len endValue
  let hi = max lo hi0
  Right (CorePureJson (Aeson.String (T.take (hi - lo) (T.drop lo text))))
corePureSubstring args = impossibleBuiltinArity "substring" 3 args

{- | Clamp a CorePure number to a @[0, upper]@ index, mapping a non-integer to a
typed error and unwrapping the guarded 'ClampedIndex' from "Cortex.Wire.Pure.Bounds".
-}
boundedIndex :: Int -> CorePureValue -> Either PureEvalError Int
boundedIndex upper value = do
  number <- corePureNumber value
  case clampIndex upper number of
    Just clamped -> Right (clampedIndexValue clamped)
    Nothing -> Left (PureTypeMismatch "integer" "number")

corePureUnlines :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureUnlines [listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  strings <- traverse corePureJsonString values
  Right (CorePureJson (Aeson.String (T.intercalate "\n" strings)))
corePureUnlines args = impossibleBuiltinArity "unlines" 1 args

stringUnaryBuiltin
  :: Text -> (Text -> Aeson.Value) -> [CorePureValue] -> Either PureEvalError CorePureValue
stringUnaryBuiltin _ render [stringValue] = do
  text <- corePureStringValue stringValue
  Right (CorePureJson (render text))
stringUnaryBuiltin name _ args = impossibleBuiltinArity name 1 args

stringBinaryBoolBuiltin
  :: Text -> (Text -> Text -> Bool) -> [CorePureValue] -> Either PureEvalError CorePureValue
stringBinaryBoolBuiltin _ predicate [firstValue, stringValue] = do
  firstText <- corePureStringValue firstValue
  text <- corePureStringValue stringValue
  Right (CorePureJson (Aeson.Bool (predicate firstText text)))
stringBinaryBoolBuiltin name _ args = impossibleBuiltinArity name 2 args

corePureKeys :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureKeys [objectValue] = do
  object <- corePureObject objectValue
  let sortedKeys =
        [Aeson.String (Key.toText key) | (key, _value) <- List.sortOn fst (KeyMap.toList object)]
  Right (CorePureJson (Aeson.Array (Vector.fromList sortedKeys)))
corePureKeys args = impossibleBuiltinArity "keys" 1 args

corePureValues :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureValues [objectValue] = do
  object <- corePureObject objectValue
  let sortedValues = [value | (_key, value) <- List.sortOn fst (KeyMap.toList object)]
  Right (CorePureJson (Aeson.Array (Vector.fromList sortedValues)))
corePureValues args = impossibleBuiltinArity "values" 1 args

corePureEntries :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureEntries [objectValue] = do
  object <- corePureObject objectValue
  let entries =
        [ Aeson.object ["key" Aeson..= Key.toText key, "value" Aeson..= value]
        | (key, value) <- List.sortOn fst (KeyMap.toList object)
        ]
  Right (CorePureJson (Aeson.Array (Vector.fromList entries)))
corePureEntries args = impossibleBuiltinArity "entries" 1 args

corePureWithDefault :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureWithDefault [defaultValue, value] =
  case value of
    CorePureJson Aeson.Null -> Right defaultValue
    _ -> Right value
corePureWithDefault args = impossibleBuiltinArity "withDefault" 2 args

corePureIsNull :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureIsNull [value] =
  Right
    ( CorePureJson
        ( Aeson.Bool
            ( case value of
                CorePureJson Aeson.Null -> True
                _ -> False
            )
        )
    )
corePureIsNull args = impossibleBuiltinArity "isNull" 1 args

corePureRange :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureRange [startValue, endValue] = do
  startNumber <- corePureNumber startValue
  endNumber <- corePureNumber endValue
  case planRange corePureBoundedIterationCap startNumber endNumber of
    Nothing -> Left (PureTypeMismatch "integer" "number")
    Just plan ->
      foldRangePlan
        (Right (CorePureJson (Aeson.Array Vector.empty)))
        ( \start end ->
            let elements = [Aeson.Number (fromInteger index) | index <- [start .. end - 1]]
             in Right (CorePureJson (Aeson.Array (Vector.fromList elements)))
        )
        (Left (PureBoundExceeded "range span"))
        plan
corePureRange args = impossibleBuiltinArity "range" 2 args

corePureFold :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFold [functionValue, initialValue, listValue] = do
  values <- corePureArray listValue
  -- The accumulator is a guarded FoldAccumulator throughout: the seed and every
  -- step result pass through foldAccumulatorOf (JSON shape and cost cap), so a
  -- function-valued or over-cap accumulator cannot slip in or out.
  seed <- foldAccumulatorOf initialValue
  result <- Vector.foldM' step seed values
  Right (CorePureJson (foldAccumulatorValue result))
  where
    step accumulator item =
      applyCorePureValue
        functionValue
        [CorePureJson (foldAccumulatorValue accumulator), CorePureJson item]
        >>= foldAccumulatorOf
corePureFold args = impossibleBuiltinArity "fold" 3 args

corePureFoldRight :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureFoldRight [functionValue, initialValue, listValue] = do
  values <- corePureArray listValue
  -- Right fold expressed as a strict left fold over the reversed vector, so it
  -- stays iterative while preserving the f(item, acc) application order; the
  -- accumulator stays a guarded FoldAccumulator, bounded before any reducer call.
  seed <- foldAccumulatorOf initialValue
  result <- Vector.foldM' step seed (Vector.reverse values)
  Right (CorePureJson (foldAccumulatorValue result))
  where
    step accumulator item =
      applyCorePureValue
        functionValue
        [CorePureJson item, CorePureJson (foldAccumulatorValue accumulator)]
        >>= foldAccumulatorOf
corePureFoldRight args = impossibleBuiltinArity "foldRight" 3 args

{- | Guard a reducer result or seed into a 'FoldAccumulator': reject a
function-valued accumulator, then enforce the JSON cost cap. This is the only way
the fold builtins obtain an accumulator, so the guard cannot be skipped.
-}
foldAccumulatorOf :: CorePureValue -> Either PureEvalError FoldAccumulator
foldAccumulatorOf value =
  case value of
    CorePureJson json ->
      maybe
        (Left (PureBoundExceeded "fold accumulator"))
        Right
        (mkFoldAccumulator corePureBoundedIterationCap json)
    _ ->
      Left (PureTypeMismatch "JSON fold accumulator" (corePureValueKind value))

{- | Total order over JSON values for @sort@ and @sortBy@. Aeson @Value@ has @Eq@
but no @Ord@; this ranks by type then orders within a type, recursing into
arrays and key-sorted objects, so the result is deterministic across builds.
-}
compareJsonValues :: Aeson.Value -> Aeson.Value -> Ordering
compareJsonValues left right =
  case (left, right) of
    (Aeson.Null, Aeson.Null) -> EQ
    (Aeson.Bool lhs, Aeson.Bool rhs) -> compare lhs rhs
    (Aeson.Number lhs, Aeson.Number rhs) -> compare lhs rhs
    (Aeson.String lhs, Aeson.String rhs) -> compare lhs rhs
    (Aeson.Array lhs, Aeson.Array rhs) ->
      compareJsonList (Vector.toList lhs) (Vector.toList rhs)
    (Aeson.Object lhs, Aeson.Object rhs) ->
      compareJsonFields (List.sortOn fst (KeyMap.toList lhs)) (List.sortOn fst (KeyMap.toList rhs))
    _ -> compare (jsonTypeRank left) (jsonTypeRank right)
  where
    compareJsonList [] [] = EQ
    compareJsonList [] _ = LT
    compareJsonList _ [] = GT
    compareJsonList (lhs : lhsRest) (rhs : rhsRest) =
      case compareJsonValues lhs rhs of
        EQ -> compareJsonList lhsRest rhsRest
        ordering -> ordering

    compareJsonFields [] [] = EQ
    compareJsonFields [] _ = LT
    compareJsonFields _ [] = GT
    compareJsonFields ((lhsKey, lhsValue) : lhsRest) ((rhsKey, rhsValue) : rhsRest) =
      case compare lhsKey rhsKey of
        EQ ->
          case compareJsonValues lhsValue rhsValue of
            EQ -> compareJsonFields lhsRest rhsRest
            ordering -> ordering
        ordering -> ordering

jsonTypeRank :: Aeson.Value -> Int
jsonTypeRank = \case
  Aeson.Null -> 0
  Aeson.Bool {} -> 1
  Aeson.Number {} -> 2
  Aeson.String {} -> 3
  Aeson.Array {} -> 4
  Aeson.Object {} -> 5

applyJsonFunction :: CorePureValue -> Aeson.Value -> Either PureEvalError CorePureValue
applyJsonFunction functionValue value =
  applyCorePureValue functionValue [CorePureJson value]

projectJsonField :: Text -> Aeson.Value -> Either PureEvalError Aeson.Value
projectJsonField fieldName = \case
  Aeson.Object object ->
    case KeyMap.lookup (Key.fromText fieldName) object of
      Just value -> Right value
      Nothing -> Left (PureFieldMissing fieldName)
  other ->
    Left (PureTypeMismatch "object" (jsonValueKind other))

applyUnaryJsonClosure
  :: Text -> CorePureExpr -> CorePureEnv -> Aeson.Value -> Either PureEvalError CorePureValue
applyUnaryJsonClosure param body closureEnv value =
  evaluateCorePureExpr (corePureEnvInsert param (CorePureJson value) closureEnv) body

numericJsonMapValue
  :: NonEmpty Text
  -> CorePureExpr
  -> CorePureEnv
  -> Maybe (Aeson.Value -> Either PureEvalError Aeson.Value)
numericJsonMapValue params body closureEnv = do
  evaluateNumber <- numericJsonMapNumber params body closureEnv
  Just (fmap Aeson.Number . evaluateNumber)

numericJsonMapNumber
  :: NonEmpty Text
  -> CorePureExpr
  -> CorePureEnv
  -> Maybe (Aeson.Value -> Either PureEvalError Scientific)
numericJsonMapNumber params body closureEnv =
  case NE.toList params of
    [param] ->
      numericJsonExpr closureEnv param body
    _ ->
      Nothing

numericJsonExpr
  :: CorePureEnv
  -> Text
  -> CorePureExpr
  -> Maybe (Aeson.Value -> Either PureEvalError Scientific)
numericJsonExpr closureEnv paramName = \case
  CorePureLit (CorePureNumber number) ->
    Just (\_value -> Right number)
  fieldExpr@CorePureFieldAccess {} -> do
    fieldName <- fieldAccessOnParam paramName fieldExpr
    Just $ \value -> do
      fieldValue <- projectJsonField fieldName value
      jsonNumber fieldValue
  CorePureUnary CorePureNegate operandExpr -> do
    evaluateOperand <- numericJsonExpr closureEnv paramName operandExpr
    Just (fmap negate . evaluateOperand)
  CorePureBinary binaryOp lhsExpr rhsExpr -> do
    evaluateBinary <- numericJsonBinaryNumbers binaryOp
    evaluateLhs <- numericJsonExpr closureEnv paramName lhsExpr
    evaluateRhs <- numericJsonExpr closureEnv paramName rhsExpr
    Just $ \value -> do
      lhs <- evaluateLhs value
      rhs <- evaluateRhs value
      evaluateBinary lhs rhs
  CorePureCall (CorePureIdent "abs") [operandExpr] ->
    if numericJsonBuiltinAvailable paramName "abs" closureEnv
      then do
        evaluateOperand <- numericJsonExpr closureEnv paramName operandExpr
        Just (fmap abs . evaluateOperand)
      else Nothing
  CorePureCall (CorePureIdent "min") [lhsExpr, rhsExpr] ->
    if numericJsonBuiltinAvailable paramName "min" closureEnv
      then numericJsonCall2 min closureEnv paramName lhsExpr rhsExpr
      else Nothing
  CorePureCall (CorePureIdent "max") [lhsExpr, rhsExpr] ->
    if numericJsonBuiltinAvailable paramName "max" closureEnv
      then numericJsonCall2 max closureEnv paramName lhsExpr rhsExpr
      else Nothing
  CorePureCall (CorePureIdent "clamp") [minimumExpr, maximumExpr, valueExpr] ->
    if numericJsonBuiltinAvailable paramName "clamp" closureEnv
      then do
        evaluateMinimum <- numericJsonExpr closureEnv paramName minimumExpr
        evaluateMaximum <- numericJsonExpr closureEnv paramName maximumExpr
        evaluateValue <- numericJsonExpr closureEnv paramName valueExpr
        Just $ \value -> do
          minimumValue <- evaluateMinimum value
          maximumValue <- evaluateMaximum value
          number <- evaluateValue value
          Right (max minimumValue (min maximumValue number))
      else Nothing
  _ ->
    Nothing

numericJsonBuiltinAvailable :: Text -> Text -> CorePureEnv -> Bool
numericJsonBuiltinAvailable paramName builtinName closureEnv =
  paramName /= builtinName && corePureBuiltinAvailable builtinName closureEnv

numericJsonCall2
  :: (Scientific -> Scientific -> Scientific)
  -> CorePureEnv
  -> Text
  -> CorePureExpr
  -> CorePureExpr
  -> Maybe (Aeson.Value -> Either PureEvalError Scientific)
numericJsonCall2 op closureEnv paramName lhsExpr rhsExpr = do
  evaluateLhs <- numericJsonExpr closureEnv paramName lhsExpr
  evaluateRhs <- numericJsonExpr closureEnv paramName rhsExpr
  Just $ \value -> do
    lhs <- evaluateLhs value
    rhs <- evaluateRhs value
    Right (op lhs rhs)

numericJsonBinaryNumbers
  :: CorePureBinOp -> Maybe (Scientific -> Scientific -> Either PureEvalError Scientific)
numericJsonBinaryNumbers = \case
  CorePureAdd -> Just (\lhs rhs -> Right (lhs + rhs))
  CorePureSubtract -> Just (\lhs rhs -> Right (lhs - rhs))
  CorePureMultiply -> Just (\lhs rhs -> Right (lhs * rhs))
  CorePureDivide -> Just divideScientific
  _ -> Nothing

divideScientific :: Scientific -> Scientific -> Either PureEvalError Scientific
divideScientific lhs rhs =
  if rhs == 0
    then Left PureDivisionByZero
    else Right (lhs / rhs)

corePureBuiltinAvailable :: Text -> CorePureEnv -> Bool
corePureBuiltinAvailable name env =
  case corePureEnvLookup name env of
    Just (CorePureBuiltin builtinName _arity [] _implementation) ->
      builtinName == name
    _ ->
      False

applyBinaryJsonClosure
  :: Text
  -> Text
  -> CorePureExpr
  -> CorePureEnv
  -> Aeson.Value
  -> Aeson.Value
  -> Either PureEvalError CorePureValue
applyBinaryJsonClosure lhsParam rhsParam body closureEnv lhsValue rhsValue =
  evaluateCorePureExpr
    ( corePureEnvPrepend
        [ (lhsParam, CorePureJson lhsValue)
        , (rhsParam, CorePureJson rhsValue)
        ]
        closureEnv
    )
    body

numericZipWithBinary
  :: NonEmpty Text
  -> CorePureExpr
  -> Maybe (Aeson.Value -> Aeson.Value -> Either PureEvalError Aeson.Value)
numericZipWithBinary params = \case
  CorePureBinary binaryOp (CorePureIdent lhsName) (CorePureIdent rhsName)
    | [lhsParam, rhsParam] <- NE.toList params
    , Just applyBinary <- numericJsonBinary binaryOp
    , Just selectLhs <- selectParam lhsParam rhsParam lhsName
    , Just selectRhs <- selectParam lhsParam rhsParam rhsName ->
        Just $ \lhsValue rhsValue ->
          applyBinary (selectLhs lhsValue rhsValue) (selectRhs lhsValue rhsValue)
  _ ->
    Nothing

selectParam
  :: Text -> Text -> Text -> Maybe (Aeson.Value -> Aeson.Value -> Aeson.Value)
selectParam lhsParam rhsParam name
  | name == lhsParam = Just const
  | name == rhsParam = Just (\_lhsValue rhsValue -> rhsValue)
  | otherwise = Nothing

numericJsonBinary
  :: CorePureBinOp -> Maybe (Aeson.Value -> Aeson.Value -> Either PureEvalError Aeson.Value)
numericJsonBinary = \case
  CorePureAdd -> Just (numericJsonBinaryOp (+))
  CorePureSubtract -> Just (numericJsonBinaryOp (-))
  CorePureMultiply -> Just (numericJsonBinaryOp (*))
  CorePureDivide -> Just numericJsonDivide
  _ -> Nothing

numericJsonBinaryOp
  :: (Scientific -> Scientific -> Scientific)
  -> Aeson.Value
  -> Aeson.Value
  -> Either PureEvalError Aeson.Value
numericJsonBinaryOp op lhs rhs =
  Aeson.Number <$> (op <$> jsonNumber lhs <*> jsonNumber rhs)

numericJsonDivide :: Aeson.Value -> Aeson.Value -> Either PureEvalError Aeson.Value
numericJsonDivide lhs rhs = do
  lhsNumber <- jsonNumber lhs
  rhsNumber <- jsonNumber rhs
  if rhsNumber == 0
    then Left PureDivisionByZero
    else Right (Aeson.Number (lhsNumber / rhsNumber))

jsonNumber :: Aeson.Value -> Either PureEvalError Scientific
jsonNumber = \case
  Aeson.Number number -> Right number
  other -> Left (PureTypeMismatch "number" (jsonValueKind other))

jsonFilterPredicate
  :: NonEmpty Text -> CorePureExpr -> Maybe (Aeson.Value -> Either PureEvalError Bool)
jsonFilterPredicate params = \case
  CorePureBinary CorePureAnd lhsExpr rhsExpr
    | [param] <- NE.toList params
    , Just lhsPredicate <- boolFieldPredicate param lhsExpr
    , Just rhsPredicate <- numericFieldComparePredicate param rhsExpr ->
        Just $ \value -> do
          lhs <- lhsPredicate value
          if lhs then rhsPredicate value else Right False
  _ ->
    Nothing

boolFieldPredicate :: Text -> CorePureExpr -> Maybe (Aeson.Value -> Either PureEvalError Bool)
boolFieldPredicate paramName expr = do
  fieldName <- fieldAccessOnParam paramName expr
  Just $ \value -> do
    fieldValue <- projectJsonField fieldName value
    jsonBool fieldValue

fieldAccessOnParam :: Text -> CorePureExpr -> Maybe Text
fieldAccessOnParam paramName = \case
  CorePureFieldAccess (CorePureIdent baseName) fieldName
    | baseName == paramName -> Just fieldName
  _ ->
    Nothing

numericFieldComparePredicate
  :: Text -> CorePureExpr -> Maybe (Aeson.Value -> Either PureEvalError Bool)
numericFieldComparePredicate paramName = \case
  CorePureBinary binaryOp fieldExpr (CorePureLit (CorePureNumber threshold)) -> do
    fieldName <- fieldAccessOnParam paramName fieldExpr
    compareNumbers <- numericJsonCompare binaryOp
    Just $ \value -> do
      fieldValue <- projectJsonField fieldName value
      fieldNumber <- jsonNumber fieldValue
      Right (compareNumbers fieldNumber threshold)
  _ ->
    Nothing

numericJsonCompare :: CorePureBinOp -> Maybe (Scientific -> Scientific -> Bool)
numericJsonCompare = \case
  CorePureLessThan -> Just (<)
  CorePureLessThanOrEqual -> Just (<=)
  CorePureGreaterThan -> Just (>)
  CorePureGreaterThanOrEqual -> Just (>=)
  _ -> Nothing

jsonBool :: Aeson.Value -> Either PureEvalError Bool
jsonBool = \case
  Aeson.Bool bool -> Right bool
  other -> Left (PureTypeMismatch "boolean" (jsonValueKind other))

filterMCore :: (a -> Either PureEvalError Bool) -> [a] -> Either PureEvalError [a]
filterMCore predicate values =
  reverse
    <$> foldM
      ( \acc value -> do
          keep <- predicate value
          Right (if keep then value : acc else acc)
      )
      []
      values

impossibleBuiltinArity :: Text -> Int -> [CorePureValue] -> Either PureEvalError a
impossibleBuiltinArity name expected args =
  Left (PureFunctionArity name expected (length args))

corePureValueToJson :: CorePureValue -> Either PureEvalError Aeson.Value
corePureValueToJson = \case
  CorePureJson value -> Right value
  CorePureClosure {} -> Left (PureTypeMismatch "JSON value" "function")
  CorePureBuiltin {} -> Left (PureTypeMismatch "JSON value" "function")

corePureStringValue :: CorePureValue -> Either PureEvalError Text
corePureStringValue value =
  case value of
    CorePureJson (Aeson.String text) -> Right text
    other -> Left (PureTypeMismatch "string" (corePureValueKind other))

corePureJsonString :: Aeson.Value -> Either PureEvalError Text
corePureJsonString = \case
  Aeson.String text -> Right text
  other -> Left (PureTypeMismatch "string" (jsonValueKind other))

corePureScalarText :: CorePureValue -> Either PureEvalError Text
corePureScalarText = \case
  CorePureJson (Aeson.String text) -> Right text
  CorePureJson (Aeson.Number number) -> Right (canonicalNumber number)
  CorePureJson (Aeson.Bool True) -> Right "true"
  CorePureJson (Aeson.Bool False) -> Right "false"
  other -> Left (PureTypeMismatch "scalar" (corePureValueKind other))

corePureNumber :: CorePureValue -> Either PureEvalError Scientific
corePureNumber value =
  case value of
    CorePureJson (Aeson.Number number) -> Right number
    other -> Left (PureTypeMismatch "number" (corePureValueKind other))

corePureBool :: CorePureValue -> Either PureEvalError Bool
corePureBool value =
  case value of
    CorePureJson (Aeson.Bool bool) -> Right bool
    other -> Left (PureTypeMismatch "boolean" (corePureValueKind other))

corePureArray :: CorePureValue -> Either PureEvalError (Vector.Vector Aeson.Value)
corePureArray value =
  case value of
    CorePureJson (Aeson.Array values) -> Right values
    other -> Left (PureTypeMismatch "array" (corePureValueKind other))

corePureObject :: CorePureValue -> Either PureEvalError (KeyMap.KeyMap Aeson.Value)
corePureObject value =
  case value of
    CorePureJson (Aeson.Object object) -> Right object
    other -> Left (PureTypeMismatch "object" (corePureValueKind other))

corePureValueKind :: CorePureValue -> Text
corePureValueKind = \case
  CorePureJson value -> jsonValueKind value
  CorePureClosure {} -> "function"
  CorePureBuiltin {} -> "function"

{- | Deterministic textual rendering of a JSON value: recursively key-sorted
objects and canonical number rendering, so structurally equal values render
identically regardless of construction order. This is the value-canonicalization
surface CorePure string conversion uses, and the encoding content addressing
(ADR 0089) hashes over.
-}
canonicalJson :: Aeson.Value -> Text
canonicalJson = \case
  Aeson.Null -> "null"
  Aeson.Bool True -> "true"
  Aeson.Bool False -> "false"
  Aeson.Number number -> canonicalNumber number
  Aeson.String text -> jsonString text
  Aeson.Array values ->
    "[" <> T.intercalate "," (fmap canonicalJson (Vector.toList values)) <> "]"
  Aeson.Object object ->
    let fields =
          [ jsonString (Key.toText key) <> ":" <> canonicalJson value
          | (key, value) <- List.sortOn fst (KeyMap.toList object)
          ]
     in "{" <> T.intercalate "," fields <> "}"

canonicalNumber :: Scientific -> Text
canonicalNumber number
  | number == 0 = "0"
  | otherwise =
      let rendered = T.pack (Scientific.formatScientific Scientific.Fixed Nothing number)
       in trimNumber rendered

trimNumber :: Text -> Text
trimNumber rendered =
  case T.breakOn "." rendered of
    (_, fraction)
      | T.null fraction -> rendered
    (whole, fraction) ->
      let trimmedFraction = T.dropWhileEnd (== '0') (T.drop 1 fraction)
       in if T.null trimmedFraction
            then whole
            else whole <> "." <> trimmedFraction

jsonString :: Text -> Text
jsonString text =
  "\"" <> T.concatMap escapeJsonChar text <> "\""
  where
    escapeJsonChar = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\b' -> "\\b"
      '\f' -> "\\f"
      c
        | Char.ord c < 0x20 ->
            "\\u" <> T.justifyRight 4 '0' (T.pack (showHex4 (Char.ord c)))
        | otherwise -> T.singleton c

    showHex4 value =
      let digits = "0123456789abcdef" :: String
          go 0 acc = acc
          go n acc =
            let (q, r) = n `quotRem` 16
             in go q ((digits !! r) : acc)
       in case go value [] of
            [] -> "0"
            xs -> xs

jsonValueKind :: Aeson.Value -> Text
jsonValueKind = \case
  Aeson.Object {} -> "object"
  Aeson.Array {} -> "array"
  Aeson.String {} -> "string"
  Aeson.Number {} -> "number"
  Aeson.Bool {} -> "boolean"
  Aeson.Null -> "null"

objectForPath :: [Text] -> Aeson.Value -> KeyMap.KeyMap Aeson.Value
objectForPath [] value =
  case value of
    Aeson.Object object -> object
    _ -> KeyMap.empty
objectForPath [segment] value =
  KeyMap.singleton (Key.fromText segment) value
objectForPath (segment : rest) value =
  KeyMap.singleton
    (Key.fromText segment)
    (Aeson.Object (objectForPath rest value))

mergeObjects :: KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value
mergeObjects =
  KeyMap.unionWith mergeJsonValue

mergeJsonValue :: Aeson.Value -> Aeson.Value -> Aeson.Value
mergeJsonValue (Aeson.Object leftObj) (Aeson.Object rightObj) =
  Aeson.Object (mergeObjects leftObj rightObj)
mergeJsonValue _ rightValue = rightValue

pureWireExecutorId :: WireExecutorId
pureWireExecutorId = WireExecutorId "pure"

pureWireExecutorProjection :: WireExecutorProjection
pureWireExecutorProjection =
  WireExecutorProjection
    { wireExecutorProjectionId = pureWireExecutorId
    , wireExecutorProjectionPorts =
        WirePorts
          { wirePortsInputs = Map.empty
          , wirePortsOutputs = Map.empty
          }
    , wireExecutorProjectionVocabulary = Set.empty
    , wireExecutorProjectionEffect = WireExecutorPure
    , wireExecutorProjectionArgumentShape = WireExecutorArgumentSchema pureExecutorArgumentSchema
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

pureExecutorArgumentSchema :: Aeson.Value
pureExecutorArgumentSchema =
  Aeson.object
    [ "$schema" Aeson..= ("https://json-schema.org/draft/2020-12/schema" :: Text)
    , "type" Aeson..= ("object" :: Text)
    , "oneOf"
        Aeson..= [ Aeson.object ["required" Aeson..= ["outputs" :: Text]]
                 , Aeson.object ["required" Aeson..= ["variant" :: Text]]
                 ]
    , "additionalProperties" Aeson..= False
    , "properties"
        Aeson..= Aeson.object
          [ "bindings"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("array" :: Text)
                , "description"
                    Aeson..= ("Top-level delayed bindings and captured constants shared by all pure outputs." :: Text)
                ]
          , "where"
              Aeson..= Aeson.object
                [ "description" Aeson..= ("Optional CorePure record expression opened into node-local scope." :: Text)
                ]
          , "outputs"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                , "description" Aeson..= ("Map from output port name to CorePure expression AST." :: Text)
                ]
          , "variant"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                , "description"
                    Aeson..= ("Declared exclusive labels and one constructor-returning CorePure expression." :: Text)
                ]
          ]
    ]
