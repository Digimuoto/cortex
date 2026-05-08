import Mathlib.Data.Finset.Basic
import Cortex.Wire.PortLinearity

/-!
## Overview

Proof-facing Wire elaboration IR.

## Context

This module is the first Lean-owned carrier for Wire source after parsing and
source inclusion have already happened. It does not model the text parser,
filesystem includes, runtime executors, or Pulse execution. Those remain
outside the kernel. The purpose here is narrower: name the static objects that
future certified elaboration will consume and separate raw source-shaped input
from accepted proof objects.

Isolated accepted node declarations project mechanically to the
source-linearity layer's open `nodePorts` object. Non-trivial source linearity,
raw graph admission, executor-registry correspondence, and identifier-shape
validation are intentionally later obligations.

ADR 0052 indexed family projection, such as `workers[i]`, is parser/expander
syntax over generated `make` children. By the time source reaches this IR, the
projection has already resolved to the selected child node reference, so
`GraphExpr` intentionally has no family-projection constructor.
-/

namespace Cortex.Wire
namespace ElaborationIR

/-! ## Nominal Identifiers -/

/-!
Nominal identifiers in this carrier preserve namespace separation only. Values
such as `NodeId`, `BindingName`, and `ExecutorRef` do not yet prove non-emptiness,
source identifier grammar, generated-name freshness, or registry membership by
construction. Local accepted carriers below add non-empty name obligations;
full source grammar validation and registry correspondence remain later checks.
-/

/-- Minimal local validity for a nominal source token represented as a `String`.

The executable grammar is stricter (`[A-Za-z_][A-Za-z0-9_]*`). This carrier uses
the smallest proof-side invariant needed to rule out the empty-token countermodel
without pretending to mechanize the parser. Downstream consumers that rely on
full source identifier shape must re-check or carry a stronger grammar witness. -/
def NominalNameValid (name : String) : Prop :=
  name ≠ ""

instance nominalNameValidDecidable (name : String) : Decidable (NominalNameValid name) :=
  inferInstanceAs (Decidable (name ≠ ""))

/-- Nominal contract identifier. -/
structure ContractId where
  /-- Human/source-facing contract name. -/
  name : String
  deriving DecidableEq, Repr

namespace ContractId

/-- Contract identifiers admitted into local accepted frontiers are non-empty. -/
def Valid (contract : ContractId) : Prop :=
  NominalNameValid contract.name

instance validDecidable (contract : ContractId) : Decidable contract.Valid :=
  inferInstanceAs (Decidable (NominalNameValid contract.name))

/-- Canonical proof-side spelling for a bounded indexed product contract `[T; N]`.

The Haskell parser stores bounded products in the same compact string shape. The
Lean carrier keeps them as ordinary contract identifiers, but this constructor
gives closure predicates a structured way to recognize that `[T; N]` is closed
whenever `T` is declared directly. -/
def boundedIndexed (element : ContractId) (count : Nat) : ContractId :=
  { name := "[" ++ element.name ++ ";" ++ toString count ++ "]" }

/-- Contract-shape closure against a declared contract namespace.

A contract is closed when it is declared directly, or when it is a bounded
indexed product whose element contract is declared directly. This mirrors
executable Wire's `[T; N]` validation rule: `[T; 0]` is the empty finite product,
but closure does not recursively synthesize nested products such as `[[T;3];4]`.

The source grammar only parses a nominal identifier as the element position of
`[T; N]`; this proof-side predicate follows that non-recursive shape. -/
inductive ClosedBy (declared : List ContractId) : ContractId → Prop where
  /-- Declared scalar or nominal record contract. -/
  | declared {contract : ContractId} :
      contract ∈ declared →
      ClosedBy declared contract
  /-- Bounded indexed product over a directly declared element contract. -/
  | boundedIndexed {element : ContractId} (count : Nat) :
      element ∈ declared →
      ClosedBy declared (ContractId.boundedIndexed element count)

end ContractId

/-- Nominal record-field label. -/
structure FieldLabel where
  /-- Human/source-facing field name. -/
  name : String
  deriving DecidableEq, Repr

namespace FieldLabel

/-- Field labels admitted into local accepted frontiers are non-empty. -/
def Valid (field : FieldLabel) : Prop :=
  NominalNameValid field.name

instance validDecidable (field : FieldLabel) : Decidable field.Valid :=
  inferInstanceAs (Decidable (NominalNameValid field.name))

end FieldLabel

/-- Nominal node identifier after source inclusion and macro expansion. -/
structure NodeId where
  /-- Source-stable node name. -/
  name : String
  deriving DecidableEq, Repr

namespace NodeId

/-- Accepted node identifiers are non-empty at this local layer. -/
def Valid (node : NodeId) : Prop :=
  NominalNameValid node.name

instance validDecidable (node : NodeId) : Decidable node.Valid :=
  inferInstanceAs (Decidable (NominalNameValid node.name))

end NodeId

/-- Nominal graph or value binding name. -/
structure BindingName where
  /-- Source-stable binding name. -/
  name : String
  deriving DecidableEq, Repr

namespace BindingName

/-- Binding identifiers are non-empty when a future admission layer chooses to enforce them. -/
def Valid (binding : BindingName) : Prop :=
  NominalNameValid binding.name

instance validDecidable (binding : BindingName) : Decidable binding.Valid :=
  inferInstanceAs (Decidable (NominalNameValid binding.name))

end BindingName

/-- Nominal select-arm key as written in source. -/
structure SelectArmKey where
  /-- Source-stable selector variant token. -/
  name : String
  deriving DecidableEq, Repr

namespace SelectArmKey

/-- Select-arm keys are non-empty when a future select admission layer chooses to enforce them. -/
def Valid (key : SelectArmKey) : Prop :=
  NominalNameValid key.name

instance validDecidable (key : SelectArmKey) : Decidable key.Valid :=
  inferInstanceAs (Decidable (NominalNameValid key.name))

end SelectArmKey

/-- Nominal kind name used by `make` and `makeEach` forms. -/
structure KindName where
  /-- Source-stable kind name. -/
  name : String
  deriving DecidableEq, Repr

namespace KindName

/-- Accepted kind identifiers are non-empty at this local layer. -/
def Valid (kind : KindName) : Prop :=
  NominalNameValid kind.name

instance validDecidable (kind : KindName) : Decidable kind.Valid :=
  inferInstanceAs (Decidable (NominalNameValid kind.name))

end KindName

/-- Nominal executor reference. Executor bodies and registry membership remain opaque here. -/
structure ExecutorRef where
  /-- Source-facing executor name. -/
  name : String
  deriving DecidableEq, Repr

namespace ExecutorRef

/-- Executor references admitted into node bodies are non-empty at this local layer. -/
def Valid (executor : ExecutorRef) : Prop :=
  NominalNameValid executor.name

instance validDecidable (executor : ExecutorRef) : Decidable executor.Valid :=
  inferInstanceAs (Decidable (NominalNameValid executor.name))

end ExecutorRef

/-! ## Node Provenance

The kernel keeps the final graph-vertex namespace flat: every admitted vertex
is identified by a single `NodeId` that authored and generated nodes share.
`NodeOrigin` records *how* a vertex entered the graph alongside its `NodeId`,
so a future admission layer can reject rendered name collisions structurally
without ever splitting the identity type. The current carrier is provenance
vocabulary only: source-linearity witnesses in this slice do not consume
`NodeOrigin`.

The constructors carry exactly the source-derivation data needed to reproduce
the rendered name deterministically:

- `authored` for nodes named by source.
- `makeIndex (binding, index)` for `make(N, K)`'s i-th child.
- `makeEachItem (binding, label)` for `makeEach(items, K)`'s per-item child.
- `starPhantom (binding, siteIndex)` for the phantom adapter inserted at the
  `siteIndex`-th `*` site under `binding`. The site index disambiguates
  multiple `*` operators inside one bound graph expression.
- `selectCondition (binding, siteIndex, key)` for the synthetic anchor of a
  `select(...)` arm. The site index disambiguates multiple `select(...)`
  clauses under one binding; `key` distinguishes arms within a site.

The default name renderer below pins a deterministic human-readable convention.
It is not a freshness proof: certified generated-form admission must still carry
a `GeneratedNamePolicy` or equivalent renderer/freshness witness that discharges
collision-freedom for the concrete generated nodes it admits. -/

/-- Provenance of a graph vertex within an admitted module. -/
inductive NodeOrigin where
  | authored
  | makeIndex (binding : BindingName) (index : Nat)
  | makeEachItem (binding : BindingName) (label : FieldLabel)
  | starPhantom (binding : BindingName) (siteIndex : Nat)
  | selectCondition (binding : BindingName) (siteIndex : Nat) (key : SelectArmKey)
  deriving DecidableEq, Repr

namespace NodeOrigin

/-- An origin is *generated* when its rendered name comes from elaboration data
rather than source text. Authored origins reuse the source-supplied node name. -/
def IsGenerated : NodeOrigin → Prop
  | .authored => False
  | .makeIndex _ _ => True
  | .makeEachItem _ _ => True
  | .starPhantom _ _ => True
  | .selectCondition _ _ _ => True

instance isGeneratedDecidable (origin : NodeOrigin) : Decidable origin.IsGenerated :=
  match origin with
  | .authored => isFalse (fun h => h)
  | .makeIndex _ _ => isTrue trivial
  | .makeEachItem _ _ => isTrue trivial
  | .starPhantom _ _ => isTrue trivial
  | .selectCondition _ _ _ => isTrue trivial

/-- Default deterministic name renderer for generated origins.

`authored` returns `none` because the source supplies the name. The four
generated constructors render to `<prefix>_<discriminator>` with prefixes
(`__make_`, `__makeEach_`, `__star_`, `__select_`) chosen so:

- generated names cannot collide *between* generated families;
- collision with an authored name requires the author to write a `__make_…`,
  `__makeEach_…`, `__star_…`, or `__select_…` identifier — which the source
  grammar permits (the lexical prefix is not reserved at the parser layer)
  and admission must therefore detect structurally rather than syntactically.

Future `GeneratedNamePolicy` instances can supply alternative renderers; this
default is for provenance display and debugging. Kernel-level generated-name
freshness is supplied by `GeneratedNamePolicy` and the accepted module's
uniqueness witnesses, not by an injectivity theorem for this raw `String`
renderer. -/
def defaultRender : NodeOrigin → Option NodeId
  | .authored => none
  | .makeIndex binding index =>
      some ⟨"__make_" ++ binding.name ++ "_" ++ toString index⟩
  | .makeEachItem binding label =>
      some ⟨"__makeEach_" ++ binding.name ++ "_" ++ label.name⟩
  | .starPhantom binding siteIndex =>
      some ⟨"__star_" ++ binding.name ++ "_" ++ toString siteIndex⟩
  | .selectCondition binding siteIndex key =>
      some ⟨"__select_" ++ binding.name ++ "_" ++ toString siteIndex ++ "_" ++ key.name⟩

/-- Authored origins do not render to a synthetic name. -/
theorem defaultRender_authored : defaultRender .authored = none := rfl

/-- Generated origins always render to some synthetic name. -/
theorem defaultRender_generated_isSome
    {origin : NodeOrigin}
    (h : origin.IsGenerated) :
    origin.defaultRender.isSome = true := by
  cases origin with
  | authored => exact absurd h (fun h' => h')
  | makeIndex _ _ => rfl
  | makeEachItem _ _ => rfl
  | starPhantom _ _ => rfl
  | selectCondition _ _ _ => rfl

