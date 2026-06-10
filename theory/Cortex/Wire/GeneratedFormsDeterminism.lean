import Cortex.Wire.GeneratedForms

/-!
## Overview

Determinism of derived-form elaboration: the accepted object for `make(N, K)`
and `makeEach(items, K)` is a function of the elaboration inputs.

`Make.accept` and `MakeEach.accept` consume a `KindInstantiatedFrontiers`
witness supplied by the caller. The theorems here close the apparent freedom in
that witness: every data field of `KindInstantiatedFrontiers` is pinned by its
exactness laws once the child labels are fixed, and the label witnesses pin the
child labels to the generated (`make`) or item-derived (`makeEach`) labels. Two
witnesses for the same source therefore coincide, and `accept` returns one
canonical object per source. This is the proof-side statement matching the
paper-facing claim that elaboration is deterministic by construction, and it
sharpens the compiler-emission target: the artifact a compilation emits for a
generated form is unique for its source.

`Star.accept` carries no analogous freedom seam: it is `Except.ok` of the
supplied witness's insertion, so determinism reduces to determinism of the
phantom-adapter witness construction, which lives with the front-end checker.
-/

namespace Cortex.Wire
namespace LinearPortGraph

open Cortex.Wire.ElaborationIR

variable {binding node : Type}
variable [DecidableEq node]

namespace KindInstantiatedFrontiers

variable {kind : AcceptedKindDecl}
variable {nodeBinding : node → binding}
variable {policy : GeneratedNamePolicy binding node nodeBinding}
variable {sourceBinding : binding}
variable {count : Nat}

/-- Per-child output ports are determined by the child labels. -/
theorem childOutputPorts_eq_of_childLabel_eq
    (left right : KindInstantiatedFrontiers kind policy sourceBinding count)
    (hLabels : left.childLabel = right.childLabel) :
    left.childOutputPorts = right.childOutputPorts := by
  funext index
  ext port
  rw [left.childOutputPorts_exact index port, right.childOutputPorts_exact index port, hLabels]

/-- Per-child input ports are determined by the child labels. -/
theorem childInputPorts_eq_of_childLabel_eq
    (left right : KindInstantiatedFrontiers kind policy sourceBinding count)
    (hLabels : left.childLabel = right.childLabel) :
    left.childInputPorts = right.childInputPorts := by
  funext index
  ext port
  rw [left.childInputPorts_exact index port, right.childInputPorts_exact index port, hLabels]

/-- The generated output instances are determined by the child labels. -/
theorem outputs_eq_of_childLabel_eq
    (left right : KindInstantiatedFrontiers kind policy sourceBinding count)
    (hLabels : left.childLabel = right.childLabel) :
    left.outputs = right.outputs := by
  have hPorts := childOutputPorts_eq_of_childLabel_eq left right hLabels
  ext output
  rw [left.outputs_exact output, right.outputs_exact output, hPorts]

/-- The generated input instances are determined by the child labels. -/
theorem inputs_eq_of_childLabel_eq
    (left right : KindInstantiatedFrontiers kind policy sourceBinding count)
    (hLabels : left.childLabel = right.childLabel) :
    left.inputs = right.inputs := by
  have hPorts := childInputPorts_eq_of_childLabel_eq left right hLabels
  ext input
  rw [left.inputs_exact input, right.inputs_exact input, hPorts]

/-- A kind-instantiated frontier witness is determined by its child labels:
every other data field is pinned by an exactness law. -/
theorem eq_of_childLabel_eq
    (left right : KindInstantiatedFrontiers kind policy sourceBinding count)
    (hLabels : left.childLabel = right.childLabel) :
    left = right := by
  have hOutputs := outputs_eq_of_childLabel_eq left right hLabels
  have hInputs := inputs_eq_of_childLabel_eq left right hLabels
  have hChildOutputs := childOutputPorts_eq_of_childLabel_eq left right hLabels
  have hChildInputs := childInputPorts_eq_of_childLabel_eq left right hLabels
  cases left
  cases right
  simp_all

end KindInstantiatedFrontiers

namespace Make

/-- The label witness pins the child labels, so any two `make` frontier
witnesses for the same source coincide. -/
theorem frontiers_unique
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    {kind : AcceptedKindDecl}
    {count : Nat}
    (left right :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabelsLeft :
      ∀ index,
        left.childLabel index = makeIndexLabel sourceBinding index.val)
    (hLabelsRight :
      ∀ index,
        right.childLabel index = makeIndexLabel sourceBinding index.val) :
    left = right :=
  KindInstantiatedFrontiers.eq_of_childLabel_eq left right
    (funext fun index => (hLabelsLeft index).trans (hLabelsRight index).symm)

/-- `make(N, K)` admission is deterministic: the accepted object does not
depend on which frontier witness the caller supplies. -/
theorem accept_deterministic
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (left right :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabelsLeft :
      ∀ index,
        left.childLabel index = makeIndexLabel sourceBinding index.val)
    (hLabelsRight :
      ∀ index,
        right.childLabel index = makeIndexLabel sourceBinding index.val) :
    accept policy sourceBinding kind hKind count left hLabelsLeft =
      accept policy sourceBinding kind hKind count right hLabelsRight := by
  cases frontiers_unique policy sourceBinding left right hLabelsLeft hLabelsRight
  rfl

end Make

namespace MakeEach

/-- The item-label witness pins the child labels, so any two `makeEach`
frontier witnesses for the same item list coincide. -/
theorem frontiers_unique
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    {kind : AcceptedKindDecl}
    {items : List MakeItem}
    (left right :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabelsLeft :
      ∀ index,
        left.childLabel index = (items.get index).label)
    (hLabelsRight :
      ∀ index,
        right.childLabel index = (items.get index).label) :
    left = right :=
  KindInstantiatedFrontiers.eq_of_childLabel_eq left right
    (funext fun index => (hLabelsLeft index).trans (hLabelsRight index).symm)

/-- `makeEach(items, K)` admission is deterministic: the accepted object does
not depend on which frontier witness the caller supplies. The item-label
check branches only on `items`, which both calls share. -/
theorem accept_deterministic
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (left right :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabelsLeft :
      ∀ index,
        left.childLabel index = (items.get index).label)
    (hLabelsRight :
      ∀ index,
        right.childLabel index = (items.get index).label) :
    accept policy sourceBinding kind hKind items left hLabelsLeft =
      accept policy sourceBinding kind hKind items right hLabelsRight := by
  cases frontiers_unique policy sourceBinding left right hLabelsLeft hLabelsRight
  rfl

end MakeEach

end LinearPortGraph
end Cortex.Wire
