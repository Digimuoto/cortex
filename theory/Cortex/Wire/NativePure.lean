import Mathlib.Data.Int.Basic
import Mathlib.Data.List.Nodup

/-!
## NativePure v1 certified kernel

The broad CorePure surface is intended to elaborate into this small
intrinsically typed kernel once the elaboration boundary lands; today the
kernel is the certified target model and no elaborator exists yet. One source
PureWire node yields one `CertifiedKernel`; cross-node fusion is deliberately
deferred. Values are immutable. The only storage classification introduced
after lowering is `read` for inputs and `write` for fresh outputs.

The proof-local typed target calculus is a separate inductive that currently
mirrors the source kernel constructor-for-constructor. It is not the shared
semantic C IR or a printable C AST; those arrive in later epic slices.
`lower` is total and `lower_refines` proves executable semantic preservation
only for expressions carrying structural/checked-i64 basis evidence. Binary64
values remain representable, but expressions containing them are explicitly
outside that refinement theorem.
-/

namespace Cortex.Wire.NativePure

abbrev Name := String

/-- Closed, bounded crossing representation algebra. -/
inductive Ty where
  | unit
  | bool
  | i64
  | u64
  | f64
  | text (capacity : Nat)
  | vector (capacity : Nat) (element : Ty)
  | record (fields : List (Name × Ty))
  | sum (variants : List (Name × Ty))

/-- A label/type pair occurs in a fixed record or sum description. -/
inductive Member : Name → Ty → List (Name × Ty) → Type where
  | head : Member name ty ((name, ty) :: rest)
  | tail : Member name ty rest → Member name ty (other :: rest)

/-- Signed integer whose constructor carries the checked-i64 invariant. -/
structure I64 where
  value : Int
  lower : -(2 ^ 63 : Int) ≤ value
  upper : value < (2 ^ 63 : Int)

namespace I64

def checked (value : Int) : Option I64 :=
  if lower : -(2 ^ 63 : Int) ≤ value then
    if upper : value < (2 ^ 63 : Int) then
      some { value, lower, upper }
    else none
  else none

def add (left right : I64) : Option I64 := checked (left.value + right.value)
def sub (left right : I64) : Option I64 := checked (left.value - right.value)
def mul (left right : I64) : Option I64 := checked (left.value * right.value)

end I64

/-- Unsigned integer whose constructor carries the uint64 invariant. -/
structure U64 where
  value : Nat
  upper : value < 2 ^ 64

/-- Erased runtime carrier. Expression indices are the typing authority. -/
inductive Value where
  | unit
  | bool (value : Bool)
  | i64 (value : I64)
  | u64 (value : U64)
  | f64 (value : Float)
  | text (value : String)
  | vector (values : List Value)
  | record (fields : List (Name × Value))
  | sum (label : Name) (payload : Value)

/-- De Bruijn lookup proving that a variable has the requested type. -/
inductive Var : List Ty → Ty → Type where
  | zero : Var (ty :: context) ty
  | succ : Var context ty → Var (other :: context) ty

mutual
  /-- Tiny intrinsically typed PureWire kernel. -/
  inductive Expr : List Ty → Ty → Type where
    | var : Var context ty → Expr context ty
    | unit : Expr context .unit
    | bool : Bool → Expr context .bool
    | i64 : I64 → Expr context .i64
    | u64 : U64 → Expr context .u64
    | f64 : Float → Expr context .f64
    | text
        (value : String)
        (bounded : value.toUTF8.size ≤ capacity) : Expr context (.text capacity)
    | letE : Expr context bound → Expr (bound :: context) result → Expr context result
    | ifE : Expr context .bool → Expr context ty → Expr context ty → Expr context ty
    | not : Expr context .bool → Expr context .bool
    | and : Expr context .bool → Expr context .bool → Expr context .bool
    | or : Expr context .bool → Expr context .bool → Expr context .bool
    | add : Expr context .i64 → Expr context .i64 → Expr context .i64
    | sub : Expr context .i64 → Expr context .i64 → Expr context .i64
    | mul : Expr context .i64 → Expr context .i64 → Expr context .i64
    | eqI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | ltI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | record : RecordExpr context fields → Expr context (.record fields)
    | project : Expr context (.record fields) → Member name ty fields → Expr context ty
    | inject : Member label payload variants → Expr context payload → Expr context (.sum variants)

  /-- Expression for every field in one fixed record. -/
  inductive RecordExpr : List Ty → List (Name × Ty) → Type where
    | nil : RecordExpr context []
    | cons
        (name : Name)
        (field : Expr context ty)
        (rest : RecordExpr context fields) : RecordExpr context ((name, ty) :: fields)
