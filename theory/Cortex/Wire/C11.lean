/-!
## Structured printable C11

This module is the untrusted-but-validated printable layer below
`Cortex.Wire.SemanticC`. It contains no arbitrary declaration or statement
escape hatch. A translation unit must pass executable structural validation
before the canonical renderer can derive its source, public header, exported
symbol inventory, and layout/resource manifest.
-/

namespace Cortex.Wire.C11

abbrev Name := String

inductive CType where
  | void
  | bool
  | char
  | int
  | u8
  | u32
  | u64
  | i64
  | f64
  | named (name : Name)
  | pointer (pointee : CType) (constPointee : Bool := false)
  | array (capacity : Nat) (element : CType)
  | namedArray (capacity : Name) (element : CType)
  | unsizedArray (element : CType)
  deriving Repr

inductive Visibility where
  | internal
  | exported
  deriving DecidableEq, Repr

inductive Storage where
  | automatic
  | static
  | extern
  deriving DecidableEq, Repr

inductive UnaryOp where
  | negate
  | logicalNot
  | bitNot
  | address
  | dereference
  | preIncrement
  deriving Repr

inductive BinaryOp where
  | multiply
  | divide
  | modulo
  | add
  | subtract
  | shiftLeft
  | shiftRight
  | less
  | lessEqual
  | greater
  | greaterEqual
  | equal
  | notEqual
  | bitAnd
  | bitXor
  | bitOr
  | logicalAnd
  | logicalOr
  deriving Repr

inductive Expr where
  | ident (name : Name)
  | signed (value : Int)
  | unsigned (value : Nat)
  | bool (value : Bool)
  | string (value : String)
  | character (value : Char)
  | null
  | unary (op : UnaryOp) (value : Expr)
  | binary (op : BinaryOp) (left right : Expr)
  | conditional (condition thenExpr elseExpr : Expr)
  | cast (ty : CType) (value : Expr)
  | call (function : Expr) (arguments : List Expr)
  | field (record : Expr) (name : Name)
  | pointerField (record : Expr) (name : Name)
  | index (array index : Expr)
  | postIncrement (value : Expr)
  | parenthesized (value : Expr)
  | sizeof (ty : CType)
  | alignof (ty : CType)
  | offsetof (ty : CType) (field : Name)
  deriving Repr

structure Local where
  name : Name
  ty : CType
  initial : Option Expr := none
  deriving Repr

inductive ForInit where
  | assign (target value : Expr)
  | local (declaration : Local)
  deriving Repr

mutual
  inductive Stmt where
    | block (statements : List Stmt)
    | local (declaration : Local)
    | evaluate (expression : Expr)
    | assign (target value : Expr)
    | branch (condition : Expr) (thenBody elseBody : List Stmt)
    | boundedFor (index : Name) (bound : Expr) (body : List Stmt)
    | forLoop (initial : ForInit) (condition step : Expr) (body : List Stmt)
    | forever (body : List Stmt)
    | switch (scrutinee : Expr) (cases : List SwitchCase) (defaultBody : List Stmt)
    | comment (lines : List String)
    | returnValue (value : Expr)
    | returnVoid
    | break
    | continue
    | trap
    deriving Repr

  structure SwitchCase where
    value : Expr
    body : List Stmt
    deriving Repr
end

structure Param where
  name : Name
  ty : CType
  deriving Repr

structure Field where
  name : Name
  ty : CType
  offset : Option Nat := none
  deriving Repr

structure StructDecl where
  name : Name
  fields : List Field
  visibility : Visibility := .internal
  emitTag : Bool := false
  deriving Repr

/-- A fixed C union. NativePure tagged sums use this rather than a byte blob so
the generated payload remains typed while retaining max-variant layout. -/
structure UnionDecl where
  name : Name
  fields : List Field
  visibility : Visibility := .internal
  emitTag : Bool := false
  deriving Repr

structure EnumMember where
  name : Name
  value : Int
  deriving Repr

structure EnumDecl where
  name : Name
  members : List EnumMember
  visibility : Visibility := .internal
  emitTag : Bool := false
  deriving Repr

structure TypedefDecl where
  name : Name
  target : CType
  visibility : Visibility := .internal
  deriving Repr

structure FunctionTypedef where
  name : Name
  result : CType
  params : List Param
  visibility : Visibility := .internal
  deriving Repr

inductive TypeDecl where
  | define (name : Name) (value : Expr)
  | alias (declaration : TypedefDecl)
  | functionAlias (declaration : FunctionTypedef)
  | enumeration (declaration : EnumDecl)
  | structure (declaration : StructDecl)
  | union (declaration : UnionDecl)
  deriving Repr

inductive Initializer where
  | expression (value : Expr)
  | list (values : List Expr)
  deriving Repr

structure Global where
  name : Name
  ty : CType
  storage : Storage := .static
  isConst : Bool := false
  initial : Option Initializer := none
  visibility : Visibility := .internal
  blankAfter : Bool := false
  deriving Repr

/-- Optional concrete whitespace for compatibility profiles. It cannot add,
remove, or change any C token produced by the structured AST. -/
structure ConcreteLayout where
  gaps : List String
  deriving Repr

structure CFunction where
  name : Name
  result : CType
  params : List Param
  body : Option (List Stmt) := none
  visibility : Visibility := .internal
  comments : List String := []
  headerComments : List String := []
  headerParams : Option (List Param) := none
  concreteLayout : Option ConcreteLayout := none
  deriving Repr

structure StaticAssert where
  condition : Expr
  message : String
  deriving Repr

structure LayoutField where
  name : Name
  offset : Nat
  size : Nat
  deriving Repr

structure Layout where
  name : Name
  size : Nat
  alignment : Nat
  fields : List LayoutField := []
  deriving Repr

structure Resource where
  name : Name
  value : Nat
  deriving Repr

/-- One structured module is the source of every emitted artifact. -/
structure TranslationUnit where
  schema : String
  identity : String
  headerGuard : Name
  headerIncludes : List String := ["stdbool.h", "stddef.h", "stdint.h"]
  localHeader : String := "program.h"
  headerLayout : Option ConcreteLayout := none
  includes : List String := []
  defines : List (Name × Expr) := []
  orderedTypes : List TypeDecl := []
  typedefs : List TypedefDecl := []
  functionTypedefs : List FunctionTypedef := []
  enums : List EnumDecl := []
  structs : List StructDecl := []
  unions : List UnionDecl := []
  globals : List Global := []
  functions : List CFunction := []
  assertions : List StaticAssert := []
  layouts : List Layout := []
  resources : List Resource := []
  deriving Repr

/-- Constructor is private so rendering APIs can require validation. -/
structure ValidatedTranslationUnit where
  private mk ::
  unit : TranslationUnit

