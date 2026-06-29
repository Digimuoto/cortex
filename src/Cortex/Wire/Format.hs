{- |
Module      : Cortex.Wire.Format
Description : Canonical formatter for Wire source.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The formatter is topology-first for graph expressions: connect chains flow
downward via @=>@ and overlays render as left-to-right frontiers. It formats
through the production AST only when the source surface is known to survive
that route. Source constructs currently lowered or discarded by the parser are
preserved unchanged until Wire has a concrete syntax tree with trivia
ownership.
-}
module Cortex.Wire.Format
  ( WireFormatError (..)
  , renderWireFormatError
  , formatWireSource
  , formatWireSourceWithExpanded
  , formatWireFile
  , formatWireExpr
  )
where

import Data.Char (isAlphaNum)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, formatScientific)
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Wire.Compile (compileWireFile)
import Cortex.Wire.Include (wireSourceIncludeNames)
import Cortex.Wire.Parser
  ( WireParseInfo (..)
  , parseWireFile
  , parseWireFileWithInfo
  , renderParseError
  )
import Cortex.Wire.Syntax

data WireFormatError
  = WireFormatParseError !Text
  | WireFormatCyclicGraph !Text
  deriving stock (Eq, Show)

renderWireFormatError :: WireFormatError -> Text
renderWireFormatError = \case
  WireFormatParseError err ->
    err
  WireFormatCyclicGraph err ->
    "wire fmt refuses to format cyclic Wire graphs: " <> err

formatWireSource :: FilePath -> Text -> Either WireFormatError Text
formatWireSource path source =
  formatWireSourceWithExpanded path source source

formatWireSourceWithExpanded :: FilePath -> Text -> Text -> Either WireFormatError Text
formatWireSourceWithExpanded path source expandedSource = do
  (parseInfo, wireFile) <-
    mapLeft
      (WireFormatParseError . renderParseError)
      (parseWireFileWithInfo path expandedSource)
  rejectCyclicGraph wireFile
  case sourceFormatStrategy source parseInfo of
    PreserveSource ->
      Right (ensureTrailingNewline source)
    FormatLoweredAst ->
      formatLoweredWireFile path wireFile

formatLoweredWireFile :: FilePath -> WireFile -> Either WireFormatError Text
formatLoweredWireFile path wireFile = do
  let formatted = formatWireFile wireFile
  reparsed <-
    mapLeft
      (WireFormatParseError . renderParseError)
      (parseWireFile path formatted)
  if reparsed == wireFile
    then Right formatted
    else
      Left
        ( WireFormatParseError
            "internal formatter error: formatted Wire source parses to a different AST."
        )

-- Topology-first layout would mislead on a cyclic graph, so block formatting
-- when the file lowers far enough to expose a cycle. Other compile errors
-- (e.g. unresolved imports) are tolerated so partially-buildable files can
-- still be tidied.
rejectCyclicGraph :: WireFile -> Either WireFormatError ()
rejectCyclicGraph wireFile =
  case compileWireFile wireFile of
    Left err@WireInvalidTopology {} ->
      Left (WireFormatCyclicGraph (renderWireError err))
    _ ->
      Right ()

formatWireFile :: WireFile -> Text
formatWireFile wireFile =
  ensureTrailingNewline . T.intercalate "\n" . dropTrailingBlank $
    formLines <> returnLines
  where
    formLines =
      intercalateBlank (fmap formatTopForm wireFile.wireFileTopForms)
    returnLines =
      case wireFile.wireFileReturn of
        Nothing -> []
        Just expr ->
          ["" | not (null formLines)]
            <> formatGraphExpr 0 expr

formatWireExpr :: Expr -> Text
formatWireExpr =
  ensureTrailingNewline . T.intercalate "\n" . formatGraphExpr 0

data WireFormatStrategy
  = FormatLoweredAst
  | PreserveSource

sourceFormatStrategy :: Text -> WireParseInfo -> WireFormatStrategy
sourceFormatStrategy source parseInfo
  | sourceNeedsSurfacePreservation source = PreserveSource
  | hasCorePureInterpolation parseInfo = PreserveSource
  | otherwise = FormatLoweredAst
  where
    hasCorePureInterpolation info =
      case info.wireParseCorePureInterpolationLine of
        Nothing -> False
        Just _ -> True