end NodeOrigin

/-! ## Ports, Contracts, And Static Values -/

/-- One typed port in a Wire node frontier. -/
structure PortSignature where
  /-- Port label as it appears in source. -/
  label : FieldLabel
  /-- Contract expected at this port. -/
  contract : ContractId
  deriving DecidableEq, Repr

namespace PortSignature

/-- Locally accepted port signatures have non-empty labels and contract names. -/
def Valid (port : PortSignature) : Prop :=
  port.label.Valid ∧ port.contract.Valid

instance validDecidable (port : PortSignature) : Decidable port.Valid :=
  inferInstanceAs (Decidable (port.label.Valid ∧ port.contract.Valid))

end PortSignature

/-- Output-direction port signature wrapper for the source-linearity lift.

Wire allows the same label and contract on opposite frontier directions. The
wrapper keeps output instances type-distinct from input instances when projecting
accepted declarations to `LinearPortGraph`. -/
structure OutputPortSignature where
  /-- Underlying accepted source port signature. -/
  signature : PortSignature
  deriving DecidableEq, Repr

/-- Input-direction port signature wrapper for the source-linearity lift.

This is intentionally separate from `OutputPortSignature`: direction is part of
Wire port identity even when labels and contracts match. -/
structure InputPortSignature where
  /-- Underlying accepted source port signature. -/
  signature : PortSignature
  deriving DecidableEq, Repr

/-- Every port in a finite frontier is locally valid. -/
def PortSignaturesValid (ports : Finset PortSignature) : Prop :=
  ∀ port, port ∈ ports → port.Valid

/-- Every port in a source-order frontier list is locally valid. -/
def PortSignatureListValid (ports : List PortSignature) : Prop :=
  ∀ port, port ∈ ports → port.Valid

/-- Source-order frontier lists have no repeated labels before `Finset` canonicalization. -/
def PortLabelListUnique (ports : List PortSignature) : Prop :=
  (ports.map PortSignature.label).Nodup

/-- Accepted frontier ports must be unique by source label, not only by full signature. -/
def PortLabelsUnique (ports : Finset PortSignature) : Prop :=
  ∀ ⦃left right : PortSignature⦄,
    left ∈ ports → right ∈ ports → left.label = right.label → left = right

/-- A valid source-order frontier list remains valid after `Finset` canonicalization. -/
theorem portSignatureListValid_toFinset
    {ports : List PortSignature}
    (hValid : PortSignatureListValid ports) :
    PortSignaturesValid ports.toFinset := by
  intro port hPort
  exact hValid port (List.mem_toFinset.mp hPort)

/-- Source-order label uniqueness means same-label members are the same port. -/
theorem portLabelListUnique_mem_eq
    {ports : List PortSignature}
    (hUnique : PortLabelListUnique ports)
    {left right : PortSignature}
    (hLeft : left ∈ ports)
    (hRight : right ∈ ports)
    (hLabel : left.label = right.label) :
    left = right := by
  induction ports generalizing left right with
  | nil =>
      cases hLeft
  | cons head tail ih =>
      simp only [PortLabelListUnique, List.map_cons, List.nodup_cons] at hUnique
      rcases hUnique with ⟨hHeadFresh, hTailUnique⟩
      simp only [List.mem_cons] at hLeft hRight
      rcases hLeft with hLeftHead | hLeftTail
      · rcases hRight with hRightHead | hRightTail
        · rw [hLeftHead, hRightHead]
        · rw [hLeftHead] at hLabel
          have hRightLabel : right.label ∈ tail.map PortSignature.label :=
            List.mem_map_of_mem (f := PortSignature.label) hRightTail
          rw [← hLabel] at hRightLabel
          exact False.elim (hHeadFresh hRightLabel)
      · rcases hRight with hRightHead | hRightTail
        · rw [hRightHead] at hLabel
          have hLeftLabel : left.label ∈ tail.map PortSignature.label :=
            List.mem_map_of_mem (f := PortSignature.label) hLeftTail
          rw [hLabel] at hLeftLabel
          exact False.elim (hHeadFresh hLeftLabel)
        · exact ih hTailUnique hLeftTail hRightTail hLabel

/-- Source-order label uniqueness remains label uniqueness after `Finset` canonicalization. -/
theorem portLabelListUnique_toFinset
    {ports : List PortSignature}
    (hUnique : PortLabelListUnique ports) :
    PortLabelsUnique ports.toFinset := by
  intro left right hLeft hRight hLabel
  exact
    portLabelListUnique_mem_eq hUnique
      (List.mem_toFinset.mp hLeft)
      (List.mem_toFinset.mp hRight)
      hLabel

/-- A singleton frontier is label-unique. -/
theorem singleton_portLabelsUnique (port : PortSignature) :
    PortLabelsUnique ({port} : Finset PortSignature) := by
  intro left right hLeft hRight _hLabel
  have hLeftEq : left = port := Finset.mem_singleton.mp hLeft
  have hRightEq : right = port := Finset.mem_singleton.mp hRight
  rw [hLeftEq, hRightEq]

/-- A singleton frontier is valid when its only port is valid. -/
theorem singleton_portSignaturesValid
    {port : PortSignature}
    (hPort : port.Valid) :
    PortSignaturesValid ({port} : Finset PortSignature) := by
  intro candidate hCandidate
  have hEq : candidate = port := Finset.mem_singleton.mp hCandidate
  rw [hEq]
  exact hPort

/-- One field in a nominal record contract. -/
structure RecordFieldDecl where
  /-- Record field label. -/
  field : FieldLabel
  /-- Contract carried by that field. -/
  contract : ContractId
  deriving DecidableEq, Repr

namespace RecordFieldDecl

/-- Locally accepted record fields have non-empty labels and contract names. -/
def Valid (field : RecordFieldDecl) : Prop :=
  field.field.Valid ∧ field.contract.Valid

end RecordFieldDecl

/-- Every field in a source-order record declaration is locally valid. -/
def RecordFieldListValid (fields : List RecordFieldDecl) : Prop :=
  ∀ field, field ∈ fields → field.Valid

/-- Record declarations have no repeated field labels before admission. -/
def RecordFieldLabelsUnique (fields : List RecordFieldDecl) : Prop :=
  (fields.map RecordFieldDecl.field).Nodup

/-- Nominal record contract shape after imports and source includes are resolved. -/
structure RecordContractDecl where
  /-- Contract identifier for the record. -/
  contract : ContractId
  /-- Declared fields. Raw declarations keep list shape so duplicate labels can be diagnosed. -/
  fields : List RecordFieldDecl
  deriving DecidableEq, Repr

namespace RecordContractDecl

/-- Local admission witness for a nominal record contract declaration. -/
structure LocallyAdmissible (decl : RecordContractDecl) : Prop where
  /-- The contract identifier is non-empty at the local carrier layer. -/
  contractValid : decl.contract.Valid
  /-- Every record field has locally valid label and contract names. -/
  fieldsValid : RecordFieldListValid decl.fields
  /-- Source-order record fields are unique by label. -/
  fieldLabelsUnique : RecordFieldLabelsUnique decl.fields

end RecordContractDecl

/-- Accepted nominal record contract declaration after local field-shape admission. -/
structure AcceptedRecordContractDecl where
  /-- Accepted contract identifier. -/
  contract : ContractId
  /-- Accepted contract identifiers are non-empty at this local layer. -/
  contractValid : contract.Valid
  /-- Accepted record fields in source order. -/
  fields : List RecordFieldDecl
  /-- Accepted record fields have locally valid labels and contract names. -/
  fieldsValid : RecordFieldListValid fields
  /-- Accepted record fields are unique by source label. -/
  fieldLabelsUnique : RecordFieldLabelsUnique fields
  deriving DecidableEq

namespace RecordContractDecl

