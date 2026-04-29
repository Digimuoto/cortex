import Mathlib.Data.Finset.Basic
import Mathlib.Data.Int.Basic

/-!
## Overview

Proof-facing model of Wire's CorePure subset and native pure-task lowering.

## Context

Wire pure output equations use a deterministic expression layer. The Haskell
implementation evaluates JSON-shaped values and lowers one
source pure node to one internal native pure task with top-level bindings, an
optional `where` expression, and output expressions.

This module does not prove the Haskell evaluator correct. It gives the Lean
track a small executable model for the first proof slice: integers, booleans,
records, field access, non-recursive sequential `let`, `if`, record merge, and
simple operators. ADR 0010 keeps authority behind registered executor
boundaries, and ADR 0023 keeps CorePure in the deterministic expression layer;
accordingly, `Expr` has no constructors for executor calls, rewrites,
durable-state reads, tools, model calls, or host callbacks.

ADR 0023 makes duplicate record fields an upstream parse/elaboration error.
The evaluator remains deterministic outside the admitted surface, but duplicate
field overwrite is not an intended record-literal semantics.

For static `where` fields, ADR 0031 settles the source surface in favor of the
Haskell behavior: local CorePure `let` bindings are evaluated at runtime but are
not expanded by static field discovery. Module-level let-declared records are
represented by the initial `StaticContext`.

## Theorem Split

The page defines values, expressions, deterministic evaluation, static
`where`-field discovery, pure-node admission, native pure-task lowering, and
the local soundness side condition needed when a `where` expression contains
CorePure `let`. The facts are local to this proof model; no theorem here claims
that the Haskell evaluator or compiler already produces these Lean witnesses.
The `where` soundness chain is exported for downstream output-value and contract
proofs; the output-key theorems in this file are structural and do not need it.
-/

namespace Cortex.Wire

/-! ## CorePure Subset -/

namespace CorePure

/-- CorePure names for variables, fields, ports, and output labels. -/
abbrev Name : Type := String

/-- `EvalError` is the deterministic typed failure surface for this proof subset. -/
inductive EvalError : Type where
  | missingVariable : Name → EvalError
  | missingField : Name → EvalError
  | expectedBool : EvalError
  | expectedInt : EvalError
  | expectedRecord : EvalError
  | duplicateBinding : Name → EvalError
  deriving Repr

/-- `Value` is the JSON-shaped value subset modeled by the first proof pass. -/
inductive Value : Type where
  | null : Value
  | bool : Bool → Value
  | int : Int → Value
  | string : String → Value
  | record : (Name → Option Value) → Value

/-- Runtime CorePure environment. -/
abbrev Env : Type := Name → Option Value

namespace Env

/-- Empty runtime environment. -/
def empty : Env :=
  fun _name => none

/-- Insert or shadow a runtime binding. -/
def insert (name : Name) (value : Value) (env : Env) : Env :=
  fun candidate => if candidate = name then some value else env candidate

end Env

/-- Static context for expressions known to expose record fields. -/
abbrev StaticContext : Type := Name → Option (Finset Name)

namespace StaticContext

/-- Empty static field context. -/
def empty : StaticContext :=
  fun _name => none

/-- Insert or shadow a static field binding. `none` deliberately shadows an outer record. -/
def insert (name : Name) (fields : Option (Finset Name)) (ctx : StaticContext) :
    StaticContext :=
  fun candidate => if candidate = name then fields else ctx candidate

/-- Hide static record facts for names opened by a node-local `where` record. -/
def hideFields (fields : Finset Name) (ctx : StaticContext) : StaticContext :=
  fun candidate => if candidate ∈ fields then none else ctx candidate

end StaticContext

/-- Unary operators in the modeled CorePure subset. -/
inductive UnaryOp : Type where
  | not
  | negate

/-- Binary operators in the modeled CorePure subset. -/
inductive BinaryOp : Type where
  | add
  | subtract
  | multiply
  | and
  | or
  | merge

/-- CorePure expression subset for the first proof slice. -/
inductive Expr : Type where
  | lit : Value → Expr
  | var : Name → Expr
  | record : List (Name × Expr) → Expr
  | field : Expr → Name → Expr
  | letE : List (Name × Expr) → Expr → Expr
  | ifE : Expr → Expr → Expr → Expr
  | unary : UnaryOp → Expr → Expr
  | binary : BinaryOp → Expr → Expr → Expr

namespace Value

/-- Interpret a value as a boolean or fail deterministically. -/
def asBool : Value → Except EvalError Bool
  | null => Except.error EvalError.expectedBool
  | bool value => Except.ok value
  | int _value => Except.error EvalError.expectedBool
  | string _value => Except.error EvalError.expectedBool
  | record _fields => Except.error EvalError.expectedBool

/-- Interpret a value as an integer or fail deterministically. -/
def asInt : Value → Except EvalError Int
  | null => Except.error EvalError.expectedInt
  | bool _value => Except.error EvalError.expectedInt
  | int value => Except.ok value
  | string _value => Except.error EvalError.expectedInt
  | record _fields => Except.error EvalError.expectedInt

/-- Interpret a value as a record or fail deterministically. -/
def asRecord : Value → Except EvalError (Name → Option Value)
  | null => Except.error EvalError.expectedRecord
  | bool _value => Except.error EvalError.expectedRecord
  | int _value => Except.error EvalError.expectedRecord
  | string _value => Except.error EvalError.expectedRecord
  | record fields => Except.ok fields

/-- `hasOnlyFields value fields` says a record value exposes no keys outside `fields`. -/
def hasOnlyFields (value : Value) (fields : Finset Name) : Prop :=
  match value with
  | record recordFields =>
      ∀ name fieldValue, recordFields name = some fieldValue → name ∈ fields
  | null => False
  | bool _value => False
  | int _value => False
  | string _value => False

end Value

/-! ## Record Helpers -/

/-- Convert evaluated field pairs to a record lookup function.

Admitted CorePure record literals must reject duplicate fields before evaluation. The right-biased
fallback here only makes the proof-side evaluator total on raw lists. -/
def recordFromValues : List (Name × Value) → Name → Option Value
  | [], _name => none
  | (fieldName, fieldValue) :: rest, name =>
      match recordFromValues rest name with
      | some value => some value
      | none => if name = fieldName then some fieldValue else none

/-- Names present in a field-expression list. -/
def fieldNameSet (fields : List (Name × Expr)) : Finset Name :=
  fields.foldr (fun field acc => insert field.1 acc) ∅

/-- Names present in an evaluated field-value list. -/
def valueFieldNameSet (fields : List (Name × Value)) : Finset Name :=
  fields.foldr (fun field acc => insert field.1 acc) ∅