-- The parser lowers `kind`/`form`, source includes, and CorePure
-- interpolation, and it drops comments. Until a CST owns that source trivia,
-- preserve such files byte-for-byte instead of routing them through the
-- lowered-AST renderer.
sourceNeedsSurfacePreservation :: Text -> Bool
sourceNeedsSurfacePreservation source =
  go NotInString False (T.unpack source)
  where
    go _mode _prevIdent [] =
      False
    go mode prevIdent chars =
      case mode of
        InSingleString ->
          case chars of
            '\\' : _escaped : rest -> go InSingleString False rest
            '"' : rest -> go NotInString False rest
            _ : rest -> go InSingleString False rest
        InMultilineString ->
          case chars of
            '\'' : '\'' : rest -> go NotInString False rest
            _ : rest -> go InMultilineString False rest
        NotInString ->
          case chars of
            '#' : _ -> True
            '/' : '*' : _ -> True
            '"' : rest -> go InSingleString False rest
            '\'' : '\'' : rest -> go InMultilineString False rest
            c : rest
              | not prevIdent && reservedAtCursor "kind" chars -> True
              | not prevIdent && reservedAtCursor "form" chars -> True
              | not prevIdent && sourceIncludeAtCursor chars -> True
              | otherwise ->
                  go NotInString (identCont c) rest

    sourceIncludeAtCursor :: String -> Bool
    sourceIncludeAtCursor input =
      any
        ((`reservedAtCursor` input) . T.unpack)
        wireSourceIncludeNames

    reservedAtCursor :: String -> String -> Bool
    reservedAtCursor word input =
      let len = length word
       in take len input == word
            && case drop len input of
              [] -> True
              c : _ -> not (identCont c)

    identCont :: Char -> Bool
    identCont c = isAlphaNum c || c == '_'

data StringMode
  = NotInString
  | InSingleString
  | InMultilineString

formatTopForm :: TopForm -> [Text]
formatTopForm = \case
  TopContract contractDecl ->
    formatContractDecl contractDecl
  TopUse useSpec ->
    [ "use "
        <> renderQName useSpec.useSpecNamespace
        <> ".{"
        <> formatUseItems useSpec.useSpecItems
        <> "};"
    ]
  TopImport importSpec ->
    [formatImportSpec importSpec <> ";"]
  TopLet visibility name rhs ->
    formatLet visibility name rhs
  TopNode nodeDecl ->
    formatNodeDecl nodeDecl

formatContractDecl :: ContractDecl -> [Text]
formatContractDecl contractDecl =
  case contractDecl.contractDeclRecordFields of
    Nothing ->
      ["contract " <> contractName <> ";"]
    Just fields ->
      ["contract " <> contractName <> " {"]
        <> fmap formatContractRecordField fields
        <> ["};"]
  where
    ContractId contractName = contractDecl.contractDeclId

formatContractRecordField :: (Text, ContractId) -> Text
formatContractRecordField (fieldName, fieldContract) =
  "  " <> fieldName <> ": " <> renderContractId fieldContract <> ";"

formatUseItems :: NonEmpty UseItem -> Text
formatUseItems =
  T.intercalate ", " . fmap formatUseItem . toList
  where
    formatUseItem = \case
      UseExecutor name Nothing -> "@" <> name
      UseExecutor name (Just alias) -> "@" <> name <> " as @" <> alias
      UseContract name Nothing -> name
      UseContract name (Just alias) -> name <> " as " <> alias

formatImportSpec :: ImportSpec -> Text
formatImportSpec = \case
  ImportNamed name path ->
    "import " <> name <> " from " <> quoteString path
  ImportExplicit names path ->
    "import {" <> T.intercalate ", " names <> "} from " <> quoteString path

formatLet :: LetVisibility -> Text -> LetRhs -> [Text]
formatLet visibility name = \case
  LetRhsWire expr ->
    formatAssignment (visibilityText <> "let " <> name <> " =") (formatGraphExpr 0 expr) ";"
  LetRhsCorePure expr ->
    [visibilityText <> "let " <> name <> " = " <> formatCorePureLetRhs expr <> ";"]
  where
    visibilityText =
      case visibility of
        LetPrivate -> ""
        LetExported -> "export "

