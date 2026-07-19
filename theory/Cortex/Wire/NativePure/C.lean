import Cortex.Wire.NativePure
import Cortex.Wire.C11

/-!
## Concrete NativePure region lowering

This is the concrete, authority-free lowering below the certified NativePure
kernel and above the shared printable C11 layer.  It fixes every aggregate
layout, inserts named padding, represents exclusive sums as a tag plus a typed
payload union, and emits one total status-returning frame function.

The scheduler is a separate additive v2 layer. A generated function can read only its
input frame and write only its output frame; checked operations return a typed
failure status. The scheduler may dispatch these functions, but cannot give them a
host context or worker authority because neither exists in this ABI.
-/

namespace Cortex.Wire.NativePure.C

open Cortex.Wire.NativePure
open Cortex.Wire.C11

inductive Status where
  | ok
  | typeMismatch
  | arithmeticOverflow
  | bounds
  | capacity
  | invalidTag
  deriving DecidableEq, Repr

def Status.code : Status → Nat
  | .ok => 0
  | .typeMismatch => 1
  | .arithmeticOverflow => 2
  | .bounds => 3
  | .capacity => 4
  | .invalidTag => 5

/-- C-safe names are construction-owned. Authored labels remain manifest
metadata and never become identifiers. -/
private def typeName (index : Nat) : Name := s!"cortex_np_type_{index}"
private def payloadName (index : Nat) : Name := s!"cortex_np_type_{index}_payload"
private def fieldName (index : Nat) : Name := s!"field_{index}"
private def variantName (index : Nat) : Name := s!"variant_{index}"
private def paddingName (index : Nat) : Name := s!"padding_{index}"

private def insertTy (types : List Ty) (ty : Ty) : List Ty :=
  if types.contains ty then types else types ++ [ty]

/-- Fuelled implementation makes nested record/sum traversal visibly total to
Lean even though recursive children occur below lists of labelled fields. -/
private def collectTyFuel : Nat → Ty → List Ty → List Ty
  | 0, _, types => types
  | _fuel + 1, .text capacity, types => insertTy types (.text capacity)
  | fuel + 1, .vector capacity element, types =>
      insertTy (collectTyFuel fuel element types) (.vector capacity element)
  | fuel + 1, .record fields, types =>
      let children := fields.foldl
        (fun acc field => collectTyFuel fuel field.2 acc) types
      insertTy children (.record fields)
  | fuel + 1, .sum variants, types =>
      let children := variants.foldl
        (fun acc variant => collectTyFuel fuel variant.2 acc) types
      insertTy children (.sum variants)
  | _ + 1, _, types => types

/-- Children precede their containing aggregate. This is also the C
declaration order, so no forward declaration is required. -/
def collectTy (ty : Ty) (types : List Ty) : List Ty :=
  collectTyFuel (reprStr ty).length ty types

mutual
  def collectExpr : SemanticC.Expr context ty → List Ty → List Ty
    | .load _, types => collectTy ty types
    | .read _, types => collectTy ty types
    | .unit, types => types
    | .bool _, types => types
    | .u8 _, types => types
    | .u32 _, types => types
    | .i64 _, types => types
    | .u64 _, types => types
    | .f64 _, types => types
    | .text _ _, types => collectTy ty types
    | .bind bound body, types => collectExpr body (collectExpr bound types)
    | .branch condition thenExpr elseExpr, types =>
        collectExpr elseExpr (collectExpr thenExpr (collectExpr condition types))
    | .not value, types => collectExpr value types
    | .and left right, types | .or left right, types | .checkedAdd left right, types
    | .checkedSub left right, types | .checkedMul left right, types
    | .eqU8 left right, types | .eqU32 left right, types | .eqU64 left right, types
    | .eqI64 left right, types | .ltU64 left right, types | .ltI64 left right, types =>
        collectExpr right (collectExpr left types)
    | .struct fields, types => collectRecord fields (collectTy ty types)
    | .field record _, types => collectTy ty (collectExpr record types)
    | .vector values, types => collectVector values (collectTy ty types)
    | .index vector index, types => collectTy ty (collectExpr index (collectExpr vector types))
    | .tagged _ payload, types => collectExpr payload (collectTy ty types)
    | .call _ args, types => collectArgs args (collectTy ty types)

  def collectRecord : SemanticC.RecordExpr context fields → List Ty → List Ty
    | .nil, types => types
    | .cons _ field rest, types => collectRecord rest (collectExpr field types)

  def collectVector : SemanticC.VectorExpr context element capacity → List Ty → List Ty
    | .nil, types => types
    | .cons head tail, types => collectVector tail (collectExpr head types)

  def collectArgs : SemanticC.Args context params → List Ty → List Ty
    | .nil, types => types
    | .cons head tail, types => collectArgs tail (collectExpr head types)
