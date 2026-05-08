import Mathlib.Data.Fintype.Basic
import Cortex.Wire.PortLinearity
import Cortex.Wire.Make
import Cortex.Wire.PhantomAdapter
import Cortex.Wire.ElaborationIR

/-!
## Overview

Source-linearity admission for Wire's three generated graph forms.

## Context

ADR 0048 introduces `make(N, K)`, ADR 0051 introduces `makeEach(items, K)`, and
ADR 0049 introduces `*`. None of the three forms is admitted as a runtime
operator: each elaborates at compile time to ordinary structure inside the
closed source linear-port algebra of `Cortex.Wire.PortLinearity`.

This module is the integration point that turns the carriers in
`Cortex.Wire.Make` and `Cortex.Wire.PhantomAdapter` into named admission
functions targeted at `LinearPortObject`. Each function returns either a
diagnostic from a small named sum, or a certified `LinearPortObject`. No
admission decision is hardcoded against any specific identity scheme. Generated
node identities come through the abstract `GeneratedNamePolicy`; the Haskell
side will supply a concrete instance later.

## Theorem Split

`GeneratedNamePolicy` is the identity-scheme abstraction. `prefixedIndex` is the
default ADR 0048 name-policy: `<binding>_<index>`.
`KindInstantiatedFrontiers` is the kind-expansion handoff: callers substitute
the generated `PortLabel` and any static `Value` parameters, then supply exact
per-child frontiers indexed by the `AcceptedKindDecl` that was instantiated.
`Make.accept`, `MakeEach.accept`, and `Star.accept` are the three admission
entry points; they return `Except <Error> (LinearPortObject ...)`. The work of
overlay, contraction, and phantom synthesis is delegated to `MakeWitness` and
`PhantomAdapterWitness` in the dependent modules; this file does not reprove
what those carriers already establish.
-/

namespace Cortex.Wire
namespace LinearPortGraph

open Cortex.Wire.ElaborationIR

