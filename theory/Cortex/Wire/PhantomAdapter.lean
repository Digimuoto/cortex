import Cortex.Wire.PortLinearity

/-!
## Overview

Proof-facing phantom adapter construction for Wire's `*` topology operator.

## Context

ADR 0049 defines `a * b` by elaboration to ordinary graph structure:

```text
a => phantom => b
```

Both arrows are ordinary certified bulk contractions from ADR 0047. The phantom
is an ordinary generated source object. Therefore `*` does not need its own
port-linearity preservation theorem; it is a construction in the closed source
linear algebra.
-/

namespace Cortex.Wire
namespace LinearPortGraph

variable {node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

namespace LinearPortObject

/-- Apply a certified bulk contraction to a linear source object. -/
def bulkContract
    (object : LinearPortObject node outputPort inputPort)
    {finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract object.graph finish) :
    LinearPortObject node outputPort inputPort where
  graph := finish
  linear := bulkContract_preserves_portLinear hBulk object.linear

end LinearPortObject

/-! ## Bulk Trace Membership -/

/-- `BulkContractContainsPair trace output input` means that one step of a certified
bulk-contraction trace contracts `output` with `input`.

This is the phantom-adapter analogue of the trace-membership predicate used by
primitive graph elaboration. `BulkContract` keeps trace order for induction; this
predicate lets the source `*` witness state the unordered boundary it discharged. -/
def BulkContractContainsPair :
    {start finish : LinearPortGraph node outputPort inputPort} →
      BulkContract start finish →
        SourcePortInstance node outputPort →
          SourcePortInstance node inputPort →
            Prop
  | _, _, BulkContract.done _graph, _output, _input => False
  | _, _, BulkContract.step _graph output input _hOutputExposed _hInputExposed tail,
      candidateOutput, candidateInput =>
      (candidateOutput = output ∧ candidateInput = input) ∨
        BulkContractContainsPair tail candidateOutput candidateInput

/-! ## Phantom Adapter Witness -/

/-- Direction of the generated phantom adapter.

`gather` consumes a multi-input boundary and emits one singular product output.
`scatter` consumes one singular product input and emits a multi-output boundary. -/
inductive PhantomDirection where
  | gather
  | scatter
  deriving DecidableEq, Repr

/-- Product shape used by the generated `*` phantom.

ADR 0049 introduced nominal record products. ADR 0052 generalizes `*` to finite
products by adding bounded indexed products `[T; N]`. Counts are natural:
`[T; 0]` is the empty finite product with no multi-side leaves. -/
inductive ProductAdapterKind (productContract : Type) where
  /-- Nominal record product, paired by field label. -/
  | nominalRecord
  /-- Bounded indexed product, paired by a finite index set of this cardinality. -/
  | boundedIndexed (element : productContract) (count : Nat)
  deriving DecidableEq, Repr

/-- Shape certificate for the generated finite-product phantom.

The certificate pins the phantom to one generated node and partitions its boundary into the
multi-side and singular-side ports used by ADR 0049/0052. Contract, record-field, indexed element
compatibility, and indexed endpoint order are recorded through caller-supplied projections and
enumerators.

The field shape mirrors the finite-product discriminator: direction, product kind, one phantom
node, boundary partition, per-direction singularity, and exact source port sets for the generated
adapter. -/
structure PhantomProductShape
    (productContract label : Type)
    (phantom : LinearPortObject node outputPort inputPort) where
  /-- Direction chosen by the finite-product discriminator. -/
  direction : PhantomDirection
  /-- Output-port contract projection used to state indexed product uniformity. -/
  outputContract : outputPort → productContract
  /-- Input-port contract projection used to state indexed product uniformity. -/
  inputContract : inputPort → productContract
  /-- Output-port label projection used to state indexed product label uniqueness. -/
  outputLabel : outputPort → label
  /-- Input-port label projection used to state indexed product label uniqueness. -/
  inputLabel : inputPort → label
  /-- Product constructor crossed by this adapter. -/
  productKind : ProductAdapterKind productContract
  /-- Aggregate product contract carried by the singular endpoint. -/
  singularContract : productContract
  /-- The unique generated phantom node. -/
  phantomNode : node
  /-- Output ports on the multi-side boundary. -/
  multiOutputs : Finset (SourcePortInstance node outputPort)
  /-- Input ports on the multi-side boundary. -/
  multiInputs : Finset (SourcePortInstance node inputPort)
  /-- Singular record output, present exactly in gather mode. -/
  singularOutputs : Finset (SourcePortInstance node outputPort)
  /-- Singular record input, present exactly in scatter mode. -/
  singularInputs : Finset (SourcePortInstance node inputPort)
  /-- The generated phantom object has exactly one node. -/
  nodes_exact : phantom.graph.nodes = {phantomNode}
  /-- Phantom outputs are exactly the declared multi outputs plus singular outputs. -/
  outputs_exact : phantom.graph.outputs = multiOutputs ∪ singularOutputs
  /-- Phantom inputs are exactly the declared multi inputs plus singular inputs. -/
  inputs_exact : phantom.graph.inputs = multiInputs ∪ singularInputs
  /-- Generated phantom starts with every output exposed. -/
  exposedOutputs_exact : phantom.graph.exposedOutputs = phantom.graph.outputs
  /-- Generated phantom starts with every input exposed. -/
  exposedInputs_exact : phantom.graph.exposedInputs = phantom.graph.inputs
  /-- Multi and singular output sets are a partition. -/
  output_partition :
    ∀ output, output ∈ multiOutputs → output ∈ singularOutputs → False
  /-- Multi and singular input sets are a partition. -/
  input_partition :
    ∀ input, input ∈ multiInputs → input ∈ singularInputs → False
  /-- Every declared multi output belongs to the phantom node. -/
  multiOutput_node :
    ∀ output, output ∈ multiOutputs → output.node = phantomNode
  /-- Every declared singular output belongs to the phantom node. -/
  singularOutput_node :
    ∀ output, output ∈ singularOutputs → output.node = phantomNode
  /-- Every declared multi input belongs to the phantom node. -/
  multiInput_node :
    ∀ input, input ∈ multiInputs → input.node = phantomNode
  /-- Every declared singular input belongs to the phantom node. -/
  singularInput_node :
    ∀ input, input ∈ singularInputs → input.node = phantomNode
  /-- Indexed products expose exactly their static arity on the multi-side. -/
  indexed_cardinality :
    match productKind, direction with
    | ProductAdapterKind.nominalRecord, _ => True
    | ProductAdapterKind.boundedIndexed _element count, PhantomDirection.gather =>
        multiInputs.card = count
    | ProductAdapterKind.boundedIndexed _element count, PhantomDirection.scatter =>
        multiOutputs.card = count
  /-- Indexed products expose a source-order enumeration of the multi-side endpoints. -/
  indexed_order :
    match productKind, direction with
    | ProductAdapterKind.nominalRecord, _ => True
    | ProductAdapterKind.boundedIndexed _element count, PhantomDirection.gather =>
        ∃ orderedInputs : Fin count → SourcePortInstance node inputPort,
          Function.Injective orderedInputs ∧
            ∀ input, input ∈ multiInputs ↔ ∃ index, orderedInputs index = input
    | ProductAdapterKind.boundedIndexed _element count, PhantomDirection.scatter =>
        ∃ orderedOutputs : Fin count → SourcePortInstance node outputPort,
          Function.Injective orderedOutputs ∧
            ∀ output, output ∈ multiOutputs ↔ ∃ index, orderedOutputs index = output
  /-- Indexed products expose only endpoints with the declared element contract. -/
  indexed_contracts :
    match productKind, direction with
    | ProductAdapterKind.nominalRecord, _ => True
    | ProductAdapterKind.boundedIndexed element _count, PhantomDirection.gather =>
        ∀ input, input ∈ multiInputs → inputContract input.port = element
    | ProductAdapterKind.boundedIndexed element _count, PhantomDirection.scatter =>
        ∀ output, output ∈ multiOutputs → outputContract output.port = element
  /-- Indexed products expose pairwise label-distinct multi-side endpoints. -/
  indexed_labels_injective :
    match productKind, direction with
    | ProductAdapterKind.nominalRecord, _ => True
    | ProductAdapterKind.boundedIndexed _element _count, PhantomDirection.gather =>
        ∀ left,
          left ∈ multiInputs →
            ∀ right,
              right ∈ multiInputs →
                inputLabel left.port = inputLabel right.port →
                  left = right
    | ProductAdapterKind.boundedIndexed _element _count, PhantomDirection.scatter =>
        ∀ left,
          left ∈ multiOutputs →
            ∀ right,
              right ∈ multiOutputs →
                outputLabel left.port = outputLabel right.port →
                  left = right
  /-- The singular endpoint carries the aggregate product contract. -/
  singular_contracts :
    match direction with
    | PhantomDirection.gather =>
        ∀ output, output ∈ singularOutputs → outputContract output.port = singularContract
    | PhantomDirection.scatter =>
        ∀ input, input ∈ singularInputs → inputContract input.port = singularContract
  /-- Direction-specific singular-side and multi-side shape. -/
  direction_consistent :
    match direction with
    | PhantomDirection.gather =>
        multiOutputs = ∅ ∧ singularInputs = ∅ ∧ singularOutputs.card = 1
    | PhantomDirection.scatter =>
        multiInputs = ∅ ∧ singularOutputs = ∅ ∧ singularInputs.card = 1

namespace PhantomProductShape

/-- Phantom-side inputs consumed by the left-to-phantom contraction. -/
def leftBoundaryInputs
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom) :
    Finset (SourcePortInstance node inputPort) :=
  match shape.direction with
  | PhantomDirection.gather => shape.multiInputs
  | PhantomDirection.scatter => shape.singularInputs

