import Cortex.Wire.NativePure.Type

/-!
## Shared typed semantic C IR

This is the proof-side, executable language shared by StaticC scheduler
specialization and NativePure region lowering. It is intentionally not C
syntax: identifiers, declarations, rendering, and translation-unit validation
belong to the next lowering layer.

The IR is intrinsically typed at expression and function boundaries. Runtime
values remain erased because the indices are the typing authority. Its
operational semantics is fuelled and deterministic, with explicit statement
failure propagation and fuel exhaustion.
-/

namespace Cortex.Wire.SemanticC

open Cortex.Wire.NativePure

/-- Access mode carried by a storage reference. -/
inductive Access where
  | read
  | write
  | readWrite
  deriving DecidableEq, Repr

/-- Concrete lifetime/ABI class selected after semantic lowering. -/
inductive StorageClass where
  | automatic
  | static
  | input
  | output
  | global
  deriving DecidableEq, Repr

/-- Typed reference to named storage. -/
structure Ref (ty : Ty) where
  name : Name
  storage : StorageClass
  access : Access
  deriving Repr

/-- A typed function authority used by semantic calls. -/
structure FunctionRef (params : List Ty) (result : Ty) where
  name : Name
  deriving Repr

mutual
  /-- Intrinsically typed expression basis shared by both lowering paths. -/
  inductive Expr : List Ty → Ty → Type where
    | load : Var context ty → Expr context ty
    | read : Ref ty → Expr context ty
    | unit : Expr context .unit
    | bool : Bool → Expr context .bool
    | u8 : U8 → Expr context .u8
    | u32 : U32 → Expr context .u32
    | i64 : I64 → Expr context .i64
    | u64 : U64 → Expr context .u64
    | f64 : Float → Expr context .f64
    | text
        (value : String)
        (bounded : value.toUTF8.size ≤ capacity) : Expr context (.text capacity)
    | bind : Expr context bound → Expr (bound :: context) result → Expr context result
    | branch : Expr context .bool → Expr context ty → Expr context ty → Expr context ty
    | not : Expr context .bool → Expr context .bool
    | and : Expr context .bool → Expr context .bool → Expr context .bool
    | or : Expr context .bool → Expr context .bool → Expr context .bool
    | checkedAdd : Expr context .i64 → Expr context .i64 → Expr context .i64
    | checkedSub : Expr context .i64 → Expr context .i64 → Expr context .i64
    | checkedMul : Expr context .i64 → Expr context .i64 → Expr context .i64
    | eqU8 : Expr context .u8 → Expr context .u8 → Expr context .bool
    | eqU32 : Expr context .u32 → Expr context .u32 → Expr context .bool
    | eqU64 : Expr context .u64 → Expr context .u64 → Expr context .bool
    | eqI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | ltU64 : Expr context .u64 → Expr context .u64 → Expr context .bool
    | ltI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | struct : RecordExpr context fields → Expr context (.record fields)
    | field : Expr context (.record fields) → Member name ty fields → Expr context ty
    | vector : VectorExpr context element capacity → Expr context (.vector capacity element)
    | index : Expr context (.vector capacity element) → Expr context .u64 → Expr context element
    | tagged : Member label payload variants → Expr context payload → Expr context (.sum variants)
    | call : FunctionRef params result → Args context params → Expr context result

  /-- Expression for every field in one fixed record. -/
  inductive RecordExpr : List Ty → List (Name × Ty) → Type where
    | nil : RecordExpr context []
    | cons
        (name : Name)
        (field : Expr context ty)
        (rest : RecordExpr context fields) : RecordExpr context ((name, ty) :: fields)

  /-- Exactly `capacity` expressions for one bounded vector value. -/
  inductive VectorExpr : List Ty → Ty → Nat → Type where
    | nil : VectorExpr context element 0
    | cons
        (head : Expr context element)
        (tail : VectorExpr context element capacity) : VectorExpr context element (capacity + 1)

  /-- Typed argument spine for one function call. -/
  inductive Args : List Ty → List Ty → Type where
    | nil : Args context []
    | cons
        (head : Expr context ty)
        (tail : Args context params) : Args context (ty :: params)