-- The Wire parser tries `expr` before `corePureExpr` for top-level let RHS, so
-- some CorePure forms need surface hints to reparse through the same branch:
-- field-access chains on bare identifiers look like Wire qualified names, and
-- nullary calls look like plain identifiers unless rendered with `()`.
formatCorePureLetRhs :: CorePureExpr -> Text
formatCorePureLetRhs expr
  | isNullaryCall expr = formatNullaryCall expr
  | isIdentChain expr = parenthesizeIdentChain expr
  | otherwise = formatCorePureExpr expr
  where
    isNullaryCall = \case
      CorePureCall _ [] -> True
      _ -> False
    formatNullaryCall = \case
      CorePureCall function [] -> formatCorePureAtom function <> "()"
      other -> formatCorePureExpr other
    isIdentChain = \case
      CorePureFieldAccess base _ -> isIdentChain' base
      _ -> False
    isIdentChain' = \case
      CorePureIdent _ -> True
      CorePureFieldAccess base _ -> isIdentChain' base
      _ -> False
    parenthesizeIdentChain = \case
      e@(CorePureIdent _) -> "(" <> formatCorePureExpr e <> ")"
      CorePureFieldAccess base fieldName ->
        parenthesizeIdentChain base <> "." <> fieldName
      other -> formatCorePureExpr other

formatNodeDecl :: NodeDecl -> [Text]
formatNodeDecl nodeDecl =
  ["node " <> nodeDecl.nodeDeclName]
    <> fmap (indentText 1 . formatPortDecl) inputPorts
    <> formatNodeBody outputPorts nodeDecl.nodeDeclBody
  where
    inputPorts =
      [ port
      | port@PortInputDecl {} <- nodeDecl.nodeDeclPortSig
      ]
    outputPorts =
      [ port
      | port <- nodeDecl.nodeDeclPortSig
      , not (isInputPort port)
      ]

formatNodeBody :: [PortDecl] -> NodeBody -> [Text]
formatNodeBody outputPorts = \case
  NodeBodyPure pureBody ->
    fmap (indentText 1 . formatPureOutputEquation) (toList pureBody.nodePureBodyOutputs)
      <> formatWhereClause pureBody.nodePureBodyWhere
  NodeBodyExecutor whereExpr call ->
    fmap (indentText 1 . formatPortDecl) outputPorts
      <> [indentText 1 ("= " <> formatExecutorCall call <> ";")]
      <> formatWhereClause whereExpr

isInputPort :: PortDecl -> Bool
isInputPort = \case
  PortInputDecl {} -> True
  PortOutputDecl {} -> False
  PortOutputSumDecl {} -> False

formatWhereClause :: Maybe CorePureExpr -> [Text]
formatWhereClause = \case
  Nothing -> []
  Just (CorePureLet bindings body) ->
    [indentText 1 "where let"]
      <> fmap (indentText 2 . formatCorePureBinding) (toList bindings)
      <> [indentText 1 "in"]
      <> formatCorePureBlock 1 body ";"
  Just expr ->
    [indentText 1 ("where " <> formatCorePureExpr expr <> ";")]

formatPureOutputEquation :: PureOutputEquation -> Text
formatPureOutputEquation outputEquation =
  "-> "
    <> formatSumVariant
      ( SumVariant
          outputEquation.pureOutputEquationLabel
          outputEquation.pureOutputEquationContract
      )
    <> " = "
    <> formatCorePureExpr outputEquation.pureOutputEquationExpr
    <> ";"

formatPortDecl :: PortDecl -> Text
formatPortDecl = \case
  PortInputDecl label contract ->
    "<- " <> formatPortLabel label <> ": " <> renderContractId contract <> ";"
  PortOutputDecl label contract ->
    "-> " <> formatPortLabel label <> ": " <> renderContractId contract <> ";"
  PortOutputSumDecl variants ->
    "-> " <> T.intercalate " | " (fmap formatSumVariant (toList variants)) <> ";"