end

private def tyIndex (types : List Ty) (ty : Ty) : Nat :=
  (types.findIdx? (· == ty)).getD types.length

def ctype (types : List Ty) : Ty → CType
  | .unit => .u8
  | .bool => .bool
  | .u8 => .u8
  | .u32 => .u32
  | .i64 => .i64
  | .u64 => .u64
  | .f64 => .f64
  | ty@(.text _) | ty@(.vector _ _) | ty@(.record _) | ty@(.sum _) =>
      .named (typeName (tyIndex types ty))

structure ConcreteField where
  sourceLabel : Name
  cName : Name
  ty : Ty
  ctype : CType
  offset : Nat
  size : Nat
  deriving Repr

structure ConcreteAggregate where
  name : Name
  size : Nat
  alignment : Nat
  fields : List ConcreteField
  declaration : TypeDecl
  deriving Repr

private structure FieldBuild where
  declarations : List Field := []
  metadata : List ConcreteField := []
  offset : Nat := 0
  padding : Nat := 0

private def addPadding (target : Nat) (state : FieldBuild) : FieldBuild :=
  if state.offset < target then
    { state with
      declarations := state.declarations ++
        [{ name := paddingName state.padding, ty := .array (target - state.offset) .u8 }]
      offset := target
      padding := state.padding + 1 }
  else state

private def addField
    (types : List Ty) (sourceLabel : Name) (index : Nat) (ty : Ty)
    (state : FieldBuild) : FieldBuild :=
  let (size, alignment) := layout ty
  let placed := addPadding (alignUp state.offset alignment) state
  let cName := fieldName index
  { placed with
    declarations := placed.declarations ++ [{ name := cName, ty := ctype types ty }]
    metadata := placed.metadata ++
      [{ sourceLabel, cName, ty, ctype := ctype types ty, offset := placed.offset, size }]
    offset := placed.offset + size }

private def finishFields (size : Nat) (state : FieldBuild) : FieldBuild :=
  addPadding size state

private def recordAggregate
    (types : List Ty) (index : Nat) (fields : List (Name × Ty)) : ConcreteAggregate :=
  let built := fields.zipIdx.foldl
    (fun state entry => addField types entry.1.1 entry.2 entry.1.2 state) {}
  let (size, alignment) := layout (.record fields)
  let finished := finishFields size built
  let name := typeName index
  { name, size, alignment, fields := finished.metadata
  , declaration := .structure { name, fields := finished.declarations, visibility := .exported } }

private def textAggregate (index capacity : Nat) : ConcreteAggregate :=
  let name := typeName index
  let (size, alignment) := layout (.text capacity)
  let raw : List Field :=
    [{ name := "length", ty := .u32 }, { name := "bytes", ty := .array capacity .u8 }]
  let used := 4 + capacity
  let fields :=
    if used < size then raw ++ [{ name := "padding_0", ty := .array (size - used) .u8 }]
    else raw
  { name, size, alignment
  , fields :=
      [ { sourceLabel := "length", cName := "length", ty := .u32, ctype := .u32
        , offset := 0, size := 4 }
      , { sourceLabel := "bytes", cName := "bytes", ty := .vector capacity .u8
        , ctype := .array capacity .u8, offset := 4, size := capacity }
      ]
  , declaration := .structure { name, fields, visibility := .exported } }