/-- Right-biased record merge for the modeled CorePure `merge` operator. -/
def mergeRecordFields
    (leftFields rightFields : Name → Option Value) :
    Name → Option Value :=
  fun name =>
    match rightFields name with
    | some value => some value
    | none => leftFields name

/-- `recordFromValues` exposes only names present in its input field list. -/
theorem recordFromValues_hasOnlyFields
    (fields : List (Name × Value)) :
    ∀ name fieldValue,
      recordFromValues fields name = some fieldValue →
        name ∈ valueFieldNameSet fields := by
  induction fields with
  | nil =>
      intro name fieldValue hLookup
      simp [recordFromValues] at hLookup
  | cons field rest ih =>
      intro name fieldValue hLookup
      rcases field with ⟨fieldName, currentValue⟩
      by_cases hName : name = fieldName
      · simp [valueFieldNameSet, hName]
      · cases hRest : recordFromValues rest name with
        | some restValue =>
            have hMember := ih name restValue hRest
            change name ∈ insert fieldName (valueFieldNameSet rest)
            exact Finset.mem_insert.mpr (Or.inr hMember)
        | none =>
            simp [recordFromValues, hRest, hName] at hLookup

/-- Every name present in an evaluated field-value list has a concrete record lookup. -/
theorem recordFromValues_field_present
    {fields : List (Name × Value)}
    {name : Name}
    (hName : name ∈ valueFieldNameSet fields) :
    ∃ fieldValue, recordFromValues fields name = some fieldValue := by
  induction fields with
  | nil =>
      simp [valueFieldNameSet] at hName
  | cons field rest ih =>
      rcases field with ⟨fieldName, currentValue⟩
      by_cases hCurrent : name = fieldName
      · subst fieldName
        cases hRest : recordFromValues rest name with
        | some restValue =>
            exact ⟨restValue, by simp [recordFromValues, hRest]⟩
        | none =>
            exact ⟨currentValue, by simp [recordFromValues, hRest]⟩
      · have hRestName : name ∈ valueFieldNameSet rest := by
          have hInserted : name ∈ insert fieldName (valueFieldNameSet rest) := by
            simpa [valueFieldNameSet] using hName
          exact (Finset.mem_insert.mp hInserted).resolve_left hCurrent
        obtain ⟨restValue, hRestLookup⟩ := ih hRestName
        exact ⟨restValue, by simp [recordFromValues, hRestLookup]⟩

/-! ## Evaluation -/

/-- Find the first duplicate name in a list, if one exists. -/
def duplicateName : List Name → Option Name
  | [] => none
  | name :: rest =>
      if name ∈ rest then some name else duplicateName rest

mutual

/-- Evaluate a CorePure expression in a runtime environment. -/
def eval (env : Env) : Expr → Except EvalError Value
  | Expr.lit value => Except.ok value
  | Expr.var name =>
      match env name with
      | some value => Except.ok value
      | none => Except.error (EvalError.missingVariable name)
  | Expr.record fields =>
      match evalFields env fields with
      | Except.ok values => Except.ok (Value.record (recordFromValues values))
      | Except.error err => Except.error err
  | Expr.field base fieldName => do
      let baseRecord ← (← eval env base).asRecord
      match baseRecord fieldName with
      | some value => Except.ok value
      | none => Except.error (EvalError.missingField fieldName)
  | Expr.letE bindings body =>
      match evalBindings env bindings with
      | Except.ok localEnv => eval localEnv body
      | Except.error err => Except.error err
  | Expr.ifE condition thenExpr elseExpr => do
      let conditionValue ← (← eval env condition).asBool
      if conditionValue then eval env thenExpr else eval env elseExpr
  | Expr.unary op operand => do
      match op with
      | UnaryOp.not =>
          Except.ok (Value.bool (!(← (← eval env operand).asBool)))
      | UnaryOp.negate =>
          Except.ok (Value.int (-(← (← eval env operand).asInt)))
  | Expr.binary op left right => do
      match op with
      | BinaryOp.add =>
          Except.ok (Value.int ((← (← eval env left).asInt) + (← (← eval env right).asInt)))
      | BinaryOp.subtract =>
          Except.ok (Value.int ((← (← eval env left).asInt) - (← (← eval env right).asInt)))
      | BinaryOp.multiply =>
          Except.ok (Value.int ((← (← eval env left).asInt) * (← (← eval env right).asInt)))
      | BinaryOp.and =>
          let leftValue ← (← eval env left).asBool
          if leftValue then
            Except.ok (Value.bool (← (← eval env right).asBool))
          else
            Except.ok (Value.bool false)
      | BinaryOp.or =>
          let leftValue ← (← eval env left).asBool
          if leftValue then
            Except.ok (Value.bool true)
          else
            Except.ok (Value.bool (← (← eval env right).asBool))
      | BinaryOp.merge =>
          match eval env left with
          | Except.error err => Except.error err
          | Except.ok Value.null => Except.error EvalError.expectedRecord
          | Except.ok (Value.bool _value) => Except.error EvalError.expectedRecord
          | Except.ok (Value.int _value) => Except.error EvalError.expectedRecord
          | Except.ok (Value.string _value) => Except.error EvalError.expectedRecord
          | Except.ok (Value.record leftRecord) =>
              match eval env right with
              | Except.error err => Except.error err
              | Except.ok Value.null => Except.error EvalError.expectedRecord
              | Except.ok (Value.bool _value) => Except.error EvalError.expectedRecord
              | Except.ok (Value.int _value) => Except.error EvalError.expectedRecord
              | Except.ok (Value.string _value) => Except.error EvalError.expectedRecord
              | Except.ok (Value.record rightRecord) =>
                  Except.ok (Value.record (mergeRecordFields leftRecord rightRecord))

/-- Evaluate record fields independently in the same environment. -/
def evalFields (env : Env) :
    List (Name × Expr) → Except EvalError (List (Name × Value))
  | [] => Except.ok []
  | (fieldName, fieldExpr) :: rest =>
      match eval env fieldExpr with
      | Except.ok fieldValue =>
          match evalFields env rest with
          | Except.ok restValues => Except.ok ((fieldName, fieldValue) :: restValues)
          | Except.error err => Except.error err
      | Except.error err => Except.error err

/-- Evaluate non-recursive sequential `let` bindings. -/
def evalBindings (env : Env) :
    List (Name × Expr) → Except EvalError Env
  | bindings =>
      match duplicateName (bindings.map Prod.fst) with
      | some name => Except.error (EvalError.duplicateBinding name)
      | none => evalBindingsNoDuplicate env bindings