/-- Locally admitted raw record contracts become accepted record contract declarations. -/
def toAccepted
    (decl : RecordContractDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedRecordContractDecl :=
  { contract := decl.contract
    contractValid := hAdmissible.contractValid
    fields := decl.fields
    fieldsValid := hAdmissible.fieldsValid
    fieldLabelsUnique := hAdmissible.fieldLabelsUnique }

end RecordContractDecl

namespace RecordContractDecl

/-- Raw record-field contracts are declared by the surrounding raw module shell. -/
def FieldContractsClosed
    (decl : RecordContractDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  ∀ field,
    field ∈ decl.fields →
      ContractId.ClosedBy (contracts.map RecordContractDecl.contract) field.contract

end RecordContractDecl

/-- Accepted record-field contracts are declared by the surrounding accepted module shell. -/
def AcceptedRecordFieldContractsClosed
    (decl : AcceptedRecordContractDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  ∀ field,
    field ∈ decl.fields →
      ContractId.ClosedBy (contracts.map AcceptedRecordContractDecl.contract) field.contract

/-- Static value fragment visible to Lean elaboration after source inclusion.

This is deliberately a shape language. It is not an evaluator for Wire, and it
does not read files. By the time a value reaches this carrier, any
`include_str`/`include_dir`-style source inclusion has already been resolved by
the external front end.

A structural `DecidableEq` instance is provided below via `StaticValue.decEq`.
Auto-derive does not handle this recursive shape because `List StaticValue`
and `List (FieldLabel × StaticValue)` reach back into the value itself; the
manual instance walks each constructor pair explicitly. -/
inductive StaticValue where
  | string (value : String)
  | bool (value : Bool)
  | nat (value : Nat)
  | list (values : List StaticValue)
  /-- Record-shaped static value. Field-label uniqueness is intentionally not
  enforced at this raw value layer; future value admission must add it before
  projecting fields by name. -/
  | record (fields : List (FieldLabel × StaticValue))
  deriving Repr

namespace StaticValue

/-! Structural decidable equality for `StaticValue`.

`deriving DecidableEq` does not handle this recursive shape because `List
StaticValue` and `List (FieldLabel × StaticValue)` reach back into the value
itself. The mutual block walks each constructor pair explicitly and recurses
through helpers for the two list payloads. The cross-constructor branches use
the structural `nomatch` discharge — no `Classical` choice and no proof debt. -/

mutual

protected def decEq : (a b : StaticValue) → Decidable (a = b)
  | .string s, .string t =>
      if h : s = t then .isTrue (h ▸ rfl)
      else .isFalse (fun heq => h (StaticValue.string.inj heq))
  | .bool x, .bool y =>
      if h : x = y then .isTrue (h ▸ rfl)
      else .isFalse (fun heq => h (StaticValue.bool.inj heq))
  | .nat n, .nat m =>
      if h : n = m then .isTrue (h ▸ rfl)
      else .isFalse (fun heq => h (StaticValue.nat.inj heq))
  | .list xs, .list ys =>
      match StaticValue.decEqList xs ys with
      | .isTrue h => .isTrue (h ▸ rfl)
      | .isFalse h => .isFalse (fun heq => h (StaticValue.list.inj heq))
  | .record xs, .record ys =>
      match StaticValue.decEqFields xs ys with
      | .isTrue h => .isTrue (h ▸ rfl)
      | .isFalse h => .isFalse (fun heq => h (StaticValue.record.inj heq))
  | .string _, .bool _ => .isFalse (fun heq => nomatch heq)
  | .string _, .nat _ => .isFalse (fun heq => nomatch heq)
  | .string _, .list _ => .isFalse (fun heq => nomatch heq)
  | .string _, .record _ => .isFalse (fun heq => nomatch heq)
  | .bool _, .string _ => .isFalse (fun heq => nomatch heq)
  | .bool _, .nat _ => .isFalse (fun heq => nomatch heq)
  | .bool _, .list _ => .isFalse (fun heq => nomatch heq)
  | .bool _, .record _ => .isFalse (fun heq => nomatch heq)
  | .nat _, .string _ => .isFalse (fun heq => nomatch heq)
  | .nat _, .bool _ => .isFalse (fun heq => nomatch heq)
  | .nat _, .list _ => .isFalse (fun heq => nomatch heq)
  | .nat _, .record _ => .isFalse (fun heq => nomatch heq)
  | .list _, .string _ => .isFalse (fun heq => nomatch heq)
  | .list _, .bool _ => .isFalse (fun heq => nomatch heq)
  | .list _, .nat _ => .isFalse (fun heq => nomatch heq)
  | .list _, .record _ => .isFalse (fun heq => nomatch heq)
  | .record _, .string _ => .isFalse (fun heq => nomatch heq)
  | .record _, .bool _ => .isFalse (fun heq => nomatch heq)
  | .record _, .nat _ => .isFalse (fun heq => nomatch heq)
  | .record _, .list _ => .isFalse (fun heq => nomatch heq)

protected def decEqList :
    (xs ys : List StaticValue) → Decidable (xs = ys)
  | [], [] => .isTrue rfl
  | [], _ :: _ => .isFalse (fun heq => nomatch heq)
  | _ :: _, [] => .isFalse (fun heq => nomatch heq)
  | x :: xs, y :: ys =>
      match StaticValue.decEq x y with
      | .isFalse h =>
          .isFalse (fun heq => h (List.cons.inj heq).left)
      | .isTrue hHead =>
          match StaticValue.decEqList xs ys with
          | .isFalse h =>
              .isFalse (fun heq => h (List.cons.inj heq).right)
          | .isTrue hTail => .isTrue (hHead ▸ hTail ▸ rfl)

protected def decEqFields :
    (xs ys : List (FieldLabel × StaticValue)) → Decidable (xs = ys)
  | [], [] => .isTrue rfl
  | [], _ :: _ => .isFalse (fun heq => nomatch heq)
  | _ :: _, [] => .isFalse (fun heq => nomatch heq)
  | (xLabel, xVal) :: xs, (yLabel, yVal) :: ys =>
      if hLabel : xLabel = yLabel then
        match StaticValue.decEq xVal yVal with
        | .isFalse h =>
            .isFalse (fun heq =>
              h (Prod.mk.inj (List.cons.inj heq).left).right)
        | .isTrue hVal =>
            match StaticValue.decEqFields xs ys with
            | .isFalse h =>
                .isFalse (fun heq => h (List.cons.inj heq).right)
            | .isTrue hTail =>
                .isTrue (by rw [hLabel, hVal, hTail])
      else
        .isFalse (fun heq =>
          hLabel (Prod.mk.inj (List.cons.inj heq).left).left)

end

instance : DecidableEq StaticValue := StaticValue.decEq

end StaticValue

/-! ## Node And Kind Declarations -/

/-- Boundary class for a node body.

Only the authority/effect boundary is represented. CorePure expressions,
executor payloads, runtime code, and executor-registry witnesses remain opaque
to this IR. -/
inductive NodeBodyBoundary where
  | corePure
  | executor (ref : ExecutorRef)
  | generatedPhantom
  deriving DecidableEq, Repr

namespace NodeBodyBoundary

/-- Local body-boundary validity checks only nominal executor spelling.

Registry membership and executor schema validation are represented separately so
this carrier can stay independent of the full registry model. -/
def LocalValid : NodeBodyBoundary → Prop
  | corePure => True
  | executor ref => ref.Valid
  | generatedPhantom => True

instance localValidDecidable (body : NodeBodyBoundary) : Decidable body.LocalValid :=
  match body with
  | corePure => isTrue trivial
  | executor ref => inferInstanceAs (Decidable ref.Valid)
  | generatedPhantom => isTrue trivial

end NodeBodyBoundary

/-! ### Kind Parameters -/

/-- Parameter class accepted by reusable Wire kind templates. -/
inductive KindParamClass where
  | portLabel
  | contract
  | value
  | configuredExecutor
  deriving DecidableEq, Repr

/-- One formal parameter on a reusable kind template.

The class mirrors the Wire grammar's `PortLabel`, `Contract`, `Value`, and
`ConfiguredExecutor` parameter categories. -/
structure KindParamDecl where
  /-- Parameter binding name inside the kind template. -/
  name : BindingName
  /-- Static class of value accepted at this parameter. -/
  paramClass : KindParamClass
  deriving DecidableEq, Repr

namespace KindParamDecl

/-- Locally accepted kind parameters have non-empty binding names. -/
def Valid (param : KindParamDecl) : Prop :=
  param.name.Valid

instance validDecidable (param : KindParamDecl) : Decidable param.Valid :=
  inferInstanceAs (Decidable param.name.Valid)

/-- A `PortLabel` formal parameter as the frontier field label it denotes. -/
def asFieldLabel (param : KindParamDecl) : FieldLabel :=
  ⟨param.name.name⟩

/-- Translating a kind `PortLabel` parameter into a field label preserves the
local non-empty-name invariant. -/
theorem asFieldLabel_valid
    (param : KindParamDecl)
    (hValid : param.Valid) :
    param.asFieldLabel.Valid :=
  hValid

end KindParamDecl

/-- Every kind parameter in a source-order list is locally valid. -/
def KindParamListValid (params : List KindParamDecl) : Prop :=
  ∀ param, param ∈ params → param.Valid

/-- Kind parameter names are unique before admission. -/
def KindParamNamesUnique (params : List KindParamDecl) : Prop :=
  (params.map KindParamDecl.name).Nodup

/-! ### Output Shapes

The Wire output frontier admits two authored shapes: an ordinary single output
port and an exclusive output sum group, written `select { armA: A; armB: B }`
in source. Both lower to the same flattened port frontier consumed by
`LinearPortGraph`, but downstream admission for `select(...)` graph expressions
needs to discriminate them. The `OutputShape` carrier preserves the authored
distinction at this IR layer; the flattened projection `outputPorts` recovers
the existing `Finset PortSignature` view used by the source-linearity lift. -/

/-- One arm of an exclusive output sum group declared on a node or kind. -/
structure OutputArmDecl where
  /-- Source-stable selector arm key. -/
  armKey : SelectArmKey
  /-- Port produced when this arm fires. -/
  port : PortSignature
  deriving DecidableEq, Repr

namespace OutputArmDecl

/-- Locally accepted output arms have non-empty arm keys and a valid port. -/
def Valid (arm : OutputArmDecl) : Prop :=
  arm.armKey.Valid ∧ arm.port.Valid

instance validDecidable (arm : OutputArmDecl) : Decidable arm.Valid :=
  inferInstanceAs (Decidable (arm.armKey.Valid ∧ arm.port.Valid))

end OutputArmDecl

/-- Authored output frontier shape on a node or kind output declaration.

`single` is the common one-port output. `sumGroup` is the exclusive output sum
group authored as `-> select { armA: A; armB: B };`. The arm list is kept in
source order so admission can surface duplicates without losing them through
canonicalization. Source admission requires at least two arms, matching the
executable `PortOutputSumDecl` invariant that a one-arm variant is represented
as `single`, not as an exclusive sum. The carrier itself does not enforce this
so raw declarations can still report malformed-group countermodels. -/
inductive OutputShape where
  | single (port : PortSignature)
  | sumGroup (arms : List OutputArmDecl)
  deriving DecidableEq, Repr

namespace OutputShape

/-- Flatten one authored output shape to its declared ports in source order. -/
def ports : OutputShape → List PortSignature
  | single port => [port]
  | sumGroup arms => arms.map OutputArmDecl.port

/-- Locally admissible authored output shape.

`single` only requires its port to be valid. `sumGroup` requires at least two
arms, valid arm keys and ports, unique arm keys, and unique port labels inside
the group. Repeated contracts across arms are allowed because the sum group is
exclusive over labels. -/
inductive LocallyAdmissible : OutputShape → Prop where
  | single {port : PortSignature} :
      port.Valid →
      LocallyAdmissible (OutputShape.single port)
  | sumGroup {arms : List OutputArmDecl} :
      2 ≤ arms.length →
      (∀ arm, arm ∈ arms → arm.Valid) →
      (arms.map OutputArmDecl.armKey).Nodup →
      (arms.map (fun arm => arm.port.label)).Nodup →
      LocallyAdmissible (OutputShape.sumGroup arms)

/-- Every flattened port of a locally admissible shape has valid label and contract. -/
theorem ports_valid_of_locallyAdmissible
    {shape : OutputShape}
    (hAdmissible : shape.LocallyAdmissible) :
    PortSignatureListValid shape.ports := by
  intro port hPort
  match shape, hAdmissible with
  | OutputShape.single declared, LocallyAdmissible.single hPort' =>
      simp only [ports, List.mem_singleton] at hPort
      subst hPort
      exact hPort'
  | OutputShape.sumGroup arms,
    LocallyAdmissible.sumGroup _hAtLeastTwo hValid _hKeyNodup _hLabelNodup =>
      simp only [ports, List.mem_map] at hPort
      rcases hPort with ⟨arm, hArmMem, hEq⟩
      subst hEq
      exact (hValid arm hArmMem).right

/-- Source-order flattened ports of a locally admissible shape are unique by label. -/
theorem ports_labels_nodup_of_locallyAdmissible
    {shape : OutputShape}
    (hAdmissible : shape.LocallyAdmissible) :
    PortLabelListUnique shape.ports := by
  match shape, hAdmissible with
  | OutputShape.single _declared, LocallyAdmissible.single _hPort =>
      simp [PortLabelListUnique, ports]
  | OutputShape.sumGroup arms,
    LocallyAdmissible.sumGroup _hAtLeastTwo _hValid _hKeyNodup hLabelNodup =>
      have hMap :
          (OutputShape.sumGroup arms).ports.map PortSignature.label =
            arms.map (fun arm => arm.port.label) := by
        simp [ports, List.map_map, Function.comp]
      unfold PortLabelListUnique
      rw [hMap]
      exact hLabelNodup

/-- A one-arm output sum group is not locally admissible.

Executable Wire parses a single output variant as `OutputShape.single`; the
exclusive-sum carrier starts at two arms. -/
theorem oneArmSumGroup_not_locallyAdmissible
    (arm : OutputArmDecl) :
    ¬ LocallyAdmissible (OutputShape.sumGroup [arm]) := by
  intro hAdmissible
  cases hAdmissible with
  | sumGroup hAtLeastTwo _hValid _hKeyNodup _hLabelNodup =>
      simp at hAtLeastTwo

/-- Two-arm output sum groups remain admissible when their local witnesses hold. -/
theorem twoArmSumGroup_locallyAdmissible
    {left right : OutputArmDecl}
    (hLeft : left.Valid)
    (hRight : right.Valid)
    (hKeys : left.armKey ≠ right.armKey)
    (hLabels : left.port.label ≠ right.port.label) :
    LocallyAdmissible (OutputShape.sumGroup [left, right]) := by
  exact
    LocallyAdmissible.sumGroup
      (by simp)
      (by
        intro arm hArm
        simp only [List.mem_cons, List.not_mem_nil, or_false] at hArm
        rcases hArm with hArm | hArm
        · rw [hArm]
          exact hLeft
        · rw [hArm]
          exact hRight)
      (by simp [hKeys])
      (by simp [hLabels])

end OutputShape

/-- Source-order flattened ports of a list of authored output shapes. -/
def OutputShapeListPorts (shapes : List OutputShape) : List PortSignature :=
  shapes.flatMap OutputShape.ports

/-- Every authored output shape in a list is locally admissible. -/
def OutputShapeListAdmissible (shapes : List OutputShape) : Prop :=
  ∀ shape, shape ∈ shapes → shape.LocallyAdmissible

/-- A list of locally admissible output shapes flattens to valid port signatures. -/
theorem outputShapeListPorts_valid
    {shapes : List OutputShape}
    (hAdmissible : OutputShapeListAdmissible shapes) :
    PortSignatureListValid (OutputShapeListPorts shapes) := by
  intro port hPort
  rcases List.mem_flatMap.mp hPort with ⟨shape, hShape, hPortShape⟩
  exact OutputShape.ports_valid_of_locallyAdmissible (hAdmissible shape hShape) port hPortShape

/-- Raw node declaration after parsing/source inclusion but before admission.

Lists preserve source multiplicity so future admission can report duplicate
ports instead of losing them through `Finset` normalization. The `outputs`
field carries authored output shapes so an exclusive output sum group remains
distinguishable from independent single outputs after parsing. -/
structure RawNodeDecl where
  /-- Declared node name. -/
  node : NodeId
  /-- Input frontier in source order. -/
  inputs : List PortSignature
  /-- Output frontier in source order, preserving authored sum-group shape. -/
  outputs : List OutputShape
  /-- Opaque body/effect boundary. -/
  body : NodeBodyBoundary
  deriving DecidableEq, Repr

namespace RawNodeDecl

/-- Source-order flattened output ports of a raw node declaration. -/
def outputPortsList (decl : RawNodeDecl) : List PortSignature :=
  OutputShapeListPorts decl.outputs

/-- Local admission witness for a raw node declaration.

This is still not graph admission: it covers only local name validity, port
validity, port-label uniqueness, output-shape admission, and executor-reference
spelling. -/
structure LocallyAdmissible (decl : RawNodeDecl) : Prop where
  /-- The node identifier is non-empty at the local carrier layer. -/
  nodeValid : decl.node.Valid
  /-- Every input port has locally valid label and contract names. -/
  inputPortsValid : PortSignatureListValid decl.inputs
  /-- Every authored output shape is locally admissible. -/
  outputShapesAdmissible : OutputShapeListAdmissible decl.outputs
  /-- Every flattened output port has locally valid label and contract names. -/
  outputPortsValid : PortSignatureListValid decl.outputPortsList
  /-- Source-order inputs are unique by label. -/
  inputLabelsUnique : PortLabelListUnique decl.inputs
  /-- Source-order flattened outputs are unique by label across the whole frontier. -/
  outputLabelsUnique : PortLabelListUnique decl.outputPortsList
  /-- The body boundary is locally valid. -/
  bodyLocalValid : decl.body.LocalValid

end RawNodeDecl

/-- Accepted node declaration after local port-shape admission.

Accepted nodes carry the authored output-shape list so an exclusive output sum
group remains discriminable from independent single outputs. The flattened
output frontier `outputPorts` projects to the same `Finset PortSignature` view
consumed by the source-linearity lift, with explicit label-uniqueness proofs so
equal labels with different contracts cannot enter the accepted layer. -/
structure AcceptedNodeDecl where
  /-- Accepted node name. -/
  node : NodeId
  /-- Accepted node names are non-empty at this local layer. -/
  nodeValid : node.Valid
  /-- Accepted input frontier. -/
  inputs : Finset PortSignature
  /-- Accepted authored output shapes in source order. -/
  outputs : List OutputShape
  /-- Accepted inputs have locally valid labels and contracts. -/
  inputPortsValid : PortSignaturesValid inputs
  /-- Accepted authored output shapes are locally admissible. -/
  outputShapesAdmissible : OutputShapeListAdmissible outputs
  /-- Source-order flattened outputs are unique by label across the whole frontier. -/
  outputPortsListLabelsUnique : PortLabelListUnique (OutputShapeListPorts outputs)
  /-- Accepted inputs are unique by source label. -/
  inputLabelsUnique : PortLabelsUnique inputs
  /-- Opaque body/effect boundary. -/
  body : NodeBodyBoundary
  /-- Accepted body boundaries have locally valid executor references. -/
  bodyLocalValid : body.LocalValid
  deriving DecidableEq

namespace AcceptedNodeDecl

/-- Singleton node domain for an accepted source node. -/
def nodeSet (decl : AcceptedNodeDecl) : Finset NodeId :=
  {decl.node}

/-- Source-order flattened output ports of an accepted node declaration. -/
def outputPortsList (decl : AcceptedNodeDecl) : List PortSignature :=
  OutputShapeListPorts decl.outputs

/-- Flattened accepted output frontier as a finite set of port signatures. -/
def outputPorts (decl : AcceptedNodeDecl) : Finset PortSignature :=
  decl.outputPortsList.toFinset

/-- Flattening an authored output-shape list to a finset agrees with the named projection. -/
theorem outputPorts_eq_toFinset (decl : AcceptedNodeDecl) :
    decl.outputPorts = (OutputShapeListPorts decl.outputs).toFinset := rfl

/-- Accepted flattened outputs have locally valid labels and contracts. -/
theorem outputPorts_valid (decl : AcceptedNodeDecl) :
    PortSignaturesValid decl.outputPorts :=
  portSignatureListValid_toFinset
    (outputShapeListPorts_valid decl.outputShapesAdmissible)

/-- Accepted flattened outputs are unique by source label. -/
theorem outputPorts_labelsUnique (decl : AcceptedNodeDecl) :
    PortLabelsUnique decl.outputPorts :=
  portLabelListUnique_toFinset decl.outputPortsListLabelsUnique

/-- Gluing theorem: the authored output-shape list flattens definitionally to the projected
port list. Slice 4 select admission consumes this equation when discriminating between
`single` and `sumGroup` shapes inside the same flattened frontier. -/
theorem outputPortsList_eq_flatMap (decl : AcceptedNodeDecl) :
    decl.outputPortsList = decl.outputs.flatMap OutputShape.ports := rfl

/-- Gluing theorem: the flattened output frontier of an accepted node equals the finset
canonicalization of the authored output-shape list. -/
theorem outputPorts_eq_flatMap_toFinset (decl : AcceptedNodeDecl) :
    decl.outputPorts = (decl.outputs.flatMap OutputShape.ports).toFinset := rfl

/-- Output source-port instances exposed by an accepted node. -/
def outputInstances
    (decl : AcceptedNodeDecl) :
    Finset (SourcePortInstance NodeId OutputPortSignature) :=
  decl.outputPorts.image (fun port => { node := decl.node, port := { signature := port } })

/-- Input source-port instances exposed by an accepted node. -/
def inputInstances
    (decl : AcceptedNodeDecl) :
    Finset (SourcePortInstance NodeId InputPortSignature) :=
  decl.inputs.image (fun port => { node := decl.node, port := { signature := port } })

/-- Mechanical projection lemma required by `LinearPortObject.nodePorts`.

At singleton-node level this is just the `Finset.image` fact that every produced
source-port instance was tagged with `decl.node`. The non-trivial domain-membership
invariant lives at future multi-node module composition. -/
theorem outputInstance_node_mem
    (decl : AcceptedNodeDecl)
    (output : SourcePortInstance NodeId OutputPortSignature)
    (hOutput : output ∈ decl.outputInstances) :
    output.node ∈ decl.nodeSet := by
  rcases Finset.mem_image.mp hOutput with ⟨_port, _hPort, hEq⟩
  subst hEq
  change decl.node ∈ ({decl.node} : Finset NodeId)
  exact Finset.mem_singleton.mpr rfl

/-- Mechanical projection lemma required by `LinearPortObject.nodePorts`.

At singleton-node level this is just the `Finset.image` fact that every produced
source-port instance was tagged with `decl.node`. The non-trivial domain-membership
invariant lives at future multi-node module composition. -/
theorem inputInstance_node_mem
    (decl : AcceptedNodeDecl)
    (input : SourcePortInstance NodeId InputPortSignature)
    (hInput : input ∈ decl.inputInstances) :
    input.node ∈ decl.nodeSet := by
  rcases Finset.mem_image.mp hInput with ⟨_port, _hPort, hEq⟩
  subst hEq
  change decl.node ∈ ({decl.node} : Finset NodeId)
  exact Finset.mem_singleton.mpr rfl

/-- Isolated accepted nodes lift to open source-linear port objects.

This lift has no internal port edges: every frontier endpoint remains open.
Composition and contraction are the later places where source linearity becomes
load-bearing. -/
def toLinearPortObject
    (decl : AcceptedNodeDecl) :
    LinearPortGraph.LinearPortObject NodeId OutputPortSignature InputPortSignature :=
  LinearPortGraph.LinearPortObject.nodePorts
    decl.nodeSet
    decl.outputInstances
    decl.inputInstances
    decl.outputInstance_node_mem
    decl.inputInstance_node_mem

end AcceptedNodeDecl

namespace RawNodeDecl

/-- Locally admitted raw nodes become accepted node declarations. -/
def toAccepted
    (decl : RawNodeDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedNodeDecl :=
  { node := decl.node
    nodeValid := hAdmissible.nodeValid
    inputs := decl.inputs.toFinset
    outputs := decl.outputs
    inputPortsValid := portSignatureListValid_toFinset hAdmissible.inputPortsValid
    outputShapesAdmissible := hAdmissible.outputShapesAdmissible
    outputPortsListLabelsUnique := hAdmissible.outputLabelsUnique
    inputLabelsUnique := portLabelListUnique_toFinset hAdmissible.inputLabelsUnique
    body := decl.body
    bodyLocalValid := hAdmissible.bodyLocalValid }

/-- Raw-to-accepted projection preserves the authored output-shape list. -/
theorem toAccepted_outputs
    (decl : RawNodeDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.toAccepted hAdmissible).outputs = decl.outputs := rfl

/-- Locally admitted raw nodes have an open source-linear lift. -/
theorem toAccepted_toLinearPortObject_portLinear
    (decl : RawNodeDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    ((decl.toAccepted hAdmissible).toLinearPortObject).graph.PortLinear :=
  (decl.toAccepted hAdmissible).toLinearPortObject.linear

end RawNodeDecl

/-- Raw kind declaration. Its body remains a source-template object, not a live graph.

Like `RawNodeDecl.outputs`, the template `outputs` field carries authored output
shapes so an exclusive output sum group on a kind template stays distinguishable
from independent single outputs. -/
structure RawKindDecl where
  /-- Kind name. -/
  kind : KindName
  /-- Formal parameters accepted by this reusable kind template. -/
  params : List KindParamDecl
  /-- Template input frontier. -/
  inputs : List PortSignature
  /-- Template output frontier in source order, preserving authored sum-group shape. -/
  outputs : List OutputShape
  /-- Opaque body/effect boundary for nodes produced from this kind. -/
  body : NodeBodyBoundary
  deriving DecidableEq, Repr

namespace RawKindDecl

/-- Source-order flattened output ports of a raw kind template declaration. -/
def outputPortsList (decl : RawKindDecl) : List PortSignature :=
  OutputShapeListPorts decl.outputs

/-- Local admission witness for a raw kind declaration. -/
structure LocallyAdmissible (decl : RawKindDecl) : Prop where
  /-- The kind identifier is non-empty at the local carrier layer. -/
  kindValid : decl.kind.Valid
  /-- Every template parameter has a locally valid binding name. -/
  paramsValid : KindParamListValid decl.params
  /-- Source-order template parameters are unique by binding name. -/
  paramNamesUnique : KindParamNamesUnique decl.params
  /-- Every template input port has locally valid label and contract names. -/
  inputPortsValid : PortSignatureListValid decl.inputs
  /-- Every authored template output shape is locally admissible. -/
  outputShapesAdmissible : OutputShapeListAdmissible decl.outputs
  /-- Every flattened template output port has locally valid label and contract names. -/
  outputPortsValid : PortSignatureListValid decl.outputPortsList
  /-- Source-order template inputs are unique by label. -/
  inputLabelsUnique : PortLabelListUnique decl.inputs
  /-- Source-order flattened template outputs are unique by label. -/
  outputLabelsUnique : PortLabelListUnique decl.outputPortsList
  /-- The kind body boundary is locally valid. -/
  bodyLocalValid : decl.body.LocalValid

end RawKindDecl

/-- Accepted kind declaration after local template admission.

The template frontier mirrors accepted node frontiers: input membership is
canonicalized with finite sets, the authored output-shape list is preserved so
exclusive sum groups remain discriminable, and label uniqueness over the
flattened template output frontier remains an explicit accepted-layer
obligation. -/
structure AcceptedKindDecl where
  /-- Kind name. -/
  kind : KindName
  /-- Accepted kind names are non-empty at this local layer. -/
  kindValid : kind.Valid
  /-- Accepted formal parameters. -/
  params : List KindParamDecl
  /-- Accepted parameters have locally valid binding names. -/
  paramsValid : KindParamListValid params
  /-- Accepted parameters are unique by binding name. -/
  paramNamesUnique : KindParamNamesUnique params
  /-- Accepted template input frontier. -/
  inputs : Finset PortSignature
  /-- Accepted authored template output shapes in source order. -/
  outputs : List OutputShape
  /-- Accepted template inputs have locally valid labels and contracts. -/
  inputPortsValid : PortSignaturesValid inputs
  /-- Accepted authored template output shapes are locally admissible. -/
  outputShapesAdmissible : OutputShapeListAdmissible outputs
  /-- Source-order flattened template outputs are unique by label across the whole frontier. -/
  outputPortsListLabelsUnique : PortLabelListUnique (OutputShapeListPorts outputs)
  /-- Accepted template inputs are unique by source label. -/
  inputLabelsUnique : PortLabelsUnique inputs
  /-- Opaque body/effect boundary for nodes produced from this kind. -/
  body : NodeBodyBoundary
  /-- Accepted kind body boundaries have locally valid executor references. -/
  bodyLocalValid : body.LocalValid
  deriving DecidableEq

namespace AcceptedKindDecl

/-- Source-order flattened output ports of an accepted kind template. -/
def outputPortsList (decl : AcceptedKindDecl) : List PortSignature :=
  OutputShapeListPorts decl.outputs

/-- Flattened accepted template output frontier as a finite set of port signatures. -/
def outputPorts (decl : AcceptedKindDecl) : Finset PortSignature :=
  decl.outputPortsList.toFinset

/-- Flattening an authored kind output-shape list to a finset agrees with the named projection. -/
theorem outputPorts_eq_toFinset (decl : AcceptedKindDecl) :
    decl.outputPorts = (OutputShapeListPorts decl.outputs).toFinset := rfl

/-- Accepted flattened template outputs have locally valid labels and contracts. -/
theorem outputPorts_valid (decl : AcceptedKindDecl) :
    PortSignaturesValid decl.outputPorts :=
  portSignatureListValid_toFinset
    (outputShapeListPorts_valid decl.outputShapesAdmissible)

/-- Accepted flattened template outputs are unique by source label. -/
theorem outputPorts_labelsUnique (decl : AcceptedKindDecl) :
    PortLabelsUnique decl.outputPorts :=
  portLabelListUnique_toFinset decl.outputPortsListLabelsUnique

/-- Gluing theorem for kind templates: the authored output-shape list flattens definitionally
to the projected port list. Slice 2 graph-expression admission consumes this equation. -/
theorem outputPortsList_eq_flatMap (decl : AcceptedKindDecl) :
    decl.outputPortsList = decl.outputs.flatMap OutputShape.ports := rfl

/-- Gluing theorem for kind templates: the flattened output frontier equals the finset
canonicalization of the authored output-shape list. -/
theorem outputPorts_eq_flatMap_toFinset (decl : AcceptedKindDecl) :
    decl.outputPorts = (decl.outputs.flatMap OutputShape.ports).toFinset := rfl

end AcceptedKindDecl

namespace RawKindDecl

/-- Locally admitted raw kinds become accepted kind declarations. -/
def toAccepted
    (decl : RawKindDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedKindDecl :=
  { kind := decl.kind
    kindValid := hAdmissible.kindValid
    params := decl.params
    paramsValid := hAdmissible.paramsValid
    paramNamesUnique := hAdmissible.paramNamesUnique
    inputs := decl.inputs.toFinset
    outputs := decl.outputs
    inputPortsValid := portSignatureListValid_toFinset hAdmissible.inputPortsValid
    outputShapesAdmissible := hAdmissible.outputShapesAdmissible
    outputPortsListLabelsUnique := hAdmissible.outputLabelsUnique
    inputLabelsUnique := portLabelListUnique_toFinset hAdmissible.inputLabelsUnique
    body := decl.body
    bodyLocalValid := hAdmissible.bodyLocalValid }

/-- Raw-to-accepted projection preserves the authored kind template output-shape list. -/
theorem toAccepted_outputs
    (decl : RawKindDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.toAccepted hAdmissible).outputs = decl.outputs := rfl

end RawKindDecl

/-! ## Graph Expressions -/

/-- Shape-level graph expression after source inclusion.

This is still syntax: `connect`, `star`, `make`, and `makeEach` are not accepted
operations until future admission constructs the corresponding certificates.
`empty` is the algebra identity for synthesized graph shapes such as zero-count
expansion, not a user-authored Wire token. `StaticValue` now carries structural
`DecidableEq`, but `GraphExpr`'s own auto-derive still fails through
`List (SelectArmKey × GraphExpr)`; a manual mutual instance is a follow-up. -/
inductive GraphExpr where
  | empty
  | node (node : NodeId)
  | binding (binding : BindingName)
  | overlay (left right : GraphExpr)
  | connect (left right : GraphExpr)
  | star (left right : GraphExpr)
  | select (base : GraphExpr) (arms : List (SelectArmKey × GraphExpr))
  | make (binding : BindingName) (count : Nat) (kind : KindName)
  | makeEach (binding : BindingName) (kind : KindName) (items : List StaticValue)
  deriving Repr

namespace GraphExpr

/-- Graph-binding reference membership for a graph expression.

This deliberately tracks only `GraphExpr.binding` leaves. The `binding`
argument of `make`/`makeEach` is the owner used to generate child node names,
not a graph-reference edge. -/
inductive BindingRefIn : GraphExpr → BindingName → Prop where
  | binding {target : BindingName} :
      BindingRefIn (GraphExpr.binding target) target
  | overlay_left {left right : GraphExpr} {target : BindingName} :
      BindingRefIn left target →
      BindingRefIn (GraphExpr.overlay left right) target
  | overlay_right {left right : GraphExpr} {target : BindingName} :
      BindingRefIn right target →
      BindingRefIn (GraphExpr.overlay left right) target
  | connect_left {left right : GraphExpr} {target : BindingName} :
      BindingRefIn left target →
      BindingRefIn (GraphExpr.connect left right) target
  | connect_right {left right : GraphExpr} {target : BindingName} :
      BindingRefIn right target →
      BindingRefIn (GraphExpr.connect left right) target
  | star_left {left right : GraphExpr} {target : BindingName} :
      BindingRefIn left target →
      BindingRefIn (GraphExpr.star left right) target
  | star_right {left right : GraphExpr} {target : BindingName} :
      BindingRefIn right target →
      BindingRefIn (GraphExpr.star left right) target
  | select_base {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)}
      {target : BindingName} :
      BindingRefIn base target →
      BindingRefIn (GraphExpr.select base arms) target
  | select_arm {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)}
      {arm : SelectArmKey × GraphExpr} {target : BindingName} :
      arm ∈ arms →
      BindingRefIn arm.snd target →
      BindingRefIn (GraphExpr.select base arms) target

/-- Generated graph forms inside a binding must derive their generated names
from that binding.

The parser rejects unbound inline `make`/`makeEach`; this predicate captures the
proof-side owner check for the post-parse carrier. It rules out impossible
states such as a graph binding `workers` whose expression contains
`make(other, ..., K)`. -/
inductive GeneratedFormsOwnedBy (owner : BindingName) : GraphExpr → Prop where
  | empty :
      GeneratedFormsOwnedBy owner GraphExpr.empty
  | node {target : NodeId} :
      GeneratedFormsOwnedBy owner (GraphExpr.node target)
  | binding {target : BindingName} :
      GeneratedFormsOwnedBy owner (GraphExpr.binding target)
  | overlay {left right : GraphExpr} :
      GeneratedFormsOwnedBy owner left →
      GeneratedFormsOwnedBy owner right →
      GeneratedFormsOwnedBy owner (GraphExpr.overlay left right)
  | connect {left right : GraphExpr} :
      GeneratedFormsOwnedBy owner left →
      GeneratedFormsOwnedBy owner right →
      GeneratedFormsOwnedBy owner (GraphExpr.connect left right)
  | star {left right : GraphExpr} :
      GeneratedFormsOwnedBy owner left →
      GeneratedFormsOwnedBy owner right →
      GeneratedFormsOwnedBy owner (GraphExpr.star left right)
  | select {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)} :
      GeneratedFormsOwnedBy owner base →
      (∀ arm, arm ∈ arms → GeneratedFormsOwnedBy owner arm.snd) →
      GeneratedFormsOwnedBy owner (GraphExpr.select base arms)
  | make {count : Nat} {kind : KindName} :
      GeneratedFormsOwnedBy owner (GraphExpr.make owner count kind)
  | makeEach {kind : KindName} {items : List StaticValue} :
      GeneratedFormsOwnedBy owner (GraphExpr.makeEach owner kind items)

end GraphExpr

/-- Graph binding expression before certified topology admission.

The same carrier is used in raw and accepted module shells because this module
does not yet provide a graph-admission certificate. Future certified elaboration
may wrap this shape in a proof-bearing accepted graph binding. -/
structure GraphBinding where
  /-- Binding name. -/
  name : BindingName
  /-- Bound graph expression. -/
  expr : GraphExpr
  deriving Repr

namespace GraphBinding

/-- Local graph-binding validity checks the binding name and generated-form ownership. -/
def LocalValid (binding : GraphBinding) : Prop :=
  binding.name.Valid ∧
    binding.expr.GeneratedFormsOwnedBy binding.name

/-- Directed graph-binding reference edge inside a module's graph-binding list.

`BindingRefEdge graphs source target` means the binding named `source` mentions
`binding target` somewhere in its expression. -/
def BindingRefEdge
    (graphs : List GraphBinding)
    (source target : BindingName) :
    Prop :=
  ∃ graph,
    graph ∈ graphs ∧
      graph.name = source ∧
        graph.expr.BindingRefIn target

/-- Placeholder acyclicity predicate for graph-binding references.

`AdmittedModuleShell` intentionally does not require this yet: the current shell
checks local validity and reference closure, while recursive binding unfolding is
left to a later certified graph-admission slice. Future admission of binding
right-hand sides should require this predicate or a stronger executable
topological-order witness. -/
def BindingRefAcyclic (graphs : List GraphBinding) : Prop :=
  ∀ graph,
    graph ∈ graphs →
      Acc
        (fun child parent => BindingRefEdge graphs parent child)
        graph.name

end GraphBinding

/-! ## Local Closure Predicates -/

namespace RawNodeDecl

/-- Raw node port contracts are declared by the surrounding raw module shell. -/
def ContractsClosed
    (decl : RawNodeDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  (∀ port,
      port ∈ decl.inputs →
        ContractId.ClosedBy (contracts.map RecordContractDecl.contract) port.contract) ∧
    ∀ port,
      port ∈ decl.outputPortsList →
        ContractId.ClosedBy (contracts.map RecordContractDecl.contract) port.contract

end RawNodeDecl

namespace AcceptedNodeDecl

/-- Accepted node port contracts are declared by the surrounding accepted module shell. -/
def ContractsClosed
    (decl : AcceptedNodeDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  (∀ port,
      port ∈ decl.inputs →
        ContractId.ClosedBy (contracts.map AcceptedRecordContractDecl.contract) port.contract) ∧
    ∀ port,
      port ∈ decl.outputPorts →
        ContractId.ClosedBy (contracts.map AcceptedRecordContractDecl.contract) port.contract

end AcceptedNodeDecl

namespace RawKindDecl

/-- Raw kind template port contracts are declared by the surrounding raw module shell. -/
def ContractsClosed
    (decl : RawKindDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  (∀ port,
      port ∈ decl.inputs →
        ContractId.ClosedBy (contracts.map RecordContractDecl.contract) port.contract) ∧
    ∀ port,
      port ∈ decl.outputPortsList →
        ContractId.ClosedBy (contracts.map RecordContractDecl.contract) port.contract

end RawKindDecl

namespace AcceptedKindDecl

/-- Accepted kind template port contracts are declared by the surrounding accepted module shell. -/
def ContractsClosed
    (decl : AcceptedKindDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  (∀ port,
      port ∈ decl.inputs →
        ContractId.ClosedBy (contracts.map AcceptedRecordContractDecl.contract) port.contract) ∧
    ∀ port,
      port ∈ decl.outputPorts →
        ContractId.ClosedBy (contracts.map AcceptedRecordContractDecl.contract) port.contract

/-- The accepted kind's template frontier uses the given `PortLabel` parameter
at every input/output label position.

This is a helper for the public `KindSupportsMake` predicate: it says that
generated child labels substitute the kind's formal label instead of overwriting
authored literal frontier labels. -/
def FrontierUsesLabelParam (decl : AcceptedKindDecl) (param : KindParamDecl) : Prop :=
  (∀ port, port ∈ decl.inputs → port.label = param.asFieldLabel) ∧
    ∀ port,
      port ∈ decl.outputPortsList →
        port.label = param.asFieldLabel

/-- `FrontierUsesLabelParam` is decidable because accepted kind frontiers are finite. -/
instance frontierUsesLabelParamDecidable
    (decl : AcceptedKindDecl)
    (param : KindParamDecl) :
    Decidable (decl.FrontierUsesLabelParam param) :=
  inferInstanceAs
    (Decidable
      ((∀ port, port ∈ decl.inputs → port.label = param.asFieldLabel) ∧
        ∀ port,
          port ∈ decl.outputPortsList →
            port.label = param.asFieldLabel))

/-- Kind parameter shape compatible with `make(N, K)` (ADR 0048).

`make` supplies one generated `PortLabel` per child, so the kind must expose
exactly one parameter and that parameter must be `KindParamClass.portLabel`.
Kinds that take additional `Contract`, `Value`, or `ConfiguredExecutor`
parameters are out of scope for `make` until a general parameter-binding design
exists (ADR 0048 Alternatives). The template frontier must also use that
parameter as every input/output label; otherwise generated child labels would
overwrite authored literal labels rather than substitute the `PortLabel` formal. -/
def KindSupportsMake (decl : AcceptedKindDecl) : Prop :=
  match decl.params with
  | [] => False
  | [param] =>
      param.paramClass = KindParamClass.portLabel ∧
        decl.FrontierUsesLabelParam param
  | _first :: _second :: _rest => False

instance kindSupportsMakeDecidable (decl : AcceptedKindDecl) :
    Decidable decl.KindSupportsMake := by
  unfold KindSupportsMake
  match decl.params with
  | [] => exact inferInstanceAs (Decidable False)
  | [_param] => exact inferInstanceAs (Decidable (_ ∧ _))
  | _first :: _second :: _rest => exact inferInstanceAs (Decidable False)

/-- Kind parameter shape compatible with `makeEach(items, K)`.

`makeEach` supplies one generated `PortLabel` per item, and may additionally
bind a static `Value` per item when the kind exposes one. The accepted shapes
are therefore: a sole `portLabel` parameter, or a `portLabel` parameter
followed by a single `value` parameter in source order. Other parameter
classes (`contract`, `configuredExecutor`) and longer parameter lists are
rejected at admission. As with `make`, the template frontier must use the
`PortLabel` formal at every input/output label position. -/
def KindSupportsMakeEach (decl : AcceptedKindDecl) : Prop :=
  match decl.params with
  | [] => False
  | [param] =>
      param.paramClass = KindParamClass.portLabel ∧
        decl.FrontierUsesLabelParam param
  | [first, second] =>
      first.paramClass = KindParamClass.portLabel ∧
        second.paramClass = KindParamClass.value ∧
          decl.FrontierUsesLabelParam first
  | _ :: _ :: _ :: _ => False

instance kindSupportsMakeEachDecidable (decl : AcceptedKindDecl) :
    Decidable decl.KindSupportsMakeEach := by
  unfold KindSupportsMakeEach
  match decl.params with
  | [] => exact inferInstanceAs (Decidable False)
  | [_param] => exact inferInstanceAs (Decidable (_ ∧ _))
  | [_first, _second] => exact inferInstanceAs (Decidable (_ ∧ _ ∧ _))
  | _ :: _ :: _ :: _ => exact inferInstanceAs (Decidable False)

/-- A kind compatible with `make` is also compatible with `makeEach`: the
generated `PortLabel` slot is the same, and the optional static `Value` slot is
allowed to be absent. -/
theorem kindSupportsMake_imp_kindSupportsMakeEach
    {decl : AcceptedKindDecl}
    (h : decl.KindSupportsMake) :
    decl.KindSupportsMakeEach := by
  unfold KindSupportsMake at h
  unfold KindSupportsMakeEach
  match hMatch : decl.params with
  | [] =>
      rw [hMatch] at h
      exact False.elim h
  | [param] =>
      rw [hMatch] at h
      exact h
  | _first :: _second :: _rest =>
      rw [hMatch] at h
      exact False.elim h

/-- A `make`-compatible kind has at most one flattened output port.

`KindSupportsMake` forces every template output label to be the sole
`PortLabel` parameter, while accepted kind declarations already require
flattened output labels to be unique. Together those invariants make
multi-output same-direction make templates impossible in this narrowed ADR 0048
slice. -/
theorem kindSupportsMake_outputPortsList_length_le_one
    {decl : AcceptedKindDecl}
    (h : decl.KindSupportsMake) :
    decl.outputPortsList.length ≤ 1 := by
  unfold KindSupportsMake at h
  match hParams : decl.params with
  | [] =>
      rw [hParams] at h
      exact False.elim h
  | [param] =>
      rw [hParams] at h
      rcases h with ⟨_hClass, hFrontier⟩
      cases hPorts : OutputShapeListPorts decl.outputs with
      | nil =>
          simp [AcceptedKindDecl.outputPortsList, hPorts]
      | cons head tail =>
          cases hTail : tail with
          | nil =>
              simp [AcceptedKindDecl.outputPortsList, hPorts, hTail]
          | cons second rest =>
              have hUniqueLabels :
                  (head.label :: second.label :: rest.map PortSignature.label).Nodup := by
                simpa [PortLabelListUnique, hPorts, hTail]
                  using decl.outputPortsListLabelsUnique
              simp only [List.nodup_cons, List.mem_cons] at hUniqueLabels
              rcases hUniqueLabels with ⟨hHeadFresh, _hTailUnique⟩
              have hHeadLabel : head.label = param.asFieldLabel := by
                exact hFrontier.right head (by simp [AcceptedKindDecl.outputPortsList, hPorts])
              have hSecondLabel : second.label = param.asFieldLabel := by
                exact hFrontier.right second
                  (by simp [AcceptedKindDecl.outputPortsList, hPorts, hTail])
              have hSameLabel : head.label = second.label := by
                rw [hHeadLabel, hSecondLabel]
              exact False.elim (hHeadFresh (Or.inl hSameLabel))
  | _first :: _second :: _rest =>
      rw [hParams] at h
      exact False.elim h

end AcceptedKindDecl

namespace GraphExpr

/-- Raw graph expressions reference only raw nodes, kinds, and graph bindings in the module shell.

This is a local closure predicate only. It does not reject graph cycles, repeated
linear resource references, invalid select coverage, or deterministic boundary
matching failures. -/
inductive RawRefsClosed
    (nodes : List RawNodeDecl)
    (kinds : List RawKindDecl)
    (graphs : List GraphBinding) :
    GraphExpr → Prop where
  | empty :
      RawRefsClosed nodes kinds graphs GraphExpr.empty
  | node {target : NodeId} :
      target ∈ nodes.map RawNodeDecl.node →
      RawRefsClosed nodes kinds graphs (GraphExpr.node target)
  | binding {target : BindingName} :
      target ∈ graphs.map GraphBinding.name →
      RawRefsClosed nodes kinds graphs (GraphExpr.binding target)
  | overlay {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.overlay left right)
  | connect {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.connect left right)
  | star {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.star left right)
  | select {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)} :
      RawRefsClosed nodes kinds graphs base →
      (∀ arm, arm ∈ arms → arm.fst.Valid) →
      (∀ arm, arm ∈ arms → RawRefsClosed nodes kinds graphs arm.snd) →
      RawRefsClosed nodes kinds graphs (GraphExpr.select base arms)
  | make {binding : BindingName} {count : Nat} {kind : KindName} :
      kind ∈ kinds.map RawKindDecl.kind →
      RawRefsClosed nodes kinds graphs (GraphExpr.make binding count kind)
  | makeEach {binding : BindingName} {kind : KindName} {items : List StaticValue} :
      kind ∈ kinds.map RawKindDecl.kind →
      RawRefsClosed nodes kinds graphs (GraphExpr.makeEach binding kind items)

/-- Accepted graph expressions reference only accepted nodes, kinds, and graph bindings.

This still is not graph admission: successful `=>`, `*`, `select(...)`, `make`,
and `makeEach` elaboration must later produce the corresponding proof objects. -/
inductive AcceptedRefsClosed
    (nodes : List AcceptedNodeDecl)
    (kinds : List AcceptedKindDecl)
    (graphs : List GraphBinding) :
    GraphExpr → Prop where
  | empty :
      AcceptedRefsClosed nodes kinds graphs GraphExpr.empty
  | node {target : NodeId} :
      target ∈ nodes.map AcceptedNodeDecl.node →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.node target)
  | binding {target : BindingName} :
      target ∈ graphs.map GraphBinding.name →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.binding target)
  | overlay {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.overlay left right)
  | connect {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.connect left right)
  | star {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.star left right)
  | select {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)} :
      AcceptedRefsClosed nodes kinds graphs base →
      (∀ arm, arm ∈ arms → arm.fst.Valid) →
      (∀ arm, arm ∈ arms → AcceptedRefsClosed nodes kinds graphs arm.snd) →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.select base arms)
  | make {binding : BindingName} {count : Nat} {kind : KindName} :
      kind ∈ kinds.map AcceptedKindDecl.kind →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.make binding count kind)
  | makeEach {binding : BindingName} {kind : KindName} {items : List StaticValue} :
      kind ∈ kinds.map AcceptedKindDecl.kind →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.makeEach binding kind items)

