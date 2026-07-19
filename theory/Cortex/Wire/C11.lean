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
  | u8
  | u32
  | u64
  | i64
  | f64
  | named (name : Name)
  | pointer (pointee : CType) (constPointee : Bool := false)
  | array (capacity : Nat) (element : CType)
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
  | null
  | unary (op : UnaryOp) (value : Expr)
  | binary (op : BinaryOp) (left right : Expr)
  | conditional (condition thenExpr elseExpr : Expr)
  | cast (ty : CType) (value : Expr)
  | call (function : Expr) (arguments : List Expr)
  | field (record : Expr) (name : Name)
  | pointerField (record : Expr) (name : Name)
  | index (array index : Expr)
  | sizeof (ty : CType)
  | alignof (ty : CType)
  deriving Repr

structure Local where
  name : Name
  ty : CType
  initial : Option Expr := none
  deriving Repr

mutual
  inductive Stmt where
    | block (statements : List Stmt)
    | local (declaration : Local)
    | evaluate (expression : Expr)
    | assign (target value : Expr)
    | branch (condition : Expr) (thenBody elseBody : List Stmt)
    | boundedFor (index : Name) (bound : Expr) (body : List Stmt)
    | switch (scrutinee : Expr) (cases : List SwitchCase) (defaultBody : List Stmt)
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
  deriving Repr

structure EnumMember where
  name : Name
  value : Int
  deriving Repr

structure EnumDecl where
  name : Name
  members : List EnumMember
  visibility : Visibility := .internal
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

structure Global where
  name : Name
  ty : CType
  storage : Storage := .static
  initial : Option Expr := none
  visibility : Visibility := .internal
  deriving Repr

structure CFunction where
  name : Name
  result : CType
  params : List Param
  body : Option (List Stmt) := none
  visibility : Visibility := .internal
  comments : List String := []
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
  includes : List String := []
  defines : List (Name × Expr) := []
  typedefs : List TypedefDecl := []
  functionTypedefs : List FunctionTypedef := []
  enums : List EnumDecl := []
  structs : List StructDecl := []
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

private def typeValid : CType → Bool
  | .void | .bool | .u8 | .u32 | .u64 | .i64 | .f64 => true
  | .named name => validIdentifier name
  | .pointer pointee _ => typeValid pointee
  | .array capacity element => 0 < capacity && typeValid element

private def exprValidFuel : Nat → Expr → Bool
  | 0, _ => false
  | fuel + 1, expression =>
      let valid := exprValidFuel fuel
      match expression with
      | .ident name => validIdentifier name
      | .signed _ | .unsigned _ | .bool _ | .string _ | .null => true
      | .unary _ value => valid value
      | .binary _ left right => valid left && valid right
      | .conditional condition thenExpr elseExpr =>
          valid condition && valid thenExpr && valid elseExpr
      | .cast ty value => typeValid ty && valid value
      | .call function arguments => valid function && arguments.all valid
      | .field record name | .pointerField record name =>
          valid record && validIdentifier name
      | .index arrayExpr indexExpr => valid arrayExpr && valid indexExpr
      | .sizeof ty | .alignof ty => typeValid ty

private def exprValid (expression : Expr) : Bool :=
  exprValidFuel (reprStr expression).length expression

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
      | .switch scrutinee cases defaultBody =>
          exprValid scrutinee &&
            cases.all (fun switchCase =>
              exprValid switchCase.value && statementsValid switchCase.body) &&
            statementsValid defaultBody
      | .returnValue value => exprValid value
      | .returnVoid | .break | .continue | .trap => true

private def statementsValid (statements : List Stmt) : Bool :=
  let fuel := (reprStr statements).length
  statements.all (stmtValidFuel fuel)

private def safeComment (comment : String) : Bool :=
  !comment.contains "*/" &&
    comment.toList.all fun char => char != '\n' && char != '\r'

private def unique : List String → Bool
  | [] => true
  | name :: rest => !rest.contains name && unique rest

private def fieldNamesValid (fields : List Field) : Bool :=
  fields.all (validIdentifier ·.name) && unique (fields.map (·.name))

private def paramsValid (params : List Param) : Bool :=
  params.all (validIdentifier ·.name) && unique (params.map (·.name))

private def exportedNames (unit : TranslationUnit) : List Name :=
  (unit.globals.filter fun global : Global =>
    global.visibility == Visibility.exported).map Global.name ++
  (unit.functions.filter fun function : CFunction =>
    function.visibility == Visibility.exported).map CFunction.name

