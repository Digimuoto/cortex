import Cortex.Wire.AdmissionArtifact.StaticValue
import Cortex.Wire.GeneratedForms

/-!
## Overview

Generated-form artifact rows for decoded Wire admission artifacts.

This page models `make` and `makeEach` provenance rows, including generated
source children, used lowered children, source-to-used backing, binding-owned
node identity, and projection into Lean `MakeItem` rows.
-/

namespace Cortex.Wire
namespace AdmissionArtifact

open Cortex.Wire.ElaborationIR

/-! ## Generated-Form Artifacts -/

/-- Generated-form kind recorded by the compiler artifact. -/
inductive GeneratedFormKind where
  | make
  | makeEach
  deriving Repr

/-- Source child row for `make`/`makeEach` before unused generated children are pruned. -/
structure GeneratedChildSourceArtifact where
  node : NodeId
  label : FieldLabel
  value : Option AdmissionStaticValue
  deriving Repr

namespace GeneratedChildSourceArtifact

/-- Identity key for matching source generated children to lowered used children. -/
def key (child : GeneratedChildSourceArtifact) : NodeId × FieldLabel :=
  (child.node, child.label)

/-- Optional static payload row is itself structurally valid. -/
def StaticValueValid (child : GeneratedChildSourceArtifact) : Prop :=
  match child.value with
  | none => True
  | some value => value.Valid

/-- Source generated-child rows carry valid node identity, label, and optional value. -/
structure Valid (child : GeneratedChildSourceArtifact) : Prop where
  nodeValid : child.node.Valid
  labelValid : child.label.Valid
  staticValueValid : child.StaticValueValid

/-- Convert a decoded generated-source row into the Lean `makeEach` item carrier. -/
def toMakeItem
    (child : GeneratedChildSourceArtifact) :
    LinearPortGraph.MakeItem :=
  { label := child.label
    value := child.value.map AdmissionStaticValue.toStaticValue }

@[simp]
theorem toMakeItem_label (child : GeneratedChildSourceArtifact) :
    child.toMakeItem.label = child.label :=
  rfl

@[simp]
theorem toMakeItem_value (child : GeneratedChildSourceArtifact) :
    child.toMakeItem.value = child.value.map AdmissionStaticValue.toStaticValue :=
  rfl

theorem toMakeItem_valid
    {child : GeneratedChildSourceArtifact}
    (hLabel : child.label.Valid) :
    child.toMakeItem.Valid :=
  hLabel

end GeneratedChildSourceArtifact

/-- Lowered child row that survived graph pruning and carries concrete frontiers. -/
structure GeneratedChildArtifact where
  node : NodeId
  label : FieldLabel
  outputs : List AdmissionBoundaryPort
  inputs : List AdmissionBoundaryPort
  deriving Repr

namespace GeneratedChildArtifact

/-- Identity key for matching lowered used children back to generated source rows. -/
def key (child : GeneratedChildArtifact) : NodeId × FieldLabel :=
  (child.node, child.label)

/-- Serialized output endpoint identities for this generated child. -/
def outputKeys (child : GeneratedChildArtifact) : List (NodeId × FieldLabel × ContractId) :=
  child.outputs.map AdmissionBoundaryPort.key

/-- Serialized input endpoint identities for this generated child. -/
def inputKeys (child : GeneratedChildArtifact) : List (NodeId × FieldLabel × ContractId) :=
  child.inputs.map AdmissionBoundaryPort.key

/-- Every serialized frontier endpoint for a generated child belongs to that child node. -/
def FrontiersOwnedByChild (child : GeneratedChildArtifact) : Prop :=
  (∀ output, output ∈ child.outputs → output.node = child.node) ∧
    (∀ input, input ∈ child.inputs → input.node = child.node)

/-- Serialized generated-child frontiers are duplicate-free per direction. -/
def FrontierKeysUnique (child : GeneratedChildArtifact) : Prop :=
  child.outputKeys.Nodup ∧ child.inputKeys.Nodup

/-- Used generated-child rows carry valid identities and boundary rows. -/
structure Valid (child : GeneratedChildArtifact) : Prop where
  nodeValid : child.node.Valid
  labelValid : child.label.Valid
  frontiersOwnedByChild : child.FrontiersOwnedByChild
  frontierKeysUnique : child.FrontierKeysUnique
  outputsValid : BoundaryPortsValid child.outputs
  inputsValid : BoundaryPortsValid child.inputs

