{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Wire v1 abstract syntax tree.
--
-- Mirrors the grammar specified in
-- @docs/Reference/Wire/grammar-v1.md@ (accepted 2026-04-23). Each
-- production in §14 has a corresponding constructor here.
--
-- Structural rules, port-key matching, and runtime admission are not
-- represented in the AST: this module only captures surface syntax.
-- Static validation happens downstream in 'Cortex.Wire.V1.Parser' (shape)
-- and 'Cortex.Wire.V1.Compiler' (well-formedness + lowering).
module Cortex.Wire.V1.AST
  ( -- * Identifiers
    QName (..),
    renderQName,
    ContractId (..),
    PortLabel (..),

    -- * Port signatures
    PortDirection (..),
    PortArity (..),
    PortDecl (..),
    SumVariant (..),

    -- * Expressions
    Literal (..),
    Field (..),
    Record (..),
    SelectArm (..),
    Expr (..),

    -- * Top-level forms
    ImportSpec (..),
    NodeDecl (..),
    TopForm (..),
    WireFile (..),
  )
where

import Data.Aeson (ToJSON)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | Qualified identifier. One or more dot-joined segments, e.g.
-- @llm.analyst@, @cortex.deep_report@. A bare (single-segment) name is
-- still a 'QName'.
newtype QName = QName (NonEmpty Text)
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

renderQName :: QName -> Text
renderQName (QName segs) = T.intercalate "." (NE.toList segs)

-- | Contract names are flat and globally namespaced (grammar §4). Two
-- 'ContractId's are equal iff their text is equal.
newtype ContractId = ContractId {unContractId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Optional port label. 'NoLabel' is a distinct port key from @Label _@ —
-- not a wildcard (grammar §6.2).
data PortLabel = NoLabel | Label !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Direction of a port: input (@<-@) or output (@->@).
data PortDirection = PortInput | PortOutput
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Input-port arity (grammar §6.3).
--
-- - 'PortSingular' accepts at most one incoming edge.
-- - 'PortList' accepts zero or more, aggregated into a list at
--   evaluation time.
--
-- Output ports are always singular and carry no 'PortArity' in the AST.
data PortArity = PortSingular | PortList
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | One variant inside a sum-grouped output (grammar §6.5).
data SumVariant = SumVariant
  { svLabel :: !PortLabel,
    svContract :: !ContractId
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | A single port declaration as written in source.
--
-- Sum-grouped output ports are distinct from single-variant outputs; the
-- grouping carries runtime-visible mutual-exclusion metadata.
data PortDecl
  = PortInputDecl !PortLabel !ContractId !PortArity
  | PortOutputDecl !PortLabel !ContractId
  | -- | Sum-grouped output. Invariant: the NonEmpty list carries **two or
    -- more** variants; a one-variant sum is a syntax error at parse time.
    PortOutputSumDecl !(NonEmpty SumVariant)
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

-- | Literal values in the ordinary (non-wire) algebra.
data Literal
  = LitString !Text
  | -- | Multi-line verbatim string (@''...''@), preserved as a single
    -- 'Text' with embedded newlines; no escape processing.
    LitMultilineString !Text
  | LitNumber !Scientific
  | LitBool !Bool
  | -- | @()@ — the empty wire. Not valid at port positions.
    LitUnit
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | One field inside a record literal. 'fieldPath' supports dotted
-- keys (grammar §8.3), e.g. @render.aggregateOpenGaps = true;@.
data Field = Field
  { fieldPath :: !(NonEmpty Text),
    fieldValue :: !Expr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Record literal: an ordered sequence of fields. Order is not
-- semantically meaningful (records are unordered) but preserving it aids
-- diagnostics.
newtype Record = Record {recordFields :: [Field]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | One named arm in a postfix @select(...)@ expression (grammar §7.7 /
-- §14.3). The key is the variant identity token as written in source;
-- downstream semantic passes resolve it against labels/contracts on the
-- selector's exclusive output boundary.
data SelectArm = SelectArm
  { selectArmKey :: !Text,
    selectArmExpr :: !Expr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Unified expression form: both wire-kind and value-kind expressions
-- share one syntax; disambiguation is semantic, not syntactic (grammar
-- §14.3).
data Expr
  = -- | @a <> b@ — graph overlay (infixl 2).
    ExprOverlay !Expr !Expr
  | -- | @a => b@ — port-key-matched connect (infixl 3).
    ExprConnect !Expr !Expr
  | -- | @a // b@ — right-biased shallow merge on records or partial
    -- nodes (infixl 5).
    ExprMerge !Expr !Expr
  | -- | @a ++ b@ — string or list concatenation (infixl 5).
    ExprConcat !Expr !Expr
  | -- | @lhs select(A: a, B: b)@ — postfix conditional reduction over an
    -- exclusive output boundary (postfix 4).
    ExprSelect !Expr !(NonEmpty SelectArm)
  | -- | @\@qual.name { config }@ — partial-node producer.
    ExprApply !QName !Record
  | -- | @qual.name { field = ... }@ — tagged-record config constructor;
    -- no leading @\@@. Value-position only.
    ExprConstructor !QName !Record
  | ExprRecord !Record
  | ExprList ![Expr]
  | ExprLit !Literal
  | -- | Bare qualified identifier. May resolve to a let binding, an
    -- imported value, a contract name, or a registry-ambient name (tool,
    -- config constructor); context decides.
    ExprIdent !QName
  | -- | @(a, b, c)@ — tuple. In graph position overlays its elements;
    -- value position is invalid (grammar §7.5 / §14.4).
    --
    -- A single-element tuple @(a)@ is indistinguishable from
    -- parenthesization; the parser normalizes it to just the inner
    -- expression, so 'ExprTuple' always holds zero or two-or-more
    -- elements.
    ExprTuple ![Expr]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Import-statement variants (grammar §9.4).
data ImportSpec
  = -- | @import name from "path";@ — binds the file's file-return
    -- expression to @name@. Fails if the target file is declaration-only.
    ImportNamed !Text !Text
  | -- | @import { a, b, c } from "path";@ — binds explicit @let@ names
    -- from the target file.
    ImportExplicit ![Text] !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | A node declaration binds a name to a specific node value. The body
-- expression must evaluate to a partial node at pin time.
data NodeDecl = NodeDecl
  { nodeDeclName :: !Text,
    nodeDeclPortSig :: ![PortDecl],
    nodeDeclBody :: !Expr
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | One top-level form in a @.wire@ file.
data TopForm
  = -- | @contract Name;@ — idempotent ambient assertion.
    TopContract !ContractId
  | TopNode !NodeDecl
  | -- | @let name = expr;@ — module-level binding.
    TopLet !Text !Expr
  | TopImport !ImportSpec
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | A parsed @.wire@ file. The file-return is the final expression with
-- no trailing semicolon; if absent, the file is declaration-only (§9.6).
data WireFile = WireFile
  { wireFileTopForms :: ![TopForm],
    wireFileReturn :: !(Maybe Expr)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)
