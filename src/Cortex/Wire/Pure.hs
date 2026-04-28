{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Deterministic Wire pure evaluator.

Pure nodes are authored as output equations and lowered to one host-bound
native pure task. The evaluator receives only already-wrapped Wire inputs and a
CorePure AST; it has no host callbacks, IO, time, randomness, model access,
or executor authority.
-}
module Cortex.Wire.Pure
  ( PureEvalError (..)
  , renderPureEvalError
  , validatePurePorts
  , bindPureInputValues
  , evaluatePureTaskOutputs
  , pureWireExecutorId
  , pureWireExecutorProjection
  , pureExecutorConfigSchema
  )
where

import Control.Monad (foldM, (>=>))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char qualified as Char
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, toBoundedInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
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
  , WirePorts (..)
  , defaultInputPortName
  )
import Cortex.Wire.Value (WirePayloadKind (..), WireValue (..), renderWirePayloadKind)

data PureEvalError
  = PureMissingVariable !Text
  | PureDivisionByZero
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
  deriving stock (Eq, Show, Generic)

renderPureEvalError :: PureEvalError -> Text
renderPureEvalError = \case
  PureMissingVariable variableName ->
    "Pure expression references missing variable " <> variableName <> "."
  PureDivisionByZero ->
    "Pure expression attempted division by zero."
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
  where
    renderList values =
      "[" <> T.intercalate ", " values <> "]"

validatePurePorts :: WirePorts -> Map Text CorePureExpr -> Either PureEvalError ()
validatePurePorts ports outputExprs =
  validatePureInputPorts ports *> validatePureOutputPorts ports outputExprs

validatePureInputPorts :: WirePorts -> Either PureEvalError ()
validatePureInputPorts ports =
  traverse_
    validateInputPort
    (Map.toAscList ports.wirePortsInputs)
  where
    inputContractCounts = pureInputContractCounts ports

    validateInputPort (portName, inputPort) = do
      contractId <- exactPureInputContract portName inputPort
      if repeatedGeneratedPurePortName inputContractCounts portName contractId
        then Left (PureInputPortRequiresLabel portName contractId)
        else Right ()

validatePureOutputPorts :: WirePorts -> Map Text CorePureExpr -> Either PureEvalError ()
validatePureOutputPorts ports outputExprs =
  let expected = Map.keys ports.wirePortsOutputs
      actual = Map.keys outputExprs
   in case expected of
        [] ->
          Left (PureOutputPortsUnsupported "pure output equations require at least one output port")
        _ | expected == actual -> Right ()
        _ -> Left (PureOutputPortsMismatch expected actual)

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
  validatePureInputPorts ports
  Map.fromList <$> traverse bindInputPort (Map.toAscList ports.wirePortsInputs)
  where
    bindInputPort (portName, inputPort) = do
      contractId <- exactPureInputContract portName inputPort
      wireValue <- singleMatchedValue portName contractId
      value <- wireValueJson portName wireValue
      Right (portName, value)

    singleMatchedValue portName contractId =
      case matchedWireValues portName contractId of
        [wireValue] -> Right wireValue
        [] -> Left (PureInputPortMissing portName contractId)
        values -> Left (PureInputPortAmbiguous portName (length values))

    matchedWireValues portName contractId =
      [ wireValue
      | wireValue <- inputBundle.wireInputBundleValues
      , wireValue.wireValueContract == contractId
      , inputValueMatchesPort portName wireValue
      ]

    inputValueMatchesPort portName wireValue
      | Map.size ports.wirePortsInputs == 1 && portName == defaultInputPortName =
          True
      | otherwise =
          wireValue.wireValuePort == Just portName

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
  -> [CorePureBinding]
  -> Map Text CorePureExpr
  -> Either PureEvalError (Map Text Aeson.Value)
evaluatePureTaskOutputs ports inputBundle bindings localBindings outputExprs = do
  validatePurePorts ports outputExprs
  inputValues <- bindPureInputValues ports inputBundle
  let inputEnv = Map.map CorePureJson inputValues
  outerEnv <- bindCorePureBindings (corePureBuiltinEnv <> inputEnv) bindings
  env <- bindCorePureBindings outerEnv localBindings
  traverse (evaluateOutput env) outputExprs
  where
    evaluateOutput env outputExpr = do
      value <- evaluateCorePureExpr env outputExpr
      corePureValueToJson value

type CorePureEnv = Map Text CorePureValue

data CorePureValue
  = CorePureJson !Aeson.Value
  | CorePureClosure !(NonEmpty Text) !CorePureExpr !CorePureEnv
  | CorePureBuiltin !Text !Int !([CorePureValue] -> Either PureEvalError CorePureValue)