formatSumVariant :: SumVariant -> Text
formatSumVariant variant =
  formatPortLabel variant.svLabel <> ": " <> renderContractId variant.svContract

formatPortLabel :: PortLabel -> Text
formatPortLabel = \case
  NoLabel -> "_"
  Label label -> label

formatExecutorCall :: ExecutorCall -> Text
formatExecutorCall = \case
  ExecutorCallInline executor config inputExpr ->
    "@"
      <> renderQName executor
      <> formatExecutorConfig config
      <> " ("
      <> formatCorePureExpr inputExpr
      <> ")"
  ExecutorCallConfigured name inputExpr ->
    name <> " (" <> formatCorePureExpr inputExpr <> ")"

formatExecutorConfig :: Record -> Text
formatExecutorConfig (Record []) =
  ""
formatExecutorConfig record =
  " " <> formatRecordInline record

formatGraphExpr :: Int -> Expr -> [Text]
formatGraphExpr level = formatGraphWithPrefix level noLinePrefix

data LinePrefix
  = LinePrefixNone
  | LinePrefix !Text
  deriving stock (Eq, Show)

noLinePrefix :: LinePrefix
noLinePrefix = LinePrefixNone

prefixText :: LinePrefix -> Text
prefixText = \case
  LinePrefixNone -> ""
  LinePrefix prefix -> prefix

indentPrefixed :: Int -> LinePrefix -> Text -> Text
indentPrefixed level prefix content =
  indentText level (prefixText prefix <> content)

formatGraphWithPrefix :: Int -> LinePrefix -> Expr -> [Text]
formatGraphWithPrefix level prefix expr =
  case expr of
    ExprConnect {} ->
      formatTopologyChain level prefix (flattenTopology expr)
    ExprStar {} ->
      formatTopologyChain level prefix (flattenTopology expr)
    ExprOverlay {} ->
      formatOverlay level prefix (flattenOverlay expr)
    _ ->
      [indentPrefixed level prefix (formatExprInline expr)]

formatTopologyChain :: Int -> LinePrefix -> TopologyChain -> [Text]
formatTopologyChain level LinePrefixNone chain
  | Just line <- formatInlineTopologyChain chain =
      [indentText level line]
formatTopologyChain level prefix (TopologyChain first rest) =
  formatStage level prefix first <> concatMap formatNext rest
  where
    formatNext (TopologyStep op stageExpr) =
      formatStage (level + 1) (LinePrefix (formatTopologyOp op <> " ")) stageExpr

formatStage :: Int -> LinePrefix -> Expr -> [Text]
formatStage level prefix = \case
  expr@ExprOverlay {} ->
    formatOverlay level prefix (flattenOverlay expr)
  expr@ExprConnect {} ->
    parenthesizeMultiline level prefix (formatGraphExpr (level + 1) expr)
  expr@ExprStar {} ->
    parenthesizeMultiline level prefix (formatGraphExpr (level + 1) expr)
  expr ->
    [indentPrefixed level prefix (formatExprInline expr)]

formatOverlay :: Int -> LinePrefix -> [Expr] -> [Text]
formatOverlay level prefix items
  | length items <= 4 && all isInlineGraphAtom items && T.length inline <= 100 =
      [indentPrefixed level prefix inline]
  | otherwise =
      formatOverlayItems level prefix items
  where
    inline =
      T.intercalate " <> " (fmap formatExprInline items)

