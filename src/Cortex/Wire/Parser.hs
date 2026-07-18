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
  , parseWireFileWithInfo
  , parseWireExpr
  , GeneratedFamilyKind (..)
  , GeneratedFamilyChild (..)
  , GeneratedFamilyProvenance (..)
  , WireParseInfo (..)
  , ParseError
  , renderParseError
  )
where

import Control.Monad (foldM, when)
import Control.Monad.State.Strict (State)
import Control.Monad.State.Strict qualified as State
import Control.Monad.Trans.Class (lift)
import Data.Char (isAlpha, isAlphaNum, isSpace)
import Data.Char qualified as Char
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Text.Megaparsec
  ( MonadParsec (notFollowedBy, takeWhileP, try)
  , ParsecT
  , anySingle
  , choice
  , eof
  , errorBundlePretty
  , many
  , manyTill
  , optional
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

type Parser = ParsecT Void Text (State WireParseInfo)

data GeneratedFamilyKind
  = GeneratedFamilyFromMake
  | GeneratedFamilyFromMakeEach
  deriving stock (Eq, Show)

data GeneratedFamilyChild = GeneratedFamilyChild
  { generatedFamilyChildNode :: !Text
  , generatedFamilyChildLabel :: !Text
  , generatedFamilyChildValue :: !(Maybe CorePureExpr)
  }
  deriving stock (Eq, Show)

data GeneratedFamilyProvenance = GeneratedFamilyProvenance
  { generatedFamilyBinding :: !Text
  , generatedFamilyKind :: !GeneratedFamilyKind
  , generatedFamilyKindName :: !Text
  , generatedFamilyChildren :: ![GeneratedFamilyChild]
  }
  deriving stock (Eq, Show)

{- | Parser-side metadata that is not part of the public Wire AST.

Generated-family provenance records structural expansion decisions made by the parser. The
compiler trusts this metadata only on text entry points that call `parseWireFileWithInfo`;
hand-built `WireFile` values do not carry generated-form admission evidence.
-}
data WireParseInfo = WireParseInfo
  { wireParseCorePureInterpolationLine :: Maybe Int
  , wireParseGeneratedFamilies :: !(Map Text GeneratedFamilyProvenance)
  }
  deriving stock (Eq, Show)

emptyWireParseInfo :: WireParseInfo
emptyWireParseInfo =
  WireParseInfo
    { wireParseCorePureInterpolationLine = Nothing
    , wireParseGeneratedFamilies = Map.empty
    }

newtype ParseError = ParseError (MP.ParseErrorBundle Text Void)
  deriving stock (Show)

renderParseError :: ParseError -> Text
renderParseError (ParseError bundle) = T.pack (errorBundlePretty bundle)

------------------------------------------------------------------------
-- Entry points
------------------------------------------------------------------------

parseWireFile :: FilePath -> Text -> Either ParseError WireFile
parseWireFile name src =
  snd <$> parseWireFileWithInfo name src

parseWireFileWithInfo :: FilePath -> Text -> Either ParseError (WireParseInfo, WireFile)
parseWireFileWithInfo name src =
  case State.runState (MP.runParserT (spaceConsumer *> wireFile <* eof) name src) emptyWireParseInfo of
    (Left bundle, _) -> Left (ParseError bundle)
    (Right ok, info) -> Right (info, ok)

{- | Parse a single expression (no file-return resolution). Useful for
REPL-style consumption and tests.
-}
parseWireExpr :: FilePath -> Text -> Either ParseError Expr
parseWireExpr name src =
  case State.runState (MP.runParserT (spaceConsumer *> expr <* eof) name src) emptyWireParseInfo of
    (Left bundle, _) -> Left (ParseError bundle)
    (Right ok, _) -> Right ok

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
  , "form"
  , "if"
  , "inherit"
  , "import"
  , "in"
  , "kind"
  , "let"
  , "make"
  , "makeEach"
  , "node"
  , "null"
  , "pure"
  , "select"
  , "then"
  , "true"
  , "use"
  , "where"
  , "with"
  ]

-- | Identifier-continuation predicate.
identCont :: Char -> Bool
identCont c = isAlphaNum c || c == '_'

-- | Unqualified identifier (grammar §2.2).
identifier :: Parser Text
identifier = lexeme (try bareIdentifier)

bareIdentifier :: Parser Text
bareIdentifier = do
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
    bareIdent = bareIdentifier

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

data ParsedTopForm
  = ParsedTopContract !ContractDecl
  | ParsedTopNode !ParsedNodeDecl
  | ParsedTopKind !KindDecl
  | ParsedTopForm !FormDecl
  | ParsedTopLet !LetVisibility !Text !LetRhs
  | ParsedTopLetMake !LetVisibility !LetTarget !MakeApplication
  | ParsedTopLetApplication !LetVisibility !Text !FormApplication
  | ParsedTopUse !UseSpec
  | ParsedTopImport !ImportSpec
  deriving stock (Show)

data LetTarget = LetTarget
  { letTargetName :: !Text
  , letTargetIndexed :: !Bool
  }
  deriving stock (Eq, Show)

data ParsedNodeDecl
  = ParsedNodeBody !Text !(Maybe Record) ![PortDecl] !NodeBody
  | ParsedNodeKindApplication !Text !KindApplication
  deriving stock (Show)

data KindDecl = KindDecl
  { kindDeclName :: !Text
  , kindDeclParams :: ![KindParam]
  , kindDeclPortSig :: ![PortDecl]
  , kindDeclBody :: !NodeBody
  }
  deriving stock (Show)

data KindParam = KindParam
  { kindParamName :: !Text
  , kindParamClass :: !KindParamClass
  }
  deriving stock (Eq, Show)

data KindParamClass
  = KindParamPortLabel
  | KindParamContract
  | KindParamValue
  | KindParamExecutor
  deriving stock (Eq, Show)

data KindApplication = KindApplication
  { kindApplicationName :: !Text
  , kindApplicationArgs :: ![Expr]
  }
  deriving stock (Show)

data FormDecl = FormDecl
  { formDeclName :: !Text
  , formDeclParams :: ![FormParam]
  , formDeclItems :: ![FormItem]
  , formDeclResult :: !Expr
  }
  deriving stock (Show)

data FormParam = FormParam
  { formParamName :: !Text
  , formParamClass :: !FormParamClass
  }
  deriving stock (Eq, Show)

data FormParamClass
  = FormParamPortLabel
  | FormParamContract
  | FormParamValue
  | FormParamGraph
  | FormParamExecutor
  deriving stock (Eq, Show)

data FormItem
  = FormItemNode !ParsedNodeDecl
  | FormItemLet !LetTarget !FormLetRhs
  deriving stock (Show)

data FormLetRhs
  = FormLetRhsWire !Expr
  | FormLetRhsCorePure !CorePureExpr
  | FormLetRhsMake !MakeApplication
  | FormLetRhsApplication !FormApplication
  deriving stock (Show)

data FormApplication = FormApplication
  { formApplicationName :: !Text
  , formApplicationArgs :: ![Expr]
  }
  deriving stock (Show)

data MakeApplication = MakeApplication
  { makeApplicationInput :: !MakeInput
  , makeApplicationKindName :: !Text
  }
  deriving stock (Show)

data MakeInput
  = MakeInputCount !MakeCount
  | MakeInputEach !MakeEach
  deriving stock (Show)

data MakeCount
  = MakeCountLiteral !Scientific
  | MakeCountBinding !Text
  deriving stock (Show)

data MakeEach
  = MakeEachLiteral ![MakeItem]
  | MakeEachBinding !Text
  deriving stock (Show)

data MakeItem = MakeItem
  { makeItemLabel :: !Text
  , makeItemValue :: !CorePureExpr
  }
  deriving stock (Show)

data KindSubstitution = KindSubstitution
  { ksPortLabels :: !(Map Text Text)
  , ksContracts :: !(Map Text Text)
  , ksValues :: !(Map Text Expr)
  , ksCoreValues :: !(Map Text CorePureExpr)
  , ksExecutors :: !(Map Text Text)
  }
  deriving stock (Show)

emptyKindSubstitution :: KindSubstitution
emptyKindSubstitution =
  KindSubstitution
    { ksPortLabels = Map.empty
    , ksContracts = Map.empty
    , ksValues = Map.empty
    , ksCoreValues = Map.empty
    , ksExecutors = Map.empty
    }

-- | Top-level expression. Overlay binds tighter than connect/star.
expr :: Parser Expr
expr =
  exprConnectLevel