private def cKeywords : List String :=
  [ "auto", "break", "case", "char", "const", "continue", "default", "do", "double"
  , "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long"
  , "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct"
  , "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Alignas"
  , "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn"
  , "_Static_assert", "_Thread_local"
  ]

/-- Names the rendered prelude itself introduces (`stdbool.h`, `stddef.h`,
`stdint.h` macros and typedefs); authored identifiers must not collide. -/
private def preludeNames : List String :=
  [ "true", "false", "bool", "NULL", "offsetof", "size_t", "ptrdiff_t"
  , "int8_t", "int16_t", "int32_t", "int64_t"
  , "uint8_t", "uint16_t", "uint32_t", "uint64_t"
  , "intptr_t", "uintptr_t"
  ]

private def asciiLetter (char : Char) : Bool :=
  ('a' ≤ char && char ≤ 'z') || ('A' ≤ char && char ≤ 'Z')

private def asciiDigit (char : Char) : Bool :=
  '0' ≤ char && char ≤ '9'

def validIdentifier (name : Name) : Bool :=
  match name.toList with
  | [] => false
  | first :: rest =>
      (first == '_' || asciiLetter first) &&
        rest.all (fun char => char == '_' || asciiLetter char || asciiDigit char) &&
          !cKeywords.contains name

/-- Identifier rule for declaration positions. Expressions may reference
reserved names (calling `__builtin_add_overflow` is deliberate), but declaring
one would shadow the implementation or prelude namespace: identifiers starting
with an underscore and an uppercase letter or with a double underscore are
reserved (C11 7.1.3), and the prelude macro/typedef names would be redefined.
-/
def declarableIdentifier (name : Name) : Bool :=
  validIdentifier name && !preludeNames.contains name &&
    (match name.toList with
     | '_' :: next :: _ => !(next == '_' || ('A' ≤ next && next ≤ 'Z'))
     | [] => true
     | [_] => true
     | _ :: _ :: _ => true)

private def isArrayType : CType → Bool
  | .array _ _ | .namedArray _ _ | .unsizedArray _ => true
  | .void | .bool | .char | .int | .u8 | .u32 | .u64 | .i64 | .f64 => false
  | .named _ | .pointer _ _ => false

private def typeValid : CType → Bool
  | .void | .bool | .char | .int | .u8 | .u32 | .u64 | .i64 | .f64 => true
  | .named name => validIdentifier name
  -- Pointer-to-array needs an inside-out declarator the renderer does not
  -- produce; flattening it to pointer-to-element would silently change the
  -- type, so it is rejected instead.
  | .pointer pointee _ => !isArrayType pointee && typeValid pointee
  | .array capacity element => 0 < capacity && typeValid element
  | .namedArray capacity element => validIdentifier capacity && typeValid element
  | .unsizedArray element => typeValid element

private def exprValidFuel : Nat → Expr → Bool
  | 0, _ => false
  | fuel + 1, expression =>
      let valid := exprValidFuel fuel
      match expression with
      | .ident name => validIdentifier name
      | .signed value => -(2 ^ 63) ≤ value && value < 2 ^ 63
      | .unsigned value => value < 2 ^ 64
      | .bool _ | .string _ | .character _ | .null => true
      | .unary _ value => valid value
      | .binary _ left right => valid left && valid right
      | .conditional condition thenExpr elseExpr =>
          valid condition && valid thenExpr && valid elseExpr
      | .cast ty value => typeValid ty && !isArrayType ty && valid value
      | .call function arguments => valid function && arguments.all valid
      | .field record name | .pointerField record name =>
          valid record && validIdentifier name
      | .index arrayExpr indexExpr => valid arrayExpr && valid indexExpr
      | .postIncrement value => valid value
      | .parenthesized value => valid value
      | .sizeof ty | .alignof ty => typeValid ty
      | .offsetof ty field => typeValid ty && validIdentifier field

private def exprValid (expression : Expr) : Bool :=
  exprValidFuel (reprStr expression).length expression

private def safeComment (comment : String) : Bool :=
  !comment.contains "*/" &&
    comment.toList.all fun char => char != '\n' && char != '\r'

private def concreteLayoutValid (layout : ConcreteLayout) : Bool :=
  layout.gaps.all fun gap =>
    gap.toList.all fun char =>
      char == ' ' || char == '\t' || char == '\n' || char == '\r'

private def stmtValidFuel : Nat → Stmt → Bool
  | 0, _ => false
  | fuel + 1, statement =>
      let statementsValid (statements : List Stmt) :=
        statements.all (stmtValidFuel fuel)
      match statement with
      | .block statements => statementsValid statements
      | .local declaration =>
          validIdentifier declaration.name && typeValid declaration.ty &&
            declaration.initial.all exprValid
      | .evaluate expression => exprValid expression
      | .assign target value => exprValid target && exprValid value
      | .branch condition thenBody elseBody =>
          exprValid condition && statementsValid thenBody && statementsValid elseBody
      | .boundedFor index bound body =>
          validIdentifier index && exprValid bound && statementsValid body
      | .forLoop initial condition step body =>
          (match initial with
           | .assign target value => exprValid target && exprValid value
           | .local declaration =>
               validIdentifier declaration.name && typeValid declaration.ty &&
                 declaration.initial.all exprValid) &&
            exprValid condition && exprValid step && statementsValid body
      | .forever body => statementsValid body
      | .switch scrutinee cases defaultBody =>
          -- C11 labels must precede statements: a declaration directly after a
          -- `case`/`default` label (authors wrap one in a `.block`) and a
          -- trailing empty case with no default are rejected rather than
          -- rendered invalid.
          let headNotDeclaration (body : List Stmt) : Bool :=
            match body.head? with
            | some (.local _) => false
            | some _ => true
            | none => true
          exprValid scrutinee &&
            cases.all (fun switchCase =>
              exprValid switchCase.value && statementsValid switchCase.body &&
                headNotDeclaration switchCase.body) &&
            statementsValid defaultBody && headNotDeclaration defaultBody &&
            (!defaultBody.isEmpty ||
              (match cases.getLast? with
               | some lastCase => !lastCase.body.isEmpty
               | none => true))
      | .returnValue value => exprValid value
      | .comment lines => lines.all safeComment
      | .returnVoid | .break | .continue | .trap => true

private def statementsValid (statements : List Stmt) : Bool :=
  let fuel := (reprStr statements).length
  statements.all (stmtValidFuel fuel)

private def unique : List String → Bool
  | [] => true
  | name :: rest => !rest.contains name && unique rest

private def fieldNamesValid (fields : List Field) : Bool :=
  fields.all (declarableIdentifier ·.name) && unique (fields.map (·.name))

