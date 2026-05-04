{- |
Module      : Cortex.Wire.Parser
Description : Megaparsec-based parser for canonical Wire syntax.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Mirrors the grammar in @docs/Reference/Wire/grammar.md@.
Produces a 'Cortex.Wire.Syntax.WireFile'; semantic validation
(executor registration, port keys, arity, contract membership) is a
later pass.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Parser
  ( parseWireFile
  , parseWireExpr
  , ParseError
  , renderParseError
  )
where

import Control.Monad (when)
import Data.Char (isAlpha, isAlphaNum, isSpace)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Text.Megaparsec
  ( MonadParsec (notFollowedBy, takeWhileP, try)
  , Parsec
  , anySingle
  , choice
  , eof
  , errorBundlePretty
  , many
  , manyTill
  , optional
  , parse
  , satisfy
  , sepEndBy
  , sepEndBy1
  , some
  , (<|>)
  )
import Text.Megaparsec qualified as MP
import Text.Megaparsec.Char (char, digitChar, space1, string)
import Text.Megaparsec.Char.Lexer qualified as L

import Cortex.Wire.Syntax

type Parser = Parsec Void Text

newtype ParseError = ParseError (MP.ParseErrorBundle Text Void)
  deriving stock (Show)

renderParseError :: ParseError -> Text
renderParseError (ParseError bundle) = T.pack (errorBundlePretty bundle)

------------------------------------------------------------------------
-- Entry points
------------------------------------------------------------------------

parseWireFile :: FilePath -> Text -> Either ParseError WireFile
parseWireFile name src =
  case parse (spaceConsumer *> wireFile <* eof) name src of
    Left bundle -> Left (ParseError bundle)
    Right ok -> Right ok

{- | Parse a single expression (no file-return resolution). Useful for
REPL-style consumption and tests.
-}
parseWireExpr :: FilePath -> Text -> Either ParseError Expr
parseWireExpr name src =
  case parse (spaceConsumer *> expr <* eof) name src of
    Left bundle -> Left (ParseError bundle)
    Right ok -> Right ok

------------------------------------------------------------------------
-- Lexer
------------------------------------------------------------------------

{- | Whitespace eater. Handles spaces/tabs/newlines plus the two comment
kinds: @# …@ line and @/* … */@ block (non-nesting, per grammar §2.1).
-}
spaceConsumer :: Parser ()
spaceConsumer =
  L.space
    space1
    (L.skipLineComment "#")
    (L.skipBlockComment "/*" "*/")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

-- | Reserved word — ensures no identifier continuation follows.
keyword :: Text -> Parser ()
keyword w = lexeme . try $ do
  _ <- string w
  notFollowedBy (satisfy identCont)
  pure ()

reservedWords :: [Text]
reservedWords =
  [ "as"
  , "contract"
  , "else"
  , "export"
  , "false"
  , "from"
  , "if"
  , "inherit"
  , "import"
  , "in"
  , "let"
  , "node"
  , "null"
  , "pure"
  , "select"
  , "then"
  , "true"
  , "use"
  , "where"
  ]

-- | Identifier-continuation predicate.
identCont :: Char -> Bool
identCont c = isAlphaNum c || c == '_'

-- | Unqualified identifier (grammar §2.2).
identifier :: Parser Text
identifier = lexeme . try $ do
  c <- satisfy (\x -> isAlpha x || x == '_')
  rest <- takeWhileP Nothing identCont
  let w = T.cons c rest
  when (w `elem` reservedWords) . fail $
    "reserved word: " <> T.unpack w
  pure w

{- | Qualified identifier: one or more unqualified identifiers joined by
dots (grammar §2.2, §14.4).
-}
qualifiedIdent :: Parser QName
qualifiedIdent = lexeme . try $ do
  first <- bareIdent
  rest <- many $ try (char '.' *> bareIdent)
  pure (QName (first :| rest))
  where
    -- Bare (non-lexemed) identifier — dots consume immediately, so we
    -- must not swallow trailing whitespace between segments.
    bareIdent :: Parser Text
    bareIdent = do
      c <- satisfy (\x -> isAlpha x || x == '_')
      rest <- takeWhileP Nothing identCont
      let w = T.cons c rest
      when (w `elem` reservedWords) . fail $
        "reserved word: " <> T.unpack w
      pure w

-- | @\@qualified.name@ in executor-application position.
executorRef :: Parser QName
executorRef = lexeme . try $ do
  _ <- char '@'
  first <- satisfy (\x -> isAlpha x || x == '_')
  rest <- takeWhileP Nothing identCont
  restSegs <- many $ try (char '.' *> bareSeg)
  let w = T.cons first rest
  pure (QName (w :| restSegs))
  where
    bareSeg :: Parser Text
    bareSeg = do
      c <- satisfy (\x -> isAlpha x || x == '_')
      rest <- takeWhileP Nothing identCont
      pure (T.cons c rest)

------------------------------------------------------------------------
-- Literals
------------------------------------------------------------------------

stringLiteral :: Parser Text
stringLiteral = fmap snd stringLiteralForm

{- | Parse a string literal and report whether it was single-line or
multi-line. Single-line strings use escape sequences; multi-line
strings are verbatim (grammar §2.4).
-}
stringLiteralForm :: Parser (StringForm, Text)
stringLiteralForm = multiLine <|> singleLine
  where
    singleLine :: Parser (StringForm, Text)
    singleLine = lexeme $ do
      _ <- char '"'
      chars <- manyTill stringChar (char '"')
      pure (FormSingle, T.pack chars)

    stringChar :: Parser Char
    stringChar = do
      c <- anySingle
      case c of
        '\\' -> do
          e <- anySingle
          case e of
            'n' -> pure '\n'
            't' -> pure '\t'
            'r' -> pure '\r'
            '"' -> pure '"'
            '\\' -> pure '\\'
            _ -> fail $ "unknown escape: \\" <> [e]
        '\n' -> fail "single-line strings may not contain raw newlines"
        '\r' -> fail "single-line strings may not contain raw carriage returns"
        _ -> pure c

    multiLine :: Parser (StringForm, Text)
    multiLine = lexeme . try $ do
      _ <- string "''"
      body <- multiLineBody
      pure (FormMulti, T.pack body)

    -- Read until the next @''@ terminator.
    multiLineBody :: Parser [Char]
    multiLineBody = do
      c <- anySingle
      if c == '\''
        then do
          follow <- optional (char '\'')
          case follow of
            Just _ -> pure []
            Nothing -> (c :) <$> multiLineBody
        else (c :) <$> multiLineBody

data StringForm = FormSingle | FormMulti
  deriving stock (Eq)

numberLiteral :: Parser Scientific
numberLiteral = lexeme . try $ do
  sign <- optional (char '-')
  intPart <- some digitChar
  fracPart <- optional (char '.' *> some digitChar)
  let raw = maybe id (const ('-' :)) sign $
        case fracPart of
          Nothing -> intPart
          Just fs -> intPart <> "." <> fs
  case reads raw :: [(Scientific, String)] of
    [(n, "")] -> pure n
    _ -> fail $ "bad number: " <> raw

boolLiteral :: Parser Bool
boolLiteral = (True <$ keyword "true") <|> (False <$ keyword "false")

------------------------------------------------------------------------
-- Expressions
------------------------------------------------------------------------

data TopologyOperator = TopologyOverlay | TopologyConnect
  deriving stock (Eq)

{- | Top-level expression. Overlay and connect are both topology
operators; the first implementation requires parentheses when they
are mixed.
-}
expr :: Parser Expr
expr = do
  first <- exprSelectLevel
  rest <- many topologyStep
  case rest of
    [] -> pure first
    (firstOp, _) : _ -> do
      when (any ((/= firstOp) . fst) rest) $
        fail "mixing <> and => requires parentheses"
      pure (foldl' applyTopology first rest)
  where
    topologyStep = do
      op <-
        (TopologyOverlay <$ symbol "<>")
          <|> (TopologyConnect <$ symbol "=>")
      rhs <- exprSelectLevel
      pure (op, rhs)

    applyTopology acc (op, rhs) =
      case op of
        TopologyOverlay -> ExprOverlay acc rhs
        TopologyConnect -> ExprConnect acc rhs

exprSelectLevel :: Parser Expr
exprSelectLevel = do
  base <- exprMergeLevel
  suffixes <- many selectSuffix
  pure (foldl ExprSelect base suffixes)

selectSuffix :: Parser (NonEmpty SelectArm)
selectSuffix = do
  keyword "select"
  _ <- symbol "("
  firstArm <- selectArm
  restArms <- many (symbol "," *> selectArm)
  _ <- optional (symbol ",")
  _ <- symbol ")"
  pure (firstArm :| restArms)

selectArm :: Parser SelectArm
selectArm = do
  armKey <- identifier
  _ <- symbol ":"
  SelectArm armKey <$> expr

{- | @//@ and @++@ share precedence level 5, operate on disjoint value
kinds; the grammar admits either operator in the chain.
-}
exprMergeLevel :: Parser Expr
exprMergeLevel = do
  first <- exprAtom
  rest <- many mergeOrConcat
  pure (foldl (\acc (op, rhs) -> op acc rhs) first rest)
  where
    mergeOrConcat :: Parser (Expr -> Expr -> Expr, Expr)
    mergeOrConcat =
      ( (symbol "//" >> pure ExprMerge)
          <|> (symbol "++" >> pure ExprConcat)
      )
        >>= \op -> exprAtom >>= \rhs -> pure (op, rhs)

{- | String literal as an expression, preserving the single-vs-multi
form on the resulting 'Literal' constructor.
-}
stringLitExpr :: Parser Expr
stringLitExpr = do
  (form, text) <- stringLiteralForm
  pure . ExprLit $ case form of
    FormSingle -> LitString text
    FormMulti -> LitMultilineString text

{- | Atomic expression: application, constructor, record, list, literal,
identifier, or parenthesized group.
-}
exprAtom :: Parser Expr
exprAtom =
  choice
    [ ExprConfiguredExecutor <$> executorRef <*> recordExpr
    , try constructorExpr
    , ExprRecord <$> recordExpr
    , listExpr
    , stringLitExpr
    , ExprLit . LitBool <$> boolLiteral
    , ExprLit . LitNumber <$> numberLiteral
    , parenOrUnit
    , ExprIdent <$> qualifiedIdent
    ]

{- | Tagged-record constructor: a qualified identifier followed
immediately by a record body, with no @\@@ prefix. Value-position only
(grammar §14.4).
-}
constructorExpr :: Parser Expr
constructorExpr = do
  name <- qualifiedIdent
  ExprConstructor name <$> recordExpr

recordExpr :: Parser Record
recordExpr = do
  _ <- symbol "{"
  fields <- concat <$> many terminatedField
  _ <- symbol "}"
  pure (Record fields)

terminatedField :: Parser [Field]
terminatedField = (try inheritFields <|> fmap pure field) <* symbol ";"

field :: Parser Field
field = do
  firstSeg <- identifier
  restSegs <- many (symbol "." *> identifier)
  _ <- symbol "="
  Field (firstSeg :| restSegs) <$> expr

inheritFields :: Parser [Field]
inheritFields = do
  keyword "inherit"
  names <- some identifier
  pure
    [ Field (name :| []) (ExprIdent (QName (name :| [])))
    | name <- names
    ]

listExpr :: Parser Expr
listExpr = do
  _ <- symbol "["
  items <- expr `sepEndBy` symbol ","
  _ <- symbol "]"
  pure (ExprList items)

-- | Parenthesized expression or empty wire.
parenOrUnit :: Parser Expr
parenOrUnit = do
  _ <- symbol "("
  maybeFirst <- optional expr
  case maybeFirst of
    Nothing -> do
      _ <- symbol ")"
      pure (ExprLit LitUnit)
    Just first -> do
      _ <- symbol ")"
      pure first

------------------------------------------------------------------------
-- CorePure expressions
------------------------------------------------------------------------

corePureExpr :: Parser CorePureExpr
corePureExpr =
  choice
    [ try corePureLet
    , try corePureIf
    , try corePureLambda
    , corePurePipeLevel
    ]

corePureIf :: Parser CorePureExpr
corePureIf = do
  keyword "if"
  condition <- corePureExpr
  keyword "then"
  thenExpr <- corePureExpr
  keyword "else"
  CorePureIf condition thenExpr <$> corePureExpr

corePureLet :: Parser CorePureExpr
corePureLet = do
  keyword "let"
  bindings <- requireNonEmpty "CorePure let requires at least one binding" =<< some corePureBinding
  keyword "in"
  CorePureLet bindings <$> corePureExpr

corePureBinding :: Parser CorePureBinding
corePureBinding = do
  name <- identifier
  _ <- symbol "="
  value <- corePureExpr
  _ <- symbol ";"
  pure CorePureBinding {corePureBindingName = name, corePureBindingExpr = value}

corePureLambda :: Parser CorePureExpr
corePureLambda = do
  paramList <- some . try $ do
    param <- identifier
    _ <- symbol ":"
    pure param
  params <- requireNonEmpty "CorePure lambda requires at least one parameter" paramList
  CorePureLambda params <$> corePureExpr

corePurePipeLevel :: Parser CorePureExpr
corePurePipeLevel = do
  first <- corePureMergeLevel
  rest <- many (symbol "|>" *> corePureMergeLevel)
  pure (foldl' (\acc functionExpr -> CorePureCall functionExpr [acc]) first rest)

corePureMergeLevel :: Parser CorePureExpr
corePureMergeLevel =
  chainLeft corePureOrLevel (CorePureBinary CorePureMerge <$ symbol "//")

corePureOrLevel :: Parser CorePureExpr
corePureOrLevel =
  chainLeft corePureAndLevel (CorePureBinary CorePureOr <$ symbol "||")

corePureAndLevel :: Parser CorePureExpr
corePureAndLevel =
  chainLeft corePureCompareLevel (CorePureBinary CorePureAnd <$ symbol "&&")

corePureCompareLevel :: Parser CorePureExpr
corePureCompareLevel =
  chainLeft corePureAddLevel compareOperator
  where
    compareOperator =
      choice
        [ CorePureBinary CorePureEqual <$ symbol "=="
        , CorePureBinary CorePureNotEqual <$ symbol "!="
        , CorePureBinary CorePureLessThanOrEqual <$ symbol "<="
        , CorePureBinary CorePureGreaterThanOrEqual <$ symbol ">="
        , CorePureBinary CorePureLessThan <$ symbol "<"
        , CorePureBinary CorePureGreaterThan <$ symbol ">"
        ]

corePureAddLevel :: Parser CorePureExpr
corePureAddLevel =
  chainLeft corePureMultiplyLevel addOperator
  where
    addOperator =
      choice
        [ CorePureBinary CorePureAdd <$ symbol "+"
        , CorePureBinary CorePureSubtract <$ symbol "-"
        ]

corePureMultiplyLevel :: Parser CorePureExpr
corePureMultiplyLevel =
  chainLeft corePureUnaryLevel multiplyOperator
  where
    multiplyOperator =
      choice
        [ CorePureBinary CorePureMultiply <$ symbol "*"
        , try (CorePureBinary CorePureDivide <$ symbol "/" <* notFollowedBy (char '/'))
        ]

corePureUnaryLevel :: Parser CorePureExpr
corePureUnaryLevel =
  choice
    [ CorePureUnary CorePureNot <$> (symbol "!" *> corePureUnaryLevel)
    , CorePureUnary CorePureNegate <$> (symbol "-" *> corePureUnaryLevel)
    , corePureApplication
    ]

corePureApplication :: Parser CorePureExpr
corePureApplication = do
  function <- corePurePostfix
  arguments <- many (try corePurePostfix)
  pure $
    case arguments of
      [] -> function
      _ -> CorePureCall function arguments

corePurePostfix :: Parser CorePureExpr
corePurePostfix = do
  base <- corePureAtom
  suffixes <- many corePureSuffix
  pure (foldl' (\acc suffix -> suffix acc) base suffixes)
  where
    corePureSuffix =
      choice
        [ do
            _ <- symbol "."
            fieldName <- identifier
            pure (`CorePureFieldAccess` fieldName)
        , do
            _ <- symbol "["
            indexExpr <- corePureExpr
            _ <- symbol "]"
            pure (`CorePureIndex` indexExpr)
        ]

corePureAtom :: Parser CorePureExpr
corePureAtom =
  choice
    [ corePureString
    , CorePureLit . CorePureBool <$> boolLiteral
    , CorePureLit CorePureNull <$ keyword "null"
    , CorePureLit . CorePureNumber <$> numberLiteral
    , corePureList
    , corePureRecord
    , betweenCorePureParens
    , CorePureIdent <$> identifier
    ]

betweenCorePureParens :: Parser CorePureExpr
betweenCorePureParens = do
  _ <- symbol "("
  value <- corePureExpr
  _ <- symbol ")"
  pure value

corePureString :: Parser CorePureExpr
corePureString = do
  corePureSingleLineString <|> corePureIndentedString

corePureSingleLineString :: Parser CorePureExpr
corePureSingleLineString = lexeme $ do
  _ <- char '"'
  raw <- T.pack <$> manyTill singleRawChar (char '"')
  either fail pure (desugarStringSegments FormSingle raw)
  where
    singleRawChar = do
      c <- anySingle
      case c of
        '\n' -> fail "single-line strings may not contain raw newlines"
        '\r' -> fail "single-line strings may not contain raw carriage returns"
        _ -> pure c

corePureIndentedString :: Parser CorePureExpr
corePureIndentedString = lexeme . try $ do
  _ <- string "''"
  raw <- T.pack <$> manyTill anySingle (try (string "''"))
  either fail pure (desugarStringSegments FormMulti (stripIndentedString raw))

data StringSegment = StringText !Text | StringInterpolation !CorePureExpr

desugarStringSegments :: StringForm -> Text -> Either String CorePureExpr
desugarStringSegments form raw =
  buildStringExpr <$> go raw []
  where
    go input acc
      | T.null input = Right (reverse acc)
      | "${" `T.isPrefixOf` input = do
          (exprValue, rest) <- parseInterpolation (T.drop 2 input)
          go rest (StringInterpolation exprValue : acc)
      | form == FormSingle && "\\${" `T.isPrefixOf` input =
          go (T.drop 3 input) (StringText "${" : acc)
      | form == FormSingle && "\\" `T.isPrefixOf` input = do
          (escaped, rest) <- singleEscaped input
          go rest (StringText escaped : acc)
      | form == FormMulti && "''${" `T.isPrefixOf` input =
          go (T.drop 4 input) (StringText "${" : acc)
      | form == FormMulti && "''' " `T.isPrefixOf` input =
          go (T.drop 3 input) (StringText "'' " : acc)
      | form == FormMulti && "''\\n" `T.isPrefixOf` input =
          go (T.drop 4 input) (StringText "\n" : acc)
      | form == FormMulti && "''\\t" `T.isPrefixOf` input =
          go (T.drop 4 input) (StringText "\t" : acc)
      | form == FormMulti && "''\\r" `T.isPrefixOf` input =
          go (T.drop 4 input) (StringText "\r" : acc)
      | otherwise =
          let (prefix, rest) = breakOnNextSpecial form input
           in go rest (StringText prefix : acc)

    singleEscaped input =
      case T.unpack (T.take 2 input) of
        ['\\', 'n'] -> Right ("\n", T.drop 2 input)
        ['\\', 't'] -> Right ("\t", T.drop 2 input)
        ['\\', 'r'] -> Right ("\r", T.drop 2 input)
        ['\\', '"'] -> Right ("\"", T.drop 2 input)
        ['\\', '\\'] -> Right ("\\", T.drop 2 input)
        ['\\', c] -> Left ("unknown escape: \\" <> [c])
        _ -> Left "unterminated escape"

parseInterpolation :: Text -> Either String (CorePureExpr, Text)
parseInterpolation input =
  case parse interpolationParser "string interpolation" input of
    Left bundle -> Left (errorBundlePretty bundle)
    Right value -> Right value
  where
    interpolationParser = do
      value <- spaceConsumer *> corePureExpr <* spaceConsumer
      _ <- char '}'
      rest <- MP.getInput
      pure (value, rest)

breakOnNextSpecial :: StringForm -> Text -> (Text, Text)
breakOnNextSpecial form input =
  let specialPrefixes =
        case form of
          FormSingle -> ["${", "\\"]
          FormMulti -> ["${", "''${", "''\\n", "''\\t", "''\\r"]
      indexOf prefix =
        case T.breakOn prefix input of
          (before, after)
            | T.null after -> Nothing
            | otherwise -> Just (T.length before)
      firstIndex = minimumMaybe (mapMaybe indexOf specialPrefixes)
   in case firstIndex of
        Nothing -> (input, "")
        Just idx -> T.splitAt idx input

minimumMaybe :: Ord a => [a] -> Maybe a
minimumMaybe values =
  case values of
    [] -> Nothing
    first : rest -> Just (foldl' min first rest)

buildStringExpr :: [StringSegment] -> CorePureExpr
buildStringExpr rawSegments =
  case mergeTextSegments rawSegments of
    [] -> CorePureLit (CorePureString "")
    [StringText text] -> CorePureLit (CorePureString text)
    segments ->
      CorePureCall
        (CorePureIdent "concat")
        [ CorePureList
            [ case segment of
                StringText text -> CorePureLit (CorePureString text)
                StringInterpolation exprValue ->
                  CorePureCall (CorePureIdent "toString") [exprValue]
            | segment <- segments
            ]
        ]

mergeTextSegments :: [StringSegment] -> [StringSegment]
mergeTextSegments =
  foldr mergeStep []
  where
    mergeStep (StringText "") acc = acc
    mergeStep (StringText left) (StringText right : rest) = StringText (left <> right) : rest
    mergeStep segment acc = segment : acc

stripIndentedString :: Text -> Text
stripIndentedString raw =
  let withoutOpeningBlank =
        case T.breakOn "\n" raw of
          (firstLine, rest)
            | T.all isSpace firstLine && not (T.null rest) -> T.drop 1 rest
          _ -> raw
      linesWithBlanks = T.splitOn "\n" withoutOpeningBlank
      nonBlankLines = filter (not . T.all isSpace) linesWithBlanks
      commonIndent =
        minimumMaybe
          [ T.length (T.takeWhile (\c -> c == ' ' || c == '\t') line)
          | line <- nonBlankLines
          ]
      stripLine line =
        case commonIndent of
          Nothing -> line
          Just indent
            | T.all isSpace line -> ""
            | otherwise -> T.drop indent line
   in T.intercalate "\n" (fmap stripLine linesWithBlanks)

corePureList :: Parser CorePureExpr
corePureList = do
  _ <- symbol "["
  items <- corePureExpr `sepEndBy` symbol ","
  _ <- symbol "]"
  pure (CorePureList items)

corePureRecord :: Parser CorePureExpr
corePureRecord = do
  _ <- symbol "{"
  fields <- concat <$> many corePureTerminatedField
  _ <- symbol "}"
  pure (CorePureRecord fields)

corePureTerminatedField :: Parser [CorePureField]
corePureTerminatedField = (try corePureInheritFields <|> fmap pure corePureField) <* symbol ";"

corePureField :: Parser CorePureField
corePureField = do
  firstSeg <- identifier
  restSegs <- many (symbol "." *> identifier)
  _ <- symbol "="
  CorePureField (firstSeg :| restSegs) <$> corePureExpr

corePureInheritFields :: Parser [CorePureField]
corePureInheritFields = do
  keyword "inherit"
  names <- some identifier
  pure [CorePureField (name :| []) (CorePureIdent name) | name <- names]

chainLeft :: Parser a -> Parser (a -> a -> a) -> Parser a
chainLeft operand operator = do
  first <- operand
  rest <- many $ do
    op <- operator
    rhs <- operand
    pure (op, rhs)
  pure (foldl' (\acc (op, rhs) -> op acc rhs) first rest)

requireNonEmpty :: String -> [a] -> Parser (NonEmpty a)
requireNonEmpty message values =
  case NE.nonEmpty values of
    Just nonEmptyValues -> pure nonEmptyValues
    Nothing -> fail message

------------------------------------------------------------------------
-- Port signatures
------------------------------------------------------------------------

inputPort :: Parser PortDecl
inputPort = do
  _ <- symbol "<-"
  lbl <- requiredLabel
  PortInputDecl lbl . ContractId <$> identifier

outputPort :: Parser PortDecl
outputPort = do
  _ <- symbol "->"
  firstVariant <- outputVariant
  -- Look ahead for a sum-group separator.
  moreVariants <- many (symbol "|" *> outputVariant)
  case moreVariants of
    [] ->
      let SumVariant lbl c = firstVariant
       in pure (PortOutputDecl lbl c)
    _ -> do
      let variants = firstVariant :| moreVariants
      pure (PortOutputSumDecl variants)

outputVariant :: Parser SumVariant
outputVariant = do
  lbl <- requiredLabel
  SumVariant lbl . ContractId <$> identifier

requiredLabel :: Parser PortLabel
requiredLabel = do
  name <- identifier
  _ <- symbol ":"
  pure (Label name)

------------------------------------------------------------------------
-- Top-level forms
------------------------------------------------------------------------

wireFile :: Parser WireFile
wireFile = do
  forms <- many topForm
  -- File-return is a trailing expression with no @;@.
  ret <- optional . try $ do
    e <- fileReturnExpr
    notFollowedBy (symbol ";")
    pure e
  pure (WireFile forms ret)

fileReturnExpr :: Parser Expr
fileReturnExpr = expr

topForm :: Parser TopForm
topForm =
  choice
    [ contractDecl
    , useStmt
    , nodeDecl
    , letBinding
    , importStmt
    ]

contractDecl :: Parser TopForm
contractDecl = do
  keyword "contract"
  n <- identifier
  _ <- symbol ";"
  pure (TopContract (ContractId n))

useStmt :: Parser TopForm
useStmt = do
  keyword "use"
  namespace <- qualifiedIdent
  _ <- symbol "."
  _ <- symbol "{"
  items <-
    requireNonEmpty "use statements require at least one selected name"
      =<< useItem `sepEndBy1` symbol ","
  _ <- symbol "}"
  _ <- symbol ";"
  pure (TopUse (UseSpec namespace items))

useItem :: Parser UseItem
useItem =
  useExecutorItem <|> useContractItem
  where
    useExecutorItem = do
      _ <- symbol "@"
      name <- identifier
      alias <- optional $ do
        keyword "as"
        _ <- symbol "@"
        identifier
      pure (UseExecutor name alias)

    useContractItem = do
      name <- identifier
      alias <- optional $ do
        keyword "as"
        identifier
      pure (UseContract name alias)

nodeDecl :: Parser TopForm
nodeDecl = do
  keyword "node"
  name <- identifier
  inputs <- many (try (inputPort <* symbol ";"))
  (outputs, mkBody) <- nodeImplementationBody
  whereExpr <- optional (try whereClause)
  pure (TopNode (NodeDecl name (inputs <> outputs) (mkBody whereExpr)))

nodeImplementationBody :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
nodeImplementationBody =
  choice
    [ try pureImplementation
    , try singleOutputExecutorShorthand
    , executorImplementation
    ]

pureImplementation :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
pureImplementation = do
  outputEquations <-
    requireNonEmpty "pure node requires at least one output equation" =<< some (try pureOutputEquation)
  let outputs = fmap pureOutputEquationPortDecl (NE.toList outputEquations)
  pure
    ( outputs
    , \whereExpr ->
        NodeBodyPure
          NodePureBody
            { nodePureBodyWhere = whereExpr
            , nodePureBodyOutputs = outputEquations
            }
    )

singleOutputExecutorShorthand :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
singleOutputExecutorShorthand = do
  _ <- symbol "->"
  SumVariant label contractId <- outputVariant
  _ <- symbol "="
  call <- executorCall
  _ <- symbol ";"
  pure
    ( [PortOutputDecl label contractId]
    , (`NodeBodyExecutor` call)
    )

executorImplementation :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
executorImplementation = do
  outputs <- many (try (outputPort <* symbol ";"))
  _ <- symbol "="
  call <- executorCall
  _ <- symbol ";"
  pure (outputs, (`NodeBodyExecutor` call))

whereClause :: Parser CorePureExpr
whereClause = do
  keyword "where"
  exprValue <- corePureExpr
  _ <- symbol ";"
  pure exprValue

pureOutputEquation :: Parser PureOutputEquation
pureOutputEquation = do
  _ <- symbol "->"
  SumVariant label contractId <- outputVariant
  _ <- symbol "="
  PureOutputEquation label contractId
    <$> pureOutputExpression
    <* symbol ";"

pureOutputExpression :: Parser CorePureExpr
pureOutputExpression = do
  keyword "pure"
  _ <- symbol "("
  value <- corePureExpr
  _ <- symbol ")"
  pure value

executorCall :: Parser ExecutorCall
executorCall =
  try inlineExecutorCall <|> configuredExecutorCall
  where
    inlineExecutorCall = do
      executor <- executorRef
      when (renderQName executor == "pure") $
        fail "pure nodes must be authored with pure (...) output equations"
      config <- fromMaybe (Record []) <$> optional (try recordExpr)
      inputArg <- betweenCallParens corePureExpr
      pure (ExecutorCallInline executor config inputArg)

    configuredExecutorCall = do
      name <- identifier
      inputArg <- betweenCallParens corePureExpr
      pure (ExecutorCallConfigured name inputArg)

betweenCallParens :: Parser a -> Parser a
betweenCallParens inner = do
  _ <- symbol "("
  value <- inner
  _ <- symbol ")"
  pure value

pureOutputEquationPortDecl :: PureOutputEquation -> PortDecl
pureOutputEquationPortDecl outputEquation =
  PortOutputDecl
    (pureOutputEquationLabel outputEquation)
    (pureOutputEquationContract outputEquation)

letBinding :: Parser TopForm
letBinding = do
  visibility <- (LetExported <$ keyword "export") <|> pure LetPrivate
  keyword "let"
  name <- identifier
  _ <- symbol "="
  TopLet visibility name <$> letRhs

letRhs :: Parser LetRhs
letRhs =
  try (LetRhsWire <$> expr <* symbol ";")
    <|> (LetRhsCorePure <$> corePureExpr <* symbol ";")

importStmt :: Parser TopForm
importStmt = do
  keyword "import"
  spec <- namedForm <|> explicitForm
  _ <- symbol ";"
  pure (TopImport spec)
  where
    namedForm = do
      n <- identifier
      keyword "from"
      ImportNamed n <$> stringLiteral

    explicitForm = do
      _ <- symbol "{"
      names <- identifier `sepEndBy` symbol ","
      _ <- symbol "}"
      keyword "from"
      ImportExplicit names <$> stringLiteral