end

mutual
  /-- Representation types admitted by the structural/checked-i64 refinement
  theorem. Binary64 remains a layout type, but is validated separately. -/
  def RefinementTy : Ty → Prop
    | .unit | .bool | .i64 | .u64 => True
    | .f64 => False
    | .text _ => True
    | .vector _ element => RefinementTy element
    | .record fields | .sum fields => RefinementFields fields

  def RefinementFields : List (Name × Ty) → Prop
    | [] => True
    | (_, field) :: rest => RefinementTy field ∧ RefinementFields rest
end

mutual
  /-- Evidence that an expression lies in the theorem-bearing structural and
  checked-i64 basis. In particular, a binary64 literal, variable, record field,
  or sum payload cannot obtain this evidence. -/
  def RefinementExpr {context ty} : Expr context ty → Prop
    | .var _ => RefinementTy ty
    | .unit | .bool _ | .i64 _ | .u64 _ | .text _ _ => True
    | .f64 _ => False
    | .letE bound body => RefinementExpr bound ∧ RefinementExpr body
    | .ifE condition thenExpr elseExpr =>
        RefinementExpr condition ∧ RefinementExpr thenExpr ∧ RefinementExpr elseExpr
    | .not value => RefinementExpr value
    | .and left right | .or left right | .add left right | .sub left right
    | .mul left right | .eqI64 left right | .ltI64 left right =>
        RefinementExpr left ∧ RefinementExpr right
    | .record fields => RefinementRecord fields
    | .project record _ => RefinementExpr record ∧ RefinementTy ty
    | .inject _ payload => RefinementExpr payload ∧ RefinementTy ty

  def RefinementRecord {context fields} : RecordExpr context fields → Prop
    | .nil => True
    | .cons _ field rest => RefinementExpr field ∧ RefinementRecord rest
end

abbrev Env := List Value

def lookup : Var context ty → Env → Option Value
  | .zero, value :: _ => some value
  | .succ slot, _ :: rest => lookup slot rest
  | _, [] => none

def memberName : Member name ty fields → Name
  | .head => name
  | .tail member => memberName member

def recordGet : Member name ty fields → List (Name × Value) → Option Value
  | .head, (_, value) :: _ => some value
  | .tail member, _ :: rest => recordGet member rest
  | _, [] => none

mutual
  /-- Executable, deterministic, authority-free kernel semantics. -/
  def eval : Expr context ty → Env → Option Value
    | .var slot, env => lookup slot env
    | .unit, _ => some .unit
    | .bool value, _ => some (.bool value)
    | .i64 value, _ => some (.i64 value)
    | .u64 value, _ => some (.u64 value)
    | .f64 value, _ => some (.f64 value)
    | .text value _, _ => some (.text value)
    | .letE bound body, env => do
        let value ← eval bound env
        eval body (value :: env)
    | .ifE condition thenExpr elseExpr, env => do
        let .bool selected ← eval condition env | none
        if selected then eval thenExpr env else eval elseExpr env
    | .not value, env => do
        let .bool result ← eval value env | none
        some (.bool (!result))
    | .and left right, env => do
        let .bool leftValue ← eval left env | none
        let .bool rightValue ← eval right env | none
        some (.bool (leftValue && rightValue))
    | .or left right, env => do
        let .bool leftValue ← eval left env | none
        let .bool rightValue ← eval right env | none
        some (.bool (leftValue || rightValue))
    | .add left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.add leftValue rightValue
    | .sub left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.sub leftValue rightValue
    | .mul left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.mul leftValue rightValue
    | .eqI64 left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .ltI64 left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        some (.bool (leftValue.value < rightValue.value))
    | .record fields, env => .record <$> evalRecord fields env
    | .project record member, env => do
        let .record fields ← eval record env | none
        recordGet member fields
    | .inject member payload, env => .sum (memberName member) <$> eval payload env

  def evalRecord : RecordExpr context fields → Env → Option (List (Name × Value))
    | .nil, _ => some []
    | .cons name field rest, env => do
        let value ← eval field env
        let values ← evalRecord rest env
        some ((name, value) :: values)