end GraphExpr

/-! ## Diagnostics And Modules -/

/-- Static elaboration diagnostics for the future Wire admission path.

Diagnostics that quote static values or graph expressions inherit the same
equality boundary as `GraphExpr`: this module keeps them printable, but does
not yet expose `DecidableEq` because `GraphExpr` itself still needs a manual
mutual instance through `List (SelectArmKey × GraphExpr)`. These constructors
seed the future admission vocabulary; the list will grow with the admission
functions that produce `ElabResult`. -/
inductive ElabDiagnostic where
  | duplicateNode (target : NodeId)
  | duplicateKind (target : KindName)
  | duplicateInputPort (owner : NodeId) (port : FieldLabel)
  | duplicateOutputPort (owner : NodeId) (port : FieldLabel)
  | duplicateRecordField (owner : ContractId) (field : FieldLabel)
  | unknownNode (target : NodeId)
  | unknownBinding (target : BindingName)
  | unknownKind (target : KindName)
  | repeatedGraphReference (target : BindingName)
  | ambiguousBoundaryMatch (contract : ContractId) (candidates : List PortSignature)
  | missingBoundaryMatch (contract : ContractId)
  | invalidMakeCount (binding : BindingName)
  | invalidMakeEachItem (binding : BindingName) (value : StaticValue)
  | invalidStarShape (left right : GraphExpr)
  | unsupported (message : String)
  deriving Repr