/-- Phantom-side outputs consumed by the phantom-to-right contraction. -/
def rightBoundaryOutputs
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom) :
    Finset (SourcePortInstance node outputPort) :=
  match shape.direction with
  | PhantomDirection.gather => shape.singularOutputs
  | PhantomDirection.scatter => shape.multiOutputs

/-- Indexed gather phantoms expose exactly the bounded product arity on the multi-input side. -/
theorem indexed_gather_multiInputs_card
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.gather) :
    shape.multiInputs.card = count := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_cardinality ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_cardinality

/-- Indexed scatter phantoms expose exactly the bounded product arity on the multi-output side. -/
theorem indexed_scatter_multiOutputs_card
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    shape.multiOutputs.card = count := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_cardinality ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_cardinality

/-- Indexed gather phantoms expose a `Fin count` enumeration of their multi-input endpoints. -/
theorem indexed_gather_multiInputs_order
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.gather) :
    ∃ orderedInputs : Fin count → SourcePortInstance node inputPort,
      Function.Injective orderedInputs ∧
        ∀ input, input ∈ shape.multiInputs ↔ ∃ index, orderedInputs index = input := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_order ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_order

/-- Indexed scatter phantoms expose a `Fin count` enumeration of their multi-output endpoints. -/
theorem indexed_scatter_multiOutputs_order
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    ∃ orderedOutputs : Fin count → SourcePortInstance node outputPort,
      Function.Injective orderedOutputs ∧
        ∀ output, output ∈ shape.multiOutputs ↔ ∃ index, orderedOutputs index = output := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_order ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_order