formatOverlayItems :: Int -> LinePrefix -> [Expr] -> [Text]
formatOverlayItems level firstPrefix items =
  case firstStagePair items of
    Just (first, second, rest) ->
      [indentPrefixed level firstPrefix (formatExprInline first <> " <> " <> formatExprInline second)]
        <> concatMap formatContinuation rest
    Nothing ->
      concat (zipWith formatItem [0 :: Int ..] items)
  where
    firstStagePair = \case
      first : second : rest
        | firstPrefix == LinePrefixNone
        , isSimpleOverlayContinuation first
        , isSimpleOverlayContinuation second ->
            Just (first, second, rest)
      _ -> Nothing

    formatItem index =
      formatItemAt itemLevel prefix
      where
        (itemLevel, prefix) =
          if index == 0
            then (level, firstPrefix)
            else (level + 1, overlayContinuationPrefix)

    formatItemAt itemLevel prefix item =
      case item of
        ExprConnect {} -> parenthesizeMultiline itemLevel prefix (formatGraphExpr (itemLevel + 1) item)
        ExprStar {} -> parenthesizeMultiline itemLevel prefix (formatGraphExpr (itemLevel + 1) item)
        -- Nested ExprOverlay only reaches this branch from explicit source
        -- grouping (flattenOverlay walks the left spine only). parenthesizeMultiline
        -- always wraps, so the right-nested AST round-trips regardless of how the
        -- inner frontier renders.
        ExprOverlay {} -> parenthesizeMultiline itemLevel prefix (formatGraphExpr (itemLevel + 1) item)
        _ -> [indentPrefixed itemLevel prefix (formatExprInline item)]

    formatContinuation =
      formatItemAt (level + 1) overlayContinuationPrefix

    overlayContinuationPrefix = LinePrefix "<> "

isSimpleOverlayContinuation :: Expr -> Bool
isSimpleOverlayContinuation = \case
  ExprConnect {} -> False
  ExprStar {} -> False
  ExprOverlay {} -> False
  expr -> isInlineGraphAtom expr

parenthesizeMultiline :: Int -> LinePrefix -> [Text] -> [Text]
parenthesizeMultiline level prefix = \case
  [] -> [indentPrefixed level prefix "()"]
  [single] -> [indentPrefixed level prefix ("(" <> T.strip single <> ")")]
  lines' ->
    [indentPrefixed level prefix "("]
      <> lines'
      <> [indentText level ")"]

data TopologyOp
  = TopologyConnect
  | TopologyStar
  deriving stock (Eq, Show)

data TopologyStep = TopologyStep !TopologyOp !Expr
  deriving stock (Eq, Show)

data TopologyChain = TopologyChain !Expr ![TopologyStep]
  deriving stock (Eq, Show)

formatTopologyOp :: TopologyOp -> Text
formatTopologyOp = \case
  TopologyConnect -> "=>"
  TopologyStar -> "*"

formatInlineTopologyChain :: TopologyChain -> Maybe Text
formatInlineTopologyChain = \case
  TopologyChain first [TopologyStep op second]
    | isInlineTopologyAtom first
    , isInlineTopologyAtom second
    , T.length line <= 100 ->
        Just line
    where
      line = formatExprInline first <> " " <> formatTopologyOp op <> " " <> formatExprInline second
  _ -> Nothing

isInlineTopologyAtom :: Expr -> Bool
isInlineTopologyAtom = \case
  ExprOverlay {} -> False
  ExprConnect {} -> False
  ExprStar {} -> False
  ExprMerge {} -> False
  ExprConcat {} -> False
  ExprList {} -> False
  expr -> T.length (formatExprInline expr) <= 80

flattenTopology :: Expr -> TopologyChain
flattenTopology expr =
  uncurry TopologyChain (go expr)
  where
    go = \case
      ExprConnect lhs rhs ->
        let (first, rest) = go lhs
         in (first, rest <> [TopologyStep TopologyConnect rhs])
      ExprStar lhs rhs ->
        let (first, rest) = go lhs
         in (first, rest <> [TopologyStep TopologyStar rhs])
      other -> (other, [])

-- Only flatten the left spine: `<>` is left-associative in the parser, so
-- right-nested overlays in the AST come from explicit grouping in source and
-- must stay grouped to round-trip. Mirrors flattenTopology.
flattenOverlay :: Expr -> [Expr]
flattenOverlay = \case
  ExprOverlay lhs rhs -> flattenOverlay lhs <> [rhs]
  other -> [other]

isInlineGraphAtom :: Expr -> Bool
isInlineGraphAtom = \case
  ExprIdent {} -> True
  ExprLit LitUnit -> True
  ExprSelect base arms ->
    isInlineGraphAtom base && all (isInlineGraphAtom . (.selectArmExpr)) arms
  ExprFamilyProjection {} -> True
  ExprOverlay lhs rhs -> isInlineGraphAtom lhs && isInlineGraphAtom rhs
  ExprConnect lhs rhs -> isInlineGraphAtom lhs && isInlineGraphAtom rhs
  ExprStar lhs rhs -> isInlineGraphAtom lhs && isInlineGraphAtom rhs
  _ -> False