private def vectorAggregate
    (types : List Ty) (index capacity : Nat) (element : Ty) : ConcreteAggregate :=
  let name := typeName index
  let (elementSize, elementAlignment) := layout element
  let payloadOffset := alignUp 4 elementAlignment
  let (size, alignment) := layout (.vector capacity element)
  let before :=
    if 4 < payloadOffset then [{ name := "padding_0", ty := .array (payloadOffset - 4) .u8 }]
    else []
  let used := payloadOffset + capacity * elementSize
  let after :=
    if used < size then [{ name := "padding_1", ty := .array (size - used) .u8 }]
    else []
  { name, size, alignment
  , fields :=
      [ { sourceLabel := "length", cName := "length", ty := .u32, ctype := .u32
        , offset := 0, size := 4 }
      , { sourceLabel := "items", cName := "items", ty := .vector capacity element
        , ctype := .array capacity (ctype types element), offset := payloadOffset
        , size := capacity * elementSize }
      ]
  , declaration := .structure
      { name, visibility := .exported
      , fields := [{ name := "length", ty := .u32 }] ++ before ++
          [{ name := "items", ty := .array capacity (ctype types element) }] ++ after } }

private def sumAggregates
    (types : List Ty) (index : Nat) (variants : List (Name × Ty)) : List ConcreteAggregate :=
  let sumName := typeName index
  let unionName := payloadName index
  let unionFields := variants.zipIdx.map fun entry : (Name × Ty) × Nat =>
    { name := variantName entry.2, ty := ctype types entry.1.2 : Field }
  let (payloadSize, payloadAlignment) := sumLayout variants
  let payloadAggregate : ConcreteAggregate :=
    { name := unionName, size := payloadSize, alignment := payloadAlignment, fields := []
    , declaration := .union
        { name := unionName, fields := unionFields, visibility := .exported } }
  let payloadOffset := alignUp 4 payloadAlignment
  let (size, alignment) := layout (.sum variants)
  let before :=
    if 4 < payloadOffset then [{ name := "padding_0", ty := .array (payloadOffset - 4) .u8 }]
    else []
  let used := payloadOffset + payloadSize
  let after :=
    if used < size then [{ name := "padding_1", ty := .array (size - used) .u8 }]
    else []
  let sumAggregate : ConcreteAggregate :=
    { name := sumName, size, alignment
    , fields :=
        [ { sourceLabel := "tag", cName := "tag", ty := .u32, ctype := .u32
          , offset := 0, size := 4 }
        , { sourceLabel := "payload", cName := "payload", ty := .sum variants
          , ctype := .named unionName, offset := payloadOffset, size := payloadSize }
        ]
    , declaration := .structure
        { name := sumName, visibility := .exported
        , fields := [{ name := "tag", ty := .u32 }] ++ before ++
            [{ name := "payload", ty := .named unionName }] ++ after } }
  [payloadAggregate, sumAggregate]

def aggregateDeclarations (types : List Ty) : List ConcreteAggregate :=
  types.zipIdx.flatMap fun entry =>
    match entry.1 with
    | .text capacity => [textAggregate entry.2 capacity]
    | .vector capacity element => [vectorAggregate types entry.2 capacity element]
    | .record fields => [recordAggregate types entry.2 fields]
    | .sum variants => sumAggregates types entry.2 variants
    | .unit | .bool | .u8 | .u32 | .i64 | .u64 | .f64 => []

private def varIndex : Var context ty → Nat
  | .zero => 0
  | .succ rest => 1 + varIndex rest

private def memberIndex : Member name ty fields → Nat
  | .head => 0
  | .tail rest => 1 + memberIndex rest

private structure Emitted where
  statements : List Stmt
  value : Cortex.Wire.C11.Expr
  next : Nat

private def temporary (next : Nat) : Name := s!"value_{next}"

private def emitRecordWith
    (emit : ∀ {fieldTy}, Nat → SemanticC.Expr context fieldTy → Except String Emitted)
    (target : Name) : (index next : Nat) → SemanticC.RecordExpr context fields →
    Except String (List Stmt × Nat)
  | _, next, .nil => pure ([], next)
  | index, next, .cons _ field rest => do
      let fieldValue ← emit next field
      let restValue ← emitRecordWith emit target (index + 1) fieldValue.next rest
      pure
        (fieldValue.statements ++
          [.assign (.field (.ident target) (fieldName index)) fieldValue.value] ++ restValue.1,
         restValue.2)