/-- Used generated-child rows mention only nodes in the top-level summary. -/
structure DomainClosed (nodes : List NodeId) (child : GeneratedChildArtifact) : Prop where
  nodeClosed : child.node ∈ nodes
  outputsClosed : BoundaryPortsClosed nodes child.outputs
  inputsClosed : BoundaryPortsClosed nodes child.inputs

end GeneratedChildArtifact

/-- Generated-family artifact emitted for one `make` or `makeEach` binding. -/
structure GeneratedFormArtifact where
  kind : GeneratedFormKind
  kindName : KindName
  binding : BindingName
  sourceChildren : List GeneratedChildSourceArtifact
  usedChildren : List GeneratedChildArtifact
  deriving Repr

namespace GeneratedFormArtifact

/-- Source child labels before graph pruning. -/
def sourceLabels (artifact : GeneratedFormArtifact) : List FieldLabel :=
  artifact.sourceChildren.map GeneratedChildSourceArtifact.label

/-- Source child identity keys before graph pruning. -/
def sourceChildKeys (artifact : GeneratedFormArtifact) : List (NodeId × FieldLabel) :=
  artifact.sourceChildren.map GeneratedChildSourceArtifact.key

/-- Used child labels after graph pruning. -/
def usedLabels (artifact : GeneratedFormArtifact) : List FieldLabel :=
  artifact.usedChildren.map GeneratedChildArtifact.label

/-- Used child identity keys after graph pruning. -/
def usedChildKeys (artifact : GeneratedFormArtifact) : List (NodeId × FieldLabel) :=
  artifact.usedChildren.map GeneratedChildArtifact.key

/-- Deterministic generated child node identity for a binding and generated label. -/
def childNodeFor (binding : BindingName) (label : FieldLabel) : NodeId :=
  ⟨binding.name ++ "_" ++ label.name⟩

/-- Every used generated child is backed by a source generated child row.

The Haskell compiler establishes this by checking `LoweredNode` provenance
before emitting `usedChildren`. A future JSON validator should discharge this
predicate before turning artifact rows into generated-form witnesses. -/
def UsedChildrenFromSource (artifact : GeneratedFormArtifact) : Prop :=
  ∀ child, child ∈ artifact.usedChildren → child.key ∈ artifact.sourceChildKeys

/-- Source and used generated child node identities follow the binding/label name policy. -/
def ChildrenOwnedByBinding (artifact : GeneratedFormArtifact) : Prop :=
  (∀ child, child ∈ artifact.sourceChildren →
      child.node = childNodeFor artifact.binding child.label) ∧
    (∀ child, child ∈ artifact.usedChildren →
      child.node = childNodeFor artifact.binding child.label)

/-- Source and used generated-child rows are unique by generated child identity. -/
def ChildKeysUnique (artifact : GeneratedFormArtifact) : Prop :=
  artifact.sourceChildKeys.Nodup ∧ artifact.usedChildKeys.Nodup

/-- Every serialized static payload on source children is structurally valid. -/
def SourceValuesValid (artifact : GeneratedFormArtifact) : Prop :=
  ∀ child, child ∈ artifact.sourceChildren → child.StaticValueValid

/-- `make(N, K)` source labels are exactly the count-derived `0 .. N - 1` labels. -/
def MakeSourceLabelsCanonical (artifact : GeneratedFormArtifact) : Prop :=
  artifact.sourceLabels =
    (List.range artifact.sourceChildren.length).map (fun index => ⟨toString index⟩)

/-- `make(N, K)` source rows carry no per-item static value payload. -/
def MakeSourceValuesEmpty (artifact : GeneratedFormArtifact) : Prop :=
  ∀ child, child ∈ artifact.sourceChildren → child.value = none

/-- Generated-form kind rows have the payload shape their source construct implies. -/
def KindShapeMatches (artifact : GeneratedFormArtifact) : Prop :=
  match artifact.kind with
  | .make => artifact.MakeSourceLabelsCanonical ∧ artifact.MakeSourceValuesEmpty
  | .makeEach => True

/-- Generated-form rows carry valid kind/binding identifiers and child rows. -/
structure RowsValid (artifact : GeneratedFormArtifact) : Prop where
  kindNameValid : artifact.kindName.Valid
  bindingValid : artifact.binding.Valid
  sourceChildrenValid : ∀ child, child ∈ artifact.sourceChildren → child.Valid
  usedChildrenValid : ∀ child, child ∈ artifact.usedChildren → child.Valid