end

/-- Erased named store; `Ref` indices retain the static type/access facts. -/
structure Store where
  cells : List (Name × Value) := []
  deriving Repr

namespace Store

def read (store : Store) (name : Name) : Option Value :=
  (store.cells.find? fun cell => cell.1 == name).map Prod.snd

private def replace (name : Name) (value : Value) : List (Name × Value) → List (Name × Value)
  | [] => [(name, value)]
  | (current, currentValue) :: rest =>
      if current == name then (name, value) :: rest
      else (current, currentValue) :: replace name value rest

def write (store : Store) (name : Name) (value : Value) : Store :=
  { cells := replace name value store.cells }

end Store

/-- Semantic function calls are resolved by a typed module environment. -/
abbrev CallResolver :=
  ∀ {params result}, FunctionRef params result → List Value → Store → Option (Value × Store)

def noCalls : CallResolver := fun _ _ _ => none

mutual
  /-- Deterministic expression semantics. Failure is represented by `none` and
  promoted to a typed statement failure by `exec`. -/
  def eval
      (resolve : CallResolver)
      (store : Store) : Expr context ty → Env → Option (Value × Store)
    | .load slot, env => (·, store) <$> lookup slot env
    | .read ref, _ => (·, store) <$> store.read ref.name
    | .unit, _ => some (.unit, store)
    | .bool value, _ => some (.bool value, store)
    | .u8 value, _ => some (.u8 value, store)
    | .u32 value, _ => some (.u32 value, store)
    | .i64 value, _ => some (.i64 value, store)
    | .u64 value, _ => some (.u64 value, store)
    | .f64 value, _ => some (.f64 value, store)
    | .text value _, _ => some (.text value, store)
    | .bind bound body, env => do
        let (value, afterBound) ← eval resolve store bound env
        eval resolve afterBound body (value :: env)
    | .branch condition thenExpr elseExpr, env => do
        let (.bool selected, afterCondition) ← eval resolve store condition env | none
        if selected then eval resolve afterCondition thenExpr env
        else eval resolve afterCondition elseExpr env
    | .not value, env => do
        let (.bool result, afterValue) ← eval resolve store value env | none
        some (.bool (!result), afterValue)
    | .and left right, env => do
        let (.bool leftValue, afterLeft) ← eval resolve store left env | none
        let (.bool rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue && rightValue), afterRight)
    | .or left right, env => do
        let (.bool leftValue, afterLeft) ← eval resolve store left env | none
        let (.bool rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue || rightValue), afterRight)
    | .checkedAdd left right, env => do
        let (.i64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.i64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        let result ← I64.add leftValue rightValue
        some (.i64 result, afterRight)
    | .checkedSub left right, env => do
        let (.i64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.i64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        let result ← I64.sub leftValue rightValue
        some (.i64 result, afterRight)
    | .checkedMul left right, env => do
        let (.i64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.i64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        let result ← I64.mul leftValue rightValue
        some (.i64 result, afterRight)
    | .eqU8 left right, env => do
        let (.u8 leftValue, afterLeft) ← eval resolve store left env | none
        let (.u8 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value == rightValue.value), afterRight)
    | .eqU32 left right, env => do
        let (.u32 leftValue, afterLeft) ← eval resolve store left env | none
        let (.u32 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value == rightValue.value), afterRight)
    | .eqU64 left right, env => do
        let (.u64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.u64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value == rightValue.value), afterRight)
    | .eqI64 left right, env => do
        let (.i64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.i64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value == rightValue.value), afterRight)
    | .ltU64 left right, env => do
        let (.u64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.u64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value < rightValue.value), afterRight)
    | .ltI64 left right, env => do
        let (.i64 leftValue, afterLeft) ← eval resolve store left env | none
        let (.i64 rightValue, afterRight) ← eval resolve afterLeft right env | none
        some (.bool (leftValue.value < rightValue.value), afterRight)
    | .struct fields, env => do
        let (values, afterFields) ← evalRecord resolve store fields env
        some (.record values, afterFields)
    | .field record member, env => do
        let (.record fields, afterRecord) ← eval resolve store record env | none
        let value ← recordGet member fields
        some (value, afterRecord)
    | .vector values, env => do
        let (items, afterItems) ← evalVector resolve store values env
        some (.vector items, afterItems)
    | .index vector index, env => do
        let (.vector values, afterVector) ← eval resolve store vector env | none
        let (.u64 offset, afterIndex) ← eval resolve afterVector index env | none
        let value ← values[offset.value]?
        some (value, afterIndex)
    | .tagged member payload, env => do
        let (value, afterPayload) ← eval resolve store payload env
        some (.sum (memberName member) value, afterPayload)
    | .call function args, env => do
        let (values, afterArgs) ← evalArgs resolve store args env
        resolve function values afterArgs

  def evalRecord
      (resolve : CallResolver)
      (store : Store) : RecordExpr context fields → Env → Option (List (Name × Value) × Store)
    | .nil, _ => some ([], store)
    | .cons name field rest, env => do
        let (value, afterField) ← eval resolve store field env
        let (values, afterRest) ← evalRecord resolve afterField rest env
        some ((name, value) :: values, afterRest)

  def evalVector
      (resolve : CallResolver)
      (store : Store) : VectorExpr context element capacity → Env → Option (List Value × Store)
    | .nil, _ => some ([], store)
    | .cons head tail, env => do
        let (value, afterHead) ← eval resolve store head env
        let (values, afterTail) ← evalVector resolve afterHead tail env
        some (value :: values, afterTail)

  def evalArgs
      (resolve : CallResolver)
      (store : Store) : Args context params → Env → Option (List Value × Store)
    | .nil, _ => some ([], store)
    | .cons head tail, env => do
        let (value, afterHead) ← eval resolve store head env
        let (values, afterTail) ← evalArgs resolve afterHead tail env
        some (value :: values, afterTail)