-- The merge parser only accepts atoms as right-hand operands and folds chains
-- left, so right-nested // or ++ in the AST must be reparenthesized to round
-- through the parser unchanged.
isExprAtom :: Expr -> Bool
isExprAtom = \case
  ExprConfiguredExecutor {} -> True
  ExprConstructor {} -> True
  ExprRecord {} -> True
  ExprList {} -> True
  ExprLit {} -> True
  ExprIdent {} -> True
  ExprFamilyProjection {} -> True
  _ -> False

formatMergeOperandLeft :: Expr -> Text
formatMergeOperandLeft expr = case expr of
  ExprMerge {} -> formatExprInline expr
  ExprConcat {} -> formatExprInline expr
  _ | isExprAtom expr -> formatExprInline expr
  _ -> "(" <> formatExprInline expr <> ")"

formatMergeOperandRight :: Expr -> Text
formatMergeOperandRight expr
  | isExprAtom expr = formatExprInline expr
  | otherwise = "(" <> formatExprInline expr <> ")"

formatExprInline :: Expr -> Text
formatExprInline expr =
  case expr of
    ExprOverlay {} ->
      "(" <> T.intercalate " <> " (fmap formatExprInline (flattenOverlay expr)) <> ")"
    ExprConnect {} ->
      "(" <> formatTopologyInline (flattenTopology expr) <> ")"
    ExprStar {} ->
      "(" <> formatTopologyInline (flattenTopology expr) <> ")"
    ExprMerge lhs rhs ->
      formatMergeOperandLeft lhs <> " // " <> formatMergeOperandRight rhs
    ExprConcat lhs rhs ->
      formatMergeOperandLeft lhs <> " ++ " <> formatMergeOperandRight rhs
    ExprSelect base arms ->
      formatExprInline base <> formatSelectSuffix arms
    ExprFamilyProjection familyName indexValue ->
      familyName <> "[" <> T.pack (show indexValue) <> "]"
    ExprConfiguredExecutor name record ->
      "@" <> renderQName name <> " " <> formatRecordInline record
    ExprConstructor name record ->
      renderQName name <> " " <> formatRecordInline record
    ExprRecord record ->
      formatRecordInline record
    ExprList items ->
      "[" <> T.intercalate ", " (fmap formatExprInline items) <> "]"
    ExprLit lit ->
      formatLiteral lit
    ExprIdent name ->
      renderQName name

formatTopologyInline :: TopologyChain -> Text
formatTopologyInline (TopologyChain first rest) =
  formatExprInline first
    <> foldMap
      ( \(TopologyStep op stageExpr) ->
          " " <> formatTopologyOp op <> " " <> formatExprInline stageExpr
      )
      rest

formatSelectSuffix :: NonEmpty SelectArm -> Text
formatSelectSuffix arms =
  " select("
    <> T.intercalate
      ", "
      [ arm.selectArmKey <> ": " <> formatExprInline arm.selectArmExpr
      | arm <- toList arms
      ]
    <> ")"

formatRecordInline :: Record -> Text
formatRecordInline record =
  case formatRecordFields record.recordFields of
    [] -> "{}"
    fields -> "{ " <> T.intercalate " " fields <> " }"

formatRecordFields :: [Field] -> [Text]
formatRecordFields =
  formatFields formatExprInline sameNameExpr . fmap fieldToPair
  where
    fieldToPair field = (field.fieldPath, field.fieldValue)

formatCorePureBlock :: Int -> CorePureExpr -> Text -> [Text]
formatCorePureBlock level expr suffix =
  case expr of
    CorePureRecord fields ->
      [indentText level "{"]
        <> fmap (indentText (level + 1)) (formatCorePureFields fields)
        <> [indentText level ("}" <> suffix)]
    _ ->
      [indentText level (formatCorePureExpr expr <> suffix)]