end

/-! ### Typed C subset -/

namespace C

mutual
  inductive Expr : List Ty → Ty → Type where
    | load : Var context ty → Expr context ty
    | unit : Expr context .unit
    | bool : Bool → Expr context .bool
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
    | eqI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | ltI64 : Expr context .i64 → Expr context .i64 → Expr context .bool
    | struct : RecordExpr context fields → Expr context (.record fields)
    | field : Expr context (.record fields) → Member name ty fields → Expr context ty
    | tagged : Member label payload variants → Expr context payload → Expr context (.sum variants)

  inductive RecordExpr : List Ty → List (Name × Ty) → Type where
    | nil : RecordExpr context []
    | cons
        (name : Name)
        (field : Expr context ty)
        (rest : RecordExpr context fields) : RecordExpr context ((name, ty) :: fields)
end

mutual
  def eval : C.Expr context ty → Env → Option Value
    | .load slot, env => lookup slot env
    | .unit, _ => some .unit
    | .bool value, _ => some (.bool value)
    | .i64 value, _ => some (.i64 value)
    | .u64 value, _ => some (.u64 value)
    | .f64 value, _ => some (.f64 value)
    | .text value _, _ => some (.text value)
    | .bind bound body, env => do
        let value ← eval bound env
        eval body (value :: env)
    | .branch condition thenExpr elseExpr, env => do
        let .bool selected ← eval condition env | none
        if selected then eval thenExpr env else eval elseExpr env
    | .not value, env => do
        let .bool result ← eval value env | none
        some (.bool (!result))
    | .and left right, env => do
        let .bool leftValue ← eval left env | none
        let .bool rightValue ← eval right env | none
        some (.bool (leftValue && rightValue))
    | .or left right, env => do
        let .bool leftValue ← eval left env | none
        let .bool rightValue ← eval right env | none
        some (.bool (leftValue || rightValue))
    | .checkedAdd left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.add leftValue rightValue
    | .checkedSub left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.sub leftValue rightValue
    | .checkedMul left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        .i64 <$> I64.mul leftValue rightValue
    | .eqI64 left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        some (.bool (leftValue.value == rightValue.value))
    | .ltI64 left right, env => do
        let .i64 leftValue ← eval left env | none
        let .i64 rightValue ← eval right env | none
        some (.bool (leftValue.value < rightValue.value))
    | .struct fields, env => .record <$> evalRecord fields env
    | .field record member, env => do
        let .record fields ← eval record env | none
        recordGet member fields
    | .tagged member payload, env => .sum (memberName member) <$> eval payload env

  def evalRecord : C.RecordExpr context fields → Env → Option (List (Name × Value))
    | .nil, _ => some []
    | .cons name field rest, env => do
        let value ← eval field env
        let values ← evalRecord rest env
        some ((name, value) :: values)

end

end C

mutual
  /-- Total constructive source-to-C-IR lowering. -/
  def lower : Expr context ty → C.Expr context ty
    | .var slot => .load slot
    | .unit => .unit
    | .bool value => .bool value
    | .i64 value => .i64 value
    | .u64 value => .u64 value
    | .f64 value => .f64 value
    | .text value bounded => .text value bounded
    | .letE bound body => .bind (lower bound) (lower body)
    | .ifE condition thenExpr elseExpr =>
        .branch (lower condition) (lower thenExpr) (lower elseExpr)
    | .not value => .not (lower value)
    | .and left right => .and (lower left) (lower right)
    | .or left right => .or (lower left) (lower right)
    | .add left right => .checkedAdd (lower left) (lower right)
    | .sub left right => .checkedSub (lower left) (lower right)
    | .mul left right => .checkedMul (lower left) (lower right)
    | .eqI64 left right => .eqI64 (lower left) (lower right)
    | .ltI64 left right => .ltI64 (lower left) (lower right)
    | .record fields => .struct (lowerRecord fields)
    | .project record member => .field (lower record) member
    | .inject member payload => .tagged member (lower payload)

  def lowerRecord : RecordExpr context fields → C.RecordExpr context fields
    | .nil => .nil
    | .cons name field rest => .cons name (lower field) (lowerRecord rest)