end

mutual
  /-- Closed expression semantics used by NativePure refinement. Storage reads
  and semantic calls are intentionally unavailable in this projection. -/
  def evalClosed : Expr context ty → Env → Option Value
    | .load slot, env => lookup slot env
    | .read _, _ => none
    | .unit, _ => some .unit
    | .bool value, _ => some (.bool value)
    | .u8 value, _ => some (.u8 value)
    | .u32 value, _ => some (.u32 value)
    | .i64 value, _ => some (.i64 value)
    | .u64 value, _ => some (.u64 value)
    | .f64 value, _ => some (.f64 value)
    | .text value _, _ => some (.text value)
    | .bind bound body, env => do
        let value ← evalClosed bound env
        evalClosed body (value :: env)
    | .branch condition thenExpr elseExpr, env => do
        let .bool selected ← evalClosed condition env | none
        if selected then evalClosed thenExpr env else evalClosed elseExpr env
    | .not value, env => do
        let .bool result ← evalClosed value env | none
        some (.bool (!result))
    | .and left right, env => do
        let .bool leftValue ← evalClosed left env | none
        let .bool rightValue ← evalClosed right env | none
        some (.bool (leftValue && rightValue))
    | .or left right, env => do
        let .bool leftValue ← evalClosed left env | none
        let .bool rightValue ← evalClosed right env | none
        some (.bool (leftValue || rightValue))
    | .checkedAdd left right, env => do
        let .i64 leftValue ← evalClosed left env | none
        let .i64 rightValue ← evalClosed right env | none
        .i64 <$> I64.add leftValue rightValue
    | .checkedSub left right, env => do
        let .i64 leftValue ← evalClosed left env | none
        let .i64 rightValue ← evalClosed right env | none
        .i64 <$> I64.sub leftValue rightValue
    | .checkedMul left right, env => do
        let .i64 leftValue ← evalClosed left env | none
        let .i64 rightValue ← evalClosed right env | none
        .i64 <$> I64.mul leftValue rightValue
    | .eqU8 left right, env => do
        let .u8 leftValue ← evalClosed left env | none
        let .u8 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .eqU32 left right, env => do
        let .u32 leftValue ← evalClosed left env | none
        let .u32 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .eqU64 left right, env => do
        let .u64 leftValue ← evalClosed left env | none
        let .u64 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .eqI64 left right, env => do
        let .i64 leftValue ← evalClosed left env | none
        let .i64 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .ltU64 left right, env => do
        let .u64 leftValue ← evalClosed left env | none
        let .u64 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value < rightValue.value))
    | .ltI64 left right, env => do
        let .i64 leftValue ← evalClosed left env | none
        let .i64 rightValue ← evalClosed right env | none
        some (.bool (leftValue.value < rightValue.value))
    | .struct fields, env => .record <$> evalClosedRecord fields env
    | .field record member, env => do
        let .record fields ← evalClosed record env | none
        recordGet member fields
    | .vector values, env => .vector <$> evalClosedVector values env
    | .index vector index, env => do
        let .vector values ← evalClosed vector env | none
        let .u64 offset ← evalClosed index env | none
        values[offset.value]?
    | .tagged member payload, env => .sum (memberName member) <$> evalClosed payload env
    | .call _ _, _ => none

  def evalClosedRecord : RecordExpr context fields → Env → Option (List (Name × Value))
    | .nil, _ => some []
    | .cons name field rest, env => do
        let value ← evalClosed field env
        let values ← evalClosedRecord rest env
        some ((name, value) :: values)

  def evalClosedVector : VectorExpr context element capacity → Env → Option (List Value)
    | .nil, _ => some []
    | .cons head tail, env => do
        let value ← evalClosed head env
        let values ← evalClosedVector tail env
        some (value :: values)