/-- Evaluate bindings after duplicate names have been rejected. -/
def evalBindingsNoDuplicate (env : Env) :
    List (Name × Expr) → Except EvalError Env
  | [] => Except.ok env
  | (bindingName, bindingExpr) :: rest =>
      match eval env bindingExpr with
      | Except.ok bindingValue =>
          evalBindingsNoDuplicate (Env.insert bindingName bindingValue env) rest
      | Except.error err => Except.error err

end

/-- Evaluating fields preserves their field-name set. -/
theorem evalFields_preserves_names
    {env : Env}
    {fields : List (Name × Expr)}
    {values : List (Name × Value)}
    (hEval : evalFields env fields = Except.ok values) :
    valueFieldNameSet values = fieldNameSet fields := by
  induction fields generalizing values with
  | nil =>
      simp [evalFields] at hEval
      cases hEval
      rfl
  | cons field rest ih =>
      rcases field with ⟨fieldName, fieldExpr⟩
      simp [evalFields] at hEval
      cases hField : eval env fieldExpr with
      | error err =>
          simp [hField] at hEval
      | ok fieldValue =>
          simp [hField] at hEval
          cases hRest : evalFields env rest with
          | error err =>
              simp [hRest] at hEval
          | ok restValues =>
              simp [hRest] at hEval
              cases hEval
              change insert fieldName (valueFieldNameSet restValues) =
                insert fieldName (fieldNameSet rest)
              rw [ih hRest]

/-- Record expressions evaluate to records containing only their statically named fields. -/
theorem eval_record_hasOnlyFields
    {env : Env}
    {fields : List (Name × Expr)}
    {recordFields : Name → Option Value}
    (hEval : eval env (Expr.record fields) = Except.ok (Value.record recordFields)) :
    ∀ name fieldValue,
      recordFields name = some fieldValue →
        name ∈ fieldNameSet fields := by
  simp [eval] at hEval
  cases hFields : evalFields env fields with
  | error err =>
      simp [hFields] at hEval
  | ok values =>
      simp [hFields] at hEval
      cases hEval
      intro name fieldValue hLookup
      have hMember := recordFromValues_hasOnlyFields values name fieldValue hLookup
      have hNames := evalFields_preserves_names hFields
      simpa [hNames] using hMember

/-- Record expressions evaluate to values containing only their statically named fields. -/
theorem eval_record_value_hasOnlyFields
    {env : Env}
    {fields : List (Name × Expr)}
    {value : Value}
    (hEval : eval env (Expr.record fields) = Except.ok value) :
    Value.hasOnlyFields value (fieldNameSet fields) := by
  cases hFields : evalFields env fields with
  | error err =>
      simp [eval, hFields] at hEval
  | ok values =>
      simp [eval, hFields] at hEval
      cases hEval
      have hNames := evalFields_preserves_names hFields
      simpa [Value.hasOnlyFields, hNames] using recordFromValues_hasOnlyFields values

/-- Right-biased record merge exposes only fields from either input record. -/
theorem mergeRecordFields_hasOnlyFields
    {leftFields rightFields : Name → Option Value}
    {leftStatic rightStatic : Finset Name}
    (hLeft : Value.hasOnlyFields (Value.record leftFields) leftStatic)
    (hRight : Value.hasOnlyFields (Value.record rightFields) rightStatic) :
    Value.hasOnlyFields
      (Value.record (mergeRecordFields leftFields rightFields))
      (leftStatic ∪ rightStatic) := by
  intro name fieldValue hLookup
  cases hRightLookup : rightFields name with
  | some rightValue =>
      have hRightMember := hRight name rightValue hRightLookup
      exact Finset.mem_union.mpr (Or.inr hRightMember)
  | none =>
      have hLeftLookup : leftFields name = some fieldValue := by
        simpa [mergeRecordFields, hRightLookup] using hLookup
      have hLeftMember := hLeft name fieldValue hLeftLookup
      exact Finset.mem_union.mpr (Or.inl hLeftMember)

/-! ## Static `where` Field Discovery -/

/-- Static field discovery for expressions used as node-local `where` clauses. -/
def whereStaticFields (ctx : StaticContext) : Expr → Option (Finset Name)
  | Expr.lit _value => none
  | Expr.record fields => some (fieldNameSet fields)
  | Expr.var name => ctx name
  | Expr.field _base _fieldName => none
  | Expr.letE _bindings body => whereStaticFields ctx body
  | Expr.ifE _condition _thenExpr _elseExpr => none
  | Expr.unary _op _operand => none
  | Expr.binary BinaryOp.merge left right =>
      match whereStaticFields ctx left, whereStaticFields ctx right with
      | some leftFields, some rightFields => some (leftFields ∪ rightFields)
      | some _leftFields, none => none
      | none, some _rightFields => none
      | none, none => none
  | Expr.binary BinaryOp.add _left _right => none
  | Expr.binary BinaryOp.subtract _left _right => none
  | Expr.binary BinaryOp.multiply _left _right => none
  | Expr.binary BinaryOp.and _left _right => none
  | Expr.binary BinaryOp.or _left _right => none

/-- Runtime environments match the static context for known record bindings. -/
def EnvMatchesStatic (env : Env) (ctx : StaticContext) : Prop :=
  ∀ name fields value,
    ctx name = some fields →
      env name = some value →
        Value.hasOnlyFields value fields

/-- Local CorePure `let` bindings do not shadow statically known module-level records. -/
def letBindingsDoNotShadowStatic
    (ctx : StaticContext) :
    List (Name × Expr) → Prop
  | [] => True
  | (bindingName, _bindingExpr) :: rest =>
      ctx bindingName = none ∧ letBindingsDoNotShadowStatic ctx rest

/-- Side condition for expressions whose local `let` binders preserve static discovery soundness. -/
def Expr.staticLetSafe (ctx : StaticContext) : Expr → Prop
  | Expr.lit _value => True
  | Expr.record _fields => True
  | Expr.var _name => True
  | Expr.field _base _fieldName => True
  | Expr.letE bindings body =>
      letBindingsDoNotShadowStatic ctx bindings ∧ Expr.staticLetSafe ctx body
  | Expr.ifE _condition _thenExpr _elseExpr => True
  | Expr.unary _op _operand => True
  | Expr.binary BinaryOp.merge left right =>
      Expr.staticLetSafe ctx left ∧ Expr.staticLetSafe ctx right
  | Expr.binary BinaryOp.add _left _right => True
  | Expr.binary BinaryOp.subtract _left _right => True
  | Expr.binary BinaryOp.multiply _left _right => True
  | Expr.binary BinaryOp.and _left _right => True
  | Expr.binary BinaryOp.or _left _right => True

/-- Static field discovery succeeds for record literals with exactly their field-name set. -/
theorem where_staticFields_record
    (ctx : StaticContext)
    (fields : List (Name × Expr)) :
    whereStaticFields ctx (Expr.record fields) = some (fieldNameSet fields) :=
  rfl