private def paramsValid (params : List Param) : Bool :=
  params.all (declarableIdentifier ·.name) && unique (params.map (·.name))

private def exportedNames (unit : TranslationUnit) : List Name :=
  (unit.globals.filter fun global : Global =>
    global.visibility == Visibility.exported).map Global.name ++
  (unit.functions.filter fun function : CFunction =>
    function.visibility == Visibility.exported).map CFunction.name

private def declaredNames (unit : TranslationUnit) : List Name :=
  unit.orderedTypes.map (fun
    | .define name _ => name
    | .alias declaration => declaration.name
    | .functionAlias declaration => declaration.name
    | .enumeration declaration => declaration.name
    | .structure declaration => declaration.name
    | .union declaration => declaration.name) ++
  -- Enum members share the ordinary identifier namespace with functions and
  -- globals, so they participate in top-level uniqueness.
  (unit.orderedTypes.flatMap fun
    | .enumeration declaration => declaration.members.map (·.name)
    | .define _ _ => []
    | .alias _ => []
    | .functionAlias _ => []
    | .structure _ => []
    | .union _ => []) ++
  unit.enums.flatMap (fun declaration => declaration.members.map (·.name)) ++
  unit.typedefs.map (·.name) ++ unit.functionTypedefs.map (·.name) ++
    unit.enums.map (·.name) ++ unit.structs.map (·.name) ++ unit.unions.map (·.name) ++
      unit.globals.map (·.name) ++ unit.functions.map (·.name)

private def safeInclude (header : String) : Bool :=
  !header.isEmpty && header.toList.all fun char =>
    char != '<' && char != '>' && char != '"' && char != '\n' && char != '\r'

private def layoutValid (layout : Layout) : Bool :=
  validIdentifier layout.name && 0 < layout.alignment &&
    layout.fields.all (fun field : LayoutField =>
      validIdentifier field.name && field.offset + field.size ≤ layout.size) &&
    unique (layout.fields.map LayoutField.name)


private def octalDigit (value : Nat) : Char :=
  Char.ofNat ('0'.toNat + value % 8)

/-- Fixed-width three-digit octal escape: a following literal digit can never
be absorbed into the escape, unlike `\0` or variable-width forms. -/
private def octalEscape (value : Nat) : String :=
  String.ofList ['\\', octalDigit (value / 64), octalDigit (value / 8), octalDigit value]

private def escapeCChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | '\x08' => "\\b"
  | '\x0c' => "\\f"
  | char =>
      if char.toNat < 0x20 || char.toNat == 0x7f then octalEscape char.toNat
      else String.singleton char

/-- Escape one char for a C character literal; a bare `'` must not close it.
A char literal ends at the closing quote, so `\0` cannot absorb a following
digit the way it can inside a string literal. -/
private def escapeCCharLiteral (char : Char) : String :=
  if char == '\'' then "\\'"
  else if char == '\x00' then "\\0"
  else escapeCChar char

/-- String-literal escaping. The second `?` of every `??` pair is escaped so a
conforming trigraph-processing translator cannot rewrite the literal. The
tail-recursive fold keeps compiled evaluation stack-safe on long literals. -/
def escapeC (value : String) : String :=
  let step (state : String × Bool) (char : Char) : String × Bool :=
    let (escaped, previousQuestion) := state
    if char == '?' && previousQuestion then (escaped ++ "\\?", false)
    else (escaped ++ escapeCChar char, char == '?')
  (value.toList.foldl step ("", false)).1

private def escapeJsonChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | '\x08' => "\\b"
  | '\x0c' => "\\f"
  | char =>
      if char.toNat < 0x20 then
        let hexDigit (value : Nat) : Char :=
          if value % 16 < 10 then Char.ofNat ('0'.toNat + value % 16)
          else Char.ofNat ('a'.toNat + value % 16 - 10)
        String.ofList ['\\', 'u', '0', '0', hexDigit (char.toNat / 16), hexDigit char.toNat]
      else String.singleton char

def escapeJson (value : String) : String :=
  String.join (value.toList.map escapeJsonChar)

private def tokenTail (char : Char) : Bool :=
  char == '_' || asciiLetter char || asciiDigit char || char == '.'

private def takeTokenTail : List Char → List Char × List Char
  | [] => ([], [])
  | char :: rest =>
      if tokenTail char then
        let (token, remaining) := takeTokenTail rest
        (char :: token, remaining)
      else ([], char :: rest)

private def takeQuoted (quote : Char) : List Char → List Char → Bool → List Char × List Char
  | [], reversed, _ => (reversed.reverse, [])
  | char :: rest, reversed, escaped =>
      if escaped then takeQuoted quote rest (char :: reversed) false
      else if char == '\\' then takeQuoted quote rest (char :: reversed) true
      else if char == quote then ((char :: reversed).reverse, rest)
      else takeQuoted quote rest (char :: reversed) false

private def takeBlockComment : List Char → List Char → List Char × List Char
  | [], reversed => (reversed.reverse, [])
  | '*' :: '/' :: rest, reversed => (('/' :: '*' :: reversed).reverse, rest)
  | char :: rest, reversed => takeBlockComment rest (char :: reversed)

private def twoCharacterToken (left right : Char) : Bool :=
  [ "->", "++", "--", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>"
  , "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="
  ].contains (String.ofList [left, right])

private def scanConcreteFuel :
    Nat → List Char → List Char → List String → List String → Option (List String × List String)
  | 0, [], reversedGap, reversedTokens, reversedGaps =>
      some (reversedTokens.reverse, (String.ofList reversedGap.reverse :: reversedGaps).reverse)
  | 0, _ :: _, _, _, _ => none
  | _ + 1, [], reversedGap, reversedTokens, reversedGaps =>
      some (reversedTokens.reverse, (String.ofList reversedGap.reverse :: reversedGaps).reverse)
  | fuel + 1, char :: rest, reversedGap, reversedTokens, reversedGaps =>
      if char == ' ' || char == '\t' || char == '\n' || char == '\r' then
        scanConcreteFuel fuel rest (char :: reversedGap) reversedTokens reversedGaps
      else
        let gap := String.ofList reversedGap.reverse
        let (tokenChars, remaining) :=
          if asciiLetter char || char == '_' || asciiDigit char then
            let (tail, after) := takeTokenTail rest
            (char :: tail, after)
          else if char == '"' || char == '\'' then
            takeQuoted char rest [char] false
          else
            match char, rest with
            | '/', '*' :: after => takeBlockComment after ['*', '/']
            | left, right :: after =>
                if twoCharacterToken left right then ([left, right], after)
                else ([left], right :: after)
            | single, [] => ([single], [])
        scanConcreteFuel fuel remaining [] (String.ofList tokenChars :: reversedTokens)
          (gap :: reversedGaps)