variable {binding node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

/-! ## Generated Name Policy -/

/-- `GeneratedNamePolicy` abstracts how generated children of a binding receive stable identities.

ADR 0048 fixes one identity scheme (`<binding>_<index>`) for emitted Haskell. The proof side does
not commit to that exact scheme: the policy supplies an opaque per-binding indexing function plus
the injectivity and binding-namespace facts that `MakeWitness` requires. The Haskell side is free
to instantiate this with the concrete ADR 0048 hash. -/
structure GeneratedNamePolicy
    (binding node : Type)
    (nodeBinding : node → binding) where
  /-- Generated child node for one binding-and-index pair. -/
  childNode : binding → Nat → node
  /-- Distinct indices under one binding produce distinct generated nodes. -/
  childNode_injective :
    ∀ (sourceBinding : binding) {left right : Nat},
      childNode sourceBinding left = childNode sourceBinding right → left = right
  /-- Every generated child belongs to its binding's namespace under the supplied projection. -/
  childNode_binding :
    ∀ (sourceBinding : binding) (index : Nat),
      nodeBinding (childNode sourceBinding index) = sourceBinding

namespace GeneratedNamePolicy

/-- The per-binding child indexing function viewed at a fixed binding and a count. -/
def childIndex
    (policy : GeneratedNamePolicy binding node nodeBinding)
    (sourceBinding : binding)
    {count : Nat}
    (index : Fin count) :
    node :=
  policy.childNode sourceBinding index.val

omit [DecidableEq node] [DecidableEq outputPort] [DecidableEq inputPort] in
/-- Fixed-binding child indexing is injective on its index domain. -/
theorem childIndex_injective
    (policy : GeneratedNamePolicy binding node nodeBinding)
    (sourceBinding : binding)
    {count : Nat} :
    Function.Injective (policy.childIndex sourceBinding (count := count)) := by
  intro left right hEq
  have hVal : left.val = right.val :=
    policy.childNode_injective sourceBinding hEq
  exact Fin.ext hVal

end GeneratedNamePolicy

/-! ### Default Prefixed-Index Carrier -/

/-- ADR 0048's default identity scheme `<binding>_<index>`.

The proof side keeps the suffix encoding opaque so the Haskell elaborator can pick its own
deterministic serialization without invalidating the proof. The string-side injectivity of
`prefixedIndexNodeId` (cancellation through binding-prefix-and-`_`) is supplied as carrier data:
because Lean's standard library does not expose a `String.append_left_cancel` lemma, callers
prove this once for their chosen suffix encoder and once for their binding-name discipline.

This module does not commit to one encoder. The carrier is the public seam between the proof
side and the Haskell elaborator's identity scheme. -/
def prefixedIndexNodeId
    (suffix : Nat → String)
    (sourceBinding : ElaborationIR.BindingName)
    (index : Nat) :
    ElaborationIR.NodeId :=
  { name := sourceBinding.name ++ "_" ++ suffix index }

/-- Carrier collecting the obligations that turn `prefixedIndexNodeId` into a
`GeneratedNamePolicy`.

`prefixed_injective` is supplied directly because the Lean standard library lacks a
`String.append_left_cancel` lemma. Concrete carriers prove it from their chosen encoder. -/
structure PrefixedIndexCarrier where
  /-- Deterministic encoding from indices to suffix strings. -/
  suffix : Nat → String
  /-- The opaque projection from generated nodes back to their owning binding. -/
  nodeBinding : ElaborationIR.NodeId → ElaborationIR.BindingName
  /-- Every prefixed node projects back to its binding. -/
  prefixed_binding :
    ∀ (sourceBinding : ElaborationIR.BindingName) (index : Nat),
      nodeBinding (prefixedIndexNodeId suffix sourceBinding index) = sourceBinding
  /-- Distinct indices at one binding produce distinct prefixed nodes. -/
  prefixed_injective :
    ∀ (sourceBinding : ElaborationIR.BindingName) {left right : Nat},
      prefixedIndexNodeId suffix sourceBinding left =
          prefixedIndexNodeId suffix sourceBinding right →
        left = right

/-- Default `GeneratedNamePolicy` derived from a `PrefixedIndexCarrier`. -/
def prefixedIndexPolicy (carrier : PrefixedIndexCarrier) :
    GeneratedNamePolicy ElaborationIR.BindingName ElaborationIR.NodeId carrier.nodeBinding where
  childNode := prefixedIndexNodeId carrier.suffix
  childNode_injective := carrier.prefixed_injective
  childNode_binding := carrier.prefixed_binding

/-! ## Generated Form Diagnostics -/

/-- Reasons a `make(N, K)` admission can be rejected at the source-linearity layer.

`Make.accept` consumes an already-proved `KindSupportsMake` witness, so it does
not branch over these constructors directly. They are reserved for the
front-end admission pass that constructs that witness from source kinds. -/
inductive MakeError where
  /-- The kind exposes no `PortLabel` parameter to drive per-child instantiation. -/
  | missingPortLabel (binding : ElaborationIR.BindingName) (kind : ElaborationIR.KindName)
  /-- The kind exposes more than one `PortLabel` parameter, which `make` cannot resolve. -/
  | multiplePortLabels (binding : ElaborationIR.BindingName) (kind : ElaborationIR.KindName)
  /-- The static count is malformed. ADR 0048 only accepts a non-negative integer literal. -/
  | invalidCount (binding : ElaborationIR.BindingName)
  deriving DecidableEq, Repr

/-- Reasons a `makeEach(items, K)` admission can be rejected at the source-linearity layer.

`MakeEach.accept` consumes `KindSupportsMakeEach`; the missing/multiple
`PortLabel` diagnostics belong to the front-end pass that constructs that
witness. This module emits only item-label diagnostics directly. -/
inductive MakeEachError where
  /-- The static items list contained a duplicate generated label. -/
  | duplicateGeneratedLabel
      (binding : ElaborationIR.BindingName)
      (label : ElaborationIR.FieldLabel)
  /-- The kind exposes no `PortLabel` parameter to drive per-item instantiation. -/
  | missingPortLabel (binding : ElaborationIR.BindingName) (kind : ElaborationIR.KindName)
  /-- The kind exposes more than one `PortLabel` parameter, which `makeEach` cannot resolve. -/
  | multiplePortLabels (binding : ElaborationIR.BindingName) (kind : ElaborationIR.KindName)
  /-- A static item produced an empty or otherwise invalid label. -/
  | invalidItemLabel (binding : ElaborationIR.BindingName) (label : ElaborationIR.FieldLabel)
  deriving DecidableEq, Repr

/-- Reasons a `*` admission can be rejected at the source-linearity layer. -/
inductive StarError where
  /-- The singular side did not expose a nominal record contract. -/
  | nonRecordSingularSide (contract : ElaborationIR.ContractId)
  /-- The multi-side label set did not match the record's field labels. -/
  | recordFieldMismatch
      (contract : ElaborationIR.ContractId)
      (recordFields : List ElaborationIR.FieldLabel)
      (multiLabels : List ElaborationIR.FieldLabel)
  /-- Phantom synthesis would produce a port clash with one of the operands. -/
  | phantomPortClash
  deriving DecidableEq, Repr

/-! ## Make Items For `makeEach` -/

/-- One static-list item presented to `makeEach`.

ADR 0051 derives this from include-resolved values: directory entries with a `label` field, plain
strings, or homogeneous record items. The proof carrier keeps only the generated label and a
parallel `StaticValue` payload that downstream consumers can use for kind parameter binding. -/
structure MakeItem where
  /-- Source-stable label that names the generated child. -/
  label : ElaborationIR.FieldLabel
  /-- Optional original static value for kinds that take a `Value` parameter. -/
  value : Option ElaborationIR.StaticValue

namespace MakeItem

/-- A `makeEach` item has a locally valid generated label. -/
def Valid (item : MakeItem) : Prop :=
  item.label.Valid

instance validDecidable (item : MakeItem) : Decidable item.Valid :=
  inferInstanceAs (Decidable item.label.Valid)

/-- Every generated label in a `makeEach` item list is locally valid. -/
def ItemsValid (items : List MakeItem) : Prop :=
  ∀ item, item ∈ items → item.Valid

instance itemsValidDecidable (items : List MakeItem) :
    Decidable (MakeItem.ItemsValid items) :=
  inferInstanceAs (Decidable (∀ item, item ∈ items → item.Valid))

/-- A list of make-items has no duplicate labels. -/
def LabelsUnique (items : List MakeItem) : Prop :=
  (items.map MakeItem.label).Nodup

/-- `LabelsUnique` is decidable because `FieldLabel` has decidable equality. -/
instance labelsUniqueDecidable (items : List MakeItem) :
    Decidable (MakeItem.LabelsUnique items) :=
  inferInstanceAs (Decidable (items.map MakeItem.label).Nodup)

end MakeItem

/-! ## Kind-Instantiated Child Frontiers -/

/-- Default generated port label for `make(N, K)` children.

This mirrors the source-facing `<binding>_<index>` convention at the port-label
level. Name freshness for graph nodes is handled by `GeneratedNamePolicy`; this
label helper only pins the generated frontier labels used by the kind
substitution witness.

The helper is not an injectivity proof: it uses ordinary string concatenation.
Callers that rely on generated label distinctness must carry a separate
`MakeItem.LabelsUnique` witness or prove injectivity from their chosen
binding/index grammar. -/
def makeIndexLabel
    (sourceBinding : BindingName)
    (index : Nat) :
    FieldLabel :=
  ⟨sourceBinding.name ++ "_" ++ toString index⟩

/-- Generated nodes for one binding under a name policy. -/
def generatedNodes
    {nodeBinding : node → binding}
    (policy : GeneratedNamePolicy binding node nodeBinding)
    (sourceBinding : binding)
    (count : Nat) :
    Finset node :=
  (Finset.univ : Finset (Fin count)).image (policy.childIndex sourceBinding)

/-- Concrete child frontiers after a reusable kind has been instantiated.

This is the proof-side handoff from kind-parameter substitution to source-linearity admission.
Haskell already substitutes `PortLabel`/`Value` parameters before lowering; Lean receives the
result as exact generated output/input port sets plus the per-child port families that
`MakeWitness` needs. The accepted kind is a type index, not data used during projection: this
prevents callers from pairing `KindSupportsMake` evidence for one kind with frontiers produced for
another kind.

The child frontier fields are also tied back to the kind's accepted template
frontier: each generated child receives one input/output port per template port,
preserving the template contract and replacing the authored label with the
generated child label. The `KindSupportsMake`/`KindSupportsMakeEach`
preconditions on the admission entry points prove that those authored labels are
exactly the kind's `PortLabel` formal, so replacement is parameter substitution
rather than arbitrary label overwrite. -/
structure KindInstantiatedFrontiers
    (kind : AcceptedKindDecl)
    {nodeBinding : node → binding}
    (policy : GeneratedNamePolicy binding node nodeBinding)
    (sourceBinding : binding)
    (count : Nat) where
  /-- Generated source port label for each child instance. -/
  childLabel : Fin count → FieldLabel
  /-- Concrete generated output instances after kind substitution. -/
  outputs : Finset (SourcePortInstance node OutputPortSignature)
  /-- Concrete generated input instances after kind substitution. -/
  inputs : Finset (SourcePortInstance node InputPortSignature)
  /-- Per-child output ports after substituting the generated `PortLabel`. -/
  childOutputPorts : Fin count → Finset OutputPortSignature
  /-- Per-child input ports after substituting the generated `PortLabel`. -/
  childInputPorts : Fin count → Finset InputPortSignature
  /-- Per-child output ports are exactly the kind template outputs with the generated label. -/
  childOutputPorts_exact :
    ∀ index port,
      port ∈ childOutputPorts index ↔
        ∃ template,
          template ∈ kind.outputPorts ∧
            port.signature =
              { label := childLabel index
                contract := template.contract }
  /-- Per-child input ports are exactly the kind template inputs with the generated label. -/
  childInputPorts_exact :
    ∀ index port,
      port ∈ childInputPorts index ↔
        ∃ template,
          template ∈ kind.inputs ∧
            port.signature =
              { label := childLabel index
                contract := template.contract }
  /-- Every generated output belongs to a generated child node. -/
  output_nodes :
    ∀ output,
      output ∈ outputs →
        output.node ∈ generatedNodes policy sourceBinding count
  /-- Every generated input belongs to a generated child node. -/
  input_nodes :
    ∀ input,
      input ∈ inputs →
        input.node ∈ generatedNodes policy sourceBinding count
  /-- The output set exactly reflects the per-child output ports. -/
  outputs_exact :
    ∀ output,
      output ∈ outputs ↔
        ∃ index port,
          port ∈ childOutputPorts index ∧
            output = { node := policy.childIndex sourceBinding index, port := port }
  /-- The input set exactly reflects the per-child input ports. -/
  inputs_exact :
    ∀ input,
      input ∈ inputs ↔
        ∃ index port,
          port ∈ childInputPorts index ∧
            input = { node := policy.childIndex sourceBinding index, port := port }

namespace KindInstantiatedFrontiers

/-- Convert already-instantiated child frontiers into the canonical `MakeWitness`. -/
def toMakeWitness
    {nodeBinding : node → binding}
    {kind : AcceptedKindDecl}
    {policy : GeneratedNamePolicy binding node nodeBinding}
    {sourceBinding : binding}
    {count : Nat}
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := node)) :
    MakeWitness binding node OutputPortSignature InputPortSignature nodeBinding where
  sourceBinding := sourceBinding
  nodes := generatedNodes policy sourceBinding count
  outputs := frontiers.outputs
  inputs := frontiers.inputs
  output_nodes := frontiers.output_nodes
  input_nodes := frontiers.input_nodes
  nodeBinding_eq := by
    intro graphNode hGraphNode
    rcases Finset.mem_image.mp hGraphNode with ⟨index, _hIndex, hEq⟩
    have hBinding := policy.childNode_binding sourceBinding index.val
    have hChild :
        policy.childIndex sourceBinding index = policy.childNode sourceBinding index.val :=
      rfl
    rw [← hEq, hChild]
    exact hBinding
  count := count
  childNode := policy.childIndex sourceBinding
  childOutputPorts := frontiers.childOutputPorts
  childInputPorts := frontiers.childInputPorts
  childNode_mem := by
    intro index
    exact Finset.mem_image.mpr ⟨index, Finset.mem_univ index, rfl⟩
  nodes_exact := by
    intro graphNode hGraphNode
    rcases Finset.mem_image.mp hGraphNode with ⟨index, _hIndex, hEq⟩
    exact ⟨index, hEq⟩
  outputs_exact := frontiers.outputs_exact
  inputs_exact := frontiers.inputs_exact
  childNode_inj := policy.childIndex_injective sourceBinding