end

/-- Explicit deterministic failure channel. -/
inductive Failure where
  | typeMismatch
  | arithmeticOverflow
  | bounds
  | capacity
  | invalidTag
  | explicit (code : Nat)
  deriving DecidableEq, Repr

mutual
  /-- Typed statements. All loops carry a static bound and may not recurse. -/
  inductive Stmt : List Ty → Ty → Type where
    | ret : Expr context result → Stmt context result
    | fail : Failure → Stmt context result
    | letS : Expr context bound → Stmt (bound :: context) result → Stmt context result
    | store
        (target : Ref ty)
        (writable : target.access ≠ .read)
        (value : Expr context ty)
        (next : Stmt context result) : Stmt context result
    | branch
        (condition : Expr context .bool)
        (thenStmt elseStmt : Stmt context result) : Stmt context result
    | boundedFor
        (bound : Nat)
        (withinU64 : bound < 2 ^ 64)
        (body : Stmt (.u64 :: context) .unit)
        (next : Stmt context result) : Stmt context result
    | switch
        (scrutinee : Expr context (.sum variants))
        (cases : Cases context result variants) : Stmt context result

  /-- One exhaustive body for each statically declared sum variant. -/
  inductive Cases : List Ty → Ty → List (Name × Ty) → Type where
    | nil : Cases context result []
    | cons
        (label : Name)
        (body : Stmt (payload :: context) result)
        (rest : Cases context result variants) :
        Cases context result ((label, payload) :: variants)
end

/-- Result of executing one semantic function body. -/
inductive Outcome where
  | returned (value : Value) (store : Store)
  | failed (failure : Failure) (store : Store)
  | exhausted
  deriving Repr