exprConnectLevel :: Parser Expr
exprConnectLevel = do
  first <- exprOverlayLevel
  rest <- many topologyStep
  pure (foldl' (flip ($)) first rest)
  where
    topologyStep = do
      op <- (ExprConnect <$ symbol "=>") <|> (ExprStar <$ symbol "*")
      rhs <- exprOverlayLevel
      pure (`op` rhs)

exprOverlayLevel :: Parser Expr
exprOverlayLevel = do
  first <- exprSelectLevel
  rest <- many (symbol "<>" *> exprSelectLevel)
  pure (foldl' ExprOverlay first rest)

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
    [ ExprExecutor <$> executorRef
    , -- Immediate @name[index]@ is graph-family projection; spaced @name [index]@ is CorePure.
      familyProjectionExpr
    , try constructorExpr
    , ExprRecord <$> recordExpr
    , listExpr
    , stringLitExpr
    , ExprLit . LitBool <$> boolLiteral
    , ExprLit . LitNumber <$> numberLiteral
    , parenOrUnit
    , ExprIdent <$> qualifiedIdent
    ]

familyProjectionExpr :: Parser Expr
familyProjectionExpr = lexeme $ do
  familyName <- try (bareIdentifier <* MP.lookAhead (char '['))
  _ <- char '['
  spaceConsumer
  indexValue <- nonNegativeIntLiteral "indexed family projection"
  _ <- symbol "]"
  pure (ExprFamilyProjection familyName indexValue)

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
  (base, spacedAfterBase) <- withTrailingSpace corePureAtom
  go base spacedAfterBase
  where
    go base spacedBeforeNextToken = do
      nextSuffix <- optional . try . withTrailingSpace $ corePureSuffix spacedBeforeNextToken
      case nextSuffix of
        Nothing -> pure base
        Just (suffix, spacedAfterSuffix) ->
          go (suffix base) spacedAfterSuffix

    corePureSuffix spacedBeforeToken =
      fieldSuffix <|> indexSuffix
      where
        fieldSuffix = do
          _ <- symbol "."
          fieldName <- identifier
          pure (`CorePureFieldAccess` fieldName)

        indexSuffix
          | spacedBeforeToken = fail "index access requires an immediate ["
          | otherwise = do
              _ <- symbol "["
              indexExpr <- corePureExpr
              _ <- symbol "]"
              pure (`CorePureIndex` indexExpr)

withTrailingSpace :: Parser a -> Parser (a, Bool)
withTrailingSpace parser = do
  before <- MP.getInput
  value <- parser
  after <- MP.getInput
  let consumed = T.take (T.length before - T.length after) before
  pure (value, textEndsWithSpace consumed)

textEndsWithSpace :: Text -> Bool
textEndsWithSpace text =
  case T.unsnoc text of
    Nothing -> False
    Just (_, lastChar) ->
      isSpace lastChar || T.isSuffixOf "*/" (T.dropWhileEnd isSpace text)

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
  startLine <- currentLineNumber
  raw <- T.pack <$> manyTill singleRawChar (char '"')
  desugarStringSegments FormSingle startLine raw
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
  startLine <- currentLineNumber
  raw <- T.pack <$> manyTill anySingle (try (string "''"))
  desugarStringSegments FormMulti startLine (stripIndentedString raw)

data StringSegment = StringText !Text | StringInterpolation !CorePureExpr

desugarStringSegments :: StringForm -> Int -> Text -> Parser CorePureExpr
desugarStringSegments form startLine raw =
  buildStringExpr <$> go startLine raw []
  where
    go line input acc
      | T.null input = pure (reverse acc)
      | "${" `T.isPrefixOf` input = do
          markCorePureInterpolation line
          (exprValue, rest) <- parseInterpolation (T.drop 2 input)
          go line rest (StringInterpolation exprValue : acc)
      | form == FormSingle && "\\${" `T.isPrefixOf` input =
          go line (T.drop 3 input) (StringText "${" : acc)
      | form == FormSingle && "\\" `T.isPrefixOf` input = do
          (escaped, rest) <- either fail pure (singleEscaped input)
          go (advanceLine line escaped) rest (StringText escaped : acc)
      | form == FormMulti && "''${" `T.isPrefixOf` input =
          go line (T.drop 4 input) (StringText "${" : acc)
      | form == FormMulti && "''' " `T.isPrefixOf` input =
          go line (T.drop 3 input) (StringText "'' " : acc)
      | form == FormMulti && "''\\n" `T.isPrefixOf` input =
          go (line + 1) (T.drop 4 input) (StringText "\n" : acc)
      | form == FormMulti && "''\\t" `T.isPrefixOf` input =
          go line (T.drop 4 input) (StringText "\t" : acc)
      | form == FormMulti && "''\\r" `T.isPrefixOf` input =
          go line (T.drop 4 input) (StringText "\r" : acc)
      | otherwise =
          let (prefix, rest) = breakOnNextSpecial form input
           in go (advanceLine line prefix) rest (StringText prefix : acc)

    singleEscaped input =
      case T.unpack (T.take 2 input) of
        ['\\', 'n'] -> Right ("\n", T.drop 2 input)
        ['\\', 't'] -> Right ("\t", T.drop 2 input)
        ['\\', 'r'] -> Right ("\r", T.drop 2 input)
        ['\\', '"'] -> Right ("\"", T.drop 2 input)
        ['\\', '\\'] -> Right ("\\", T.drop 2 input)
        ['\\', c] -> Left ("unknown escape: \\" <> [c])
        _ -> Left "unterminated escape"

    advanceLine line text = line + T.count "\n" text

currentLineNumber :: Parser Int
currentLineNumber =
  MP.unPos . MP.sourceLine <$> MP.getSourcePos

markCorePureInterpolation :: Int -> Parser ()
markCorePureInterpolation line =
  lift . State.modify' $ \info ->
    info
      { wireParseCorePureInterpolationLine =
          case wireParseCorePureInterpolationLine info of
            Nothing -> Just line
            Just existingLine -> Just existingLine
      }

parseInterpolation :: Text -> Parser (CorePureExpr, Text)
parseInterpolation input =
  do
    info <- lift State.get
    case State.runState (MP.runParserT interpolationParser "string interpolation" input) info of
      (Left bundle, _) -> fail (errorBundlePretty bundle)
      (Right value, info') -> do
        lift (State.put info')
        pure value
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
  source <- optional (symbol "(" *> corePureExpr <* symbol ")")
  names <- some identifier
  pure
    [ CorePureField
        (name :| [])
        (maybe (CorePureIdent name) (`CorePureFieldAccess` name) source)
    | name <- names
    ]

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
  contractId <- contractRef
  rejectLegacyPortSemicolon
  pure (PortInputDecl lbl contractId)

outputPort :: Parser PortDecl
outputPort = do
  _ <- symbol "->"
  firstVariant <- outputVariant
  -- Look ahead for a sum-group separator.
  moreVariants <- many (symbol "|" *> outputVariant)
  rejectLegacyPortSemicolon
  case moreVariants of
    [] ->
      let SumVariant lbl c = firstVariant
       in pure (PortOutputDecl lbl c)
    _ -> do
      let variants = firstVariant :| moreVariants
      pure (PortOutputSumDecl variants)

rejectLegacyPortSemicolon :: Parser ()
rejectLegacyPortSemicolon = do
  legacy <- optional (MP.lookAhead (symbol ";"))
  when (isJust legacy) $
    fail "semicolon-delimited port declarations were removed; arrows and = delimit node clauses"

outputVariant :: Parser SumVariant
outputVariant = do
  lbl <- requiredLabel
  SumVariant lbl <$> contractRef

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
  (scope, expandedForms) <- either fail pure (expandStructuralForms forms)
  lift . State.modify' $ \info ->
    info
      { wireParseGeneratedFamilies =
          wireParseGeneratedFamilies info <> scope.esGeneratedFamilies
      }
  ret' <- either fail pure (traverse (resolveFamilyProjections scope.esIndexedFamilies) ret)
  pure (WireFile expandedForms ret')

fileReturnExpr :: Parser Expr
fileReturnExpr = expr

topForm :: Parser ParsedTopForm
topForm =
  choice
    [ contractDecl
    , useStmt
    , kindDecl
    , formDecl
    , nodeDecl
    , letBinding
    , importStmt
    ]

contractDecl :: Parser ParsedTopForm
contractDecl = do
  keyword "contract"
  n <- identifier
  fields <- optional contractRecordFields
  _ <- symbol ";"
  pure
    ( ParsedTopContract
        ContractDecl
          { contractDeclId = ContractId n
          , contractDeclRecordFields = fields
          }
    )

contractRecordFields :: Parser [(Text, ContractId)]
contractRecordFields = do
  _ <- symbol "{"
  fields <- many contractRecordField
  _ <- symbol "}"
  pure fields

contractRecordField :: Parser (Text, ContractId)
contractRecordField = do
  fieldName <- identifier
  _ <- symbol ":"
  fieldContract <- contractRef
  _ <- symbol ";"
  pure (fieldName, fieldContract)

contractRef :: Parser ContractId
contractRef =
  try boundedIndexedContract <|> (ContractId <$> identifier)

boundedIndexedContract :: Parser ContractId
boundedIndexedContract = do
  _ <- symbol "["
  elementContract <- identifier
  _ <- symbol ";"
  count <- nonNegativeIntLiteral "bounded indexed contract"
  _ <- symbol "]"
  pure (ContractId (boundedIndexedContractName elementContract (fromIntegral count)))

nonNegativeIntLiteral :: String -> Parser Int
nonNegativeIntLiteral context = lexeme $ do
  digits <- some digitChar
  case digits of
    '0' : _ : _ ->
      fail (context <> " index must not contain leading zeros")
    _ ->
      pure ()
  case reads digits :: [(Integer, String)] of
    [(integerValue, "")]
      | integerValue <= toInteger (maxBound :: Int) ->
          pure (fromInteger integerValue)
    _ ->
      fail (context <> " index is too large")

useStmt :: Parser ParsedTopForm
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
  pure (ParsedTopUse (UseSpec namespace items))

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

kindDecl :: Parser ParsedTopForm
kindDecl = do
  keyword "kind"
  name <- identifier
  _ <- symbol "("
  params <- kindParam `sepEndBy` symbol ","
  _ <- symbol ")"
  _ <- symbol "="
  inputs <- many (try inputPort)
  (outputs, mkBody) <- nodeImplementationBody
  whereExpr <- optional (try whereClause)
  pure (ParsedTopKind (KindDecl name params (inputs <> outputs) (mkBody whereExpr)))

kindParam :: Parser KindParam
kindParam = do
  name <- identifier
  _ <- symbol ":"
  KindParam name <$> parseKindParamClass

parseKindParamClass :: Parser KindParamClass
parseKindParamClass = do
  className <- identifier
  case className of
    "PortLabel" -> pure KindParamPortLabel
    "Contract" -> pure KindParamContract
    "Value" -> pure KindParamValue
    "Executor" -> pure KindParamExecutor
    "ConfiguredExecutor" -> fail "ConfiguredExecutor was removed; use Executor"
    other -> fail ("unknown kind parameter class: " <> T.unpack other)

formDecl :: Parser ParsedTopForm
formDecl = do
  keyword "form"
  name <- identifier
  _ <- symbol "("
  params <- formParam `sepEndBy` symbol ","
  _ <- symbol ")"
  _ <- symbol "="
  _ <- symbol "{"
  items <- many formItem
  result <- expr
  _ <- symbol ";"
  _ <- symbol "}"
  _ <- symbol ";"
  pure (ParsedTopForm (FormDecl name params items result))

formParam :: Parser FormParam
formParam = do
  name <- identifier
  _ <- symbol ":"
  FormParam name <$> parseFormParamClass

parseFormParamClass :: Parser FormParamClass
parseFormParamClass = do
  className <- identifier
  case className of
    "PortLabel" -> pure FormParamPortLabel
    "Contract" -> pure FormParamContract
    "Value" -> pure FormParamValue
    "Graph" -> pure FormParamGraph
    "Executor" -> pure FormParamExecutor
    "ConfiguredExecutor" -> fail "ConfiguredExecutor was removed; use Executor"
    other -> fail ("unknown form parameter class: " <> T.unpack other)

formItem :: Parser FormItem
formItem =
  try formNodeItem <|> formLetItem

formNodeItem :: Parser FormItem
formNodeItem = do
  keyword "node"
  FormItemNode <$> nodeDeclAfterKeyword

formLetItem :: Parser FormItem
formLetItem = do
  keyword "let"
  target <- letTarget
  _ <- symbol "="
  FormItemLet target <$> formLetRhs target

letTarget :: Parser LetTarget
letTarget = do
  name <- identifier
  indexed <- optional (try (symbol "[" *> symbol "]"))
  pure
    LetTarget
      { letTargetName = name
      , letTargetIndexed = isJust indexed
      }

formLetRhs :: LetTarget -> Parser FormLetRhs
formLetRhs target
  | target.letTargetIndexed =
      try (FormLetRhsMake <$> makeApplication <* symbol ";")
        <|> fail indexedLetRequiresMakeMessage
  | otherwise =
      try (FormLetRhsMake <$> (makeApplication <|> makeEachApplication) <* symbol ";")
        <|> try (FormLetRhsApplication <$> formApplication <* symbol ";")
        <|> try (FormLetRhsWire <$> expr <* symbol ";")
        <|> (FormLetRhsCorePure <$> corePureExpr <* symbol ";")

nodeDecl :: Parser ParsedTopForm
nodeDecl = do
  keyword "node"
  ParsedTopNode <$> nodeDeclAfterKeyword

nodeDeclAfterKeyword :: Parser ParsedNodeDecl
nodeDeclAfterKeyword = do
  name <- identifier
  try (kindNodeDecl name) <|> ordinaryNodeDecl name

kindNodeDecl :: Text -> Parser ParsedNodeDecl
kindNodeDecl name = do
  _ <- symbol "="
  application <- kindApplication
  _ <- symbol ";"
  pure (ParsedNodeKindApplication name application)

kindApplication :: Parser KindApplication
kindApplication = do
  name <- identifier
  _ <- symbol "("
  args <- expr `sepEndBy` symbol ","
  _ <- symbol ")"
  pure (KindApplication name args)

ordinaryNodeDecl :: Text -> Parser ParsedNodeDecl
ordinaryNodeDecl name = do
  metadata <- optional (keyword "with" *> recordExpr)
  inputs <- many (try inputPort)
  (outputs, mkBody) <- nodeImplementationBody
  whereExpr <- optional (try whereClause)
  pure (ParsedNodeBody name metadata (inputs <> outputs) (mkBody whereExpr))

nodeImplementationBody :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
nodeImplementationBody =
  choice
    [ try pureImplementation
    , try singleOutputExecutorShorthand
    , executorImplementation
    ]

pureImplementation :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
pureImplementation = try pureSumImplementation <|> pureProductImplementation

pureProductImplementation :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
pureProductImplementation = do
  outputEquations <-
    requireNonEmpty "pure node requires at least one output equation" =<< some (try pureOutputEquation)
  let outputs = fmap pureOutputEquationPortDecl (NE.toList outputEquations)
  pure
    ( outputs
    , \whereExpr ->
        NodeBodyPure
          NodePureBody
            { nodePureBodyWhere = whereExpr
            , nodePureBodyResult = NodePureProduct outputEquations
            }
    )

pureSumImplementation :: Parser ([PortDecl], Maybe CorePureExpr -> NodeBody)
pureSumImplementation = do
  _ <- symbol "->"
  firstVariant <- outputVariant
  remainingVariants <- some (symbol "|" *> outputVariant)
  _ <- symbol "="
  bodyExpr <- pureOutputExpression
  _ <- symbol ";"
  let variants = firstVariant :| remainingVariants
  pure
    ( [PortOutputSumDecl variants]
    , \whereExpr ->
        NodeBodyPure
          NodePureBody
            { nodePureBodyWhere = whereExpr
            , nodePureBodyResult = NodePureSum variants bodyExpr
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
  outputs <- many (try outputPort)
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
pureOutputExpression =
  removedPureWrapper <|> corePureExpr
  where
    -- Do not wrap this branch in try: pure is reserved, so once it is consumed
    -- the only useful outcome is the targeted legacy-wrapper diagnostic.
    removedPureWrapper = do
      keyword "pure"
      _ <- symbol "("
      fail "pure (...) output wrappers were removed; write the CorePure expression directly"

executorCall :: Parser ExecutorCall
executorCall = inlineExecutorCall
  where
    inlineExecutorCall = do
      executor <- executorRef
      when (renderQName executor == "pure") $
        fail "CorePure output equations are written directly; @pure is not an executor"
      rejectLegacyCallParens
      inputArg <- optional corePureExpr
      legacyTrailing <- optional (try (MP.lookAhead (symbol "(")))
      when (isJust legacyTrailing) $
        fail "legacy executor config/input calls were removed; pass one explicit record argument"
      pure (ExecutorCallInline executor inputArg)

    rejectLegacyCallParens = do
      legacy <- optional (MP.lookAhead (symbol "("))
      when (isJust legacy) $
        fail "parenthesized executor calls were removed; pass zero or one bare argument"

pureOutputEquationPortDecl :: PureOutputEquation -> PortDecl
pureOutputEquationPortDecl outputEquation =
  PortOutputDecl
    (pureOutputEquationLabel outputEquation)
    (pureOutputEquationContract outputEquation)

letBinding :: Parser ParsedTopForm
letBinding = do
  visibility <- (LetExported <$ keyword "export") <|> pure LetPrivate
  keyword "let"
  target <- letTarget
  _ <- symbol "="
  parsedLetRhs visibility target

parsedLetRhs :: LetVisibility -> LetTarget -> Parser ParsedTopForm
parsedLetRhs visibility target
  | target.letTargetIndexed =
      try (ParsedTopLetMake visibility target <$> makeApplication <* symbol ";")
        <|> fail indexedLetRequiresMakeMessage
  | otherwise =
      try (ParsedTopLetMake visibility target <$> (makeApplication <|> makeEachApplication) <* symbol ";")
        <|> try (ParsedTopLetApplication visibility target.letTargetName <$> formApplication <* symbol ";")
        <|> try (ParsedTopLet visibility target.letTargetName . LetRhsWire <$> expr <* symbol ";")
        <|> (ParsedTopLet visibility target.letTargetName . LetRhsCorePure <$> corePureExpr <* symbol ";")

indexedLetRequiresMakeMessage :: String
indexedLetRequiresMakeMessage =
  "indexed let bindings require a make(count, kind) right-hand side"

makeApplication :: Parser MakeApplication
makeApplication = do
  keyword "make"
  _ <- symbol "("
  countValue <- makeCount
  _ <- symbol ","
  kindName <- identifier
  _ <- optional (symbol ",")
  _ <- symbol ")"
  pure
    MakeApplication
      { makeApplicationInput = MakeInputCount countValue
      , makeApplicationKindName = kindName
      }

makeEachApplication :: Parser MakeApplication
makeEachApplication = do
  keyword "makeEach"
  _ <- symbol "("
  eachValue <- makeEach
  _ <- symbol ","
  kindName <- identifier
  _ <- optional (symbol ",")
  _ <- symbol ")"
  pure
    MakeApplication
      { makeApplicationInput = MakeInputEach eachValue
      , makeApplicationKindName = kindName
      }

makeCount :: Parser MakeCount
makeCount =
  (MakeCountLiteral <$> numberLiteral)
    <|> (MakeCountBinding <$> identifier)

makeEach :: Parser MakeEach
makeEach =
  (MakeEachLiteral <$> (staticMakeItems =<< corePureList))
    <|> (MakeEachBinding <$> identifier)

formApplication :: Parser FormApplication
formApplication = do
  name <- identifier
  _ <- symbol "("
  args <- expr `sepEndBy` symbol ","
  _ <- symbol ")"
  pure (FormApplication name args)

importStmt :: Parser ParsedTopForm
importStmt = do
  keyword "import"
  spec <- namedForm <|> explicitForm
  _ <- symbol ";"
  pure (ParsedTopImport spec)
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

expandStructuralForms :: [ParsedTopForm] -> Either String (ExpansionScope, [TopForm])
expandStructuralForms forms = do
  (scope, reversedForms) <- foldM step (emptyExpansionScope, []) forms
  Right (scope, reverse reversedForms)
  where
    step (scope, acc) = \case
      ParsedTopContract contractDeclValue ->
        Right (scope, TopContract contractDeclValue : acc)
      ParsedTopUse useSpec ->
        Right (scope, TopUse useSpec : acc)
      ParsedTopLet visibility name rhs -> do
        resolved <- resolveLetRhsFamilyProjections scope.esIndexedFamilies rhs
        Right (recordStaticMakeData name resolved scope, TopLet visibility name resolved : acc)
      ParsedTopLetMake visibility target application -> do
        expanded <- expandMakeBinding scope visibility target.letTargetName application
        let scopeWithFamily = recordGeneratedFamily expanded.embGeneratedFamily scope
            scope' =
              if target.letTargetIndexed
                then
                  recordIndexedFamily
                    target.letTargetName
                    expanded.embGeneratedChildNames
                    scopeWithFamily
                else scopeWithFamily
        Right (scope', reverse expanded.embForms <> acc)
      ParsedTopLetApplication visibility name application -> do
        application' <- resolveFormApplicationFamilyProjections scope.esIndexedFamilies application
        case Map.lookup application'.formApplicationName scope.esForms of
          Just formDeclValue -> do
            expanded <- expandFormBinding scope visibility name formDeclValue application'
            let scopeWithFamilies =
                  scope
                    { esGeneratedFamilies =
                        expanded.efbGeneratedFamilies <> scope.esGeneratedFamilies
                    }
            Right (scopeWithFamilies, reverse expanded.efbForms <> acc)
          Nothing -> do
            rhs <- formApplicationToCorePureLetRhs application'
            Right (scope, TopLet visibility name rhs : acc)
      ParsedTopImport importSpec ->
        Right (scope, TopImport importSpec : acc)
      ParsedTopKind kindDeclValue -> do
        validateKindDecl kindDeclValue
        when (Map.member kindDeclValue.kindDeclName scope.esKinds) $
          Left ("kind " <> T.unpack kindDeclValue.kindDeclName <> " was declared more than once")
        Right (scope {esKinds = Map.insert kindDeclValue.kindDeclName kindDeclValue scope.esKinds}, acc)
      ParsedTopForm formDeclValue -> do
        validateFormDecl formDeclValue
        when (Map.member formDeclValue.formDeclName scope.esForms) $
          Left ("form " <> T.unpack formDeclValue.formDeclName <> " was declared more than once")
        Right (scope {esForms = Map.insert formDeclValue.formDeclName formDeclValue scope.esForms}, acc)
      ParsedTopNode parsedNode -> do
        nodeDeclValue <- expandParsedNode scope.esKinds parsedNode
        Right (scope, TopNode nodeDeclValue : acc)

recordStaticMakeData :: Text -> LetRhs -> ExpansionScope -> ExpansionScope
recordStaticMakeData name rhs scope =
  case rhs of
    LetRhsWire (ExprLit (LitNumber countValue)) ->
      scope {esMakeCounts = Map.insert name countValue scope.esMakeCounts}
    LetRhsCorePure (CorePureLit (CorePureNumber countValue)) ->
      scope {esMakeCounts = Map.insert name countValue scope.esMakeCounts}
    LetRhsWire (ExprList items)
      | Just makeItems <- staticMakeItemsFromExprs items ->
          scope {esMakeItems = Map.insert name makeItems scope.esMakeItems}
    LetRhsCorePure (CorePureList items)
      | Just makeItems <- staticMakeItemsFromCorePure items ->
          scope {esMakeItems = Map.insert name makeItems scope.esMakeItems}
    _ ->
      scope

data ExpansionScope = ExpansionScope
  { esKinds :: !(Map Text KindDecl)
  , esForms :: !(Map Text FormDecl)
  , -- Structural expansion happens during one top-form fold, so only preceding closed static lets
    -- are visible as make counts or makeEach item lists.
    esMakeCounts :: !(Map Text Scientific)
  , esMakeItems :: !(Map Text [MakeItem])
  , esIndexedFamilies :: !(Map Text [Text])
  , esGeneratedFamilies :: !(Map Text GeneratedFamilyProvenance)
  }
  deriving stock (Show)

emptyExpansionScope :: ExpansionScope
emptyExpansionScope =
  ExpansionScope
    { esKinds = Map.empty
    , esForms = Map.empty
    , esMakeCounts = Map.empty
    , esMakeItems = Map.empty
    , esIndexedFamilies = Map.empty
    , esGeneratedFamilies = Map.empty
    }

data ExpandedMakeBinding = ExpandedMakeBinding
  { embForms :: ![TopForm]
  , embGeneratedChildNames :: ![Text]
  , embGeneratedFamily :: !GeneratedFamilyProvenance
  }
  deriving stock (Show)

data GeneratedMakeChild = GeneratedMakeChild
  { gmcName :: !Text
  , gmcLabel :: !Text
  , gmcValue :: !(Maybe CorePureExpr)
  , gmcKindArguments :: ![Expr]
  }
  deriving stock (Show)

expandMakeBinding
  :: ExpansionScope -> LetVisibility -> Text -> MakeApplication -> Either String ExpandedMakeBinding
expandMakeBinding scope visibility bindingName application = do
  kindDeclValue <-
    maybe
      ( Left
          ( "make("
              <> T.unpack bindingName
              <> ") references unknown kind "
              <> T.unpack application.makeApplicationKindName
          )
      )
      Right
      (Map.lookup application.makeApplicationKindName scope.esKinds)
  generated <- makeGeneratedChildren scope bindingName application kindDeclValue
  let childNames = fmap (.gmcName) generated
      familyKind =
        case application.makeApplicationInput of
          MakeInputCount {} -> GeneratedFamilyFromMake
          MakeInputEach {} -> GeneratedFamilyFromMakeEach
      generatedFamily =
        GeneratedFamilyProvenance
          { generatedFamilyBinding = bindingName
          , generatedFamilyKind = familyKind
          , generatedFamilyKindName = application.makeApplicationKindName
          , generatedFamilyChildren =
              [ GeneratedFamilyChild
                  { generatedFamilyChildNode = child.gmcName
                  , generatedFamilyChildLabel = child.gmcLabel
                  , generatedFamilyChildValue = child.gmcValue
                  }
              | child <- generated
              ]
          }
      childNode child = do
        nodeDeclValue <-
          expandParsedNode
            scope.esKinds
            ( ParsedNodeKindApplication
                child.gmcName
                KindApplication
                  { kindApplicationName = application.makeApplicationKindName
                  , kindApplicationArgs = child.gmcKindArguments
                  }
            )
        Right nodeDeclValue
      resultExpr = overlayGeneratedChildren childNames
  nodes <- traverse childNode generated
  Right
    ExpandedMakeBinding
      { embForms = fmap TopNode nodes <> [TopLet visibility bindingName (LetRhsWire resultExpr)]
      , embGeneratedChildNames = childNames
      , embGeneratedFamily = generatedFamily
      }

recordIndexedFamily :: Text -> [Text] -> ExpansionScope -> ExpansionScope
recordIndexedFamily familyName childNames scope =
  scope {esIndexedFamilies = Map.insert familyName childNames scope.esIndexedFamilies}

recordGeneratedFamily :: GeneratedFamilyProvenance -> ExpansionScope -> ExpansionScope
recordGeneratedFamily family scope =
  scope
    { esGeneratedFamilies =
        Map.insert family.generatedFamilyBinding family scope.esGeneratedFamilies
    }

resolveLetRhsFamilyProjections :: Map Text [Text] -> LetRhs -> Either String LetRhs
resolveLetRhsFamilyProjections families = \case
  LetRhsWire exprValue -> do
    resolved <- resolveFamilyProjectionsWithStatus families exprValue
    -- The surface form @name[index]@ is both a graph-family projection and CorePure index syntax.
    -- Unknown families in value-compatible lets must round back into CorePure instead of becoming
    -- graph lets that fail later during lowering.
    -- If the whole expression is not CorePure-compatible, the unresolved projection stays in graph
    -- form so graph lowering can report it with graph-domain context.
    if resolved.rfrContainsProjection
      then case exprToCorePureExpr resolved.rfrExpr of
        Right coreExpr ->
          Right (LetRhsCorePure coreExpr)
        Left _ ->
          Right (LetRhsWire resolved.rfrExpr)
      else Right (LetRhsWire resolved.rfrExpr)
  rhs@LetRhsCorePure {} ->
    Right rhs

resolveFormApplicationFamilyProjections
  :: Map Text [Text] -> FormApplication -> Either String FormApplication
resolveFormApplicationFamilyProjections families application =
  (\args -> application {formApplicationArgs = args})
    <$> traverse (resolveFamilyProjections families) application.formApplicationArgs

resolveFamilyProjections :: Map Text [Text] -> Expr -> Either String Expr
resolveFamilyProjections families exprValue =
  (.rfrExpr) <$> resolveFamilyProjectionsWithStatus families exprValue

data ResolvedFamilyExpr = ResolvedFamilyExpr
  { rfrExpr :: !Expr
  , rfrContainsProjection :: !Bool
  }
  deriving stock (Eq, Show)

data ResolvedFamilyRecord = ResolvedFamilyRecord
  { rfrRecord :: !Record
  , rfrRecordContainsProjection :: !Bool
  }
  deriving stock (Eq, Show)

resolvedExpr :: Expr -> ResolvedFamilyExpr
resolvedExpr exprValue =
  ResolvedFamilyExpr
    { rfrExpr = exprValue
    , rfrContainsProjection = False
    }

unresolvedProjectionExpr :: Text -> Int -> ResolvedFamilyExpr
unresolvedProjectionExpr familyName indexValue =
  ResolvedFamilyExpr
    { rfrExpr = ExprFamilyProjection familyName indexValue
    , rfrContainsProjection = True
    }

mapResolvedRecord :: (Record -> Expr) -> ResolvedFamilyRecord -> ResolvedFamilyExpr
mapResolvedRecord f resolved =
  ResolvedFamilyExpr
    { rfrExpr = f resolved.rfrRecord
    , rfrContainsProjection = resolved.rfrRecordContainsProjection
    }

combineResolved2
  :: (Expr -> Expr -> Expr) -> ResolvedFamilyExpr -> ResolvedFamilyExpr -> ResolvedFamilyExpr
combineResolved2 f lhs rhs =
  ResolvedFamilyExpr
    { rfrExpr = f lhs.rfrExpr rhs.rfrExpr
    , rfrContainsProjection = lhs.rfrContainsProjection || rhs.rfrContainsProjection
    }

combineResolvedList :: ([Expr] -> Expr) -> [ResolvedFamilyExpr] -> ResolvedFamilyExpr
combineResolvedList f resolvedItems =
  ResolvedFamilyExpr
    { rfrExpr = f (fmap (.rfrExpr) resolvedItems)
    , rfrContainsProjection = any (.rfrContainsProjection) resolvedItems
    }

resolveFamilyProjectionsWithStatus :: Map Text [Text] -> Expr -> Either String ResolvedFamilyExpr
resolveFamilyProjectionsWithStatus families = go
  where
    go = \case
      ExprOverlay lhs rhs ->
        combineResolved2 ExprOverlay <$> go lhs <*> go rhs
      ExprConnect lhs rhs ->
        combineResolved2 ExprConnect <$> go lhs <*> go rhs
      ExprStar lhs rhs ->
        combineResolved2 ExprStar <$> go lhs <*> go rhs
      ExprMerge lhs rhs ->
        combineResolved2 ExprMerge <$> go lhs <*> go rhs
      ExprConcat lhs rhs ->
        combineResolved2 ExprConcat <$> go lhs <*> go rhs
      ExprSelect base arms ->
        combineSelect <$> go base <*> traverse resolveArm arms
      ExprFamilyProjection familyName indexValue ->
        resolveProjection familyName indexValue
      ExprExecutor executor ->
        Right (resolvedExpr (ExprExecutor executor))
      ExprConstructor name recordValue ->
        mapResolvedRecord (ExprConstructor name) <$> resolveRecord recordValue
      ExprRecord recordValue ->
        mapResolvedRecord ExprRecord <$> resolveRecord recordValue
      ExprList items ->
        combineResolvedList ExprList <$> traverse go items
      ExprLit literalValue ->
        Right (resolvedExpr (ExprLit literalValue))
      ExprIdent name ->
        Right (resolvedExpr (ExprIdent name))

    resolveArm (SelectArm key armExpr) = do
      resolvedArm <- go armExpr
      Right (SelectArm key resolvedArm.rfrExpr, resolvedArm.rfrContainsProjection)

    combineSelect base arms =
      ResolvedFamilyExpr
        { rfrExpr = ExprSelect base.rfrExpr (fmap fst arms)
        , rfrContainsProjection =
            base.rfrContainsProjection || any snd arms
        }

    resolveRecord (Record fields) = do
      resolvedFields <- traverse resolveField fields
      Right
        ResolvedFamilyRecord
          { rfrRecord = Record (fmap fst resolvedFields)
          , rfrRecordContainsProjection = any snd resolvedFields
          }

    resolveField (Field path value) = do
      resolvedValue <- go value
      Right (Field path resolvedValue.rfrExpr, resolvedValue.rfrContainsProjection)

    resolveProjection familyName indexValue =
      case Map.lookup familyName families of
        Nothing ->
          Right (unresolvedProjectionExpr familyName indexValue)
        Just childNames
          | Just childName <- familyChildAt indexValue childNames ->
              Right (resolvedExpr (ExprIdent (QName (childName :| []))))
          | otherwise ->
              Left
                ( "indexed family projection "
                    <> T.unpack familyName
                    <> "["
                    <> show indexValue
                    <> "] is out of range for family of size "
                    <> show (length childNames)
                )

familyChildAt :: Int -> [Text] -> Maybe Text
familyChildAt indexValue childNames
  | indexValue < 0 = Nothing
  | otherwise = listToMaybe (drop indexValue childNames)

makeGeneratedChildren
  :: ExpansionScope
  -> Text
  -> MakeApplication
  -> KindDecl
  -> Either String [GeneratedMakeChild]
makeGeneratedChildren scope bindingName application kindDeclValue =
  case application.makeApplicationInput of
    MakeInputCount countInput -> do
      _ <- makeKindLabelParam kindDeclValue
      count <- staticMakeCount scope bindingName countInput
      Right
        [ let label = T.pack (show idx)
              name = bindingName <> "_" <> label
           in GeneratedMakeChild
                { gmcName = name
                , gmcLabel = label
                , gmcValue = Nothing
                , gmcKindArguments = [ExprIdent (QName (name :| []))]
                }
        | idx <- [0 .. count - 1]
        ]
    MakeInputEach eachInput -> do
      (_labelParam, maybeValueParam) <- makeEachKindParams kindDeclValue
      items <- staticMakeEachItems scope bindingName eachInput
      let child item = do
            let name = bindingName <> "_" <> item.makeItemLabel
            sourceValue <-
              traverse
                ( \_ ->
                    if corePureLeanStaticValueCompatible item.makeItemValue
                      then Right item.makeItemValue
                      else
                        Left
                          ( "makeEach Value item for "
                              <> T.unpack bindingName
                              <> " must be a source static value: string, boolean, natural number, list, or flat record"
                          )
                )
                maybeValueParam
            valueArg <- traverse (const (corePureExprToExpr item.makeItemValue)) maybeValueParam
            Right
              GeneratedMakeChild
                { gmcName = name
                , gmcLabel = item.makeItemLabel
                , gmcValue = sourceValue
                , gmcKindArguments = ExprIdent (QName (name :| [])) : foldMap pure valueArg
                }
      traverse child items

makeKindLabelParam :: KindDecl -> Either String KindParam
makeKindLabelParam kindDeclValue =
  case kindDeclValue.kindDeclParams of
    [param]
      | param.kindParamClass == KindParamPortLabel ->
          Right param
    _ ->
      Left
        ( "kind "
            <> T.unpack kindDeclValue.kindDeclName
            <> " used with make(...) must declare exactly one PortLabel parameter"
        )

makeEachKindParams :: KindDecl -> Either String (KindParam, Maybe KindParam)
makeEachKindParams kindDeclValue =
  case kindDeclValue.kindDeclParams of
    [labelParam]
      | labelParam.kindParamClass == KindParamPortLabel ->
          Right (labelParam, Nothing)
    [labelParam, valueParam]
      | labelParam.kindParamClass == KindParamPortLabel
      , valueParam.kindParamClass == KindParamValue ->
          Right (labelParam, Just valueParam)
    _ ->
      Left
        ( "kind "
            <> T.unpack kindDeclValue.kindDeclName
            <> " used with makeEach(...) must declare PortLabel or PortLabel, Value parameters"
        )

staticMakeCount :: ExpansionScope -> Text -> MakeCount -> Either String Int
staticMakeCount scope bindingName = \case
  MakeCountLiteral countValue ->
    staticMakeScientificCount bindingName countValue
  MakeCountBinding countName ->
    case Map.lookup countName scope.esMakeCounts of
      Just countValue ->
        staticMakeScientificCount bindingName countValue
      Nothing ->
        Left
          ( "make count for "
              <> T.unpack bindingName
              <> " references "
              <> T.unpack countName
              <> ", but make counts must be integer literals or preceding closed numeric lets"
          )

staticMakeScientificCount :: Text -> Scientific -> Either String Int
staticMakeScientificCount bindingName countValue =
  case floatingOrInteger countValue :: Either Double Integer of
    Left _ ->
      Left ("make count for " <> T.unpack bindingName <> " must be an integer")
    Right integerValue
      | integerValue < 0 ->
          Left ("make count for " <> T.unpack bindingName <> " must be non-negative")
      | integerValue > toInteger (maxBound :: Int) ->
          Left ("make count for " <> T.unpack bindingName <> " is too large")
      | otherwise ->
          Right (fromInteger integerValue)

staticMakeEachItems :: ExpansionScope -> Text -> MakeEach -> Either String [MakeItem]
staticMakeEachItems _scope bindingName (MakeEachLiteral items) =
  validateStaticMakeEachItems bindingName items
staticMakeEachItems scope bindingName (MakeEachBinding itemName) =
  case Map.lookup itemName scope.esMakeItems of
    Just items -> validateStaticMakeEachItems bindingName items
    Nothing ->
      Left
        ( "makeEach items for "
            <> T.unpack bindingName
            <> " reference "
            <> T.unpack itemName
            <> ", but makeEach items must be a preceding static list with label fields"
        )

validateStaticMakeEachItems :: Text -> [MakeItem] -> Either String [MakeItem]
validateStaticMakeEachItems bindingName items =
  case duplicateMakeItemLabels items of
    duplicateLabel : _ ->
      Left
        ( "makeEach items for "
            <> T.unpack bindingName
            <> " produce duplicate generated label "
            <> T.unpack duplicateLabel
        )
    [] ->
      Right items

duplicateMakeItemLabels :: [MakeItem] -> [Text]
duplicateMakeItemLabels items =
  [ label
  | (label, count) <-
      Map.toAscList
        (Map.fromListWith (+) [(item.makeItemLabel, 1 :: Int) | item <- items])
  , count > 1
  ]

staticMakeItems :: CorePureExpr -> Parser [MakeItem]
staticMakeItems = \case
  CorePureList items ->
    case staticMakeItemsFromCorePure items of
      Just makeItems -> pure makeItems
      Nothing -> fail "makeEach literal items must be strings or records with string label fields"
  _ ->
    fail "makeEach literal items must be a static CorePure list"

staticMakeItemsFromExprs :: [Expr] -> Maybe [MakeItem]
staticMakeItemsFromExprs =
  traverse
    ( \exprValue -> do
        corePureValue <- either (const Nothing) Just (exprToCorePureExpr exprValue)
        staticMakeItemFromCorePure corePureValue
    )

staticMakeItemsFromCorePure :: [CorePureExpr] -> Maybe [MakeItem]
staticMakeItemsFromCorePure =
  traverse staticMakeItemFromCorePure

staticMakeItemFromCorePure :: CorePureExpr -> Maybe MakeItem
staticMakeItemFromCorePure exprValue =
  case exprValue of
    CorePureLit (CorePureString labelText) ->
      Just
        MakeItem
          { makeItemLabel = sanitizeMakeItemLabel labelText
          , makeItemValue = exprValue
          }
    CorePureRecord fields -> do
      labelText <- staticRecordStringField "label" fields
      Just
        MakeItem
          { makeItemLabel = sanitizeMakeItemLabel labelText
          , makeItemValue = exprValue
          }
    _ ->
      Nothing

corePureLeanStaticValueCompatible :: CorePureExpr -> Bool
corePureLeanStaticValueCompatible = \case
  CorePureLit (CorePureString _text) -> True
  CorePureLit (CorePureBool _boolValue) -> True
  CorePureLit (CorePureNumber numberValue) ->
    case floatingOrInteger numberValue :: Either Double Integer of
      Right integerValue -> integerValue >= 0
      Left _fractionalValue -> False
  CorePureLit CorePureNull -> False
  CorePureList items ->
    all corePureLeanStaticValueCompatible items
  CorePureRecord fields ->
    corePureLeanStaticRecordCompatible fields
  CorePureIdent _name -> False
  CorePureFieldAccess _target _fieldName -> False
  CorePureIndex _target _index -> False
  CorePureLambda _params _body -> False
  CorePureCall _function _arguments -> False
  CorePureUnary _operator _value -> False
  CorePureBinary _operator _lhs _rhs -> False
  CorePureLet _bindings _body -> False
  CorePureIf _condition _thenBranch _elseBranch -> False

corePureLeanStaticRecordCompatible :: [CorePureField] -> Bool
corePureLeanStaticRecordCompatible fields =
  all corePureLeanStaticFieldCompatible fields
    && Set.size (Set.fromList fieldNames) == length fieldNames
  where
    fieldNames =
      [ fieldName
      | CorePureField (fieldName :| []) _value <- fields
      ]

corePureLeanStaticFieldCompatible :: CorePureField -> Bool
corePureLeanStaticFieldCompatible = \case
  CorePureField (_fieldName :| []) value ->
    corePureLeanStaticValueCompatible value
  CorePureField (_fieldName :| _nestedPath) _value ->
    False

staticRecordStringField :: Text -> [CorePureField] -> Maybe Text
staticRecordStringField fieldName fields =
  case [ text
       | CorePureField (pathHead :| []) (CorePureLit (CorePureString text)) <- fields
       , pathHead == fieldName
       ] of
    text : _ -> Just text
    [] -> Nothing

sanitizeMakeItemLabel :: Text -> Text
sanitizeMakeItemLabel labelText =
  let mapped =
        T.map
          ( \charValue ->
              if Char.isAlphaNum charValue || charValue == '_'
                then charValue
                else '_'
          )
          labelText
      stripped = T.dropWhile (== '_') mapped
   in case T.uncons stripped of
        Just (firstChar, _)
          | Char.isAlpha firstChar || firstChar == '_' ->
              stripped
        _ ->
          "item_" <> stripped

corePureExprToExpr :: CorePureExpr -> Either String Expr
corePureExprToExpr = \case
  CorePureLit (CorePureString text) ->
    Right (ExprLit (LitString text))
  CorePureLit (CorePureNumber numberValue) ->
    Right (ExprLit (LitNumber numberValue))
  CorePureLit (CorePureBool boolValue) ->
    Right (ExprLit (LitBool boolValue))
  CorePureLit CorePureNull ->
    Left "makeEach Value items cannot contain null because Wire graph values have no null literal"
  CorePureList items ->
    ExprList <$> traverse corePureExprToExpr items
  CorePureRecord fields ->
    ExprRecord . Record <$> traverse corePureFieldToField fields
  CorePureIdent name ->
    Right (ExprIdent (QName (name :| [])))
  CorePureBinary CorePureMerge lhs rhs ->
    ExprMerge <$> corePureExprToExpr lhs <*> corePureExprToExpr rhs
  other ->
    Left ("makeEach Value item must be a static literal/list/record, got " <> show other)
  where
    corePureFieldToField (CorePureField path value) =
      Field path <$> corePureExprToExpr value

overlayGeneratedChildren :: [Text] -> Expr
overlayGeneratedChildren = \case
  [] -> ExprLit LitUnit
  firstName : restNames ->
    foldl'
      ExprOverlay
      (ExprIdent (QName (firstName :| [])))
      [ ExprIdent (QName (name :| []))
      | name <- restNames
      ]

validateKindDecl :: KindDecl -> Either String ()
validateKindDecl kindDeclValue =
  case duplicateText (fmap (.kindParamName) kindDeclValue.kindDeclParams) of
    Nothing -> Right ()
    Just duplicateName ->
      Left
        ( "kind "
            <> T.unpack kindDeclValue.kindDeclName
            <> " declares parameter "
            <> T.unpack duplicateName
            <> " more than once"
        )

validateFormDecl :: FormDecl -> Either String ()
validateFormDecl formDeclValue =
  case duplicateText (fmap (.formParamName) formDeclValue.formDeclParams) of
    Nothing -> Right ()
    Just duplicateName ->
      Left
        ( "form "
            <> T.unpack formDeclValue.formDeclName
            <> " declares parameter "
            <> T.unpack duplicateName
            <> " more than once"
        )

data FormSubstitution = FormSubstitution
  { fsKindSubstitution :: !KindSubstitution
  , fsGraphs :: !(Map Text Expr)
  }
  deriving stock (Show)

emptyFormSubstitution :: FormSubstitution
emptyFormSubstitution =
  FormSubstitution
    { fsKindSubstitution = emptyKindSubstitution
    , fsGraphs = Map.empty
    }

data FormExpansionState = FormExpansionState
  { fesLocalNames :: !(Map Text Text)
  , fesLocalLetNames :: !(Map Text Text)
  , fesIndexedFamilies :: !(Map Text [Text])
  , fesMakeCounts :: !(Map Text Scientific)
  , fesMakeItems :: !(Map Text [MakeItem])
  , fesGeneratedFamilies :: !(Map Text GeneratedFamilyProvenance)
  , fesOutputForms :: ![TopForm]
  }
  deriving stock (Show)

emptyFormExpansionState :: FormExpansionState
emptyFormExpansionState =
  FormExpansionState
    { fesLocalNames = Map.empty
    , fesLocalLetNames = Map.empty
    , fesIndexedFamilies = Map.empty
    , fesMakeCounts = Map.empty
    , fesMakeItems = Map.empty
    , fesGeneratedFamilies = Map.empty
    , fesOutputForms = []
    }

data ExpandedFormBinding = ExpandedFormBinding
  { efbForms :: ![TopForm]
  , efbGeneratedFamilies :: !(Map Text GeneratedFamilyProvenance)
  }
  deriving stock (Show)

expandFormBinding
  :: ExpansionScope
  -> LetVisibility
  -> Text
  -> FormDecl
  -> FormApplication
  -> Either String ExpandedFormBinding
expandFormBinding scope visibility bindingName formDeclValue application = do
  subst <- formSubstitutionForApplication formDeclValue application
  expandedState <-
    foldM
      (expandFormItem scope subst bindingName)
      emptyFormExpansionState
      formDeclValue.formDeclItems
  resultExpr <-
    substituteFormExpr
      subst
      expandedState.fesLocalNames
      expandedState.fesIndexedFamilies
      formDeclValue.formDeclResult
  Right
    ExpandedFormBinding
      { efbForms =
          expandedState.fesOutputForms
            <> [TopLet visibility bindingName (LetRhsWire resultExpr)]
      , efbGeneratedFamilies = expandedState.fesGeneratedFamilies
      }

expandFormItem
  :: ExpansionScope
  -> FormSubstitution
  -> Text
  -> FormExpansionState
  -> FormItem
  -> Either String FormExpansionState
expandFormItem scope subst prefix state = \case
  FormItemNode parsedNode -> do
    let localName = parsedNodeName parsedNode
    ensureFreshFormLocal subst state localName
    nodeDeclValue <- expandParsedNode scope.esKinds parsedNode
    substituted <- substituteFormNodeDecl subst state.fesLocalLetNames nodeDeclValue
    let prefixedName = formScopedName prefix localName
        prefixedNode = substituted {nodeDeclName = prefixedName}
    Right
      state
        { fesLocalNames = Map.insert localName prefixedName state.fesLocalNames
        , fesOutputForms = state.fesOutputForms <> [TopNode prefixedNode]
        }
  FormItemLet target rhs -> do
    let localName = target.letTargetName
    ensureFreshFormLocal subst state localName
    let prefixedName = formScopedName prefix localName
        stateWithName =
          state
            { fesLocalNames = Map.insert localName prefixedName state.fesLocalNames
            , fesLocalLetNames = Map.insert localName prefixedName state.fesLocalLetNames
            }
    case rhs of
      FormLetRhsApplication application ->
        case Map.lookup application.formApplicationName scope.esForms of
          Just formDeclValue -> do
            application' <-
              substituteFormApplication
                subst
                state.fesLocalNames
                state.fesIndexedFamilies
                application
            expanded <- expandFormBinding scope LetPrivate prefixedName formDeclValue application'
            Right
              stateWithName
                { fesOutputForms = state.fesOutputForms <> expanded.efbForms
                , fesGeneratedFamilies =
                    expanded.efbGeneratedFamilies <> state.fesGeneratedFamilies
                }
          Nothing -> do
            letRhsValue <-
              formApplicationToCorePureLetRhs
                =<< substituteFormApplication
                  subst
                  state.fesLocalNames
                  state.fesIndexedFamilies
                  application
            Right
              stateWithName
                { fesOutputForms =
                    state.fesOutputForms <> [TopLet LetPrivate prefixedName letRhsValue]
                }
      FormLetRhsMake application -> do
        application' <- substituteFormMakeApplication subst state.fesLocalNames application
        expanded <- expandMakeBinding (scopeWithFormData scope state) LetPrivate prefixedName application'
        let stateWithFamily =
              if target.letTargetIndexed
                then
                  stateWithName
                    { fesIndexedFamilies =
                        Map.insert localName expanded.embGeneratedChildNames stateWithName.fesIndexedFamilies
                    }
                else stateWithName
        Right
          stateWithFamily
            { fesOutputForms = state.fesOutputForms <> expanded.embForms
            , fesGeneratedFamilies =
                Map.insert
                  expanded.embGeneratedFamily.generatedFamilyBinding
                  expanded.embGeneratedFamily
                  state.fesGeneratedFamilies
            }
      FormLetRhsWire exprValue -> do
        letRhsValue <-
          substituteFormWireLetRhs
            subst
            state.fesLocalNames
            state.fesLocalLetNames
            state.fesIndexedFamilies
            exprValue
        let stateWithData =
              recordFormStaticMakeData prefixedName letRhsValue stateWithName
        Right
          stateWithData
            { fesOutputForms =
                state.fesOutputForms <> [TopLet LetPrivate prefixedName letRhsValue]
            }
      FormLetRhsCorePure exprValue -> do
        exprValue' <- substituteFormCorePure subst state.fesLocalLetNames exprValue
        let stateWithData =
              recordFormStaticMakeData prefixedName (LetRhsCorePure exprValue') stateWithName
        Right
          stateWithData
            { fesOutputForms =
                state.fesOutputForms <> [TopLet LetPrivate prefixedName (LetRhsCorePure exprValue')]
            }

scopeWithFormData :: ExpansionScope -> FormExpansionState -> ExpansionScope
scopeWithFormData scope state =
  scope
    { esMakeCounts = state.fesMakeCounts <> scope.esMakeCounts
    , esMakeItems = state.fesMakeItems <> scope.esMakeItems
    }

recordFormStaticMakeData :: Text -> LetRhs -> FormExpansionState -> FormExpansionState
recordFormStaticMakeData name rhs state =
  let scope =
        recordStaticMakeData
          name
          rhs
          emptyExpansionScope
            { esMakeCounts = state.fesMakeCounts
            , esMakeItems = state.fesMakeItems
            }
   in state
        { fesMakeCounts = scope.esMakeCounts
        , fesMakeItems = scope.esMakeItems
        }

parsedNodeName :: ParsedNodeDecl -> Text
parsedNodeName = \case
  ParsedNodeBody name _ _ _ -> name
  ParsedNodeKindApplication name _ -> name

ensureFreshFormLocal :: FormSubstitution -> FormExpansionState -> Text -> Either String ()
ensureFreshFormLocal subst state localName =
  when
    ( Map.member localName state.fesLocalNames
        || Map.member localName subst.fsKindSubstitution.ksPortLabels
        || Map.member localName subst.fsKindSubstitution.ksContracts
        || Map.member localName subst.fsKindSubstitution.ksValues
        || Map.member localName subst.fsKindSubstitution.ksExecutors
        || Map.member localName subst.fsGraphs
    )
    (Left ("form local name " <> T.unpack localName <> " is already bound"))

formScopedName :: Text -> Text -> Text
formScopedName prefix localName =
  prefix <> "/" <> localName

formSubstitutionForApplication :: FormDecl -> FormApplication -> Either String FormSubstitution
formSubstitutionForApplication formDeclValue application = do
  let expectedCount = length formDeclValue.formDeclParams
      actualCount = length application.formApplicationArgs
  when (expectedCount /= actualCount) $
    Left
      ( "form "
          <> T.unpack formDeclValue.formDeclName
          <> " expects "
          <> show expectedCount
          <> " argument(s), got "
          <> show actualCount
      )
  foldM bindFormArgument emptyFormSubstitution $
    zip formDeclValue.formDeclParams application.formApplicationArgs
  where
    bindFormArgument subst (param, arg) =
      case param.formParamClass of
        FormParamPortLabel -> do
          actual <- expectSimpleFormIdentifier formDeclValue param "PortLabel" arg
          Right
            subst
              { fsKindSubstitution =
                  subst.fsKindSubstitution
                    { ksPortLabels =
                        Map.insert param.formParamName actual subst.fsKindSubstitution.ksPortLabels
                    }
              }
        FormParamContract -> do
          actual <- expectSimpleFormIdentifier formDeclValue param "Contract" arg
          Right
            subst
              { fsKindSubstitution =
                  subst.fsKindSubstitution
                    { ksContracts =
                        Map.insert param.formParamName actual subst.fsKindSubstitution.ksContracts
                    }
              }
        FormParamExecutor -> do
          actual <- expectSimpleFormIdentifier formDeclValue param "Executor" arg
          Right
            subst
              { fsKindSubstitution =
                  subst.fsKindSubstitution
                    { ksExecutors =
                        Map.insert
                          param.formParamName
                          actual
                          subst.fsKindSubstitution.ksExecutors
                    }
              }
        FormParamValue -> do
          coreValue <- exprToCorePureExpr arg
          Right
            subst
              { fsKindSubstitution =
                  subst.fsKindSubstitution
                    { ksValues = Map.insert param.formParamName arg subst.fsKindSubstitution.ksValues
                    , ksCoreValues =
                        Map.insert param.formParamName coreValue subst.fsKindSubstitution.ksCoreValues
                    }
              }
        FormParamGraph ->
          Right subst {fsGraphs = Map.insert param.formParamName arg subst.fsGraphs}

expectSimpleFormIdentifier :: FormDecl -> FormParam -> String -> Expr -> Either String Text
expectSimpleFormIdentifier formDeclValue param expectedClass = \case
  ExprIdent (QName (name :| [])) ->
    Right name
  other ->
    Left
      ( "form "
          <> T.unpack formDeclValue.formDeclName
          <> " parameter "
          <> T.unpack param.formParamName
          <> " expects "
          <> expectedClass
          <> " argument, got "
          <> show other
      )

substituteFormApplication
  :: FormSubstitution
  -> Map Text Text
  -> Map Text [Text]
  -> FormApplication
  -> Either String FormApplication
substituteFormApplication subst localNames indexedFamilies application =
  FormApplication application.formApplicationName
    <$> traverse (substituteFormExpr subst localNames indexedFamilies) application.formApplicationArgs

substituteFormMakeApplication
  :: FormSubstitution -> Map Text Text -> MakeApplication -> Either String MakeApplication
substituteFormMakeApplication subst localNames application =
  (\inputValue -> application {makeApplicationInput = inputValue})
    <$> substituteFormMakeInput subst localNames application.makeApplicationInput

substituteFormMakeInput
  :: FormSubstitution -> Map Text Text -> MakeInput -> Either String MakeInput
substituteFormMakeInput subst localNames = \case
  MakeInputCount countValue ->
    MakeInputCount <$> substituteFormMakeCount subst localNames countValue
  MakeInputEach eachValue ->
    MakeInputEach <$> substituteFormMakeEach subst localNames eachValue

substituteFormMakeCount
  :: FormSubstitution -> Map Text Text -> MakeCount -> Either String MakeCount
substituteFormMakeCount subst localNames = \case
  MakeCountLiteral countValue ->
    Right (MakeCountLiteral countValue)
  MakeCountBinding countName ->
    case Map.lookup countName subst.fsKindSubstitution.ksValues of
      Just (ExprLit (LitNumber countValue)) ->
        Right (MakeCountLiteral countValue)
      Just (ExprIdent (QName (replacement :| []))) ->
        Right (MakeCountBinding replacement)
      Just other ->
        Left
          ( "make count "
              <> T.unpack countName
              <> " must resolve to an integer literal or static count binding, got "
              <> show other
          )
      Nothing ->
        Right (MakeCountBinding (Map.findWithDefault countName countName localNames))

substituteFormMakeEach
  :: FormSubstitution -> Map Text Text -> MakeEach -> Either String MakeEach
substituteFormMakeEach subst localNames = \case
  MakeEachLiteral items ->
    Right (MakeEachLiteral items)
  MakeEachBinding itemName ->
    case Map.lookup itemName subst.fsKindSubstitution.ksValues of
      Just (ExprIdent (QName (replacement :| []))) ->
        Right (MakeEachBinding replacement)
      Just other ->
        Left
          ( "makeEach items "
              <> T.unpack itemName
              <> " must resolve to a static item-list binding, got "
              <> show other
          )
      Nothing ->
        Right (MakeEachBinding (Map.findWithDefault itemName itemName localNames))

formApplicationToCorePureLetRhs :: FormApplication -> Either String LetRhs
formApplicationToCorePureLetRhs application =
  LetRhsCorePure . CorePureCall (CorePureIdent application.formApplicationName)
    <$> traverse exprToCorePureExpr application.formApplicationArgs

substituteFormNodeDecl
  :: FormSubstitution -> Map Text Text -> NodeDecl -> Either String NodeDecl
substituteFormNodeDecl subst localLetNames nodeDeclValue = do
  metadata <- traverse (substituteRecord subst.fsKindSubstitution) nodeDeclValue.nodeDeclMetadata
  portSig <- traverse (substitutePortDecl subst.fsKindSubstitution) nodeDeclValue.nodeDeclPortSig
  body <-
    substituteNodeBody subst.fsKindSubstitution nodeDeclValue.nodeDeclBody
      >>= rewriteNodeBodyLocalLets localLetNames
  Right
    ( nodeDeclValue
        { nodeDeclMetadata = metadata
        , nodeDeclPortSig = portSig
        , nodeDeclBody = body
        }
    )

substituteFormExpr
  :: FormSubstitution -> Map Text Text -> Map Text [Text] -> Expr -> Either String Expr
substituteFormExpr subst localNames indexedFamilies exprValue = do
  substituted <- substituteExpr subst.fsKindSubstitution exprValue
  rewritten <- rewriteFormExpr subst.fsGraphs localNames substituted
  resolveFamilyProjections indexedFamilies rewritten

substituteFormWireLetRhs
  :: FormSubstitution
  -> Map Text Text
  -> Map Text Text
  -> Map Text [Text]
  -> Expr
  -> Either String LetRhs
substituteFormWireLetRhs subst localNames localLetNames indexedFamilies exprValue = do
  substituted <- substituteExpr subst.fsKindSubstitution exprValue
  rewritten <- rewriteFormExpr subst.fsGraphs localNames substituted
  resolved <- resolveLetRhsFamilyProjections indexedFamilies (LetRhsWire rewritten)
  case resolved of
    LetRhsCorePure coreExpr ->
      LetRhsCorePure <$> substituteFormCorePure subst localLetNames coreExpr
    LetRhsWire wireExpr ->
      Right (LetRhsWire wireExpr)

substituteFormCorePure
  :: FormSubstitution -> Map Text Text -> CorePureExpr -> Either String CorePureExpr
substituteFormCorePure subst localLetNames exprValue =
  rewriteCorePureLocalLets localLetNames
    <$> substituteCorePureExpr subst.fsKindSubstitution exprValue

rewriteFormExpr :: Map Text Expr -> Map Text Text -> Expr -> Either String Expr
rewriteFormExpr graphParams localNames = go
  where
    go = \case
      ExprOverlay lhs rhs ->
        ExprOverlay <$> go lhs <*> go rhs
      ExprConnect lhs rhs ->
        ExprConnect <$> go lhs <*> go rhs
      ExprStar lhs rhs ->
        ExprStar <$> go lhs <*> go rhs
      ExprMerge lhs rhs ->
        ExprMerge <$> go lhs <*> go rhs
      ExprConcat lhs rhs ->
        ExprConcat <$> go lhs <*> go rhs
      ExprSelect base arms ->
        ExprSelect <$> go base <*> traverse rewriteArm arms
      ExprFamilyProjection familyName indexValue ->
        Right (ExprFamilyProjection familyName indexValue)
      ExprExecutor executor ->
        Right (ExprExecutor executor)
      ExprConstructor name recordValue ->
        ExprConstructor name <$> rewriteRecord recordValue
      ExprRecord recordValue ->
        ExprRecord <$> rewriteRecord recordValue
      ExprList items ->
        ExprList <$> traverse go items
      ExprLit literalValue ->
        Right (ExprLit literalValue)
      ExprIdent (QName (name :| []))
        | Just replacement <- Map.lookup name graphParams ->
            go replacement
        | Just replacement <- Map.lookup name localNames ->
            Right (ExprIdent (QName (replacement :| [])))
      ExprIdent name ->
        Right (ExprIdent name)

    rewriteArm (SelectArm key armExpr) =
      SelectArm key <$> go armExpr

    rewriteRecord (Record fields) =
      Record <$> traverse rewriteField fields

    rewriteField (Field path value) =
      Field path <$> go value

rewriteNodeBodyLocalLets :: Map Text Text -> NodeBody -> Either String NodeBody
rewriteNodeBodyLocalLets localLetNames = \case
  NodeBodyExecutor whereExpr executorCallValue ->
    Right $
      NodeBodyExecutor
        (fmap (rewriteCorePureLocalLets localLetNames) whereExpr)
        (rewriteExecutorCallLocalLets localLetNames executorCallValue)
  NodeBodyPure pureBody ->
    Right . NodeBodyPure $ case pureBody of
      NodePureBody whereExpr (NodePureProduct outputs) ->
        NodePureBody
          (fmap (rewriteCorePureLocalLets localLetNames) whereExpr)
          (NodePureProduct (fmap (rewritePureOutputEquationLocalLets localLetNames) outputs))
      NodePureBody whereExpr (NodePureSum variants bodyExpr) ->
        NodePureBody
          (fmap (rewriteCorePureLocalLets localLetNames) whereExpr)
          (NodePureSum variants (rewriteCorePureLocalLets localLetNames bodyExpr))

rewritePureOutputEquationLocalLets :: Map Text Text -> PureOutputEquation -> PureOutputEquation
rewritePureOutputEquationLocalLets localLetNames outputEquation =
  outputEquation
    { pureOutputEquationExpr =
        rewriteCorePureLocalLets localLetNames outputEquation.pureOutputEquationExpr
    }

rewriteExecutorCallLocalLets :: Map Text Text -> ExecutorCall -> ExecutorCall
rewriteExecutorCallLocalLets localLetNames = \case
  ExecutorCallInline executor inputArg ->
    ExecutorCallInline executor (fmap (rewriteCorePureLocalLets localLetNames) inputArg)
  ExecutorCallBound name inputArg ->
    ExecutorCallBound
      (Map.findWithDefault name name localLetNames)
      (fmap (rewriteCorePureLocalLets localLetNames) inputArg)

rewriteCorePureLocalLets :: Map Text Text -> CorePureExpr -> CorePureExpr
rewriteCorePureLocalLets localLetNames = go
  where
    go = \case
      CorePureLit literalValue ->
        CorePureLit literalValue
      CorePureIdent name ->
        CorePureIdent (Map.findWithDefault name name localLetNames)
      CorePureList items ->
        CorePureList (fmap go items)
      CorePureRecord fields ->
        CorePureRecord (fmap rewriteField fields)
      CorePureFieldAccess target fieldName ->
        CorePureFieldAccess (go target) fieldName
      CorePureIndex target indexValue ->
        CorePureIndex (go target) (go indexValue)
      CorePureLambda params body ->
        CorePureLambda
          params
          (rewriteCorePureLocalLets (foldr Map.delete localLetNames (NE.toList params)) body)
      CorePureCall function args ->
        CorePureCall (go function) (fmap go args)
      CorePureUnary op value ->
        CorePureUnary op (go value)
      CorePureBinary op lhs rhs ->
        CorePureBinary op (go lhs) (go rhs)
      CorePureLet bindings body ->
        rewriteLet bindings body
      CorePureIf condition thenExpr elseExpr ->
        CorePureIf (go condition) (go thenExpr) (go elseExpr)

    rewriteField (CorePureField path value) =
      CorePureField path (go value)

    rewriteLet bindings body =
      let bindingNames = fmap (.corePureBindingName) (NE.toList bindings)
          localLetNames' = foldr Map.delete localLetNames bindingNames
          rewriteBinding binding =
            binding {corePureBindingExpr = rewriteCorePureLocalLets localLetNames binding.corePureBindingExpr}
       in CorePureLet
            (fmap rewriteBinding bindings)
            (rewriteCorePureLocalLets localLetNames' body)

duplicateText :: [Text] -> Maybe Text
duplicateText =
  go Map.empty
  where
    go _seen [] = Nothing
    go seen (name : rest)
      | Map.member name seen = Just name
      | otherwise = go (Map.insert name () seen) rest

expandParsedNode :: Map Text KindDecl -> ParsedNodeDecl -> Either String NodeDecl
expandParsedNode _kindScope (ParsedNodeBody name metadata portSig body) =
  Right
    NodeDecl
      { nodeDeclName = name
      , nodeDeclMetadata = metadata
      , nodeDeclPortSig = portSig
      , nodeDeclBody = body
      }
expandParsedNode kindScope (ParsedNodeKindApplication nodeName application) = do
  kindDeclValue <-
    maybe
      ( Left
          ("node " <> T.unpack nodeName <> " applies unknown kind " <> T.unpack application.kindApplicationName)
      )
      Right
      (Map.lookup application.kindApplicationName kindScope)
  subst <- kindSubstitutionForApplication kindDeclValue application
  portSig <- traverse (substitutePortDecl subst) kindDeclValue.kindDeclPortSig
  body <- substituteNodeBody subst kindDeclValue.kindDeclBody
  Right
    NodeDecl
      { nodeDeclName = nodeName
      , nodeDeclMetadata = Nothing
      , nodeDeclPortSig = portSig
      , nodeDeclBody = body
      }

kindSubstitutionForApplication :: KindDecl -> KindApplication -> Either String KindSubstitution
kindSubstitutionForApplication kindDeclValue application = do
  let expectedCount = length kindDeclValue.kindDeclParams
      actualCount = length application.kindApplicationArgs
  when (expectedCount /= actualCount) $
    Left
      ( "kind "
          <> T.unpack kindDeclValue.kindDeclName
          <> " expects "
          <> show expectedCount
          <> " argument(s), got "
          <> show actualCount
      )
  foldM bindKindArgument emptyKindSubstitution $
    zip kindDeclValue.kindDeclParams application.kindApplicationArgs
  where
    bindKindArgument subst (param, arg) =
      case param.kindParamClass of
        KindParamPortLabel -> do
          actual <- expectSimpleIdentifier kindDeclValue param "PortLabel" arg
          Right subst {ksPortLabels = Map.insert param.kindParamName actual subst.ksPortLabels}
        KindParamContract -> do
          actual <- expectSimpleIdentifier kindDeclValue param "Contract" arg
          Right subst {ksContracts = Map.insert param.kindParamName actual subst.ksContracts}
        KindParamExecutor -> do
          actual <- expectSimpleIdentifier kindDeclValue param "Executor" arg
          Right
            subst
              { ksExecutors =
                  Map.insert param.kindParamName actual subst.ksExecutors
              }
        KindParamValue -> do
          coreValue <- exprToCorePureExpr arg
          Right
            subst
              { ksValues = Map.insert param.kindParamName arg subst.ksValues
              , ksCoreValues = Map.insert param.kindParamName coreValue subst.ksCoreValues
              }

expectSimpleIdentifier :: KindDecl -> KindParam -> String -> Expr -> Either String Text
expectSimpleIdentifier kindDeclValue param expectedClass = \case
  ExprIdent (QName (name :| [])) ->
    Right name
  other ->
    Left
      ( "kind "
          <> T.unpack kindDeclValue.kindDeclName
          <> " parameter "
          <> T.unpack param.kindParamName
          <> " expects "
          <> expectedClass
          <> " argument, got "
          <> show other
      )

substitutePortDecl :: KindSubstitution -> PortDecl -> Either String PortDecl
substitutePortDecl subst = \case
  PortInputDecl label contractId ->
    Right (PortInputDecl (substitutePortLabel subst label) (substituteContractId subst contractId))
  PortOutputDecl label contractId ->
    Right (PortOutputDecl (substitutePortLabel subst label) (substituteContractId subst contractId))
  PortOutputSumDecl variants ->
    PortOutputSumDecl <$> traverse (substituteSumVariant subst) variants

substituteSumVariant :: KindSubstitution -> SumVariant -> Either String SumVariant
substituteSumVariant subst (SumVariant label contractId) =
  Right (SumVariant (substitutePortLabel subst label) (substituteContractId subst contractId))

substitutePortLabel :: KindSubstitution -> PortLabel -> PortLabel
substitutePortLabel subst = \case
  NoLabel -> NoLabel
  Label labelName -> Label (Map.findWithDefault labelName labelName subst.ksPortLabels)

substituteContractId :: KindSubstitution -> ContractId -> ContractId
substituteContractId subst (ContractId contractName) =
  ContractId $
    case parseBoundedIndexedContractName contractName of
      Just (elementContract, count) ->
        boundedIndexedContractName
          (Map.findWithDefault elementContract elementContract subst.ksContracts)
          count
      Nothing ->
        Map.findWithDefault contractName contractName subst.ksContracts

substituteNodeBody :: KindSubstitution -> NodeBody -> Either String NodeBody
substituteNodeBody subst = \case
  NodeBodyExecutor whereExpr executorCallValue ->
    NodeBodyExecutor
      <$> traverse (substituteCorePureExpr subst) whereExpr
      <*> substituteExecutorCall subst executorCallValue
  NodeBodyPure pureBody ->
    NodeBodyPure <$> substitutePureBody subst pureBody

substitutePureBody :: KindSubstitution -> NodePureBody -> Either String NodePureBody
substitutePureBody subst = \case
  NodePureBody whereExpr (NodePureProduct outputs) ->
    NodePureBody
      <$> traverse (substituteCorePureExpr subst) whereExpr
      <*> (NodePureProduct <$> traverse (substitutePureOutputEquation subst) outputs)
  NodePureBody whereExpr (NodePureSum variants bodyExpr) ->
    NodePureBody
      <$> traverse (substituteCorePureExpr subst) whereExpr
      <*> ( NodePureSum
              <$> traverse (substituteSumVariant subst) variants
              <*> substituteCorePureExpr subst bodyExpr
          )

substitutePureOutputEquation
  :: KindSubstitution -> PureOutputEquation -> Either String PureOutputEquation
substitutePureOutputEquation subst outputEquation =
  PureOutputEquation
    (substitutePortLabel subst outputEquation.pureOutputEquationLabel)
    (substituteContractId subst outputEquation.pureOutputEquationContract)
    <$> substituteCorePureExpr subst outputEquation.pureOutputEquationExpr

substituteExecutorCall :: KindSubstitution -> ExecutorCall -> Either String ExecutorCall
substituteExecutorCall subst = \case
  ExecutorCallInline executor@(QName (name :| [])) inputArg
    | Just bound <- Map.lookup name subst.ksExecutors ->
        ExecutorCallBound bound <$> traverse (substituteCorePureExpr subst) inputArg
    | otherwise ->
        ExecutorCallInline executor <$> traverse (substituteCorePureExpr subst) inputArg
  ExecutorCallInline executor inputArg ->
    ExecutorCallInline executor <$> traverse (substituteCorePureExpr subst) inputArg
  ExecutorCallBound name inputArg ->
    ExecutorCallBound
      (Map.findWithDefault name name subst.ksExecutors)
      <$> traverse (substituteCorePureExpr subst) inputArg

substituteRecord :: KindSubstitution -> Record -> Either String Record
substituteRecord subst (Record fields) =
  Record <$> traverse (substituteField subst) fields

substituteField :: KindSubstitution -> Field -> Either String Field
substituteField subst (Field path value) =
  Field path <$> substituteExpr subst value

substituteExpr :: KindSubstitution -> Expr -> Either String Expr
substituteExpr subst = \case
  ExprOverlay lhs rhs ->
    ExprOverlay <$> substituteExpr subst lhs <*> substituteExpr subst rhs
  ExprConnect lhs rhs ->
    ExprConnect <$> substituteExpr subst lhs <*> substituteExpr subst rhs
  ExprStar lhs rhs ->
    ExprStar <$> substituteExpr subst lhs <*> substituteExpr subst rhs
  ExprMerge lhs rhs ->
    ExprMerge <$> substituteExpr subst lhs <*> substituteExpr subst rhs
  ExprConcat lhs rhs ->
    ExprConcat <$> substituteExpr subst lhs <*> substituteExpr subst rhs
  ExprSelect base arms ->
    ExprSelect <$> substituteExpr subst base <*> traverse (substituteSelectArm subst) arms
  ExprFamilyProjection familyName indexValue ->
    Right (ExprFamilyProjection familyName indexValue)
  ExprExecutor executor ->
    Right (ExprExecutor executor)
  ExprConstructor name recordValue ->
    ExprConstructor name <$> substituteRecord subst recordValue
  ExprRecord recordValue ->
    ExprRecord <$> substituteRecord subst recordValue
  ExprList items ->
    ExprList <$> traverse (substituteExpr subst) items
  ExprLit literalValue ->
    Right (ExprLit literalValue)
  ExprIdent (QName (name :| []))
    | Just replacement <- Map.lookup name subst.ksValues ->
        Right replacement
  ExprIdent name ->
    Right (ExprIdent name)

substituteSelectArm :: KindSubstitution -> SelectArm -> Either String SelectArm
substituteSelectArm subst (SelectArm key armExpr) =
  SelectArm key <$> substituteExpr subst armExpr

substituteCorePureExpr :: KindSubstitution -> CorePureExpr -> Either String CorePureExpr
substituteCorePureExpr subst = \case
  CorePureLit literalValue ->
    Right (CorePureLit literalValue)
  CorePureIdent name ->
    Right $
      case Map.lookup name subst.ksCoreValues of
        Just replacement -> replacement
        Nothing ->
          CorePureIdent (Map.findWithDefault name name subst.ksPortLabels)
  CorePureList items ->
    CorePureList <$> traverse (substituteCorePureExpr subst) items
  CorePureRecord fields ->
    CorePureRecord <$> traverse (substituteCorePureField subst) fields
  CorePureFieldAccess target fieldName ->
    CorePureFieldAccess <$> substituteCorePureExpr subst target <*> pure fieldName
  CorePureIndex target indexValue ->
    CorePureIndex <$> substituteCorePureExpr subst target <*> substituteCorePureExpr subst indexValue
  CorePureLambda params body ->
    CorePureLambda params
      <$> substituteCorePureExpr (withoutCorePureNames (NE.toList params) subst) body
  CorePureCall function args ->
    CorePureCall
      <$> substituteCorePureExpr subst function
      <*> traverse (substituteCorePureExpr subst) args
  CorePureUnary op value ->
    CorePureUnary op <$> substituteCorePureExpr subst value
  CorePureBinary op lhs rhs ->
    CorePureBinary op <$> substituteCorePureExpr subst lhs <*> substituteCorePureExpr subst rhs
  CorePureLet bindings body ->
    substituteCorePureLet subst bindings body
  CorePureIf condition thenExpr elseExpr ->
    CorePureIf
      <$> substituteCorePureExpr subst condition
      <*> substituteCorePureExpr subst thenExpr
      <*> substituteCorePureExpr subst elseExpr

substituteCorePureLet
  :: KindSubstitution -> NonEmpty CorePureBinding -> CorePureExpr -> Either String CorePureExpr
substituteCorePureLet subst bindings body = do
  (substAfterBindings, reversedBindings) <-
    foldM
      ( \(currentSubst, acc) binding -> do
          exprValue <- substituteCorePureExpr currentSubst binding.corePureBindingExpr
          let currentSubst' = withoutCorePureNames [binding.corePureBindingName] currentSubst
          pure
            ( currentSubst'
            , binding {corePureBindingExpr = exprValue} : acc
            )
      )
      (subst, [])
      (NE.toList bindings)
  case NE.nonEmpty (reverse reversedBindings) of
    Nothing ->
      Left "internal error: CorePure let lost all bindings during kind expansion"
    Just bindings' ->
      CorePureLet bindings' <$> substituteCorePureExpr substAfterBindings body

substituteCorePureField :: KindSubstitution -> CorePureField -> Either String CorePureField
substituteCorePureField subst (CorePureField path value) =
  CorePureField path <$> substituteCorePureExpr subst value

withoutCorePureNames :: [Text] -> KindSubstitution -> KindSubstitution
withoutCorePureNames names subst =
  subst
    { ksPortLabels = foldr Map.delete subst.ksPortLabels names
    , ksCoreValues = foldr Map.delete subst.ksCoreValues names
    }

exprToCorePureExpr :: Expr -> Either String CorePureExpr
exprToCorePureExpr = \case
  ExprLit (LitString text) ->
    Right (CorePureLit (CorePureString text))
  ExprLit (LitMultilineString text) ->
    Right (CorePureLit (CorePureString text))
  ExprLit (LitNumber numberValue) ->
    Right (CorePureLit (CorePureNumber numberValue))
  ExprLit (LitBool boolValue) ->
    Right (CorePureLit (CorePureBool boolValue))
  ExprList items ->
    CorePureList <$> traverse exprToCorePureExpr items
  ExprRecord (Record fields) ->
    CorePureRecord <$> traverse fieldToCorePure fields
  ExprIdent (QName (name :| [])) ->
    Right (CorePureIdent name)
  ExprMerge lhs rhs ->
    CorePureBinary CorePureMerge <$> exprToCorePureExpr lhs <*> exprToCorePureExpr rhs
  ExprFamilyProjection familyName indexValue ->
    Right
      ( CorePureIndex
          (CorePureIdent familyName)
          (CorePureLit (CorePureNumber (fromIntegral indexValue)))
      )
  other ->
    Left ("kind Value argument must be CorePure-compatible, got " <> show other)
  where
    fieldToCorePure (Field path value) =
      CorePureField path <$> exprToCorePureExpr value