/-- Kind-instantiated child frontiers produce a source-linear object. -/
theorem toMakeWitness_portLinear
    {nodeBinding : node → binding}
    {kind : AcceptedKindDecl}
    {policy : GeneratedNamePolicy binding node nodeBinding}
    {sourceBinding : binding}
    {count : Nat}
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := node)) :
    frontiers.toMakeWitness.toObject.graph.PortLinear :=
  frontiers.toMakeWitness.toObject.linear

/-- The source-linear object built from kind-instantiated frontiers exposes
exactly the generated output instances promised by the witness. -/
theorem toMakeWitness_toObject_outputs_exact
    {nodeBinding : node → binding}
    {kind : AcceptedKindDecl}
    {policy : GeneratedNamePolicy binding node nodeBinding}
    {sourceBinding : binding}
    {count : Nat}
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := node)) :
    ∀ output,
      output ∈ frontiers.toMakeWitness.toObject.graph.outputs ↔
        ∃ index port,
          port ∈ frontiers.childOutputPorts index ∧
            output = { node := policy.childIndex sourceBinding index, port := port } := by
  simpa
    [KindInstantiatedFrontiers.toMakeWitness, MakeWitness.toObject,
      LinearPortObject.nodePorts, openNodePorts]
    using frontiers.outputs_exact