private def outcomeValue : Outcome → Option Value
  | .returned value _ => some value
  | .failed _ _ => none
  | .exhausted => none

private def outcomeFailure : Outcome → Option Failure
  | .returned _ _ => none
  | .failed failure _ => some failure
  | .exhausted => none

private def valueBool : Value → Option Bool
  | .unit => none
  | .bool value => some value
  | .u8 _ => none
  | .u32 _ => none
  | .i64 _ => none
  | .u64 _ => none
  | .f64 _ => none
  | .text _ => none
  | .vector _ => none
  | .record _ => none
  | .sum _ _ => none

private def valueSum : Value → Option (Name × Value)
  | .unit => none
  | .bool _ => none
  | .u8 _ => none
  | .u32 _ => none
  | .i64 _ => none
  | .u64 _ => none
  | .f64 _ => none
  | .text _ => none
  | .vector _ => none
  | .record _ => none
  | .sum label payload => some (label, payload)

private def valueU64 : Value → Option Nat
  | .unit => none
  | .bool _ => none
  | .u8 _ => none
  | .u32 _ => none
  | .i64 _ => none
  | .u64 value => some value.value
  | .f64 _ => none
  | .text _ => none
  | .vector _ => none
  | .record _ => none
  | .sum _ _ => none

mutual
  /-- Fuelled operational statement semantics. The bounded-loop constructor
  also limits every loop independently of fuel. -/
  def exec
      (resolve : CallResolver) : Nat → Stmt context result → Env → Store → Outcome
    | 0, _, _, _ => .exhausted
    | _fuel + 1, .ret value, env, store =>
        match eval resolve store value env with
        | some (result, afterValue) => .returned result afterValue
        | none => .failed .typeMismatch store
    | _, .fail failure, _, store => .failed failure store
    | fuel + 1, .letS value body, env, store =>
        match eval resolve store value env with
        | some (bound, afterValue) => exec resolve fuel body (bound :: env) afterValue
        | none => .failed .typeMismatch store
    | fuel + 1, .store target _ value next, env, store =>
        match eval resolve store value env with
        | some (stored, afterValue) =>
            exec resolve fuel next env (afterValue.write target.name stored)
        | none => .failed .typeMismatch store
    | fuel + 1, .branch condition thenStmt elseStmt, env, store =>
        match eval resolve store condition env with
        | none => .failed .typeMismatch store
        | some (value, afterCondition) =>
            match valueBool value with
            | some selected =>
                if selected then exec resolve fuel thenStmt env afterCondition
                else exec resolve fuel elseStmt env afterCondition
            | none => .failed .typeMismatch store
    | fuel + 1, .boundedFor bound _ body next, env, store =>
        match execLoop resolve fuel body env (List.range bound) store with
        | .returned .unit afterLoop => exec resolve fuel next env afterLoop
        | .returned _ afterLoop => .failed .typeMismatch afterLoop
        | .failed failure afterLoop => .failed failure afterLoop
        | .exhausted => .exhausted
    | fuel + 1, .switch scrutinee cases, env, store =>
        match eval resolve store scrutinee env with
        | none => .failed .typeMismatch store
        | some (value, afterScrutinee) =>
            match valueSum value with
            | some (label, payload) =>
                execCases resolve fuel cases label payload env afterScrutinee
            | none => .failed .typeMismatch store

  def execCases
      (resolve : CallResolver) :
      Nat → Cases context result variants → Name → Value → Env → Store → Outcome
    | 0, _, _, _, _, _ => .exhausted
    | _, .nil, _, _, _, store => .failed .invalidTag store
    | fuel + 1, .cons label body rest, selected, payload, env, store =>
        if selected == label then exec resolve fuel body (payload :: env) store
        else execCases resolve fuel rest selected payload env store

  def execLoop
      (resolve : CallResolver)
      : Nat → Stmt (.u64 :: context) .unit → Env → List Nat → Store → Outcome
    | 0, _, _, _, _ => .exhausted
    | _, _, _, [], store => .returned .unit store
    | fuel + 1, body, env, index :: rest, store =>
        if inRange : index < 2 ^ 64 then
          match exec resolve fuel body (.u64 { value := index, upper := inRange } :: env) store with
          | .returned .unit afterBody => execLoop resolve fuel body env rest afterBody
          | .returned _ afterBody => .failed .typeMismatch afterBody
          | .failed failure afterBody => .failed failure afterBody
          | .exhausted => .exhausted
        else .failed .bounds store