private def emitExprFuel
    (fuel : Nat)
    (types : List Ty) (env : List Cortex.Wire.C11.Expr) (next : Nat)
    (expr : SemanticC.Expr context ty) : Except String Emitted :=
  match fuel with
  | 0 => throw "NativePure C lowering exhausted structural fuel"
  | fuel + 1 =>
    let emitBinary {operand : Ty}
        (op : BinaryOp) (left right : SemanticC.Expr context operand) := do
      let leftValue ← emitExprFuel fuel types env next left
      let rightValue ← emitExprFuel fuel types env leftValue.next right
      pure
        { statements := leftValue.statements ++ rightValue.statements
        , value := .binary op leftValue.value rightValue.value
        , next := rightValue.next }
    let emitChecked
        (builtin : Name) (left right : SemanticC.Expr context .i64) := do
      let leftValue ← emitExprFuel fuel types env next left
      let rightValue ← emitExprFuel fuel types env leftValue.next right
      let resultName := temporary rightValue.next
      pure
        { statements := leftValue.statements ++ rightValue.statements ++
            [ .local { name := resultName, ty := .i64 }
            , .branch
                (.call (.ident builtin)
                  [leftValue.value, rightValue.value, .unary .address (.ident resultName)])
                [.returnValue (.unsigned Status.arithmeticOverflow.code)] []
            ]
        , value := .ident resultName
        , next := rightValue.next + 1 }
    match expr with
    | .load slot =>
        match env[varIndex slot]? with
        | some value => pure { statements := [], value, next }
        | none => throw "NativePure C lowering lost a typed input binding"
    | .read _ => throw "NativePure region lowering forbids ambient storage reads"
    | .unit => pure { statements := [], value := .unsigned 0, next }
    | .bool value => pure { statements := [], value := .bool value, next }
    | .u8 value => pure { statements := [], value := .unsigned value.value, next }
    | .u32 value => pure { statements := [], value := .unsigned value.value, next }
    | .i64 value => pure { statements := [], value := .signed value.value, next }
    | .u64 value => pure { statements := [], value := .unsigned value.value, next }
    | .f64 _ => throw "binary64 concrete literals remain in the PR 13 validation slice"
    | .text value _ => do
        let resultName := temporary next
        let bytes := value.toUTF8.toList
        let assignments := bytes.zipIdx.map fun entry : UInt8 × Nat =>
          .assign (.index (.field (.ident resultName) "bytes") (.unsigned entry.2))
            (.unsigned entry.1.toNat)
        pure
          { statements :=
              [.local { name := resultName, ty := ctype types ty }]
              ++ [.assign (.field (.ident resultName) "length") (.unsigned bytes.length)]
              ++ assignments
          , value := .ident resultName, next := next + 1 }
    | .bind bound body => do
        let boundValue ← emitExprFuel fuel types env next bound
        let bodyValue ← emitExprFuel fuel types (boundValue.value :: env) boundValue.next body
        pure
          { statements := boundValue.statements ++ bodyValue.statements
          , value := bodyValue.value, next := bodyValue.next }
    | .branch condition thenExpr elseExpr => do
        let conditionValue ← emitExprFuel fuel types env next condition
        let resultName := temporary conditionValue.next
        let thenValue ← emitExprFuel fuel types env (conditionValue.next + 1) thenExpr
        let elseValue ← emitExprFuel fuel types env thenValue.next elseExpr
        pure
          { statements := conditionValue.statements ++
              [.local { name := resultName, ty := ctype types ty }] ++
              [.branch conditionValue.value
                (thenValue.statements ++ [.assign (.ident resultName) thenValue.value])
                (elseValue.statements ++ [.assign (.ident resultName) elseValue.value])]
          , value := .ident resultName, next := elseValue.next }
    | .not value => do
        let emitted ← emitExprFuel fuel types env next value
        pure { emitted with value := .unary .logicalNot emitted.value }
    | .and left right => emitBinary .logicalAnd left right
    | .or left right => emitBinary .logicalOr left right
    | .checkedAdd left right => emitChecked "__builtin_add_overflow" left right
    | .checkedSub left right => emitChecked "__builtin_sub_overflow" left right
    | .checkedMul left right => emitChecked "__builtin_mul_overflow" left right
    | .eqU8 left right => emitBinary .equal left right
    | .eqU32 left right => emitBinary .equal left right
    | .eqU64 left right => emitBinary .equal left right
    | .eqI64 left right => emitBinary .equal left right
    | .ltU64 left right => emitBinary .less left right
    | .ltI64 left right => emitBinary .less left right
    | .struct fields => do
        let resultName := temporary next
        let fieldsValue ←
          emitRecordWith (fun fieldNext field => emitExprFuel fuel types env fieldNext field)
            resultName 0 (next + 1) fields
        pure
          { statements := [.local { name := resultName, ty := ctype types ty }] ++ fieldsValue.1
          , value := .ident resultName, next := fieldsValue.2 }
    | .field record member => do
        let recordValue ← emitExprFuel fuel types env next record
        pure { recordValue with value := .field recordValue.value (fieldName (memberIndex member)) }
    | .vector _ =>
        throw "bounded vector construction awaits the PR 13 differential closure"
    | .index vector index => do
        let vectorValue ← emitExprFuel fuel types env next vector
        let indexValue ← emitExprFuel fuel types env vectorValue.next index
        pure
          { statements := vectorValue.statements ++ indexValue.statements ++
              [ .branch
                  (.binary .greaterEqual indexValue.value
                    (.field vectorValue.value "length"))
                  [.returnValue (.unsigned Status.bounds.code)] []
              ]
          , value := .index (.field vectorValue.value "items") indexValue.value
          , next := indexValue.next }
    | .tagged member payload => do
        let payloadValue ← emitExprFuel fuel types env next payload
        let resultName := temporary payloadValue.next
        let index := memberIndex member
        pure
          { statements := payloadValue.statements ++
              [ .local { name := resultName, ty := ctype types ty }
              , .assign (.field (.ident resultName) "tag") (.unsigned index)
              , .assign
                  (.field (.field (.ident resultName) "payload") (variantName index))
                  payloadValue.value
              ]
          , value := .ident resultName, next := payloadValue.next + 1 }
    | .call _ _ => throw "NativePure region lowering forbids semantic function calls"
