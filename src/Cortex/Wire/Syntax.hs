{- |
Module      : Cortex.Wire.Syntax
Description : Canonical Wire surface syntax and shared structural types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Mirrors the grammar specified in
@docs/Reference/Wire/grammar.md@ (accepted 2026-04-23). Each
production in §14 has a corresponding constructor here.

Structural rules, port-key matching, and runtime admission are not
represented in the AST: this module only captures surface syntax.
Static validation happens downstream in 'Cortex.Wire.Parser' (shape)
and 'Cortex.Wire.Compile' (well-formedness + lowering).

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Syntax
  ( module Cortex.Wire.AST

    -- * Identifiers
  , QName (..)
  , renderQName
  , ContractId (..)
  , boundedIndexedContractName
  , parseBoundedIndexedContractName
  , renderContractId
  , PortLabel (..)

    -- * Port signatures
  , PortDirection (..)
  , PortDecl (..)
  , SumVariant (..)

    -- * Expressions
  , Literal (..)
  , Field (..)
  , Record (..)
  , SelectArm (..)
  , Expr (..)
  , CorePureLiteral (..)
  , CorePureUnaryOp (..)
  , CorePureBinOp (..)
  , CorePureField (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , ExecutorCall (..)
  , LetVisibility (..)
  , LetRhs (..)

    -- * Top-level forms
  , ImportSpec (..)
  , UseItem (..)
  , UseSpec (..)
  , ContractDecl (..)
  , PureOutputEquation (..)
  , NodePureResult (..)
  , NodePureBody (..)
  , NodeBody (..)
  , NodeDecl (..)
  , TopForm (..)
  , WireFile (..)
  )
where

import Control.Monad (guard)
import Data.Aeson (FromJSON, ToJSON (..), (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

import Cortex.Wire.AST

{- | Qualified identifier. One or more dot-joined segments, e.g.
@review.analyst@, @cortex.deep_report@. A bare (single-segment) name is
still a 'QName'.
-}
newtype QName = QName (NonEmpty Text)
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

renderQName :: QName -> Text
renderQName (QName segs) = T.intercalate "." (NE.toList segs)

{- | Contract names are flat and globally namespaced (grammar §4). Two
'ContractId's are equal iff their text is equal.
-}
newtype ContractId = ContractId {unContractId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

{- | Canonical compact storage form for bounded indexed products; use 'renderContractId' for
user-facing output with spacing.
-}
boundedIndexedContractName :: Text -> Natural -> Text
boundedIndexedContractName elementContract count =
  "[" <> elementContract <> ";" <> T.pack (show count) <> "]"

parseBoundedIndexedContractName :: Text -> Maybe (Text, Natural)
parseBoundedIndexedContractName rawName = do
  -- Accept the human-rendered form "[T; N]" as well as canonical storage "[T;N]".
  inner <- T.stripSuffix "]" =<< T.stripPrefix "[" (T.strip rawName)
  case T.splitOn ";" inner of
    [rawElement, rawCount] -> do
      let elementContract = T.strip rawElement
      guard (not (T.null elementContract))
      count <- readMaybe (T.unpack (T.strip rawCount))
      if count < (0 :: Integer)
        then Nothing
        else Just (elementContract, fromInteger count)
    _ ->
      Nothing

renderContractId :: ContractId -> Text
renderContractId (ContractId contractName) =
  case parseBoundedIndexedContractName contractName of
    Just (elementContract, count) ->
      "[" <> elementContract <> "; " <> T.pack (show count) <> "]"
    Nothing ->
      contractName

{- | Optional port label. 'NoLabel' is a distinct port key from @Label _@ —
not a wildcard (grammar §6.2).
-}
data PortLabel = NoLabel | Label !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Direction of a port: input (@<-@) or output (@->@).
data PortDirection = PortInput | PortOutput
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | One variant inside a sum-grouped output (grammar §6.5).
data SumVariant = SumVariant
  { svLabel :: !PortLabel
  , svContract :: !ContractId
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

{- | A single port declaration as written in source.

Sum-grouped output ports are distinct from single-variant outputs; the
grouping carries runtime-visible mutual-exclusion metadata.
-}
data PortDecl
  = PortInputDecl !PortLabel !ContractId
  | PortOutputDecl !PortLabel !ContractId
  | {- | Sum-grouped output. Invariant: the NonEmpty list carries **two or
    more** variants; a one-variant sum is a syntax error at parse time.
    -}
    PortOutputSumDecl !(NonEmpty SumVariant)
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Literal values in the ordinary (non-wire) algebra.
data Literal
  = LitString !Text
  | {- | Multi-line verbatim string (@''...''@), preserved as a single
    'Text' with embedded newlines; no escape processing.
    -}
    LitMultilineString !Text
  | LitNumber !Scientific
  | LitBool !Bool
  | -- | @()@ — the empty wire. Not valid at port positions.
    LitUnit
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | One field inside a record literal. 'fieldPath' supports dotted
keys (grammar §8.3), e.g. @render.aggregateOpenGaps = true;@.
-}
data Field = Field
  { fieldPath :: !(NonEmpty Text)
  , fieldValue :: !Expr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Record literal: an ordered sequence of fields. Order is not
semantically meaningful (records are unordered) but preserving it aids
diagnostics.
-}
newtype Record = Record {recordFields :: [Field]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | One named arm in a postfix @select(...)@ expression (grammar §7.7 /
§14.3). The key is the variant identity token as written in source;
downstream semantic passes resolve it against labels/contracts on the
selector's exclusive output boundary.
-}
data SelectArm = SelectArm
  { selectArmKey :: !Text
  , selectArmExpr :: !Expr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Unified expression form: both wire-kind and value-kind expressions
share one syntax; disambiguation is semantic, not syntactic (grammar
§14.3).
-}
data Expr
  = -- | @a <> b@ — graph overlay (infixl 2).
    ExprOverlay !Expr !Expr
  | -- | @a => b@ — port-key-matched connect (infixl 3).
    ExprConnect !Expr !Expr
  | -- | @a * b@ — explicit phantom record↔ports adapter (infixl 3).
    ExprStar !Expr !Expr
  | -- | @a // b@ — right-biased shallow merge on records (infixl 5).
    ExprMerge !Expr !Expr
  | -- | @a ++ b@ — string or list concatenation (infixl 5).
    ExprConcat !Expr !Expr
  | {- | @lhs select(A: a, B: b)@ — postfix conditional reduction over an
    exclusive output boundary (postfix 4).
    -}
    ExprSelect !Expr !(NonEmpty SelectArm)
  | -- | @family[0]@ — source projection from an indexed @make@ family.
    ExprFamilyProjection !Text !Int
  | -- | @\@qual.name@ — inert bare executor authority value.
    ExprExecutor !QName
  | -- | @\@qual.name { config }@ — inert configured executor value.
    ExprConfiguredExecutor !QName !Record
  | {- | @qual.name { field = ... }@ — tagged-record config constructor;
    no leading @\@@. Value-position only.
    -}
    ExprConstructor !QName !Record
  | ExprRecord !Record
  | ExprList ![Expr]
  | ExprLit !Literal
  | {- | Bare qualified identifier. May resolve to a let binding, an
    imported value, a contract name, or a registry-ambient name (tool,
    config constructor); context decides.
    -}
    ExprIdent !QName
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Literals admitted by CorePure, the deterministic expression
language used by pure output equations.
-}
data CorePureLiteral
  = CorePureString !Text
  | CorePureNumber !Scientific
  | CorePureBool !Bool
  | CorePureNull
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CorePureUnaryOp
  = CorePureNegate
  | CorePureNot
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CorePureBinOp
  = CorePureAdd
  | CorePureSubtract
  | CorePureMultiply
  | CorePureDivide
  | CorePureMerge
  | CorePureEqual
  | CorePureNotEqual
  | CorePureLessThan
  | CorePureLessThanOrEqual
  | CorePureGreaterThan
  | CorePureGreaterThanOrEqual
  | CorePureAnd
  | CorePureOr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CorePureField = CorePureField
  { corePureFieldPath :: !(NonEmpty Text)
  , corePureFieldValue :: !CorePureExpr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CorePureBinding = CorePureBinding
  { corePureBindingName :: !Text
  , corePureBindingExpr :: !CorePureExpr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CorePureExpr
  = CorePureLit !CorePureLiteral
  | CorePureIdent !Text
  | CorePureList ![CorePureExpr]
  | CorePureRecord ![CorePureField]
  | CorePureFieldAccess !CorePureExpr !Text
  | CorePureIndex !CorePureExpr !CorePureExpr
  | CorePureLambda !(NonEmpty Text) !CorePureExpr
  | CorePureCall !CorePureExpr ![CorePureExpr]
  | CorePureUnary !CorePureUnaryOp !CorePureExpr
  | CorePureBinary !CorePureBinOp !CorePureExpr !CorePureExpr
  | CorePureLet !(NonEmpty CorePureBinding) !CorePureExpr
  | CorePureIf !CorePureExpr !CorePureExpr !CorePureExpr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutorCall
  = ExecutorCallInline !QName !Record !CorePureExpr
  | ExecutorCallConfigured !Text !CorePureExpr
  | -- | New compatible surface: @\@executor@ with zero or one bare argument.
    ExecutorCallBare !QName !(Maybe CorePureExpr)
  | -- | A bare executor authority supplied through a kind/form parameter.
    ExecutorCallBoundBare !Text !(Maybe CorePureExpr)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data LetVisibility = LetPrivate | LetExported
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

data LetRhs
  = LetRhsWire !Expr
  | LetRhsCorePure !CorePureExpr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Import-statement variants (grammar §9.4).
data ImportSpec
  = {- | @import name from "path";@ — binds the file's file-return
    expression to @name@. Fails if the target file is declaration-only.
    -}
    ImportNamed !Text !Text
  | {- | @import { a, b, c } from "path";@ — binds explicit @let@ names
    from the target file.
    -}
    ImportExplicit ![Text] !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data UseItem
  = UseExecutor !Text !(Maybe Text)
  | UseContract !Text !(Maybe Text)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data UseSpec = UseSpec
  { useSpecNamespace :: !QName
  , useSpecItems :: !(NonEmpty UseItem)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data PureOutputEquation = PureOutputEquation
  { pureOutputEquationLabel :: !PortLabel
  , pureOutputEquationContract :: !ContractId
  , pureOutputEquationExpr :: !CorePureExpr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data NodePureResult
  = NodePureProduct !(NonEmpty PureOutputEquation)
  | NodePureSum !(NonEmpty SumVariant) !CorePureExpr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data NodePureBody = NodePureBody
  { nodePureBodyWhere :: !(Maybe CorePureExpr)
  , nodePureBodyResult :: !NodePureResult
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data NodeBody
  = NodeBodyExecutor !(Maybe CorePureExpr) !ExecutorCall
  | NodeBodyPure !NodePureBody
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | A node declaration binds a name to a specific node value. The body
contains an executor call or CorePure output equations that lower to the
native pure evaluator.
-}
data NodeDecl = NodeDecl
  { nodeDeclName :: !Text
  , nodeDeclMetadata :: !(Maybe Record)
  , nodeDeclPortSig :: ![PortDecl]
  , nodeDeclBody :: !NodeBody
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON NodeDecl where
  toJSON node =
    Aeson.object $
      [ "nodeDeclName" .= node.nodeDeclName
      , "nodeDeclPortSig" .= node.nodeDeclPortSig
      , "nodeDeclBody" .= node.nodeDeclBody
      ]
        <> foldMap (\metadata -> ["nodeDeclMetadata" .= metadata]) node.nodeDeclMetadata

-- | Contract declaration. A source contract may optionally carry a nominal record shape for `*`.
data ContractDecl = ContractDecl
  { contractDeclId :: !ContractId
  , contractDeclRecordFields :: !(Maybe [(Text, ContractId)])
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | One top-level form in a @.wire@ file.
data TopForm
  = -- | @contract Name;@ or @contract Name { field: Contract; };@.
    TopContract !ContractDecl
  | TopNode !NodeDecl
  | -- | @let name = rhs;@ or @export let name = rhs;@.
    TopLet !LetVisibility !Text !LetRhs
  | TopUse !UseSpec
  | TopImport !ImportSpec
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | A parsed @.wire@ file. The file-return is the final expression with
no trailing semicolon; if absent, the file is declaration-only (§9.6).
-}
data WireFile = WireFile
  { wireFileTopForms :: ![TopForm]
  , wireFileReturn :: !(Maybe Expr)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)