/-- Used generated children that survived pruning are closed over the top-level node summary.

Source children are deliberately not required to be top-level nodes: the compiler
records source generated children before graph pruning, while `usedChildren`
records the generated nodes that actually remain in the compiled graph. -/
def DomainClosed (nodes : List NodeId) (artifact : GeneratedFormArtifact) : Prop :=
  ∀ child, child ∈ artifact.usedChildren → GeneratedChildArtifact.DomainClosed nodes child

/-- Exact source-child backing still exposes the old label-membership consequence. -/
theorem usedChildrenFromSource_label_mem
    {artifact : GeneratedFormArtifact}
    (hBacked : artifact.UsedChildrenFromSource)
    {child : GeneratedChildArtifact}
    (hChild : child ∈ artifact.usedChildren) :
    child.label ∈ artifact.sourceLabels := by
  rcases List.mem_map.mp (hBacked child hChild) with ⟨source, hSource, hKey⟩
  exact List.mem_map.mpr ⟨source, hSource, Prod.mk.inj hKey |>.right⟩

/-- Row-level validator obligation for a generated-form artifact. -/
structure Valid (artifact : GeneratedFormArtifact) : Prop where
  usedChildrenFromSource : artifact.UsedChildrenFromSource
  childrenOwnedByBinding : artifact.ChildrenOwnedByBinding
  childKeysUnique : artifact.ChildKeysUnique
  sourceValuesValid : artifact.SourceValuesValid
  kindShapeMatches : artifact.KindShapeMatches
  rowsValid : artifact.RowsValid

/-- Source rows viewed as Lean `makeEach` items. -/
def sourceMakeItems
    (artifact : GeneratedFormArtifact) :
    List LinearPortGraph.MakeItem :=
  artifact.sourceChildren.map GeneratedChildSourceArtifact.toMakeItem

/-- The generated-label list survives the source-row-to-`MakeItem` projection unchanged. -/
theorem sourceMakeItems_labels
    (artifact : GeneratedFormArtifact) :
    artifact.sourceMakeItems.map LinearPortGraph.MakeItem.label =
      artifact.sourceChildren.map GeneratedChildSourceArtifact.label := by
  simp [sourceMakeItems]

/-- The optional static payload list is exactly mapped into `StaticValue`. -/
theorem sourceMakeItems_values
    (artifact : GeneratedFormArtifact) :
    artifact.sourceMakeItems.map LinearPortGraph.MakeItem.value =
      artifact.sourceChildren.map
        (fun child => child.value.map AdmissionStaticValue.toStaticValue) := by
  simp [sourceMakeItems]

/-- If every source child has a valid generated label, the projected Lean items are valid. -/
theorem sourceMakeItems_valid
    {artifact : GeneratedFormArtifact}
    (hLabels : ∀ child, child ∈ artifact.sourceChildren → child.label.Valid) :
    LinearPortGraph.MakeItem.ItemsValid artifact.sourceMakeItems := by
  intro item hItem
  unfold sourceMakeItems at hItem
  rcases List.mem_map.mp hItem with ⟨child, hChildMem, hItemEq⟩
  rw [← hItemEq]
  exact GeneratedChildSourceArtifact.toMakeItem_valid (hLabels child hChildMem)

/-- Binding-owned, key-unique source rows project to duplicate-free `makeEach` labels. -/
theorem sourceMakeItems_labelsUnique
    {artifact : GeneratedFormArtifact}
    (hOwned : artifact.ChildrenOwnedByBinding)
    (hUnique : artifact.ChildKeysUnique) :
    LinearPortGraph.MakeItem.LabelsUnique artifact.sourceMakeItems := by
  unfold LinearPortGraph.MakeItem.LabelsUnique
  rw [sourceMakeItems_labels]
  have hSourceChildrenNodup : artifact.sourceChildren.Nodup :=
    hUnique.left.of_map GeneratedChildSourceArtifact.key
  apply hSourceChildrenNodup.map_on
  intro left hLeft right hRight hLabels
  exact
    List.inj_on_of_nodup_map hUnique.left
      hLeft
      hRight
      (by
        unfold GeneratedChildSourceArtifact.key
        apply Prod.ext
        · rw [hOwned.left left hLeft, hOwned.left right hRight, hLabels]
        · exact hLabels)

end GeneratedFormArtifact

end AdmissionArtifact
end Cortex.Wire