/-- Static field discovery for merge is the union of both record field sets. -/
theorem where_staticFields_merge
    {ctx : StaticContext}
    {left right : Expr}
    {leftFields rightFields : Finset Name}
    (hLeft : whereStaticFields ctx left = some leftFields)
    (hRight : whereStaticFields ctx right = some rightFields) :
    whereStaticFields ctx (Expr.binary BinaryOp.merge left right) =
      some (leftFields ∪ rightFields) := by
  simp [whereStaticFields, hLeft, hRight]

/-- Static field discovery for `let` checks only the final body expression. -/
theorem where_staticFields_let
    (ctx : StaticContext)
    (bindings : List (Name × Expr))
    (body : Expr) :
    whereStaticFields ctx (Expr.letE bindings body) =
      whereStaticFields ctx body :=
  rfl

/-- Evaluated non-duplicate bindings preserve the static context when they do not shadow it. -/
theorem evalBindingsNoDuplicate_preserves_static_context
    {ctx : StaticContext}
    {env localEnv : Env}
    {bindings : List (Name × Expr)}
    (hMatch : EnvMatchesStatic env ctx)
    (hNoShadow : letBindingsDoNotShadowStatic ctx bindings)
    (hEval : evalBindingsNoDuplicate env bindings = Except.ok localEnv) :
    EnvMatchesStatic localEnv ctx := by
  induction bindings generalizing ctx env localEnv with
  | nil =>
      simp [evalBindingsNoDuplicate] at hEval
      cases hEval
      exact hMatch
  | cons head tail ih =>
      rcases head with ⟨bindingName, bindingExpr⟩
      have hHeadNoShadow : ctx bindingName = none := hNoShadow.1
      have hTailNoShadow : letBindingsDoNotShadowStatic ctx tail := hNoShadow.2
      simp [evalBindingsNoDuplicate] at hEval
      cases hBindingEval : eval env bindingExpr with
      | error err =>
          simp [hBindingEval] at hEval
      | ok bindingValue =>
          simp [hBindingEval] at hEval
          have hNextMatch :
              EnvMatchesStatic (Env.insert bindingName bindingValue env) ctx := by
            intro candidate fields value hStaticLookup hEnvLookup
            simp [Env.insert] at hEnvLookup
            by_cases hCandidate : candidate = bindingName
            · rw [hCandidate] at hStaticLookup
              simp [hHeadNoShadow] at hStaticLookup
            · simp [hCandidate] at hEnvLookup
              exact hMatch candidate fields value hStaticLookup hEnvLookup
          exact ih hNextMatch hTailNoShadow hEval

/-- Runtime binding evaluation preserves the static context when it succeeds without shadowing. -/
theorem evalBindings_preserves_static_context
    {ctx : StaticContext}
    {env localEnv : Env}
    {bindings : List (Name × Expr)}
    (hMatch : EnvMatchesStatic env ctx)
    (hNoShadow : letBindingsDoNotShadowStatic ctx bindings)
    (hEval : evalBindings env bindings = Except.ok localEnv) :
    EnvMatchesStatic localEnv ctx := by
  cases hDuplicate : duplicateName (bindings.map Prod.fst) with
  | some duplicate =>
      simp [evalBindings, hDuplicate] at hEval
  | none =>
      have hNoDuplicateEval :
          evalBindingsNoDuplicate env bindings = Except.ok localEnv := by
        simpa [evalBindings, hDuplicate] using hEval
      exact evalBindingsNoDuplicate_preserves_static_context hMatch hNoShadow hNoDuplicateEval

/-- Runtime merge evaluation preserves the union of the statically admitted fields. -/
private theorem eval_merge_hasOnlyFields
    {ctx : StaticContext}
    {env : Env}
    {left right : Expr}
    {leftFields rightFields : Finset Name}
    {value : Value}
    (hLeftSafe : Expr.staticLetSafe ctx left)
    (hRightSafe : Expr.staticLetSafe ctx right)
    (hMatch : EnvMatchesStatic env ctx)
    (hLeftStatic : whereStaticFields ctx left = some leftFields)
    (hRightStatic : whereStaticFields ctx right = some rightFields)
    (hEval : eval env (Expr.binary BinaryOp.merge left right) = Except.ok value)
    (leftIH :
      ∀ {ctx : StaticContext}
        {env : Env}
        {fields : Finset Name}
        {value : Value},
        Expr.staticLetSafe ctx left →
          EnvMatchesStatic env ctx →
            whereStaticFields ctx left = some fields →
              eval env left = Except.ok value →
                Value.hasOnlyFields value fields)
    (rightIH :
      ∀ {ctx : StaticContext}
        {env : Env}
        {fields : Finset Name}
        {value : Value},
        Expr.staticLetSafe ctx right →
          EnvMatchesStatic env ctx →
            whereStaticFields ctx right = some fields →
              eval env right = Except.ok value →
                Value.hasOnlyFields value fields) :
    Value.hasOnlyFields value (leftFields ∪ rightFields) := by
  cases hLeftEval : eval env left with
  | error err =>
      simp [eval, hLeftEval] at hEval
  | ok leftValue =>
      cases leftValue with
      | null =>
          simp [eval, hLeftEval] at hEval
      | bool leftBool =>
          simp [eval, hLeftEval] at hEval
      | int leftInt =>
          simp [eval, hLeftEval] at hEval
      | string leftString =>
          simp [eval, hLeftEval] at hEval
      | record leftRecord =>
          cases hRightEval : eval env right with
          | error err =>
              simp [eval, hLeftEval, hRightEval] at hEval
          | ok rightValue =>
              cases rightValue with
              | null =>
                  simp [eval, hLeftEval, hRightEval] at hEval
              | bool rightBool =>
                  simp [eval, hLeftEval, hRightEval] at hEval
              | int rightInt =>
                  simp [eval, hLeftEval, hRightEval] at hEval
              | string rightString =>
                  simp [eval, hLeftEval, hRightEval] at hEval
              | record rightRecord =>
                  simp [eval, hLeftEval, hRightEval] at hEval
                  cases hEval
                  have hLeftHas :=
                    leftIH hLeftSafe hMatch hLeftStatic hLeftEval
                  have hRightHas :=
                    rightIH hRightSafe hMatch hRightStatic hRightEval
                  exact mergeRecordFields_hasOnlyFields hLeftHas hRightHas