private def declaredNames (unit : TranslationUnit) : List Name :=
  unit.typedefs.map (·.name) ++ unit.functionTypedefs.map (·.name) ++
    unit.enums.map (·.name) ++ unit.structs.map (·.name) ++
      unit.globals.map (·.name) ++ unit.functions.map (·.name)

private def safeInclude (header : String) : Bool :=
  !header.isEmpty && header.toList.all fun char =>
    char != '<' && char != '>' && char != '"' && char != '\n' && char != '\r'

private def layoutValid (layout : Layout) : Bool :=
  validIdentifier layout.name && 0 < layout.alignment &&
    layout.fields.all (fun field : LayoutField =>
      validIdentifier field.name && field.offset + field.size ≤ layout.size) &&
    unique (layout.fields.map LayoutField.name)

def validate (unit : TranslationUnit) : Except String ValidatedTranslationUnit := do
  if unit.schema.isEmpty then throw "translation-unit schema must not be empty"
  if unit.identity.isEmpty then throw "translation-unit identity must not be empty"
  if !validIdentifier unit.headerGuard then throw "invalid header guard"
  if !unit.includes.all safeInclude then throw "invalid system include"
  if !unique (unit.defines.map Prod.fst ++ declaredNames unit) then
    throw "duplicate top-level C identifier"
  if !(declaredNames unit).all validIdentifier then throw "invalid top-level C identifier"
  if !unit.defines.all (validIdentifier ·.1) then throw "invalid preprocessor identifier"
  if !unique (unit.defines.map (·.1)) then throw "duplicate preprocessor identifier"
  if !unit.defines.all (exprValid ·.2) then throw "invalid preprocessor expression"
  if !unit.structs.all (fieldNamesValid ·.fields) then throw "invalid or duplicate struct field"
  if !unit.structs.all (fun declaration => declaration.fields.all (typeValid ·.ty)) then
    throw "invalid struct field type"
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
      typeValid global.ty && global.initial.all exprValid) then
    throw "invalid global declaration"
  if !unit.functions.all (fun function : CFunction =>
      typeValid function.result && function.params.all (typeValid ·.ty) &&
        function.body.all statementsValid && function.comments.all safeComment) then
    throw "invalid function declaration"
  if !unit.assertions.all (exprValid ·.condition) then throw "invalid static assertion"
  if !unique (exportedNames unit) then throw "duplicate exported symbol"
  if !unit.layouts.all layoutValid then
    throw "invalid layout metadata"
  if !unit.resources.all (validIdentifier ·.name) || !unique (unit.resources.map (·.name)) then
    throw "invalid resource metadata"
  pure (.mk unit)

private def escapeCChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | '\x00' => "\\0"
  | '\x08' => "\\b"
  | '\x0c' => "\\f"
  | char => String.singleton char

def escapeC (value : String) : String :=
  String.join (value.toList.map escapeCChar)

private def escapeJsonChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | '\x08' => "\\b"
  | '\x0c' => "\\f"
  | char => String.singleton char

def escapeJson (value : String) : String :=
  String.join (value.toList.map escapeJsonChar)

private def renderBaseType : CType → String
  | .void => "void"
  | .bool => "bool"
  | .u8 => "uint8_t"
  | .u32 => "uint32_t"
  | .u64 => "uint64_t"
  | .i64 => "int64_t"
  | .f64 => "double"
  | .named name => name
  | .pointer pointee constPointee =>
      (if constPointee then "const " else "") ++ renderBaseType pointee ++ " *"
  | .array _ element => renderBaseType element

def renderDeclaration : CType → Name → String
  | .array capacity element, name => renderDeclaration element s!"{name}[{capacity}]"
  | ty, name => renderBaseType ty ++ (if name.isEmpty then "" else " " ++ name)

private def unaryToken : UnaryOp → String
  | .negate => "-"
  | .logicalNot => "!"
  | .bitNot => "~"
  | .address => "&"
  | .dereference => "*"

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
  | .ident _ | .signed _ | .unsigned _ | .bool _ | .string _ | .null |
    .call _ _ | .field _ _ | .pointerField _ _ | .index _ _ | .sizeof _ | .alignof _ => 15