formatCorePureBinding :: CorePureBinding -> Text
formatCorePureBinding binding =
  binding.corePureBindingName <> " = " <> formatCorePureExpr binding.corePureBindingExpr <> ";"

formatCorePureExpr :: CorePureExpr -> Text
formatCorePureExpr = \case
  CorePureLit literal -> formatCorePureLiteral literal
  CorePureIdent name -> name
  CorePureList items ->
    "[" <> T.intercalate ", " (fmap formatCorePureExpr items) <> "]"
  CorePureRecord fields ->
    case formatCorePureFields fields of
      [] -> "{}"
      rendered -> "{ " <> T.intercalate " " rendered <> " }"
  CorePureFieldAccess base fieldName ->
    formatCorePureAtom base <> "." <> fieldName
  CorePureIndex base indexExpr ->
    formatCorePureAtom base <> "[" <> formatCorePureExpr indexExpr <> "]"
  CorePureLambda params body ->
    -- A lambda body that is itself a lambda must be parenthesised: the parser
    -- folds consecutive `ident:` tokens into a single multi-parameter lambda.
    let renderedBody = case body of
          CorePureLambda {} -> "(" <> formatCorePureExpr body <> ")"
          _ -> formatCorePureExpr body
     in T.intercalate " " (fmap (<> ":") (toList params)) <> " " <> renderedBody
  CorePureCall function args
    | Just rendered <- formatSourceIncludeCall function args ->
        rendered
    | otherwise ->
        T.unwords (formatCorePureAtom function : fmap formatCorePureAtom args)
  CorePureUnary op body ->
    formatCorePureUnaryOp op <> formatCorePureAtom body
  CorePureBinary op lhs rhs ->
    "("
      <> formatCorePureExpr lhs
      <> " "
      <> formatCorePureBinOp op
      <> " "
      <> formatCorePureExpr rhs
      <> ")"
  CorePureLet bindings body ->
    "let "
      <> T.unwords (fmap formatCorePureBinding (toList bindings))
      <> " in "
      <> formatCorePureExpr body
  CorePureIf condition thenExpr elseExpr ->
    "if "
      <> formatCorePureExpr condition
      <> " then "
      <> formatCorePureExpr thenExpr
      <> " else "
      <> formatCorePureExpr elseExpr

formatCorePureAtom :: CorePureExpr -> Text
formatCorePureAtom expr =
  case expr of
    CorePureLit {} -> formatCorePureExpr expr
    CorePureIdent {} -> formatCorePureExpr expr
    CorePureList {} -> formatCorePureExpr expr
    CorePureRecord {} -> formatCorePureExpr expr
    CorePureFieldAccess {} -> formatCorePureExpr expr
    CorePureIndex {} -> formatCorePureExpr expr
    _ -> "(" <> formatCorePureExpr expr <> ")"

formatSourceIncludeCall :: CorePureExpr -> [CorePureExpr] -> Maybe Text
formatSourceIncludeCall function args =
  case (function, args) of
    (CorePureIdent name, [CorePureLit (CorePureString path)])
      | isSourceIncludeName name ->
          Just (name <> "(" <> quoteCorePureString path <> ")")
    _ ->
      Nothing

isSourceIncludeName :: Text -> Bool
isSourceIncludeName =
  (`elem` wireSourceIncludeNames)

formatCorePureFields :: [CorePureField] -> [Text]
formatCorePureFields =
  formatFields formatCorePureExpr sameNameCorePure . fmap fieldToPair
  where
    fieldToPair field = (field.corePureFieldPath, field.corePureFieldValue)

formatFields
  :: (value -> Text)
  -> (value -> Maybe Text)
  -> [(NonEmpty Text, value)]
  -> [Text]
formatFields formatValue sameName =
  go
  where
    go [] = []
    go (field@(path, value) : rest)
      | isSelfField path value =
          let (selfFields, remaining) = span (uncurry isSelfField) (field : rest)
           in ("inherit " <> T.unwords (fmap (NE.head . fst) selfFields) <> ";") : go remaining
      | otherwise =
          (formatFieldPath path <> " = " <> formatValue value <> ";") : go rest
    isSelfField path value =
      case (path, sameName value) of
        (name :| [], Just valueName) -> name == valueName
        _ -> False