/-- Indexed gather phantoms expose only multi-inputs with the product's element contract. -/
theorem indexed_gather_multiInputs_contract
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.gather) :
    ∀ input, input ∈ shape.multiInputs → shape.inputContract input.port = element := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_contracts ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_contracts

/-- Indexed scatter phantoms expose only multi-outputs with the product's element contract. -/
theorem indexed_scatter_multiOutputs_contract
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    ∀ output, output ∈ shape.multiOutputs → shape.outputContract output.port = element := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_contracts ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_contracts

/-- Indexed gather phantoms expose label-distinct multi-input endpoints. -/
theorem indexed_gather_multiInputs_label_injective
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.gather) :
    ∀ left,
      left ∈ shape.multiInputs →
        ∀ right,
          right ∈ shape.multiInputs →
            shape.inputLabel left.port = shape.inputLabel right.port →
              left = right := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_labels_injective ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_labels_injective

/-- Indexed scatter phantoms expose label-distinct multi-output endpoints. -/
theorem indexed_scatter_multiOutputs_label_injective
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    {count : Nat}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element count)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    ∀ left,
      left ∈ shape.multiOutputs →
        ∀ right,
          right ∈ shape.multiOutputs →
            shape.outputLabel left.port = shape.outputLabel right.port →
              left = right := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hKind hDirection indexed_labels_injective ⊢
  cases hDirection
  cases productKind with
  | nominalRecord =>
      cases hKind
  | boundedIndexed shapeElement shapeCount =>
      cases hKind
      exact indexed_labels_injective