/-- The source-linear object built from kind-instantiated frontiers exposes
exactly the generated input instances promised by the witness. -/
theorem toMakeWitness_toObject_inputs_exact
    {nodeBinding : node → binding}
    {kind : AcceptedKindDecl}
    {policy : GeneratedNamePolicy binding node nodeBinding}
    {sourceBinding : binding}
    {count : Nat}
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := node)) :
    ∀ input,
      input ∈ frontiers.toMakeWitness.toObject.graph.inputs ↔
        ∃ index port,
          port ∈ frontiers.childInputPorts index ∧
            input = { node := policy.childIndex sourceBinding index, port := port } := by
  simpa
    [KindInstantiatedFrontiers.toMakeWitness, MakeWitness.toObject,
      LinearPortObject.nodePorts, openNodePorts]
    using frontiers.inputs_exact

end KindInstantiatedFrontiers

/-! ## `make(N, K)` Admission -/

namespace Make

/-- Admit `make(N, K)` from a kind-instantiated frontier witness.

The `AcceptedKindDecl.KindSupportsMake` precondition pins the kind-parameter shape from
ADR 0048. The caller supplies `frontiers`, which is the result of substituting each generated
`PortLabel` into the kind's authored frontier. This function does not redo substitution; it turns
the supplied exact child-frontier evidence into the canonical `MakeWitness` object.