end

/-- Typed function signature. -/
structure Signature where
  params : List Ty
  result : Ty
  deriving Repr

/-- One total semantic function body before concrete C layout/rendering. -/
structure Function (signature : Signature) where
  name : Name
  body : Stmt signature.params signature.result

inductive SomeFunction where
  | mk (signature : Signature) (function : Function signature)

/-- Fixed record declaration retained for concrete layout lowering. -/
structure StructDecl where
  name : Name
  fields : List (Name × Ty)
  deriving Repr

/-- Fixed tagged-sum declaration retained for concrete layout lowering. -/
structure SumDecl where
  name : Name
  variants : List (Name × Ty)
  deriving Repr

structure Global (ty : Ty) where
  name : Name
  storage : StorageClass
  initial : Option Value := none
  deriving Repr

inductive SomeGlobal where
  | mk (ty : Ty) (global : Global ty)

/-- Semantic module assembled by scheduler and region lowering. -/
structure Module where
  structs : List StructDecl := []
  sums : List SumDecl := []
  globals : List SomeGlobal := []
  functions : List SomeFunction := []

def runFunction
    (resolve : CallResolver)
    (fuel : Nat)
    (function : Function signature)
    (arguments : List Value)
    (store : Store := {}) : Outcome :=
  exec resolve fuel function.body arguments store

/-! ### Executable basis checks -/

private def loopSmokeSignature : Signature :=
  { params := [], result := .bool }

private def loopSmoke : Function loopSmokeSignature :=
  { name := "loop_smoke"
  , body :=
      .boundedFor
        3
        (by decide)
        (.ret .unit)
        (.ret (.bool true))
  }

example : (outcomeValue (runFunction noCalls 16 loopSmoke [])).bind valueBool = some true := by
  native_decide

private def storedValue : Ref .u64 :=
  { name := "result", storage := .output, access := .readWrite }

private def storeSmokeSignature : Signature :=
  { params := [.u64], result := .u64 }

private def storeSmoke : Function storeSmokeSignature :=
  { name := "store_smoke"
  , body :=
      .store
        storedValue
        (by decide)
        (.load .zero)
        (.ret (.read storedValue))
  }

example :
    (outcomeValue
          (runFunction
            noCalls
            8
            storeSmoke
            [.u64 { value := 7, upper := by decide }])).bind valueU64 =
      some 7 := by
  native_decide

private def sumSmokeSignature : Signature :=
  { params := [.sum [("left", .bool), ("right", .i64)]], result := .bool }

private def sumSmoke : Function sumSmokeSignature :=
  { name := "sum_smoke"
  , body :=
      .switch
        (.load .zero)
        (.cons "left" (.ret (.load .zero))
          (.cons "right" (.ret (.bool false)) .nil))
  }

example :
    (outcomeValue
          (runFunction noCalls 8 sumSmoke [.sum "left" (.bool true)])).bind valueBool =
      some true := by
  native_decide

private def failureSmokeSignature : Signature :=
  { params := [], result := .unit }

private def failureSmoke : Function failureSmokeSignature :=
  { name := "failure_smoke", body := .fail (.explicit 7) }

example : outcomeFailure (runFunction noCalls 2 failureSmoke []) = some (.explicit 7) := by
  native_decide

end Cortex.Wire.SemanticC