/-- Gather phantoms expose singular outputs with the aggregate product contract. -/
theorem gather_singularOutputs_contract
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    (hDirection : shape.direction = PhantomDirection.gather) :
    ∀ output,
      output ∈ shape.singularOutputs →
        shape.outputContract output.port = shape.singularContract := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hDirection singular_contracts ⊢
  cases hDirection
  exact singular_contracts

/-- Scatter phantoms expose singular inputs with the aggregate product contract. -/
theorem scatter_singularInputs_contract
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    ∀ input,
      input ∈ shape.singularInputs →
        shape.inputContract input.port = shape.singularContract := by
  rcases shape with
    ⟨direction, outputContract, inputContract, outputLabel, inputLabel, productKind,
      singularContract,
      phantomNode, multiOutputs, multiInputs, singularOutputs, singularInputs,
      nodes_exact, outputs_exact, inputs_exact, exposedOutputs_exact, exposedInputs_exact,
      output_partition, input_partition, multiOutput_node, singularOutput_node,
      multiInput_node, singularInput_node, indexed_cardinality, indexed_order,
      indexed_contracts,
      indexed_labels_injective, singular_contracts, direction_consistent⟩
  dsimp at hDirection singular_contracts ⊢
  cases hDirection
  exact singular_contracts

/-- Zero-count indexed gather phantoms have no multi-input leaves. -/
theorem indexed_gather_zero_multiInputs_empty
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element 0)
    (hDirection : shape.direction = PhantomDirection.gather) :
    shape.multiInputs = ∅ := by
  exact Finset.card_eq_zero.mp
    (indexed_gather_multiInputs_card shape hKind hDirection)

/-- Zero-count indexed scatter phantoms have no multi-output leaves. -/
theorem indexed_scatter_zero_multiOutputs_empty
    {productContract label : Type}
    {phantom : LinearPortObject node outputPort inputPort}
    (shape : PhantomProductShape productContract label phantom)
    {element : productContract}
    (hKind : shape.productKind = ProductAdapterKind.boundedIndexed element 0)
    (hDirection : shape.direction = PhantomDirection.scatter) :
    shape.multiOutputs = ∅ := by
  exact Finset.card_eq_zero.mp
    (indexed_scatter_multiOutputs_card shape hKind hDirection)

end PhantomProductShape

/-- `PhantomAdapterWitness` exhibits `*` as an ordinary generated phantom plus two contractions.