private def scanConcrete (rendered : String) : Option (List String × List String) :=
  scanConcreteFuel (rendered.length + 1) rendered.toList [] [] []

private def interleaveConcrete : List String → List String → Option String
  | [gap], [] => some gap
  | gap :: gaps, token :: tokens =>
      (interleaveConcrete gaps tokens).map fun rest => gap ++ token ++ rest
  | _, _ => none

private def applyConcreteLayout (layout : Option ConcreteLayout) (rendered : String) : String :=
  match layout, scanConcrete rendered with
  | some concrete, some (tokens, _) =>
      (interleaveConcrete concrete.gaps tokens).getD rendered
  | none, _ | _, none => rendered

/-- Inclusive token-index spans of preprocessor directive lines in a canonical
rendering. The renderer never emits a newline inside a token, so per-line
scanning concatenates to the full scan. -/
private def directiveSpans (canonical : String) : List (Nat × Nat) :=
  let step (state : Nat × List (Nat × Nat)) (line : String) : Nat × List (Nat × Nat) :=
    let (index, spans) := state
    match scanConcrete line with
    | some (tokens, _) =>
        let count := tokens.length
        let startsDirective :=
          (line.toList.dropWhile fun char =>
            char == ' ' || char == '	' || char == '
').head? == some '#'
        if 0 < count && startsDirective then
          (index + count, (index, index + count - 1) :: spans)
        else (index + count, spans)
    | none => (index, spans)
  ((canonical.splitOn "
").foldl step (0, [])).2.reverse

/-- Enforce the ConcreteLayout contract mechanically: gap arity must match the
token stream, the interleaved output must re-scan to the identical token list
(no fusion, no comment formation), and no gap interior to a preprocessor
directive line may contain a newline. -/
private def checkConcreteLayout
    (layout : Option ConcreteLayout) (canonical : String) : Except String Unit := do
  match layout with
  | none => pure ()
  | some concrete =>
      match scanConcrete canonical with
      | none => throw "concrete layout target failed token scanning"
      | some (tokens, _) =>
          match interleaveConcrete concrete.gaps tokens with
          | none => throw "concrete layout gap count does not match the token stream"
          | some applied =>
              match scanConcrete applied with
              | none => throw "concrete layout produces an unscannable rendering"
              | some (appliedTokens, _) =>
                  if appliedTokens != tokens then
                    throw "concrete layout alters the C token stream"
                  let gapHasNewline (gap : String) : Bool :=
                    gap.toList.any fun char => char == '
' || char == '
'
                  let splitsDirective :=
                    (directiveSpans canonical).any fun span =>
                      (List.range (span.2 - span.1)).any fun offset =>
                        match concrete.gaps[span.1 + 1 + offset]? with
                        | some gap => gapHasNewline gap
                        | none => false
                  if splitsDirective then
                    throw "concrete layout splits a preprocessor directive"
                  pure ()

private def renderBaseType : CType → String
  | .void => "void"
  | .bool => "bool"
  | .char => "char"
  | .int => "int"
  | .u8 => "uint8_t"
  | .u32 => "uint32_t"
  | .u64 => "uint64_t"
  | .i64 => "int64_t"
  | .f64 => "double"
  | .named name => name
  | .pointer pointee constPointee =>
      (if constPointee then "const " else "") ++ renderBaseType pointee ++ " *"
  | .array _ element => renderBaseType element
  | .namedArray _ element => renderBaseType element
  | .unsizedArray element => renderBaseType element

def renderDeclaration : CType → Name → String
  | .array capacity element, name => renderDeclaration element s!"{name}[{capacity}u]"
  | .namedArray capacity element, name => renderDeclaration element s!"{name}[{capacity}]"
  | .unsizedArray element, name => renderDeclaration element s!"{name}[]"
  | .pointer pointee constPointee, name =>
      let rendered :=
        (if constPointee then "const " else "") ++ renderBaseType pointee ++ " *"
      rendered ++ name
  | ty, name => renderBaseType ty ++ (if name.isEmpty then "" else " " ++ name)

private def unaryToken : UnaryOp → String
  | .negate => "-"
  | .logicalNot => "!"
  | .bitNot => "~"
  | .address => "&"
  | .dereference => "*"
  | .preIncrement => "++"

private def binaryToken : BinaryOp → String
  | .multiply => "*"
  | .divide => "/"
  | .modulo => "%"
  | .add => "+"
  | .subtract => "-"
  | .shiftLeft => "<<"
  | .shiftRight => ">>"
  | .less => "<"
  | .lessEqual => "<="
  | .greater => ">"
  | .greaterEqual => ">="
  | .equal => "=="
  | .notEqual => "!="
  | .bitAnd => "&"
  | .bitXor => "^"
  | .bitOr => "|"
  | .logicalAnd => "&&"
  | .logicalOr => "||"

private def binaryPrecedence : BinaryOp → Nat
  | .multiply | .divide | .modulo => 13
  | .add | .subtract => 12
  | .shiftLeft | .shiftRight => 11
  | .less | .lessEqual | .greater | .greaterEqual => 10
  | .equal | .notEqual => 9
  | .bitAnd => 8
  | .bitXor => 7
  | .bitOr => 6
  | .logicalAnd => 5
  | .logicalOr => 4

private def exprPrecedence : Expr → Nat
  | .conditional _ _ _ => 3
  | .binary op _ _ => binaryPrecedence op
  | .unary _ _ | .cast _ _ => 14
  | .ident _ | .signed _ | .unsigned _ | .bool _ | .string _ | .character _ | .null |
    .call _ _ | .field _ _ | .pointerField _ _ | .index _ _ | .postIncrement _ |
    .parenthesized _ | .sizeof _ | .alignof _ | .offsetof _ _ => 15

private def renderExprFuel : Nat → Nat → Expr → String
  | 0, _, _ => ""
  | fuel + 1, parent, expression =>
      let renderAt := renderExprFuel fuel
      let precedence := exprPrecedence expression
      let rendered :=
        match expression with
        | .ident name => name
        | .signed value =>
            -- The magnitude of INT64_MIN is not a valid C11 constant; render
            -- the standard subtraction form instead.
            if value == -(2 ^ 63) then "(-9223372036854775807 - 1)"
            else toString value
        | .unsigned value => s!"{value}u"
        | .bool true => "true"
        | .bool false => "false"
        | .string value => "\"" ++ escapeC value ++ "\""
        | .character value => "'" ++ escapeCCharLiteral value ++ "'"
        | .null => "NULL"
        | .unary op value =>
            let token := unaryToken op
            let operand := renderAt 14 value
            -- A separating space keeps adjacent tokens from fusing into a
            -- different operator: `- -x` must never render as `--x`.
            let fuses :=
              match token.toList.getLast?, operand.toList.head? with
              | some tail, some head =>
                  (tail == '-' && head == '-') || (tail == '+' && head == '+') ||
                    (tail == '&' && head == '&')
              | _, _ => false
            token ++ (if fuses then " " else "") ++ operand
        | .binary op left right =>
            let precedence := binaryPrecedence op
            renderAt precedence left ++ " " ++ binaryToken op ++ " " ++
              renderAt (precedence + 1) right
        | .conditional condition thenExpr elseExpr =>
            renderAt 4 condition ++ " ? " ++ renderAt 3 thenExpr ++ " : " ++
              renderAt 3 elseExpr
        | .cast ty value => "(" ++ renderDeclaration ty "" ++ ")" ++ renderAt 14 value
        | .call function arguments =>
            renderAt 15 function ++ "(" ++
              String.intercalate ", " (arguments.map (renderAt 0)) ++ ")"
        | .field record name => renderAt 15 record ++ "." ++ name
        | .pointerField record name => renderAt 15 record ++ "->" ++ name
        | .index arrayExpr indexExpr =>
            renderAt 15 arrayExpr ++ "[" ++ renderAt 0 indexExpr ++ "]"
        | .postIncrement value => renderAt 15 value ++ "++"
        | .parenthesized value => "(" ++ renderAt 0 value ++ ")"
        | .sizeof ty => "sizeof(" ++ renderDeclaration ty "" ++ ")"
        | .alignof ty => "_Alignof(" ++ renderDeclaration ty "" ++ ")"
        | .offsetof ty field =>
            "offsetof(" ++ renderDeclaration ty "" ++ ", " ++ field ++ ")"
      if precedence < parent then "(" ++ rendered ++ ")" else rendered

def renderExpr (expression : Expr) : String :=
  renderExprFuel (reprStr expression).length 0 expression

private def indentation (depth : Nat) : String :=
  String.ofList (List.replicate (depth * 2) ' ')

private def renderStmtFuel : Nat → Nat → Stmt → String
  | 0, _, _ => ""
  | fuel + 1, depth, statement =>
      let renderList (nestedDepth : Nat) (statements : List Stmt) :=
        String.join (statements.map (renderStmtFuel fuel nestedDepth))
      let renderBlock (nestedDepth : Nat) (statements : List Stmt) :=
        "{\n" ++ renderList (nestedDepth + 1) statements ++ indentation nestedDepth ++ "}"
      match statement with
      | .block statements => indentation depth ++ renderBlock depth statements ++ "\n"
      | .local declaration =>
          indentation depth ++ renderDeclaration declaration.ty declaration.name ++
            (declaration.initial.map (" = " ++ renderExpr ·)).getD "" ++ ";\n"
      | .evaluate expression => indentation depth ++ renderExpr expression ++ ";\n"
      | .assign target value =>
          indentation depth ++ renderExpr target ++ " = " ++ renderExpr value ++ ";\n"
      | .branch condition thenBody elseBody =>
          indentation depth ++ "if (" ++ renderExpr condition ++ ") " ++
            renderBlock depth thenBody ++
            (if elseBody.isEmpty then "\n"
             else " else " ++ renderBlock depth elseBody ++ "\n")
      | .boundedFor index bound body =>
          indentation depth ++ "for (uint64_t " ++ index ++ " = 0u; " ++ index ++ " < " ++
            renderExpr bound ++ "; ++" ++ index ++ ") " ++ renderBlock depth body ++ "\n"
      | .forLoop initial condition step body =>
          let renderedInitial :=
            match initial with
            | .assign target value => renderExpr target ++ " = " ++ renderExpr value
            | .local declaration =>
                renderDeclaration declaration.ty declaration.name ++
                  (declaration.initial.map (" = " ++ renderExpr ·)).getD ""
          indentation depth ++ "for (" ++ renderedInitial ++ "; " ++ renderExpr condition ++
            "; " ++ renderExpr step ++ ") " ++ renderBlock depth body ++ "\n"
      | .forever body => indentation depth ++ "for (;;) " ++ renderBlock depth body ++ "\n"
      | .switch scrutinee cases defaultBody =>
          let renderCase (switchCase : SwitchCase) :=
            indentation (depth + 1) ++ "case " ++ renderExpr switchCase.value ++ ":\n" ++
              renderList (depth + 2) switchCase.body
          indentation depth ++ "switch (" ++ renderExpr scrutinee ++ ") {\n" ++
            String.join (cases.map renderCase) ++
            (if defaultBody.isEmpty then ""
             else indentation (depth + 1) ++ "default:\n" ++
               renderList (depth + 2) defaultBody) ++
            indentation depth ++ "}\n"
      | .returnValue value => indentation depth ++ "return " ++ renderExpr value ++ ";\n"
      | .comment lines =>
          match lines with
          | [] => ""
          | first :: rest =>
              indentation depth ++ "/* " ++ first ++
                (if rest.isEmpty then " */\n"
                 else "\n" ++ String.intercalate "\n" (rest.map fun line =>
                   indentation depth ++ " * " ++ line) ++ " */\n")
      | .returnVoid => indentation depth ++ "return;\n"
      | .break => indentation depth ++ "break;\n"
      | .continue => indentation depth ++ "continue;\n"
      | .trap => indentation depth ++ "__builtin_trap();\n"

private def renderStmtList (depth : Nat) (statements : List Stmt) : String :=
  let fuel := (reprStr statements).length
  String.join (statements.map (renderStmtFuel fuel depth))

private def renderBlock (depth : Nat) (statements : List Stmt) : String :=
  "{\n" ++ renderStmtList (depth + 1) statements ++ indentation depth ++ "}"

private def renderParams (params : List Param) : String :=
  if params.isEmpty then "void"
  else String.intercalate ", " (params.map fun param => renderDeclaration param.ty param.name)

private def renderStruct (decl : StructDecl) : String :=
  "typedef struct" ++ (if decl.emitTag then " " ++ decl.name else "") ++ " {\n" ++
    String.join (decl.fields.map fun field =>
      "  " ++ renderDeclaration field.ty field.name ++ ";\n") ++
    "} " ++ decl.name ++ ";\n\n"

private def renderUnion (decl : UnionDecl) : String :=
  "typedef union" ++ (if decl.emitTag then " " ++ decl.name else "") ++ " {\n" ++
    String.join (decl.fields.map fun field =>
      "  " ++ renderDeclaration field.ty field.name ++ ";\n") ++
    "} " ++ decl.name ++ ";\n\n"

private def renderEnum (decl : EnumDecl) : String :=
  "typedef enum" ++ (if decl.emitTag then " " ++ decl.name else "") ++ " {\n" ++
    String.intercalate ",\n" (decl.members.map fun member =>
      "  " ++ member.name ++ " = " ++ toString member.value) ++ "\n} " ++ decl.name ++ ";\n\n"

private def renderTypedef (decl : TypedefDecl) : String :=
  "typedef " ++ renderDeclaration decl.target decl.name ++ ";\n"

private def renderFunctionTypedef (decl : FunctionTypedef) : String :=
  "typedef " ++ renderDeclaration decl.result "" ++ " (*" ++ decl.name ++ ")(" ++
    renderParams decl.params ++ ");\n"

private def typeDeclVisibility : TypeDecl → Visibility
  | .define _ _ => .exported
  | .alias declaration => declaration.visibility
  | .functionAlias declaration => declaration.visibility
  | .enumeration declaration => declaration.visibility
  | .structure declaration => declaration.visibility
  | .union declaration => declaration.visibility

/-- Macro bodies below primary precedence are parenthesized so use-site
context cannot re-associate the expansion. -/
private def renderDefineBody (value : Expr) : String :=
  if exprPrecedence value == 15 then renderExpr value
  else "(" ++ renderExpr value ++ ")"

private def renderTypeDecl : TypeDecl → String
  | .define name value => "#define " ++ name ++ " " ++ renderDefineBody value ++ "\n\n"
  | .alias declaration => renderTypedef declaration
  | .functionAlias declaration => renderFunctionTypedef declaration
  | .enumeration declaration => renderEnum declaration
  | .structure declaration => renderStruct declaration
  | .union declaration => renderUnion declaration

private def renderPrototype (function : CFunction) : String :=
  String.join (function.headerComments.map fun comment => "/* " ++ comment ++ " */\n") ++
    renderDeclaration function.result "" ++ " " ++ function.name ++ "(" ++
    renderParams (function.headerParams.getD function.params) ++ ");\n"

private def renderFunctionCanonical (function : CFunction) : String :=
  match function.body with
  | none => renderPrototype function
  | some body =>
      String.join (function.comments.map fun comment => "/* " ++ comment ++ " */\n") ++
        (if function.visibility == .internal then "static " else "") ++
        renderDeclaration function.result "" ++ " " ++ function.name ++ "(" ++
        renderParams function.params ++ ") " ++
        renderBlock 0 body ++ "\n\n"

private def renderFunction (function : CFunction) : String :=
  applyConcreteLayout function.concreteLayout (renderFunctionCanonical function)

private def renderGlobal (global : Global) : String :=
  (match global.storage with | .automatic => "" | .static => "static " | .extern => "extern ") ++
    (if global.isConst then "const " else "") ++
    renderDeclaration global.ty global.name ++
    (global.initial.map fun
      | .expression value => " = " ++ renderExpr value
      | .list values => " = {" ++ String.intercalate ", " (values.map renderExpr) ++ "}").getD "" ++
    ";\n" ++ (if global.blankAfter then "\n" else "")

private def renderGlobalExtern (global : Global) : String :=
  "extern " ++ renderDeclaration global.ty global.name ++ ";\n"

private def renderAssertion (assertion : StaticAssert) : String :=
  "_Static_assert(" ++ renderExpr assertion.condition ++ ", \"" ++
    escapeC assertion.message ++ "\");\n"

private def renderTypeDecls (unit : TranslationUnit) (publicOnly : Bool) : String :=
  let visible (visibility : Visibility) :=
    if publicOnly then visibility == .exported else visibility == .internal
  if unit.orderedTypes.isEmpty then
    String.join ((unit.typedefs.filter fun declaration =>
      visible declaration.visibility).map renderTypedef) ++
      String.join ((unit.functionTypedefs.filter fun declaration =>
        visible declaration.visibility).map renderFunctionTypedef) ++
      (if unit.typedefs.isEmpty && unit.functionTypedefs.isEmpty then "" else "\n") ++
      String.join ((unit.enums.filter fun declaration =>
        visible declaration.visibility).map renderEnum) ++
      String.join ((unit.structs.filter fun declaration =>
        visible declaration.visibility).map renderStruct) ++
      String.join ((unit.unions.filter fun declaration =>
        visible declaration.visibility).map renderUnion)
  else
    String.join ((unit.orderedTypes.filter fun declaration =>
      visible (typeDeclVisibility declaration)).map renderTypeDecl)

private def renderHeaderCanonicalUnit (unit : TranslationUnit) : String :=
  "#ifndef " ++ unit.headerGuard ++ "\n#define " ++ unit.headerGuard ++ "\n\n" ++
    String.join (unit.headerIncludes.map fun header => "#include <" ++ header ++ ">\n") ++ "\n" ++
    "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n" ++
    renderTypeDecls unit true ++
    String.join ((unit.globals.filter fun global : Global =>
      global.visibility == Visibility.exported).map renderGlobalExtern) ++
    String.join ((unit.functions.filter fun function : CFunction =>
      function.visibility == Visibility.exported).map renderPrototype) ++
    "\n#ifdef __cplusplus\n}\n#endif\n\n#endif\n"

def validate (unit : TranslationUnit) : Except String ValidatedTranslationUnit := do
  if unit.schema.isEmpty then throw "translation-unit schema must not be empty"
  if unit.identity.isEmpty then throw "translation-unit identity must not be empty"
  if !validIdentifier unit.headerGuard then throw "invalid header guard"
  if !unit.includes.all safeInclude then throw "invalid system include"
  if !unit.headerIncludes.all safeInclude then throw "invalid header include"
  if unit.localHeader.isEmpty || !safeInclude unit.localHeader then throw "invalid local header"
  if !unique (unit.defines.map Prod.fst ++ declaredNames unit) then
    throw "duplicate top-level C identifier"
  if !(declaredNames unit).all declarableIdentifier then throw "invalid top-level C identifier"
  if !unit.defines.all (declarableIdentifier ·.1) then throw "invalid preprocessor identifier"
  if !unique (unit.defines.map (·.1)) then throw "duplicate preprocessor identifier"
  if !unit.defines.all (exprValid ·.2) then throw "invalid preprocessor expression"
  if !unit.structs.all (fieldNamesValid ·.fields) then throw "invalid or duplicate struct field"
  if !unit.structs.all (fun declaration => declaration.fields.all (typeValid ·.ty)) then
    throw "invalid struct field type"
  if !unit.unions.all (fieldNamesValid ·.fields) then throw "invalid or duplicate union field"
  if !unit.unions.all (fun declaration =>
      !declaration.fields.isEmpty && declaration.fields.all (typeValid ·.ty)) then
    throw "invalid union field type"
  if !unit.enums.all (fun declaration =>
      !declaration.members.isEmpty &&
        declaration.members.all (validIdentifier ·.name) &&
        unique (declaration.members.map (·.name))) then
    throw "invalid enum declaration"
  if !unit.functions.all (fun function : CFunction => paramsValid function.params) then
    throw "invalid or duplicate function parameter"
  if !unit.functionTypedefs.all (fun function : FunctionTypedef => paramsValid function.params) then
    throw "invalid or duplicate function-typedef parameter"
  if !unit.typedefs.all (typeValid ·.target) then throw "invalid typedef target"
  if !unit.functionTypedefs.all (fun function =>
      typeValid function.result && function.params.all (typeValid ·.ty)) then
    throw "invalid function-typedef type"
  if !unit.globals.all (fun global =>
      typeValid global.ty && global.initial.all fun
        | .expression value => exprValid value
        | .list values => values.all exprValid) then
    throw "invalid global declaration"
  -- An exported global with internal linkage (or an internal extern
  -- declaration with no definition) has no coherent linkage in C11 6.2.2.
  if !unit.globals.all (fun global =>
      (global.visibility != Visibility.exported || global.storage != Storage.static) &&
        (global.visibility != Visibility.internal || global.storage != Storage.extern)) then
    throw "global storage contradicts its visibility"
  if !unit.functions.all (fun function : CFunction =>
      typeValid function.result && function.params.all (typeValid ·.ty) &&
        function.body.all statementsValid && function.comments.all safeComment) then
    throw "invalid function declaration"
  if !unit.functions.all (fun function : CFunction =>
      function.headerComments.all safeComment) then
    throw "invalid function header comment"
  if !unit.functions.all (fun function : CFunction =>
      function.headerParams.all paramsValid &&
        function.concreteLayout.all concreteLayoutValid) then
    throw "invalid concrete function layout"
  if !unit.headerLayout.all concreteLayoutValid then throw "invalid concrete header layout"
  if !unit.assertions.all (exprValid ·.condition) then throw "invalid static assertion"
  for declaration in unit.orderedTypes do
    match declaration with
    | .define name value =>
        if !validIdentifier name || !exprValid value then throw "invalid ordered header define"
    | .alias alias =>
        if !typeValid alias.target then throw "invalid ordered typedef target"
    | .functionAlias function =>
        if !paramsValid function.params || !typeValid function.result ||
            !function.params.all (typeValid ·.ty) then
          throw "invalid ordered function typedef"
    | .enumeration enumeration =>
        if enumeration.members.isEmpty ||
            !enumeration.members.all (validIdentifier ·.name) ||
            !unique (enumeration.members.map (·.name)) then
          throw "invalid ordered enum declaration"
    | .structure declaration =>
        if !fieldNamesValid declaration.fields || !declaration.fields.all (typeValid ·.ty) then
          throw "invalid ordered struct declaration"
    | .union declaration =>
        if declaration.fields.isEmpty || !fieldNamesValid declaration.fields ||
            !declaration.fields.all (typeValid ·.ty) then
          throw "invalid ordered union declaration"
  if !unique (exportedNames unit) then throw "duplicate exported symbol"
  if !unit.layouts.all layoutValid then
    throw "invalid layout metadata"
  if !unit.resources.all (validIdentifier ·.name) || !unique (unit.resources.map (·.name)) then
    throw "invalid resource metadata"
  -- ConcreteLayout contract enforcement: every layout must reproduce the
  -- canonical token stream exactly and keep directives intact.
  for function in unit.functions do
    match checkConcreteLayout function.concreteLayout (renderFunctionCanonical function) with
    | .ok _ => pure ()
    | .error message => throw (message ++ " (function " ++ function.name ++ ")")
  match checkConcreteLayout unit.headerLayout (renderHeaderCanonicalUnit unit) with
  | .ok _ => pure ()
  | .error message => throw (message ++ " (header)")
  pure (.mk unit)

def renderHeader (validated : ValidatedTranslationUnit) : String :=
  applyConcreteLayout validated.unit.headerLayout (renderHeaderCanonicalUnit validated.unit)

def renderSource (validated : ValidatedTranslationUnit) : String :=
  let unit := validated.unit
  "#include \"" ++ unit.localHeader ++ "\"\n" ++
    String.join (unit.includes.map fun header => "#include <" ++ header ++ ">\n") ++ "\n" ++
    String.join (unit.defines.map fun define =>
      "#define " ++ define.1 ++ " " ++ renderDefineBody define.2 ++ "\n") ++
    (if unit.defines.isEmpty then "" else "\n") ++
    renderTypeDecls unit false ++
    String.join (unit.globals.map renderGlobal) ++
    (if unit.globals.isEmpty then "" else "\n") ++
    String.join (unit.assertions.map renderAssertion) ++
    (if unit.assertions.isEmpty then "" else "\n") ++
    String.join (unit.functions.map renderFunction)

def renderExports (validated : ValidatedTranslationUnit) : String :=
  String.join (exportedNames validated.unit |>.map (· ++ "\n"))

private def renderLayoutFieldJson (field : LayoutField) : String :=
  "{\"name\":\"" ++ escapeJson field.name ++ "\",\"offset\":" ++ toString field.offset ++
    ",\"size\":" ++ toString field.size ++ "}"

private def renderLayoutJson (layout : Layout) : String :=
  "{\"name\":\"" ++ escapeJson layout.name ++ "\",\"size\":" ++ toString layout.size ++
    ",\"alignment\":" ++ toString layout.alignment ++ ",\"fields\":[" ++
    String.intercalate "," (layout.fields.map renderLayoutFieldJson) ++ "]}"

def renderManifest (validated : ValidatedTranslationUnit) : String :=
  let unit := validated.unit
  "{\n" ++
    "  \"schema\": \"" ++ escapeJson unit.schema ++ "\",\n" ++
    "  \"identity\": \"" ++ escapeJson unit.identity ++ "\",\n" ++
    "  \"exports\": [" ++
      String.intercalate "," (exportedNames unit |>.map fun name =>
        "\"" ++ escapeJson name ++ "\"") ++
      "],\n" ++
    "  \"layouts\": [" ++ String.intercalate "," (unit.layouts.map renderLayoutJson) ++ "],\n" ++
    "  \"resources\": {" ++ String.intercalate "," (unit.resources.map fun resource =>
      "\"" ++ escapeJson resource.name ++ "\":" ++ toString resource.value) ++ "}\n" ++
    "}\n"

structure RenderedArtifacts where
  source : String
  header : String
  exports : String
  manifest : String
  deriving Repr

def renderArtifacts (validated : ValidatedTranslationUnit) : RenderedArtifacts :=
  { source := renderSource validated
  , header := renderHeader validated
  , exports := renderExports validated
  , manifest := renderManifest validated
  }

/-! ### Executable renderer checks -/

example :
    renderExpr (.binary .multiply (.binary .add (.ident "a") (.ident "b")) (.ident "c")) =
      "(a + b) * c" := by
  native_decide

example : renderExpr (.string "a\n\"b") = "\"a\\n\\\"b\"" := by
  native_decide

private def smokeUnit : TranslationUnit :=
  { schema := "cortex.wire.c11-artifact/v1"
  , identity := "smoke"
  , headerGuard := "CORTEX_SMOKE_H"
  , structs :=
      [ { name := "cortex_smoke_result"
        , fields := [{ name := "value", ty := .u32 }]
        , visibility := .exported
        }
      , { name := "cortex_smoke_state"
        , fields := [{ name := "ready", ty := .bool }]
        }
      ]
  , globals :=
      [ { name := "cortex_smoke_version"
        , ty := .u32
        , storage := .automatic
        , initial := some (.expression (.unsigned 1))
        , visibility := .exported
        }
      ]
  , functions :=
      [ { name := "cortex_smoke"
        , result := .u32
        , params := []
        , body := some [.returnValue (.unsigned 7)]
        , visibility := .exported
        }
      ]
  , layouts := [{ name := "smoke_layout", size := 8, alignment := 8 }]
  , resources := [{ name := "stack_bytes", value := 8 }]
  }

private def smokeArtifacts : Option RenderedArtifacts :=
  match validate smokeUnit with
  | .ok validated => some (renderArtifacts validated)
  | .error _ => none

example : smokeArtifacts.map (·.exports) = some "cortex_smoke_version\ncortex_smoke\n" := by
  native_decide

example : smokeArtifacts.map (·.manifest.contains "\"stack_bytes\":8") = some true := by
  native_decide

example :
    smokeArtifacts.map (·.header.contains "extern uint32_t cortex_smoke_version;") =
      some true := by
  native_decide

example : smokeArtifacts.map (·.header.contains "cortex_smoke_result") = some true := by
  native_decide

example : smokeArtifacts.map (·.source.contains "cortex_smoke_result") = some false := by
  native_decide

example :
    (match validate { smokeUnit with headerLayout := some { gaps := ["/* token */"] } } with
     | .error _ => true
     | .ok _ => false) = true := by
  native_decide

example : smokeArtifacts.map (·.source.contains "cortex_smoke_state") = some true := by
  native_decide

private def duplicateRejected : Bool :=
  match validate { smokeUnit with functions := smokeUnit.functions ++ smokeUnit.functions } with
  | .ok _ => false
  | .error _ => true

example : duplicateRejected = true := by
  native_decide

private def overflowingLayoutRejected : Bool :=
  match validate { smokeUnit with layouts :=
      [{ name := "bad_layout", size := 4, alignment := 4,
         fields := [{ name := "wide", offset := 2, size := 4 }] }] } with
  | .ok _ => false
  | .error _ => true

example : overflowingLayoutRejected = true := by
  native_decide

private def injectedIncludeRejected : Bool :=
  match validate { smokeUnit with includes := ["stdint.h>\n#error injected"] } with
  | .ok _ => false
  | .error _ => true

example : injectedIncludeRejected = true := by
  native_decide

private def layoutArityRejected : Bool :=
  match
    validate
      { smokeUnit with
        functions :=
          [ { name := "cortex_smoke_gap"
            , result := .void
            , params := []
            , body := some [.returnVoid]
            , concreteLayout := some { gaps := [" ", " "] } } ] }
  with
  | .ok _ => false
  | .error message => message.startsWith "concrete layout gap count does not match"

example : layoutArityRejected = true := by
  native_decide

private def layoutFusionRejected : Bool :=
  match
    validate
      { smokeUnit with
        functions :=
          [ { name := "cortex_smoke_fuse"
            , result := .void
            , params := []
            , body := some [.returnVoid]
            , concreteLayout := some { gaps := List.replicate 11 "" } } ] }
  with
  | .ok _ => false
  | .error message => message.startsWith "concrete layout alters the C token stream"

example : layoutFusionRejected = true := by
  native_decide

/-! ### Token-level and validation regression checks (epic review batch 3) -/

example : renderExpr (.unary .negate (.unary .negate (.ident "x"))) = "- -x" := by
  native_decide

example : renderExpr (.unary .preIncrement (.unary .preIncrement (.ident "x"))) = "++ ++x" := by
  native_decide

example : renderExpr (.unary .address (.unary .address (.ident "x"))) = "& &x" := by
  native_decide

example : renderExpr (.unary .negate (.ident "x")) = "-x" := by
  native_decide

example : renderExpr (.signed (-9223372036854775808)) = "(-9223372036854775807 - 1)" := by
  native_decide

example : escapeC (String.ofList ['\x00', '7']) = "\\0007" := by
  native_decide

example : escapeC "??=" = "?\\?=" := by
  native_decide

example : renderExpr (.character '\'') = "'\\''" := by
  native_decide

example : declarableIdentifier "true" = false := by
  native_decide

example : declarableIdentifier "uint64_t" = false := by
  native_decide

example : declarableIdentifier "_Reserved" = false := by
  native_decide

example : declarableIdentifier "__reserved" = false := by
  native_decide

example : validIdentifier "__builtin_add_overflow" = true := by
  native_decide

private def exportedStaticGlobalRejected : Bool :=
  match
    validate
      { smokeUnit with
        globals :=
          [ { name := "cortex_smoke_exported"
            , ty := .u64
            , storage := .static
            , visibility := .exported } ] }
  with
  | .ok _ => false
  | .error message => message == "global storage contradicts its visibility"

example : exportedStaticGlobalRejected = true := by
  native_decide

private def hugeSignedLiteralRejected : Bool :=
  match
    validate { smokeUnit with defines := [("CORTEX_SMOKE_HUGE", .signed (2 ^ 100))] }
  with
  | .ok _ => false
  | .error _ => true

example : hugeSignedLiteralRejected = true := by
  native_decide

private def pointerToArrayRejected : Bool :=
  match
    validate
      { smokeUnit with
        globals :=
          [ { name := "cortex_smoke_rows"
            , ty := .pointer (.array 4 .u32) false
            , storage := .extern
            , visibility := .exported } ] }
  with
  | .ok _ => false
  | .error _ => true

example : pointerToArrayRejected = true := by
  native_decide

end Cortex.Wire.C11