end

/-- Structural and checked-i64 operations refine the executable source semantics. -/
theorem lower_refines
    (expr : Expr context ty) (_basis : RefinementExpr expr) (env : Env) :
    C.eval (lower expr) env = eval expr env := by
  clear _basis
  revert env
  apply Expr.rec
    (motive_1 := fun _ _ expr => ∀ env, C.eval (lower expr) env = eval expr env)
    (motive_2 := fun _ _ fields => ∀ env,
      C.evalRecord (lowerRecord fields) env = evalRecord fields env) <;>
    simp_all [lower, lowerRecord, C.eval, C.evalRecord, eval, evalRecord]

/-! ### First-class bounds and minimal post-lowering regions -/

/-- Round `value` up to the next multiple of `alignment`. -/
def alignUp (value alignment : Nat) : Nat :=
  if alignment ≤ 1 then value
  else value + (alignment - value % alignment) % alignment

mutual
  /-- Fixed C layout `(size, alignment)` including record and tagged-sum
  padding. Mirrors the Haskell `nativeShapeLayout`; record and sum entries are
  expected in the canonical sorted-label order the Haskell `Map` emits. -/
  def layout : Ty → Nat × Nat
    | .unit => (1, 1)
    | .bool => (1, 1)
    | .i64 => (8, 8)
    | .u64 => (8, 8)
    | .f64 => (8, 8)
    | .text capacity => (alignUp (4 + capacity) 4, 4)
    | .vector capacity element =>
        let (elementSize, elementAlign) := layout element
        let alignment := max 4 elementAlign
        (alignUp (4 + capacity * elementSize) alignment, alignment)
    | .record fields =>
        let (size, alignment) := recordLayout fields 0 1
        (alignUp size alignment, alignment)
    | .sum variants =>
        let (payloadSize, payloadAlign) := sumLayout variants
        let alignment := max 4 payloadAlign
        (alignUp (alignUp 4 payloadAlign + payloadSize) alignment, alignment)

  /-- Fold field layouts left-to-right: each field is placed at its aligned
  offset and the aggregate alignment is the maximum field alignment. -/
  def recordLayout : List (Name × Ty) → Nat → Nat → Nat × Nat
    | [], offset, alignment => (offset, alignment)
    | (_, field) :: rest, offset, alignment =>
        let (fieldSize, fieldAlign) := layout field
        recordLayout rest (alignUp offset fieldAlign + fieldSize) (max alignment fieldAlign)

  /-- Payload `(size, alignment)` of a tagged sum: maxima over the variants. -/
  def sumLayout : List (Name × Ty) → Nat × Nat
    | [] => (0, 1)
    | (_, payload) :: rest =>
        let (payloadSize, payloadAlign) := layout payload
        let (restSize, restAlign) := sumLayout rest
        (max payloadSize restSize, max payloadAlign restAlign)
end

/-- Layout size in bytes, padding included. -/
def sizeOf (ty : Ty) : Nat := (layout ty).1

/-- Layout alignment in bytes. -/
def alignOf (ty : Ty) : Nat := (layout ty).2

example : layout (.text 5) = (12, 4) := by native_decide

example : layout (.record [("flag", .bool), ("score", .i64)]) = (16, 8) := by
  native_decide

example : layout (.sum [("none", .unit), ("some", .i64)]) = (16, 8) := by
  native_decide

/-- Labels are nonblank (Haskell rejects whitespace-only labels) and strictly
ascending — the canonical `Map.toAscList` order the Haskell projection emits.
Strict ascent also yields distinctness, and it pins the field order the
padding-aware `layout` computes over: permuting fields changes offsets. -/
def LabelsCanonical (labels : List Name) : Prop :=
  (∀ label ∈ labels, label.trimAscii.isEmpty = false) ∧ labels.Pairwise (· < ·)