/-- Result of static elaboration/admission. -/
abbrev ElabResult (α : Type) : Type :=
  Except (List ElabDiagnostic) α

/-- Raw source module after parsing and source inclusion.

The raw module keeps graph bindings as syntax, so it remains on the printable
side of the equality boundary until `GraphExpr` gains structural equality. -/
structure RawModule where
  /-- Raw record contracts. -/
  contracts : List RecordContractDecl
  /-- Raw kind templates. -/
  kinds : List RawKindDecl
  /-- Raw node declarations. -/
  nodes : List RawNodeDecl
  /-- Raw graph bindings. -/
  graphs : List GraphBinding
  deriving Repr

namespace RawModule

/-- Local admission witness for a raw module shell.

This gathers declaration-local admission, per-namespace uniqueness, and reference
closure. It still does not construct certified graph artifacts, prove graph
linearity, bind executors against a registry, reject graph cycles, or elaborate
generated operators. -/
structure LocallyAdmissible (decl : RawModule) : Prop where
  /-- Every raw record contract is locally admissible. -/
  contractsAdmissible :
    ∀ contract, contract ∈ decl.contracts → contract.LocallyAdmissible
  /-- Every raw kind template is locally admissible. -/
  kindsAdmissible :
    ∀ kind, kind ∈ decl.kinds → kind.LocallyAdmissible
  /-- Every raw node declaration is locally admissible. -/
  nodesAdmissible :
    ∀ node, node ∈ decl.nodes → node.LocallyAdmissible
  /-- Every raw graph binding has a locally valid binding name. -/
  graphsValid :
    ∀ graph, graph ∈ decl.graphs → graph.LocalValid
  /-- Raw contract declarations are unique by contract identifier. -/
  contractsUnique : (decl.contracts.map RecordContractDecl.contract).Nodup
  /-- Raw kind declarations are unique by kind name. -/
  kindsUnique : (decl.kinds.map RawKindDecl.kind).Nodup
  /-- Raw node declarations are unique by node name. -/
  nodesUnique : (decl.nodes.map RawNodeDecl.node).Nodup
  /-- Raw graph bindings are unique by binding name. -/
  graphsUnique : (decl.graphs.map GraphBinding.name).Nodup
  /-- Raw record-field contracts are declared or bounded products over declared contracts. -/
  recordFieldContractsClosed :
    ∀ contract, contract ∈ decl.contracts → contract.FieldContractsClosed decl.contracts
  /-- Raw node port contracts are declared or bounded products over declared contracts. -/
  nodeContractsClosed :
    ∀ node, node ∈ decl.nodes → node.ContractsClosed decl.contracts
  /-- Raw kind port contracts are declared or bounded products over declared contracts. -/
  kindContractsClosed :
    ∀ kind, kind ∈ decl.kinds → kind.ContractsClosed decl.contracts
  /-- Raw graph expressions reference declared nodes, kinds, and graph bindings. -/
  graphRefsClosed :
    ∀ graph, graph ∈ decl.graphs → graph.expr.RawRefsClosed decl.nodes decl.kinds decl.graphs

