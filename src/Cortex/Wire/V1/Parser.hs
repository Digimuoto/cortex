{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Megaparsec-based parser for Wire syntax.
--
-- Mirrors the grammar in @docs/Reference/Wire/grammar.md@.
-- Produces a 'Cortex.Wire.V1.AST.WireFile'; semantic validation
-- (executor registration, port keys, arity, contract membership) is a
-- later pass.
module Cortex.Wire.V1.Parser
  ( parseWireFile,
    parseWireExpr,
    ParseError,
    renderParseError,
  )
where

import Control.Monad (when)
import Cortex.Wire.V1.AST
import Data.Char (isAlpha, isAlphaNum)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isJust)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Text.Megaparsec
  ( MonadParsec (notFollowedBy, takeWhileP, try),
    Parsec,
    anySingle,
    choice,
    eof,
    errorBundlePretty,
    many,
    manyTill,
    optional,
    parse,
    satisfy,
    sepEndBy,
    some,
    (<?>),
    (<|>),
  )
import Text.Megaparsec qualified as MP
import Text.Megaparsec.Char (char, digitChar, space1, string)
import Text.Megaparsec.Char.Lexer qualified as L

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

-- | Parse a single expression (no file-return resolution). Useful for
-- REPL-style consumption and tests.
parseWireExpr :: FilePath -> Text -> Either ParseError Expr
parseWireExpr name src =
  case parse (spaceConsumer *> expr <* eof) name src of
    Left bundle -> Left (ParseError bundle)
    Right ok -> Right ok

------------------------------------------------------------------------
-- Lexer
------------------------------------------------------------------------

-- | Whitespace eater. Handles spaces/tabs/newlines plus the two comment
-- kinds: @# …@ line and @/* … */@ block (non-nesting, per grammar §2.1).
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
  ["contract", "node", "let", "import", "from", "select", "true", "false"]

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

-- | Qualified identifier: one or more unqualified identifiers joined by
-- dots (grammar §2.2, §14.4).
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

-- | Parse a string literal and report whether it was single-line or
-- multi-line. Single-line strings use escape sequences; multi-line
-- strings are verbatim (grammar §2.4).
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

-- | Top-level expression = overlay level (lowest precedence).
expr :: Parser Expr
expr = exprOverlayLevel

-- | @<>@ binds the loosest: @a => b <> c@ parses as @a => (b <> c)@ …
-- wait, <> is infixl 2 (lowest), so the overlay layer sits OUTSIDE =>.
-- Correct reading: @a => b <> c => d@ parses as @(a => b) <> (c => d)@.
exprOverlayLevel :: Parser Expr
exprOverlayLevel = do
  first <- exprConnectLevel
  rest <- many (symbol "<>" *> exprConnectLevel)
  pure (foldl ExprOverlay first rest)

exprConnectLevel :: Parser Expr
exprConnectLevel = do
  first <- exprSelectLevel
  rest <- many (symbol "=>" *> exprSelectLevel)
  pure (foldl ExprConnect first rest)

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

-- | @//@ and @++@ share precedence level 5, operate on disjoint value
-- kinds; the grammar admits either operator in the chain.
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

-- | String literal as an expression, preserving the single-vs-multi
-- form on the resulting 'Literal' constructor.
stringLitExpr :: Parser Expr
stringLitExpr = do
  (form, text) <- stringLiteralForm
  pure . ExprLit $ case form of
    FormSingle -> LitString text
    FormMulti -> LitMultilineString text

-- | Atomic expression: application, constructor, record, list, literal,
-- identifier, or parenthesized group / tuple.
exprAtom :: Parser Expr
exprAtom =
  choice
    [ ExprApply <$> executorRef <*> recordExpr,
      try constructorExpr,
      ExprRecord <$> recordExpr,
      listExpr,
      stringLitExpr,
      ExprLit . LitBool <$> boolLiteral,
      ExprLit . LitNumber <$> numberLiteral,
      parenOrTuple,
      ExprIdent <$> qualifiedIdent
    ]