mutual
  /-- The Haskell `NativeShape` algebra rejects empty containers and blank
  labels, and its `Map` representation fixes sorted-label order. The Lean list
  representation carries the same discipline as a predicate so a kernel type
  cannot silently depend on a shape or field order the projection would never
  produce. -/
  def WellFormedTy : Ty → Prop
    | .unit => True
    | .bool => True
    | .i64 => True
    | .u64 => True
    | .f64 => True
    | .text capacity => 0 < capacity
    | .vector capacity element => 0 < capacity ∧ WellFormedTy element
    | .record fields =>
        fields ≠ [] ∧ LabelsCanonical (fields.map Prod.fst) ∧ WellFormedFields fields
    | .sum variants =>
        variants ≠ [] ∧ LabelsCanonical (variants.map Prod.fst) ∧ WellFormedFields variants

  def WellFormedFields : List (Name × Ty) → Prop
    | [] => True
    | (_, field) :: rest => WellFormedTy field ∧ WellFormedFields rest
end

example : WellFormedTy (.record [("flag", .bool), ("score", .i64)]) := by
  (simp [WellFormedTy, WellFormedFields, LabelsCanonical]; native_decide)

example : ¬ WellFormedTy (.record [("score", .i64), ("flag", .bool)]) := by
  simp [WellFormedTy, WellFormedFields, LabelsCanonical]

example : ¬ WellFormedTy (.sum [("", .unit), ("some", .i64)]) := by
  (simp [WellFormedTy, WellFormedFields, LabelsCanonical]; native_decide)

mutual
  def steps : Expr context ty → Nat
    | .var _ | .unit | .bool _ | .i64 _ | .u64 _ | .f64 _ | .text _ _ => 1
    | .letE bound body => 1 + steps bound + steps body
    | .ifE condition thenExpr elseExpr =>
        1 + steps condition + max (steps thenExpr) (steps elseExpr)
    | .not value => 1 + steps value
    | .and left right | .or left right | .add left right | .sub left right
    | .mul left right | .eqI64 left right | .ltI64 left right => 1 + steps left + steps right
    | .record fields => 1 + recordSteps fields
    | .project record _ => 1 + steps record
    | .inject _ payload => 1 + steps payload

  def recordSteps : RecordExpr context fields → Nat
    | .nil => 0
    | .cons _ field rest => steps field + recordSteps rest
end

structure ResourceBounds where
  stackBytes : Nat
  staticBytes : Nat
  outputBytes : Nat
  checkpointBytes : Nat
  maxSteps : Nat
  checkpointWithinHostedCeiling : checkpointBytes ≤ 2 * 1024 * 1024

inductive Access where
  | read
  | write
  deriving DecidableEq, Repr

structure Region where
  name : Name
  access : Access
  capacity : Nat
  alignment : Nat
  deriving Repr

/-- Writes are fresh and disjoint from all reads; read/read aliasing is allowed. -/
def RegionsWellFormed (regions : List Region) : Prop :=
  let writes := (regions.filter (fun region => region.access = .write)).map (·.name)
  let reads := (regions.filter (fun region => region.access = .read)).map (·.name)
  writes.Nodup ∧ ∀ name ∈ writes, name ∉ reads

/-- One source PureWire node and its typed/bounded realization evidence. The
declared bounds are tied to the body: a kernel cannot claim fewer worst-case
steps than its body costs or a smaller output than its output layout. -/
structure CertifiedKernel where
  sourceNode : Name
  inputs : List Ty
  output : Ty
  body : Expr inputs output
  bounds : ResourceBounds
  regions : List Region
  regionsWellFormed : RegionsWellFormed regions
  inputsWellFormed : ∀ ty ∈ inputs, WellFormedTy ty
  outputWellFormed : WellFormedTy output
  refinementBasis : RefinementExpr body
  stepsSound : steps body ≤ bounds.maxSteps
  outputSound : sizeOf output ≤ bounds.outputBytes

def CertifiedKernel.target (kernel : CertifiedKernel) : C.Expr kernel.inputs kernel.output :=
  lower kernel.body

theorem CertifiedKernel.target_refines
    (kernel : CertifiedKernel) (env : Env) :
    C.eval kernel.target env = eval kernel.body env :=
  lower_refines kernel.body kernel.refinementBasis env

end Cortex.Wire.NativePure