/-- Core recursive proof for static `where` field soundness. -/
private theorem whereStaticFields_sound_expr
    (expr : Expr) :
    ∀ {ctx : StaticContext}
      {env : Env}
      {fields : Finset Name}
      {value : Value},
      Expr.staticLetSafe ctx expr →
        EnvMatchesStatic env ctx →
          whereStaticFields ctx expr = some fields →
            eval env expr = Except.ok value →
              Value.hasOnlyFields value fields :=
  Expr.rec
    (motive_1 := fun expr =>
      ∀ {ctx : StaticContext}
        {env : Env}
        {fields : Finset Name}
        {value : Value},
        Expr.staticLetSafe ctx expr →
          EnvMatchesStatic env ctx →
            whereStaticFields ctx expr = some fields →
              eval env expr = Except.ok value →
                Value.hasOnlyFields value fields)
    (motive_2 := fun _bindings => True)
    (motive_3 := fun _binding => True)
    (fun literalValue {ctx env fields value} hSafe hMatch hStatic hEval => by
      simp [whereStaticFields] at hStatic)
    (fun name {ctx env fields value} hSafe hMatch hStatic hEval => by
      exact hMatch name fields value hStatic (by
        cases hLookup : env name with
        | none =>
            simp [eval, hLookup] at hEval
        | some envValue =>
            simp [eval, hLookup] at hEval
            cases hEval
            rfl))
    (fun fields _fieldsIH {ctx env staticFields value} hSafe hMatch hStatic hEval => by
      cases hStatic
      exact eval_record_value_hasOnlyFields hEval)
    (fun base fieldName _baseIH {ctx env fields value} hSafe hMatch hStatic hEval => by
      simp [whereStaticFields] at hStatic)
    (fun bindings body _bindingsIH bodyIH {ctx env fields value} hSafe hMatch hStatic hEval => by
      have hNoShadow : letBindingsDoNotShadowStatic ctx bindings := hSafe.1
      have hBodySafe : Expr.staticLetSafe ctx body := hSafe.2
      simp [whereStaticFields] at hStatic
      cases hBindings : evalBindings env bindings with
      | error err =>
          simp [eval, hBindings] at hEval
      | ok localEnv =>
          have hLocalMatch : EnvMatchesStatic localEnv ctx :=
            evalBindings_preserves_static_context hMatch hNoShadow hBindings
          have hBodyEval : eval localEnv body = Except.ok value := by
            simpa [eval, hBindings] using hEval
          exact bodyIH hBodySafe hLocalMatch hStatic hBodyEval)
    (fun condition thenExpr elseExpr _conditionIH _thenIH _elseIH {ctx env fields value}
        hSafe hMatch hStatic hEval => by
      simp [whereStaticFields] at hStatic)
    (fun op operand _operandIH {ctx env fields value} hSafe hMatch hStatic hEval => by
      simp [whereStaticFields] at hStatic)
    (fun op left right leftIH rightIH {ctx env fields value} hSafe hMatch hStatic hEval => by
      cases op with
      | add =>
          simp [whereStaticFields] at hStatic
      | subtract =>
          simp [whereStaticFields] at hStatic
      | multiply =>
          simp [whereStaticFields] at hStatic
      | and =>
          simp [whereStaticFields] at hStatic
      | or =>
          simp [whereStaticFields] at hStatic
      | merge =>
          have hLeftSafe : Expr.staticLetSafe ctx left := hSafe.1
          have hRightSafe : Expr.staticLetSafe ctx right := hSafe.2
          cases hLeftStatic : whereStaticFields ctx left with
          | none =>
              cases hRightStatic : whereStaticFields ctx right with
              | none =>
                  simp [whereStaticFields, hLeftStatic, hRightStatic] at hStatic
              | some rightFields =>
                  simp [whereStaticFields, hLeftStatic, hRightStatic] at hStatic
          | some leftFields =>
              cases hRightStatic : whereStaticFields ctx right with
              | none =>
                  simp [whereStaticFields, hLeftStatic, hRightStatic] at hStatic
              | some rightFields =>
                  simp [whereStaticFields, hLeftStatic, hRightStatic] at hStatic
                  cases hStatic
                  exact
                    eval_merge_hasOnlyFields
                      hLeftSafe hRightSafe hMatch hLeftStatic hRightStatic hEval leftIH rightIH)
    True.intro
    (fun head tail _headIH _tailIH => True.intro)
    (fun bindingName bindingExpr _exprIH => True.intro)
    expr

/-- Static field discovery is sound for safe expressions in matching runtime environments. -/
theorem whereStaticFields_sound
    {ctx : StaticContext}
    {env : Env}
    {expr : Expr}
    {fields : Finset Name}
    {value : Value}
    (hSafe : Expr.staticLetSafe ctx expr)
    (hMatch : EnvMatchesStatic env ctx)
    (hStatic : whereStaticFields ctx expr = some fields)
    (hEval : eval env expr = Except.ok value) :
    Value.hasOnlyFields value fields :=
  whereStaticFields_sound_expr expr hSafe hMatch hStatic hEval

/-! ## Pure Node Lowering -/

/-- Pure output equation in the proof-side lowering model. -/
structure PureOutputEquation where
  /-- Declared output label. -/
  output : Name
  /-- CorePure expression that computes the output value. -/
  expr : Expr

/-- Output labels present in an output-equation list. -/
def outputEquationKeySet (outputs : List PureOutputEquation) : Finset Name :=
  outputs.foldr (fun output acc => insert output.output acc) ∅

/-- Source pure node model needed for lowering proofs. -/
structure PureNode where
  /-- Declared input port names. -/
  inputPorts : Finset Name
  /-- Declared output port names. -/
  outputPorts : Finset Name
  /-- Top-level delayed bindings visible to this node. -/
  bindings : List (Name × Expr)
  /-- Optional node-local `where` expression. -/
  whereExpr : Option Expr
  /-- Output equations. -/
  outputs : List PureOutputEquation

namespace PureNode

/-- Output labels declared by the output-equation map. -/
def outputKeys (node : PureNode) : Finset Name :=
  outputEquationKeySet node.outputs

/-- Static `where` field set, with no fields when the node has no `where` expression. -/
def whereFields (ctx : StaticContext) (node : PureNode) : Option (Finset Name) :=
  match node.whereExpr with
  | none => some ∅
  | some whereExpr => whereStaticFields ctx whereExpr

end PureNode

/-- Admission checks needed before lowering a source pure node. -/
structure PureNodeAdmitted (ctx : StaticContext) (node : PureNode) : Prop where
  /-- Top-level node bindings do not shadow statically known module-level records. -/
  bindings_noShadow : letBindingsDoNotShadowStatic ctx node.bindings
  /-- Output equations match declared output ports exactly. -/
  outputs_match : node.outputKeys = node.outputPorts
  /-- The node-local `where` expression has a statically known field set. -/
  where_static : ∃ fields, node.whereFields ctx = some fields
  /-- Local `let` binders inside the `where` expression preserve static field soundness. -/
  where_letSafe :
    ∀ whereExpr,
      node.whereExpr = some whereExpr →
        Expr.staticLetSafe ctx whereExpr
  /-- Node-local `where` fields do not collide with input port names. -/
  where_noInputCollision :
    ∀ fields,
      node.whereFields ctx = some fields →
        Disjoint fields node.inputPorts