end RawModule

namespace RawModule

/-- Accepted contract list projected from locally admissible raw contracts. -/
def acceptedContracts
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedRecordContractDecl :=
  decl.contracts.attach.map
    (fun contract =>
      contract.val.toAccepted
        (hAdmissible.contractsAdmissible contract.val contract.property))

/-- Accepted kind list projected from locally admissible raw kind templates. -/
def acceptedKinds
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedKindDecl :=
  decl.kinds.attach.map
    (fun kind =>
      kind.val.toAccepted
        (hAdmissible.kindsAdmissible kind.val kind.property))

/-- Accepted node list projected from locally admissible raw node declarations. -/
def acceptedNodes
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedNodeDecl :=
  decl.nodes.attach.map
    (fun node =>
      node.val.toAccepted
        (hAdmissible.nodesAdmissible node.val node.property))

/-- Projecting accepted contracts preserves the raw contract-name list. -/
theorem acceptedContracts_contracts
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedContracts hAdmissible).map AcceptedRecordContractDecl.contract =
      decl.contracts.map RecordContractDecl.contract := by
  simp [acceptedContracts, RecordContractDecl.toAccepted]

/-- Projecting accepted kinds preserves the raw kind-name list. -/
theorem acceptedKinds_kinds
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedKinds hAdmissible).map AcceptedKindDecl.kind =
      decl.kinds.map RawKindDecl.kind := by
  simp [acceptedKinds, RawKindDecl.toAccepted]

