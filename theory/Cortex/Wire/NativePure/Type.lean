import Mathlib.Data.Int.Basic

/-!
## NativePure representation types

This module owns the closed value algebra shared by the authored NativePure
kernel and the semantic C IR. `u8` and `u32` are target-internal scalar types;
registry `native_shape/v1` projections continue to expose only the documented
Wire crossing algebra.
-/

namespace Cortex.Wire.NativePure

abbrev Name := String

/-- Closed, bounded native representation algebra. -/
inductive Ty where
  | unit
  | bool
  | u8
  | u32
  | i64
  | u64
  | f64
  | text (capacity : Nat)
  | vector (capacity : Nat) (element : Ty)
  | record (fields : List (Name × Ty))
  | sum (variants : List (Name × Ty))
  deriving Repr

/-- A label/type pair occurs in a fixed record or sum description. -/
inductive Member : Name → Ty → List (Name × Ty) → Type where
  | head : Member name ty ((name, ty) :: rest)
  | tail : Member name ty rest → Member name ty (other :: rest)

/-- Signed integer whose constructor carries the checked-i64 invariant. -/
structure I64 where
  value : Int
  lower : -(2 ^ 63 : Int) ≤ value
  upper : value < (2 ^ 63 : Int)
  deriving DecidableEq, Repr

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

/-- Unsigned integer whose constructor carries the uint8 invariant. -/
structure U8 where
  value : Nat
  upper : value < 2 ^ 8
  deriving DecidableEq, Repr

/-- Unsigned integer whose constructor carries the uint32 invariant. -/
structure U32 where
  value : Nat
  upper : value < 2 ^ 32
  deriving DecidableEq, Repr

/-- Unsigned integer whose constructor carries the uint64 invariant. -/
structure U64 where
  value : Nat
  upper : value < 2 ^ 64
  deriving DecidableEq, Repr

/-- Erased runtime carrier. Expression indices are the typing authority. -/
inductive Value where
  | unit
  | bool (value : Bool)
  | u8 (value : U8)
  | u32 (value : U32)
  | i64 (value : I64)
  | u64 (value : U64)
  | f64 (value : Float)
  | text (value : String)
  | vector (values : List Value)
  | record (fields : List (Name × Value))
  | sum (label : Name) (payload : Value)
  deriving Repr

/-- De Bruijn lookup proving that a variable has the requested type. -/
inductive Var : List Ty → Ty → Type where
  | zero : Var (ty :: context) ty
  | succ : Var context ty → Var (other :: context) ty

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

end Cortex.Wire.NativePure
