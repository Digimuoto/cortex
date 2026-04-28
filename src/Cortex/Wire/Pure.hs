{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | First-slice deterministic Wire pure evaluator.
--
-- This module is intentionally small: numeric JSON scalar expressions over
-- explicit Wire input ports. Host authority and Pulse binding live outside
-- Wire source; this module only supplies the inert projection and pure
-- evaluation logic.
module Cortex.Wire.Pure
  ( PureExpr (..),
    PureEvalError (..),
    renderPureEvalError,
    parsePureExpr,
    evaluatePureExpr,
    evaluatePureExprText,
    bindPureInputVariables,
    evaluatePureTaskOutput,
    pureWireExecutorId,
    pureWireExecutorProjection,
    pureExecutorConfigSchema,
  )
where

import Control.Applicative (empty)
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..),
    WireExecutorEffect (..),
    WireExecutorId (..),
    WireExecutorPortPolicy (..),
    WireExecutorProjection (..),
  )
import Cortex.Wire.Runtime (WireInputBundle (..))
import Cortex.Wire.Syntax
  ( WireInputCardinality (..),
    WireInputPort (..),
    WirePorts (..),
    defaultInputPortName,
  )
import Cortex.Wire.Value (WirePayloadKind (..), WireValue (..), renderWirePayloadKind)
import Data.Aeson qualified as Aeson
import Data.Char qualified as Char
import Data.Functor (($>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import GHC.Generics (Generic)
import Text.Megaparsec
  ( MonadParsec (notFollowedBy, takeWhileP),
    Parsec,
    between,
    choice,
    eof,
    errorBundlePretty,
    parse,
    satisfy,
    try,
    (<|>),
  )
import Text.Megaparsec.Char (char, space1)
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = Parsec Void Text

data PureExpr
  = PureNumber !Scientific
  | PureVariable !Text
  | PureNegate !PureExpr
  | PureAdd !PureExpr !PureExpr
  | PureSubtract !PureExpr !PureExpr
  | PureMultiply !PureExpr !PureExpr
  | PureDivide !PureExpr !PureExpr
  deriving stock (Eq, Show, Generic)

data PureEvalError
  = PureExpressionParseError !Text
  | PureMissingVariable !Text
  | PureDivisionByZero
  | PureInputPortUnsupported !Text !Text
  | PureInputPortRequiresLabel !Text !Text
  | PureInputPortMissing !Text !Text
  | PureInputPortAmbiguous !Text !Int
  | PureInputPayloadKindMismatch !Text !WirePayloadKind
  | PureInputNonNumeric !Text !Aeson.Value
  deriving stock (Eq, Show, Generic)

renderPureEvalError :: PureEvalError -> Text
renderPureEvalError = \case
  PureExpressionParseError errText ->
    "Invalid pure expression: " <> errText
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
      <> " expected a JSON scalar but received payload kind "
      <> renderWirePayloadKind payloadKind
      <> "."
  PureInputNonNumeric portName value ->
    "Pure input port "
      <> portName
      <> " expected a numeric JSON value but received "
      <> T.pack (show value)
      <> "."

parsePureExpr :: Text -> Either PureEvalError PureExpr
parsePureExpr sourceText =
  case parse (spaceConsumer *> expression <* eof) "wire-pure-expression" sourceText of
    Left bundle -> Left (PureExpressionParseError (T.pack (errorBundlePretty bundle)))
    Right expr -> Right expr

evaluatePureExprText :: Map Text Scientific -> Text -> Either PureEvalError Scientific
evaluatePureExprText variables sourceText = do
  expr <- parsePureExpr sourceText
  evaluatePureExpr variables expr

evaluatePureExpr :: Map Text Scientific -> PureExpr -> Either PureEvalError Scientific
evaluatePureExpr variables = \case
  PureNumber number ->
    Right number
  PureVariable variableName ->
    case Map.lookup variableName variables of
      Just value -> Right value
      Nothing -> Left (PureMissingVariable variableName)
  PureNegate expr ->
    negate <$> evaluatePureExpr variables expr
  PureAdd lhs rhs ->
    (+) <$> evaluatePureExpr variables lhs <*> evaluatePureExpr variables rhs
  PureSubtract lhs rhs ->
    (-) <$> evaluatePureExpr variables lhs <*> evaluatePureExpr variables rhs
  PureMultiply lhs rhs ->
    (*) <$> evaluatePureExpr variables lhs <*> evaluatePureExpr variables rhs
  PureDivide lhs rhs -> do
    numerator <- evaluatePureExpr variables lhs
    denominator <- evaluatePureExpr variables rhs
    if denominator == 0
      then Left PureDivisionByZero
      else Right (numerator / denominator)

bindPureInputVariables :: WirePorts -> WireInputBundle -> Either PureEvalError (Map Text Scientific)
bindPureInputVariables ports inputBundle =
  Map.fromList <$> traverse bindInputPort (Map.toAscList ports.wirePortsInputs)
  where
    inputContractCounts =
      Map.fromListWith
        (+)
        [ (contractId, 1 :: Int)
        | inputPort <- Map.elems ports.wirePortsInputs,
          contractId <- inputPort.wireInputPortAccepts
        ]

    bindInputPort (portName, inputPort) = do
      contractId <- exactInputContract portName inputPort
      if repeatedGeneratedPortName portName contractId
        then Left (PureInputPortRequiresLabel portName contractId)
        else do
          wireValue <- singleMatchedValue portName contractId
          number <- wireValueNumber portName wireValue
          Right (portName, number)

    exactInputContract portName inputPort =
      case inputPort.wireInputPortAccepts of
        [contractId]
          | inputPort.wireInputPortCardinality == WireInputCardinalityOne ->
              Right contractId
          | otherwise ->
              Left (PureInputPortUnsupported portName "list inputs are not supported in the first pure evaluator slice")
        [] ->
          Left (PureInputPortUnsupported portName "no accepted contract")
        _ ->
          Left (PureInputPortUnsupported portName "multiple accepted contracts")

    repeatedGeneratedPortName portName contractId =
      Map.findWithDefault 0 contractId inputContractCounts > 1
        && portName == generatedPortNamePrefix contractId portName

    generatedPortNamePrefix contractId portName =
      let prefix = contractId <> "_"
       in if prefix `T.isPrefixOf` portName && T.all Char.isDigit (T.drop (T.length prefix) portName)
            then portName
            else ""

    singleMatchedValue portName contractId =
      case matchedWireValues portName contractId of
        [wireValue] -> Right wireValue
        [] -> Left (PureInputPortMissing portName contractId)
        values -> Left (PureInputPortAmbiguous portName (length values))

    matchedWireValues portName contractId =
      [ wireValue
      | wireValue <- inputBundle.wireInputBundleValues,
        wireValue.wireValueContract == contractId,
        inputValueMatchesPort portName wireValue
      ]

    inputValueMatchesPort portName wireValue
      | Map.size ports.wirePortsInputs == 1 && portName == defaultInputPortName =
          True
      | otherwise =
          wireValue.wireValuePort == Just portName

wireValueNumber :: Text -> WireValue -> Either PureEvalError Scientific
wireValueNumber portName wireValue
  | wireValue.wireValuePayloadKind /= WirePayloadJson =
      Left (PureInputPayloadKindMismatch portName wireValue.wireValuePayloadKind)
  | otherwise =
      case wireValue.wireValueValue of
        Aeson.Number number -> Right number
        other -> Left (PureInputNonNumeric portName other)

evaluatePureTaskOutput :: WirePorts -> WireInputBundle -> Text -> Either PureEvalError Aeson.Value
evaluatePureTaskOutput ports inputBundle expressionText = do
  variables <- bindPureInputVariables ports inputBundle
  Aeson.Number <$> evaluatePureExprText variables expressionText

pureWireExecutorId :: WireExecutorId
pureWireExecutorId = WireExecutorId "pure"

pureWireExecutorProjection :: WireExecutorProjection
pureWireExecutorProjection =
  WireExecutorProjection
    { wireExecutorProjectionId = pureWireExecutorId,
      wireExecutorProjectionPorts =
        WirePorts
          { wirePortsInputs = Map.empty,
            wirePortsOutputs = Map.empty
          },
      wireExecutorProjectionVocabulary = Set.empty,
      wireExecutorProjectionEffect = WireExecutorPure,
      wireExecutorProjectionConfigShape = WireExecutorConfigSchema pureExecutorConfigSchema,
      wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

pureExecutorConfigSchema :: Aeson.Value
pureExecutorConfigSchema =
  Aeson.object
    [ "$schema" Aeson..= ("https://json-schema.org/draft/2020-12/schema" :: Text),
      "type" Aeson..= ("object" :: Text),
      "required" Aeson..= ["expr" :: Text],
      "additionalProperties" Aeson..= False,
      "properties"
        Aeson..= Aeson.object
          [ "expr"
              Aeson..= Aeson.object
                [ "type" Aeson..= ("string" :: Text),
                  "description"
                    Aeson..= ( "Numeric Wire pure expression over explicit input labels." ::
                                 Text
                             )
                ]
          ]
    ]

spaceConsumer :: Parser ()
spaceConsumer =
  L.space space1 empty empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

identifier :: Parser Text
identifier = lexeme . try $ do
  firstChar <- satisfy (\c -> Char.isAlpha c || c == '_')
  rest <- takeWhileP Nothing (\c -> Char.isAlphaNum c || c == '_')
  pure (T.cons firstChar rest)

numberLiteral :: Parser PureExpr
numberLiteral =
  PureNumber <$> lexeme (L.signed (pure ()) L.scientific)

variable :: Parser PureExpr
variable =
  PureVariable <$> identifier

term :: Parser PureExpr
term =
  choice
    [ between (symbol "(") (symbol ")") expression,
      numberLiteral,
      variable
    ]

factor :: Parser PureExpr
factor =
  (symbol "-" *> (PureNegate <$> factor))
    <|> term

expression :: Parser PureExpr
expression =
  chainLeft multiplyExpression addOperator

multiplyExpression :: Parser PureExpr
multiplyExpression =
  chainLeft factor multiplyOperator

chainLeft :: Parser PureExpr -> Parser (PureExpr -> PureExpr -> PureExpr) -> Parser PureExpr
chainLeft operand operator = do
  first <- operand
  foldl' (\acc (op, rhs) -> op acc rhs) first <$> manyOperatorApplications
  where
    manyOperatorApplications =
      manyPairs []
    manyPairs acc =
      ( do
          op <- operator
          rhs <- operand
          manyPairs (acc <> [(op, rhs)])
      )
        <|> pure acc

addOperator :: Parser (PureExpr -> PureExpr -> PureExpr)
addOperator =
  choice
    [ symbol "+" $> PureAdd,
      symbol "-" $> PureSubtract
    ]

multiplyOperator :: Parser (PureExpr -> PureExpr -> PureExpr)
multiplyOperator =
  choice
    [ symbol "*" $> PureMultiply,
      try (symbol "/" <* notFollowedBy (char '/')) $> PureDivide
    ]