/-- Native pure task configuration produced by lowering. -/
structure NativePureTaskConfig where
  /-- Top-level delayed bindings or captured constants. -/
  bindings : List (Name × Expr)
  /-- Optional node-local `where` expression. -/
  whereExpr : Option Expr
  /-- Output expression map. -/
  outputs : List PureOutputEquation

/-- Lowered node kind used to state that pure nodes lower to one native pure task. -/
inductive LoweredNodeKind : Type where
  | nativePure

/-- Lowered pure node artifact. -/
structure LoweredPureNode where
  /-- Lowered node kind. -/
  kind : LoweredNodeKind
  /-- Native pure task configuration. -/
  config : NativePureTaskConfig

/-- Lower a source pure node to one native pure task. -/
def lowerPureNode (_ctx : StaticContext) (node : PureNode) :
    LoweredPureNode :=
  { kind := LoweredNodeKind.nativePure
    config :=
      { bindings := node.bindings
        whereExpr := node.whereExpr
        outputs := node.outputs } }

/-- Open a record value into an environment, shadowing outer variables by field name. -/
def openRecordIntoEnv (recordFields : Name → Option Value) (env : Env) : Env :=
  fun name =>
    match recordFields name with
    | some value => some value
    | none => env name

/-- Opening a `where` record preserves static facts outside names opened by the record. -/
theorem openRecordIntoEnv_preserves_hidden_static_context
    {ctx : StaticContext}
    {env : Env}
    {recordFields : Name → Option Value}
    {staticFields : Finset Name}
    (hMatch : EnvMatchesStatic env ctx)
    (hRecord : Value.hasOnlyFields (Value.record recordFields) staticFields) :
    EnvMatchesStatic
      (openRecordIntoEnv recordFields env)
      (StaticContext.hideFields staticFields ctx) := by
  intro name fields value hStatic hLocal
  cases hRecordLookup : recordFields name with
  | none =>
      have hOuterLookup : env name = some value := by
        simpa [openRecordIntoEnv, hRecordLookup] using hLocal
      by_cases hMember : name ∈ staticFields
      · have hHidden : StaticContext.hideFields staticFields ctx name = none := by
          simp [StaticContext.hideFields, hMember]
        rw [hHidden] at hStatic
        simp at hStatic
      · have hOuterStatic : ctx name = some fields := by
          simpa [StaticContext.hideFields, hMember] using hStatic
        exact hMatch name fields value hOuterStatic hOuterLookup
  | some openedValue =>
      have hMember : name ∈ staticFields := hRecord name openedValue hRecordLookup
      have hHidden : StaticContext.hideFields staticFields ctx name = none := by
        simp [StaticContext.hideFields, hMember]
      rw [hHidden] at hStatic
      simp at hStatic

/-- Evaluate an optional `where` expression into the local pure-task environment. -/
def evalWhereEnv (env : Env) : Option Expr → Except EvalError Env
  | none => Except.ok env
  | some whereExpr =>
      match eval env whereExpr with
      | Except.error err => Except.error err
      | Except.ok Value.null => Except.error EvalError.expectedRecord
      | Except.ok (Value.bool _value) => Except.error EvalError.expectedRecord
      | Except.ok (Value.int _value) => Except.error EvalError.expectedRecord
      | Except.ok (Value.string _value) => Except.error EvalError.expectedRecord
      | Except.ok (Value.record recordFields) =>
          Except.ok (openRecordIntoEnv recordFields env)

/-- Evaluate output equations in an already prepared pure-task environment. -/
def evalOutputEquationValues (env : Env) :
    List PureOutputEquation → Except EvalError (List (Name × Value))
  | [] => Except.ok []
  | output :: rest =>
      match eval env output.expr with
      | Except.error err => Except.error err
      | Except.ok outputValue =>
          match evalOutputEquationValues env rest with
          | Except.error err => Except.error err
          | Except.ok restValues => Except.ok ((output.output, outputValue) :: restValues)

/-- Convert evaluated output values into the proof-side output lookup surface. -/
def outputLookupFromValues (values : List (Name × Value)) : Name → Option Value :=
  recordFromValues values

/-- Evaluate output equations to a lookup function in an already prepared environment. -/
def evalOutputEquations (env : Env)
    (outputs : List PureOutputEquation) :
    Except EvalError (Name → Option Value) :=
  match evalOutputEquationValues env outputs with
  | Except.error err => Except.error err
  | Except.ok values => Except.ok (outputLookupFromValues values)

/-- Evaluating output equations preserves their declared output-label set. -/
theorem evalOutputEquationValues_preserves_names
    {env : Env}
    {outputs : List PureOutputEquation}
    {values : List (Name × Value)}
    (hEval : evalOutputEquationValues env outputs = Except.ok values) :
    valueFieldNameSet values = outputEquationKeySet outputs := by
  induction outputs generalizing values with
  | nil =>
      simp [evalOutputEquationValues] at hEval
      cases hEval
      rfl
  | cons output rest ih =>
      simp [evalOutputEquationValues] at hEval
      cases hOutputEval : eval env output.expr with
      | error err =>
          simp [hOutputEval] at hEval
      | ok outputValue =>
          simp [hOutputEval] at hEval
          cases hRest : evalOutputEquationValues env rest with
          | error err =>
              simp [hRest] at hEval
          | ok restValues =>
              simp [hRest] at hEval
              cases hEval
              change insert output.output (valueFieldNameSet restValues) =
                insert output.output (outputEquationKeySet rest)
              rw [ih hRest]

/-- Output lookup exposes only names present in the evaluated output-value list. -/
theorem outputLookupFromValues_keys_subset
    {values : List (Name × Value)}
    {name : Name}
    {value : Value}
    (hLookup : outputLookupFromValues values name = some value) :
    name ∈ valueFieldNameSet values :=
  recordFromValues_hasOnlyFields values name value hLookup

/-- Every evaluated output-value name is present in the output lookup. -/
theorem outputLookupFromValues_key_present
    {values : List (Name × Value)}
    {name : Name}
    (hName : name ∈ valueFieldNameSet values) :
    ∃ value, outputLookupFromValues values name = some value :=
  recordFromValues_field_present hName