sameNameExpr :: Expr -> Maybe Text
sameNameExpr = \case
  ExprIdent (QName (name :| [])) -> Just name
  _ -> Nothing

sameNameCorePure :: CorePureExpr -> Maybe Text
sameNameCorePure = \case
  CorePureIdent name -> Just name
  _ -> Nothing

formatFieldPath :: NonEmpty Text -> Text
formatFieldPath =
  T.intercalate "." . toList

-- The Wire parser only accepts plain decimals (-?[0-9]+(\.[0-9]+)?), so the
-- formatter must avoid scientific notation for any value that round-trips. We
-- ask Data.Scientific for fixed-point output and strip a redundant trailing
-- ".0" so integer values render compactly.
renderDecimal :: Scientific -> Text
renderDecimal number =
  let raw = T.pack (formatScientific Fixed Nothing number)
   in fromMaybe raw (T.stripSuffix ".0" raw)

formatLiteral :: Literal -> Text
formatLiteral = \case
  LitString text -> quoteString text
  LitMultilineString text -> "''" <> text <> "''"
  LitNumber number -> renderDecimal number
  LitBool True -> "true"
  LitBool False -> "false"
  LitUnit -> "()"

formatCorePureLiteral :: CorePureLiteral -> Text
formatCorePureLiteral = \case
  CorePureString text -> quoteCorePureString text
  CorePureNumber number -> renderDecimal number
  CorePureBool True -> "true"
  CorePureBool False -> "false"
  CorePureNull -> "null"

formatCorePureUnaryOp :: CorePureUnaryOp -> Text
formatCorePureUnaryOp = \case
  CorePureNegate -> "-"
  CorePureNot -> "!"

formatCorePureBinOp :: CorePureBinOp -> Text
formatCorePureBinOp = \case
  CorePureAdd -> "+"
  CorePureSubtract -> "-"
  CorePureMultiply -> "*"
  CorePureDivide -> "/"
  CorePureMerge -> "//"
  CorePureEqual -> "=="
  CorePureNotEqual -> "!="
  CorePureLessThan -> "<"
  CorePureLessThanOrEqual -> "<="
  CorePureGreaterThan -> ">"
  CorePureGreaterThanOrEqual -> ">="
  CorePureAnd -> "&&"
  CorePureOr -> "||"

quoteString :: Text -> Text
quoteString text =
  "\"" <> T.concatMap escapeChar text <> "\""
  where
    escapeChar = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\t' -> "\\t"
      '\r' -> "\\r"
      char -> T.singleton char

quoteCorePureString :: Text -> Text
quoteCorePureString text =
  "\"" <> T.replace "${" "\\${" (T.concatMap escapeChar text) <> "\""
  where
    escapeChar = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\t' -> "\\t"
      '\r' -> "\\r"
      char -> T.singleton char

formatAssignment :: Text -> [Text] -> Text -> [Text]
formatAssignment prefix rhs suffix =
  case rhs of
    [] -> [prefix <> " " <> suffix]
    [single] -> [prefix <> " " <> T.strip single <> suffix]
    _ ->
      [prefix]
        <> appendSuffix suffix (fmap (indentText 1) rhs)

appendSuffix :: Text -> [Text] -> [Text]
appendSuffix suffix = \case
  [] -> [suffix]
  [line] -> [line <> suffix]
  line : rest -> line : appendSuffix suffix rest

intercalateBlank :: [[Text]] -> [Text]
intercalateBlank = \case
  [] -> []
  first : rest -> first <> concatMap ([""] <>) rest

dropTrailingBlank :: [Text] -> [Text]
dropTrailingBlank =
  reverse . dropWhile T.null . reverse

indentText :: Int -> Text -> Text
indentText level text =
  T.replicate (level * 2) " " <> text

ensureTrailingNewline :: Text -> Text
ensureTrailingNewline text
  | T.null text = text
  | T.isSuffixOf "\n" text = text
  | otherwise = text <> "\n"

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = \case
  Left err -> Left (f err)
  Right ok -> Right ok