The public admission function is intentionally Wire-specific: it targets the
direction-tagged `OutputPortSignature`/`InputPortSignature` wrappers from
`ElaborationIR`, so the accepted kind and the generated frontier witness live in
the same IR vocabulary. The label witness pins `make` to the generated
`<binding>_<index>` labels.

Because `accept` consumes `KindSupportsMake` and the label witness as
preconditions, this function has no remaining rejection branch. `MakeError` is
reserved for the front-end checker that constructs those witnesses. -/
def accept
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (_hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (_hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val) :
    Except MakeError (LinearPortObject NodeId OutputPortSignature InputPortSignature) :=
  Except.ok frontiers.toMakeWitness.toObject

/-- Once kind-shape and label witnesses exist, `make(N, K)` admission is the
canonical object and cannot emit a `MakeError`. -/
theorem accept_eq_ok
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val) :
    accept policy sourceBinding kind hKind count frontiers hLabels =
      Except.ok frontiers.toMakeWitness.toObject :=
  rfl

/-- `Make.accept` never returns an error once its proof preconditions are supplied. -/
theorem accept_never_errors
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (error : MakeError) :
    accept policy sourceBinding kind hKind count frontiers hLabels ≠ Except.error error := by
  intro hError
  cases hError

/-- Successful `make(N, K)` admission returns exactly the supplied instantiated frontier object. -/
theorem accept_ok_eq
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind count frontiers hLabels = Except.ok object) :
    object = frontiers.toMakeWitness.toObject := by
  unfold accept at hAccept
  cases hAccept
  rfl