-- | Tagged-record constructor: a qualified identifier followed
-- immediately by a record body, with no @\@@ prefix. Value-position only
-- (grammar §14.4).
constructorExpr :: Parser Expr
constructorExpr = do
  name <- qualifiedIdent
  ExprConstructor name <$> recordExpr

recordExpr :: Parser Record
recordExpr = do
  _ <- symbol "{"
  fields <- many terminatedField
  _ <- symbol "}"
  pure (Record fields)

terminatedField :: Parser Field
terminatedField = field <* symbol ";"

field :: Parser Field
field = do
  firstSeg <- identifier
  restSegs <- many (symbol "." *> identifier)
  _ <- symbol "="
  Field (firstSeg :| restSegs) <$> expr

listExpr :: Parser Expr
listExpr = do
  _ <- symbol "["
  items <- expr `sepEndBy` symbol ","
  _ <- symbol "]"
  pure (ExprList items)

-- | Parenthesized expression or tuple (grammar §14.4).
parenOrTuple :: Parser Expr
parenOrTuple = do
  _ <- symbol "("
  maybeFirst <- optional expr
  case maybeFirst of
    Nothing -> do
      _ <- symbol ")"
      pure (ExprLit LitUnit)
    Just first -> do
      rest <- many (symbol "," *> expr)
      hadTrailingComma <- isJust <$> optional (symbol ",")
      _ <- symbol ")"
      case rest of
        []
          | hadTrailingComma ->
              fail "single-element tuples are not admitted"
          | otherwise ->
              pure first
        _ ->
          pure (ExprTuple (first : rest))

------------------------------------------------------------------------
-- Port signatures
------------------------------------------------------------------------

-- | Zero or more port declarations. Terminates at the first non-port
-- token (@=@ introducing the body).
portSignature :: Parser [PortDecl]
portSignature = many (try portDecl)

portDecl :: Parser PortDecl
portDecl = inputPort <|> outputPort

inputPort :: Parser PortDecl
inputPort = do
  _ <- symbol "<-"
  (lbl, typ) <- portBodyInput
  pure (uncurry (PortInputDecl lbl) typ)

portBodyInput :: Parser (PortLabel, (ContractId, PortArity))
portBodyInput = do
  lbl <- optionalLabel
  typ <- inputType
  pure (lbl, typ)

-- | Single-contract or bracketed list contract.
inputType :: Parser (ContractId, PortArity)
inputType =
  (listed <|> single) <?> "input contract"
  where
    single = do
      c <- identifier
      pure (ContractId c, PortSingular)

    listed = do
      _ <- symbol "["
      c <- identifier
      _ <- symbol "]"
      pure (ContractId c, PortList)

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
  lbl <- optionalLabel
  SumVariant lbl . ContractId <$> identifier

-- | Optional @label:@ prefix. Distinguished from a bare
-- contract-name-then-separator by lookahead for the colon.
optionalLabel :: Parser PortLabel
optionalLabel = do
  ml <- optional . try $ do
    name <- identifier
    _ <- symbol ":"
    pure name
  pure (maybe NoLabel Label ml)

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
fileReturnExpr = do
  first <- expr
  rest <- many (symbol "," *> expr)
  pure (foldl ExprOverlay first rest)

topForm :: Parser TopForm
topForm =
  choice
    [ contractDecl,
      nodeDecl,
      letBinding,
      importStmt
    ]

contractDecl :: Parser TopForm
contractDecl = do
  keyword "contract"
  n <- identifier
  _ <- symbol ";"
  pure (TopContract (ContractId n))

nodeDecl :: Parser TopForm
nodeDecl = do
  keyword "node"
  name <- identifier
  _ <- symbol ":"
  sig <- portSignature
  when (null sig) $
    fail "Wire requires every node to declare at least one port"
  _ <- symbol "="
  body <- expr
  _ <- symbol ";"
  pure (TopNode (NodeDecl name sig body))

letBinding :: Parser TopForm
letBinding = do
  keyword "let"
  name <- identifier
  _ <- symbol "="
  value <- expr
  _ <- symbol ";"
  pure (TopLet name value)

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