/-- Successful output-equation evaluation exposes only declared output labels. -/
theorem evalOutputEquations_keys_subset
    {env : Env}
    {outputs : List PureOutputEquation}
    {lookup : Name → Option Value}
    {name : Name}
    {value : Value}
    (hEval : evalOutputEquations env outputs = Except.ok lookup)
    (hLookup : lookup name = some value) :
    name ∈ outputEquationKeySet outputs := by
  cases hValues : evalOutputEquationValues env outputs with
  | error err =>
      simp [evalOutputEquations, hValues] at hEval
  | ok values =>
      simp [evalOutputEquations, hValues] at hEval
      cases hEval
      have hMember := outputLookupFromValues_keys_subset (values := values) hLookup
      have hNames := evalOutputEquationValues_preserves_names hValues
      simpa [hNames] using hMember

/-- Every declared output label is present after successful output-equation evaluation. -/
theorem evalOutputEquations_keys_present
    {env : Env}
    {outputs : List PureOutputEquation}
    {lookup : Name → Option Value}
    {name : Name}
    (hEval : evalOutputEquations env outputs = Except.ok lookup)
    (hName : name ∈ outputEquationKeySet outputs) :
    ∃ value, lookup name = some value := by
  cases hValues : evalOutputEquationValues env outputs with
  | error err =>
      simp [evalOutputEquations, hValues] at hEval
  | ok values =>
      simp [evalOutputEquations, hValues] at hEval
      cases hEval
      have hNames := evalOutputEquationValues_preserves_names hValues
      have hValueName : name ∈ valueFieldNameSet values := by
        simpa [hNames] using hName
      exact outputLookupFromValues_key_present hValueName

namespace PureNode

/-- Evaluate a source pure node to its proof-side output lookup function. -/
def evalOutputs (env : Env) (node : PureNode) :
    Except EvalError (Name → Option Value) :=
  match evalBindings env node.bindings with
  | Except.error err => Except.error err
  | Except.ok outerEnv =>
      match evalWhereEnv outerEnv node.whereExpr with
      | Except.error err => Except.error err
      | Except.ok localEnv => evalOutputEquations localEnv node.outputs

end PureNode

namespace NativePureTaskConfig

/-- Evaluate a native pure-task config to its proof-side output lookup function. -/
def evalOutputs (env : Env) (config : NativePureTaskConfig) :
    Except EvalError (Name → Option Value) :=
  match evalBindings env config.bindings with
  | Except.error err => Except.error err
  | Except.ok outerEnv =>
      match evalWhereEnv outerEnv config.whereExpr with
      | Except.error err => Except.error err
      | Except.ok localEnv => evalOutputEquations localEnv config.outputs

end NativePureTaskConfig

/-- Pure output equation keys match declared ports for admitted pure nodes. -/
theorem pureOutput_keys_match_declaredPorts
    {ctx : StaticContext}
    {node : PureNode}
    (hNode : PureNodeAdmitted ctx node) :
    node.outputKeys = node.outputPorts :=
  hNode.outputs_match

/-- Admitted `where` fields are disjoint from input ports. -/
theorem where_noInputCollision
    {ctx : StaticContext}
    {node : PureNode}
    {fields : Finset Name}
    (hNode : PureNodeAdmitted ctx node)
    (hFields : node.whereFields ctx = some fields) :
    Disjoint fields node.inputPorts :=
  hNode.where_noInputCollision fields hFields

/-- Admitted pure nodes expose a statically known `where` field set. -/
theorem pureNode_whereFields_known
    {ctx : StaticContext}
    {node : PureNode}
    (hNode : PureNodeAdmitted ctx node) :
    ∃ fields, node.whereFields ctx = some fields :=
  hNode.where_static

/-- Admitted node bindings preserve the static context when evaluated. -/
theorem pureNode_bindings_noShadow
    {ctx : StaticContext}
    {node : PureNode}
    (hNode : PureNodeAdmitted ctx node) :
    letBindingsDoNotShadowStatic ctx node.bindings :=
  hNode.bindings_noShadow

/-- Admitted `where` expressions satisfy the local-let safety side condition. -/
theorem pureNode_where_letSafe
    {ctx : StaticContext}
    {node : PureNode}
    {whereExpr : Expr}
    (hNode : PureNodeAdmitted ctx node)
    (hWhere : node.whereExpr = some whereExpr) :
    Expr.staticLetSafe ctx whereExpr :=
  hNode.where_letSafe whereExpr hWhere

/-- Admitted `where` evaluation exposes only the statically admitted fields. -/
theorem pureNode_where_hasOnlyFields
    {ctx : StaticContext}
    {env outerEnv : Env}
    {node : PureNode}
    {whereExpr : Expr}
    {whereFields : Finset Name}
    {whereValue : Value}
    (hNode : PureNodeAdmitted ctx node)
    (hMatch : EnvMatchesStatic env ctx)
    (hBindings : evalBindings env node.bindings = Except.ok outerEnv)
    (hWhere : node.whereExpr = some whereExpr)
    (hStatic : whereStaticFields ctx whereExpr = some whereFields)
    (hEval : eval outerEnv whereExpr = Except.ok whereValue) :
    Value.hasOnlyFields whereValue whereFields := by
  have hOuterMatch : EnvMatchesStatic outerEnv ctx :=
    evalBindings_preserves_static_context hMatch hNode.bindings_noShadow hBindings
  have hSafe : Expr.staticLetSafe ctx whereExpr :=
    hNode.where_letSafe whereExpr hWhere
  exact whereStaticFields_sound hSafe hOuterMatch hStatic hEval

/-- Successful `where` environment evaluation opens a record with statically admitted fields. -/
theorem pureNode_evalWhereEnv_record_hasOnlyFields
    {ctx : StaticContext}
    {env outerEnv localEnv : Env}
    {node : PureNode}
    {whereExpr : Expr}
    {whereFields : Finset Name}
    (hNode : PureNodeAdmitted ctx node)
    (hMatch : EnvMatchesStatic env ctx)
    (hBindings : evalBindings env node.bindings = Except.ok outerEnv)
    (hWhere : node.whereExpr = some whereExpr)
    (hStatic : whereStaticFields ctx whereExpr = some whereFields)
    (hEvalWhere : evalWhereEnv outerEnv node.whereExpr = Except.ok localEnv) :
    ∃ recordFields,
      eval outerEnv whereExpr = Except.ok (Value.record recordFields) ∧
        localEnv = openRecordIntoEnv recordFields outerEnv ∧
          Value.hasOnlyFields (Value.record recordFields) whereFields := by
  simp [evalWhereEnv, hWhere] at hEvalWhere
  cases hEval : eval outerEnv whereExpr with
  | error err =>
      simp [hEval] at hEvalWhere
  | ok whereValue =>
      cases whereValue with
      | null =>
          simp [hEval] at hEvalWhere
      | bool whereBool =>
          simp [hEval] at hEvalWhere
      | int whereInt =>
          simp [hEval] at hEvalWhere
      | string whereString =>
          simp [hEval] at hEvalWhere
      | record recordFields =>
          simp [hEval] at hEvalWhere
          cases hEvalWhere
          have hWhereFields :
              Value.hasOnlyFields (Value.record recordFields) whereFields :=
            pureNode_where_hasOnlyFields hNode hMatch hBindings hWhere hStatic hEval
          exact ⟨recordFields, rfl, rfl, hWhereFields⟩