/-- Projecting accepted nodes preserves the raw node-name list. -/
theorem acceptedNodes_nodes
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedNodes hAdmissible).map AcceptedNodeDecl.node =
      decl.nodes.map RawNodeDecl.node := by
  simp [acceptedNodes, RawNodeDecl.toAccepted]

/-- Raw graph reference closure transfers across local raw-to-accepted declaration projection. -/
theorem rawRefsClosed_toAccepted
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible)
    {expr : GraphExpr}
    (hClosed : expr.RawRefsClosed decl.nodes decl.kinds decl.graphs) :
    expr.AcceptedRefsClosed
      (decl.acceptedNodes hAdmissible)
      (decl.acceptedKinds hAdmissible)
      decl.graphs := by
  induction hClosed with
  | empty =>
      exact GraphExpr.AcceptedRefsClosed.empty
  | node hNode =>
      exact
        GraphExpr.AcceptedRefsClosed.node
          (by
            rw [acceptedNodes_nodes]
            exact hNode)
  | binding hBinding =>
      exact GraphExpr.AcceptedRefsClosed.binding hBinding
  | overlay _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.overlay ihLeft ihRight
  | connect _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.connect ihLeft ihRight
  | star _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.star ihLeft ihRight
  | select _hBase hArmKeys _hArms ihBase ihArms =>
      exact GraphExpr.AcceptedRefsClosed.select ihBase hArmKeys ihArms
  | make hKind =>
      exact
        GraphExpr.AcceptedRefsClosed.make
          (by
            rw [acceptedKinds_kinds]
            exact hKind)
  | makeEach hKind =>
      exact
        GraphExpr.AcceptedRefsClosed.makeEach
          (by
            rw [acceptedKinds_kinds]
            exact hKind)

end RawModule

/-- Accepted module shell.

Kinds and nodes here have reached their accepted carriers. Graph bindings remain
plain expression carriers: the actual certificates connecting graph expressions
to `LinearPortObject`, `MakeWitness`, `PhantomAdapterWitness`, and `BulkContract`
are intentionally left to later proof modules. Accepted modules also do not
expose decidable equality until graph expressions do.

The uniqueness fields are per represented namespace. Full Wire source-scope
collision checks across contracts, nodes, graph/value lets, imports, executors,
and future kinds belong to module admission rather than this local carrier.
Graph-binding reference cycles are also admissible at this shell layer; later
binding-body admission should require `GraphBinding.BindingRefAcyclic graphs`
or a stronger executable unfolding-order witness. -/
structure AdmittedModuleShell where
  /-- Accepted record contracts. -/
  contracts : List AcceptedRecordContractDecl
  /-- Accepted record contract identifiers are unique inside the module shell. -/
  contractsUnique : (contracts.map AcceptedRecordContractDecl.contract).Nodup
  /-- Accepted kind templates. -/
  kinds : List AcceptedKindDecl
  /-- Accepted kind names are unique inside the module shell. -/
  kindsUnique : (kinds.map AcceptedKindDecl.kind).Nodup
  /-- Accepted node declarations. -/
  nodes : List AcceptedNodeDecl
  /-- Accepted node names are unique inside the module shell. -/
  nodesUnique : (nodes.map AcceptedNodeDecl.node).Nodup
  /-- Graph bindings awaiting future certified topology admission. -/
  graphs : List GraphBinding
  /-- Graph binding names are unique inside the module shell. -/
  graphsUnique : (graphs.map GraphBinding.name).Nodup
  /-- Accepted graph bindings have locally valid binding names. -/
  graphsValid :
    ∀ graph, graph ∈ graphs → graph.LocalValid
  /-- Accepted record-field contracts are declared or bounded products over declared contracts. -/
  recordFieldContractsClosed :
    ∀ contract, contract ∈ contracts → AcceptedRecordFieldContractsClosed contract contracts
  /-- Accepted node port contracts are declared or bounded products over declared contracts. -/
  nodeContractsClosed :
    ∀ node, node ∈ nodes → node.ContractsClosed contracts
  /-- Accepted kind port contracts are declared or bounded products over declared contracts. -/
  kindContractsClosed :
    ∀ kind, kind ∈ kinds → kind.ContractsClosed contracts
  /-- Accepted graph expressions reference declared nodes, kinds, and graph bindings. -/
  graphRefsClosed :
    ∀ graph, graph ∈ graphs → graph.expr.AcceptedRefsClosed nodes kinds graphs