private def renderExprFuel : Nat → Nat → Expr → String
  | 0, _, _ => ""
  | fuel + 1, parent, expression =>
      let renderAt := renderExprFuel fuel
      let precedence := exprPrecedence expression
      let rendered :=
        match expression with
        | .ident name => name
        | .signed value => toString value
        | .unsigned value => s!"{value}u"
        | .bool true => "true"
        | .bool false => "false"
        | .string value => "\"" ++ escapeC value ++ "\""
        | .null => "NULL"
        | .unary op value => unaryToken op ++ renderAt 14 value
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
        | .sizeof ty => "sizeof(" ++ renderDeclaration ty "" ++ ")"
        | .alignof ty => "_Alignof(" ++ renderDeclaration ty "" ++ ")"
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
  "typedef struct " ++ decl.name ++ " {\n" ++
    String.join (decl.fields.map fun field =>
      "  " ++ renderDeclaration field.ty field.name ++ ";\n") ++
    "} " ++ decl.name ++ ";\n\n"

private def renderEnum (decl : EnumDecl) : String :=
  "typedef enum " ++ decl.name ++ " {\n" ++
    String.intercalate ",\n" (decl.members.map fun member =>
      "  " ++ member.name ++ " = " ++ toString member.value) ++ "\n} " ++ decl.name ++ ";\n\n"

private def renderTypedef (decl : TypedefDecl) : String :=
  "typedef " ++ renderDeclaration decl.target decl.name ++ ";\n"

private def renderFunctionTypedef (decl : FunctionTypedef) : String :=
  "typedef " ++ renderDeclaration decl.result "" ++ " (*" ++ decl.name ++ ")(" ++
    renderParams decl.params ++ ");\n"

private def renderPrototype (function : CFunction) : String :=
  String.join (function.comments.map fun comment => "/* " ++ comment ++ " */\n") ++
    renderDeclaration function.result function.name ++ "(" ++ renderParams function.params ++ ");\n"

private def renderFunction (function : CFunction) : String :=
  match function.body with
  | none => renderPrototype function
  | some body =>
      String.join (function.comments.map fun comment => "/* " ++ comment ++ " */\n") ++
        (if function.visibility == .internal then "static " else "") ++
        renderDeclaration function.result function.name ++ "(" ++
        renderParams function.params ++ ") " ++
        renderBlock 0 body ++ "\n\n"

private def renderGlobal (global : Global) : String :=
  (match global.storage with | .automatic => "" | .static => "static " | .extern => "extern ") ++
    renderDeclaration global.ty global.name ++
    (global.initial.map (" = " ++ renderExpr ·)).getD "" ++ ";\n"

private def renderGlobalExtern (global : Global) : String :=
  "extern " ++ renderDeclaration global.ty global.name ++ ";\n"

private def renderAssertion (assertion : StaticAssert) : String :=
  "_Static_assert(" ++ renderExpr assertion.condition ++ ", \"" ++
    escapeC assertion.message ++ "\");\n"

private def renderTypeDecls (unit : TranslationUnit) (publicOnly : Bool) : String :=
  let visible (visibility : Visibility) :=
    if publicOnly then visibility == .exported else visibility == .internal
  String.join ((unit.typedefs.filter fun declaration =>
    visible declaration.visibility).map renderTypedef) ++
    String.join ((unit.functionTypedefs.filter fun declaration =>
      visible declaration.visibility).map renderFunctionTypedef) ++
    (if unit.typedefs.isEmpty && unit.functionTypedefs.isEmpty then "" else "\n") ++
    String.join ((unit.enums.filter fun declaration =>
      visible declaration.visibility).map renderEnum) ++
    String.join ((unit.structs.filter fun declaration =>
      visible declaration.visibility).map renderStruct)

def renderHeader (validated : ValidatedTranslationUnit) : String :=
  let unit := validated.unit
  "#ifndef " ++ unit.headerGuard ++ "\n#define " ++ unit.headerGuard ++ "\n\n" ++
    "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n" ++
    "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n" ++
    renderTypeDecls unit true ++
    String.join ((unit.globals.filter fun global : Global =>
      global.visibility == Visibility.exported).map renderGlobalExtern) ++
    String.join ((unit.functions.filter fun function : CFunction =>
      function.visibility == Visibility.exported).map renderPrototype) ++
    "\n#ifdef __cplusplus\n}\n#endif\n\n#endif\n"

def renderSource (validated : ValidatedTranslationUnit) : String :=
  let unit := validated.unit
  "#include \"program.h\"\n" ++
    String.join (unit.includes.map fun header => "#include <" ++ header ++ ">\n") ++ "\n" ++
    String.join (unit.defines.map fun define =>
      "#define " ++ define.1 ++ " " ++ renderExpr define.2 ++ "\n") ++
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
        , initial := some (.unsigned 1)
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

end Cortex.Wire.C11
