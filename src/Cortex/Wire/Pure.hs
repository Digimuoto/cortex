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
  , renderPureEvalError
  , validatePurePorts
  , validatePureTaskConfig
  , corePureStaticContextFromBindings
  , corePureWhereStaticFields
  , bindPureInputValues
  , evaluatePureTaskOutputs
  , corePureBuiltinSignature
  , corePureBuiltinAuthorityReport
  , corePureBuiltinAuthorityFree
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
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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
  | PureDuplicateRecordFieldPath ![Text] ![Text]
  | PureJsonParseError !Text
  | PureWhereExpectedRecord !Text
  | PureStaticFieldSetUndeterminable
  | PureStaticBindingCycle !Text
  | PureStaticLetShadowsStatic !Text
  deriving stock (Eq, Show, Generic)

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
  PureDuplicateRecordFieldPath leftPath rightPath ->
    "Pure record literal declares conflicting field paths "
      <> renderRecordPath leftPath
      <> " and "
      <> renderRecordPath rightPath
      <> "."
  PureJsonParseError reason ->
    "Pure expression could not parse JSON: " <> reason <> "."
  PureWhereExpectedRecord actual ->
    "Pure where-clause must evaluate to a record, but received " <> actual <> "."
  PureStaticFieldSetUndeterminable ->
    "Pure where-clause field set is not statically determinable."
  PureStaticBindingCycle bindingName ->
    "Pure where-clause field discovery found a cyclic top-level binding at " <> bindingName <> "."
  PureStaticLetShadowsStatic bindingName ->
    "Pure where-clause local let binding shadows statically known binding " <> bindingName <> "."
  where
    renderList values =
      "[" <> T.intercalate ", " values <> "]"

    renderRecordPath =
      T.intercalate "."

validatePurePorts :: WirePorts -> Map Text CorePureExpr -> Either PureEvalError ()
validatePurePorts ports outputExprs =
  validatePureInputPorts ports *> validatePureOutputPorts ports outputExprs

validatePureTaskConfig
  :: WirePorts
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError ()
validatePureTaskConfig ports bindings whereExpr outputExprs =
  validatePurePorts ports outputExprs
    *> validateCorePureTaskExpressions bindings whereExpr outputExprs

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
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either PureEvalError (Map Text Aeson.Value)
evaluatePureTaskOutputs ports inputBundle bindings whereExpr outputExprs = do
  validatePureTaskConfig ports bindings whereExpr outputExprs
  inputValues <- bindPureInputValues ports inputBundle
  let inputEnv = Map.map CorePureJson inputValues
  outerEnv <- bindCorePureBindings (corePureBuiltinEnv <> inputEnv) bindings
  env <- bindCorePureWhere outerEnv whereExpr
  traverse (evaluateOutput env) outputExprs
  where
    evaluateOutput env outputExpr = do
      value <- evaluateCorePureExpr env outputExpr
      corePureValueToJson value

type CorePureEnv = Map Text CorePureValue

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
                Map.insert (Key.toText key) (CorePureJson value) acc
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
      | length argumentValues < NE.length params -> do
          validateCorePureParamNames params
          (appliedParams, remainingParams) <-
            partialClosureParams params (length argumentValues)
          let closureEnv' = Map.fromList (zip appliedParams argumentValues) <> closureEnv
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

corePureBuiltinEnv :: CorePureEnv
corePureBuiltinEnv =
  Map.fromList
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
        [ Aeson.object ["fst" Aeson..= lhsItem, "snd" Aeson..= rhsItem]
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
          ]
    ]