evaluateCorePureExpr :: CorePureEnv -> CorePureExpr -> Either PureEvalError CorePureValue
evaluateCorePureExpr env = \case
  CorePureLit literal ->
    Right (CorePureJson (corePureLiteralToJson literal))
  CorePureIdent name ->
    case Map.lookup name env of
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
    case baseValue of
      Aeson.Object object ->
        case KeyMap.lookup (Key.fromText fieldName) object of
          Just value -> Right (CorePureJson value)
          Nothing -> Left (PureFieldMissing fieldName)
      other ->
        Left (PureTypeMismatch "object" (jsonValueKind other))
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
      Right (Map.insert binding.corePureBindingName value currentEnv)

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
    CorePureDivide -> do
      lhsNumber <- corePureNumber lhs
      rhsNumber <- corePureNumber rhs
      if rhsNumber == 0
        then Left PureDivisionByZero
        else Right (CorePureJson (Aeson.Number (lhsNumber / rhsNumber)))
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
      | NE.length params == length argumentValues ->
          validateCorePureParamNames params
            *> evaluateCorePureExpr (Map.fromList (zip (NE.toList params) argumentValues) <> closureEnv) body
      | otherwise ->
          Left (PureFunctionArity "<lambda>" (NE.length params) (length argumentValues))
    CorePureBuiltin name arity implementation
      | arity == length argumentValues ->
          implementation argumentValues
      | otherwise ->
          Left (PureFunctionArity name arity (length argumentValues))
    other ->
      Left (PureFunctionExpected (corePureValueKind other))

corePureBuiltinEnv :: CorePureEnv
corePureBuiltinEnv =
  Map.fromList
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
    ]
  where
    builtin name arity implementation =
      (name, CorePureBuiltin name arity implementation)

corePureMap :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureMap [functionValue, listValue] = do
  values <- corePureArray listValue
  mapped <- traverse (applyJsonFunction functionValue) (Vector.toList values)
  CorePureJson . Aeson.Array . Vector.fromList <$> traverse corePureValueToJson mapped
corePureMap args = impossibleBuiltinArity "map" 2 args

corePureFilter :: [CorePureValue] -> Either PureEvalError CorePureValue
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
        [ Aeson.Array (Vector.fromList [lhsItem, rhsItem])
        | (lhsItem, rhsItem) <- zip lhs rhs
        ]
  Right (CorePureJson (Aeson.Array (Vector.fromList pairs)))
corePureZip args = impossibleBuiltinArity "zip" 2 args

corePureZipWith :: [CorePureValue] -> Either PureEvalError CorePureValue
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
  values <- Vector.toList <$> corePureArray listValue
  numbers <- traverse (corePureNumber . CorePureJson) values
  Right (CorePureJson (Aeson.Number (sum numbers)))
corePureSum args = impossibleBuiltinArity "sum" 1 args

corePureAll :: [CorePureValue] -> Either PureEvalError CorePureValue
corePureAll [functionValue, listValue] = do
  values <- Vector.toList <$> corePureArray listValue
  results <- traverse (applyJsonFunction functionValue >=> corePureBool) values
  Right (CorePureJson (Aeson.Bool (and results)))
corePureAll args = impossibleBuiltinArity "all" 2 args

corePureAny :: [CorePureValue] -> Either PureEvalError CorePureValue
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

applyJsonFunction :: CorePureValue -> Aeson.Value -> Either PureEvalError CorePureValue
applyJsonFunction functionValue value =
  applyCorePureValue functionValue [CorePureJson value]

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

corePureValueKind :: CorePureValue -> Text
corePureValueKind = \case
  CorePureJson value -> jsonValueKind value
  CorePureClosure {} -> "function"
  CorePureBuiltin {} -> "function"

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
    , wireExecutorProjectionConfigShape = WireExecutorConfigSchema pureExecutorConfigSchema
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

pureExecutorConfigSchema :: Aeson.Value
pureExecutorConfigSchema =
  Aeson.object
    [ "$schema" Aeson..= ("https://json-schema.org/draft/2020-12/schema" :: Text)
    , "type" Aeson..= ("object" :: Text)
    , "required" Aeson..= ["outputs" :: Text]
    , "additionalProperties" Aeson..= False
    , "properties"
        Aeson..= Aeson.object
          [ "bindings"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("array" :: Text)
                , "description" Aeson..= ("Top-level CorePure helper bindings shared by all pure outputs." :: Text)
                ]
          , "localBindings"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("array" :: Text)
                , "description" Aeson..= ("Node-local CorePure bindings evaluated after top-level helpers." :: Text)
                ]
          , "outputs"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                , "description" Aeson..= ("Map from output port name to CorePure expression AST." :: Text)
                ]
          ]
    ]