/-- The `make(N, K)` frontier witness exposes the generated child-label equation. -/
theorem accept_childLabel_eq
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (index : Fin count) :
    frontiers.childLabel index = makeIndexLabel sourceBinding index.val :=
  hLabels index

/-- The `make(N, K)` frontier witness exposes exact generated output frontiers. -/
theorem accept_childOutputPorts_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId)) :
    ∀ index port,
      port ∈ frontiers.childOutputPorts index ↔
        ∃ template,
          template ∈ kind.outputPorts ∧
            port.signature =
              { label := frontiers.childLabel index
                contract := template.contract } :=
  frontiers.childOutputPorts_exact

/-- The `make(N, K)` frontier witness exposes exact generated input frontiers. -/
theorem accept_childInputPorts_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId)) :
    ∀ index port,
      port ∈ frontiers.childInputPorts index ↔
        ∃ template,
          template ∈ kind.inputs ∧
            port.signature =
              { label := frontiers.childLabel index
                contract := template.contract } :=
  frontiers.childInputPorts_exact

/-- Successful `make(N, K)` admission exposes the exact output instances on the returned object. -/
theorem accept_outputs_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind count frontiers hLabels = Except.ok object) :
    ∀ output,
      output ∈ object.graph.outputs ↔
        ∃ index port,
          port ∈ frontiers.childOutputPorts index ∧
            output = { node := policy.childIndex sourceBinding index, port := port } := by
  have hEq : object = frontiers.toMakeWitness.toObject :=
    accept_ok_eq policy sourceBinding kind hKind count frontiers hLabels object hAccept
  rw [hEq]
  exact frontiers.toMakeWitness_toObject_outputs_exact

/-- Successful `make(N, K)` admission exposes the exact input instances on the returned object. -/
theorem accept_inputs_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind count frontiers hLabels = Except.ok object) :
    ∀ input,
      input ∈ object.graph.inputs ↔
        ∃ index port,
          port ∈ frontiers.childInputPorts index ∧
            input = { node := policy.childIndex sourceBinding index, port := port } := by
  have hEq : object = frontiers.toMakeWitness.toObject :=
    accept_ok_eq policy sourceBinding kind hKind count frontiers hLabels object hAccept
  rw [hEq]
  exact frontiers.toMakeWitness_toObject_inputs_exact

/-- A successful `make(N, K)` admission carries source linearity. -/
theorem accept_portLinear
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMake)
    (count : Nat)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding count
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = makeIndexLabel sourceBinding index.val)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind count frontiers hLabels = Except.ok object) :
    object.graph.PortLinear := by
  unfold accept at hAccept
  cases hAccept
  exact KindInstantiatedFrontiers.toMakeWitness_portLinear frontiers

end Make

/-! ## `makeEach(items, K)` Admission -/

namespace MakeEach

/-- Validate `makeEach` items while tracking labels seen so far. -/
def acceptItemsWithSeen
    (sourceBinding : ElaborationIR.BindingName)
    (seen : List ElaborationIR.FieldLabel) :
    List MakeItem → Except MakeEachError (List MakeItem)
  | [] => Except.ok []
  | head :: tail =>
      if head.Valid then
        if head.label ∈ seen then
          Except.error (MakeEachError.duplicateGeneratedLabel sourceBinding head.label)
        else
          match acceptItemsWithSeen sourceBinding (head.label :: seen) tail with
          | Except.error error => Except.error error
          | Except.ok acceptedTail => Except.ok (head :: acceptedTail)
      else
        Except.error (MakeEachError.invalidItemLabel sourceBinding head.label)

/-- Reject invalid or duplicate labels in a static `makeEach` item list. -/
def acceptItems
    (sourceBinding : ElaborationIR.BindingName)
    (items : List MakeItem) :
    Except MakeEachError (List MakeItem) :=
  acceptItemsWithSeen sourceBinding [] items

private def makeEachExampleBinding : ElaborationIR.BindingName := ⟨"workers"⟩

private def makeEachExampleItem : MakeItem :=
  { label := ⟨"worker_0"⟩
    value := none }

private def makeEachDuplicateItem : MakeItem :=
  { label := ⟨"worker_0"⟩
    value := none }

private def makeEachInvalidItem : MakeItem :=
  { label := ⟨""⟩
    value := none }