namespace AdmittedModuleShell

/-- Every graph binding in an admitted module shell owns the generated forms it contains.

This is the transitive enforcement point for `GeneratedFormsOwnedBy`: individual
`GraphBinding.LocalValid` carries the local owner proof, and the shell requires
that local validity for every binding in `graphs`. -/
theorem graph_generatedFormsOwnedBy
    (mod : AdmittedModuleShell)
    {graph : GraphBinding}
    (hGraph : graph ∈ mod.graphs) :
    graph.expr.GeneratedFormsOwnedBy graph.name :=
  (mod.graphsValid graph hGraph).right

end AdmittedModuleShell

namespace RawModule

/-- Locally admissible raw module shells project to accepted module shells.

This is still not certified graph elaboration. It only transports local
declaration admission, namespace uniqueness, and reference-closure witnesses to
the accepted carrier. -/
def toAccepted
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    AdmittedModuleShell :=
  { contracts := decl.acceptedContracts hAdmissible
    contractsUnique := by
      rw [acceptedContracts_contracts]
      exact hAdmissible.contractsUnique
    kinds := decl.acceptedKinds hAdmissible
    kindsUnique := by
      rw [acceptedKinds_kinds]
      exact hAdmissible.kindsUnique
    nodes := decl.acceptedNodes hAdmissible
    nodesUnique := by
      rw [acceptedNodes_nodes]
      exact hAdmissible.nodesUnique
    graphs := decl.graphs
    graphsUnique := hAdmissible.graphsUnique
    graphsValid := hAdmissible.graphsValid
    recordFieldContractsClosed := by
      intro contract hContract
      rcases List.mem_map.mp hContract with ⟨rawContract, _hRawContractMem, hEq⟩
      subst hEq
      intro field hField
      have hRawField : field ∈ rawContract.val.fields := by
        simpa [RecordContractDecl.toAccepted] using hField
      have hKnown :
          ContractId.ClosedBy
            (decl.contracts.map RecordContractDecl.contract)
            field.contract :=
        hAdmissible.recordFieldContractsClosed
          rawContract.val
          rawContract.property
          field
          hRawField
      rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
      exact hKnown
    nodeContractsClosed := by
      intro node hNode
      rcases List.mem_map.mp hNode with ⟨rawNode, _hRawNodeMem, hEq⟩
      subst hEq
      refine ⟨?_, ?_⟩
      · intro port hPort
        have hRawPort : port ∈ rawNode.val.inputs := by
          simpa [RawNodeDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            ContractId.ClosedBy
              (decl.contracts.map RecordContractDecl.contract)
              port.contract :=
          (hAdmissible.nodeContractsClosed rawNode.val rawNode.property).left
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
      · intro port hPort
        have hPortList : port ∈ rawNode.val.outputPortsList := by
          have hMem :
              port ∈ (OutputShapeListPorts (rawNode.val.toAccepted
                (hAdmissible.nodesAdmissible rawNode.val rawNode.property)).outputs).toFinset := by
            simpa [AcceptedNodeDecl.outputPorts, AcceptedNodeDecl.outputPortsList] using hPort
          have hList :
              port ∈ OutputShapeListPorts (rawNode.val.toAccepted
                (hAdmissible.nodesAdmissible rawNode.val rawNode.property)).outputs :=
            List.mem_toFinset.mp hMem
          simpa [RawNodeDecl.toAccepted, RawNodeDecl.outputPortsList] using hList
        have hKnown :
            ContractId.ClosedBy
              (decl.contracts.map RecordContractDecl.contract)
              port.contract :=
          (hAdmissible.nodeContractsClosed rawNode.val rawNode.property).right
            port
            hPortList
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
    kindContractsClosed := by
      intro kind hKind
      rcases List.mem_map.mp hKind with ⟨rawKind, _hRawKindMem, hEq⟩
      subst hEq
      refine ⟨?_, ?_⟩
      · intro port hPort
        have hRawPort : port ∈ rawKind.val.inputs := by
          simpa [RawKindDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            ContractId.ClosedBy
              (decl.contracts.map RecordContractDecl.contract)
              port.contract :=
          (hAdmissible.kindContractsClosed rawKind.val rawKind.property).left
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
      · intro port hPort
        have hPortList : port ∈ rawKind.val.outputPortsList := by
          have hMem :
              port ∈ (OutputShapeListPorts (rawKind.val.toAccepted
                (hAdmissible.kindsAdmissible rawKind.val rawKind.property)).outputs).toFinset := by
            simpa [AcceptedKindDecl.outputPorts, AcceptedKindDecl.outputPortsList] using hPort
          have hList :
              port ∈ OutputShapeListPorts (rawKind.val.toAccepted
                (hAdmissible.kindsAdmissible rawKind.val rawKind.property)).outputs :=
            List.mem_toFinset.mp hMem
          simpa [RawKindDecl.toAccepted, RawKindDecl.outputPortsList] using hList
        have hKnown :
            ContractId.ClosedBy
              (decl.contracts.map RecordContractDecl.contract)
              port.contract :=
          (hAdmissible.kindContractsClosed rawKind.val rawKind.property).right
            port
            hPortList
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
    graphRefsClosed := by
      intro graph hGraph
      exact
        rawRefsClosed_toAccepted
          decl
          hAdmissible
          (hAdmissible.graphRefsClosed graph hGraph) }

end RawModule

/-! ## Shape Examples -/

namespace Examples

/-- Example contract used by the C-build shape example. -/
def commandSpecContract : ContractId :=
  ⟨"CommandSpec"⟩

/-- Declared scalar contracts are closed against their declaration namespace. -/
theorem commandSpecContract_closed :
    ContractId.ClosedBy [commandSpecContract] commandSpecContract :=
  ContractId.ClosedBy.declared (by simp)

/-- Example bounded indexed product contract over command specs. -/
def commandSpecBatchContract : ContractId :=
  ContractId.boundedIndexed commandSpecContract 3

/-- Bounded indexed products are closed when their element contract is closed. -/
theorem commandSpecBatchContract_closed :
    ContractId.ClosedBy [commandSpecContract] commandSpecBatchContract :=
  ContractId.ClosedBy.boundedIndexed 3 (by simp)

/-- Zero-count indexed products are intentionally admitted as empty finite products. -/
def commandSpecEmptyBatchContract : ContractId :=
  ContractId.boundedIndexed commandSpecContract 0

/-- Empty indexed products still close over a directly declared element contract. -/
theorem commandSpecEmptyBatchContract_closed :
    ContractId.ClosedBy [commandSpecContract] commandSpecEmptyBatchContract :=
  ContractId.ClosedBy.boundedIndexed 0 (by simp)

/-- Example contract for a compiled object artifact. -/
def objectArtifactContract : ContractId :=
  ⟨"ObjectArtifact"⟩

/-- Example input port carrying a command spec. -/
def specPort : PortSignature :=
  { label := ⟨"spec"⟩, contract := commandSpecContract }

/-- The example command-spec input port is locally valid. -/
theorem specPort_valid : specPort.Valid := by
  constructor <;> decide

/-- Example output port carrying a build artifact. -/
def artifactPort : PortSignature :=
  { label := ⟨"artifact"⟩, contract := objectArtifactContract }

/-- The example artifact output port is locally valid. -/
theorem artifactPort_valid : artifactPort.Valid := by
  constructor <;> decide

/-- Accepted single output shape produced by a `cBuild`-shaped artifact node. -/
def artifactSingleShape : OutputShape :=
  OutputShape.single artifactPort

/-- The example artifact single-output shape is locally admissible. -/
theorem artifactSingleShape_admissible : artifactSingleShape.LocallyAdmissible :=
  OutputShape.LocallyAdmissible.single artifactPort_valid

/-- Accepted single output shape that re-exposes the spec port on the output side. -/
def specSingleShape : OutputShape :=
  OutputShape.single specPort

/-- The example spec single-output shape is locally admissible. -/
theorem specSingleShape_admissible : specSingleShape.LocallyAdmissible :=
  OutputShape.LocallyAdmissible.single specPort_valid

/-- Singleton authored output shape lists are locally admissible when the shape itself is. -/
theorem singleton_outputShapeListAdmissible
    {shape : OutputShape}
    (hShape : shape.LocallyAdmissible) :
    OutputShapeListAdmissible [shape] := by
  intro candidate hCandidate
  rcases List.mem_singleton.mp hCandidate with hEq
  exact hEq ▸ hShape

/-- A single-port output shape produces a length-one flattened port list. -/
theorem singleton_outputShapeListPortsLabelsUnique
    (port : PortSignature) :
    PortLabelListUnique (OutputShapeListPorts [OutputShape.single port]) := by
  simp [PortLabelListUnique, OutputShapeListPorts, OutputShape.ports]

/-- Accepted shape of one compile node in the C-build example family. -/
def cBuildCompileNode : AcceptedNodeDecl where
  node := ⟨"compile_metrics"⟩
  nodeValid := by decide
  inputs := {specPort}
  outputs := [artifactSingleShape]
  inputPortsValid := singleton_portSignaturesValid specPort_valid
  outputShapesAdmissible := singleton_outputShapeListAdmissible artifactSingleShape_admissible
  outputPortsListLabelsUnique := singleton_outputShapeListPortsLabelsUnique artifactPort
  inputLabelsUnique := singleton_portLabelsUnique specPort
  body := NodeBodyBoundary.executor ⟨"shell"⟩
  bodyLocalValid := by decide

/-- Accepted pass-through shape showing that input and output directions may reuse a label. -/
def cBuildPassThroughNode : AcceptedNodeDecl where
  node := ⟨"pass_spec"⟩
  nodeValid := by decide
  inputs := {specPort}
  outputs := [specSingleShape]
  inputPortsValid := singleton_portSignaturesValid specPort_valid
  outputShapesAdmissible := singleton_outputShapeListAdmissible specSingleShape_admissible
  outputPortsListLabelsUnique := singleton_outputShapeListPortsLabelsUnique specPort
  inputLabelsUnique := singleton_portLabelsUnique specPort
  body := NodeBodyBoundary.corePure
  bodyLocalValid := trivial

/-- C-build-shaped graph expression using both `makeEach` and `*`.

This only demonstrates representability of post-source-include syntax. Future
modules must still certify the expression and produce the linear certificates. -/
def cBuildGraphShape : GraphExpr :=
  GraphExpr.connect
    (GraphExpr.makeEach
      ⟨"compile_units"⟩
      ⟨"compile_unit"⟩
      [ StaticValue.string "src/lib/metrics.c"
      , StaticValue.string "src/lib/parse.c"
      , StaticValue.string "src/app/main.c"
      ])
    (GraphExpr.star
      (GraphExpr.node ⟨"archive_lib"⟩)
      (GraphExpr.node ⟨"link_app"⟩))

end Examples

end ElaborationIR
end Cortex.Wire