termination_by fuel

/-- Total constructive lowering. `steps` is a structural upper bound for the
admitted expression tree; the extra unit covers the root dispatch. -/
private def emitExpr
    (types : List Ty) (env : List Cortex.Wire.C11.Expr) (next : Nat)
    (fuel : Nat) (expr : SemanticC.Expr context ty) : Except String Emitted :=
  emitExprFuel (fuel + 1) types env next expr

structure Region where
  name : Name
  inputLabels : List Name
  kernel : CertifiedKernel

private def regionTypes (region : Region) : List Ty :=
  let inputs := region.kernel.inputs.foldl (fun types ty => collectTy ty types) []
  collectExpr region.kernel.target (collectTy region.kernel.output inputs)

private def frameFields
    (types : List Ty) (labels : List Name) (values : List Ty) : FieldBuild :=
  values.zipIdx.foldl (fun state entry =>
    addField types (labels[entry.2]?.getD s!"input_{entry.2}") entry.2 entry.1 state) {}

private def inputFrame (region : Region) (types : List Ty) : ConcreteAggregate :=
  let name := region.name ++ "_input"
  let built := frameFields types region.inputLabels region.kernel.inputs
  let calculatedSize :=
    alignUp built.offset (region.kernel.inputs.foldl (fun acc ty => max acc (alignOf ty)) 1)
  let size := max 1 calculatedSize
  let finished := finishFields size built
  { name, size, alignment := region.kernel.inputs.foldl (fun acc ty => max acc (alignOf ty)) 1
  , fields := finished.metadata
  , declaration := .structure
      { name, fields := if finished.declarations.isEmpty then [{ name := "empty", ty := .u8 }]
        else finished.declarations, visibility := .exported } }