The witness starts with a left operand, a generated phantom object, and a right operand. It first
overlays and contracts `left <> phantom`, then overlays the right operand and contracts again. The
bulk-contract fields are where the compiler's finite-product discriminator supplies the certified
endpoint matchings. The coverage fields rule out vacuous traces that leave the phantom boundary
unconsumed: the first trace must consume exactly the phantom inputs selected by the product
direction, and the second trace must consume exactly the phantom outputs selected by the product
direction. -/
structure PhantomAdapterWitness (node outputPort inputPort productContract label : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Left operand of `*`. -/
  left : LinearPortObject node outputPort inputPort
  /-- Generated phantom finite-product adapter. -/
  phantom : LinearPortObject node outputPort inputPort
  /-- Right operand of `*`. -/
  right : LinearPortObject node outputPort inputPort
  /-- Shape certificate tying the generated phantom to ADR 0049/0052 finite-product boundaries. -/
  phantomShape : PhantomProductShape productContract label phantom
  /-- The left operand and phantom use disjoint source domains. -/
  leftPhantomDisjoint : DomainDisjoint left.graph phantom.graph
  /-- Intermediate graph after contracting the left/phantom boundary. -/
  afterLeft : LinearPortGraph node outputPort inputPort
  /-- Certified bulk contraction for the left/phantom boundary. -/
  leftBulk :
    BulkContract (LinearPortGraph.overlay left.graph phantom.graph) afterLeft
  /-- Every left/phantom contraction uses an exposed output from the left operand. -/
  leftBulk_outputs_from_left :
    ∀ output input,
      BulkContractContainsPair leftBulk output input →
        output ∈ left.graph.exposedOutputs
  /-- The left/phantom trace consumes exactly the phantom inputs selected by direction. -/
  leftBulk_inputs_exact :
    ∀ input,
      (∃ output, BulkContractContainsPair leftBulk output input) ↔
        input ∈ phantomShape.leftBoundaryInputs
  /-- The intermediate graph and right operand use disjoint source domains. -/
  afterLeftRightDisjoint : DomainDisjoint afterLeft right.graph
  /-- Final graph after contracting the phantom/right boundary. -/
  finish : LinearPortGraph node outputPort inputPort
  /-- Certified bulk contraction for the phantom/right boundary. -/
  rightBulk :
    BulkContract (LinearPortGraph.overlay afterLeft right.graph) finish
  /-- Every phantom/right contraction uses an exposed input from the right operand. -/
  rightBulk_inputs_from_right :
    ∀ output input,
      BulkContractContainsPair rightBulk output input →
        input ∈ right.graph.exposedInputs
  /-- The phantom/right trace consumes exactly the phantom outputs selected by direction. -/
  rightBulk_outputs_exact :
    ∀ output,
      (∃ input, BulkContractContainsPair rightBulk output input) ↔
        output ∈ phantomShape.rightBoundaryOutputs

namespace PhantomAdapterWitness

/-- Elaborate `*` as overlay with a generated phantom followed by two certified contractions. -/
def starInsertion
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label) :
    LinearPortObject node outputPort inputPort :=
  let leftPhantom :=
    LinearPortObject.overlay
      witness.left
      witness.phantom
      witness.leftPhantomDisjoint
  let afterLeft :=
    leftPhantom.bulkContract witness.leftBulk
  let withRight :=
    LinearPortObject.overlay
      afterLeft
      witness.right
      witness.afterLeftRightDisjoint
  withRight.bulkContract witness.rightBulk

/-- `*` elaboration returns a source-linear graph. -/
theorem starInsertion_portLinear
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label) :
    (witness.starInsertion).graph.PortLinear :=
  witness.starInsertion.linear

/-- The first `*` contraction consumes exactly the phantom-side inputs. -/
theorem leftBulk_inputs_exact_of_witness
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label)
    (input : SourcePortInstance node inputPort) :
    (∃ output, BulkContractContainsPair witness.leftBulk output input) ↔
      input ∈ witness.phantomShape.leftBoundaryInputs :=
  witness.leftBulk_inputs_exact input

/-- The second `*` contraction consumes exactly the phantom-side outputs. -/
theorem rightBulk_outputs_exact_of_witness
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label)
    (output : SourcePortInstance node outputPort) :
    (∃ input, BulkContractContainsPair witness.rightBulk output input) ↔
      output ∈ witness.phantomShape.rightBoundaryOutputs :=
  witness.rightBulk_outputs_exact output

/-- Left-side `*` contraction outputs come from the left operand's exposed frontier. -/
theorem leftBulk_outputs_from_left_of_witness
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label)
    {output : SourcePortInstance node outputPort}
    {input : SourcePortInstance node inputPort}
    (hPair : BulkContractContainsPair witness.leftBulk output input) :
    output ∈ witness.left.graph.exposedOutputs :=
  witness.leftBulk_outputs_from_left output input hPair

/-- Right-side `*` contraction inputs come from the right operand's exposed frontier. -/
theorem rightBulk_inputs_from_right_of_witness
    (witness : PhantomAdapterWitness node outputPort inputPort productContract label)
    {output : SourcePortInstance node outputPort}
    {input : SourcePortInstance node inputPort}
    (hPair : BulkContractContainsPair witness.rightBulk output input) :
    input ∈ witness.right.graph.exposedInputs :=
  witness.rightBulk_inputs_from_right output input hPair

end PhantomAdapterWitness
end LinearPortGraph
end Cortex.Wire