/-- The environment produced by the `where` step matches static facts outside opened fields. -/
theorem pureNode_evalWhereEnv_localEnv_match_for_fields
    {ctx : StaticContext}
    {env outerEnv localEnv : Env}
    {node : PureNode}
    {whereFields : Finset Name}
    (hNode : PureNodeAdmitted ctx node)
    (hMatch : EnvMatchesStatic env ctx)
    (hBindings : evalBindings env node.bindings = Except.ok outerEnv)
    (hFields : node.whereFields ctx = some whereFields)
    (hEvalWhere : evalWhereEnv outerEnv node.whereExpr = Except.ok localEnv) :
    EnvMatchesStatic localEnv (StaticContext.hideFields whereFields ctx) := by
  have hOuterMatch : EnvMatchesStatic outerEnv ctx :=
    evalBindings_preserves_static_context hMatch hNode.bindings_noShadow hBindings
  cases hWhere : node.whereExpr with
  | none =>
      simp [PureNode.whereFields, hWhere] at hFields
      cases hFields
      simp [evalWhereEnv, hWhere] at hEvalWhere
      cases hEvalWhere
      simpa [StaticContext.hideFields] using hOuterMatch
  | some whereExpr =>
      have hStatic : whereStaticFields ctx whereExpr = some whereFields := by
        simpa [PureNode.whereFields, hWhere] using hFields
      obtain ⟨recordFields, _hEval, hLocalEnv, hRecordFields⟩ :=
        pureNode_evalWhereEnv_record_hasOnlyFields
          hNode hMatch hBindings hWhere hStatic hEvalWhere
      cases hLocalEnv
      exact
        openRecordIntoEnv_preserves_hidden_static_context hOuterMatch hRecordFields

/-- The environment produced by the `where` step matches a hidden admitted static context. -/
theorem pureNode_evalWhereEnv_localEnv_match
    {ctx : StaticContext}
    {env outerEnv localEnv : Env}
    {node : PureNode}
    (hNode : PureNodeAdmitted ctx node)
    (hMatch : EnvMatchesStatic env ctx)
    (hBindings : evalBindings env node.bindings = Except.ok outerEnv)
    (hEvalWhere : evalWhereEnv outerEnv node.whereExpr = Except.ok localEnv) :
    ∃ whereFields,
      node.whereFields ctx = some whereFields ∧
        EnvMatchesStatic localEnv (StaticContext.hideFields whereFields ctx) := by
  obtain ⟨whereFields, hFields⟩ := hNode.where_static
  exact
    ⟨ whereFields,
      hFields,
      pureNode_evalWhereEnv_localEnv_match_for_fields
        hNode hMatch hBindings hFields hEvalWhere ⟩

/-- Successful source pure-node evaluation exposes only declared output ports. -/
theorem pureNode_evalOutputs_keys_in_outputPorts
    {ctx : StaticContext}
    {env : Env}
    {node : PureNode}
    {lookup : Name → Option Value}
    (hNode : PureNodeAdmitted ctx node)
    (hEval : node.evalOutputs env = Except.ok lookup) :
    ∀ name value, lookup name = some value → name ∈ node.outputPorts := by
  cases hBindings : evalBindings env node.bindings with
  | error err =>
      simp [PureNode.evalOutputs, hBindings] at hEval
  | ok outerEnv =>
      cases hWhere : evalWhereEnv outerEnv node.whereExpr with
      | error err =>
          simp [PureNode.evalOutputs, hBindings, hWhere] at hEval
      | ok localEnv =>
          have hOutputEval :
              evalOutputEquations localEnv node.outputs = Except.ok lookup := by
            simpa [PureNode.evalOutputs, hBindings, hWhere] using hEval
          intro name value hLookup
          have hMember := evalOutputEquations_keys_subset hOutputEval hLookup
          have hOutputKey : name ∈ node.outputKeys := by
            simpa [PureNode.outputKeys] using hMember
          simpa [hNode.outputs_match] using hOutputKey

/-- Successful source pure-node evaluation produces every declared output port. -/
theorem pureNode_evalOutputs_outputPorts_present
    {ctx : StaticContext}
    {env : Env}
    {node : PureNode}
    {lookup : Name → Option Value}
    (hNode : PureNodeAdmitted ctx node)
    (hEval : node.evalOutputs env = Except.ok lookup) :
    ∀ name, name ∈ node.outputPorts → ∃ value, lookup name = some value := by
  cases hBindings : evalBindings env node.bindings with
  | error err =>
      simp [PureNode.evalOutputs, hBindings] at hEval
  | ok outerEnv =>
      cases hWhere : evalWhereEnv outerEnv node.whereExpr with
      | error err =>
          simp [PureNode.evalOutputs, hBindings, hWhere] at hEval
      | ok localEnv =>
          have hOutputEval :
              evalOutputEquations localEnv node.outputs = Except.ok lookup := by
            simpa [PureNode.evalOutputs, hBindings, hWhere] using hEval
          intro name hPort
          have hOutputKey : name ∈ node.outputKeys := by
            simpa [hNode.outputs_match] using hPort
          have hKeySet : name ∈ outputEquationKeySet node.outputs := by
            simpa [PureNode.outputKeys] using hOutputKey
          exact evalOutputEquations_keys_present hOutputEval hKeySet

/-- Source pure nodes lower to one native pure task. -/
theorem pureNode_lowers_to_one_nativeTask
    (ctx : StaticContext)
    (node : PureNode) :
    (lowerPureNode ctx node).kind = LoweredNodeKind.nativePure :=
  rfl

/-- Lowering preserves source pure-node output evaluation in the proof-side evaluator. -/
theorem pureNode_lowering_evalOutputs_eq
    (ctx : StaticContext)
    (env : Env)
    (node : PureNode) :
    (lowerPureNode ctx node).config.evalOutputs env =
      node.evalOutputs env :=
  rfl

/-- CorePure evaluation is deterministic because it is a pure function. -/
theorem pureEvaluation_deterministic
    {env : Env}
    {expr : Expr}
    {left right : Value}
    (hLeft : eval env expr = Except.ok left)
    (hRight : eval env expr = Except.ok right) :
    left = right := by
  rw [hLeft] at hRight
  cases hRight
  rfl

end CorePure

end Cortex.Wire