private def outputFrame (region : Region) (types : List Ty) : ConcreteAggregate :=
  let name := region.name ++ "_output"
  let (size, alignment) := layout region.kernel.output
  { name, size, alignment
  , fields :=
      [{ sourceLabel := "value", cName := "value", ty := region.kernel.output
       , ctype := ctype types region.kernel.output, offset := 0, size }]
  , declaration := .structure
      { name, fields := [{ name := "value", ty := ctype types region.kernel.output }]
      , visibility := .exported } }

private def effectFrame
    (region : Region) (input output : ConcreteAggregate) : ConcreteAggregate :=
  let name := region.name ++ "_effect_frame"
  let hasInput := !region.kernel.inputs.isEmpty
  let inputOffset := 0
  let outputOffset := if hasInput then alignUp (inputOffset + input.size) output.alignment else 0
  let alignment := if hasInput then max input.alignment output.alignment else output.alignment
  let size := alignUp (outputOffset + output.size) alignment
  let beforeOutput :=
    if hasInput && inputOffset + input.size < outputOffset then
      [{ name := "padding_1", ty := .array (outputOffset - inputOffset - input.size) .u8 }]
    else []
  let trailing :=
    if outputOffset + output.size < size then
      [{ name := "padding_2", ty := .array (size - outputOffset - output.size) .u8 }]
    else []
  { name, size, alignment
  , fields :=
      (if hasInput then
        [ { sourceLabel := "input", cName := "input", ty := .unit
          , ctype := .named input.name, offset := inputOffset, size := input.size }]
      else []) ++
      [ { sourceLabel := "output", cName := "output", ty := region.kernel.output
        , ctype := .named output.name, offset := outputOffset, size := output.size }
      ]
  , declaration := .structure
      { name, visibility := .exported
      , fields := (if hasInput then [{ name := "input", ty := .named input.name }] else []) ++
          beforeOutput ++
          [{ name := "output", ty := .named output.name }] ++ trailing } }

private def aggregateLayout (aggregate : ConcreteAggregate) : Layout :=
  { name := aggregate.name, size := aggregate.size, alignment := aggregate.alignment
  , fields := aggregate.fields.map fun field =>
      { name := field.cName, offset := field.offset, size := field.size } }

private def aggregateAssertions (aggregate : ConcreteAggregate) : List StaticAssert :=
  [ { condition := .binary .equal (.sizeof (.named aggregate.name)) (.unsigned aggregate.size)
    , message := aggregate.name ++ " size" }
  , { condition := .binary .equal (.alignof (.named aggregate.name)) (.unsigned aggregate.alignment)
    , message := aggregate.name ++ " alignment" }
  ] ++ aggregate.fields.map fun field =>
    { condition := .binary .equal (.offsetof (.named aggregate.name) field.cName)
        (.unsigned field.offset)
    , message := aggregate.name ++ "." ++ field.cName ++ " offset" }

private def regionFunction
    (region : Region) (types : List Ty) (input output : ConcreteAggregate) :
    Except String CFunction := do
  if !validIdentifier region.name then throw "NativePure region C name is not a valid identifier"
  if region.inputLabels.length != region.kernel.inputs.length then
    throw "NativePure region input labels do not match its typed boundary"
  let environment := region.kernel.inputs.zipIdx.map fun entry =>
    .pointerField (.ident "input") (fieldName entry.2)
  let emitted ←
    emitExpr types environment 0 region.kernel.bounds.maxSteps region.kernel.target
  pure
    { name := region.name ++ "_run"
    , result := .u32
    , params :=
        [ { name := "input", ty := .pointer (.named input.name) true }
        , { name := "output", ty := .pointer (.named output.name) false }
        ]
    , body := some (emitted.statements ++
        [ .assign (.pointerField (.ident "output") "value") emitted.value
        , .returnValue (.unsigned Status.ok.code)
        ])
    , visibility := .exported
    , comments :=
        ["Synchronous, heap-free and authority-free NativePure region."] }