/-- Invalid generated labels are rejected with the concrete offending label. -/
example :
    acceptItems makeEachExampleBinding [makeEachInvalidItem] =
      Except.error
        (MakeEachError.invalidItemLabel makeEachExampleBinding makeEachInvalidItem.label) := by
  rfl

/-- Duplicate generated labels are rejected with the concrete duplicate label. -/
example :
    acceptItems makeEachExampleBinding [makeEachExampleItem, makeEachDuplicateItem] =
      Except.error
        (MakeEachError.duplicateGeneratedLabel
          makeEachExampleBinding
          makeEachDuplicateItem.label) := by
  rfl

/-- Admit `makeEach(items, K)` from checked items and instantiated child frontiers.

The function still performs the source-level label checks over `items`: labels
must be locally valid and duplicate-free. The kind-shape precondition requires
either a generated `PortLabel` parameter or generated `PortLabel` plus static
`Value`; the supplied `frontiers` is the exact post-substitution port family.

The checked item list is not stored in the returned object. Its relationship to
the generated frontier is the explicit `hLabels` proof obligation, exposed for
callers through `accept_childLabel_eq`. Missing/multiple `PortLabel`
diagnostics are front-end obligations discharged before this entry point. -/
def accept
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (_hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (_hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label) :
    Except MakeEachError
      (LinearPortObject NodeId OutputPortSignature InputPortSignature) :=
  match acceptItems sourceBinding items with
  | Except.error error => Except.error error
  | Except.ok _items => Except.ok frontiers.toMakeWitness.toObject

/-- `makeEach` errors exactly when source item-label checking errors.

Kind-shape diagnostics are not produced by this function: callers must supply
`KindSupportsMakeEach` before admission reaches this layer. -/
theorem accept_error_iff_acceptItems_error
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (error : MakeEachError) :
    accept policy sourceBinding kind hKind items frontiers hLabels = Except.error error ↔
      acceptItems sourceBinding items = Except.error error := by
  unfold accept
  cases hItems : acceptItems sourceBinding items with
  | error itemError =>
      change Except.error itemError = Except.error error ↔
        Except.error itemError = Except.error error
      constructor
      · intro hError
        cases hError
        rfl
      · intro hError
        cases hError
        rfl
  | ok accepted =>
      change Except.ok frontiers.toMakeWitness.toObject = Except.error error ↔
        Except.ok accepted = Except.error error
      constructor
      · intro hError
        cases hError
      · intro hError
        cases hError

/-- Successful `makeEach(items, K)` admission returns the supplied frontier object. -/
theorem accept_ok_eq
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind items frontiers hLabels = Except.ok object) :
    object = frontiers.toMakeWitness.toObject := by
  unfold accept at hAccept
  cases hItems : acceptItems sourceBinding items with
  | error error =>
      rw [hItems] at hAccept
      cases hAccept
  | ok _accepted =>
      rw [hItems] at hAccept
      cases hAccept
      rfl

/-- The `makeEach(items, K)` frontier witness exposes item-derived generated labels. -/
theorem accept_childLabel_eq
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (index : Fin items.length) :
    frontiers.childLabel index = (items.get index).label :=
  hLabels index

/-- The `makeEach(items, K)` frontier witness exposes exact generated output frontiers. -/
theorem accept_childOutputPorts_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId)) :
    ∀ index port,
      port ∈ frontiers.childOutputPorts index ↔
        ∃ template,
          template ∈ kind.outputPorts ∧
            port.signature =
              { label := frontiers.childLabel index
                contract := template.contract } :=
  frontiers.childOutputPorts_exact

/-- The `makeEach(items, K)` frontier witness exposes exact generated input frontiers. -/
theorem accept_childInputPorts_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId)) :
    ∀ index port,
      port ∈ frontiers.childInputPorts index ↔
        ∃ template,
          template ∈ kind.inputs ∧
            port.signature =
              { label := frontiers.childLabel index
                contract := template.contract } :=
  frontiers.childInputPorts_exact