private def dispatchFunction
    (region : Region) (input output : ConcreteAggregate) : CFunction :=
  { name := region.name ++ "_dispatch"
  , result := .u32
  , params :=
      [ { name := "input", ty := .pointer .void true }
      , { name := "output", ty := .pointer .void false }
      ]
  , body := some
      [ .returnValue
          (.call (.ident (region.name ++ "_run"))
            [ .cast (.pointer (.named input.name) true) (.ident "input")
            , .cast (.pointer (.named output.name) false) (.ident "output")
            ])
      ]
  , visibility := .exported
  , comments :=
      ["Type-erased scheduler adapter; the region still receives no host authority."] }

private def translationUnitWithDispatch
    (dispatchable : Bool) (identity : String) (region : Region) :
    Except String TranslationUnit := do
  if identity.isEmpty then throw "NativePure program identity must not be empty"
  let types := regionTypes region
  let nativeAggregates := aggregateDeclarations types
  let input := inputFrame region types
  let output := outputFrame region types
  let effect := effectFrame region input output
  let aggregates := nativeAggregates ++ [input, output, effect]
  let function ← regionFunction region types input output
  if output.size > region.kernel.bounds.outputBytes then
    throw "NativePure output frame exceeds its certified bound"
  if effect.size > region.kernel.bounds.checkpointBytes then
    throw "NativePure effect frame exceeds its certified checkpoint bound"
  pure
    { schema := "cortex.wire.native-pure-c/v1"
    , identity
    , headerGuard := region.name ++ "_NATIVE_PURE_C_V1_H"
    , localHeader := region.name ++ ".h"
    , orderedTypes :=
        [ .enumeration
            { name := "cortex_np_status", visibility := .exported
            , members :=
                [ { name := "CORTEX_NP_OK", value := Status.ok.code }
                , { name := "CORTEX_NP_TYPE_MISMATCH", value := Status.typeMismatch.code }
                , { name := "CORTEX_NP_ARITHMETIC_OVERFLOW"
                  , value := Status.arithmeticOverflow.code }
                , { name := "CORTEX_NP_BOUNDS", value := Status.bounds.code }
                , { name := "CORTEX_NP_CAPACITY", value := Status.capacity.code }
                , { name := "CORTEX_NP_INVALID_TAG", value := Status.invalidTag.code }
                ] }
        ] ++ aggregates.map (·.declaration)
    , functions := [function] ++
        (if dispatchable then [dispatchFunction region input output] else [])
    , assertions := aggregates.flatMap aggregateAssertions ++
        [ { condition := .binary .lessEqual (.sizeof (.named output.name))
              (.unsigned region.kernel.bounds.outputBytes)
          , message := "NativePure output bound" }
        , { condition := .binary .lessEqual (.sizeof (.named effect.name))
              (.unsigned region.kernel.bounds.checkpointBytes)
          , message := "NativePure checkpoint bound" }
        ]
    , layouts := aggregates.map aggregateLayout
    , resources :=
        [ { name := "stack_bytes", value := region.kernel.bounds.stackBytes }
        , { name := "static_bytes", value := region.kernel.bounds.staticBytes }
        , { name := "output_bytes", value := region.kernel.bounds.outputBytes }
        , { name := "checkpoint_bytes", value := region.kernel.bounds.checkpointBytes }
        , { name := "max_steps", value := region.kernel.bounds.maxSteps }
        ] }

def translationUnit (identity : String) (region : Region) : Except String TranslationUnit :=
  translationUnitWithDispatch false identity region

def translationUnitDispatchable
    (identity : String) (region : Region) : Except String TranslationUnit :=
  translationUnitWithDispatch true identity region

def compile (identity : String) (region : Region) : Except String ValidatedTranslationUnit := do
  let unit ← translationUnit identity region
  C11.validate unit

def render (identity : String) (region : Region) : Except String RenderedArtifacts := do
  renderArtifacts <$> compile identity region

def compileDispatchable
    (identity : String) (region : Region) : Except String ValidatedTranslationUnit := do
  let unit ← translationUnitDispatchable identity region
  C11.validate unit

def renderDispatchable (identity : String) (region : Region) : Except String RenderedArtifacts := do
  renderArtifacts <$> compileDispatchable identity region

end Cortex.Wire.NativePure.C