/-- Successful `makeEach(items, K)` admission exposes exact output instances on the result. -/
theorem accept_outputs_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind items frontiers hLabels = Except.ok object) :
    ∀ output,
      output ∈ object.graph.outputs ↔
        ∃ index port,
          port ∈ frontiers.childOutputPorts index ∧
            output = { node := policy.childIndex sourceBinding index, port := port } := by
  have hEq : object = frontiers.toMakeWitness.toObject :=
    accept_ok_eq policy sourceBinding kind hKind items frontiers hLabels object hAccept
  rw [hEq]
  exact frontiers.toMakeWitness_toObject_outputs_exact

/-- Successful `makeEach(items, K)` admission exposes exact input instances on the result. -/
theorem accept_inputs_exact
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind items frontiers hLabels = Except.ok object) :
    ∀ input,
      input ∈ object.graph.inputs ↔
        ∃ index port,
          port ∈ frontiers.childInputPorts index ∧
            input = { node := policy.childIndex sourceBinding index, port := port } := by
  have hEq : object = frontiers.toMakeWitness.toObject :=
    accept_ok_eq policy sourceBinding kind hKind items frontiers hLabels object hAccept
  rw [hEq]
  exact frontiers.toMakeWitness_toObject_inputs_exact

/-- A successful `makeEach(items, K)` admission carries source linearity. -/
theorem accept_portLinear
    {nodeBinding : NodeId → BindingName}
    (policy : GeneratedNamePolicy BindingName NodeId nodeBinding)
    (sourceBinding : BindingName)
    (kind : ElaborationIR.AcceptedKindDecl)
    (hKind : kind.KindSupportsMakeEach)
    (items : List MakeItem)
    (frontiers :
      KindInstantiatedFrontiers kind policy sourceBinding items.length
        (node := NodeId))
    (hLabels :
      ∀ index,
        frontiers.childLabel index = (items.get index).label)
    (object : LinearPortObject NodeId OutputPortSignature InputPortSignature)
    (hAccept :
      accept policy sourceBinding kind hKind items frontiers hLabels = Except.ok object) :
    object.graph.PortLinear := by
  unfold accept at hAccept
  cases hItems : acceptItems sourceBinding items with
  | error error =>
      rw [hItems] at hAccept
      cases hAccept
  | ok _accepted =>
      rw [hItems] at hAccept
      cases hAccept
      exact KindInstantiatedFrontiers.toMakeWitness_portLinear frontiers

end MakeEach

/-! ## `*` (Star) Admission -/

namespace Star

/-- `*` admission at the source-linearity layer.

ADR 0049's `*` elaborates to `multi-side => phantom => singular-side`. The phantom synthesis,
record-form discriminator, and bulk-contraction pairing are mechanized in
`PhantomAdapterWitness`. This entry point therefore consumes a fully constructed witness and
returns the resulting `LinearPortObject`. The integrator slice constructs the witness from a
record-contract, the multi-side `LinearPortObject`, and the singular-side `LinearPortObject`; this
file does not re-derive that machinery.

Returning `Except StarError` keeps the signature uniform with the other two admission entry
points. The first-sketch implementation never produces an error, because witness construction has
already discharged the structural obligations; the named diagnostics are reserved for slice 7's
front-end before it builds the witness. -/
def accept
    (witness : PhantomAdapterWitness node outputPort inputPort) :
    Except StarError (LinearPortObject node outputPort inputPort) :=
  Except.ok witness.starInsertion

/-- Successful `*` admission returns exactly the supplied phantom-adapter insertion. -/
theorem accept_ok_eq
    (witness : PhantomAdapterWitness node outputPort inputPort)
    (object : LinearPortObject node outputPort inputPort)
    (hAccept : accept witness = Except.ok object) :
    object = witness.starInsertion := by
  have hUnwrap :
      (Except.ok witness.starInsertion :
        Except StarError (LinearPortObject node outputPort inputPort)) =
          Except.ok object := hAccept
  exact (Except.ok.inj hUnwrap).symm

/-- The witnessed `*` admission preserves source linearity. -/
theorem accept_portLinear
    (witness : PhantomAdapterWitness node outputPort inputPort)
    (object : LinearPortObject node outputPort inputPort)
    (hAccept : accept witness = Except.ok object) :
    object.graph.PortLinear := by
  have hEq : object = witness.starInsertion :=
    accept_ok_eq witness object hAccept
  rw [hEq]
  exact witness.starInsertion_portLinear

end Star

end LinearPortGraph
end Cortex.Wire
